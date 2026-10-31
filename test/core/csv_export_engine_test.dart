import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/export/csv_export_engine.dart';
import 'package:tempo/core/state/timer_state_machine.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late TempoDatabase db;
  late Directory tempDir;
  late File targetFile;

  // Fixed epoch time converter for completely deterministic UTC-based test assertions
  DateTime fixedEpochToDateTime(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);

  const testActivityCoding = Activity(
    id: 'act-coding',
    name: 'Coding',
    colorHex: '#2196F3',
    iconName: 'code',
    isPinned: true,
    sortOrder: 1,
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  const testActivityLunch = Activity(
    id: 'act-lunch',
    name: 'Lunch',
    colorHex: '#4CAF50',
    iconName: 'restaurant',
    isPinned: false,
    sortOrder: 2,
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  const testActivityQuotes = Activity(
    id: 'act-quotes',
    name: 'Reviewing "Deep Work"',
    colorHex: '#9C27B0',
    iconName: 'book',
    isPinned: false,
    sortOrder: 3,
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  const tagContact = Tag(
    id: 'tag-contact',
    name: 'Contact',
    colorHex: '#FF5722',
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  const tagImportant = Tag(
    id: 'tag-important',
    name: 'Important',
    colorHex: '#E91E63',
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  const tagClientQuotes = Tag(
    id: 'tag-quotes',
    name: 'VIP "Client"',
    colorHex: '#673AB7',
    createdAtEpochMs: 1700000000000,
    updatedAtEpochMs: 1700000000000,
  );

  setUp(() async {
    db = await TempoDatabase.openInMemory();
    await db.insertActivity(testActivityCoding);
    await db.insertActivity(testActivityLunch);
    await db.insertActivity(testActivityQuotes);
    await db.insertTag(tagContact);
    await db.insertTag(tagImportant);
    await db.insertTag(tagClientQuotes);

    tempDir = await Directory.systemTemp.createTemp('tempo_csv_test_');
    targetFile = File(p.join(tempDir.path, CsvExportEngine.defaultFileName));
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('CSV Schema Formatting & STT Parity', () {
    test('formats header exactly matching 8-column Simple Time Tracker schema',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final csvString = await engine.generateCsvString();
      final lines = csvString.split('\n');

      expect(lines.first, equals(CsvExportEngine.csvHeader));
      expect(
        lines.first,
        equals(
          'activity name,time started,time ended,comment,categories,record tags,duration,duration minutes',
        ),
      );
      // Header-only output ends with single empty trailing entry from split('\n')
      expect(lines.length, equals(2));
      expect(lines[1], isEmpty);
    });

    test('formats duration with unpadded integers matching STT quirks', () {
      // 0 ms -> 0:0:0
      expect(CsvExportEngine.formatDuration(0), equals('0:0:0'));
      expect(CsvExportEngine.formatDurationMinutes(0), equals(0));

      // 19 min 9 sec = 1,149,000 ms -> 0:19:9 and 19 min
      expect(CsvExportEngine.formatDuration(1149000), equals('0:19:9'));
      expect(CsvExportEngine.formatDurationMinutes(1149000), equals(19));

      // 1 hour flat = 3,600,000 ms -> 1:0:0 and 60 min
      expect(CsvExportEngine.formatDuration(3600000), equals('1:0:0'));
      expect(CsvExportEngine.formatDurationMinutes(3600000), equals(60));

      // 5 min flat = 300,000 ms -> 0:5:0 and 5 min
      expect(CsvExportEngine.formatDuration(300000), equals('0:5:0'));
      expect(CsvExportEngine.formatDurationMinutes(300000), equals(5));

      // 46 min 50 sec = 2,810,000 ms -> 0:46:50 and 46 min
      expect(CsvExportEngine.formatDuration(2810000), equals('0:46:50'));
      expect(CsvExportEngine.formatDurationMinutes(2810000), equals(46));

      // 25 hours 3 min 7 sec = 90,187,000 ms -> 25:3:7 and 1503 min
      expect(CsvExportEngine.formatDuration(90187000), equals('25:3:7'));
      expect(CsvExportEngine.formatDurationMinutes(90187000), equals(1503));
    });

    test('escapes and quotes string columns while keeping numeric/timestamps raw',
        () async {
      // 2025-09-17 11:46:37 UTC = 1758109597000 ms
      // 1 hour later = 1758113197000 ms
      final record = Record(
        id: 'rec-1',
        activityId: testActivityQuotes.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        comment: 'Discussed "Architecture" & plans\nw/ Abel',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
        tagIds: [tagContact.id, tagClientQuotes.id],
      );
      await db.insertRecord(record);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final csvString = await engine.generateCsvString();

      // Using RFC 4180 CSV decoder to inspect decoded fields
      final rows = Csv(autoDetect: false).decode(csvString);
      expect(rows.length, equals(2));

      final dataRow = rows[1];
      expect(dataRow[0], equals('Reviewing "Deep Work"'));
      expect(dataRow[1], equals('2025-09-17 11:46:37'));
      expect(dataRow[2], equals('2025-09-17 12:46:37'));
      expect(dataRow[3], equals('Discussed "Architecture" & plans\nw/ Abel'));
      expect(dataRow[4], equals('')); // Categories empty
      expect(dataRow[5], equals('Contact, VIP "Client"'));
      expect(dataRow[6], equals('1:0:0'));
      expect(dataRow[7], equals('60'));

      // Check exact raw serial representation of double quotes
      expect(
        csvString,
        contains(
          '"Reviewing ""Deep Work""",2025-09-17 11:46:37,2025-09-17 12:46:37,"Discussed ""Architecture"" & plans\nw/ Abel","","Contact, VIP ""Client""",1:0:0,60\n',
        ),
      );
    });

    test('serializes empty comments and empty tags as pair of double quotes',
        () async {
      final record = Record(
        id: 'rec-empty',
        activityId: testActivityCoding.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758110746000,
        durationMs: 1149000, // 19m 9s
        comment: '',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758110746000,
        updatedAtEpochMs: 1758110746000,
        tagIds: const [],
      );
      await db.insertRecord(record);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final csvString = await engine.generateCsvString();
      expect(
        csvString,
        contains('"Coding",2025-09-17 11:46:37,2025-09-17 12:05:46,"","","",0:19:9,19\n'),
      );
    });

    test('orders exported records chronologically by timeStarted ascending',
        () async {
      final recordLater = Record(
        id: 'rec-later',
        activityId: testActivityCoding.id,
        startedAtEpochMs: 1758200000000,
        endedAtEpochMs: 1758203600000,
        durationMs: 3600000,
        comment: 'Later session',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758203600000,
        updatedAtEpochMs: 1758203600000,
      );
      final recordEarlier = Record(
        id: 'rec-earlier',
        activityId: testActivityLunch.id,
        startedAtEpochMs: 1758100000000,
        endedAtEpochMs: 1758103600000,
        durationMs: 3600000,
        comment: 'Earlier session',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758103600000,
        updatedAtEpochMs: 1758103600000,
      );

      // Insert later record first into database
      await db.insertRecord(recordLater);
      await db.insertRecord(recordEarlier);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final csvString = await engine.generateCsvString();
      final rows = Csv(autoDetect: false).decode(csvString);

      expect(rows.length, equals(3)); // Header + 2 rows
      expect(rows[1][0], equals('Lunch')); // Earlier first
      expect(rows[2][0], equals('Coding')); // Later second
    });
  });

  group('BNPB Parser Compatibility & SHA-256 Fingerprint', () {
    test('generates CSV fully compatible with BNPB TimeTrackerParser ingestion',
        () async {
      // Record 1: Tagged with "Contact" -> Should be ingested by BNPB
      final contactRecord = Record(
        id: 'rec-contact',
        activityId: testActivityLunch.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        comment: 'w/ Abel',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
        tagIds: [tagContact.id],
      );

      // Record 2: Not tagged with "Contact" -> Skipped by BNPB
      final nonContactRecord = Record(
        id: 'rec-solo',
        activityId: testActivityCoding.id,
        startedAtEpochMs: 1758200000000,
        endedAtEpochMs: 1758203600000,
        durationMs: 3600000,
        comment: 'Solo work without tags',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758203600000,
        updatedAtEpochMs: 1758203600000,
        tagIds: const [],
      );

      // Record 3: Multi-tagged with "Contact, Important" and "with " marker
      final meetingRecord = Record(
        id: 'rec-meeting',
        activityId: testActivityLunch.id,
        startedAtEpochMs: 1758300000000,
        endedAtEpochMs: 1758303600000,
        durationMs: 3600000,
        comment: 'Kickoff with Alice Smith',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758303600000,
        updatedAtEpochMs: 1758303600000,
        tagIds: [tagContact.id, tagImportant.id],
      );

      await db.insertRecord(contactRecord);
      await db.insertRecord(nonContactRecord);
      await db.insertRecord(meetingRecord);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final csvContent = await engine.generateCsvString();

      // Simulate BNPB's exact parsing logic from TimeTrackerParser
      final rows = Csv(autoDetect: false).decode(csvContent);
      expect(rows, isNotEmpty);

      final headerRow =
          rows.first.map((e) => e.toString().trim().toLowerCase()).toList();
      final activityIdx = headerRow.indexOf('activity name');
      final startIdx = headerRow.indexOf('time started');
      final commentIdx = headerRow.indexOf('comment');
      final tagsIdx = headerRow.indexOf('record tags');
      final durationMinIdx = headerRow.indexOf('duration minutes');

      expect(activityIdx, isNot(-1));
      expect(startIdx, isNot(-1));
      expect(tagsIdx, isNot(-1));
      expect(commentIdx, isNot(-1));
      expect(durationMinIdx, isNot(-1));

      final stagedCandidates = <Map<String, dynamic>>[];
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        final tags = row[tagsIdx].toString();
        if (!tags.toLowerCase().contains('contact')) {
          continue; // Skipped, exactly like BNPB
        }

        final activityName = row[activityIdx].toString().trim();
        final timeStartedStr = row[startIdx].toString().trim();
        final comment = row[commentIdx].toString().trim();
        final durationStr = row[durationMinIdx].toString().trim();
        final durationMinutes = int.tryParse(durationStr);

        // Deterministic SHA-256 fingerprint matching BNPB:
        final raw =
            '$timeStartedStr|${durationMinutes ?? ''}|$activityName|$comment';
        final fingerprint = sha256.convert(utf8.encode(raw)).toString();

        stagedCandidates.add({
          'activityName': activityName,
          'timeStarted': timeStartedStr,
          'comment': comment,
          'durationMinutes': durationMinutes,
          'fingerprint': fingerprint,
        });
      }

      // Exactly 2 of the 3 records should be staged
      expect(stagedCandidates.length, equals(2));

      // Candidate 1: Lunch w/ Abel
      expect(stagedCandidates[0]['activityName'], equals('Lunch'));
      expect(stagedCandidates[0]['comment'], equals('w/ Abel'));
      expect(stagedCandidates[0]['timeStarted'], equals('2025-09-17 11:46:37'));
      expect(stagedCandidates[0]['durationMinutes'], equals(60));

      final expectedFingerprint1 = sha256
          .convert(utf8.encode('2025-09-17 11:46:37|60|Lunch|w/ Abel'))
          .toString();
      expect(stagedCandidates[0]['fingerprint'], equals(expectedFingerprint1));

      // Candidate 2: Lunch Kickoff with Alice Smith
      expect(stagedCandidates[1]['activityName'], equals('Lunch'));
      expect(
        stagedCandidates[1]['comment'],
        equals('Kickoff with Alice Smith'),
      );
      expect(stagedCandidates[1]['durationMinutes'], equals(60));
    });

    test('reproducible SHA-256 deduplication fingerprint remains identical across exports',
        () async {
      final record = Record(
        id: 'rec-hash-check',
        activityId: testActivityLunch.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        comment: 'w/ Abel',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
        tagIds: [tagContact.id],
      );
      await db.insertRecord(record);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final export1 = await engine.exportImmediately();
      final content1 = await export1.readAsString();

      final export2 = await engine.exportImmediately();
      final content2 = await export2.readAsString();

      expect(content1, equals(content2));

      final rows1 = Csv(autoDetect: false).decode(content1);
      final raw1 =
          '${rows1[1][1]}|${rows1[1][7]}|${rows1[1][0]}|${rows1[1][3]}';
      final hash1 = sha256.convert(utf8.encode(raw1)).toString();

      final rows2 = Csv(autoDetect: false).decode(content2);
      final raw2 =
          '${rows2[1][1]}|${rows2[1][7]}|${rows2[1][0]}|${rows2[1][3]}';
      final hash2 = sha256.convert(utf8.encode(raw2)).toString();

      expect(hash1, equals(hash2));
    });
  });

  group('Atomic Write-Flush-Rename Pipeline', () {
    test('writes to sibling temporary file and atomically renames to target',
        () async {
      final record = Record(
        id: 'rec-atomic',
        activityId: testActivityCoding.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        comment: 'Atomic test',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
      );
      await db.insertRecord(record);

      var generatedUuid = 'test-uuid-1234';
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        generateUuid: () => generatedUuid,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final exported = await engine.exportImmediately();

      expect(await exported.exists(), isTrue);
      expect(exported.path, equals(targetFile.path));

      // Sibling temp file must NOT exist after successful atomic rename
      final expectedTempPath = p.join(
        tempDir.path,
        '.${CsvExportEngine.defaultFileName}.tmp.$generatedUuid',
      );
      expect(await File(expectedTempPath).exists(), isFalse);

      // Verify no other temporary files were left behind
      final tempFiles = tempDir
          .listSync()
          .where((f) => p.basename(f.path).startsWith('.'))
          .toList();
      expect(tempFiles, isEmpty);

      final content = await exported.readAsString();
      expect(content, contains('"Coding",2025-09-17 11:46:37'));
    });

    test('atomically replaces pre-existing file without leaving stale or corrupted bytes',
        () async {
      // Pre-populate target file with stale/corrupted content
      await targetFile.writeAsString('CORRUPT_STALE_DATA_LINE_1\nLINE_2');
      expect(await targetFile.readAsString(), contains('CORRUPT_STALE_DATA'));

      final record = Record(
        id: 'rec-replace',
        activityId: testActivityLunch.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        comment: 'Fresh data',
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
      );
      await db.insertRecord(record);

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final exported = await engine.exportImmediately();
      final content = await exported.readAsString();

      expect(content, isNot(contains('CORRUPT_STALE_DATA')));
      expect(content, contains('"Lunch",2025-09-17 11:46:37'));
      expect(content.startsWith(CsvExportEngine.csvHeader), isTrue);
    });

    test('automatically creates non-existent parent directories', () async {
      final nestedTarget = File(
        p.join(
          tempDir.path,
          'deeply',
          'nested',
          'folder',
          CsvExportEngine.defaultFileName,
        ),
      );
      expect(await nestedTarget.parent.exists(), isFalse);

      final engine = CsvExportEngine(
        database: db,
        targetFile: nestedTarget,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final exported = await engine.exportImmediately();
      expect(await exported.exists(), isTrue);
      expect(await nestedTarget.parent.exists(), isTrue);
    });

    test('cleans up temporary sibling file if serialization fails', () async {
      var generatedUuid = 'fail-uuid-5678';
      final expectedTempPath = p.join(
        tempDir.path,
        '.${CsvExportEngine.defaultFileName}.tmp.$generatedUuid',
      );

      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        generateUuid: () => generatedUuid,
        epochToDateTime: (_) => throw FormatException('Simulated crash'),
      );
      addTearDown(engine.dispose);

      final record = Record(
        id: 'rec-crash',
        activityId: testActivityCoding.id,
        startedAtEpochMs: 1758109597000,
        endedAtEpochMs: 1758113197000,
        durationMs: 3600000,
        timezoneId: 'UTC',
        createdAtEpochMs: 1758113197000,
        updatedAtEpochMs: 1758113197000,
      );
      await db.insertRecord(record);

      expect(() => engine.exportImmediately(), throwsA(isA<FormatException>()));

      // Temp file should not remain
      expect(await File(expectedTempPath).exists(), isFalse);
    });
  });

  group('Debounce & Mutex Concurrency Control', () {
    test('coalesces multiple rapid scheduleExport calls into a single write',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: const Duration(milliseconds: 100),
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      // Trigger multiple rapid schedule calls
      final f1 = engine.scheduleExport();
      final f2 = engine.scheduleExport();
      final f3 = engine.scheduleExport();

      expect(engine.isExportScheduled, isTrue);

      // All callers awaiting scheduleExport should resolve to the same exported File
      final results = await Future.wait([f1, f2, f3]);
      expect(results[0].path, equals(targetFile.path));
      expect(results[1].path, equals(targetFile.path));
      expect(results[2].path, equals(targetFile.path));

      expect(engine.isExportScheduled, isFalse);
      expect(await targetFile.exists(), isTrue);
    });

    test('zero-delay debounce exports immediately without timer delay',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: Duration.zero,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final file = await engine.scheduleExport();
      expect(await file.exists(), isTrue);
      expect(engine.isExportScheduled, isFalse);
    });

    test('exportImmediately cancels any pending debounced timer', () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: const Duration(seconds: 10),
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      final scheduledFuture = engine.scheduleExport();
      expect(engine.isExportScheduled, isTrue);

      // Immediately export without waiting 10 seconds
      final immediateFile = await engine.exportImmediately();

      expect(engine.isExportScheduled, isFalse);
      expect(await immediateFile.exists(), isTrue);

      // Scheduled future should have completed as well
      final scheduledFile = await scheduledFuture;
      expect(scheduledFile.path, equals(targetFile.path));
    });
  });

  group('TimerStateMachine Integration', () {
    test('timer stop automatically triggers debounced export to target CSV',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: Duration.zero, // Zero-delay for synchronous test
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      int mockTime = 1758109597000;
      final sm = TimerStateMachine(
        database: db,
        csvExportEngine: engine,
        nowUtcMs: () => mockTime,
        generateId: () => 'sm-rec-1',
        getTimezoneId: () => 'UTC',
      );
      addTearDown(sm.dispose);

      await sm.start(testActivityLunch.id, comment: 'w/ Abel');

      // Fast-forward 1 hour (3600000 ms)
      mockTime += 3600000;

      // Stop timer: triggers debounced export
      final stoppedRecord = await sm.stop();
      expect(stoppedRecord.id, equals('sm-rec-1'));

      // Verify file was written immediately
      expect(await targetFile.exists(), isTrue);
      final content = await targetFile.readAsString();
      expect(content, contains('"Lunch",2025-09-17 11:46:37'));
      expect(content, contains('"w/ Abel"'));
      expect(content, contains('1:0:0,60'));
    });

    test('timer switchActivity automatically triggers debounced export of committed record',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: Duration.zero,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      int mockTime = 1758109597000;
      final sm = TimerStateMachine(
        database: db,
        csvExportEngine: engine,
        nowUtcMs: () => mockTime,
        generateId: () => 'sm-rec-switch',
        getTimezoneId: () => 'UTC',
      );
      addTearDown(sm.dispose);

      await sm.start(testActivityLunch.id, comment: 'Quick lunch');

      // Fast-forward 30 minutes
      mockTime += 1800000;

      // Switch to Coding
      await sm.switchActivity(testActivityCoding.id, comment: 'Back to work');

      // The Lunch record should be committed and exported
      expect(await targetFile.exists(), isTrue);
      final content = await targetFile.readAsString();
      expect(content, contains('"Lunch"'));
      expect(content, contains('"Quick lunch"'));
      expect(content, contains('0:30:0,30'));
    });

    test('crash recovery truncateToHeartbeat automatically triggers debounced export',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: Duration.zero,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      int mockTime = 1758109597000;
      final sm = TimerStateMachine(
        database: db,
        csvExportEngine: engine,
        nowUtcMs: () => mockTime,
        generateId: () => 'sm-rec-recovery',
        getTimezoneId: () => 'UTC',
      );
      addTearDown(sm.dispose);

      await sm.start(testActivityCoding.id, comment: 'Session before crash');

      // Simulate 1 hour passing, then heartbeat
      mockTime += 3600000;
      await sm.tickHeartbeat();

      // Simulate abnormal crash gap (7 hours > 6 hour threshold)
      mockTime += 7 * 3600 * 1000;

      final session = await sm.checkCrashRecovery();
      expect(session, isNotNull);

      // Truncate to heartbeat
      final recoveredRecord = await session!.truncateToHeartbeat(
        finalComment: 'Session recovered',
      );
      expect(recoveredRecord.id, equals('sm-rec-recovery'));

      // Verify exported CSV has the recovered record
      expect(await targetFile.exists(), isTrue);
      final content = await targetFile.readAsString();
      expect(content, contains('"Coding"'));
      expect(content, contains('"Session recovered"'));
      expect(content, contains('1:0:0,60'));
    });

    test('attachExportEngine dynamically binds engine to existing state machine',
        () async {
      final engine = CsvExportEngine(
        database: db,
        targetFile: targetFile,
        debounceDuration: Duration.zero,
        epochToDateTime: fixedEpochToDateTime,
      );
      addTearDown(engine.dispose);

      int mockTime = 1758109597000;
      final sm = TimerStateMachine(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'sm-rec-dyn',
        getTimezoneId: () => 'UTC',
      );
      addTearDown(sm.dispose);

      expect(sm.csvExportEngine, isNull);
      sm.attachExportEngine(engine);
      expect(sm.csvExportEngine, equals(engine));

      await sm.start(testActivityLunch.id);
      mockTime += 1800000;
      await sm.stop();

      expect(await targetFile.exists(), isTrue);
      final content = await targetFile.readAsString();
      expect(content, contains('"Lunch"'));
    });
  });
}
