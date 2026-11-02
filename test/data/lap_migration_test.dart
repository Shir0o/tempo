import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';

/// A version-2 database as shipped before the Lap replaced `active_timer`.
const String _v2Activities = '''
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

const String _v2Tags = '''
CREATE TABLE tags (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v2Records = '''
CREATE TABLE records (
    id TEXT PRIMARY KEY NOT NULL,
    activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL,
    ended_at_epoch_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    timezone_id TEXT NOT NULL,
    end_timezone_id TEXT NOT NULL DEFAULT '',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v2RecordTags = '''
CREATE TABLE record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''';

const String _v2ActiveTimer = '''
CREATE TABLE active_timer (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    activity_id TEXT NOT NULL REFERENCES activities(id),
    started_at_epoch_ms INTEGER NOT NULL,
    started_timezone_id TEXT NOT NULL DEFAULT '',
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
    tempDir = await Directory.systemTemp.createTemp('tempo-lap-migration');
    dbPath = p.join(tempDir.path, 'tempo.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<Database> createV2Database() async {
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute(_v2Activities);
          await db.execute(_v2Tags);
          await db.execute(_v2Records);
          await db.execute(_v2RecordTags);
          await db.execute(_v2ActiveTimer);
        },
      ),
    );
    await db.insert('activities', {
      'id': 'act-sleep',
      'name': 'Sleep',
      'created_at_epoch_ms': 1,
      'updated_at_epoch_ms': 1,
    });
    await db.insert('tags', {
      'id': 'tag-travel',
      'name': 'Travel',
      'created_at_epoch_ms': 1,
      'updated_at_epoch_ms': 1,
    });
    await db.insert('records', {
      'id': 'rec-old',
      'activity_id': 'act-sleep',
      'started_at_epoch_ms': 1000,
      'ended_at_epoch_ms': 2000,
      'duration_ms': 1000,
      'comment': 'Old record',
      'timezone_id': 'Asia/Tokyo',
      'end_timezone_id': 'Asia/Tokyo',
      'created_at_epoch_ms': 1000,
      'updated_at_epoch_ms': 2000,
    });
    return db;
  }

  test('closes a paused running timer and opens the Lap at its end', () async {
    final db = await createV2Database();
    const startedAt = 3000;
    const pausedAt = 123000;
    await db.insert('active_timer', {
      'id': 1,
      'activity_id': 'act-sleep',
      'started_at_epoch_ms': startedAt,
      'started_timezone_id': 'PST',
      'is_paused': 1,
      'paused_at_epoch_ms': pausedAt,
      'accumulated_pause_ms': 0,
      'current_comment': 'Napping w/ Sam',
      'initial_tags_json': '["tag-travel"]',
      'last_heartbeat_epoch_ms': pausedAt,
    });
    await db.close();

    final tempo = await TempoDatabase.open(path: dbPath);
    addTearDown(tempo.close);

    // The old timer table is gone and the Lap now exists.
    final tables = await tempo.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='active_timer';",
    );
    expect(tables, isEmpty);

    final lap = await tempo.getLap();
    expect(lap, isNotNull);
    expect(lap!.startedAtEpochMs, equals(pausedAt));

    final records = await tempo.getRecords(orderBy: 'started_at_epoch_ms ASC');
    expect(records.length, equals(3));

    final closed = records.firstWhere((r) => r.startedAtEpochMs == startedAt);
    expect(closed.endedAtEpochMs, equals(pausedAt));
    expect(closed.durationMs, equals(pausedAt - startedAt));
    expect(closed.activityId, equals('act-sleep'));
    expect(closed.comment, equals('Napping w/ Sam'));
    expect(closed.tagIds, equals(['tag-travel']));
    expect(closed.timezoneId, equals('America/Los_Angeles'));
    expect(closed.endTimezoneId, isNotEmpty);

    // The gap between the pre-upgrade Record and the closed timer is filled.
    final gap = records.firstWhere((r) => r.startedAtEpochMs == 2000);
    expect(gap.endedAtEpochMs, equals(startedAt));
    expect(gap.activityId, isNull);
  });

  test('opens a Lap at upgrade time when no timer was running', () async {
    final db = await createV2Database();
    await db.close();

    final before = DateTime.now().toUtc().millisecondsSinceEpoch;
    final tempo = await TempoDatabase.open(path: dbPath);
    addTearDown(tempo.close);
    final after = DateTime.now().toUtc().millisecondsSinceEpoch;

    final lap = await tempo.getLap();
    expect(lap, isNotNull);
    expect(lap!.startedAtEpochMs, greaterThanOrEqualTo(before));
    expect(lap.startedAtEpochMs, lessThanOrEqualTo(after));

    // Existing Records are untouched.
    final records = await tempo.getRecords(orderBy: 'started_at_epoch_ms ASC');
    expect(records.length, equals(2));
    expect(records.first.id, equals('rec-old'));
    expect(records.first.startedAtEpochMs, equals(1000));
    expect(records.first.endedAtEpochMs, equals(2000));

    // Time between the last Record and the open Lap is filled as Untracked.
    final gap = records.last;
    expect(gap.activityId, isNull);
    expect(gap.startedAtEpochMs, equals(2000));
    expect(gap.endedAtEpochMs, equals(lap.startedAtEpochMs));
  });
}
