import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tempo/data/database/store_lifecycle.dart';

void main() {
  late Directory temp;
  late String lockPath;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tempo-store-lifecycle');
    lockPath = p.join(temp.path, StoreLifecycle.lockFileName);
    now = DateTime.utc(2026, 11, 5, 12);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  StoreLifecycle build({
    bool Function(int pid)? alive,
    DateTime Function()? clock,
  }) => StoreLifecycle(
    databasesPath: temp.path,
    staleAfter: const Duration(seconds: 60),
    isProcessAlive: alive,
    now: clock ?? () => now,
  );

  Future<void> writeLock({
    required int lockPid,
    required String purpose,
    required DateTime acquiredAt,
  }) => File(lockPath).writeAsString(
    jsonEncode({
      'pid': lockPid,
      'purpose': purpose,
      'acquired_at': acquiredAt.millisecondsSinceEpoch,
    }),
  );

  group('exclusive access', () {
    test(
      'a restore holds the store exclusively and refuses a second caller',
      () async {
        final restore = build(alive: (_) => true);
        await restore.acquire(purpose: StoreLifecycle.restorePurpose);

        expect(restore.isHeld, isTrue);
        await expectLater(
          restore.assertUnlocked(),
          throwsA(isA<StoreBusyException>()),
        );

        final second = build(alive: (_) => true);
        await expectLater(
          second.acquire(purpose: StoreLifecycle.sessionPurpose),
          throwsA(
            isA<StoreBusyException>().having(
              (e) => e.holder?.purpose,
              'holder purpose',
              StoreLifecycle.restorePurpose,
            ),
          ),
        );
      },
    );

    test('releasing lets the next holder in', () async {
      final first = build(alive: (_) => true);
      await first.acquire(purpose: StoreLifecycle.restorePurpose);
      await first.release();
      expect(first.isHeld, isFalse);

      final second = build(alive: (_) => true);
      await second.acquire(purpose: StoreLifecycle.sessionPurpose);
      await second.release();
    });

    test('the MCP session fails closed while a restore holds the lock', () async {
      final restore = build(alive: (_) => true);
      await restore.acquire(purpose: StoreLifecycle.restorePurpose);

      // The CLI runs in another process, so it reads the lock file rather than
      // any in-memory state.
      final cli = build(alive: (_) => true);
      try {
        await cli.acquire(purpose: StoreLifecycle.sessionPurpose);
        fail('the MCP session must not open the store during a restore');
      } on StoreBusyException catch (e) {
        expect(e.toString(), 'store busy: restore in progress');
      }
    });

    test('a completed restore leaves the store open again', () async {
      final restore = build(alive: (_) => true);
      await restore.acquire(purpose: StoreLifecycle.restorePurpose);
      await restore.release();

      final cli = build(alive: (_) => true);
      await cli.acquire(purpose: StoreLifecycle.sessionPurpose);
      expect(File(lockPath).existsSync(), isTrue);
      await cli.release();
      expect(File(lockPath).existsSync(), isFalse);
    });
  });

  group('store swap', () {
    test('closes the live store before the file is replaced', () async {
      final target = File(p.join(temp.path, 'tempo.db'));
      await target.writeAsString('old store');
      await File('${target.path}-wal').writeAsString('wal');
      final snapshot = File(p.join(temp.path, 'snapshot.db'));
      await snapshot.writeAsString('new store');

      final lifecycle = build(alive: (_) => true);
      await lifecycle.acquire(purpose: StoreLifecycle.restorePurpose);

      var closed = false;
      await lifecycle.replaceStoreAtomically(
        source: snapshot,
        target: target,
        closeStore: () async {
          closed = true;
          // The old store is still whole at this point.
          expect(await target.readAsString(), 'old store');
          expect(File('${target.path}-wal').existsSync(), isTrue);
        },
      );

      expect(closed, isTrue);
      expect(await target.readAsString(), 'new store');
      expect(File('${target.path}-wal').existsSync(), isFalse);
      expect(File('${target.path}-shm').existsSync(), isFalse);
      expect(
        File('${target.path}.restore').existsSync(),
        isFalse,
        reason: 'the temp copy is renamed away',
      );
    });

    test('refuses a swap without the restore lock', () async {
      final target = File(p.join(temp.path, 'tempo.db'));
      await target.writeAsString('old store');
      final snapshot = File(p.join(temp.path, 'snapshot.db'));
      await snapshot.writeAsString('new store');

      final lifecycle = build(alive: (_) => true);
      await expectLater(
        lifecycle.replaceStoreAtomically(
          source: snapshot,
          target: target,
          closeStore: () async {},
        ),
        throwsStateError,
      );
      expect(await target.readAsString(), 'old store');
    });
  });

  group('stale locks', () {
    test('a lock older than 60 s with a dead pid is broken', () async {
      await writeLock(
        lockPid: 424242,
        purpose: StoreLifecycle.restorePurpose,
        acquiredAt: now.subtract(const Duration(seconds: 61)),
      );

      final lifecycle = build(alive: (_) => false);
      await lifecycle.acquire(purpose: StoreLifecycle.sessionPurpose);

      final written = StoreLockInfo.tryParse(
        await File(lockPath).readAsString(),
      );
      expect(written?.pid, pid);
      expect(written?.purpose, StoreLifecycle.sessionPurpose);
      await lifecycle.release();
    });

    test('a recent lock with a dead pid still blocks', () async {
      await writeLock(
        lockPid: 424242,
        purpose: StoreLifecycle.restorePurpose,
        acquiredAt: now.subtract(const Duration(seconds: 30)),
      );

      final lifecycle = build(alive: (_) => false);
      await expectLater(
        lifecycle.acquire(purpose: StoreLifecycle.sessionPurpose),
        throwsA(isA<StoreBusyException>()),
      );
    });

    test('an old lock held by a live pid still blocks', () async {
      await writeLock(
        lockPid: 424242,
        purpose: StoreLifecycle.restorePurpose,
        acquiredAt: now.subtract(const Duration(minutes: 10)),
      );

      final lifecycle = build(alive: (_) => true);
      await expectLater(
        lifecycle.acquire(purpose: StoreLifecycle.sessionPurpose),
        throwsA(isA<StoreBusyException>()),
      );
    });

    test('an unreadable lock fails closed until it ages out', () async {
      await File(lockPath).writeAsString('{ not json');

      final lifecycle = build(alive: (_) => false);
      await expectLater(
        lifecycle.acquire(purpose: StoreLifecycle.sessionPurpose),
        throwsA(isA<StoreBusyException>()),
      );
    });

    test('assertUnlocked does not block on a stale lock', () async {
      await writeLock(
        lockPid: 424242,
        purpose: StoreLifecycle.restorePurpose,
        acquiredAt: now.subtract(const Duration(minutes: 5)),
      );

      final lifecycle = build(alive: (_) => false);
      await lifecycle.assertUnlocked();
    });
  });
}
