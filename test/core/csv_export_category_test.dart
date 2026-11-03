import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/export/csv_export_engine.dart';
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

  DateTime fixedEpochToDateTime(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);

  setUp(() async {
    db = await TempoDatabase.openInMemory();
    tempDir = await Directory.systemTemp.createTemp('tempo-csv-cat-test');
    targetFile = File(p.join(tempDir.path, 'stt_records_automatic.csv'));
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('formats record row with category in 5th column', () {
    final engine = CsvExportEngine(
      database: db,
      targetFile: targetFile,
      epochToDateTime: fixedEpochToDateTime,
    );

    final record = Record(
      id: 'rec-1',
      activityId: 'act-1',
      startedAtEpochMs: 1700000000000,
      endedAtEpochMs: 1700003600000,
      comment: 'Sample note',
      timezoneId: 'UTC',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );

    final row = engine.formatRecordRow(
      record: record,
      activityName: 'Coding',
      tagNames: ['Work'],
      categories: 'Productivity',
    );

    expect(
      row,
      '"Coding",2023-11-14 22:13:20,2023-11-14 23:13:20,"Sample note","Productivity","Work",1:0:0,60\n',
    );
  });

  test('generateCsvString resolves and outputs category name for categorized activity', () async {
    final engine = CsvExportEngine(
      database: db,
      targetFile: targetFile,
      epochToDateTime: fixedEpochToDateTime,
    );

    final category = Category(
      id: 'cat-prod',
      name: 'Productivity',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );
    await db.upsertCategory(category);

    final activityCategorized = Activity(
      id: 'act-1',
      name: 'Coding',
      categoryId: 'cat-prod',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );
    await db.insertActivity(activityCategorized);

    final activityUncategorized = Activity(
      id: 'act-2',
      name: 'Lunch',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );
    await db.insertActivity(activityUncategorized);

    final record1 = Record(
      id: 'rec-1',
      activityId: 'act-1',
      startedAtEpochMs: 1700000000000,
      endedAtEpochMs: 1700001800000,
      timezoneId: 'UTC',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );
    final record2 = Record(
      id: 'rec-2',
      activityId: 'act-2',
      startedAtEpochMs: 1700001800000,
      endedAtEpochMs: 1700003600000,
      timezoneId: 'UTC',
      createdAtEpochMs: 1700000000000,
      updatedAtEpochMs: 1700000000000,
    );
    await db.insertRecord(record1);
    await db.insertRecord(record2);

    final csvContent = await engine.generateCsvString();
    final lines = csvContent.trim().split('\n');

    expect(lines.length, 3);
    expect(
      lines[0],
      'activity name,time started,time ended,comment,categories,record tags,duration,duration minutes',
    );
    expect(
      lines[1],
      '"Coding",2023-11-14 22:13:20,2023-11-14 22:43:20,"","Productivity","",0:30:0,30',
    );
    expect(
      lines[2],
      '"Lunch",2023-11-14 22:43:20,2023-11-14 23:13:20,"","","",0:30:0,30',
    );
  });
}
