import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/core/sync/discovery.dart';
import 'package:tempo/core/sync/intent_queue.dart';
import 'package:tempo/core/sync/peer_pairing.dart';
import 'package:tempo/core/sync/replica_applier.dart';
import 'package:tempo/core/sync/sync_client.dart';
import 'package:tempo/core/sync/sync_listener.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/data/models/sync_change.dart';

/// Epoch milliseconds for a wall-clock time in [zone].
int wallMs(
  String zone,
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) => epochMsFromWallClock(
  DateTime.utc(year, month, day, hour, minute),
  zone,
  referenceEpochMs: DateTime.utc(year, month, day, 12).millisecondsSinceEpoch,
);

const int minuteMs = 60000;
const int hourMs = 3600000;
const String zone = 'America/Los_Angeles';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory temp;
  late TempoDatabase phoneDb;
  late TempoDatabase macDb;
  late DayRecorder phoneRecorder;
  late SyncListener listener;
  late SyncClient client;
  late ReplicaApplier applier;
  late IntentQueue queue;
  late FakePeerDiscovery discovery;
  late PeerPairing phonePairing;
  late PeerPairing macPairing;
  late InMemoryPeerSecretStore macSecrets;
  late RemoteRecordCommands macCommands;
  late int phoneNow;
  late int macNow;
  late int recordCounter;
  late int intentCounter;

  /// Morning of 5 November 2026, 09:00 in Los Angeles.
  final base = wallMs(zone, 2026, 11, 5, 9);

  Future<TempoDatabase> openStore(String name) => TempoDatabase.open(
    path: p.join(temp.path, name),
    factory: databaseFactoryFfi,
  );

  /// The phone's own catalogue, written before any Record. The activity's
  /// change is appended before its category's, so applying by `seq` alone
  /// would fail the foreign key.
  Future<void> seedPhoneCatalog() async {
    final category = Category(
      id: 'cat-work',
      name: 'Work',
      colorHex: '#112233',
      iconName: 'work',
      createdAtEpochMs: base - hourMs,
      updatedAtEpochMs: base - hourMs,
    );
    final activity = Activity(
      id: 'act-coding',
      name: 'Coding',
      categoryId: category.id,
      colorHex: category.colorHex,
      createdAtEpochMs: base - hourMs,
      updatedAtEpochMs: base - hourMs,
    );
    final tag = Tag(
      id: 'tag-travel',
      name: 'Travel',
      createdAtEpochMs: base - hourMs,
      updatedAtEpochMs: base - hourMs,
    );
    await phoneDb.upsertCategory(category);
    await phoneDb.insertActivity(activity);
    await phoneDb.insertTag(tag);
    await phoneDb.appendChange(
      SyncChange.activityUpsert(activity, atEpochMs: activity.updatedAtEpochMs),
    );
    await phoneDb.appendChange(
      SyncChange.categoryUpsert(category, atEpochMs: category.updatedAtEpochMs),
    );
    await phoneDb.appendChange(
      SyncChange.tagUpsert(tag, atEpochMs: tag.updatedAtEpochMs),
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tempo_replication_test');

    // sqflite caches `:memory:` by path, so each store lives in its own file
    // inside this test's temporary directory.
    phoneDb = await openStore('phone.db');
    macDb = await openStore('mac.db');

    phoneNow = base;
    macNow = base;
    recordCounter = 0;
    intentCounter = 0;

    await seedPhoneCatalog();

    phoneRecorder = DayRecorder(
      database: phoneDb,
      nowUtcMs: () => phoneNow,
      generateId: () => 'rec-${++recordCounter}',
      getTimezoneId: () => zone,
      autoSplitAtMidnight: false,
      undoGraceWindow: const Duration(days: 1),
    );
    await phoneRecorder.initialize();

    final phoneSecrets = InMemoryPeerSecretStore();
    macSecrets = InMemoryPeerSecretStore();
    phonePairing = PeerPairing(
      database: phoneDb,
      secrets: phoneSecrets,
      nowUtcMs: () => phoneNow,
    );
    macPairing = PeerPairing(
      database: macDb,
      secrets: macSecrets,
      nowUtcMs: () => macNow,
    );

    listener = SyncListener(
      database: phoneDb,
      dayRecorder: phoneRecorder,
      pairing: phonePairing,
      host: '127.0.0.1',
      port: 0,
      longPollTimeout: const Duration(seconds: 2),
    );
    final port = await listener.start();

    // The Mac shows the pairing code; the phone scans it. The Mac then finds
    // the phone over discovery and adopts it on the first answered exchange.
    final invite = await macPairing.createInvite();
    await phonePairing.pairFromInvite(invite);
    discovery = FakePeerDiscovery(
      peer: DiscoveredPeer(
        host: '127.0.0.1',
        port: port,
        storeId: (await phoneDb.getSyncSettings()).storeId,
      ),
    );

    applier = ReplicaApplier(macDb);
    queue = IntentQueue(macDb);
    client = SyncClient(
      database: macDb,
      pairing: macPairing,
      applier: applier,
      queue: queue,
      discovery: discovery,
      nowUtcMs: () => macNow,
    );
    macCommands = RemoteRecordCommands(
      database: macDb,
      queue: queue,
      nowUtcMs: () => macNow,
      zoneId: () => zone,
      generateIntentId: () => 'intent-${++intentCounter}',
    );
  });

  tearDown(() async {
    await listener.stop();
    client.dispose();
    phoneRecorder.dispose();
    await phoneDb.close();
    await macDb.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  /// POSTs a hand-built request, for the cases a queue cannot produce (a
  /// duplicate id with a different body).
  Future<Map<String, dynamic>> postRaw(SyncRequest request) async {
    final body = jsonEncode(request.toJson());
    final secret = await macPairing.secretForPeerStore(
      (await phoneDb.getSyncSettings()).storeId,
    );
    final timestamp = phoneNow;
    final signature = PeerPairing.signatureFor(
      secret: secret!,
      timestampEpochMs: timestamp,
      body: body,
    );
    final response = await http.post(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: listener.boundPort,
        path: '/sync',
      ),
      headers: {
        'content-type': 'application/json',
        SyncListener.deviceHeader: (await macDb.getSyncSettings()).deviceId,
        SyncListener.timestampHeader: '$timestamp',
        SyncListener.signatureHeader: signature,
      },
      body: body,
    );
    expect(response.statusCode, 200, reason: response.body);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Record>> phoneRecords() =>
      phoneDb.getRecords(orderBy: 'started_at_epoch_ms ASC');

  Future<List<Record>> macRecords() =>
      macDb.getRecords(orderBy: 'started_at_epoch_ms ASC');

  test('a label on the phone reaches the Mac row for row', () async {
    phoneNow = base + 58 * minuteMs;
    macNow = phoneNow;
    final record = await phoneRecorder.label(
      'act-coding',
      comment: 'w/ Sam',
      tags: const ['tag-travel'],
    );

    final result = await client.pull();

    expect(result.changesApplied, greaterThan(0));
    expect(result.replayed, isFalse);
    // The code carries no address, so the first exchange finds the phone over
    // discovery; adoption then dials that address directly.
    expect(discovery.lookups, 1);
    final peer = (await macDb.getPeers()).single;
    expect(peer.host, '127.0.0.1');
    expect(peer.storeId, (await phoneDb.getSyncSettings()).storeId);
    final replica = await macDb.getRecordById(record.id);
    expect(replica, equals(record));
    expect(replica!.comment, 'w/ Sam');
    expect(replica.tagIds, ['tag-travel']);
    expect(
      (await macDb.getLap())!.startedAtEpochMs,
      phoneRecorder.lap!.startedAtEpochMs,
    );
    expect(await applier.appliedSeq(), await phoneDb.highestChangeSeq());
    expect(await macDb.getActivityById('act-coding'), isNotNull);
    expect((await macDb.getActivityById('act-coding'))!.categoryId, 'cat-work');
    expect(await macDb.getAllTags(), hasLength(1));
  });

  test('a category is applied before the activity that points at it', () async {
    final category = Category(
      id: 'cat-life',
      name: 'Life',
      colorHex: '#445566',
      iconName: 'home',
      createdAtEpochMs: base,
      updatedAtEpochMs: base,
    );
    final activity = Activity(
      id: 'act-gym',
      name: 'Gym',
      categoryId: category.id,
      colorHex: category.colorHex,
      createdAtEpochMs: base,
      updatedAtEpochMs: base,
    );
    await phoneDb.upsertCategory(category);
    await phoneDb.insertActivity(activity);
    // Activity change first, category change second: only the entity order
    // makes the foreign key resolve.
    await phoneDb.appendChange(
      SyncChange.activityUpsert(activity, atEpochMs: base),
    );
    await phoneDb.appendChange(
      SyncChange.categoryUpsert(category, atEpochMs: base),
    );

    await client.pull();
    expect((await macDb.getActivityById('act-gym'))!.categoryId, 'cat-life');

    // An update must not be an INSERT OR REPLACE: the activity keeps its
    // category and keeps its colour in step with the category.
    final updated = category.copyWith(
      name: 'Life admin',
      colorHex: '#778899',
      updatedAtEpochMs: base + 1,
    );
    await phoneDb.upsertCategory(updated);
    await phoneDb.appendChange(
      SyncChange.categoryUpsert(updated, atEpochMs: base + 1),
    );

    await client.pull();
    final replica = await macDb.getActivityById('act-gym');
    expect(replica!.categoryId, 'cat-life');
    expect(replica.colorHex, '#778899');
    expect((await macDb.getCategoryById('cat-life'))!.name, 'Life admin');
  });

  test('an unknown change kind aborts without advancing the cursor', () async {
    phoneNow = base + 10 * minuteMs;
    macNow = phoneNow;
    await phoneRecorder.label('act-coding');
    await client.pull();
    final before = await applier.appliedSeq();
    final replicaRecords = await macRecords();

    await phoneDb.db.insert('changes', {
      'change_id': 'future-1',
      'kind': 'future_kind',
      'entity_id': 'anything',
      'at_epoch_ms': phoneNow,
      'payload_json': '{"version":1,"payload":{}}',
    });

    await expectLater(client.pull(), throwsA(isA<ReplicaApplyException>()));
    expect(await applier.appliedSeq(), before);
    expect(await macRecords(), equals(replicaRecords));
    expect(client.status.value, SyncClientStatus.failed);
    expect(client.lastError, contains('behind the phone'));
  });

  test('a repeated pull changes nothing', () async {
    phoneNow = base + 30 * minuteMs;
    macNow = phoneNow;
    await phoneRecorder.label('act-coding');

    final first = await client.pull();
    expect(first.changesApplied, greaterThan(0));
    final cursor = await applier.appliedSeq();

    final second = await client.pull();
    expect(second.changesApplied, 0);
    expect(second.replayed, isFalse);
    expect(await applier.appliedSeq(), cursor);
  });

  test('a replica with rows but no cursor is cleared before replay', () async {
    final stale = Record(
      id: 'stale-record',
      activityId: null,
      startedAtEpochMs: base - 2 * hourMs,
      endedAtEpochMs: base - hourMs,
      timezoneId: zone,
      endTimezoneId: zone,
      createdAtEpochMs: base - 2 * hourMs,
      updatedAtEpochMs: base - hourMs,
    );
    await macDb.insertRecord(stale);
    expect(await macDb.getSetting(ReplicaApplier.appliedSeqKey), isNull);

    phoneNow = base + 30 * minuteMs;
    macNow = phoneNow;
    await phoneRecorder.label('act-coding');

    final result = await client.pull();
    expect(result.replayed, isTrue);
    final ids = (await macRecords()).map((r) => r.id).toList();
    expect(ids, isNot(contains('stale-record')));
    expect(await applier.appliedSeq(), await phoneDb.highestChangeSeq());
  });

  test('an intent is applied at the instant it was tapped', () async {
    // The Mac has seen the Lap start at 09:00.
    await client.pull();

    phoneNow = base + 61 * minuteMs;
    macNow = base + 60 * minuteMs;
    await macCommands.label('act-coding');
    final queued = await queue.pendingIntents();
    expect(queued, hasLength(1));
    expect(queued.single.tappedAtEpochMs, base + 60 * minuteMs);
    expect(queued.single.intent.expectedLapStartEpochMs, base);

    final result = await client.pull();

    final records = await phoneRecords();
    expect(records, hasLength(1));
    expect(records.single.startedAtEpochMs, base);
    expect(records.single.endedAtEpochMs, base + 60 * minuteMs);
    expect(records.single.timezoneId, zone);
    expect(phoneRecorder.lap!.startedAtEpochMs, base + 60 * minuteMs);

    expect(result.intentResults, hasLength(1));
    expect(result.intentResults.single.result.isApplied, isTrue);
    final answered = await queue.byId(queued.single.intentId);
    expect(answered!.isApplied, isTrue);
    expect(answered.reason, isEmpty);

    // The Record the intent produced comes back on the same exchange.
    expect(
      await macDb.getRecordById(records.single.id),
      equals(records.single),
    );
    expect(
      (await macDb.getLap())!.startedAtEpochMs,
      phoneRecorder.lap!.startedAtEpochMs,
    );
  });

  test('a moved Lap rejects the intent with lap-moved', () async {
    await client.pull();

    phoneNow = base + 61 * minuteMs;
    macNow = base + 60 * minuteMs;
    await queue.enqueue(
      SyncIntent.label(
        intentId: 'intent-moved',
        tappedAtEpochMs: macNow,
        tappedAtZoneId: zone,
        // The Mac believed the Lap started an hour earlier.
        expectedLapStartEpochMs: base - hourMs,
        activityId: 'act-coding',
      ),
    );

    final result = await client.pull();

    expect(await phoneRecords(), isEmpty);
    expect(
      result.intentResults.single.result.status,
      IntentResult.rejectedStatus,
    );
    expect(
      result.intentResults.single.result.reason,
      IntentResult.reasonLapMoved,
    );
    final answered = await queue.byId('intent-moved');
    expect(answered!.isRejected, isTrue);
    expect(answered.reason, IntentResult.reasonLapMoved);
    expect(phoneRecorder.lap!.startedAtEpochMs, base);
  });

  test('an edit that overlaps a labelled Record is rejected', () async {
    phoneNow = base + 30 * minuteMs;
    await phoneRecorder.label('act-coding');
    phoneNow = base + 45 * minuteMs;
    final second = await phoneRecorder.label('act-coding');
    expect(phoneRecorder.lap!.startedAtEpochMs, base + 45 * minuteMs);

    macNow = base + 46 * minuteMs;
    phoneNow = base + 46 * minuteMs;
    await client.pull();
    final before = await macDb.getRecordById(second.id);

    await queue.enqueue(
      SyncIntent.adjustEdges(
        intentId: 'intent-overlap',
        tappedAtEpochMs: macNow,
        tappedAtZoneId: zone,
        expectedLapStartEpochMs: base + 45 * minuteMs,
        recordId: second.id,
        // 09:10–09:30 already belongs to the first labelled Record.
        startEpochMs: base + 10 * minuteMs,
      ),
    );

    final result = await client.pull();

    expect(
      result.intentResults.single.result.reason,
      IntentResult.reasonOverlap,
    );
    expect(
      (await queue.byId('intent-overlap'))!.reason,
      IntentResult.reasonOverlap,
    );
    expect(await macDb.getRecordById(second.id), equals(before));
    expect((await phoneRecords())[1].startedAtEpochMs, base + 30 * minuteMs);
  });

  test('a paginated replay of 2,000 changes converges', () async {
    // Clear the catalogue page first, so this test counts only the 2,000.
    await client.pull();

    final tags = [
      for (var i = 0; i < 2000; i++)
        Tag(
          id: 'tag-$i',
          name: 'Tag $i',
          createdAtEpochMs: base,
          updatedAtEpochMs: base,
        ),
    ];
    // One transaction, so the log is written as fast as the test needs.
    await phoneDb.db.transaction((txn) async {
      for (final tag in tags) {
        await txn.insert('tags', tag.toMap());
        await phoneDb.appendChange(
          SyncChange.tagUpsert(tag, atEpochMs: tag.updatedAtEpochMs),
          executor: txn,
        );
      }
    });

    final before = (await macDb.getAllTags()).length;
    final result = await client.pull();

    expect(result.changesApplied, 2000);
    expect(await macDb.getAllTags(), hasLength(before + 2000));
    expect(await applier.appliedSeq(), await phoneDb.highestChangeSeq());
    expect(
      (await macDb.getAllTags()).map((tag) => tag.id),
      contains('tag-1999'),
    );
  });

  test(
    'a renewed log epoch clears the replica and replays from zero',
    () async {
      phoneNow = base + 30 * minuteMs;
      macNow = phoneNow;
      await phoneRecorder.label('act-coding');
      final first = await client.pull();
      expect(first.replayed, isFalse);
      expect(await macRecords(), hasLength(1));

      // A restore or a bootstrap adoption replaces the history and renews the
      // log, backfilling one change per entity, exactly as
      // BootstrapService.adopt does.
      final replacement = Record(
        id: 'rec-after-restore',
        activityId: 'act-coding',
        startedAtEpochMs: base,
        endedAtEpochMs: base + 20 * minuteMs,
        timezoneId: zone,
        createdAtEpochMs: phoneNow,
        updatedAtEpochMs: phoneNow,
      );
      final category = (await phoneDb.getCategoryById('cat-work'))!;
      final activity = (await phoneDb.getActivityById('act-coding'))!;
      final tag = (await phoneDb.getTagById('tag-travel'))!;
      final lap = phoneRecorder.lap!;
      await phoneDb.db.transaction((txn) async {
        await txn.delete('record_tags');
        await txn.delete('records');
        await txn.delete('changes');
        await txn.insert('records', replacement.toMap());
        for (final change in [
          SyncChange.categoryUpsert(category, atEpochMs: phoneNow),
          SyncChange.activityUpsert(activity, atEpochMs: phoneNow),
          SyncChange.tagUpsert(tag, atEpochMs: phoneNow),
          SyncChange.recordUpsert(replacement, atEpochMs: phoneNow),
          SyncChange.lapSet(lap, atEpochMs: phoneNow),
        ]) {
          await phoneDb.appendChange(change, executor: txn);
        }
      });
      await phoneDb.setSetting(SyncSettingKeys.logEpoch, 'epoch-after-restore');

      final result = await client.pull();

      expect(result.replayed, isTrue);
      expect(await macRecords(), hasLength(1));
      expect((await macRecords()).single.id, 'rec-after-restore');
      expect(await applier.appliedSeq(), await phoneDb.highestChangeSeq());
      expect(
        await macDb.getSetting(ReplicaApplier.replicaLogEpochKey),
        'epoch-after-restore',
      );
    },
  );

  test(
    'a resent intent after a restore is answered, not applied twice',
    () async {
      await client.pull();
      phoneNow = base + 6 * minuteMs;
      macNow = base + 5 * minuteMs;
      await macCommands.label('act-coding');

      await client.pull();
      expect(await phoneRecords(), hasLength(1));
      final queued = await queue.pendingIntents();
      expect(queued, isEmpty);

      // The Mac lost the answer (its queue was restored from an older copy), so
      // the same intent travels again.
      await macDb.db.update(
        IntentQueue.table,
        {'status': IntentQueue.pendingStatus, 'reason': ''},
        where: 'intent_id = ?',
        whereArgs: ['intent-1'],
      );
      expect(await queue.pendingIntents(), hasLength(1));

      final result = await client.pull();

      expect(await phoneRecords(), hasLength(1));
      expect(
        result.intentResults.single.result.status,
        IntentResult.appliedStatus,
      );
      expect((await queue.byId('intent-1'))!.isApplied, isTrue);
    },
  );

  test('a stale intent id is a no-op whatever it now asks for', () async {
    phoneNow = base + 5 * minuteMs;
    macNow = phoneNow;
    await client.pull();
    phoneNow = base + 6 * minuteMs;
    await macCommands.label('act-coding');
    await client.pull();

    final applied = (await phoneRecords()).single;
    expect(applied.endedAtEpochMs, base + 5 * minuteMs);

    // A duplicate id with a different body: the phone must answer from
    // `processed_intents` and write nothing.
    final stale = SyncIntent.split(
      intentId: 'intent-1',
      tappedAtEpochMs: base + 4 * minuteMs,
      tappedAtZoneId: zone,
      expectedLapStartEpochMs: base,
    );
    final response = await postRaw(
      SyncRequest(
        deviceId: (await macDb.getSyncSettings()).deviceId,
        storeId: (await macDb.getSyncSettings()).storeId,
        logEpoch: '',
        appliedSeq: 0,
        limit: 500,
        intents: [stale],
      ),
    );

    final outcomes = response['intentResults'] as List;
    expect(outcomes, hasLength(1));
    expect((outcomes.single as Map)['status'], IntentResult.appliedStatus);
    expect((outcomes.single as Map)['entityId'], applied.id);
    expect(await phoneRecords(), hasLength(1));
    expect((await phoneRecords()).single, equals(applied));
  });

  test('a long poll completes as soon as a change exists', () async {
    await client.pull();

    phoneNow = base + 20 * minuteMs;
    macNow = phoneNow;
    final held = client.awaitChanges();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await phoneRecorder.label('act-coding');
    listener.notifyChanged();

    final result = await held;
    // A label is a Record and a Lap move.
    expect(result.changesApplied, 2);
    expect(await macRecords(), hasLength(1));

    // A second wait with nothing new returns empty at the timeout.
    final empty = await client.awaitChanges();
    expect(empty.changesApplied, 0);
  });
}
