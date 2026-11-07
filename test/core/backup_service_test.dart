import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/backup/backup_destination.dart';
import 'package:tempo/core/backup/backup_service.dart';
import 'package:tempo/data/database/store_lifecycle.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory temp;
  late Directory localDirectory;
  late Directory destinationRoot;
  late String databasePath;
  late TempoDatabase database;
  late StoreLifecycle lifecycle;
  late DateTime clock;

  final base = DateTime.utc(2026, 11, 4, 8).millisecondsSinceEpoch;

  Future<TempoDatabase> openStore(String path) async {
    final db = await TempoDatabase.open(
      path: path,
      factory: databaseFactoryFfi,
    );
    await db.db.execute('''
CREATE TABLE IF NOT EXISTS changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    change_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    at_epoch_ms INTEGER NOT NULL,
    payload_json TEXT NOT NULL
);
''');
    return db;
  }

  Future<void> insertRecord(
    String id,
    int startedAtEpochMs,
    int endedAtEpochMs,
  ) => database.insertRecord(
    Record(
      id: id,
      activityId: null,
      startedAtEpochMs: startedAtEpochMs,
      endedAtEpochMs: endedAtEpochMs,
      timezoneId: 'UTC',
      createdAtEpochMs: startedAtEpochMs,
      updatedAtEpochMs: startedAtEpochMs,
    ),
  );

  Future<void> insertChange(String id) => database.db.insert('changes', {
    'change_id': id,
    'kind': 'record_upsert',
    'entity_id': id,
    'at_epoch_ms': base,
    'payload_json': '{}',
  });

  Future<void> insertContiguousDay() async {
    await insertRecord('r1', base, base + 3600000);
    await insertRecord('r2', base + 3600000, base + 7200000);
  }

  String Function() counterUuids() {
    var next = 0;
    return () => 'uuid-${next++}';
  }

  BackupService buildService({
    BackupDestination? destination,
    StoreLifecycle? withLifecycle,
    bool? supportsVacuumInto,
    int generations = 5,
  }) => BackupService(
    database: database,
    lifecycle: withLifecycle ?? lifecycle,
    factory: databaseFactoryFfi,
    localDirectory: localDirectory,
    storeId: 'store-1',
    destination: destination,
    defaultGenerations: generations,
    supportsVacuumInto: supportsVacuumInto,
    now: () => clock,
    uuid: counterUuids(),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tempo-backup-service');
    localDirectory = Directory(p.join(temp.path, 'local'));
    await localDirectory.create();
    destinationRoot = Directory(p.join(temp.path, 'destination'));
    await destinationRoot.create();
    databasePath = p.join(temp.path, 'tempo.db');
    database = await openStore(databasePath);
    clock = DateTime.utc(2026, 11, 5, 9);
    lifecycle = StoreLifecycle(
      databasesPath: temp.path,
      isProcessAlive: (_) => true,
      now: () => clock,
    );
  });

  tearDown(() async {
    await database.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  group('snapshot', () {
    test('captures pending writes with VACUUM INTO', () async {
      await database.db.rawQuery('PRAGMA journal_mode=WAL;');
      await insertContiguousDay();
      await insertChange('c1');
      await insertChange('c2');
      expect(
        File('$databasePath-wal').existsSync(),
        isTrue,
        reason: 'the newest commits are still in the WAL',
      );

      final snapshot = await buildService().snapshot();

      expect(snapshot.capturedSeq, 2);
      expect(snapshot.verifiedSeq, 2);
      expect(snapshot.schemaVersion, TempoDatabase.databaseVersion);
      final bytes = await snapshot.file.readAsBytes();
      expect(snapshot.bytes, bytes.length);
      expect(snapshot.sha256, sha256Hex(bytes));

      final copy = await databaseFactoryFfi.openDatabase(
        snapshot.file.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final records = await copy.rawQuery(
          'SELECT COUNT(*) AS count FROM records',
        );
        expect(records.first['count'], 2);
        final changes = await copy.rawQuery(
          'SELECT COUNT(*) AS count FROM changes',
        );
        expect(changes.first['count'], 2);
      } finally {
        await copy.close();
      }
    });

    test('checkpoint-and-copy fallback takes the store lock', () async {
      await insertContiguousDay();
      await insertChange('c1');

      final recording = _RecordingLifecycle(
        databasesPath: temp.path,
        isProcessAlive: (_) => true,
        now: () => clock,
      );
      final snapshot = await buildService(
        withLifecycle: recording,
        supportsVacuumInto: false,
      ).snapshot();

      expect(
        recording.purposes,
        contains(StoreLifecycle.snapshotFallbackPurpose),
      );
      expect(recording.isHeld, isFalse);
      expect(snapshot.verifiedSeq, 1);
      expect(snapshot.schemaVersion, TempoDatabase.databaseVersion);
    });

    test(
      'compares the snapshot to the captured seq, not the live store',
      () async {
        await insertChange('c1');
        await insertChange('c2');

        final service = buildService();
        service.beforeSnapshotCopy = () => insertChange('c3');
        final snapshot = await service.snapshot();

        final live = await database.db.rawQuery(
          'SELECT COALESCE(MAX(seq), 0) AS seq FROM changes',
        );
        expect(live.first['seq'], 3, reason: 'the concurrent write landed');
        expect(
          snapshot.capturedSeq,
          2,
          reason: 'captured in the read transaction',
        );
        expect(
          snapshot.verifiedSeq,
          3,
          reason:
              'the snapshot includes the concurrent write and still verifies',
        );
      },
    );

    test('a gap in coverage still produces a restorable snapshot', () async {
      await insertRecord('r1', base, base + 3600000);
      await insertRecord('r2', base + 7200000, base + 10800000);

      final snapshot = await buildService().snapshot();

      expect(await snapshot.file.exists(), isTrue);
      final copy = await databaseFactoryFfi.openDatabase(
        snapshot.file.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final count = await copy.rawQuery(
          'SELECT COUNT(*) AS count FROM records',
        );
        expect(count.first['count'], 2);
      } finally {
        await copy.close();
      }
    });

    test(
      'an overlap in coverage still produces a restorable snapshot',
      () async {
        await insertRecord('r1', base, base + 7200000);
        await insertRecord('r2', base + 3600000, base + 10800000);

        final snapshot = await buildService().snapshot();

        expect(await snapshot.file.exists(), isTrue);
      },
    );
  });

  group('promotion and manifest', () {
    test(
      'records generations newest first with hash, bytes and version',
      () async {
        await insertContiguousDay();
        final destination = FilesystemBackupDestination(
          rootPath: destinationRoot.path,
        );
        final service = buildService(destination: destination);

        final first = (await service.promote())!;
        clock = clock.add(const Duration(hours: 1));
        final second = (await service.promote())!;
        clock = clock.add(const Duration(hours: 1));
        final third = (await service.promote())!;

        final manifest = await service.readManifest();
        expect(
          manifest.generations.map((generation) => generation.file).toList(),
          [third.file, second.file, first.file],
        );
        for (final generation in manifest.generations) {
          expect(generation.verified, isTrue);
          expect(generation.schemaVersion, TempoDatabase.databaseVersion);
          expect(generation.bytes, greaterThan(0));
          final bytes = await File(
            p.join(destinationRoot.path, 'tempo', 'store-1', generation.file),
          ).readAsBytes();
          expect(generation.sha256, sha256Hex(bytes));
        }

        final raw = jsonDecode(
          await File(
            p.join(destinationRoot.path, 'tempo', 'store-1', 'manifest.json'),
          ).readAsString(),
        ) as Map<String, dynamic>;
        final entries = raw['generations'] as List<dynamic>;
        expect(
          (entries.first as Map<String, dynamic>).keys,
          containsAll([
            'file',
            'hash',
            'bytes',
            'schemaVersion',
            'createdAt',
            'verified',
          ]),
        );
        expect(raw['storeId'], 'store-1');
      },
    );

    test('prunes to five generations after a verified write', () async {
      await insertContiguousDay();
      final destination = FilesystemBackupDestination(
        rootPath: destinationRoot.path,
      );
      final service = buildService(destination: destination);

      final promoted = <String>[];
      for (var i = 0; i < 7; i++) {
        promoted.add((await service.promote())!.file);
        clock = clock.add(const Duration(hours: 1));
      }

      final manifest = await service.readManifest();
      expect(manifest.generations.length, 5);
      expect(
        manifest.generations.map((generation) => generation.file).toList(),
        promoted.reversed.take(5).toList(),
      );

      final files = await destination.list('tempo/store-1');
      final backups = files
          .where((file) => p.basename(file.path).startsWith('backup-'))
          .toList();
      expect(backups.length, 5);
      expect(
        backups.map((file) => p.basename(file.path)).toSet(),
        isNot(contains(promoted[0])),
      );
      expect(
        backups.map((file) => p.basename(file.path)).toSet(),
        isNot(contains(promoted[1])),
      );
    });
  });

  group('restore', () {
    test(
      'a failed validation leaves the store and the local snapshot intact',
      () async {
        await insertContiguousDay();
        final destination = FilesystemBackupDestination(
          rootPath: destinationRoot.path,
        );
        final service = buildService(destination: destination);
        final generation = (await service.promote())!;

        final rolling = File(
          p.join(localDirectory.path, 'store-1', 'snapshot.db'),
        );
        final before = sha256Hex(await rolling.readAsBytes());

        final generationPath = p.join(
          destinationRoot.path,
          'tempo',
          'store-1',
          generation.file,
        );
        await File(generationPath).writeAsString('corrupted');

        await expectLater(
          service.prepareRestore(generation),
          throwsA(isA<BackupVerificationException>()),
        );

        expect(sha256Hex(await rolling.readAsBytes()), before);
        final rows = await database.db.rawQuery(
          'SELECT COUNT(*) AS count FROM records',
        );
        expect(rows.first['count'], 2);
      },
    );

    test(
      'prepareRestore validates a generation and snapshots the current store',
      () async {
        await insertContiguousDay();
        await insertChange('c1');
        final destination = FilesystemBackupDestination(
          rootPath: destinationRoot.path,
        );
        final service = buildService(destination: destination);
        final generation = (await service.promote())!;

        final prepared = await service.prepareRestore(generation);

        expect(prepared.generation.file, generation.file);
        expect(prepared.generation.sha256, generation.sha256);
        expect(await prepared.stagedFile.exists(), isTrue);
        expect(
          sha256Hex(await prepared.stagedFile.readAsBytes()),
          generation.sha256,
        );
        expect(prepared.preRestoreSnapshot.verifiedSeq, 1);
        expect(
          await File(p.join(localDirectory.path, 'store-1', 'pre-restore.db'))
              .exists(),
          isTrue,
          reason: 'the pre-restore snapshot survives an interrupted swap',
        );
      },
    );
  });

  group('SAF destination', () {
    test(
      'promotion is marked valid only after the destination hash matches',
      () async {
        await insertContiguousDay();
        final store = _FakeSafStore();
        final destination = SafBackupDestination(
          treeUri:
              'content://com.google.android.apps.docs.tree/primary%3ATempo',
          providerAuthority: 'com.google.android.apps.docs',
          store: store,
        );
        expect(destination.isCloudSynced, isTrue);
        expect(destination.isOwnStorage, isFalse);

        final service = buildService(destination: destination);
        final generation = (await service.promote())!;

        final stored =
            store.files[p.posix.join('tempo', 'store-1', generation.file)];
        expect(stored, isNotNull);
        expect(sha256Hex(stored!), generation.sha256);
        expect(
          store.files.keys.where((path) => path.startsWith('tempo/.tmp/')),
          isEmpty,
          reason: 'the temp copy is deleted after a verified promotion',
        );

        final manifest = await service.readManifest();
        expect(manifest.generations.single.verified, isTrue);
      },
    );

    test(
      'a destination that writes different bytes leaves no generation',
      () async {
        await insertContiguousDay();
        final store = _FakeSafStore()..corruptWrites = true;
        final destination = SafBackupDestination(
          treeUri:
              'content://com.google.android.apps.docs.tree/primary%3ATempo',
          providerAuthority: 'com.google.android.apps.docs',
          store: store,
        );
        final service = buildService(destination: destination);

        await expectLater(
          service.promote(),
          throwsA(isA<BackupVerificationException>()),
        );
        expect((await service.readManifest()).generations, isEmpty);
        expect(
          store.files.keys.where(
            (path) => path.startsWith('tempo/store-1/backup-'),
          ),
          isEmpty,
        );
      },
    );

    test('the SAF picker refuses the phone\'s own storage', () async {
      final store = _FakeSafStore(
        tree: const SafTree(
          treeUri: 'content://com.android.externalstorage.documents.tree/x',
          providerAuthority: 'com.android.externalstorage.documents',
        ),
      );
      await expectLater(
        SafBackupDestination.pick(store: store),
        throwsA(isA<BackupDestinationRefusedException>()),
      );
    });
  });

  group('cloud detection', () {
    test('flags known sync roots and network volumes', () {
      expect(
        looksCloudSynced(
          '/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Tempo',
        ),
        isTrue,
      );
      expect(looksCloudSynced('/Users/me/Dropbox/Tempo'), isTrue);
      expect(looksCloudSynced('/Users/me/Backups'), isFalse);
      expect(
        looksCloudSynced('/Volumes/backup', mountSource: 'smbfs:/nas'),
        isTrue,
      );
    });
  });
}

class _RecordingLifecycle extends StoreLifecycle {
  final List<String> purposes = [];

  _RecordingLifecycle({
    required super.databasesPath,
    super.isProcessAlive,
    super.now,
  });

  @override
  Future<void> acquire({required String purpose}) {
    purposes.add(purpose);
    return super.acquire(purpose: purpose);
  }
}

class _FakeSafStore implements SafDocumentStore {
  _FakeSafStore({this.tree});

  final SafTree? tree;
  final Map<String, List<int>> files = {};
  bool corruptWrites = false;

  @override
  Future<SafTree?> pickTree() async => tree;

  @override
  Future<bool> reopen(String treeUri) async => true;

  @override
  Future<void> createDirectory(
    String treeUri,
    String relativeDirectory,
  ) async {}

  @override
  Future<void> writeFile(
    String treeUri,
    String relativePath,
    List<int> bytes,
  ) async {
    files[relativePath] = corruptWrites
        ? bytes.sublist(0, bytes.length ~/ 2)
        : List<int>.from(bytes);
  }

  @override
  Future<Uint8List> readFile(String treeUri, String relativePath) async {
    final bytes = files[relativePath];
    if (bytes == null) {
      throw BackupDestinationException('SAF file is missing: $relativePath');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<List<DestinationFile>> list(
    String treeUri,
    String relativeDirectory,
  ) async {
    final prefix = relativeDirectory.endsWith('/')
        ? relativeDirectory
        : '$relativeDirectory/';
    return files.entries
        .where(
          (entry) =>
              entry.key.startsWith(prefix) &&
              !entry.key.substring(prefix.length).contains('/'),
        )
        .map(
          (entry) => DestinationFile(
            path: entry.key,
            bytes: entry.value.length,
            modifiedAtEpochMs: 0,
          ),
        )
        .toList();
  }

  @override
  Future<void> delete(String treeUri, String relativePath) async {
    files.remove(relativePath);
  }

  @override
  Future<void> release(String treeUri) async {}
}
