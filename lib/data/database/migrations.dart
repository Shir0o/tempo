import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../core/time/timezone_id.dart';

/// The single-row table holding the open Lap. Schema v3 replaces
/// `active_timer`; there is always exactly one row with `id = 1`.
const String createLapTableSql = '''
CREATE TABLE IF NOT EXISTS lap (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    started_at_epoch_ms INTEGER NOT NULL,
    started_timezone_id TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1
);
''';

/// Version 2: Records remember the zone they ended in, timers remember the
/// zone they started in, and legacy abbreviation zone ids are upgraded to
/// IANA ids where a best-effort mapping exists.
Future<void> migrateV1ToV2(DatabaseExecutor db) async {
  await db.execute(
    "ALTER TABLE records ADD COLUMN end_timezone_id TEXT NOT NULL DEFAULT ''",
  );
  await db.execute(
    "ALTER TABLE active_timer ADD COLUMN started_timezone_id TEXT NOT NULL DEFAULT ''",
  );

  // Every pre-v2 Record has a single zone: backfill the end zone from it.
  await db.execute('UPDATE records SET end_timezone_id = timezone_id');

  // Convert abbreviations such as `PST` to IANA ids. Ambiguous abbreviations
  // use the documented choices in `ianaZoneForAbbreviation`; anything already
  // IANA or unknown keeps its stored value.
  final distinctZones = await db.rawQuery(
    'SELECT DISTINCT timezone_id FROM records',
  );
  for (final row in distinctZones) {
    final stored = row['timezone_id'] as String;
    final iana = ianaZoneForAbbreviation(stored);
    if (iana == null) continue;
    await db.rawUpdate(
      'UPDATE records SET timezone_id = ?, end_timezone_id = ? '
      'WHERE timezone_id = ?',
      [iana, iana, stored],
    );
  }
}

/// Version 4: Records may be Untracked (`activity_id IS NULL`).
///
/// SQLite cannot drop the NOT NULL constraint in place, so the Records table
/// is rebuilt. `record_tags` is snapshotted first because dropping the parent
/// table with foreign keys enabled cascades to its children. Gaps between
/// existing Records are then filled with Untracked Records from the earliest
/// Record onward; pre-existing overlaps are left untouched so no data is lost.
Future<void> migrateV3ToV4(DatabaseExecutor db) async {
  final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;

  await db.execute('''
CREATE TEMP TABLE record_tags_backup AS SELECT * FROM record_tags;
''');
  await db.execute('DROP TABLE record_tags;');
  await db.execute('''
CREATE TABLE records_v4 (
    id TEXT PRIMARY KEY NOT NULL,
    activity_id TEXT REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL,
    ended_at_epoch_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    timezone_id TEXT NOT NULL,
    end_timezone_id TEXT NOT NULL DEFAULT '',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''');
  await db.execute('''
INSERT INTO records_v4 (
    id, activity_id, started_at_epoch_ms, ended_at_epoch_ms, duration_ms,
    comment, timezone_id, end_timezone_id, created_at_epoch_ms,
    updated_at_epoch_ms
)
SELECT
    id, activity_id, started_at_epoch_ms, ended_at_epoch_ms, duration_ms,
    comment, timezone_id, end_timezone_id, created_at_epoch_ms,
    updated_at_epoch_ms
FROM records;
''');
  await db.execute('DROP TABLE records;');
  await db.execute('ALTER TABLE records_v4 RENAME TO records;');
  await db.execute('''
CREATE TABLE record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''');
  final backupCount = await db.rawQuery(
    'SELECT COUNT(*) AS count FROM record_tags_backup',
  );
  if ((backupCount.first['count'] as int) > 0) {
    await db.execute('''
INSERT OR IGNORE INTO record_tags (record_id, tag_id)
SELECT record_id, tag_id FROM record_tags_backup;
''');
  }
  await db.execute('DROP TABLE record_tags_backup;');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_records_started ON records(started_at_epoch_ms);',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_records_activity ON records(activity_id);',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_records_updated ON records(updated_at_epoch_ms);',
  );

  await _fillRecordGapsWithUntracked(db, nowUtc);
}

/// Inserts an Untracked Record for every uncovered span between existing
/// Records, walking forward from the earliest Record. Overlaps are skipped
/// rather than corrected: the cursor only advances past time already covered.
Future<void> _fillRecordGapsWithUntracked(
  DatabaseExecutor db,
  int nowUtc,
) async {
  final rows = await db.query(
    'records',
    columns: [
      'started_at_epoch_ms',
      'ended_at_epoch_ms',
      'timezone_id',
      'end_timezone_id',
    ],
    orderBy: 'started_at_epoch_ms ASC, ended_at_epoch_ms ASC',
  );
  if (rows.isEmpty) return;

  final lapRows = await db.query(
    'lap',
    columns: ['started_at_epoch_ms', 'started_timezone_id'],
    where: 'id = 1',
    limit: 1,
  );
  final lapStartEpochMs = lapRows.isEmpty
      ? null
      : lapRows.first['started_at_epoch_ms'] as int;
  final lapTimezoneId = lapRows.isEmpty
      ? ''
      : lapRows.first['started_timezone_id'] as String? ?? '';

  var cursorEpochMs = rows.first['started_at_epoch_ms'] as int;
  var cursorTimezoneId =
      (rows.first['end_timezone_id'] as String?)?.isNotEmpty == true
      ? rows.first['end_timezone_id'] as String
      : rows.first['timezone_id'] as String;

  Future<void> addGap(int endEpochMs, String endTimezoneId) async {
    if (endEpochMs <= cursorEpochMs) return;
    await _insertRecordSplitAtMidnight(
      db,
      activityId: null,
      startedAtEpochMs: cursorEpochMs,
      endedAtEpochMs: endEpochMs,
      startTimezoneId: cursorTimezoneId,
      endTimezoneId: endTimezoneId,
      nowUtc: nowUtc,
    );
    cursorEpochMs = endEpochMs;
    cursorTimezoneId = endTimezoneId;
  }

  for (final row in rows) {
    final startedAtEpochMs = row['started_at_epoch_ms'] as int;
    final endedAtEpochMs = row['ended_at_epoch_ms'] as int;
    final startTimezoneId = row['timezone_id'] as String;
    final rawEndTimezoneId = row['end_timezone_id'] as String?;
    final endTimezoneId = rawEndTimezoneId == null || rawEndTimezoneId.isEmpty
        ? startTimezoneId
        : rawEndTimezoneId;

    if (startedAtEpochMs > cursorEpochMs) {
      await addGap(startedAtEpochMs, startTimezoneId);
    }
    if (endedAtEpochMs > cursorEpochMs) {
      cursorEpochMs = endedAtEpochMs;
      cursorTimezoneId = endTimezoneId;
    }
  }

  if (lapStartEpochMs != null) {
    await addGap(
      lapStartEpochMs,
      lapTimezoneId.isEmpty ? cursorTimezoneId : lapTimezoneId,
    );
  }
}

/// Version 3: the always-running Lap replaces the active timer.
///
/// A running timer is closed as a Record ending at migration time (a paused
/// one at the instant it was paused), split at each local midnight it crossed,
/// and the Lap opens at that same instant. There is no pause in a Record: its
/// duration is always end - start. A fresh install has no timer; its Lap opens
/// at migration time too.
Future<void> migrateV2ToV3(DatabaseExecutor db) async {
  final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
  final currentZone = localTimezoneId();

  var lapStartEpochMs = nowUtc;
  var lapTimezoneId = currentZone;

  final timerRows = await db.rawQuery(
    'SELECT * FROM active_timer WHERE id = 1 LIMIT 1',
  );
  if (timerRows.isNotEmpty) {
    final timer = timerRows.first;
    final startedAtEpochMs = timer['started_at_epoch_ms'] as int;
    final isPaused = (timer['is_paused'] as int? ?? 0) == 1;
    final pausedAtEpochMs = timer['paused_at_epoch_ms'] as int?;
    final endedAtEpochMs = isPaused && pausedAtEpochMs != null
        ? pausedAtEpochMs
        : nowUtc;

    final storedZone = timer['started_timezone_id'] as String? ?? '';
    final startTimezoneId = storedZone.isEmpty
        ? currentZone
        : (ianaZoneForAbbreviation(storedZone) ?? storedZone);

    final recordIds = await _insertRecordSplitAtMidnight(
      db,
      activityId: timer['activity_id'] as String,
      startedAtEpochMs: startedAtEpochMs,
      endedAtEpochMs: endedAtEpochMs,
      comment: timer['current_comment'] as String? ?? '',
      startTimezoneId: startTimezoneId,
      endTimezoneId: currentZone,
      nowUtc: nowUtc,
    );

    final tagsJson = timer['initial_tags_json'] as String? ?? '[]';
    if (tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson);
        if (decoded is List) {
          for (final recordId in recordIds) {
            for (final tagId in decoded) {
              await db.insert('record_tags', {
                'record_id': recordId,
                'tag_id': tagId.toString(),
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          }
        }
      } catch (_) {}
    }

    lapStartEpochMs = endedAtEpochMs;
    lapTimezoneId = currentZone;
  }

  await db.execute('DROP TABLE IF EXISTS active_timer');
  await db.execute(createLapTableSql);
  await db.insert('lap', {
    'id': 1,
    'started_at_epoch_ms': lapStartEpochMs,
    'started_timezone_id': lapTimezoneId,
    'revision': 1,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// Inserts the span [startedAtEpochMs, endedAtEpochMs) as one Record per Day,
/// split at each local midnight in [endTimezoneId] (the zone the span ended
/// in, as for a live MidnightSplit). Every part shares the Activity and
/// comment; parts after the first start in [endTimezoneId]. Returns the new
/// Record ids, oldest first. Only columns present since schema v2 are written,
/// so this works at every migration step.
Future<List<String>> _insertRecordSplitAtMidnight(
  DatabaseExecutor db, {
  required String? activityId,
  required int startedAtEpochMs,
  required int endedAtEpochMs,
  String comment = '',
  required String startTimezoneId,
  required String endTimezoneId,
  required int nowUtc,
}) async {
  final ids = <String>[];
  var cursor = startedAtEpochMs;
  var cursorTimezoneId = startTimezoneId;
  while (cursor < endedAtEpochMs) {
    final midnight = nextLocalMidnightUtcMs(endTimezoneId, cursor);
    final end = midnight < endedAtEpochMs ? midnight : endedAtEpochMs;
    final id = const Uuid().v4();
    await db.insert('records', {
      'id': id,
      'activity_id': activityId,
      'started_at_epoch_ms': cursor,
      'ended_at_epoch_ms': end,
      'duration_ms': end - cursor,
      'comment': comment,
      'timezone_id': cursorTimezoneId,
      'end_timezone_id': endTimezoneId,
      'created_at_epoch_ms': nowUtc,
      'updated_at_epoch_ms': nowUtc,
    });
    ids.add(id);
    cursor = end;
    cursorTimezoneId = endTimezoneId;
  }
  return ids;
}

/// Version 5: Records distinguish MidnightSplit halves from explicitly split
/// ones, so labelling the open Lap can apply to the whole unlabeled span while
/// still respecting a Split the user made by hand.
Future<void> migrateV4ToV5(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE records ADD COLUMN is_midnight_split INTEGER NOT NULL DEFAULT 0',
  );
}

/// Version 6: Introduces first-class Category entity and classifies Activities
/// with a nullable category_id foreign key.
Future<void> migrateV5ToV6(DatabaseExecutor db) async {
  await db.execute('''
CREATE TABLE IF NOT EXISTS categories (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL,
    icon_name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''');
  await db.execute(
    'ALTER TABLE activities ADD COLUMN category_id TEXT REFERENCES categories(id) ON DELETE SET NULL',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_activities_category_id ON activities(category_id);',
  );
}

/// Version 7: A key/value store for user preferences that must survive a
/// restart and travel with the database backup.
Future<void> migrateV6ToV7(DatabaseExecutor db) async {
  await db.execute('''
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
''');
}

/// Version 8: Activities that belong to a Category take the Category's colour,
/// so every activity in one category shares one colour.
Future<void> migrateV7ToV8(DatabaseExecutor db) async {
  await db.execute('''
UPDATE activities
SET color_hex = (
  SELECT categories.color_hex
  FROM categories
  WHERE categories.id = activities.category_id
)
WHERE category_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM categories WHERE categories.id = activities.category_id
  );
''');
}

/// Version 9: Backfill activities with default color to inherit their parent
/// category's color_hex.
Future<void> migrateV8ToV9(DatabaseExecutor db) async {
  await db.execute('''
UPDATE activities
SET color_hex = (
    SELECT categories.color_hex
    FROM categories
    WHERE categories.id = activities.category_id
)
WHERE category_id IS NOT NULL
  AND color_hex = '#4CAF50'
  AND EXISTS (
      SELECT 1 FROM categories
      WHERE categories.id = activities.category_id
        AND categories.color_hex IS NOT NULL
        AND categories.color_hex != ''
  );
''');
}
