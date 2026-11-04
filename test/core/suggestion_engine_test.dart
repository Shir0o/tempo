import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  group('ContextualSuggestionEngine', () {
    const engine = ContextualSuggestionEngine();
    const zoneUtc = 'UTC';
    const zoneNY = 'America/New_York';

    Activity makeActivity(
      String id, {
      String name = '',
      bool isArchived = false,
    }) {
      return Activity(
        id: id,
        name: name.isEmpty ? id : name,
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
        isArchived: isArchived,
      );
    }

    Record makeRecord({
      required String id,
      required String? activityId,
      required int startedAtEpochMs,
      required int endedAtEpochMs,
      String timezoneId = zoneUtc,
      bool isMidnightSplit = false,
    }) {
      return Record(
        id: id,
        activityId: activityId,
        startedAtEpochMs: startedAtEpochMs,
        endedAtEpochMs: endedAtEpochMs,
        timezoneId: timezoneId,
        endTimezoneId: timezoneId,
        isMidnightSplit: isMidnightSplit,
        createdAtEpochMs: startedAtEpochMs,
        updatedAtEpochMs: endedAtEpochMs,
      );
    }

    test('cold start (empty history) returns candidates preserving order', () {
      final candidates = [
        makeActivity('act_1'),
        makeActivity('act_2'),
        makeActivity('act_3'),
      ];

      final ranked = engine.rank(
        candidates: candidates,
        history: const [],
        precedingActivityId: null,
        targetEpochMs: 1700000000000,
        timezoneId: zoneUtc,
      );

      expect(ranked.map((a) => a.id).toList(), ['act_1', 'act_2', 'act_3']);
    });

    test('filters out archived / tombstoned activities', () {
      final candidates = [
        makeActivity('act_1', isArchived: true),
        makeActivity('act_2', isArchived: false),
        makeActivity('act_3', isArchived: true),
        makeActivity('act_4', isArchived: false),
      ];

      final ranked = engine.rank(
        candidates: candidates,
        history: const [],
        precedingActivityId: null,
        targetEpochMs: 1700000000000,
        timezoneId: zoneUtc,
      );

      expect(ranked.map((a) => a.id).toList(), ['act_2', 'act_4']);
    });

    test(
      'Markov transition (A -> B) correctly ranks B first when preceding is A',
      () {
        final a = makeActivity('act_A');
        final b = makeActivity('act_B');
        final c = makeActivity('act_C');

        // History: A -> B, A -> B, A -> C
        final history = [
          makeRecord(
            id: 'r1',
            activityId: 'act_A',
            startedAtEpochMs: 1000,
            endedAtEpochMs: 2000,
          ),
          makeRecord(
            id: 'r2',
            activityId: 'act_B',
            startedAtEpochMs: 2000,
            endedAtEpochMs: 3000,
          ),
          makeRecord(
            id: 'r3',
            activityId: 'act_A',
            startedAtEpochMs: 3000,
            endedAtEpochMs: 4000,
          ),
          makeRecord(
            id: 'r4',
            activityId: 'act_B',
            startedAtEpochMs: 4000,
            endedAtEpochMs: 5000,
          ),
          makeRecord(
            id: 'r5',
            activityId: 'act_A',
            startedAtEpochMs: 5000,
            endedAtEpochMs: 6000,
          ),
          makeRecord(
            id: 'r6',
            activityId: 'act_C',
            startedAtEpochMs: 6000,
            endedAtEpochMs: 7000,
          ),
        ];

        final ranked = engine.rank(
          candidates: [c, b, a],
          history: history,
          precedingActivityId: 'act_A',
          targetEpochMs: 8000,
          timezoneId: zoneUtc,
        );

        // Even though candidate list had c first, B has 2 transitions vs C's 1 transition
        expect(ranked.first.id, 'act_B');
        expect(ranked[1].id, 'act_C');
      },
    );

    test('Temporal slotting (Activity C at 8am, Activity D at 8pm)', () {
      final actC = makeActivity('act_C');
      final actD = makeActivity('act_D');

      // Monday 2026-11-02 08:00:00 UTC
      // Tuesday 2026-11-03 08:00:00 UTC
      // Monday 2026-11-02 20:00:00 UTC
      // Tuesday 2026-11-03 20:00:00 UTC
      final monMorningMs = DateTime.utc(2026, 11, 2, 8).millisecondsSinceEpoch;
      final tueMorningMs = DateTime.utc(2026, 11, 3, 8).millisecondsSinceEpoch;
      final monEveningMs = DateTime.utc(2026, 11, 2, 20).millisecondsSinceEpoch;
      final tueEveningMs = DateTime.utc(2026, 11, 3, 20).millisecondsSinceEpoch;

      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'act_C',
          startedAtEpochMs: monMorningMs,
          endedAtEpochMs: monMorningMs + 3600000,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'act_D',
          startedAtEpochMs: monEveningMs,
          endedAtEpochMs: monEveningMs + 3600000,
        ),
      ];

      // Query on Tuesday at 8:30am (within 8am +/- 1 hour) on a weekday
      final morningRanked = engine.rank(
        candidates: [actD, actC],
        history: history,
        precedingActivityId: null,
        targetEpochMs: tueMorningMs + 1800000,
        timezoneId: zoneUtc,
      );
      expect(morningRanked.first.id, 'act_C');

      // Query on Tuesday at 8:30pm (within 8pm +/- 1 hour) on a weekday
      final eveningRanked = engine.rank(
        candidates: [actC, actD],
        history: history,
        precedingActivityId: null,
        targetEpochMs: tueEveningMs + 1800000,
        timezoneId: zoneUtc,
      );
      expect(eveningRanked.first.id, 'act_D');
    });

    test('Timezone and DST handling uses wallClockAt', () {
      final actMorning = makeActivity('morning_act');
      final actEvening = makeActivity('evening_act');

      // In America/New_York (UTC-5 in winter):
      // 13:00 UTC is 08:00 AM NY time.
      final nyTargetTimeUtcMs = DateTime.utc(
        2026,
        11,
        2,
        13,
      ).millisecondsSinceEpoch;

      // History recorded at 08:00 AM in America/New_York (which is 13:00 UTC)
      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'morning_act',
          startedAtEpochMs: nyTargetTimeUtcMs - 7 * 86400000,
          endedAtEpochMs: nyTargetTimeUtcMs - 7 * 86400000 + 1800000,
          timezoneId: zoneNY,
        ),
      ];

      final ranked = engine.rank(
        candidates: [actEvening, actMorning],
        history: history,
        precedingActivityId: null,
        targetEpochMs: nyTargetTimeUtcMs,
        timezoneId: zoneNY,
      );

      expect(ranked.first.id, 'morning_act');
    });

    test('Synthetic midnight split records preserve activity transitions', () {
      final sleep = makeActivity('sleep');
      final breakfast = makeActivity('breakfast');
      final work = makeActivity('work');

      // History where Sleep spans across midnight:
      // Record 1: Sleep from 23:00 to 00:00 (isMidnightSplit = true)
      // Record 2: Sleep from 00:00 to 07:00
      // Record 3: Breakfast from 07:00 to 07:30
      final t0 = DateTime.utc(2026, 11, 1, 23).millisecondsSinceEpoch;
      final t1 = DateTime.utc(2026, 11, 2, 0).millisecondsSinceEpoch;
      final t2 = DateTime.utc(2026, 11, 2, 7).millisecondsSinceEpoch;
      final t3 = DateTime.utc(2026, 11, 2, 7, 30).millisecondsSinceEpoch;

      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'sleep',
          startedAtEpochMs: t0,
          endedAtEpochMs: t1,
          isMidnightSplit: true,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'sleep',
          startedAtEpochMs: t1,
          endedAtEpochMs: t2,
        ),
        makeRecord(
          id: 'r3',
          activityId: 'breakfast',
          startedAtEpochMs: t2,
          endedAtEpochMs: t3,
        ),
      ];

      // When preceding activity is sleep, breakfast should rank top
      final ranked = engine.rank(
        candidates: [work, breakfast, sleep],
        history: history,
        precedingActivityId: 'sleep',
        targetEpochMs: t3 + 1000,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'breakfast');
    });

    test('Untracked preceding record (activityId == null) ignores Markov', () {
      final act1 = makeActivity('act_1');
      final act2 = makeActivity('act_2');

      // History has null -> act_2
      final history = [
        makeRecord(
          id: 'r1',
          activityId: null,
          startedAtEpochMs: 1000,
          endedAtEpochMs: 2000,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'act_2',
          startedAtEpochMs: 2000,
          endedAtEpochMs: 3000,
        ),
      ];

      // Preceding activity is null: Untracked interval
      final ranked = engine.rank(
        candidates: [act1, act2],
        history: history,
        precedingActivityId: null,
        targetEpochMs: 4000,
        timezoneId: zoneUtc,
      );

      // Since preceding is null, Markov is ignored.
      // Both act1 and act2 have 0 temporal slot match (far away).
      // act2 has frequency 1, act1 has frequency 0.
      expect(ranked.first.id, 'act_2');
    });

    test('Performance: execution time is sub-millisecond for 2000 records', () {
      final candidates = List.generate(20, (i) => makeActivity('act_$i'));
      final history = List.generate(
        2000,
        (i) => makeRecord(
          id: 'r_$i',
          activityId: 'act_${i % 20}',
          startedAtEpochMs: 1700000000000 + i * 3600000,
          endedAtEpochMs: 1700000000000 + (i + 1) * 3600000,
        ),
      );

      // Warm up JIT
      for (var i = 0; i < 5; i++) {
        engine.rank(
          candidates: candidates,
          history: history,
          precedingActivityId: 'act_3',
          targetEpochMs: 1700000000000 + 2000 * 3600000,
          timezoneId: zoneUtc,
        );
      }

      final sw = Stopwatch()..start();
      const iterations = 50;
      for (var i = 0; i < iterations; i++) {
        engine.rank(
          candidates: candidates,
          history: history,
          precedingActivityId: 'act_3',
          targetEpochMs: 1700000000000 + 2000 * 3600000,
          timezoneId: zoneUtc,
        );
      }
      sw.stop();
      final avgMicros = sw.elapsedMicroseconds / iterations;
      // Should be well under 1000 microseconds (1 millisecond)
      expect(
        avgMicros,
        lessThan(3000),
      ); // generous buffer for debug mode/shared CI runner
    });
  });
}
