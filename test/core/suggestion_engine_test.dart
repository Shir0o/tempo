import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  group('ContextualSuggestionEngine', () {
    const engine = ContextualSuggestionEngine();
    const zoneUtc = 'UTC';
    const zoneNY = 'America/New_York';
    const hour = Duration.millisecondsPerHour;

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

    SuggestionObservation makeRecord({
      required String id,
      required String? activityId,
      required int startedAtEpochMs,
      int? endedAtEpochMs,
      String timezoneId = zoneUtc,
      bool isMidnightSplit = false,
    }) {
      return SuggestionObservation(
        activityId: activityId,
        startedAtEpochMs: startedAtEpochMs,
        timezoneId: timezoneId,
      );
    }

    List<SuggestionObservation> ordered(List<SuggestionObservation> records) =>
        records
          ..sort((a, b) => a.startedAtEpochMs.compareTo(b.startedAtEpochMs));

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

        // History: A -> B, A -> B, A -> C.
        final history = [
          makeRecord(id: 'r1', activityId: 'act_A', startedAtEpochMs: 1000),
          makeRecord(id: 'r2', activityId: 'act_B', startedAtEpochMs: 2000),
          makeRecord(id: 'r3', activityId: 'act_A', startedAtEpochMs: 3000),
          makeRecord(id: 'r4', activityId: 'act_B', startedAtEpochMs: 4000),
          makeRecord(id: 'r5', activityId: 'act_A', startedAtEpochMs: 5000),
          makeRecord(id: 'r6', activityId: 'act_C', startedAtEpochMs: 6000),
        ];

        final ranked = engine.rank(
          candidates: [c, b, a],
          history: history,
          precedingActivityId: 'act_A',
          targetEpochMs: 8000,
          timezoneId: zoneUtc,
        );

        expect(ranked.first.id, 'act_B');
        expect(ranked[1].id, 'act_C');
      },
    );

    test('Temporal slotting (Activity C at 8am, Activity D at 8pm)', () {
      final actC = makeActivity('act_C');
      final actD = makeActivity('act_D');

      final monMorningMs = DateTime.utc(2026, 11, 2, 8).millisecondsSinceEpoch;
      final tueMorningMs = DateTime.utc(2026, 11, 3, 8).millisecondsSinceEpoch;
      final monEveningMs = DateTime.utc(2026, 11, 2, 20).millisecondsSinceEpoch;
      final tueEveningMs = DateTime.utc(2026, 11, 3, 20).millisecondsSinceEpoch;

      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'act_C',
          startedAtEpochMs: monMorningMs,
          endedAtEpochMs: monMorningMs + hour,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'act_D',
          startedAtEpochMs: monEveningMs,
          endedAtEpochMs: monEveningMs + hour,
        ),
      ];

      final morningRanked = engine.rank(
        candidates: [actD, actC],
        history: history,
        precedingActivityId: null,
        targetEpochMs: tueMorningMs + 1800000,
        timezoneId: zoneUtc,
      );
      expect(morningRanked.first.id, 'act_C');

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

      // 13:00 UTC is 08:00 in America/New_York in winter.
      final nyTargetTimeUtcMs = DateTime.utc(
        2026,
        11,
        2,
        13,
      ).millisecondsSinceEpoch;

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

      final ranked = engine.rank(
        candidates: [work, breakfast, sleep],
        history: history,
        precedingActivityId: 'sleep',
        targetEpochMs: t3 + 1000,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'breakfast');
    });

    test('contextFromHistory collapses a MidnightSplit into one run', () {
      final t0 = DateTime.utc(2026, 11, 1, 23).millisecondsSinceEpoch;
      final t1 = DateTime.utc(2026, 11, 2, 0).millisecondsSinceEpoch;
      final t2 = DateTime.utc(2026, 11, 2, 7).millisecondsSinceEpoch;
      final t3 = DateTime.utc(2026, 11, 2, 7, 30).millisecondsSinceEpoch;

      final context = ContextualSuggestionEngine.contextFromHistory([
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
      ], targetEpochMs: t3 + 1000);

      expect(context.precedingActivityId, 'breakfast');
      expect(context.secondPrecedingActivityId, 'sleep');
    });

    test('a split night does not double-count frequency', () {
      final t0 = DateTime.utc(2026, 11, 1, 23).millisecondsSinceEpoch;
      final t1 = DateTime.utc(2026, 11, 2, 0).millisecondsSinceEpoch;
      final t2 = DateTime.utc(2026, 11, 2, 7).millisecondsSinceEpoch;
      final t3 = DateTime.utc(2026, 11, 2, 7, 30).millisecondsSinceEpoch;
      final target = DateTime.utc(2026, 11, 2, 15).millisecondsSinceEpoch;

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

      final ranked = engine.rank(
        candidates: [makeActivity('breakfast'), makeActivity('sleep')],
        history: history,
        precedingActivityId: null,
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      // Both are one run. With Sleep counted twice, Sleep would win.
      expect(ranked.first.id, 'breakfast');
    });

    test('contextFromHistory breaks at untracked gaps and repeated labels', () {
      final context = ContextualSuggestionEngine.contextFromHistory([
        makeRecord(id: 'r1', activityId: 'a', startedAtEpochMs: 1000),
        makeRecord(id: 'r2', activityId: null, startedAtEpochMs: 2000),
        makeRecord(id: 'r3', activityId: 'b', startedAtEpochMs: 3000),
        makeRecord(id: 'r4', activityId: null, startedAtEpochMs: 4000),
        makeRecord(id: 'r5', activityId: 'b', startedAtEpochMs: 5000),
        makeRecord(id: 'r6', activityId: 'c', startedAtEpochMs: 6000),
      ], targetEpochMs: 7000);

      expect(context.precedingActivityId, 'c');
      expect(context.secondPrecedingActivityId, 'b');
    });

    test('contextFromHistory returns no pair across an untracked gap', () {
      final context = ContextualSuggestionEngine.contextFromHistory([
        makeRecord(id: 'r1', activityId: 'a', startedAtEpochMs: 1000),
        makeRecord(id: 'r2', activityId: null, startedAtEpochMs: 2000),
        makeRecord(id: 'r3', activityId: 'b', startedAtEpochMs: 3000),
      ], targetEpochMs: 4000);

      expect(context.precedingActivityId, 'b');
      expect(context.secondPrecedingActivityId, isNull);
    });

    test('contextFromHistory handles empty and single-record histories', () {
      final empty = ContextualSuggestionEngine.contextFromHistory(
        const [],
        targetEpochMs: 2000,
      );
      expect(empty.precedingActivityId, isNull);
      expect(empty.secondPrecedingActivityId, isNull);

      final single = ContextualSuggestionEngine.contextFromHistory([
        makeRecord(id: 'r1', activityId: 'a', startedAtEpochMs: 1000),
      ], targetEpochMs: 2000);
      expect(single.precedingActivityId, 'a');
      expect(single.secondPrecedingActivityId, isNull);
    });

    test('Markov-2 distinguishes Gym -> Shower from Sleep -> Shower', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // Gym -> Shower -> Dinner on three days.
      for (final daysAgo in [8, 4, 2]) {
        final start = target - daysAgo * 86400000;
        history.add(add('gym', start));
        history.add(add('shower', start + hour));
        history.add(add('dinner', start + 2 * hour));
      }

      // Sleep -> Shower -> Commute on three other days.
      for (final daysAgo in [7, 5, 3]) {
        final start = target - daysAgo * 86400000 - 10 * hour;
        history.add(add('sleep', start));
        history.add(add('shower', start + hour));
        history.add(add('commute', start + 2 * hour));
      }

      ordered(history);
      final candidates = [
        makeActivity('commute'),
        makeActivity('dinner'),
        makeActivity('gym'),
        makeActivity('shower'),
      ];

      final gymRanked = engine.rank(
        candidates: candidates,
        history: history,
        precedingActivityId: 'shower',
        secondPrecedingActivityId: 'gym',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );
      expect(gymRanked.first.id, 'dinner');

      final sleepRanked = engine.rank(
        candidates: candidates,
        history: history,
        precedingActivityId: 'shower',
        secondPrecedingActivityId: 'sleep',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );
      expect(sleepRanked.first.id, 'commute');
    });

    test('an unseen pair backs off to Markov-1', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // Outcomes start three hours after the target's time of day, so only
      // the sequence decides; the time signal is tested on its own.
      for (final daysAgo in [5, 4, 3]) {
        final start = target - daysAgo * 86400000;
        history.add(add('shower', start));
        history.add(add('commute', start + 3 * hour));
      }
      for (final daysAgo in [2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('shower', start));
        history.add(add('dinner', start + 3 * hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('dinner'), makeActivity('commute')],
        history: history,
        precedingActivityId: 'shower',
        secondPrecedingActivityId: 'errand',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'commute');
    });

    test('a stale pair does not activate Markov-2 over a strong Markov-1', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // The pair (a, b) has two observations, but both are around 30 days old.
      for (final daysAgo in [30, 29]) {
        final start = target - daysAgo * 86400000;
        history.add(add('a', start));
        history.add(add('b', start + hour));
        history.add(add('d', start + 2 * hour));
      }

      // b -> c is a daily sequence for the last ten days.
      for (final daysAgo in [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('b', start));
        history.add(add('c', start + hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('c'), makeActivity('d')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'c');
    });

    test('a pair at the half-life boundary activates Markov-2', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // Two observations at 14 and 13 days: just over one fresh weight.
      for (final daysAgo in [14, 13]) {
        final start = target - daysAgo * 86400000;
        history.add(add('a', start));
        history.add(add('b', start + hour));
        history.add(add('d', start + 2 * hour));
      }

      for (final daysAgo in [5, 4, 3, 2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('b', start));
        history.add(add('c', start + hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('c'), makeActivity('d')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'd');
    });

    test('one observation of a pair does not activate Markov-2', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      final start = target - 2 * hour;
      history.add(add('a', start));
      history.add(add('b', start + hour));
      history.add(add('d', start + 2 * hour));

      for (final daysAgo in [5, 4, 3, 2, 1]) {
        final day = target - daysAgo * 86400000;
        history.add(add('b', day));
        history.add(add('c', day + hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('d'), makeActivity('c')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'c');
    });

    test('context mass counts outcomes that are not candidates', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // b -> c daily sequence.
      for (final daysAgo in [5, 4, 3, 2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('b', start));
        history.add(add('c', start + hour));
      }

      // Today: (a, b) -> z twice (z is not a candidate), then (a, b) -> d.
      for (final hoursAgo in [6, 4, 2]) {
        final start = target - hoursAgo * hour;
        history.add(add('a', start));
        history.add(add('b', start + hour));
        history.add(add(hoursAgo == 2 ? 'd' : 'z', start + 2 * hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('c'), makeActivity('d')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      // The pair is established by the z outcomes, so d's trigram wins over c's
      // stronger bigram.
      expect(ranked.first.id, 'd');
    });

    test(
      'an established pair with no candidate trigram falls back to Markov-1',
      () {
        final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
        final history = <SuggestionObservation>[];
        var id = 0;

        SuggestionObservation add(String activityId, int startMs) {
          id++;
          return makeRecord(
            id: 'r$id',
            activityId: activityId,
            startedAtEpochMs: startMs,
            endedAtEpochMs: startMs + hour,
          );
        }

        // b -> c daily sequence.
        for (final daysAgo in [5, 4, 3, 2, 1]) {
          final start = target - daysAgo * 86400000;
          history.add(add('b', start));
          history.add(add('c', start + hour));
        }

        // Today: (a, b) -> z twice. z is not a candidate.
        for (final hoursAgo in [4, 2]) {
          final start = target - hoursAgo * hour;
          history.add(add('a', start));
          history.add(add('b', start + hour));
          history.add(add('z', start + 2 * hour));
        }

        ordered(history);
        final ranked = engine.rank(
          candidates: [makeActivity('d'), makeActivity('c')],
          history: history,
          precedingActivityId: 'b',
          secondPrecedingActivityId: 'a',
          targetEpochMs: target,
          timezoneId: zoneUtc,
        );

        // The pair is established, but neither candidate has trigram evidence.
        // The comparator must fall through to b -> c, not stop at zero and use
        // the candidate list order (which would return d).
        expect(ranked.first.id, 'c');
      },
    );

    test('a token trigram outcome falls through to Markov-1', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // b -> c daily sequence.
      for (final daysAgo in [5, 4, 3, 2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('b', start));
        history.add(add('c', start + hour));
      }

      // The pair (a, b) is established by z outcomes; z is not a candidate.
      for (final daysAgo in [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]) {
        final start = target - daysAgo * 86400000;
        history.add(add('a', start));
        history.add(add('b', start + hour));
        history.add(add('z', start + 2 * hour));
      }

      // One token d outcome, exactly 60 days old. It is below the 10% share.
      final oldStart = target - 60 * 86400000;
      history.add(add('a', oldStart));
      history.add(add('b', oldStart + hour));
      history.add(add('d', oldStart + 2 * hour));

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('d'), makeActivity('c')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'c');
    });

    test('an untracked gap breaks the training chain', () {
      final target = DateTime.utc(2026, 11, 5, 18).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String? activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // Twice: a, untracked, b, c. If the gap were bridged, (a, b) -> c would
      // have two observations and activate Markov-2.
      for (final hoursAgo in [12, 10]) {
        final start = target - hoursAgo * hour;
        history.add(add('a', start));
        history.add(add(null, start + hour));
        history.add(add('b', start + 2 * hour));
        history.add(add('c', start + 3 * hour));
      }

      // b -> d is the stronger bigram.
      for (final hoursAgo in [8, 7, 6, 5, 4]) {
        final start = target - hoursAgo * hour;
        history.add(add('b', start));
        history.add(add('d', start + hour));
      }

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('c'), makeActivity('d')],
        history: history,
        precedingActivityId: 'b',
        secondPrecedingActivityId: 'a',
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'd');
    });

    test(
      'decay makes a recent pattern beat older but more frequent history',
      () {
        final target = DateTime.utc(2026, 11, 5, 15).millisecondsSinceEpoch;
        final history = <SuggestionObservation>[];
        var id = 0;

        SuggestionObservation add(String activityId, int startMs) {
          id++;
          return makeRecord(
            id: 'r$id',
            activityId: activityId,
            startedAtEpochMs: startMs,
            endedAtEpochMs: startMs + hour,
          );
        }

        // Recent: one record today at 03:00.
        history.add(add('recent', target - 12 * hour));

        // Old: three records around 30 days ago at 03:00.
        for (final daysAgo in [30, 29, 28]) {
          history.add(add('old', target - daysAgo * 86400000 - 12 * hour));
        }

        ordered(history);
        final ranked = engine.rank(
          candidates: [makeActivity('old'), makeActivity('recent')],
          history: history,
          precedingActivityId: null,
          targetEpochMs: target,
          timezoneId: zoneUtc,
        );

        expect(ranked.first.id, 'recent');
      },
    );

    test('temporal slot scores are decayed', () {
      final target = DateTime.utc(2026, 11, 4, 10).millisecondsSinceEpoch;
      final history = <SuggestionObservation>[];
      var id = 0;

      SuggestionObservation add(String activityId, int startMs) {
        id++;
        return makeRecord(
          id: 'r$id',
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: startMs + hour,
        );
      }

      // A: many evening records (high frequency) plus one old 10:00 record.
      for (final daysAgo in [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]) {
        history.add(add('a', target - daysAgo * 86400000 + 10 * hour));
      }
      history.add(add('a', target - 40 * 86400000));

      // B: one record at 10:00 today.
      history.add(add('b', target));

      ordered(history);
      final ranked = engine.rank(
        candidates: [makeActivity('a'), makeActivity('b')],
        history: history,
        precedingActivityId: null,
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      // A has far more frequency, but B's decayed temporal match wins first.
      expect(ranked.first.id, 'b');
    });

    test('a record that starts after the target is not evidence', () {
      final target = DateTime.utc(2026, 11, 5, 15).millisecondsSinceEpoch;
      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'future',
          startedAtEpochMs: target + hour,
          endedAtEpochMs: target + 2 * hour,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'past',
          startedAtEpochMs: target - hour,
          endedAtEpochMs: target,
        ),
      ];

      final ranked = engine.rank(
        candidates: [makeActivity('future'), makeActivity('past')],
        history: history,
        precedingActivityId: null,
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'past');
    });

    test('only the exact 60-day edge is evidence', () {
      final target = DateTime.utc(2026, 11, 5, 15).millisecondsSinceEpoch;
      final history = [
        makeRecord(
          id: 'r1',
          activityId: 'old',
          startedAtEpochMs: target - 61 * 86400000 - 12 * hour,
          endedAtEpochMs: target - 61 * 86400000 - 11 * hour,
        ),
        makeRecord(
          id: 'r2',
          activityId: 'beyond',
          startedAtEpochMs: target - 60 * 86400000 - 1,
          endedAtEpochMs: target - 60 * 86400000,
        ),
        makeRecord(
          id: 'r3',
          activityId: 'edge',
          startedAtEpochMs: target - 60 * 86400000,
          endedAtEpochMs: target - 60 * 86400000 + hour,
        ),
      ];

      final ranked = engine.rank(
        candidates: [
          makeActivity('old'),
          makeActivity('beyond'),
          makeActivity('edge'),
        ],
        history: history,
        precedingActivityId: null,
        targetEpochMs: target,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'edge');
    });

    test('equal scores preserve the candidate list order', () {
      final candidates = [
        makeActivity('act_3'),
        makeActivity('act_1'),
        makeActivity('act_2'),
      ];

      final ranked = engine.rank(
        candidates: candidates,
        history: const [],
        precedingActivityId: null,
        targetEpochMs: 1700000000000,
        timezoneId: zoneUtc,
      );

      expect(ranked.map((a) => a.id).toList(), ['act_3', 'act_1', 'act_2']);
    });

    test('Untracked preceding record (activityId == null) ignores Markov', () {
      final act1 = makeActivity('act_1');
      final act2 = makeActivity('act_2');

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

      final ranked = engine.rank(
        candidates: [act1, act2],
        history: history,
        precedingActivityId: null,
        targetEpochMs: 4000,
        timezoneId: zoneUtc,
      );

      expect(ranked.first.id, 'act_2');
    });

    test('Performance: execution time stays under the CI regression bound', () {
      final candidates = List.generate(20, (i) => makeActivity('act_$i'));
      final target = 1700000000000 + 60 * 86400000;
      final interval = (60 * 86400000) ~/ 6000;
      final history = List.generate(
        6000,
        (i) => makeRecord(
          id: 'r_$i',
          activityId: 'act_${i % 20}',
          startedAtEpochMs: target - 60 * 86400000 + i * interval,
          endedAtEpochMs: target - 60 * 86400000 + (i + 1) * interval,
          timezoneId: zoneNY,
        ),
      );

      // Warm up JIT.
      for (var i = 0; i < 5; i++) {
        engine.rank(
          candidates: candidates,
          history: history,
          precedingActivityId: 'act_3',
          secondPrecedingActivityId: 'act_2',
          targetEpochMs: target,
          timezoneId: zoneNY,
        );
      }

      final sw = Stopwatch()..start();
      const iterations = 50;
      for (var i = 0; i < iterations; i++) {
        engine.rank(
          candidates: candidates,
          history: history,
          precedingActivityId: 'act_3',
          secondPrecedingActivityId: 'act_2',
          targetEpochMs: target,
          timezoneId: zoneNY,
        );
      }
      sw.stop();
      final avgMicros = sw.elapsedMicroseconds / iterations;

      // Regression guard for shared CI runners, not the on-device 2 ms target.
      expect(avgMicros, lessThan(5000));
    });
  });
}
