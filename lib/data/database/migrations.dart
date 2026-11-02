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

/// Version 3: the always-running Lap replaces the active timer.
///
/// A running timer is closed as a Record ending at migration time (its pause
/// time is already excluded), and the Lap opens at that same instant. A fresh
/// install has no timer; its Lap opens at migration time too.
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
    final accumulatedPauseMs = timer['accumulated_pause_ms'] as int? ?? 0;
    final endedAtEpochMs = isPaused && pausedAtEpochMs != null
        ? pausedAtEpochMs
        : nowUtc;
    final rawDuration = endedAtEpochMs - startedAtEpochMs - accumulatedPauseMs;

    final storedZone = timer['started_timezone_id'] as String? ?? '';
    final startTimezoneId = storedZone.isEmpty
        ? currentZone
        : (ianaZoneForAbbreviation(storedZone) ?? storedZone);

    final recordId = const Uuid().v4();
    await db.insert('records', {
      'id': recordId,
      'activity_id': timer['activity_id'] as String,
      'started_at_epoch_ms': startedAtEpochMs,
      'ended_at_epoch_ms': endedAtEpochMs,
      'duration_ms': rawDuration < 0 ? 0 : rawDuration,
      'comment': timer['current_comment'] as String? ?? '',
      'timezone_id': startTimezoneId,
      'end_timezone_id': currentZone,
      'created_at_epoch_ms': nowUtc,
      'updated_at_epoch_ms': nowUtc,
    });

    final tagsJson = timer['initial_tags_json'] as String? ?? '[]';
    if (tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson);
        if (decoded is List) {
          for (final tagId in decoded) {
            await db.insert('record_tags', {
              'record_id': recordId,
              'tag_id': tagId.toString(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
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
