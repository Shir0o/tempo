import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';

/// Where pairing secrets live. The database holds peer identity and address
/// only, so a snapshot never carries a credential.
abstract class PeerSecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> deleteAll();
}

/// A store for tests and for a preview build without platform storage.
class InMemoryPeerSecretStore implements PeerSecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _values.clear();
  }
}

/// The platform's secure storage: Keystore-backed preferences on Android and
/// the login Keychain on macOS, keyed by the key this side passes.
///
/// The native side implements `read`, `write`, `delete`, and `deleteAll` on
/// `MethodChannel('tempo/pairing_secrets')`.
class PlatformPeerSecretStore implements PeerSecretStore {
  static const MethodChannel channel = MethodChannel('tempo/pairing_secrets');

  const PlatformPeerSecretStore();

  @override
  Future<String?> read(String key) async =>
      await channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) async {
    await channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  @override
  Future<void> delete(String key) async {
    await channel.invokeMethod<void>('delete', {'key': key});
  }

  @override
  Future<void> deleteAll() async {
    await channel.invokeMethod<void>('deleteAll');
  }
}

/// The QR payload the phone shows: `tempo://pair?h=&p=&s=&id=`.
///
/// The secret is 256 random bits, base64url without padding. The store id lets
/// the Mac tell which phone answered, and the host and port are the fallback
/// for networks that block mDNS.
class PairingInvite {
  static const String scheme = 'tempo';
  static const String action = 'pair';
  static const int secretBytes = 32;

  final String host;
  final int port;
  final String secret;
  final String storeId;

  const PairingInvite({
    required this.host,
    required this.port,
    required this.secret,
    required this.storeId,
  });

  /// A new 256-bit secret, base64url without padding.
  static String generateSecret({Random? random}) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(secretBytes, (_) => source.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Whether [secret] is a 256-bit secret this format can carry.
  static bool isValidSecret(String secret) {
    try {
      return base64Url.decode(base64Url.normalize(secret)).length ==
          secretBytes;
    } on FormatException {
      return false;
    }
  }

  String encode() => Uri(
    scheme: scheme,
    host: action,
    queryParameters: {'h': host, 'p': '$port', 's': secret, 'id': storeId},
  ).toString();

  factory PairingInvite.decode(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != scheme || uri.host != action) {
      throw const FormatException('Not a Tempo pairing code.');
    }
    final params = uri.queryParameters;
    final host = params['h'];
    final port = int.tryParse(params['p'] ?? '');
    final secret = params['s'];
    final storeId = params['id'];
    if (host == null ||
        host.isEmpty ||
        port == null ||
        port <= 0 ||
        port > 65535 ||
        secret == null ||
        storeId == null ||
        storeId.isEmpty) {
      throw const FormatException('A pairing code is missing a field.');
    }
    if (!isValidSecret(secret)) {
      throw const FormatException('A pairing code has an invalid secret.');
    }
    return PairingInvite(
      host: host,
      port: port,
      secret: secret,
      storeId: storeId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingInvite &&
          host == other.host &&
          port == other.port &&
          secret == other.secret &&
          storeId == other.storeId;

  @override
  int get hashCode => Object.hash(host, port, secret, storeId);

  @override
  String toString() =>
      'PairingInvite(host: $host, port: $port, storeId: $storeId)';
}

/// Why a signed request was refused. The listener answers `401` and the Mac
/// shows the reason beside the client.
enum PeerAuthFailure { unknownPeer, staleTimestamp, badSignature }

/// The outcome of checking one request's signature.
class PeerAuthorization {
  final String? secret;
  final PeerAuthFailure? failure;

  const PeerAuthorization._(this.secret, this.failure);

  const PeerAuthorization.authorized(String secret) : this._(secret, null);

  const PeerAuthorization.refused(PeerAuthFailure failure)
    : this._(null, failure);

  bool get isAuthorized => secret != null;

  bool get isUnknownPeer => failure == PeerAuthFailure.unknownPeer;
}

/// Generates and checks pairing secrets, sign requests, and remembers which
/// client is paired.
///
/// Secrets are keyed by the phone's store id in `peer:<storeId>` on the Mac.
/// The phone keeps the secret it showed in `invite:<ownStoreId>` until a client
/// proves it has it, then re-keys it under `peer:<clientDeviceId>` so pairing
/// each client stays independent and "revoke all" can still clear everything.
class PeerPairing {
  /// A request further than this from the phone's clock is refused.
  static const Duration maxClockSkew = Duration(minutes: 5);

  static const String peerSecretPrefix = 'peer:';
  static const String inviteSecretPrefix = 'invite:';

  final TempoDatabase database;
  final PeerSecretStore secrets;
  final int Function() _nowUtcMs;
  final Random _random;

  PeerPairing({
    required this.database,
    required this.secrets,
    int Function()? nowUtcMs,
    Random? random,
  }) : _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  static String peerSecretKey(String storeId) => '$peerSecretPrefix$storeId';

  static String inviteSecretKey(String storeId) =>
      '$inviteSecretPrefix$storeId';

  /// Creates the secret the phone shows and keeps it until a client uses it.
  Future<PairingInvite> createInvite({
    required String host,
    required int port,
    String? storeId,
  }) async {
    final resolvedStoreId = storeId ?? await _ownStoreId();
    if (resolvedStoreId.isEmpty) {
      throw StateError('the store has no store_id yet');
    }
    final secret = PairingInvite.generateSecret(random: _random);
    await secrets.write(inviteSecretKey(resolvedStoreId), secret);
    return PairingInvite(
      host: host,
      port: port,
      secret: secret,
      storeId: resolvedStoreId,
    );
  }

  /// Adopts a scanned code on the Mac: stores the phone's secret and records
  /// the phone as a peer. The phone's device id is not in the code, so the peer
  /// row is keyed by its store id until an exchange teaches the Mac more.
  Future<void> pairFromInvite(
    PairingInvite invite, {
    String? peerDeviceId,
    String? host,
  }) async {
    await secrets.write(peerSecretKey(invite.storeId), invite.secret);
    await database.upsertPeer(
      SyncPeer(
        peerDeviceId: peerDeviceId ?? invite.storeId,
        storeId: invite.storeId,
        host: host ?? invite.host,
        lastSeenEpochMs: _nowUtcMs(),
      ),
    );
  }

  /// The secret for a phone store, on the Mac side.
  Future<String?> secretForPeerStore(String storeId) =>
      secrets.read(peerSecretKey(storeId));

  /// The secret used to authorize a request on the phone side: the client's
  /// own key once it has paired, otherwise the invitation still in force.
  Future<String?> secretForDevice(
    String deviceId, {
    required String ownStoreId,
  }) async =>
      await secrets.read(peerSecretKey(deviceId)) ??
      await secrets.read(inviteSecretKey(ownStoreId));

  /// Checks one request's timestamp and HMAC, re-keying the invitation under
  /// the client's device id on its first successful use.
  Future<PeerAuthorization> authorize({
    required String deviceId,
    required String ownStoreId,
    required int timestampEpochMs,
    required String body,
    required String signature,
    int? nowUtcMs,
  }) async {
    final secret = await secretForDevice(deviceId, ownStoreId: ownStoreId);
    if (secret == null) {
      return const PeerAuthorization.refused(PeerAuthFailure.unknownPeer);
    }
    final now = nowUtcMs ?? _nowUtcMs();
    if ((now - timestampEpochMs).abs() > maxClockSkew.inMilliseconds) {
      return const PeerAuthorization.refused(PeerAuthFailure.staleTimestamp);
    }
    final expected = signatureFor(
      secret: secret,
      timestampEpochMs: timestampEpochMs,
      body: body,
    );
    if (!_constantTimeEquals(expected, signature)) {
      return const PeerAuthorization.refused(PeerAuthFailure.badSignature);
    }
    if (await secrets.read(peerSecretKey(deviceId)) == null) {
      await secrets.write(peerSecretKey(deviceId), secret);
    }
    return PeerAuthorization.authorized(secret);
  }

  /// HMAC-SHA256 over `timestamp || body`.
  static String signatureFor({
    required String secret,
    required int timestampEpochMs,
    required String body,
  }) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    return hmac.convert(utf8.encode('$timestampEpochMs$body')).toString();
  }

  /// The instant a request is signed at, so both sides can stamp it.
  int nowUtcMs() => _nowUtcMs();

  /// Forgets one client: its secret and its row in `sync_peers`.
  Future<void> forget(String peerDeviceId, {String? peerStoreId}) async {
    await secrets.delete(peerSecretKey(peerDeviceId));
    if (peerStoreId != null) {
      await secrets.delete(peerSecretKey(peerStoreId));
    }
    await database.deletePeer(peerDeviceId);
  }

  /// Drops every secret and every paired client, which is what "revoke all
  /// paired devices" does.
  Future<void> revokeAll() async {
    await secrets.deleteAll();
    await database.db.delete('sync_peers');
  }

  /// A restore or a bootstrap adoption renews the log and the store identity,
  /// so every client must pair again.
  Future<void> rotateOnRestore() => revokeAll();

  Future<String> _ownStoreId() async =>
      await database.getSetting(SyncSettingKeys.storeId) ?? '';

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}
