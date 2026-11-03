import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/export/csv_export_engine.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

/// Epoch milliseconds for a wall-clock time in [zone].
int wallMs(
  String zone,
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) {
  const noon = 12;
  return epochMsFromWallClock(
    DateTime.utc(year, month, day, hour, minute),
    zone,
    referenceEpochMs: DateTime.utc(
      year,
      month,
      day,
      noon,
    ).millisecondsSinceEpoch,
  );
}

const int hourMs = 3600000;

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

  group('Correcting the past', () {
    late int morning;
    late Record sleepRecord;
    late Record mealsRecord;
    late int lapStart;

    Future<void> recordTwoHours() async {
      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 1, 8);
      await recorder.initialize();
      morning = nowUtc;

      nowUtc = wallMs(zoneId, 2026, 6, 1, 10);
      sleepRecord = await recorder.label(
        sleep.id,
        comment: 'w/ Sam',
        tags: [travelTag.id],
      );

      nowUtc = wallMs(zoneId, 2026, 6, 1, 12);
      mealsRecord = await recorder.label(meals.id);
      lapStart = recorder.lap!.startedAtEpochMs;
    }

    int at(int hour, [int minute = 0]) =>
        wallMs(zoneId, 2026, 6, 1, hour, minute);

    test(
      'moveBoundary resizes both neighbours and keeps the Day whole',
      () async {
        await recordTwoHours();
        final edge = at(11);

        final moved = await recorder.moveBoundary(sleepRecord.id, edge);

        expect(moved.id, sleepRecord.id);
        expect(moved.startedAtEpochMs, morning);
        expect(moved.endedAtEpochMs, edge);
        expect(moved.durationMs, 3 * hourMs);
        expect(moved.activityId, sleep.id);
        expect(moved.comment, 'w/ Sam');
        expect(moved.tagIds, [travelTag.id]);

        final right = await db.getRecordById(mealsRecord.id);
        expect(right!.startedAtEpochMs, edge);
        expect(right.durationMs, hourMs);
        expect(right.activityId, meals.id);

        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        expect(records[0].endedAtEpochMs, records[1].startedAtEpochMs);
        expect(records.last.endedAtEpochMs, recorder.lap!.startedAtEpochMs);
        expect(records.last.endedAtEpochMs, lapStart);
      },
    );

    test('moveBoundary refuses to pass a neighbour\'s other edge', () async {
      await recordTwoHours();

      await expectLater(
        recorder.moveBoundary(sleepRecord.id, mealsRecord.endedAtEpochMs),
        throwsA(isA<RecordEditRefused>()),
      );
      await expectLater(
        recorder.moveBoundary(sleepRecord.id, morning),
        throwsA(
          isA<RecordEditRefused>().having(
            (error) => error.message,
            'message',
            contains('past a neighbouring Record'),
          ),
        ),
      );

      final left = await db.getRecordById(sleepRecord.id);
      expect(left!.endedAtEpochMs, at(10));
      final right = await db.getRecordById(mealsRecord.id);
      expect(right!.startedAtEpochMs, at(10));
    });

    test(
      'moveBoundary refuses to move the edge where the open Lap starts',
      () async {
        await recordTwoHours();

        await expectLater(
          recorder.moveBoundary(mealsRecord.id, at(11)),
          throwsA(
            isA<RecordEditRefused>().having(
              (error) => error.message,
              'message',
              contains('open Lap'),
            ),
          ),
        );

        final unchanged = await db.getRecordById(mealsRecord.id);
        expect(unchanged!.endedAtEpochMs, lapStart);
      },
    );

    test('moveBoundary keeps each Record\'s start and end zones', () async {
      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 1, 8);
      await recorder.initialize();

      zoneId = 'Asia/Tokyo';
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      sleepRecord = await recorder.label(sleep.id);
      nowUtc += hourMs;
      mealsRecord = await recorder.label(meals.id);

      await recorder.moveBoundary(
        sleepRecord.id,
        sleepRecord.startedAtEpochMs + hourMs ~/ 2,
      );

      final left = await db.getRecordById(sleepRecord.id);
      expect(left!.timezoneId, 'America/Los_Angeles');
      expect(left.endTimezoneId, 'Asia/Tokyo');

      final right = await db.getRecordById(mealsRecord.id);
      expect(right!.timezoneId, 'Asia/Tokyo');
      expect(right.endTimezoneId, 'Asia/Tokyo');
    });

    test('splitRecord creates two neighbours that share everything', () async {
      await recordTwoHours();
      final splitAt = at(9, 30);

      final later = await recorder.splitRecord(sleepRecord.id, splitAt);

      final earlier = await db.getRecordById(sleepRecord.id);
      expect(earlier!.startedAtEpochMs, morning);
      expect(earlier.endedAtEpochMs, splitAt);
      expect(earlier.durationMs, 90 * 60 * 1000);

      expect(later.startedAtEpochMs, splitAt);
      expect(later.endedAtEpochMs, at(10));
      expect(later.durationMs, 30 * 60 * 1000);

      for (final half in [earlier, later]) {
        expect(half.activityId, sleep.id);
        expect(half.comment, 'w/ Sam');
        expect(half.tagIds, [travelTag.id]);
        expect(half.timezoneId, 'America/Los_Angeles');
        expect(half.endTimezoneId, 'America/Los_Angeles');
      }
      expect(later.id, isNot(sleepRecord.id));

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(3));
      expect(records[0].endedAtEpochMs, records[1].startedAtEpochMs);
      expect(records[1].endedAtEpochMs, records[2].startedAtEpochMs);
    });

    test('splitRecord refuses a time outside the Record', () async {
      await recordTwoHours();

      await expectLater(
        recorder.splitRecord(sleepRecord.id, sleepRecord.startedAtEpochMs),
        throwsA(isA<RecordEditRefused>()),
      );
      await expectLater(
        recorder.splitRecord(sleepRecord.id, sleepRecord.endedAtEpochMs),
        throwsA(
          isA<RecordEditRefused>().having(
            (error) => error.message,
            'message',
            contains('outside this Record'),
          ),
        ),
      );

      expect(await db.getRecords(), hasLength(2));
    });

    test('splitRecord gives both halves the zones they lived in', () async {
      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 1, 8);
      await recorder.initialize();

      zoneId = 'Asia/Tokyo';
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      sleepRecord = await recorder.label(sleep.id);

      final later = await recorder.splitRecord(
        sleepRecord.id,
        sleepRecord.startedAtEpochMs + hourMs ~/ 2,
      );

      final earlier = await db.getRecordById(sleepRecord.id);
      expect(earlier!.timezoneId, 'America/Los_Angeles');
      expect(earlier.endTimezoneId, 'Asia/Tokyo');
      expect(later.timezoneId, 'Asia/Tokyo');
      expect(later.endTimezoneId, 'Asia/Tokyo');
    });

    test(
      'merge joins neighbours and tombstones the one that disappears',
      () async {
        await recordTwoHours();

        final merged = await recorder.merge(sleepRecord.id, mealsRecord.id);

        expect(merged.id, sleepRecord.id);
        expect(merged.startedAtEpochMs, morning);
        expect(merged.endedAtEpochMs, at(12));
        expect(merged.durationMs, 4 * hourMs);
        expect(merged.activityId, sleep.id);
        expect(merged.comment, 'w/ Sam');
        expect(merged.tagIds, [travelTag.id]);

        expect(await db.getRecordById(mealsRecord.id), isNull);
        final tombstones = await db.getTombstones();
        expect(tombstones.single.entityId, mealsRecord.id);
        expect(tombstones.single.entityType, 'record');

        final records = await db.getRecords();
        expect(records, hasLength(1));
        expect(recorder.lap!.startedAtEpochMs, merged.endedAtEpochMs);
      },
    );

    test('merge refuses Records that are not neighbours', () async {
      await recordTwoHours();
      nowUtc = at(13);
      final laterRecord = await recorder.label(meals.id);

      await expectLater(
        recorder.merge(sleepRecord.id, laterRecord.id),
        throwsA(
          isA<RecordEditRefused>().having(
            (error) => error.message,
            'message',
            contains("aren't next to each other"),
          ),
        ),
      );

      expect(await db.getRecords(), hasLength(3));
      expect(await db.getTombstones(), isEmpty);
    });

    test('delete makes a Record Untracked without removing its time', () async {
      await recordTwoHours();
      final before = await db.getRecordById(mealsRecord.id);

      final deleted = await recorder.delete(mealsRecord.id);

      expect(deleted.id, mealsRecord.id);
      expect(deleted.isUntracked, isTrue);
      expect(deleted.comment, isEmpty);
      expect(deleted.tagIds, isEmpty);
      expect(deleted.startedAtEpochMs, before!.startedAtEpochMs);
      expect(deleted.endedAtEpochMs, before.endedAtEpochMs);

      expect(await db.getRecordById(mealsRecord.id), isNotNull);
      expect(await db.getTombstones(), isEmpty);

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(2));
      final covered = records.fold<int>(0, (sum, r) => sum + r.elapsedMs);
      expect(covered, 4 * hourMs);
    });

    test('relabel turns a Record back into an Untracked Record', () async {
      await recordTwoHours();

      final untracked = await recorder.relabel(mealsRecord.id, null);

      expect(untracked.isUntracked, isTrue);
      expect(untracked.startedAtEpochMs, mealsRecord.startedAtEpochMs);
      expect(untracked.endedAtEpochMs, mealsRecord.endedAtEpochMs);
    });

    test('every correction schedules a debounced CSV rewrite', () async {
      final exportDir = await Directory.systemTemp.createTemp(
        'tempo-corrections',
      );
      addTearDown(() => exportDir.delete(recursive: true));
      final engine = CsvExportEngine(database: db, exportDirectory: exportDir);
      addTearDown(engine.dispose);
      recorder.attachExportEngine(engine);

      await recordTwoHours();
      await engine.exportImmediately();
      expect(engine.isExportScheduled, isFalse);

      final edge = at(11);
      await recorder.moveBoundary(sleepRecord.id, edge);
      expect(engine.isExportScheduled, isTrue);
      await engine.exportImmediately();

      final later = await recorder.splitRecord(sleepRecord.id, at(9));
      expect(engine.isExportScheduled, isTrue);
      await engine.exportImmediately();

      await recorder.merge(sleepRecord.id, later.id);
      expect(engine.isExportScheduled, isTrue);
      await engine.exportImmediately();

      await recorder.delete(mealsRecord.id);
      expect(engine.isExportScheduled, isTrue);
      await engine.exportImmediately();

      await recorder.relabel(mealsRecord.id, meals.id);
      expect(engine.isExportScheduled, isTrue);
      await engine.exportImmediately();
    });
  });

  group('MidnightSplit', () {
    late int lapStart;

    Future<void> startLapAt(String zone, int y, int mo, int d, int h) async {
      zoneId = zone;
      nowUtc = wallMs(zone, y, mo, d, h);
      await recorder.initialize();
      lapStart = recorder.lap!.startedAtEpochMs;
    }

    test('closes the Lap and reopens it at local midnight', () async {
      await startLapAt('America/Los_Angeles', 2026, 6, 1, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      await recorder.applyMidnightSplits();

      final midnight = wallMs(zoneId, 2026, 6, 2, 0);
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(1));
      final split = records.single;
      expect(split.activityId, isNull);
      expect(split.isMidnightSplit, isTrue);
      expect(split.startedAtEpochMs, lapStart);
      expect(split.endedAtEpochMs, midnight);
      expect(split.durationMs, 2 * hourMs);
      expect(split.timezoneId, 'America/Los_Angeles');
      expect(split.endTimezoneId, 'America/Los_Angeles');

      expect(recorder.lap!.startedAtEpochMs, midnight);
      expect(recorder.lap!.startedTimezoneId, 'America/Los_Angeles');
      expect(recorder.lap!.revision, 2);
    });

    test(
      'a label after midnight covers the whole span, one Record per Day',
      () async {
        await startLapAt('America/Los_Angeles', 2026, 6, 1, 22);

        zoneId = 'America/Los_Angeles';
        nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
        await recorder.applyMidnightSplits();

        nowUtc = wallMs(zoneId, 2026, 6, 2, 2);
        final closing = await recorder.label(
          sleep.id,
          comment: 'w/ Sam',
          tags: [travelTag.id],
        );

        final midnight = wallMs(zoneId, 2026, 6, 2, 0);
        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        expect(records, hasLength(2));

        final firstDay = records.first;
        expect(firstDay.activityId, sleep.id);
        expect(firstDay.comment, 'w/ Sam');
        expect(firstDay.tagIds, [travelTag.id]);
        expect(firstDay.startedAtEpochMs, lapStart);
        expect(firstDay.endedAtEpochMs, midnight);
        expect(firstDay.durationMs, 2 * hourMs);

        final secondDay = records.last;
        expect(secondDay.id, closing.id);
        expect(secondDay.activityId, sleep.id);
        expect(secondDay.comment, 'w/ Sam');
        expect(secondDay.tagIds, [travelTag.id]);
        expect(secondDay.startedAtEpochMs, midnight);
        expect(secondDay.endedAtEpochMs, nowUtc);
        expect(secondDay.durationMs, 2 * hourMs);
      },
    );

    test('undo restores the MidnightSplit half as Untracked', () async {
      await startLapAt('America/Los_Angeles', 2026, 6, 1, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      await recorder.applyMidnightSplits();

      nowUtc = wallMs(zoneId, 2026, 6, 2, 2);
      await recorder.label(sleep.id, comment: 'w/ Sam');

      expect(await recorder.undoLast(), isTrue);

      final midnight = wallMs(zoneId, 2026, 6, 2, 0);
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(1));
      expect(records.single.activityId, isNull);
      expect(records.single.isMidnightSplit, isTrue);
      expect(records.single.comment, isEmpty);
      expect(records.single.startedAtEpochMs, lapStart);
      expect(records.single.endedAtEpochMs, midnight);

      expect(recorder.lap!.startedAtEpochMs, midnight);
      expect(recorder.lap!.revision, 2);
    });

    test('a label does not absorb a Split the user made', () async {
      await startLapAt('America/Los_Angeles', 2026, 6, 1, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      await recorder.applyMidnightSplits();

      nowUtc = wallMs(zoneId, 2026, 6, 2, 1, 30);
      await recorder.split();

      nowUtc = wallMs(zoneId, 2026, 6, 2, 2);
      await recorder.label(sleep.id);

      final midnight = wallMs(zoneId, 2026, 6, 2, 0);
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(3));
      expect(records[0].isMidnightSplit, isTrue);
      expect(records[0].activityId, isNull);
      expect(records[1].isMidnightSplit, isFalse);
      expect(records[1].activityId, isNull);
      expect(records[1].startedAtEpochMs, midnight);
      expect(records[1].endedAtEpochMs, wallMs(zoneId, 2026, 6, 2, 1, 30));
      expect(records[2].activityId, sleep.id);
      expect(records[2].durationMs, 30 * 60 * 1000);
    });

    test('initialize applies every midnight missed while closed', () async {
      await startLapAt('America/Los_Angeles', 2026, 6, 1, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 4, 9);

      final reopened = DayRecorder(
        database: db,
        nowUtcMs: () => nowUtc,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => zoneId,
        autoSplitAtMidnight: false,
      );
      addTearDown(reopened.dispose);

      await reopened.initialize();

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(3));
      expect(records.map((r) => r.isMidnightSplit), everyElement(isTrue));
      expect(records.map((r) => r.activityId), everyElement(isNull));
      expect(records[0].durationMs, 2 * hourMs);
      expect(records[1].durationMs, 24 * hourMs);
      expect(records[2].durationMs, 24 * hourMs);
      expect(records.last.endedAtEpochMs, wallMs(zoneId, 2026, 6, 4, 0));
      expect(reopened.lap!.startedAtEpochMs, wallMs(zoneId, 2026, 6, 4, 0));
    });

    test('a DST day totals its real 23 hours', () async {
      await startLapAt('America/Los_Angeles', 2026, 3, 7, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 3, 9, 2);
      await recorder.applyMidnightSplits();

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(2));
      expect(records[0].durationMs, 2 * hourMs);
      expect(records[1].durationMs, 23 * hourMs);
      expect(recorder.lap!.startedAtEpochMs, wallMs(zoneId, 2026, 3, 9, 0));
    });

    test('a DST day totals its real 25 hours', () async {
      await startLapAt('America/Los_Angeles', 2026, 10, 31, 22);

      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 11, 2, 2);
      await recorder.applyMidnightSplits();

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(2));
      expect(records[0].durationMs, 2 * hourMs);
      expect(records[1].durationMs, 25 * hourMs);
    });

    test('midnight uses the zone in effect at that moment', () async {
      await startLapAt('America/Los_Angeles', 2026, 6, 1, 20);

      // The user is in Tokyo by the time the next midnight arrives.
      zoneId = 'Asia/Tokyo';
      nowUtc = wallMs(zoneId, 2026, 6, 3, 1);
      await recorder.applyMidnightSplits();

      final midnight = wallMs(zoneId, 2026, 6, 3, 0);
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(1));
      final split = records.single;
      expect(split.endedAtEpochMs, midnight);
      expect(split.durationMs, 12 * hourMs);
      expect(split.timezoneId, 'America/Los_Angeles');
      expect(split.endTimezoneId, 'Asia/Tokyo');
      expect(recorder.lap!.startedAtEpochMs, midnight);
      expect(recorder.lap!.startedTimezoneId, 'Asia/Tokyo');
    });
  });

  group('Review fixes', () {
    /// Records 22:00 → 00:00 → 01:00 as Sleep and 01:00 → 02:00 as Meals in
    /// Los Angeles, so one Boundary sits on midnight.
    Future<List<Record>> recordAcrossMidnight() async {
      zoneId = 'America/Los_Angeles';
      nowUtc = wallMs(zoneId, 2026, 6, 1, 22);
      await recorder.initialize();
      nowUtc = wallMs(zoneId, 2026, 6, 2, 1);
      await recorder.label(sleep.id);
      nowUtc = wallMs(zoneId, 2026, 6, 2, 2);
      await recorder.label(meals.id);
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(3));
      expect(records[0].endedAtEpochMs, wallMs(zoneId, 2026, 6, 2, 0));
      return records;
    }

    test('moveBoundary refuses to carry a Record across midnight', () async {
      final records = await recordAcrossMidnight();
      final beforeMidnight = records[0];
      final afterMidnight = records[1];

      // The Record ending at midnight would grow past it.
      expect(
        () => recorder.moveBoundary(
          beforeMidnight.id,
          wallMs(zoneId, 2026, 6, 2, 0, 30),
        ),
        throwsA(isA<RecordEditRefused>()),
      );
      // The Record starting at midnight would begin the evening before.
      expect(
        () => recorder.moveBoundary(
          beforeMidnight.id,
          wallMs(zoneId, 2026, 6, 1, 23, 30),
        ),
        throwsA(isA<RecordEditRefused>()),
      );
      expect(
        await db.getRecords(orderBy: 'started_at_epoch_ms ASC'),
        equals(records),
      );

      // A Boundary inside one Day still moves.
      final moved = await recorder.moveBoundary(
        afterMidnight.id,
        wallMs(zoneId, 2026, 6, 2, 1, 30),
      );
      expect(moved.endedAtEpochMs, wallMs(zoneId, 2026, 6, 2, 1, 30));
    });

    test('merge refuses Records that meet at midnight', () async {
      final records = await recordAcrossMidnight();

      expect(
        () => recorder.merge(records[0].id, records[1].id),
        throwsA(isA<RecordEditRefused>()),
      );
      expect(
        await db.getRecords(orderBy: 'started_at_epoch_ms ASC'),
        equals(records),
      );

      final merged = await recorder.merge(records[1].id, records[2].id);
      expect(merged.startedAtEpochMs, wallMs(zoneId, 2026, 6, 2, 0));
      expect(merged.endedAtEpochMs, wallMs(zoneId, 2026, 6, 2, 2));
    });

    test(
      'a clock moved back never writes a Record ending before it starts',
      () async {
        await recorder.initialize();
        nowUtc += 60000;
        await recorder.label(sleep.id);
        final lapStart = recorder.lap!.startedAtEpochMs;

        nowUtc = lapStart - 120000;
        final closing = await recorder.label(meals.id);

        expect(closing.startedAtEpochMs, lapStart);
        expect(closing.endedAtEpochMs, lapStart);
        expect(closing.durationMs, 0);
        expect(recorder.lap!.startedAtEpochMs, lapStart);

        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        for (final record in records) {
          expect(
            record.endedAtEpochMs,
            greaterThanOrEqualTo(record.startedAtEpochMs),
          );
        }
        expect(records.last.endedAtEpochMs, recorder.lap!.startedAtEpochMs);
      },
    );

    test('relabel initializes the recorder like every other edit', () async {
      await recorder.initialize();
      nowUtc += 60000;
      final record = await recorder.label(sleep.id);

      final reopened = DayRecorder(
        database: db,
        nowUtcMs: () => nowUtc,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => zoneId,
      );
      addTearDown(reopened.dispose);
      expect(reopened.lap, isNull);

      await reopened.relabel(record.id, meals.id);
      expect(reopened.lap, isNotNull);
      expect(reopened.lap!.startedAtEpochMs, record.endedAtEpochMs);
    });

    test('annotate edits comment and tags and schedules an export', () async {
      final exportDir = await Directory.systemTemp.createTemp('tempo-notes');
      addTearDown(() => exportDir.delete(recursive: true));
      final engine = CsvExportEngine(database: db, exportDirectory: exportDir);
      addTearDown(engine.dispose);
      recorder.attachExportEngine(engine);

      await recorder.initialize();
      nowUtc += 60000;
      final record = await recorder.label(sleep.id);
      await engine.exportImmediately();
      expect(engine.isExportScheduled, isFalse);

      final updated = await recorder.annotate(
        record.id,
        comment: 'w/ Sam',
        tagIds: [travelTag.id],
      );
      expect(engine.isExportScheduled, isTrue);

      final stored = await db.getRecordById(record.id);
      expect(stored!.comment, 'w/ Sam');
      expect(stored.tagIds, [travelTag.id]);
      expect(stored.activityId, sleep.id);
      expect(stored.startedAtEpochMs, record.startedAtEpochMs);
      expect(stored.endedAtEpochMs, record.endedAtEpochMs);
      expect(updated, equals(stored));
      await engine.exportImmediately();
    });

    test('a legacy Lap without a zone reads the injected zone', () async {
      await db.setLap(
        Lap(startedAtEpochMs: nowUtc, startedTimezoneId: '', revision: 1),
      );
      zoneId = 'Asia/Kolkata';
      await recorder.initialize();

      expect(recorder.lapStartTimezoneId, 'Asia/Kolkata');
    });

    test('durationMs is always end - start, whatever was stored', () {
      final record = Record.fromMap({
        'id': 'rec-paused',
        'activity_id': sleep.id,
        'started_at_epoch_ms': 1000,
        'ended_at_epoch_ms': 61000,
        'duration_ms': 30000,
        'timezone_id': 'UTC',
        'created_at_epoch_ms': 0,
        'updated_at_epoch_ms': 0,
      });
      expect(record.durationMs, 60000);
      expect(record.toMap()['duration_ms'], 60000);
    });
  });
}
