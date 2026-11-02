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

  setUp(() async {
    db = await TempoDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  // Simulated device zones: the export must not depend on either of them.
  DateTime deviceInUtc(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  DateTime deviceInTokyo(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms + 9 * 3600000, isUtc: true);

  CsvExportEngine engineFor(DateTime Function(int) deviceZone) {
    final engine = CsvExportEngine(
      database: db,
      targetFile: File(p.join(Directory.systemTemp.path, 'unused.csv')),
      epochToDateTime: deviceZone,
    );
    addTearDown(engine.dispose);
    return engine;
  }

  Record recordAt(DateTime startUtc, Duration length, String timezoneId) {
    final start = startUtc.millisecondsSinceEpoch;
    final end = start + length.inMilliseconds;
    return Record(
      id: 'rec-tz',
      activityId: 'act',
      startedAtEpochMs: start,
      endedAtEpochMs: end,
      durationMs: length.inMilliseconds,
      timezoneId: timezoneId,
      createdAtEpochMs: end,
      updatedAtEpochMs: end,
    );
  }

  String rowFor(CsvExportEngine engine, Record record) =>
      engine.formatRecordRow(
        record: record,
        activityName: 'Flight',
        tagNames: const [],
      );

  test('rows are identical regardless of the current device zone', () {
    // 2026-03-01 10:00 PST.
    final record = recordAt(
      DateTime.utc(2026, 3, 1, 18),
      const Duration(hours: 6),
      'America/Los_Angeles',
    );

    final fromUtcDevice = rowFor(engineFor(deviceInUtc), record);
    final fromTokyoDevice = rowFor(engineFor(deviceInTokyo), record);

    expect(fromTokyoDevice, equals(fromUtcDevice));
    expect(
      fromUtcDevice,
      equals(
        '"Flight",2026-03-01 10:00:00,2026-03-01 16:00:00,"","","",6:0:0,360\n',
      ),
    );
  });

  test('a 6h record crossing a DST change keeps a 6h wall-clock span', () {
    // 2026-03-08 00:00 PST; LA springs forward at 02:00 during the record.
    final record = recordAt(
      DateTime.utc(2026, 3, 8, 8),
      const Duration(hours: 6),
      'America/Los_Angeles',
    );

    expect(
      rowFor(engineFor(deviceInTokyo), record),
      equals(
        '"Flight",2026-03-08 00:00:00,2026-03-08 06:00:00,"","","",6:0:0,360\n',
      ),
    );
  });

  test('legacy abbreviation zone ids resolve to their UTC offset', () {
    final start = DateTime.utc(2026, 7, 1, 12);
    const hour = Duration(hours: 1);
    final engine = engineFor(deviceInUtc);

    expect(
      rowFor(engine, recordAt(start, hour, 'PDT')),
      startsWith('"Flight",2026-07-01 05:00:00,2026-07-01 06:00:00,'),
    );
    expect(
      rowFor(engine, recordAt(start, hour, 'JST')),
      startsWith('"Flight",2026-07-01 21:00:00,2026-07-01 22:00:00,'),
    );
    expect(
      rowFor(engine, recordAt(start, hour, 'GMT+05:30')),
      startsWith('"Flight",2026-07-01 17:30:00,2026-07-01 18:30:00,'),
    );
  });

  test('unknown zone ids fall back to the device zone', () {
    final record = recordAt(
      DateTime.utc(2026, 7, 1, 12),
      const Duration(hours: 1),
      'Not/AZone',
    );

    expect(
      rowFor(engineFor(deviceInTokyo), record),
      startsWith('"Flight",2026-07-01 21:00:00,2026-07-01 22:00:00,'),
    );
  });
}
