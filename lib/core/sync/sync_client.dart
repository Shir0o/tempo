import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';
import 'discovery.dart';
import 'intent_queue.dart';
import 'peer_pairing.dart';
import 'replica_applier.dart';
import 'sync_listener.dart';

/// What the Mac is doing right now, for Settings and the menu bar.
enum SyncClientStatus { idle, syncing, waitingForPhone, upToDate, failed }

/// A pull that could not run, with a message the Mac can show as-is.
class SyncClientException implements Exception {
  final String message;

  const SyncClientException(this.message);

  @override
  String toString() => message;
}

/// The phone did not answer in time: the Mac is paired but the phone is not on
/// the network or Tempo is not open there.
class SyncWaitingException extends SyncClientException {
  const SyncWaitingException() : super('waiting for the phone');
}

/// What one exchange wrote.
class SyncPullResult {
  final int changesApplied;
  final List<IntentOutcome> intentResults;

  /// True when the replica was cleared and replayed because the phone's store
  /// id or log epoch changed.
  final bool replayed;

  /// The cursor after the exchange.
  final int appliedSeq;

  const SyncPullResult({
    required this.changesApplied,
    required this.appliedSeq,
    this.intentResults = const [],
    this.replayed = false,
  });
}

/// The client counters Settings shows. `applied`, `rejected`, and `pending`
/// come from the intents table; there is no separate log.
class SyncClientStats {
  final SyncClientStatus status;
  final int appliedSeq;
  final int lastSuccessEpochMs;
  final int changesApplied;
  final int intentsApplied;
  final int intentsRejected;
  final int intentsPending;

  const SyncClientStats({
    required this.status,
    required this.appliedSeq,
    required this.lastSuccessEpochMs,
    required this.changesApplied,
    required this.intentsApplied,
    required this.intentsRejected,
    required this.intentsPending,
  });
}

/// The Mac's side of replication.
///
/// Pulls the phone's changes in pages of [pageSize], applies them with
/// [ReplicaApplier], resends every unanswered intent, and clears the replica
/// when the phone's store id or log epoch changes. While running it keeps a
/// long-poll open so a label on the phone lands without a poll interval, and
/// falls back to a [pollInterval] when long-polling does not answer.
class SyncClient {
  final TempoDatabase database;
  final PeerPairing pairing;
  final ReplicaApplier applier;
  final IntentQueue queue;
  final PeerDiscovery discovery;

  /// Pages are this large; the phone never sends more than 500.
  final int pageSize;

  final Duration longPollTimeout;
  final Duration pollInterval;
  final Duration discoveryTimeout;
  final Duration requestTimeout;

  final http.Client _http;
  final bool _ownsHttpClient;
  final int Function() _nowUtcMs;

  final ValueNotifier<SyncClientStatus> status = ValueNotifier(
    SyncClientStatus.idle,
  );

  String? lastError;
  int _lastSuccessEpochMs = 0;
  int _changesApplied = 0;
  bool _running = false;
  bool _longPollWorks = true;
  DiscoveredPeer? _manualPeer;
  Future<void>? _lock;

  SyncClient({
    required this.database,
    required this.pairing,
    required this.applier,
    required this.queue,
    required this.discovery,
    this.pageSize = 500,
    this.longPollTimeout = SyncListener.defaultLongPollTimeout,
    this.pollInterval = const Duration(seconds: 30),
    this.discoveryTimeout = defaultDiscoveryTimeout,
    this.requestTimeout = const Duration(seconds: 20),
    http.Client? httpClient,
    int Function()? nowUtcMs,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// The wait before retry number [attempt], 1 s doubling to 60 s.
  static Duration backoffForAttempt(int attempt) {
    if (attempt <= 0) return const Duration(seconds: 1);
    final exponent = (attempt - 1).clamp(0, 6).toInt();
    final seconds = 1 << exponent;
    return Duration(seconds: seconds > 60 ? 60 : seconds);
  }

  /// One full exchange: send pending intents, apply every page, repeat while
  /// the phone has more.
  Future<SyncPullResult> pull() => _serialized(() async {
    _begin();
    try {
      final session = await _dial();
      final result = await _pullPages(session);
      _changesApplied += result.changesApplied;
      _succeeded();
      return result;
    } catch (error) {
      _failed(error);
      rethrow;
    }
  });

  /// Holds one long-poll, applies what arrives, and returns it. When the phone
  /// changed its identity the whole replica is replayed instead.
  Future<SyncPullResult> awaitChanges() => _serialized(() async {
    _begin();
    try {
      final session = await _dial();
      final deviceId = await _deviceId();
      final since = await applier.appliedSeq();
      final timestamp = _nowUtcMs();
      final signature = PeerPairing.signatureFor(
        secret: session.secret,
        timestampEpochMs: timestamp,
        body: '',
      );
      final uri = Uri(
        scheme: 'http',
        host: session.peer.host,
        port: session.peer.port,
        path: '/changes',
        queryParameters: {'since': '$since', 'limit': '$pageSize'},
      );
      final response = await _http
          .get(
            uri,
            headers: {
              SyncListener.deviceHeader: deviceId,
              SyncListener.timestampHeader: '$timestamp',
              SyncListener.signatureHeader: signature,
            },
          )
          .timeout(longPollTimeout + requestTimeout);
      if (response.statusCode != 200) {
        throw SyncClientException(
          'the phone refused the change request (${response.statusCode}).',
        );
      }
      final exchange = _decodeResponse(response.body);
      await _adopt(session, exchange.storeId);
      final accepted = await _accept(session, exchange, allowReset: true);
      if (accepted.replayed) {
        final result = await _pullPages(session);
        _changesApplied += result.changesApplied;
        _succeeded();
        return result;
      }
      _changesApplied += accepted.applied;
      _succeeded();
      return SyncPullResult(
        changesApplied: accepted.applied,
        appliedSeq: await applier.appliedSeq(),
        intentResults: accepted.outcomes,
      );
    } catch (error) {
      _failed(error);
      rethrow;
    }
  });

  /// Starts the replication loop. Opening the app, resuming it, and queueing an
  /// intent all funnel here; the loop is idempotent.
  void start() {
    unawaited(applyReplicationSetting());
  }

  /// Reads the one flag that gates replication. The replica's store is open
  /// either way, so the Day still renders while replication is off.
  Future<bool> replicationEnabled() async =>
      (await database.getSyncSettings()).replicateEnabled;

  /// Starts or stops the loop to match `replicate_enabled`. Idempotent, so a
  /// pairing or a Settings change can call it again; returns whether the loop
  /// is running.
  Future<bool> applyReplicationSetting() async {
    if (!await replicationEnabled()) {
      _running = false;
      if (status.value != SyncClientStatus.idle) {
        status.value = SyncClientStatus.idle;
      }
      return false;
    }
    if (!_running) {
      _running = true;
      _longPollWorks = true;
      unawaited(_loop());
    }
    return true;
  }

  Future<void> stop() async {
    _running = false;
  }

  /// Exchanges now, without waiting for the loop's backoff: a label made on the
  /// Mac is queued and its result comes back on the same pull.
  void notifyIntentQueued() => retryNow();

  /// Tries an exchange at once, whether or not the loop is between attempts.
  ///
  /// Settings rings this while a pairing code is on screen, so the exchange
  /// that adopts the phone happens as soon as it scans, not at the next
  /// backoff step.
  void retryNow() {
    if (!_running) {
      start();
      return;
    }
    unawaited(pull().then<void>((_) {}, onError: (Object _) {}));
  }

  /// Turns replication on and starts the loop. Showing a pairing code does
  /// this, so the Mac is already looking for the phone when it scans.
  Future<void> enableReplication() async {
    await database.setSetting(SyncSettingKeys.replicateEnabled, 'true');
    await applyReplicationSetting();
  }

  /// Dials [host] and [port] instead of waiting for mDNS, using the secret in
  /// the pairing code on screen. The row is written only once an exchange
  /// succeeds, so a mistyped address does not pair anything.
  void setManualPeer({required String host, required int port}) {
    _manualPeer = DiscoveredPeer(host: host, port: port, storeId: '');
  }

  /// The store ids of the phones this Mac has adopted. Settings compares the
  /// set before and after showing a code, so a phone paired earlier is not
  /// mistaken for the one that just scanned.
  Future<Set<String>> pairedPeerStores() async => {
    for (final peer in await database.getPeers()) peer.storeId,
  };

  Future<SyncClientStats> stats() async {
    // Settings reloads this after a pairing or a Settings change, which is the
    // moment `replicate_enabled` can flip; re-evaluate before reporting.
    await applyReplicationSetting();
    await queue.ensureTable();
    final rows = await database.db.rawQuery(
      'SELECT status, COUNT(*) AS total FROM ${IntentQueue.table} '
      'GROUP BY status',
    );
    int countOf(String status) {
      for (final row in rows) {
        if (row['status'] == status) return row['total'] as int? ?? 0;
      }
      return 0;
    }

    return SyncClientStats(
      status: status.value,
      appliedSeq: await applier.appliedSeq(),
      lastSuccessEpochMs: _lastSuccessEpochMs,
      changesApplied: _changesApplied,
      intentsApplied: countOf(IntentQueue.appliedStatus),
      intentsRejected: countOf(IntentQueue.rejectedStatus),
      intentsPending: countOf(IntentQueue.pendingStatus),
    );
  }

  void dispose() {
    _running = false;
    status.dispose();
    if (_ownsHttpClient) _http.close();
  }

  Future<void> _loop() async {
    var failures = 0;
    while (_running) {
      // A Settings change takes effect on the next exchange, not at restart.
      if (!await replicationEnabled()) {
        _running = false;
        status.value = SyncClientStatus.idle;
        return;
      }
      try {
        await pull();
        failures = 0;
      } catch (error) {
        if (!_running) return;
        failures++;
        // A phone that is closed, asleep, or off the network is not a
        // permanent failure. Keep retrying at the capped backoff instead of
        // stopping, so the Mac reconnects when the phone comes back rather
        // than staying "paired" and silent until the app is restarted.
        await Future<void>.delayed(backoffForAttempt(failures));
        continue;
      }
      if (!_running) return;

      if (_longPollWorks) {
        try {
          await awaitChanges();
          continue;
        } catch (_) {
          // A phone or proxy that does not hold a request still answers a
          // poll; the 30-second fallback takes over for this run.
          _longPollWorks = false;
        }
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<SyncPullResult> _pullPages(_PeerSession session) async {
    var applied = 0;
    var replayed = false;
    var didReset = false;
    final outcomes = <IntentOutcome>[];
    var more = true;

    while (more) {
      final response = await _post(session, await _buildRequest(session));
      final accepted = await _accept(session, response, allowReset: !didReset);
      applied += accepted.applied;
      outcomes.addAll(accepted.outcomes);
      if (accepted.replayed) {
        replayed = true;
        didReset = true;
        continue;
      }
      more = response.more && accepted.applied > 0;
    }

    return SyncPullResult(
      changesApplied: applied,
      appliedSeq: await applier.appliedSeq(),
      intentResults: outcomes,
      replayed: replayed,
    );
  }

  Future<SyncRequest> _buildRequest(_PeerSession session) async {
    final settings = await database.getSyncSettings();
    return SyncRequest(
      deviceId: settings.deviceId,
      storeId: settings.storeId,
      logEpoch:
          await database.getSetting(ReplicaApplier.replicaLogEpochKey) ?? '',
      appliedSeq: await applier.appliedSeq(),
      limit: pageSize,
      intents: [
        for (final queued in await queue.pendingIntents()) queued.intent,
      ],
    );
  }

  Future<({int applied, List<IntentOutcome> outcomes, bool replayed})> _accept(
    _PeerSession session,
    SyncResponse response, {
    required bool allowReset,
  }) async {
    if (allowReset &&
        (await _uninitialisedReplicaHasRows() ||
            await _identityChanged(response))) {
      // The phone restored, adopted a Mac's export, or was replaced. Nothing
      // in the replica can be trusted against the new log. A replica that
      // holds rows but never had a cursor is a store from before replication
      // and is cleared the same way.
      await applier.reset();
      await _rememberReplica(response);
      return (applied: 0, outcomes: const <IntentOutcome>[], replayed: true);
    }
    await _rememberReplica(response);
    await applier.apply(response.changes);
    final results = <String, IntentResult>{
      for (final outcome in response.intentResults)
        outcome.intentId: outcome.result,
    };
    await queue.applyResults(results);
    return (
      applied: response.changes.length,
      outcomes: response.intentResults,
      replayed: false,
    );
  }

  /// True when the replica holds rows but has never had a cursor written.
  ///
  /// That is what a store from before replication looks like: its rows are not
  /// the phone's, so they must be cleared before the first page is applied.
  Future<bool> _uninitialisedReplicaHasRows() async {
    final cursor = await database.getSetting(ReplicaApplier.appliedSeqKey);
    if (cursor != null) return false;
    final rows = await database.db.rawQuery(
      'SELECT (SELECT COUNT(*) FROM records) + '
      '(SELECT COUNT(*) FROM activities) + '
      '(SELECT COUNT(*) FROM categories) + '
      '(SELECT COUNT(*) FROM tags) + '
      '(SELECT COUNT(*) FROM lap) AS total',
    );
    return ((rows.first['total'] as int?) ?? 0) > 0;
  }

  Future<bool> _identityChanged(SyncResponse response) async {
    final storedStoreId = await database.getSetting(
      ReplicaApplier.replicaOfStoreIdKey,
    );
    final storedEpoch = await database.getSetting(
      ReplicaApplier.replicaLogEpochKey,
    );
    final storeChanged =
        storedStoreId != null &&
        storedStoreId.isNotEmpty &&
        storedStoreId != response.storeId;
    final epochChanged =
        storedEpoch != null &&
        storedEpoch.isNotEmpty &&
        storedEpoch != response.logEpoch;
    return storeChanged || epochChanged;
  }

  Future<void> _rememberReplica(SyncResponse response) async {
    await database.setSetting(
      ReplicaApplier.replicaOfStoreIdKey,
      response.storeId,
    );
    await database.setSetting(
      ReplicaApplier.replicaLogEpochKey,
      response.logEpoch,
    );
  }

  Future<SyncResponse> _post(_PeerSession session, SyncRequest request) async {
    final body = jsonEncode(request.toJson());
    final timestamp = _nowUtcMs();
    final signature = PeerPairing.signatureFor(
      secret: session.secret,
      timestampEpochMs: timestamp,
      body: body,
    );
    final uri = Uri(
      scheme: 'http',
      host: session.peer.host,
      port: session.peer.port,
      path: '/sync',
    );
    final response = await _http
        .post(
          uri,
          headers: {
            'content-type': 'application/json',
            SyncListener.deviceHeader: request.deviceId,
            SyncListener.timestampHeader: '$timestamp',
            SyncListener.signatureHeader: signature,
          },
          body: body,
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw SyncClientException(
        'the phone refused the exchange (${response.statusCode}).',
      );
    }
    final exchange = _decodeResponse(response.body);
    await _adopt(session, exchange.storeId);
    return exchange;
  }

  /// Saves the phone that just answered, the first time an invitation pairs a
  /// session. After this the address comes from `sync_peers`, not discovery.
  Future<void> _adopt(_PeerSession session, String storeId) async {
    if (!session.pending) return;
    final peer = session.peer;
    await pairing.adoptPeer(storeId: storeId, host: peer.host, port: peer.port);
    session.pending = false;
    // A typed address has done its job; a later pairing starts from discovery.
    if (identical(peer, _manualPeer)) _manualPeer = null;
  }

  SyncResponse _decodeResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('not a JSON object');
      return SyncResponse.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException catch (e) {
      throw SyncClientException('the phone sent an unreadable answer: $e');
    }
  }

  Future<_PeerSession> _dial() async {
    final paired = await _pairedSession();
    if (paired != null) return paired;

    // The Mac shows the pairing code; the phone scans it. The code names no
    // address, so the Mac finds the phone over mDNS, or at an address typed
    // while the code was on screen, and signs with the invitation secret.
    final manual = _manualPeer;
    if (manual != null) {
      final secret = await pairing.pendingInviteSecret();
      if (secret == null) {
        throw const SyncClientException('this Mac has no pairing code to use.');
      }
      return _PeerSession(peer: manual, secret: secret, pending: true);
    }

    try {
      await discovery.start();
    } on DiscoveryUnavailableException catch (e) {
      throw SyncClientException(e.message);
    }
    final peer = await discovery.find(timeout: discoveryTimeout);
    if (peer == null) {
      throw const SyncWaitingException();
    }
    final stored = await pairing.secretForPeerStore(peer.storeId);
    final secret = stored ?? await pairing.pendingInviteSecret();
    if (secret == null) {
      throw SyncClientException(
        'this Mac is not paired with the phone at ${peer.host}.',
      );
    }
    return _PeerSession(peer: peer, secret: secret, pending: stored == null);
  }

  /// The phone this Mac paired with, as its row in `sync_peers` remembers it.
  ///
  /// The row carries the address discovery found, so a network that blocks
  /// mDNS connects directly once the first exchange has happened.
  Future<_PeerSession?> _pairedSession() async {
    for (final peer in await database.getPeers()) {
      if (peer.host.isEmpty || peer.storeId.isEmpty) continue;
      final secret = await pairing.secretForPeerStore(peer.storeId);
      if (secret == null) continue;
      return _PeerSession(
        peer: DiscoveredPeer(
          host: peer.host,
          port: peer.port,
          storeId: peer.storeId,
        ),
        secret: secret,
      );
    }
    return null;
  }

  Future<String> _deviceId() async =>
      (await database.getSyncSettings()).deviceId;

  void _begin() {
    lastError = null;
    status.value = SyncClientStatus.syncing;
  }

  void _succeeded() {
    lastError = null;
    _lastSuccessEpochMs = _nowUtcMs();
    status.value = SyncClientStatus.upToDate;
  }

  void _failed(Object error) {
    lastError = error.toString();
    status.value = error is SyncWaitingException
        ? SyncClientStatus.waitingForPhone
        : SyncClientStatus.failed;
  }

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      completer.complete();
      if (_lock == completer.future) _lock = null;
    }
  }
}

class _PeerSession {
  final DiscoveredPeer peer;
  final String secret;

  /// True when the secret is the Mac's invitation, not a paired store's: the
  /// first successful answer adopts the phone and clears this.
  bool pending;

  _PeerSession({
    required this.peer,
    required this.secret,
    this.pending = false,
  });
}
