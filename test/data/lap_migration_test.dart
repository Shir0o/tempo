import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

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
      // There is no pause in a Record: this must not shorten its duration.
      'accumulated_pause_ms': 30000,
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

  /// Every Record follows the previous one and none crosses a local midnight
  /// in the zone it ended in.
  void expectContinuousDays(List<Record> records) {
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      expect(r.durationMs, r.endedAtEpochMs - r.startedAtEpochMs);
      expect(
        nextLocalMidnightUtcMs(r.endTimezoneId, r.startedAtEpochMs),
        greaterThanOrEqualTo(r.endedAtEpochMs),
        reason: '${r.id} crosses midnight',
      );
      if (i > 0) {
        expect(r.startedAtEpochMs, records[i - 1].endedAtEpochMs);
      }
    }
  }

  test('splits a running timer at every midnight it crossed', () async {
    final db = await createV2Database();
    final startedAt =
        DateTime.now().toUtc().millisecondsSinceEpoch - 50 * 3600000;
    await db.update(
      'records',
      {'started_at_epoch_ms': startedAt - 1000, 'ended_at_epoch_ms': startedAt},
      where: 'id = ?',
      whereArgs: ['rec-old'],
    );
    await db.insert('active_timer', {
      'id': 1,
      'activity_id': 'act-sleep',
      'started_at_epoch_ms': startedAt,
      'started_timezone_id': 'Asia/Tokyo',
      'accumulated_pause_ms': 3600000,
      'current_comment': 'Long nap',
      'initial_tags_json': '["tag-travel"]',
      'last_heartbeat_epoch_ms': startedAt,
    });
    await db.close();

    final tempo = await TempoDatabase.open(path: dbPath);
    addTearDown(tempo.close);

    final lap = await tempo.getLap();
    final records = await tempo.getRecords(orderBy: 'started_at_epoch_ms ASC');
    final timerParts = records.skip(1).toList();
    // 50 hours cross at least two midnights.
    expect(timerParts.length, greaterThanOrEqualTo(3));
    expectContinuousDays(records);
    expect(timerParts.first.startedAtEpochMs, startedAt);
    expect(timerParts.first.timezoneId, 'Asia/Tokyo');
    expect(timerParts.last.endedAtEpochMs, lap!.startedAtEpochMs);
    for (final part in timerParts) {
      expect(part.activityId, 'act-sleep');
      expect(part.comment, 'Long nap');
      expect(part.tagIds, ['tag-travel']);
    }
    // The whole span counts: the old pause is not subtracted.
    final total = timerParts.fold<int>(0, (sum, r) => sum + r.durationMs);
    expect(total, lap.startedAtEpochMs - startedAt);
  });

  test('opens a Lap at upgrade time when no timer was running', () async {
    final db = await createV2Database();
    // The last Record ended two days before the upgrade.
    final lastEnded =
        DateTime.now().toUtc().millisecondsSinceEpoch - 48 * 3600000;
    await db.update(
      'records',
      {'started_at_epoch_ms': lastEnded - 1000, 'ended_at_epoch_ms': lastEnded},
      where: 'id = ?',
      whereArgs: ['rec-old'],
    );
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
    expect(records.first.id, equals('rec-old'));
    expect(records.first.startedAtEpochMs, equals(lastEnded - 1000));
    expect(records.first.endedAtEpochMs, equals(lastEnded));

    // Time between the last Record and the open Lap is filled as Untracked,
    // one Record per Day.
    final gaps = records.skip(1).toList();
    expect(gaps.length, greaterThanOrEqualTo(2));
    expect(gaps.every((r) => r.activityId == null), isTrue);
    expect(gaps.first.startedAtEpochMs, equals(lastEnded));
    expect(gaps.last.endedAtEpochMs, equals(lap.startedAtEpochMs));
    expectContinuousDays(records);
  });
}
