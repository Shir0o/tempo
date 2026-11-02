import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late TempoDatabase db;
  late DayRecorder recorder;
  late int nowUtc;
  late String zoneId;
  late int idCounter;

  const sleep = Activity(
    id: 'act-sleep',
    name: 'Sleep',
    colorHex: '#5C6BC0',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  const meals = Activity(
    id: 'act-meals',
    name: 'Meals',
    colorHex: '#FFB300',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  const travelTag = Tag(
    id: 'tag-travel',
    name: 'Travel',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  setUp(() async {
    db = await TempoDatabase.openInMemory(factory: databaseFactoryFfi);
    await db.insertActivity(sleep);
    await db.insertActivity(meals);
    await db.insertTag(travelTag);

    nowUtc = 1000000;
    zoneId = 'America/Los_Angeles';
    idCounter = 0;

    recorder = DayRecorder(
      database: db,
      nowUtcMs: () => nowUtc,
      generateId: () => 'rec-${++idCounter}',
      getTimezoneId: () => zoneId,
    );
  });

  tearDown(() async {
    recorder.dispose();
    await db.close();
  });

  test(
    'labeling closes exactly [lapStart, now) and opens the next Lap',
    () async {
      await recorder.initialize();
      expect(recorder.lap!.startedAtEpochMs, equals(1000000));

      nowUtc += 90000;
      zoneId = 'Asia/Tokyo';

      final record = await recorder.label(
        sleep.id,
        comment: 'w/ Sam',
        tags: [travelTag.id],
      );

      expect(record.startedAtEpochMs, equals(1000000));
      expect(record.endedAtEpochMs, equals(1090000));
      expect(record.durationMs, equals(90000));
      expect(record.activityId, equals(sleep.id));
      expect(record.comment, equals('w/ Sam'));
      expect(record.tagIds, equals([travelTag.id]));
      expect(record.timezoneId, equals('America/Los_Angeles'));
      expect(record.endTimezoneId, equals('Asia/Tokyo'));

      // The new Lap starts at the instant the Record ended, in the new zone.
      expect(recorder.lap!.startedAtEpochMs, equals(1090000));
      expect(recorder.lap!.startedTimezoneId, equals('Asia/Tokyo'));
      expect(recorder.lap!.revision, equals(2));

      final stored = await db.getRecordById(record.id);
      expect(stored, isNotNull);
      expect(stored!.tagIds, equals([travelTag.id]));

      final lapRow = await db.getLap();
      expect(lapRow!.startedAtEpochMs, equals(1090000));
    },
  );

  test('sameAsLast uses the previous labelled Activity', () async {
    await recorder.initialize();

    nowUtc += 60000;
    await recorder.label(meals.id);

    nowUtc += 120000;
    final record = await recorder.sameAsLast();

    expect(record, isNotNull);
    expect(record!.activityId, equals(meals.id));
    expect(record.startedAtEpochMs, equals(1060000));
    expect(record.endedAtEpochMs, equals(1180000));
    expect(recorder.lap!.startedAtEpochMs, equals(1180000));
  });

  test(
    'split closes the Lap as an Untracked Record and opens a new Lap',
    () async {
      await recorder.initialize();
      nowUtc += 90000;
      zoneId = 'Asia/Tokyo';

      final record = await recorder.split();

      expect(record.activityId, isNull);
      expect(record.isUntracked, isTrue);
      expect(record.startedAtEpochMs, equals(1000000));
      expect(record.endedAtEpochMs, equals(1090000));
      expect(record.durationMs, equals(90000));
      expect(record.timezoneId, equals('America/Los_Angeles'));
      expect(record.endTimezoneId, equals('Asia/Tokyo'));
      expect(record.comment, isEmpty);

      expect(recorder.lap!.startedAtEpochMs, equals(1090000));
      expect(recorder.lap!.startedTimezoneId, equals('Asia/Tokyo'));

      final stored = await db.getRecordById(record.id);
      expect(stored, isNotNull);
      expect(stored!.activityId, isNull);
    },
  );

  test('sameAsLast skips Untracked Records', () async {
    await recorder.initialize();
    nowUtc += 60000;
    await recorder.label(sleep.id);

    nowUtc += 60000;
    await recorder.split();

    nowUtc += 60000;
    final record = await recorder.sameAsLast();

    expect(record, isNotNull);
    expect(record!.activityId, equals(sleep.id));
    expect(record.startedAtEpochMs, equals(1120000));
  });

  test('undo inside the grace window restores the previous Lap', () async {
    await recorder.initialize();
    nowUtc += 90000;

    final record = await recorder.label(sleep.id, comment: 'w/ Sam');
    nowUtc += 2000;

    expect(await recorder.undoLast(), isTrue);

    expect(await db.getRecordById(record.id), isNull);
    expect(recorder.lap!.startedAtEpochMs, equals(1000000));
    expect(recorder.lap!.startedTimezoneId, equals('America/Los_Angeles'));
    expect(recorder.lap!.revision, equals(1));

    final storedLap = await db.getLap();
    expect(storedLap!.startedAtEpochMs, equals(1000000));

    final tombstones = await db.getTombstones();
    expect(tombstones.single.entityId, equals(record.id));
    expect(tombstones.single.entityType, equals('record'));
  });

  test('undo after the grace window is refused and keeps the Record', () async {
    await recorder.initialize();
    nowUtc += 90000;

    final record = await recorder.label(sleep.id);
    nowUtc += 4000;

    expect(await recorder.undoLast(), isFalse);

    expect(await db.getRecordById(record.id), isNotNull);
    expect(recorder.lap!.startedAtEpochMs, equals(1090000));
    expect(await db.getTombstones(), isEmpty);
  });

  test('undo reverses a split within the window', () async {
    await recorder.initialize();
    nowUtc += 45000;

    final record = await recorder.split();
    nowUtc += 1000;

    expect(await recorder.undoLast(), isTrue);
    expect(await db.getRecordById(record.id), isNull);
    expect(recorder.lap!.startedAtEpochMs, equals(1000000));
  });

  test('undoLast is a no-op without a recent label or split', () async {
    await recorder.initialize();
    expect(await recorder.undoLast(), isFalse);
    expect(await db.getRecords(), isEmpty);
  });

  test('relabel does not arm undo', () async {
    await recorder.initialize();
    final now = nowUtc;
    await db.insertRecord(
      Record(
        id: 'rec-manual',
        activityId: null,
        startedAtEpochMs: now - 60000,
        endedAtEpochMs: now,
        durationMs: 60000,
        timezoneId: zoneId,
        endTimezoneId: zoneId,
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      ),
    );

    final relabelled = await recorder.relabel('rec-manual', meals.id);
    expect(relabelled.activityId, equals(meals.id));

    expect(await recorder.undoLast(), isFalse);
    expect(await db.getRecordById('rec-manual'), isNotNull);
  });

  test('sameAsLast returns null when no Record exists yet', () async {
    await recorder.initialize();
    expect(await recorder.sameAsLast(), isNull);
    expect(recorder.lap!.startedAtEpochMs, equals(1000000));
  });

  test('initialize reuses the persisted Lap instead of resetting it', () async {
    await recorder.initialize();

    nowUtc += 500000;
    final reopened = DayRecorder(
      database: db,
      nowUtcMs: () => nowUtc,
      generateId: () => 'rec-${++idCounter}',
      getTimezoneId: () => zoneId,
    );
    addTearDown(reopened.dispose);

    await reopened.initialize();
    expect(reopened.lap!.startedAtEpochMs, equals(1000000));
  });

  test('label rejects an unknown Activity without changing the Lap', () async {
    await recorder.initialize();
    nowUtc += 30000;

    expect(
      () => recorder.label('missing-activity'),
      throwsA(isA<ArgumentError>()),
    );
    expect(recorder.lap!.startedAtEpochMs, equals(1000000));
    expect(await db.getRecords(), isEmpty);
  });

  test('lap stream emits the new Lap after a label', () async {
    await recorder.initialize();
    final emissions = <Lap?>[];
    final subscription = recorder.lapStream.listen(emissions.add);
    addTearDown(subscription.cancel);

    nowUtc += 30000;
    await recorder.label(sleep.id);
    await Future<void>.delayed(Duration.zero);

    expect(emissions.single!.startedAtEpochMs, equals(1030000));
  });
}
