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
