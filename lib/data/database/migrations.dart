import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/time/timezone_id.dart';

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
