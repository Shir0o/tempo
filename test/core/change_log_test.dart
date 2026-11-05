import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/data/models/sync_change.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Change log', () {
    late TempoDatabase db;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
    });

    tearDown(() async {
      await db.close();
    });

    test('appends changes and reads them after a seq with a limit', () async {
      final tag = Tag(
        id: 'tag-1',
        name: 'Travel',
        createdAtEpochMs: 10,
        updatedAtEpochMs: 20,
      );
      final record = Record(
        id: 'rec-1',
        activityId: null,
        startedAtEpochMs: 100,
        endedAtEpochMs: 200,
        comment: 'w/ Sam',
        timezoneId: 'America/Los_Angeles',
        endTimezoneId: 'Asia/Tokyo',
        createdAtEpochMs: 100,
        updatedAtEpochMs: 300,
        tagIds: [tag.id],
      );

      final seqs = [
        await db.appendChange(
          SyncChange.tagUpsert(tag, atEpochMs: tag.updatedAtEpochMs),
        ),
        await db.appendChange(
          SyncChange.recordUpsert(record, atEpochMs: record.updatedAtEpochMs),
        ),
        await db.appendChange(
          SyncChange.recordRemove(record.id, atEpochMs: 400),
        ),
      ];

      expect(seqs, [1, 2, 3]);

      final firstTwo = await db.changesAfter(0, 2);
      expect(firstTwo.map((c) => c.seq), [1, 2]);
      expect(firstTwo.first.kind, SyncChangeKind.tagUpsert);
      expect(firstTwo.last.kind, SyncChangeKind.recordUpsert);
      expect(firstTwo.last.record, equals(record));

      final afterSecond = await db.changesAfter(2);
      expect(afterSecond.map((c) => c.kind), [SyncChangeKind.recordRemove]);
      expect(afterSecond.single.entityId, record.id);

      expect(await db.changesAfter(3), isEmpty);
    });

    test('reports the highest seq, or 0 for an empty log', () async {
      expect(await db.highestChangeSeq(), 0);

      await db.appendChange(SyncChange.recordRemove('rec-1', atEpochMs: 10));
      await db.appendChange(SyncChange.recordRemove('rec-2', atEpochMs: 20));

      expect(await db.highestChangeSeq(), 2);
    });

    test('rejects an unknown change kind and an unknown payload version', () {
      expect(
        () => SyncChange.fromRow({
          'change_id': 'change-1',
          'kind': 'future_kind',
          'entity_id': 'entity-1',
          'at_epoch_ms': 1,
          'payload_json': SyncChange.encodePayload(const {}),
        }),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => SyncChange.decodePayload('{"version": 999, "payload": {}}'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Schema v10 seeding', () {
    test('a fresh install has the replication tables and settings', () async {
      final db = await TempoDatabase.openInMemory();
      addTearDown(db.close);

      final tables = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
      );
      expect(
        tables.map((t) => t['name']),
        containsAll([
          'changes',
          'processed_intents',
          'watch_watermarks',
          'sync_peers',
        ]),
      );

      final settings = await db.getSyncSettings();
      expect(settings.storeId, isNotEmpty);
      expect(settings.deviceId, isNotEmpty);
      expect(settings.logEpoch, isNotEmpty);
      expect(
        {settings.storeId, settings.deviceId, settings.logEpoch}.length,
        3,
        reason: 'store, device, and log epoch are distinct ids',
      );
      expect(settings.backupEnabled, isFalse);
      expect(settings.backupDestination, isEmpty);
      expect(settings.backupGenerations, 5);
      expect(settings.exportRedactComments, isFalse);
      expect(settings.replicateEnabled, isFalse);
    });

    test('the v9 to v10 backfill covers every Record, Activity, Category, Tag, '
        'and the Lap', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'tempo-change-backfill',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final dbPath = p.join(tempDir.path, 'tempo.db');

      final before = await TempoDatabase.open(path: dbPath);
      final category = Category(
        id: 'cat-1',
        name: 'Work',
        colorHex: '#445566',
        createdAtEpochMs: 1000,
        updatedAtEpochMs: 1100,
      );
      await before.upsertCategory(category);
      final activity = Activity(
        id: 'act-1',
        name: 'Deep Work',
        categoryId: category.id,
        colorHex: '#112233',
        createdAtEpochMs: 1000,
        updatedAtEpochMs: 1200,
      );
      await before.insertActivity(activity);
      final tag = Tag(
        id: 'tag-1',
        name: 'Travel',
        createdAtEpochMs: 1000,
        updatedAtEpochMs: 1300,
      );
      await before.insertTag(tag);
      final record = Record(
        id: 'rec-1',
        activityId: activity.id,
        startedAtEpochMs: 1000,
        endedAtEpochMs: 2000,
        comment: 'w/ Sam',
        timezoneId: 'America/Los_Angeles',
        endTimezoneId: 'Asia/Tokyo',
        createdAtEpochMs: 900,
        updatedAtEpochMs: 1400,
        tagIds: [tag.id],
      );
      await before.insertRecord(record);
      final lap = Lap(
        startedAtEpochMs: 1500,
        startedTimezoneId: 'America/Los_Angeles',
        revision: 3,
      );
      await before.setLap(lap);
      final storedActivity = await before.getActivityById(activity.id);
      final storedRecord = await before.getRecordById(record.id);
      final storeIdBefore = (await before.getSyncSettings()).storeId;

      // Put the store back to the v9 shape: no replication tables, and a
      // user_version that makes the next open run the v9 -> v10 migration.
      for (final table in [
        'changes',
        'processed_intents',
        'watch_watermarks',
        'sync_peers',
      ]) {
        await before.db.execute('DROP TABLE $table;');
      }
      await before.db.execute('PRAGMA user_version = 9;');
      await before.close();

      final db = await TempoDatabase.open(path: dbPath);
      addTearDown(db.close);

      expect(TempoDatabase.databaseVersion, 10);
      final changes = await db.changesAfter(0);
      expect(changes, hasLength(5));
      expect(await db.highestChangeSeq(), 5);

      // Applied order: categories, activities, tags, records, lap.
      final byKind = {for (final change in changes) change.kind: change};
      expect(byKind.keys, {
        SyncChangeKind.categoryUpsert,
        SyncChangeKind.activityUpsert,
        SyncChangeKind.tagUpsert,
        SyncChangeKind.recordUpsert,
        SyncChangeKind.lapSet,
      });

      final categoryChange = byKind[SyncChangeKind.categoryUpsert]!;
      expect(categoryChange.entityId, category.id);
      expect(categoryChange.atEpochMs, category.updatedAtEpochMs);
      expect(categoryChange.category, equals(category));

      final activityChange = byKind[SyncChangeKind.activityUpsert]!;
      expect(activityChange.entityId, activity.id);
      expect(activityChange.atEpochMs, activity.updatedAtEpochMs);
      expect(activityChange.activity, equals(storedActivity));

      final tagChange = byKind[SyncChangeKind.tagUpsert]!;
      expect(tagChange.entityId, tag.id);
      expect(tagChange.atEpochMs, tag.updatedAtEpochMs);
      expect(tagChange.tag, equals(tag));

      final recordChange = byKind[SyncChangeKind.recordUpsert]!;
      expect(recordChange.entityId, record.id);
      expect(recordChange.atEpochMs, record.updatedAtEpochMs);
      expect(recordChange.record, equals(storedRecord));
      expect(recordChange.tagIds, [tag.id]);

      final lapChange = byKind[SyncChangeKind.lapSet]!;
      expect(lapChange.entityId, 'lap');
      expect(lapChange.atEpochMs, lap.startedAtEpochMs);
      expect(lapChange.lap, equals(lap));

      // The migration keeps the store id it was seeded with.
      expect((await db.getSyncSettings()).storeId, storeIdBefore);
    });
  });

  group('Processed intents and watch watermarks', () {
    late TempoDatabase db;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
    });

    tearDown(() async {
      await db.close();
    });

    test('an intent is recorded once per log epoch and intent id', () async {
      ProcessedIntent entry(String logEpoch) => ProcessedIntent(
        logEpoch: logEpoch,
        intentId: 'intent-1',
        entityId: 'rec-1',
        appliedAtEpochMs: 500,
        result: IntentResult.appliedStatus,
      );

      await db.markProcessedIntent(entry('epoch-1'));
      await db.markProcessedIntent(entry('epoch-1'));

      final rows = await db.db.query('processed_intents');
      expect(rows, hasLength(1));

      final stored = await db.lookupProcessedIntent('epoch-1', 'intent-1');
      expect(stored, isNotNull);
      expect(stored!.entityId, 'rec-1');
      expect(
        stored.toIntentResult(),
        equals(IntentResult.applied(entityId: 'rec-1', appliedAtEpochMs: 500)),
      );

      // A renewed log epoch starts a fresh set of processed intents.
      await db.markProcessedIntent(entry('epoch-2'));
      expect(await db.db.query('processed_intents'), hasLength(2));
      expect(await db.lookupProcessedIntent('epoch-2', 'intent-1'), isNotNull);
      expect(await db.lookupProcessedIntent('epoch-3', 'intent-1'), isNull);
    });

    test('a rejected intent keeps its reason', () async {
      await db.markProcessedIntent(
        ProcessedIntent(
          logEpoch: 'epoch-1',
          intentId: 'intent-2',
          appliedAtEpochMs: 0,
          result: IntentResult.rejectedStatus,
          reason: IntentResult.reasonLapMoved,
        ),
      );

      final stored = await db.lookupProcessedIntent('epoch-1', 'intent-2');
      expect(stored!.result, IntentResult.rejectedStatus);
      expect(stored.reason, IntentResult.reasonLapMoved);
    });

    test(
      'a watch watermark starts at 0 and only moves for its device',
      () async {
        expect(await db.getWatchWatermark('watch-1'), 0);

        await db.setWatchWatermark('watch-1', 7);
        expect(await db.getWatchWatermark('watch-1'), 7);

        await db.setWatchWatermark('watch-1', 12);
        expect(await db.getWatchWatermark('watch-1'), 12);

        expect(await db.getWatchWatermark('watch-2'), 0);
        expect(await db.db.query('watch_watermarks'), hasLength(1));
      },
    );

    test('peers are stored and removed by device id', () async {
      await db.upsertPeer(
        const SyncPeer(
          peerDeviceId: 'peer-1',
          storeId: 'store-1',
          host: '192.168.1.20:8787',
          lastSeenEpochMs: 100,
        ),
      );
      await db.upsertPeer(
        const SyncPeer(
          peerDeviceId: 'peer-1',
          storeId: 'store-1',
          host: '192.168.1.21:8787',
          lastSeenEpochMs: 200,
        ),
      );

      final peers = await db.getPeers();
      expect(peers, hasLength(1));
      expect(peers.single.host, '192.168.1.21:8787');

      await db.deletePeer('peer-1');
      expect(await db.getPeers(), isEmpty);
    });
  });
}
