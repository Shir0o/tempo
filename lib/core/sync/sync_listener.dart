import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';
import '../state/day_recorder.dart';
import 'discovery.dart';
import 'peer_pairing.dart';

/// What the Mac sends to `POST /sync`.
class SyncRequest {
  final String deviceId;

  /// The Mac's own store id, recorded as the peer's identity.
  final String storeId;

  /// The phone log epoch this replica has replayed.
  final String logEpoch;

  /// The last `changes.seq` this replica has applied.
  final int appliedSeq;

  /// How many changes this page may carry.
  final int limit;

  /// Proposals waiting for an answer. They are resent until answered.
  final List<SyncIntent> intents;

  const SyncRequest({
    required this.deviceId,
    required this.storeId,
    required this.logEpoch,
    required this.appliedSeq,
    required this.limit,
    this.intents = const [],
  });

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'storeId': storeId,
    'logEpoch': logEpoch,
    'appliedSeq': appliedSeq,
    'limit': limit,
    'intents': intents.map((intent) => intent.toJson()).toList(),
  };

  factory SyncRequest.fromJson(Map<String, dynamic> json) {
    final rawIntents = json['intents'];
    return SyncRequest(
      deviceId: json['deviceId'] as String? ?? '',
      storeId: json['storeId'] as String? ?? '',
      logEpoch: json['logEpoch'] as String? ?? '',
      appliedSeq: json['appliedSeq'] as int? ?? 0,
      limit: json['limit'] as int? ?? 500,
      intents: rawIntents is List
          ? [
              for (final raw in rawIntents)
                SyncIntent.fromJson(Map<String, dynamic>.from(raw as Map)),
            ]
          : const [],
    );
  }
}

/// The phone's answer to one intent.
class IntentOutcome {
  final String intentId;
  final IntentResult result;

  const IntentOutcome({required this.intentId, required this.result});

  Map<String, dynamic> toJson() => {
    'intentId': intentId,
    'status': result.status,
    'reason': result.reason,
    'entityId': result.entityId,
    'appliedAtEpochMs': result.appliedAtEpochMs,
  };

  factory IntentOutcome.fromJson(Map<String, dynamic> json) => IntentOutcome(
    intentId: json['intentId'] as String,
    result: IntentResult(
      status: json['status'] as String,
      reason: json['reason'] as String? ?? '',
      entityId: json['entityId'] as String? ?? '',
      appliedAtEpochMs: json['appliedAtEpochMs'] as int? ?? 0,
    ),
  );
}

/// `{storeId, logEpoch, changes, intentResults, more}`.
class SyncResponse {
  final String storeId;
  final String logEpoch;

  /// Raw `changes` rows, oldest first. Sent unparsed so a kind this Mac does
  /// not know still arrives, and aborts the pull instead of being skipped.
  final List<Map<String, dynamic>> changes;

  final List<IntentOutcome> intentResults;
  final bool more;

  const SyncResponse({
    required this.storeId,
    required this.logEpoch,
    this.changes = const [],
    this.intentResults = const [],
    this.more = false,
  });

  Map<String, dynamic> toJson() => {
    'storeId': storeId,
    'logEpoch': logEpoch,
    'changes': changes,
    'intentResults': intentResults.map((outcome) => outcome.toJson()).toList(),
    'more': more,
  };

  factory SyncResponse.fromJson(Map<String, dynamic> json) {
    final rawChanges = json['changes'];
    final rawResults = json['intentResults'];
    return SyncResponse(
      storeId: json['storeId'] as String? ?? '',
      logEpoch: json['logEpoch'] as String? ?? '',
      changes: rawChanges is List
          ? [
              for (final raw in rawChanges)
                Map<String, dynamic>.from(raw as Map),
            ]
          : const [],
      intentResults: rawResults is List
          ? [
              for (final raw in rawResults)
                IntentOutcome.fromJson(Map<String, dynamic>.from(raw as Map)),
            ]
          : const [],
      more: json['more'] as bool? ?? false,
    );
  }
}

/// The phone's side of replication: an HTTP server that verifies the client's
/// signature, applies its intents through [DayRecorder], and answers with the
/// changes past the client's cursor.
///
/// `GET /changes` is held open for up to [longPollTimeout] so a label on the
/// phone reaches the Mac without waiting for a poll interval. The server itself
/// never wakes a held request; it notices the next change on a short interval,
/// and [notifyChanged] shortens that to immediately when the app can call it.
///
/// Rule: `replicate_enabled` alone gates the listener. A phone with no paired
/// client may still run it; every unpaired request is refused with 401.
class SyncListener {
  static const String defaultHost = '0.0.0.0';
  static const int defaultPort = SyncPeer.defaultPort;

  /// A request larger than this is refused rather than buffered.
  static const int maxBodyBytes = 4 * 1024 * 1024;

  /// How long a stalled request may take to arrive, body included.
  static const Duration readTimeout = Duration(seconds: 15);

  static const Duration defaultLongPollTimeout = Duration(seconds: 25);

  /// The most changes one page may carry, however large a limit the client asks
  /// for.
  static const int maxPageSize = 500;

  static const String timestampHeader = 'x-tempo-timestamp';
  static const String signatureHeader = 'x-tempo-signature';
  static const String deviceHeader = 'x-tempo-device';

  final TempoDatabase database;
  final DayRecorder dayRecorder;
  final PeerPairing pairing;
  final String host;
  final int port;
  final Duration longPollTimeout;
  final PeerAdvertiser? advertiser;
  final String serviceName;

  /// How often a held request re-reads the log when nothing announced a change.
  static const Duration _changePollInterval = Duration(milliseconds: 200);

  HttpServer? _server;
  int _boundPort = 0;
  final List<Completer<void>> _waiters = [];

  /// Bumped when a client appears in `sync_peers` for the first time, so an
  /// open Settings page can show a device that paired while it was watching.
  final ValueNotifier<int> peersRevision = ValueNotifier<int>(0);

  SyncListener({
    required this.database,
    required this.dayRecorder,
    required this.pairing,
    this.host = defaultHost,
    this.port = defaultPort,
    this.longPollTimeout = defaultLongPollTimeout,
    this.advertiser,
    this.serviceName = 'Tempo',
  });

  /// The port the server actually listens on; [port] may be 0, which lets the
  /// OS pick one for tests.
  int get boundPort => _boundPort;

  bool get isRunning => _server != null;

  /// Binds the server and advertises the service when an [advertiser] is set.
  Future<int> start() async {
    if (_server != null) return _boundPort;
    final server = await HttpServer.bind(host, port);
    _server = server;
    _boundPort = server.port;
    server.listen((request) => unawaited(_handle(request)));

    final advertiser = this.advertiser;
    if (advertiser != null) {
      try {
        final settings = await database.getSyncSettings();
        await advertiser.advertise(
          name: serviceName,
          port: _boundPort,
          storeId: settings.storeId,
        );
      } catch (_) {
        // mDNS is a convenience; a network that blocks it still pairs by hand.
      }
    }
    return _boundPort;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    await advertiser?.stop();
  }

  /// Starts or stops the server to match `replicate_enabled`, leaving the store
  /// open either way. Idempotent, so a pairing or a Settings change can call it
  /// again; returns whether the listener is running.
  Future<bool> applyReplicationSetting() async {
    if (!(await database.getSyncSettings()).replicateEnabled) {
      await stop();
      return false;
    }
    await start();
    return true;
  }

  /// Wakes every held change request, so a label written by the app completes
  /// the Mac's wait at once.
  void notifyChanged() {
    final waiting = [..._waiters];
    _waiters.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/sync') {
        await _handleSync(request);
        return;
      }
      if (request.method == 'GET' && path == '/changes') {
        await _handleLongPoll(request);
        return;
      }
      await _json(request, HttpStatus.notFound, {'error': 'not found'});
    } on _HttpFailure catch (failure) {
      await _safeJson(request, failure.status, {'error': failure.message});
    } catch (error) {
      await _safeJson(request, HttpStatus.internalServerError, {
        'error': '$error',
      });
    }
  }

  /// Answers a request that may already be gone: a client that timed out and
  /// hung up must not turn a response into an unhandled error.
  Future<void> _safeJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    try {
      await _json(request, status, body);
    } catch (_) {
      // The connection was closed before the answer could be written.
    }
  }

  Future<void> _handleSync(HttpRequest request) async {
    final body = await _readBody(request);
    final deviceId =
        request.headers.value(deviceHeader) ?? _deviceIdFromBody(body);
    final authorization = await _authorize(request, deviceId, body);
    if (!authorization.isAuthorized) {
      throw _HttpFailure(HttpStatus.unauthorized, _reason(authorization));
    }

    final SyncRequest exchange;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('the body must be a JSON object');
      }
      exchange = SyncRequest.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException catch (e) {
      throw _HttpFailure(HttpStatus.badRequest, '$e');
    }

    // An intent applies at the instant it was tapped, exactly once. The phone
    // records the answer in `processed_intents` inside the same transaction as
    // the Record it produced.
    final outcomes = <IntentOutcome>[];
    for (final intent in exchange.intents) {
      final result = await dayRecorder.applyIntent(intent);
      outcomes.add(IntentOutcome(intentId: intent.intentId, result: result));
    }

    await _rememberPeer(request, exchange);
    final settings = await database.getSyncSettings();
    final page = await _changesPage(
      exchange.appliedSeq,
      _clampLimit(exchange.limit),
    );
    await _json(
      request,
      HttpStatus.ok,
      SyncResponse(
        storeId: settings.storeId,
        logEpoch: settings.logEpoch,
        changes: page.rows,
        intentResults: outcomes,
        more: page.more,
      ).toJson(),
    );
  }

  Future<void> _handleLongPoll(HttpRequest request) async {
    final deviceId = request.uri.queryParameters['device'] ?? '';
    final authorization = await _authorize(request, deviceId, '');
    if (!authorization.isAuthorized) {
      throw _HttpFailure(HttpStatus.unauthorized, _reason(authorization));
    }

    final query = request.uri.queryParameters;
    final since = int.tryParse(query['since'] ?? '') ?? 0;
    final limit = _clampLimit(
      int.tryParse(query['limit'] ?? '') ?? maxPageSize,
    );

    await _awaitChange(since);
    await _rememberPeer(request, null, deviceId: deviceId);
    final settings = await database.getSyncSettings();
    final page = await _changesPage(since, limit);
    await _json(
      request,
      HttpStatus.ok,
      SyncResponse(
        storeId: settings.storeId,
        logEpoch: settings.logEpoch,
        changes: page.rows,
        more: page.more,
      ).toJson(),
    );
  }

  /// Returns as soon as the log holds anything past [since], or after the
  /// long-poll budget.
  Future<void> _awaitChange(int since) async {
    final deadline = DateTime.now().add(longPollTimeout);
    while (await database.highestChangeSeq() <= since) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      final slice = remaining < _changePollInterval
          ? remaining
          : _changePollInterval;
      await _waitForSignal(slice);
    }
  }

  Future<void> _waitForSignal(Duration atMost) async {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    final timer = Timer(atMost, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
      _waiters.remove(waiter);
    }
  }

  Future<({List<Map<String, dynamic>> rows, bool more})> _changesPage(
    int since,
    int limit,
  ) async {
    // One extra row answers "is there another page" without a second query.
    final rows = await database.db.rawQuery(
      'SELECT * FROM changes WHERE seq > ? ORDER BY seq ASC LIMIT ?',
      [since, limit + 1],
    );
    final more = rows.length > limit;
    return (
      rows: rows
          .take(limit)
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
      more: more,
    );
  }

  Future<PeerAuthorization> _authorize(
    HttpRequest request,
    String deviceId,
    String body,
  ) async {
    final timestamp = int.tryParse(
      request.headers.value(timestampHeader) ?? '',
    );
    final signature = request.headers.value(signatureHeader) ?? '';
    if (timestamp == null || signature.isEmpty) {
      throw const _HttpFailure(
        HttpStatus.unauthorized,
        'a request must carry a timestamp and a signature',
      );
    }
    final settings = await database.getSyncSettings();
    return pairing.authorize(
      deviceId: deviceId,
      ownStoreId: settings.storeId,
      timestampEpochMs: timestamp,
      body: body,
      signature: signature,
    );
  }

  String _reason(PeerAuthorization authorization) =>
      switch (authorization.failure) {
        PeerAuthFailure.unknownPeer => 'this device is not paired',
        PeerAuthFailure.staleTimestamp => 'the request clock is too far off',
        PeerAuthFailure.badSignature => 'the signature does not match',
        null => 'unauthorized',
      };

  /// Keeps `sync_peers` current so Settings can name the paired clients and
  /// their last exchange without a separate log table.
  Future<void> _rememberPeer(
    HttpRequest request,
    SyncRequest? exchange, {
    String? deviceId,
  }) async {
    final id = deviceId ?? exchange?.deviceId ?? '';
    if (id.isEmpty) return;
    // A held change request carries no body, so it must not blank the identity
    // an earlier exchange taught the phone.
    final existing = await database.getPeer(id);
    await database.upsertPeer(
      SyncPeer(
        peerDeviceId: id,
        storeId: exchange?.storeId ?? existing?.storeId ?? '',
        host:
            request.connectionInfo?.remoteAddress.address ??
            existing?.host ??
            '',
        lastSeenEpochMs: pairing.nowUtcMs(),
      ),
    );
    // Announce a new client once; a held request that repeats on every poll
    // must not turn an open Settings page into a reload loop.
    if (existing == null) peersRevision.value++;
  }

  Future<String> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in request.timeout(readTimeout)) {
        builder.add(chunk);
        if (builder.length > maxBodyBytes) {
          throw const _HttpFailure(
            HttpStatus.requestEntityTooLarge,
            'the request body is too large',
          );
        }
      }
    } on TimeoutException {
      throw const _HttpFailure(
        HttpStatus.requestTimeout,
        'the request did not arrive in time',
      );
    }
    try {
      return utf8.decode(builder.takeBytes());
    } on FormatException {
      throw const _HttpFailure(HttpStatus.badRequest, 'the body is not UTF-8');
    }
  }

  int _clampLimit(int limit) =>
      limit <= 0 ? maxPageSize : (limit > maxPageSize ? maxPageSize : limit);

  String _deviceIdFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['deviceId'] is String) {
        return decoded['deviceId'] as String;
      }
    } catch (_) {
      // A malformed body is refused as unauthorized rather than crashing.
    }
    return '';
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

class _HttpFailure implements Exception {
  final int status;
  final String message;

  const _HttpFailure(this.status, this.message);
}
