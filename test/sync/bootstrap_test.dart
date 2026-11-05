import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/sync/bootstrap_service.dart';
import 'package:tempo/core/sync/store_export.dart';
import 'package:tempo/data/database/store_lifecycle.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/data/models/sync_change.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory temp;
  var lifecycleCounter = 0;
  var storeCounter = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tempo_bootstrap_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  StoreLifecycle newLifecycle() => StoreLifecycle(
    databasesPath: p.join(temp.path, 'locks', '${lifecycleCounter++}'),
  );

  /// sqflite caches `:memory:` by path, so each store needs its own file.
  Future<TempoDatabase> openStore([String? name]) => TempoDatabase.open(
    path: p.join(temp.path, name ?? 'store-${storeCounter++}.db'),
    factory: databaseFactoryFfi,
  );

  String Function() counterUuids(String prefix) {
    var next = 0;
    return () => '$prefix-${next++}';
  }

  final base = DateTime.utc(2026, 11, 4, 8).millisecondsSinceEpoch;
  final lapStart = base + 7200000;

  /// A phone-sized history: one Category, one Activity, two Tags, a Record that
  /// crosses zones, an Untracked Record, tag links, and the open Lap.
  Future<Lap> seedPhone(
    TempoDatabase db, {
    String storeId = 'phone-store',
    String deviceId = 'phone-device',
    String logEpoch = 'phone-epoch',
  }) async {
    await db.upsertCategory(
      Category(
        id: 'cat-1',
        name: 'Work',
        colorHex: '#112233',
        iconName: 'work',
        createdAtEpochMs: base,
        updatedAtEpochMs: base,
      ),
    );
    await db.insertActivity(
      Activity(
        id: 'act-1',
        name: 'Coding',
        categoryId: 'cat-1',
        createdAtEpochMs: base,
        updatedAtEpochMs: base,
      ),
    );
    await db.insertTag(
      Tag(
        id: 'tag-1',
        name: 'Contact',
        createdAtEpochMs: base,
        updatedAtEpochMs: base,
      ),
    );
    await db.insertTag(
      Tag(
        id: 'tag-2',
        name: 'Travel',
        createdAtEpochMs: base,
        updatedAtEpochMs: base,
      ),
    );
    await db.insertRecord(
      Record(
        id: 'rec-1',
        activityId: 'act-1',
        startedAtEpochMs: base,
        endedAtEpochMs: base + 3600000,
        timezoneId: 'America/Los_Angeles',
        endTimezoneId: 'Asia/Tokyo',
        createdAtEpochMs: base,
        updatedAtEpochMs: base + 1000,
        tagIds: const ['tag-1'],
      ),
    );
    await db.insertRecord(
      Record(
        id: 'rec-2',
        activityId: null,
        startedAtEpochMs: base + 3600000,
        endedAtEpochMs: lapStart,
        comment: 'w/ Sam',
        timezoneId: 'Europe/Paris',
        createdAtEpochMs: base + 3600000,
        updatedAtEpochMs: base + 3601000,
        tagIds: const ['tag-2'],
      ),
    );
    final lap = Lap(
      startedAtEpochMs: lapStart,
      startedTimezoneId: 'Europe/Paris',
      revision: 3,
    );
    await db.setLap(lap);
    await db.setSyncSettings(
      SyncSettings(storeId: storeId, deviceId: deviceId, logEpoch: logEpoch),
    );
    return lap;
  }

  /// A test-only applier: proves the backfilled change feed can rebuild the
  /// store from `seq` 1.
  Future<void> applyChanges(TempoDatabase db, List<SyncChange> changes) async {
    await db.db.transaction((txn) async {
      for (final change in changes) {
        switch (change.kind) {
          case SyncChangeKind.categoryUpsert:
            await txn.insert('categories', change.category!.toMap());
          case SyncChangeKind.activityUpsert:
            await txn.insert('activities', change.activity!.toMap());
          case SyncChangeKind.tagUpsert:
            await txn.insert('tags', change.tag!.toMap());
          case SyncChangeKind.recordUpsert:
            final record = change.record!;
            await txn.insert('records', record.toMap());
            for (final tagId in record.tagIds) {
              await txn.insert('record_tags', {
                'record_id': record.id,
                'tag_id': tagId,
              });
            }
          case SyncChangeKind.lapSet:
            await txn.insert(
              'lap',
              change.lap!.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          case SyncChangeKind.categoryRemove:
          case SyncChangeKind.activityRemove:
          case SyncChangeKind.tagRemove:
          case SyncChangeKind.recordRemove:
            fail('bootstrap never backfills a removal');
        }
      }
    });
  }

  Future<void> expectStoresMatch(
    TempoDatabase actual,
    TempoDatabase expected,
  ) async {
    expect(
      await actual.getCategories(),
      equals(await expected.getCategories()),
    );
    expect(
      await actual.getAllActivities(includeArchived: true),
      equals(await expected.getAllActivities(includeArchived: true)),
    );
    expect(await actual.getAllTags(), equals(await expected.getAllTags()));
    expect(
      await actual.getRecords(orderBy: 'started_at_epoch_ms ASC, id ASC'),
      equals(
        await expected.getRecords(orderBy: 'started_at_epoch_ms ASC, id ASC'),
      ),
    );
    expect(await actual.getLap(), equals(await expected.getLap()));
  }

  group('StoreExport', () {
    late TempoDatabase source;
    late StoreExport export;

    setUp(() async {
      source = await openStore();
      await seedPhone(source);
      export = await BootstrapService(
        database: source,
        lifecycle: newLifecycle(),
        now: () => DateTime.utc(2026, 11, 5, 12),
      ).export();
    });

    tearDown(() async {
      await source.close();
    });

    test('round trip preserves ids, both zones, tags, and the Lap', () async {
      final decoded = StoreExport.decodeBytes(export.encodeBytes());

      expect(decoded.schemaVersion, TempoDatabase.databaseVersion);
      expect(decoded.sha256, export.sha256);
      expect(decoded.sourceStoreId, 'phone-store');
      expect(decoded.records.map((record) => record.id), ['rec-1', 'rec-2']);
      expect(decoded.activities.single.id, 'act-1');
      expect(decoded.categories.single.id, 'cat-1');

      final crossing = decoded.records.first;
      expect(crossing.timezoneId, 'America/Los_Angeles');
      expect(crossing.endTimezoneId, 'Asia/Tokyo');
      expect(crossing.tagIds, ['tag-1']);
      expect(decoded.records.last.timezoneId, 'Europe/Paris');
      expect(decoded.records.last.endTimezoneId, 'Europe/Paris');
      expect(decoded.records.last.tagIds, ['tag-2']);

      expect(decoded.tags.map((tag) => tag.name), ['Contact', 'Travel']);
      expect(decoded.lap, await source.getLap());
      expect(decoded.lap!.revision, 3);
    });

    test('rejects an unknown container version', () {
      final envelope = jsonDecode(export.encode()) as Map<String, dynamic>;
      envelope['version'] = StoreExport.formatVersion + 1;
      expect(
        () => StoreExport.decode(jsonEncode(envelope)),
        throwsA(isA<StoreExportVersionException>()),
      );
    });

    test('rejects a newer schema version', () {
      final envelope = jsonDecode(export.encode()) as Map<String, dynamic>;
      envelope['schema_version'] = TempoDatabase.databaseVersion + 1;
      expect(
        () => StoreExport.decode(jsonEncode(envelope)),
        throwsA(isA<StoreExportVersionException>()),
      );
    });

    test('rejects a payload that does not match its hash', () {
      final envelope = jsonDecode(export.encode()) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      (payload['records'] as List).removeAt(0);
      expect(
        () => StoreExport.decode(jsonEncode(envelope)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BootstrapService.adopt', () {
    late TempoDatabase source;
    late StoreExport export;

    setUp(() async {
      source = await openStore();
      await seedPhone(source);
      export = await BootstrapService(
        database: source,
        lifecycle: newLifecycle(),
      ).export();
    });

    tearDown(() async {
      await source.close();
    });

    test(
      'seeds a bare replica and backfills its complete change feed',
      () async {
        final target = await openStore();
        final targetStoreId = (await target.getSyncSettings()).storeId;
        // Replica metadata a Mac would hold must not survive adoption.
        await target.setSetting('applied_seq', '42');
        await target.setSetting('replica_of_store_id', 'phone-store');
        await target.setSetting('replica_log_epoch', 'phone-epoch');

        final result = await BootstrapService(
          database: target,
          lifecycle: newLifecycle(),
          uuid: counterUuids('reissued'),
        ).adopt(export);

        expect(result.overwroteExisting, isFalse);
        expect(result.preBootstrapSnapshotPath, isNull);
        expect(result.storeId, targetStoreId);
        expect(result.deviceId, 'reissued-0');
        expect(result.logEpoch, 'reissued-1');
        expect(result.records, 2);
        expect(result.changes, 7);
        await expectStoresMatch(target, source);

        final settings = await target.getSyncSettings();
        expect(settings.storeId, targetStoreId);
        expect(settings.deviceId, 'reissued-0');
        expect(settings.logEpoch, 'reissued-1');
        expect(await target.getSetting('applied_seq'), isNull);
        expect(await target.getSetting('replica_of_store_id'), isNull);
        expect(await target.getSetting('replica_log_epoch'), isNull);

        final changes = await target.changesAfter(0);
        expect(changes, hasLength(7));
        expect(changes.map((change) => change.kind), [
          SyncChangeKind.categoryUpsert,
          SyncChangeKind.activityUpsert,
          SyncChangeKind.tagUpsert,
          SyncChangeKind.tagUpsert,
          SyncChangeKind.recordUpsert,
          SyncChangeKind.recordUpsert,
          SyncChangeKind.lapSet,
        ]);

        // The phone's feed is complete: replaying it rebuilds the same store.
        final replayed = await openStore();
        await applyChanges(replayed, changes);
        await expectStoresMatch(replayed, target);

        await target.close();
        await replayed.close();
      },
    );

    test('refuses a non-empty store without allowOverwrite', () async {
      final targetPath = p.join(temp.path, 'target.db');
      final target = await TempoDatabase.open(
        path: targetPath,
        factory: databaseFactoryFfi,
      );
      await target.insertRecord(
        Record(
          id: 'existing',
          activityId: null,
          startedAtEpochMs: base,
          endedAtEpochMs: base + 1000,
          timezoneId: 'UTC',
          createdAtEpochMs: base,
          updatedAtEpochMs: base,
        ),
      );
      await target.setLap(Lap(startedAtEpochMs: base + 1000));

      final service = BootstrapService(
        database: target,
        lifecycle: newLifecycle(),
        uuid: counterUuids('refused'),
      );
      await expectLater(
        service.adopt(export),
        throwsA(isA<BootstrapOverwriteRefusedException>()),
      );

      // Nothing was written or removed.
      expect(await target.getRecords(), hasLength(1));
      expect((await target.getRecords()).single.id, 'existing');
      expect((await target.getLap())!.startedAtEpochMs, base + 1000);
      expect(await target.changesAfter(0), isEmpty);
      expect(await target.getSetting('device_id'), isNot('refused-0'));

      await target.close();
    });

    test('snapshots then replaces a non-empty store when confirmed', () async {
      final targetPath = p.join(temp.path, 'target.db');
      final target = await TempoDatabase.open(
        path: targetPath,
        factory: databaseFactoryFfi,
      );
      await target.insertRecord(
        Record(
          id: 'existing',
          activityId: null,
          startedAtEpochMs: base,
          endedAtEpochMs: base + 1000,
          timezoneId: 'UTC',
          createdAtEpochMs: base,
          updatedAtEpochMs: base,
        ),
      );
      await target.setLap(Lap(startedAtEpochMs: base + 1000));

      final result = await BootstrapService(
        database: target,
        lifecycle: newLifecycle(),
        uuid: counterUuids('overwrite'),
      ).adopt(export, allowOverwrite: true);

      expect(result.overwroteExisting, isTrue);
      expect(result.preBootstrapSnapshotPath, isNotNull);
      final snapshot = File(result.preBootstrapSnapshotPath!);
      expect(await snapshot.exists(), isTrue);
      expect(await snapshot.length(), greaterThan(0));

      expect(await target.getRecordById('existing'), isNull);
      await expectStoresMatch(target, source);
      expect(await target.changesAfter(0), hasLength(7));

      await target.close();
    });

    test('seeds a replacement phone from the Mac replica export', () async {
      // The Mac adopted the phone's history and now holds a replica.
      final mac = await openStore();
      await BootstrapService(
        database: mac,
        lifecycle: newLifecycle(),
        uuid: counterUuids('mac'),
      ).adopt(export);

      final exportPath = p.join(
        temp.path,
        'replica.${StoreExport.fileExtension}',
      );
      await BootstrapService(
        database: mac,
        lifecycle: newLifecycle(),
      ).exportToFile(exportPath);
      expect(await File(exportPath).exists(), isTrue);

      final replacement = await openStore();
      final replacementStoreId = (await replacement.getSyncSettings()).storeId;
      final result = await BootstrapService(
        database: replacement,
        lifecycle: newLifecycle(),
        uuid: counterUuids('replacement'),
      ).adoptFromFile(exportPath);

      expect(result.storeId, replacementStoreId);
      expect(result.records, 2);
      expect(result.deviceId, 'replacement-0');
      expect(result.logEpoch, 'replacement-1');
      // Same ids, spans, zones, tags, and Lap as the phone the Mac replicated.
      await expectStoresMatch(replacement, source);
      expect(
        (await replacement.getRecordById('rec-1'))!.endTimezoneId,
        'Asia/Tokyo',
      );
      expect((await replacement.getRecordById('rec-1'))!.tagIds, ['tag-1']);

      await mac.close();
      await replacement.close();
    });

    test('rejects an export with a coverage gap', () async {
      final target = await openStore();
      final gapped = StoreExport.create(
        createdAtEpochMs: base,
        records: [
          Record(
            id: 'gap-1',
            activityId: null,
            startedAtEpochMs: base,
            endedAtEpochMs: base + 1000,
            timezoneId: 'UTC',
            createdAtEpochMs: base,
            updatedAtEpochMs: base,
          ),
          Record(
            id: 'gap-2',
            activityId: null,
            startedAtEpochMs: base + 2000,
            endedAtEpochMs: base + 3000,
            timezoneId: 'UTC',
            createdAtEpochMs: base + 2000,
            updatedAtEpochMs: base + 2000,
          ),
        ],
        lap: Lap(startedAtEpochMs: base + 3000),
      );

      await expectLater(
        BootstrapService(
          database: target,
          lifecycle: newLifecycle(),
        ).adopt(gapped),
        throwsA(
          isA<BootstrapException>().having(
            (error) => error.message,
            'message',
            contains('Coverage gap'),
          ),
        ),
      );
      expect(await target.getRecords(), isEmpty);
      expect(await target.changesAfter(0), isEmpty);

      await target.close();
    });
  });
}
