import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/import/stt_import_service.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late TempoDatabase db;

  setUp(() async {
    db = await TempoDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('SttImportService', () {
    test('Catalog Only import upserts categories and activities without creating records', () async {
      final service = SttImportService(
        database: db,
        getTimezoneId: () => 'UTC',
        nowUtcMs: () => 1700000000000,
      );

      const backupContent = '''
app simple time tracker
category\t1\tSpiritual\t3\t\t
category\t2\tEssentials\t7\t\t
typeCategory\t10\t1
typeCategory\t11\t2
recordType\t10\tMorning Time\tic_lightbulb_outline_24px\t3\t0\t\t\t\t\t\t0\t
recordType\t11\tLunch\tic_restaurant_24px\t7\t0\t\t\t\t\t\t0\t
record\t1\t10\t1699990000000\t1699991000000\tNote\t
''';

      final result = await service.import(
        content: backupContent,
        scope: SttImportScope.catalogOnly,
      );

      expect(result.categoriesImported, equals(2));
      expect(result.activitiesImported, equals(2));
      expect(result.recordsImported, equals(0));
      expect(result.syntheticRecordsCreated, equals(0));

      final categories = await db.getCategories();
      expect(categories.length, equals(2));
      expect(
        categories.map((c) => c.name),
        containsAll(['Spiritual', 'Essentials']),
      );

      final activities = await db.getAllActivities();
      expect(activities.length, equals(2));
      final morning = activities.firstWhere((a) => a.name == 'Morning Time');
      final spiritual = categories.firstWhere((c) => c.name == 'Spiritual');
      expect(morning.categoryId, equals(spiritual.id));

      final records = await db.getRecords();
      expect(records, isEmpty);
    });

    test(
      'Full History import synthesizes untracked gaps and splits at midnight',
      () async {
        // Day 1: 1700006400000 is 2023-11-15 00:00:00 UTC
        const day1Midnight = 1700006400000;
        // Interval 1: 01:00 to 02:00 (3600000 to 7200000 after midnight)
        final start1 = day1Midnight + 3600000;
        final end1 = day1Midnight + 7200000;
        // Interval 2: 04:00 to 05:00 (14400000 to 18000000 after midnight)
        final start2 = day1Midnight + 14400000;
        final end2 = day1Midnight + 18000000;
        // Lap starts at 06:00 (21600000 after midnight)
        final lapStart = day1Midnight + 21600000;

        await db.setLap(
          Lap(
            id: 1,
            startedAtEpochMs: lapStart,
            startedTimezoneId: 'UTC',
            revision: 1,
          ),
        );

        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => lapStart + 10000,
        );

        final backupContent =
            '''
app simple time tracker
category\t1\tSpiritual\t3\t\t
typeCategory\t10\t1
recordType\t10\tPrayer\tic_sports_bar_24px\t3\t0\t\t\t\t\t\t0\t
record\t1\t10\t$start1\t$end1\tPrayer 1\t
record\t2\t10\t$start2\t$end2\tPrayer 2\t
''';

        final result = await service.import(
          content: backupContent,
          scope: SttImportScope.fullHistory,
        );

        expect(result.recordsImported, equals(2));
        // Gaps:
        // 1. [day1Midnight, start1] -> synthetic untracked (1 hour)
        // 2. [end1, start2] -> synthetic untracked (2 hours)
        // 3. [end2, lapStart] -> synthetic untracked (1 hour)
        expect(result.syntheticRecordsCreated, equals(3));

        final allRecords = await db.getRecords(
          orderBy: 'started_at_epoch_ms ASC',
        );
        expect(allRecords.length, equals(5));

        // 00:00 - 01:00: Untracked
        expect(allRecords[0].activityId, isNull);
        expect(allRecords[0].startedAtEpochMs, equals(day1Midnight));
        expect(allRecords[0].endedAtEpochMs, equals(start1));

        // 01:00 - 02:00: Prayer 1
        expect(allRecords[1].activityId, isNotNull);
        expect(allRecords[1].startedAtEpochMs, equals(start1));
        expect(allRecords[1].endedAtEpochMs, equals(end1));

        // 02:00 - 04:00: Untracked
        expect(allRecords[2].activityId, isNull);
        expect(allRecords[2].startedAtEpochMs, equals(end1));
        expect(allRecords[2].endedAtEpochMs, equals(start2));

        // 04:00 - 05:00: Prayer 2
        expect(allRecords[3].activityId, isNotNull);
        expect(allRecords[3].startedAtEpochMs, equals(start2));
        expect(allRecords[3].endedAtEpochMs, equals(end2));

        // 05:00 - 06:00: Untracked (up to Lap)
        expect(allRecords[4].activityId, isNull);
        expect(allRecords[4].startedAtEpochMs, equals(end2));
        expect(allRecords[4].endedAtEpochMs, equals(lapStart));
      },
    );

    test('Existing Tempo records take absolute precedence over imported colliding intervals', () async {
      const dayMidnight = 1700006400000;
      final start = dayMidnight + 3600000; // 01:00
      final end = dayMidnight + 7200000; // 02:00
      final lapStart = dayMidnight + 10800000; // 03:00

      await db.setLap(
        Lap(
          id: 1,
          startedAtEpochMs: lapStart,
          startedTimezoneId: 'UTC',
          revision: 1,
        ),
      );

      // Pre-existing Tempo record: 01:00 - 02:00
      final existingActivity = Activity(
        id: 'act-existing',
        name: 'Work',
        createdAtEpochMs: dayMidnight,
        updatedAtEpochMs: dayMidnight,
      );
      await db.insertActivity(existingActivity);

      final existingRecord = Record(
        id: 'rec-existing',
        activityId: 'act-existing',
        startedAtEpochMs: start,
        endedAtEpochMs: end,
        comment: 'Existing work',
        timezoneId: 'UTC',
        createdAtEpochMs: dayMidnight,
        updatedAtEpochMs: dayMidnight,
      );
      await db.insertRecord(existingRecord);

      final service = SttImportService(
        database: db,
        getTimezoneId: () => 'UTC',
        nowUtcMs: () => lapStart + 5000,
      );

      // Import interval that collides directly with 01:00 - 02:00
      final collidingBackup =
          '''
app simple time tracker
category\t1\tSpiritual\t3\t\t
typeCategory\t10\t1
recordType\t10\tPrayer\tic_sports_bar_24px\t3\t0\t\t\t\t\t\t0\t
record\t1\t10\t$start\t$end\tConflicting prayer\t
''';

      final result = await service.import(
        content: collidingBackup,
        scope: SttImportScope.fullHistory,
      );

      expect(result.skippedDueToCollision, equals(1));
      expect(result.recordsImported, equals(0));

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      // Should have:
      // [dayMidnight, start] -> Untracked
      // [start, end] -> Existing Work record preserved!
      // [end, lapStart] -> Untracked
      expect(records.length, equals(3));
      expect(records[1].id, equals('rec-existing'));
      expect(records[1].activityId, equals('act-existing'));
      expect(records[1].comment, equals('Existing work'));
    });

    test(
      'importing the same history twice does not duplicate gap Records',
      () async {
        const dayMidnight = 1700006400000;
        final start = dayMidnight + 3600000; // 01:00
        final end = dayMidnight + 7200000; // 02:00
        final lapStart = dayMidnight + 10800000; // 03:00

        await db.setLap(
          Lap(
            id: 1,
            startedAtEpochMs: lapStart,
            startedTimezoneId: 'UTC',
            revision: 1,
          ),
        );

        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => lapStart + 1000,
        );

        final backup =
            '''
app simple time tracker
recordType\t10\tPrayer\tic_sports_bar_24px\t3\t0\t\t\t\t\t\t0\t
record\t1\t10\t$start\t$end\tPrayer\t
''';

        await service.import(
          content: backup,
          scope: SttImportScope.fullHistory,
        );
        final first = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        expect(first.length, equals(3));

        final second = await service.import(
          content: backup,
          scope: SttImportScope.fullHistory,
        );
        expect(second.recordsImported, equals(0));
        expect(second.skippedDueToCollision, equals(1));

        final after = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        expect(
          after.length,
          equals(3),
          reason: 'the second import must not write a second gap Record',
        );
        for (var i = 1; i < after.length; i++) {
          expect(
            after[i].startedAtEpochMs,
            equals(after[i - 1].endedAtEpochMs),
            reason: 'Records must stay contiguous after a re-import',
          );
        }
      },
    );

    test(
      'an existing Record that starts before the import day is not overlapped',
      () async {
        const dayMidnight = 1700006400000;
        final lapStart = dayMidnight + 10 * 3600000; // 10:00

        await db.setLap(
          Lap(
            id: 1,
            startedAtEpochMs: lapStart,
            startedTimezoneId: 'UTC',
            revision: 1,
          ),
        );

        final activity = Activity(
          id: 'act-cross',
          name: 'Night',
          createdAtEpochMs: dayMidnight,
          updatedAtEpochMs: dayMidnight,
        );
        await db.insertActivity(activity);
        await db.insertRecord(
          Record(
            id: 'rec-cross',
            activityId: activity.id,
            // Starts on the previous day and runs into the import window.
            startedAtEpochMs: dayMidnight - 3600000,
            endedAtEpochMs: dayMidnight + 9 * 3600000,
            timezoneId: 'UTC',
            createdAtEpochMs: dayMidnight,
            updatedAtEpochMs: dayMidnight,
          ),
        );

        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => lapStart + 1000,
        );

        final nestedStart = dayMidnight + 6 * 3600000; // 06:00
        final backup =
            '''
app simple time tracker
recordType\t10\tPrayer\tic_sports_bar_24px\t3\t0\t\t\t\t\t\t0\t
record\t1\t10\t$nestedStart\t${nestedStart + 370000}\tNested\t
''';

        final result = await service.import(
          content: backup,
          scope: SttImportScope.fullHistory,
        );

        expect(result.skippedDueToCollision, equals(1));
        expect(result.recordsImported, equals(0));

        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        expect(records.first.id, equals('rec-cross'));
        for (var i = 1; i < records.length; i++) {
          expect(
            records[i].startedAtEpochMs,
            equals(records[i - 1].endedAtEpochMs),
            reason: 'the crossing Record must not be overlapped',
          );
        }
      },
    );

    test(
      'Splits multi-day spans across local midnight into distinct records',
      () async {
        // 2023-11-15 00:00:00 UTC = 1700006400000
        const day1Midnight = 1700006400000;
        const day2Midnight = day1Midnight + 86400000; // 2023-11-16 00:00:00 UTC
        final start = day1Midnight + 22 * 3600000; // 22:00 on Day 1
        final end = day2Midnight + 2 * 3600000; // 02:00 on Day 2
        final lapStart = day2Midnight + 3 * 3600000; // 03:00 on Day 2

        await db.setLap(
          Lap(
            id: 1,
            startedAtEpochMs: lapStart,
            startedTimezoneId: 'UTC',
            revision: 1,
          ),
        );

        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => lapStart + 1000,
        );

        final multiDayBackup =
            '''
app simple time tracker
recordType\t10\tSleep\tic_airline_seat_individual_suite_24px\t7\t0\t\t\t\t\t\t0\t
record\t1\t10\t$start\t$end\tOvernight sleep\t
''';

        final result = await service.import(
          content: multiDayBackup,
          scope: SttImportScope.fullHistory,
        );

        // The interval was split into 2 records across midnight
        expect(result.recordsImported, equals(2));

        final records = await db.getRecords(
          trackedOnly: true,
          orderBy: 'started_at_epoch_ms ASC',
        );
        expect(records.length, equals(2));
        // First part: 22:00 -> 00:00 midnight
        expect(records[0].startedAtEpochMs, equals(start));
        expect(records[0].endedAtEpochMs, equals(day2Midnight));
        expect(records[0].isMidnightSplit, isTrue);

        // Second part: 00:00 -> 02:00
        expect(records[1].startedAtEpochMs, equals(day2Midnight));
        expect(records[1].endedAtEpochMs, equals(end));
        expect(records[1].isMidnightSplit, isFalse);
      },
    );

    test('Full History import imports intervals across lapStart and advances the open Lap', () async {
      // Day midnight: 1700006400000 is 2023-11-15 00:00:00 UTC
      const dayMidnight = 1700006400000;
      // Existing open Lap started earlier today at 02:00
      final lapStart = dayMidnight + 7200000; // 02:00
      // Imported record 1: 01:00 to 03:00 (crosses lapStart)
      final start1 = dayMidnight + 3600000;
      final end1 = dayMidnight + 10800000;
      // Imported record 2: 04:00 to 05:00 (starts strictly after lapStart)
      final start2 = dayMidnight + 14400000;
      final end2 = dayMidnight + 18000000;
      // Current wall clock: 06:00
      final now = dayMidnight + 21600000;

      await db.setLap(
        Lap(
          id: 1,
          startedAtEpochMs: lapStart,
          startedTimezoneId: 'UTC',
          revision: 1,
        ),
      );

      final service = SttImportService(
        database: db,
        getTimezoneId: () => 'UTC',
        nowUtcMs: () => now,
      );

      final backupContent =
          '''
app simple time tracker
category\t1\tProductivity\t3\t\t
typeCategory\t10\t1
recordType\t10\tCoding\tic_computer_24px\t3\t0\t\t\t\t\t\t0\t
record\t1\t10\t$start1\t$end1\tMorning coding\t
record\t2\t10\t$start2\t$end2\tAfternoon coding\t
''';

      final result = await service.import(
        content: backupContent,
        scope: SttImportScope.fullHistory,
      );

      expect(result.recordsImported, equals(2));

      // Check open Lap has been advanced to latestCeiling (end2)
      final updatedLap = await db.getLap();
      expect(updatedLap, isNotNull);
      expect(updatedLap!.startedAtEpochMs, equals(end2));

      // Check all records including synthetic gaps
      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      // Gaps + records:
      // 1. [00:00, 01:00] Untracked
      // 2. [01:00, 03:00] Coding 1
      // 3. [03:00, 04:00] Untracked
      // 4. [04:00, 05:00] Coding 2
      // (Lap covers 05:00 to now)
      expect(records.length, equals(4));

      expect(records[0].activityId, isNull);
      expect(records[0].startedAtEpochMs, equals(dayMidnight));
      expect(records[0].endedAtEpochMs, equals(start1));

      expect(records[1].activityId, isNotNull);
      expect(records[1].startedAtEpochMs, equals(start1));
      expect(records[1].endedAtEpochMs, equals(end1));
      expect(records[1].comment, equals('Morning coding'));

      expect(records[2].activityId, isNull);
      expect(records[2].startedAtEpochMs, equals(end1));
      expect(records[2].endedAtEpochMs, equals(start2));

      expect(records[3].activityId, isNotNull);
      expect(records[3].startedAtEpochMs, equals(start2));
      expect(records[3].endedAtEpochMs, equals(end2));
      expect(records[3].comment, equals('Afternoon coding'));
    });

    test(
      'CSV import with record tags creates Tag and associates in record_tags',
      () async {
        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => 1700000000000,
        );

        const csvContent = '''"activity name","time started","time ended","comment","categories","record tags","duration","duration minutes"
"Meeting","2023-11-14 10:00:00","2023-11-14 11:00:00","1:1 sync","Work","Contact, Important","01:00:00","60"
''';

        final result = await service.import(
          content: csvContent,
          scope: SttImportScope.fullHistory,
        );

        expect(result.recordsImported, equals(1));

        // Verify tags created; Contact is marked so later Records that name
        // someone are tagged automatically.
        final contactTag = await db.getTagByName('Contact');
        expect(contactTag, isNotNull);
        expect(contactTag!.name, equals('Contact'));
        expect(contactTag.colorHex, equals('#9E9E9E'));
        expect(contactTag.isContact, isTrue);

        final importantTag = await db.getTagByName('Important');
        expect(importantTag, isNotNull);
        expect(importantTag!.name, equals('Important'));
        expect(importantTag.isContact, isFalse);

        // Verify record is associated with both tags
        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        final meetingRecord = records.firstWhere((r) => r.activityId != null);
        expect(meetingRecord.comment, equals('1:1 sync'));
        expect(
          meetingRecord.tagIds,
          containsAll([contactTag.id, importantTag.id]),
        );

        // Verify database junction table record_tags has rows
        final junctionRows = await db.db.query(
          'record_tags',
          where: 'record_id = ?',
          whereArgs: [meetingRecord.id],
        );
        expect(junctionRows.length, equals(2));
        final tagIdsInDb = junctionRows
            .map((r) => r['tag_id'] as String)
            .toList();
        expect(tagIdsInDb, containsAll([contactTag.id, importantTag.id]));
      },
    );

    test(
      'a comment that names someone creates and attaches the Contact tag',
      () async {
        final service = SttImportService(
          database: db,
          getTimezoneId: () => 'UTC',
          nowUtcMs: () => 1700000000000,
        );

        const csvContent = '''"activity name","time started","time ended","comment","categories","record tags","duration","duration minutes"
"Lunch","2023-11-14 10:00:00","2023-11-14 11:00:00","Lunch w/ Sam","Work","","01:00:00","60"
''';

        final result = await service.import(
          content: csvContent,
          scope: SttImportScope.fullHistory,
        );

        expect(result.recordsImported, equals(1));

        final contactTag = await db.getTagByName('Contact');
        expect(contactTag, isNotNull);
        expect(contactTag!.isContact, isTrue);

        final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
        final lunch = records.firstWhere((r) => r.comment == 'Lunch w/ Sam');
        expect(lunch.tagIds, contains(contactTag.id));
      },
    );
  });
}
