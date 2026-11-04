import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';

/// A version-1 database as shipped before Records carried an end zone.
const String _v1Activities = '''
CREATE TABLE activities (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    color_hex TEXT NOT NULL DEFAULT '#4CAF50',
    icon_name TEXT NOT NULL DEFAULT 'schedule',
    is_pinned INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v1Records = '''
CREATE TABLE records (
    id TEXT PRIMARY KEY NOT NULL,
    activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL,
    ended_at_epoch_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    timezone_id TEXT NOT NULL,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v1RecordTags = '''
CREATE TABLE record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''';

const String _v1ActiveTimer = '''
CREATE TABLE active_timer (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    activity_id TEXT NOT NULL REFERENCES activities(id),
    started_at_epoch_ms INTEGER NOT NULL,
    is_paused INTEGER NOT NULL DEFAULT 0,
    paused_at_epoch_ms INTEGER DEFAULT NULL,
    accumulated_pause_ms INTEGER NOT NULL DEFAULT 0,
    current_comment TEXT NOT NULL DEFAULT '',
    initial_tags_json TEXT NOT NULL DEFAULT '[]',
    last_heartbeat_epoch_ms INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1
);
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tempo-migration-test');
    dbPath = p.join(tempDir.path, 'tempo.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // Recent instants, so the gap fill and the running timer span only a few
  // Days once they are split at midnight.
  final base = DateTime.now().toUtc().millisecondsSinceEpoch - 3 * 3600000;
  final timerStart = base + 2000;

  Future<void> createV1Database() async {
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(_v1Activities);
          await db.execute(_v1Records);
          await db.execute(_v1RecordTags);
          await db.execute(_v1ActiveTimer);
        },
      ),
    );
    await db.insert('activities', {
      'id': 'act',
      'name': 'Transit',
      'created_at_epoch_ms': 1,
      'updated_at_epoch_ms': 1,
    });
    for (final entry in {
      'rec-pst': 'PST',
      'rec-jst': 'JST',
      'rec-cst': 'CST',
      'rec-unknown': 'Not/AZone',
      'rec-iana': 'America/Los_Angeles',
    }.entries) {
      await db.insert('records', {
        'id': entry.key,
        'activity_id': 'act',
        'started_at_epoch_ms': base,
        'ended_at_epoch_ms': base + 1000,
        'duration_ms': 1000,
        'timezone_id': entry.value,
        'created_at_epoch_ms': base,
        'updated_at_epoch_ms': base + 1000,
      });
    }
    await db.insert('active_timer', {
      'id': 1,
      'activity_id': 'act',
      'started_at_epoch_ms': timerStart,
      'last_heartbeat_epoch_ms': timerStart + 1000,
    });
    await db.close();
  }

  test(
    'upgrading backfills end zones and maps abbreviations to IANA',
    () async {
      await createV1Database();

      final db = await TempoDatabase.open(path: dbPath);
      addTearDown(db.close);

      expect(TempoDatabase.databaseVersion, 9);

      final pst = await db.getRecordById('rec-pst');
      expect(pst!.timezoneId, 'America/Los_Angeles');
      expect(pst.endTimezoneId, 'America/Los_Angeles');

      final jst = await db.getRecordById('rec-jst');
      expect(jst!.timezoneId, 'Asia/Tokyo');
      expect(jst.endTimezoneId, 'Asia/Tokyo');

      final cst = await db.getRecordById('rec-cst');
      expect(cst!.timezoneId, 'America/Chicago');

      // Unresolvable ids keep their stored value and still get an end zone.
      final unknown = await db.getRecordById('rec-unknown');
      expect(unknown!.timezoneId, 'Not/AZone');
      expect(unknown.endTimezoneId, 'Not/AZone');

      // Already-IANA rows are untouched.
      final iana = await db.getRecordById('rec-iana');
      expect(iana!.timezoneId, 'America/Los_Angeles');
      expect(iana.endTimezoneId, 'America/Los_Angeles');
    },
  );

  test(
    'upgrading closes a running timer and opens the Lap at its end',
    () async {
      await createV1Database();

      final db = await TempoDatabase.open(path: dbPath);
      addTearDown(db.close);

      final lap = await db.getLap();
      expect(lap, isNotNull);
      expect(lap!.startedTimezoneId, isNotEmpty);

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      // The running timer is closed up to the Lap, one Record per Day.
      final timerParts = records
          .where(
            (r) => r.activityId == 'act' && r.startedAtEpochMs >= timerStart,
          )
          .toList();
      expect(timerParts, isNotEmpty);
      expect(timerParts.first.startedAtEpochMs, equals(timerStart));
      expect(timerParts.last.endedAtEpochMs, equals(lap.startedAtEpochMs));
      for (var i = 1; i < timerParts.length; i++) {
        expect(
          timerParts[i].startedAtEpochMs,
          equals(timerParts[i - 1].endedAtEpochMs),
        );
      }
    },
  );
}
