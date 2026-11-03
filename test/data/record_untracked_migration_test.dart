import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

/// A version-3 database: Records still require an Activity.
const String _v3Activities = '''
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

const String _v3Tags = '''
CREATE TABLE tags (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v3Records = '''
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

const String _v3RecordTags = '''
CREATE TABLE record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''';

const String _v3Lap = '''
CREATE TABLE lap (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    started_at_epoch_ms INTEGER NOT NULL,
    started_timezone_id TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1
);
''';

const String _v3Tombstones = '''
CREATE TABLE tombstones (
    entity_id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    deleted_at_epoch_ms INTEGER NOT NULL
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
    tempDir = await Directory.systemTemp.createTemp('tempo-untracked-migrate');
    dbPath = p.join(tempDir.path, 'tempo.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> insertRecord(
    Database db, {
    required String id,
    required int start,
    required int end,
    required String timezoneId,
    String? endTimezoneId,
  }) async {
    await db.insert('records', {
      'id': id,
      'activity_id': 'act-sleep',
      'started_at_epoch_ms': start,
      'ended_at_epoch_ms': end,
      'duration_ms': end - start,
      'comment': '',
      'timezone_id': timezoneId,
      'end_timezone_id': endTimezoneId ?? timezoneId,
      'created_at_epoch_ms': start,
      'updated_at_epoch_ms': start,
    });
  }

  Future<Database> createV3Database() async {
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute(_v3Activities);
          await db.execute(_v3Tags);
          await db.execute(_v3Records);
          await db.execute(_v3RecordTags);
          await db.execute(_v3Lap);
          await db.execute(_v3Tombstones);
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
    await insertRecord(
      db,
      id: 'rec-a',
      start: 1000,
      end: 2000,
      timezoneId: 'Asia/Tokyo',
    );
    await insertRecord(
      db,
      id: 'rec-b',
      start: 3000,
      end: 4000,
      timezoneId: 'Asia/Tokyo',
    );
    // Overlaps rec-b and ends later; kept as-is.
    await insertRecord(
      db,
      id: 'rec-c',
      start: 3500,
      end: 5000,
      timezoneId: 'Asia/Tokyo',
      endTimezoneId: 'America/Los_Angeles',
    );
    await insertRecord(
      db,
      id: 'rec-d',
      start: 6000,
      end: 7000,
      timezoneId: 'America/Los_Angeles',
    );
    await db.insert('record_tags', {
      'record_id': 'rec-a',
      'tag_id': 'tag-travel',
    });
    await db.insert('lap', {
      'id': 1,
      'started_at_epoch_ms': 8000,
      'started_timezone_id': 'Asia/Tokyo',
      'revision': 4,
    });
    return db;
  }

  test('gap fill writes one Untracked Record per Day', () async {
    final v3 = await createV3Database();
    // 06:00 on 3 Jan 1970 in Tokyo: the gap from 7000 crosses two midnights.
    const lapStart = 162000000;
    await v3.update('lap', {'started_at_epoch_ms': lapStart});
    await v3.close();

    final tempo = await TempoDatabase.open(path: dbPath);
    addTearDown(tempo.close);

    final tail = (await tempo.getRecords(orderBy: 'started_at_epoch_ms ASC'))
        .where((r) => r.isUntracked && r.startedAtEpochMs >= 7000)
        .toList();

    const tokyoJan2 = 54000000;
    const tokyoJan3 = 140400000;
    expect(
      tail.map((r) => [r.startedAtEpochMs, r.endedAtEpochMs]).toList(),
      equals([
        [7000, tokyoJan2],
        [tokyoJan2, tokyoJan3],
        [tokyoJan3, lapStart],
      ]),
    );
    expect(tail.first.timezoneId, 'America/Los_Angeles');
    expect(tail.map((r) => r.endTimezoneId).toSet(), {'Asia/Tokyo'});
    expect(tail[1].timezoneId, 'Asia/Tokyo');
    expect(tail[1].durationMs, 24 * 3600000);
  });

  test(
    'nullable activity_id, gap fill, overlaps preserved, tags kept',
    () async {
      final v3 = await createV3Database();
      await v3.close();

      final tempo = await TempoDatabase.open(path: dbPath);
      addTearDown(tempo.close);

      final records = await tempo.getRecords(
        orderBy: 'started_at_epoch_ms ASC',
      );

      // Original Records and their overlap are untouched.
      final byId = {for (final r in records) r.id: r};
      expect(byId['rec-a']!.startedAtEpochMs, equals(1000));
      expect(byId['rec-a']!.endedAtEpochMs, equals(2000));
      expect(byId['rec-a']!.tagIds, equals(['tag-travel']));
      expect(byId['rec-b']!.startedAtEpochMs, equals(3000));
      expect(byId['rec-b']!.endedAtEpochMs, equals(4000));
      expect(byId['rec-c']!.startedAtEpochMs, equals(3500));
      expect(byId['rec-c']!.endedAtEpochMs, equals(5000));
      expect(records.length, equals(7));

      // Gaps between Records (and up to the Lap) become Untracked Records.
      final untracked = records.where((r) => r.isUntracked).toList();
      expect(untracked.length, equals(3));

      final gapOne = untracked.firstWhere((r) => r.startedAtEpochMs == 2000);
      expect(gapOne.endedAtEpochMs, equals(3000));
      expect(gapOne.durationMs, equals(1000));
      expect(gapOne.timezoneId, equals('Asia/Tokyo'));
      expect(gapOne.endTimezoneId, equals('Asia/Tokyo'));

      final gapTwo = untracked.firstWhere((r) => r.startedAtEpochMs == 5000);
      expect(gapTwo.endedAtEpochMs, equals(6000));
      expect(gapTwo.timezoneId, equals('America/Los_Angeles'));
      expect(gapTwo.endTimezoneId, equals('America/Los_Angeles'));

      final tail = untracked.firstWhere((r) => r.startedAtEpochMs == 7000);
      expect(tail.endedAtEpochMs, equals(8000));
      expect(tail.timezoneId, equals('America/Los_Angeles'));
      expect(tail.endTimezoneId, equals('Asia/Tokyo'));

      // The Lap is unchanged.
      final lap = await tempo.getLap();
      expect(lap!.startedAtEpochMs, equals(8000));
      expect(lap.revision, equals(4));

      // The rebuilt table accepts Records without an Activity.
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await tempo.insertRecord(
        Record(
          id: 'rec-new-untracked',
          activityId: null,
          startedAtEpochMs: 9000,
          endedAtEpochMs: 9500,
          timezoneId: 'Asia/Tokyo',
          endTimezoneId: 'Asia/Tokyo',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      expect(
        (await tempo.getRecordById('rec-new-untracked'))!.activityId,
        isNull,
      );
    },
  );
}
