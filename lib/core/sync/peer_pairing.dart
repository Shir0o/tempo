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

/// The pairing payload the Mac shows: `tempo://pair?s=&id=`, plus `h` and `p`
/// when the device showing it is also the one that listens.
///
/// The secret is 256 random bits, base64url without padding. The store id names
/// the device that showed the code. A Mac has no listener, so its code carries
/// neither host nor port; a code that does carry them came from a phone, and
/// the phone's scanner refuses it rather than pairing two phones by mistake.
class PairingInvite {
  static const String scheme = 'tempo';
  static const String action = 'pair';
  static const int secretBytes = 32;

  /// Empty when the device showing the code is not a listener.
  final String host;
  final int port;
  final String secret;
  final String storeId;

  const PairingInvite({
    this.host = '',
    this.port = 0,
    required this.secret,
    required this.storeId,
  });

  /// Whether the code names a device a client can dial directly.
  bool get hasEndpoint => host.isNotEmpty && port > 0;

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

  String encode() {
    final parameters = <String, String>{'s': secret, 'id': storeId};
    if (hasEndpoint) {
      parameters['h'] = host;
      parameters['p'] = '$port';
    }
    return Uri(
      scheme: scheme,
      host: action,
      queryParameters: parameters,
    ).toString();
  }

  factory PairingInvite.decode(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != scheme || uri.host != action) {
      throw const FormatException('Not a Tempo pairing code.');
    }
    final params = uri.queryParameters;
    final secret = params['s'];
    final storeId = params['id'];
    if (secret == null || storeId == null || storeId.isEmpty) {
      throw const FormatException('A pairing code is missing a field.');
    }
    if (!isValidSecret(secret)) {
      throw const FormatException('A pairing code has an invalid secret.');
    }

    final rawHost = params['h'];
    final rawPort = params['p'];
    final hasEndpoint = rawHost != null || rawPort != null;
    if (!hasEndpoint) {
      return PairingInvite(secret: secret, storeId: storeId);
    }
    final port = int.tryParse(rawPort ?? '');
    if (rawHost == null ||
        rawHost.isEmpty ||
        port == null ||
        port <= 0 ||
        port > 65535) {
      throw const FormatException('A pairing code has an invalid address.');
    }
    return PairingInvite(
      host: rawHost,
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

/// Generates and checks pairing secrets, signs requests, and remembers which
/// device is paired.
///
/// The Mac shows a code carrying a secret it generated; the phone scans it and
/// keeps the secret under `peer:<macStoreId>`. The Mac keeps the same secret
/// under `invite:<ownStoreId>` until a phone answers it, then re-keys it under
/// the phone's store id so "revoke all" can still clear everything.
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

  /// Creates the secret the Mac shows and keeps it until a phone proves it has
  /// it. The Mac has no listener, so the code names no address.
  Future<PairingInvite> createInvite({
    String host = '',
    int port = 0,
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

  /// Adopts the Mac's code on the phone: stores the Mac's secret under the
  /// store id the code names, so the Mac's first signed request is accepted.
  ///
  /// No peer row is written here: the code names no address or device id, and
  /// the phone records the Mac when its first signed request arrives. A row
  /// created now would be a second, empty entry for the same Mac.
  Future<void> pairFromInvite(PairingInvite invite) async {
    await secrets.write(peerSecretKey(invite.storeId), invite.secret);
  }

  /// The secret for a paired store, on whichever side is dialling.
  Future<String?> secretForPeerStore(String storeId) =>
      secrets.read(peerSecretKey(storeId));

  /// The secret the Mac is still waiting for a phone to adopt, if any.
  Future<String?> pendingInviteSecret() async =>
      secrets.read(inviteSecretKey(await _ownStoreId()));

  /// Saves the phone this Mac just reached as a paired peer and drops the
  /// invitation, so later exchanges dial the phone's address directly.
  Future<void> adoptPeer({
    required String storeId,
    required String host,
    required int port,
  }) async {
    if (storeId.isEmpty) return;
    final ownStoreId = await _ownStoreId();
    final secret =
        await secrets.read(inviteSecretKey(ownStoreId)) ??
        await secrets.read(peerSecretKey(storeId));
    if (secret == null) return;
    await secrets.write(peerSecretKey(storeId), secret);
    await secrets.delete(inviteSecretKey(ownStoreId));
    await database.upsertPeer(
      SyncPeer(
        peerDeviceId: storeId,
        storeId: storeId,
        host: host,
        port: port,
        lastSeenEpochMs: _nowUtcMs(),
      ),
    );
  }

  /// The secret used to authorize a request: the client's own key once it has
  /// paired, the key of the store that signed, or the invitation still in
  /// force on this side.
  Future<String?> secretForDevice(
    String deviceId, {
    required String ownStoreId,
    String? peerStoreId,
  }) async {
    final direct = await secrets.read(peerSecretKey(deviceId));
    if (direct != null) return direct;
    if (peerStoreId != null && peerStoreId.isNotEmpty) {
      final byStore = await secrets.read(peerSecretKey(peerStoreId));
      if (byStore != null) return byStore;
    }
    return secrets.read(inviteSecretKey(ownStoreId));
  }

  /// Checks one request's timestamp and HMAC, re-keying the invitation under
  /// the client's device id on its first successful use.
  Future<PeerAuthorization> authorize({
    required String deviceId,
    required String ownStoreId,
    required int timestampEpochMs,
    required String body,
    required String signature,
    String? peerStoreId,
    int? nowUtcMs,
  }) async {
    final secret = await secretForDevice(
      deviceId,
      ownStoreId: ownStoreId,
      peerStoreId: peerStoreId,
    );
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
