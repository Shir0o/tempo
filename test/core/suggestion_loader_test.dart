import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/suggestion_loader.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('loadSuggestions', () {
    const zone = 'UTC';
    final now = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
    late TempoDatabase db;

    Activity activity(
      String id, {
      bool isPinned = false,
      bool isArchived = false,
    }) => Activity(
      id: id,
      name: id,
      isPinned: isPinned,
      isArchived: isArchived,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );

    Future<void> insertRecord(String id, String? activityId, int startMs) =>
        db.insertRecord(
          Record(
            id: id,
            activityId: activityId,
            startedAtEpochMs: startMs,
            endedAtEpochMs: startMs + 3600000,
            timezoneId: zone,
            createdAtEpochMs: startMs,
            updatedAtEpochMs: startMs,
          ),
        );

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      for (final id in ['sleep', 'shower', 'commute', 'gym', 'old', 'recent']) {
        await db.insertActivity(activity(id));
      }
    });

    tearDown(() async {
      await db.close();
    });

    test('derives the routine context from the lean history', () async {
      const hour = 3600000;
      // Two complete Sleep -> Shower -> Commute routines, then Sleep -> Shower.
      await insertRecord('r1', 'sleep', now - 10 * hour);
      await insertRecord('r2', 'shower', now - 9 * hour);
      await insertRecord('r3', 'commute', now - 8 * hour);
      await insertRecord('r4', 'sleep', now - 7 * hour);
      await insertRecord('r5', 'shower', now - 6 * hour);
      await insertRecord('r6', 'commute', now - 5 * hour);
      await insertRecord('r7', 'sleep', now - 4 * hour);
      await insertRecord('r8', 'shower', now - 3 * hour);

      final ranked = await loadSuggestions(
        database: db,
        candidates: [
          activity('gym'),
          activity('commute'),
          activity('shower'),
          activity('sleep'),
        ],
        nowEpochMs: now,
        timezoneId: zone,
        limit: 4,
      );

      expect(ranked.first.id, 'commute');
    });

    test('ignores a Record outside the 60-day window', () async {
      const day = 86400000;
      await insertRecord('old', 'old', now - 61 * day);
      await insertRecord('recent', 'recent', now - 3600000);

      final ranked = await loadSuggestions(
        database: db,
        candidates: [activity('old'), activity('recent')],
        nowEpochMs: now,
        timezoneId: zone,
        limit: 2,
      );

      expect(ranked.first.id, 'recent');
    });

    test('ignores a future-dated Record', () async {
      const hour = 3600000;
      await insertRecord('future', 'gym', now + hour);
      await insertRecord('past', 'recent', now - hour);

      final ranked = await loadSuggestions(
        database: db,
        candidates: [activity('gym'), activity('recent')],
        nowEpochMs: now,
        timezoneId: zone,
        limit: 2,
      );

      expect(ranked.first.id, 'recent');
    });

    test('shows pinned activities at cold start', () async {
      final ranked = await loadSuggestions(
        database: db,
        candidates: [
          activity('gym'),
          activity('pinned', isPinned: true),
          activity('archived-pinned', isPinned: true, isArchived: true),
        ],
        nowEpochMs: now,
        timezoneId: zone,
        limit: 4,
      );

      expect(ranked.map((activity) => activity.id), ['pinned']);
    });

    test('always gives a pinned activity a suggestion slot', () async {
      const hour = 3600000;
      await insertRecord('r1', 'gym', now - 2 * hour);
      await insertRecord('r2', 'recent', now - hour);

      final ranked = await loadSuggestions(
        database: db,
        candidates: [
          activity('gym'),
          activity('recent'),
          activity('pinned', isPinned: true),
        ],
        nowEpochMs: now,
        timezoneId: zone,
        limit: 2,
      );

      expect(ranked.map((activity) => activity.id), ['pinned', 'recent']);
    });
  });
}
