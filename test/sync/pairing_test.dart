import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/sync/peer_pairing.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/sync_change.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory temp;
  var storeCounter = 0;

  Future<TempoDatabase> openStore(String name) => TempoDatabase.open(
    path: p.join(temp.path, '$name-${storeCounter++}.db'),
    factory: databaseFactoryFfi,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tempo_pairing_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  const now = 1762387200000; // 2026-11-05T20:00:00Z

  PairingInvite newInvite({String storeId = 'store-phone'}) => PairingInvite(
    host: '192.168.1.24',
    port: 8727,
    secret: PairingInvite.generateSecret(random: Random(42)),
    storeId: storeId,
  );

  group('PairingInvite', () {
    test('encodes and decodes tempo://pair', () {
      final invite = newInvite();
      final encoded = invite.encode();

      expect(encoded, startsWith('tempo://pair?'));
      expect(encoded, contains('h=192.168.1.24'));
      expect(encoded, contains('p=8727'));
      expect(encoded, contains('id=store-phone'));

      final decoded = PairingInvite.decode(encoded);
      expect(decoded, equals(invite));
    });

    test('a code from a device with no listener carries no address', () {
      final invite = PairingInvite(
        secret: PairingInvite.generateSecret(random: Random(9)),
        storeId: 'store-mac',
      );
      final encoded = invite.encode();

      expect(encoded, isNot(contains('h=')));
      expect(encoded, isNot(contains('p=')));
      expect(invite.hasEndpoint, isFalse);
      expect(PairingInvite.decode(encoded), equals(invite));
    });

    test('a secret is 256 bits and survives encoding', () {
      final secret = PairingInvite.generateSecret(random: Random(7));
      final bytes = base64Url.decode(base64Url.normalize(secret));

      expect(bytes, hasLength(PairingInvite.secretBytes));
      expect(bytes, hasLength(32));
      expect(PairingInvite.isValidSecret(secret), isTrue);
      expect(secret, isNot(contains('=')));
    });

    test('each invitation generates a new secret', () {
      final first = newInvite();
      final second = PairingInvite(
        host: first.host,
        port: first.port,
        secret: PairingInvite.generateSecret(),
        storeId: first.storeId,
      );
      expect(first.secret, isNot(second.secret));
    });

    test('rejects a foreign scheme, a bad port, and a short secret', () {
      final secret = newInvite().secret;
      expect(
        () => PairingInvite.decode('https://pair?h=x&p=1&s=$secret&id=s'),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.decode('tempo://pair?h=x&p=0&s=$secret&id=s'),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.decode('tempo://pair?h=x&p=1&s=short&id=s'),
        throwsFormatException,
      );
      expect(
        () => PairingInvite.decode('tempo://pair?h=x&p=1&s=$secret'),
        throwsFormatException,
      );
    });
  });

  group('Signatures', () {
    test('an HMAC over timestamp and body verifies with the same secret', () {
      final secret = newInvite().secret;
      const body = '{"deviceId":"mac","appliedSeq":0}';

      final signature = PeerPairing.signatureFor(
        secret: secret,
        timestampEpochMs: now,
        body: body,
      );

      expect(signature, hasLength(64));
      expect(
        PeerPairing.signatureFor(
          secret: secret,
          timestampEpochMs: now,
          body: body,
        ),
        signature,
      );
      expect(
        PeerPairing.signatureFor(
          secret: secret,
          timestampEpochMs: now + 1,
          body: body,
        ),
        isNot(signature),
      );
      expect(
        PeerPairing.signatureFor(
          secret: secret,
          timestampEpochMs: now,
          body: '$body ',
        ),
        isNot(signature),
      );
      expect(
        PeerPairing.signatureFor(
          secret: PairingInvite.generateSecret(),
          timestampEpochMs: now,
          body: body,
        ),
        isNot(signature),
      );
    });
  });

  group('Authorization', () {
    late TempoDatabase phoneDb;
    late TempoDatabase macDb;
    late InMemoryPeerSecretStore phoneSecrets;
    late PeerPairing phonePairing;
    late PeerPairing macPairing;
    late PairingInvite invite;
    late String storeId;

    setUp(() async {
      phoneDb = await openStore('phone');
      macDb = await openStore('mac');
      phoneSecrets = InMemoryPeerSecretStore();
      storeId = (await phoneDb.getSyncSettings()).storeId;
      phonePairing = PeerPairing(
        database: phoneDb,
        secrets: phoneSecrets,
        nowUtcMs: () => now,
      );
      macPairing = PeerPairing(
        database: macDb,
        secrets: InMemoryPeerSecretStore(),
        nowUtcMs: () => now,
      );
      // The Mac shows the code; the phone scans it.
      invite = await macPairing.createInvite();
      await phonePairing.pairFromInvite(invite);
    });

    tearDown(() async {
      await phoneDb.close();
      await macDb.close();
    });

    Future<PeerAuthorization> authorize({
      required String secret,
      String deviceId = 'mac-device',
      String? peerStoreId,
      int atMillis = now,
      String body = '{"deviceId":"mac-device"}',
      String? signature,
    }) => phonePairing.authorize(
      deviceId: deviceId,
      ownStoreId: storeId,
      peerStoreId: peerStoreId ?? invite.storeId,
      timestampEpochMs: atMillis,
      body: body,
      signature:
          signature ??
          PeerPairing.signatureFor(
            secret: secret,
            timestampEpochMs: atMillis,
            body: body,
          ),
    );

    test('a signed request from the paired secret is accepted', () async {
      final authorization = await authorize(secret: invite.secret);

      expect(authorization.isAuthorized, isTrue);
      expect(authorization.secret, invite.secret);
      // The first use moves the secret to the client's own device key.
      expect(
        await phoneSecrets.read(PeerPairing.peerSecretKey('mac-device')),
        invite.secret,
      );
    });

    test('a wrong secret is refused', () async {
      final authorization = await authorize(
        secret: invite.secret,
        signature: PeerPairing.signatureFor(
          secret: PairingInvite.generateSecret(),
          timestampEpochMs: now,
          body: '{"deviceId":"mac-device"}',
        ),
      );

      expect(authorization.isAuthorized, isFalse);
      expect(authorization.failure, PeerAuthFailure.badSignature);
    });

    test('a timestamp beyond five minutes of skew is refused', () async {
      final stale = await authorize(
        secret: invite.secret,
        atMillis: now - const Duration(minutes: 5, seconds: 1).inMilliseconds,
      );
      final ahead = await authorize(
        secret: invite.secret,
        atMillis: now + const Duration(minutes: 5, seconds: 1).inMilliseconds,
      );
      final edge = await authorize(
        secret: invite.secret,
        atMillis: now - const Duration(minutes: 4, seconds: 59).inMilliseconds,
      );

      expect(stale.failure, PeerAuthFailure.staleTimestamp);
      expect(ahead.failure, PeerAuthFailure.staleTimestamp);
      expect(edge.isAuthorized, isTrue);
    });

    test('a request from a device that never paired is refused', () async {
      // No code was scanned, so there is no secret to check against.
      final authorization = await authorize(
        secret: PairingInvite.generateSecret(),
        deviceId: 'stranger',
        peerStoreId: 'stranger-store',
      );

      expect(authorization.failure, PeerAuthFailure.unknownPeer);
      expect(authorization.isAuthorized, isFalse);
    });

    test('a tampered body is refused', () async {
      final signature = PeerPairing.signatureFor(
        secret: invite.secret,
        timestampEpochMs: now,
        body: '{"deviceId":"mac-device"}',
      );

      final authorization = await authorize(
        secret: invite.secret,
        body: '{"deviceId":"mac-device","appliedSeq":999}',
        signature: signature,
      );

      expect(authorization.failure, PeerAuthFailure.badSignature);
    });
  });

  group('Paired devices', () {
    late TempoDatabase phoneDb;
    late TempoDatabase macDb;
    late InMemoryPeerSecretStore phoneSecrets;
    late InMemoryPeerSecretStore macSecrets;
    late PeerPairing phonePairing;
    late PeerPairing macPairing;
    late PairingInvite invite;
    late String phoneStoreId;

    setUp(() async {
      phoneDb = await openStore('phone');
      macDb = await openStore('mac');
      phoneSecrets = InMemoryPeerSecretStore();
      macSecrets = InMemoryPeerSecretStore();
      phonePairing = PeerPairing(
        database: phoneDb,
        secrets: phoneSecrets,
        nowUtcMs: () => now,
      );
      macPairing = PeerPairing(
        database: macDb,
        secrets: macSecrets,
        nowUtcMs: () => now,
      );
      invite = await macPairing.createInvite();
      await phonePairing.pairFromInvite(invite);
      phoneStoreId = (await phoneDb.getSyncSettings()).storeId;
    });

    tearDown(() async {
      await phoneDb.close();
      await macDb.close();
    });

    test('the phone keeps the code\'s secret for the store it names', () async {
      expect(await macPairing.pendingInviteSecret(), invite.secret);
      expect(
        await phoneSecrets.read(PeerPairing.peerSecretKey(invite.storeId)),
        invite.secret,
      );
      // No peer row yet: the code names no address or device id, so the phone
      // records the Mac when its first signed request arrives.
      expect(await phoneDb.getPeers(), isEmpty);
    });

    test('the first answered exchange adopts the phone', () async {
      await macPairing.adoptPeer(
        storeId: phoneStoreId,
        host: '192.168.1.24',
        port: 8727,
      );

      expect(await macPairing.secretForPeerStore(phoneStoreId), invite.secret);
      // The invitation is spent, so the code on screen no longer pairs.
      expect(await macPairing.pendingInviteSecret(), isNull);
      // The secret is never in the database, only the peer's identity.
      final row = await macDb.getPeer(phoneStoreId);
      expect(row!.storeId, phoneStoreId);
      expect(row.host, '192.168.1.24');
      expect(row.port, 8727);
    });

    test('revoke all invalidates every stored secret and peer', () async {
      // Two Macs, so this is not just one key.
      final otherMacDb = await openStore('mac-two');
      final otherMac = PeerPairing(
        database: otherMacDb,
        secrets: InMemoryPeerSecretStore(),
        nowUtcMs: () => now,
      );
      final secondInvite = await otherMac.createInvite();
      await phonePairing.pairFromInvite(secondInvite);
      expect(
        await phoneSecrets.read(
          PeerPairing.peerSecretKey(secondInvite.storeId),
        ),
        secondInvite.secret,
      );

      await phonePairing.revokeAll();
      await macPairing.revokeAll();

      expect(await macPairing.pendingInviteSecret(), isNull);
      expect(
        await phoneSecrets.read(PeerPairing.peerSecretKey(invite.storeId)),
        isNull,
      );
      expect(
        await phoneSecrets.read(
          PeerPairing.peerSecretKey(secondInvite.storeId),
        ),
        isNull,
      );
      expect(await phoneDb.getPeers(), isEmpty);
      expect(await macDb.getPeers(), isEmpty);
      await otherMacDb.close();
    });

    test('disconnect deletes the stored secret and the peer row', () async {
      await phonePairing.forget(invite.storeId);

      expect(
        await phoneSecrets.read(PeerPairing.peerSecretKey(invite.storeId)),
        isNull,
      );
      expect(await phoneDb.getPeer(invite.storeId), isNull);

      // The Mac still holds its code until the phone answers it.
      expect(await macPairing.pendingInviteSecret(), invite.secret);
      await macPairing.forget(phoneStoreId);
      expect(await macDb.getPeers(), isEmpty);
      expect(await macPairing.pendingInviteSecret(), invite.secret);
    });

    test('a restore rotates the secret, so clients must pair again', () async {
      await phonePairing.rotateOnRestore();

      expect(
        await phoneSecrets.read(PeerPairing.peerSecretKey(invite.storeId)),
        isNull,
      );
      expect(await phoneDb.getPeers(), isEmpty);

      // A new code replaces the old one, and carries a fresh secret.
      final rotated = await macPairing.createInvite();
      expect(rotated.secret, isNot(invite.secret));
      expect(rotated.storeId, invite.storeId);
      expect(await macPairing.pendingInviteSecret(), rotated.secret);
    });
  });

  test('a paired peer can be read back as a SyncPeer row', () async {
    final db = await openStore('peer');
    await db.upsertPeer(
      const SyncPeer(
        peerDeviceId: 'phone-device',
        storeId: 'store-phone',
        host: '192.168.1.24',
        lastSeenEpochMs: now,
      ),
    );

    final peer = await db.getPeer('phone-device');
    expect(peer!.storeId, 'store-phone');
    await db.close();
  });
}
