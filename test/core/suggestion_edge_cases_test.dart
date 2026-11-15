import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/models/models.dart';

/// Edge cases for the blended suggestions (issue #142): habitual sequences,
/// weekly slots, empty history, gaps in the Day, and time zone and DST changes.
void main() {
  const engine = ContextualSuggestionEngine();
  const la = 'America/Los_Angeles';
  const ny = 'America/New_York';
  const tokyo = 'Asia/Tokyo';

  Activity activity(String id, {bool isArchived = false}) => Activity(
    id: id,
    name: id,
    isArchived: isArchived,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  /// The instant [day] at [hour]:[minute] on the wall clock in [zone].
  int at(DateTime day, int hour, int minute, [String zone = la]) =>
      epochMsFromWallClock(
        DateTime.utc(day.year, day.month, day.day, hour, minute),
        zone,
        referenceEpochMs: DateTime.utc(
          day.year,
          day.month,
          day.day,
          12,
        ).millisecondsSinceEpoch,
      );

  SuggestionObservation obs(
    String? id,
    DateTime day,
    int hour,
    int minute, [
    String zone = la,
  ]) => SuggestionObservation(
    activityId: id,
    startedAtEpochMs: at(day, hour, minute, zone),
    timezoneId: zone,
  );

  List<RankedSuggestion> rankAt(
    List<SuggestionObservation> history,
    List<Activity> candidates,
    int target, {
    String zone = la,
    int limit = 4,
  }) {
    history.sort((a, b) => a.startedAtEpochMs.compareTo(b.startedAtEpochMs));
    final context = ContextualSuggestionEngine.contextFromHistory(
      history,
      targetEpochMs: target,
    );
    return engine.rankExplained(
      candidates: candidates,
      history: history,
      precedingActivityId: context.precedingActivityId,
      secondPrecedingActivityId: context.secondPrecedingActivityId,
      targetEpochMs: target,
      timezoneId: zone,
      limit: limit,
    );
  }

  List<String> ids(List<RankedSuggestion> ranked) => [
    for (final suggestion in ranked) suggestion.activity.id,
  ];

  /// Each Thursday in the [weeks] weeks before [thursday], Commute at 08:00
  /// for half an hour, then Work at 08:30, then Untracked time from 09:00, in
  /// [zone]. The Untracked time keeps one week from leading into the next.
  List<SuggestionObservation> thursdayCommutes(
    DateTime thursday,
    int weeks, {
    String zone = la,
  }) => [
    for (var week = weeks; week >= 1; week--) ...[
      obs('commute', thursday.subtract(Duration(days: 7 * week)), 8, 0, zone),
      obs('work', thursday.subtract(Duration(days: 7 * week)), 8, 30, zone),
      obs(null, thursday.subtract(Duration(days: 7 * week)), 9, 0, zone),
    ],
  ];

  final weeklyCandidates = [
    activity('work'),
    activity('breakfast'),
    activity('commute'),
  ];

  group('habitual sequences', () {
    final candidates = [
      activity('breakfast'),
      activity('grooming'),
      activity('bible'),
      activity('reading'),
    ];

    /// Bible reading at 06:30 then Grooming at 07:00 on each recent day.
    List<SuggestionObservation> mornings(DateTime today, int days) => [
      for (var daysAgo = days; daysAgo >= 1; daysAgo--) ...[
        obs('bible', today.subtract(Duration(days: daysAgo)), 6, 30),
        obs('grooming', today.subtract(Duration(days: daysAgo)), 7, 0),
        obs('breakfast', today.subtract(Duration(days: daysAgo)), 7, 30),
      ],
    ];

    test('Grooming follows Bible reading even at an unusual hour', () {
      final today = DateTime.utc(2026, 11, 14);
      // Bible reading late today, hours away from its usual slot.
      final history = mornings(today, 10)..add(obs('bible', today, 10, 0));

      final ranked = rankAt(history, candidates, at(today, 10, 40));

      expect(ranked.first.activity.id, 'grooming');
      expect(ranked.first.reason?.kind, SuggestionReasonKind.after);
      expect(ranked.first.reason?.activityId, 'bible');
    });

    test('a MidnightSplit of Bible reading still leads to Grooming', () {
      final today = DateTime.utc(2026, 11, 14);
      final yesterday = today.subtract(const Duration(days: 1));
      final history = mornings(today, 10)
        ..add(obs('bible', yesterday, 23, 40))
        ..add(obs('bible', today, 0, 0));

      final ranked = rankAt(history, candidates, at(today, 0, 20));

      expect(ranked.first.activity.id, 'grooming');
    });

    test('the Activity just logged is not suggested again', () {
      final today = DateTime.utc(2026, 11, 14);
      final history = mornings(today, 10)..add(obs('bible', today, 6, 30));

      final ranked = rankAt(history, candidates, at(today, 6, 31));

      expect(ids(ranked).first, 'grooming');
      expect(ids(ranked).indexOf('bible'), greaterThan(0));
      expect(ranked.firstWhere((s) => s.activity.id == 'bible').reason, null);
    });
  });

  group('weekly patterns', () {
    // Thursday 12 November 2026.
    final thursday = DateTime.utc(2026, 11, 12);

    test('a Thursday 08:00 to 08:30 Commute leads at 08:00 on Thursday', () {
      final history = thursdayCommutes(thursday, 6)
        // Breakfast at 08:00 on the other weekdays.
        ..addAll([
          for (var daysAgo = 1; daysAgo <= 42; daysAgo++)
            if (thursday.subtract(Duration(days: daysAgo)).weekday
                case final weekday
                when weekday != DateTime.thursday &&
                    weekday != DateTime.saturday &&
                    weekday != DateTime.sunday) ...[
              obs(
                'breakfast',
                thursday.subtract(Duration(days: daysAgo)),
                8,
                0,
              ),
              obs(null, thursday.subtract(Duration(days: daysAgo)), 8, 30),
            ],
        ]);

      final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

      expect(ranked.first.activity.id, 'commute');
      final reason = ranked.first.reason!;
      expect(reason.kind, SuggestionReasonKind.weekday);
      expect(reason.weekday, DateTime.thursday);
      expect(reason.minuteOfDay, 8 * 60);
    });

    test('the Thursday Commute does not lead on Friday', () {
      final friday = thursday.add(const Duration(days: 1));
      final history = thursdayCommutes(thursday, 6)
        ..addAll([
          for (var week = 6; week >= 1; week--) ...[
            obs('breakfast', friday.subtract(Duration(days: 7 * week)), 8, 0),
            obs(null, friday.subtract(Duration(days: 7 * week)), 8, 30),
          ],
        ]);

      final ranked = rankAt(history, weeklyCandidates, at(friday, 8, 0));

      expect(ranked.first.activity.id, 'breakfast');
      expect(ranked.first.reason?.weekday, DateTime.friday);
    });

    test('labeling a Lap that opened at 08:05 still finds the Commute', () {
      final history = thursdayCommutes(thursday, 6);

      final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 5));

      expect(ranked.first.activity.id, 'commute');
      expect(ranked.first.reason?.minuteOfDay, 8 * 60);
    });
  });

  group('empty history', () {
    test('no history keeps the candidate order and gives no reasons', () {
      final ranked = rankAt([], weeklyCandidates, at(DateTime.utc(2026), 8, 0));

      expect(ids(ranked), ['work', 'breakfast', 'commute']);
      expect(ranked.every((suggestion) => suggestion.reason == null), isTrue);
    });

    test('only Untracked time gives no reasons and no context', () {
      final day = DateTime.utc(2026, 11, 12);
      final history = [obs(null, day, 6, 0), obs(null, day, 7, 0)];
      final target = at(day, 8, 0);

      final context = ContextualSuggestionEngine.contextFromHistory(
        history,
        targetEpochMs: target,
      );
      final ranked = rankAt(history, weeklyCandidates, target);

      expect(context.precedingActivityId, isNull);
      expect(ranked.every((suggestion) => suggestion.reason == null), isTrue);
    });

    test('no candidates, or only archived ones, give nothing', () {
      final day = DateTime.utc(2026, 11, 12);
      final history = thursdayCommutes(day, 2);

      expect(rankAt(history, [], at(day, 8, 0)), isEmpty);
      expect(
        rankAt(history, [activity('commute', isArchived: true)], at(day, 8, 0)),
        isEmpty,
      );
      expect(rankAt(history, weeklyCandidates, at(day, 8, 0), limit: 0), []);
    });
  });

  group('gaps in the Day', () {
    // The app reads no calendar; a gap is Untracked time or days with
    // nothing logged, such as a week away.
    final thursday = DateTime.utc(2026, 11, 12);

    test('a week away does not erase the Thursday Commute', () {
      // Thursdays three to six weeks back, then two empty weeks.
      final history = [
        for (var week = 6; week >= 3; week--) ...[
          obs('commute', thursday.subtract(Duration(days: 7 * week)), 8, 0),
          obs('work', thursday.subtract(Duration(days: 7 * week)), 8, 30),
          obs(null, thursday.subtract(Duration(days: 7 * week)), 9, 0),
        ],
      ];

      final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

      expect(ranked.first.activity.id, 'commute');
      expect(ranked.first.reason?.kind, SuggestionReasonKind.weekday);
    });

    test('Untracked time between two Activities breaks the sequence', () {
      final day = DateTime.utc(2026, 11, 14);
      final history = [
        for (var daysAgo = 10; daysAgo >= 1; daysAgo--) ...[
          obs('bible', day.subtract(Duration(days: daysAgo)), 6, 30),
          obs('grooming', day.subtract(Duration(days: daysAgo)), 7, 0),
        ],
        // Today: Bible reading, then an Untracked stretch.
        obs('bible', day, 13, 0),
        obs(null, day, 13, 30),
      ];

      final ranked = rankAt(history, [
        activity('grooming'),
        activity('bible'),
      ], at(day, 14, 0));

      // No preceding Activity, so nothing claims to follow Bible reading.
      expect(
        ranked.any((s) => s.reason?.kind == SuggestionReasonKind.after),
        isFalse,
      );
    });

    test('a gap inside a routine does not bridge its two halves', () {
      final day = DateTime.utc(2026, 11, 14);
      // Bible reading is always followed by Untracked time, then Breakfast.
      final history = [
        for (var daysAgo = 10; daysAgo >= 1; daysAgo--) ...[
          obs('bible', day.subtract(Duration(days: daysAgo)), 6, 30),
          obs(null, day.subtract(Duration(days: daysAgo)), 7, 0),
          obs('breakfast', day.subtract(Duration(days: daysAgo)), 7, 30),
          obs('grooming', day.subtract(Duration(days: daysAgo)), 18, 0),
        ],
        obs('bible', day, 15, 0),
      ];

      final ranked = rankAt(history, [
        activity('breakfast'),
        activity('grooming'),
      ], at(day, 15, 30));

      expect(
        ranked.where((s) => s.reason?.kind == SuggestionReasonKind.after),
        isEmpty,
      );
    });
  });

  group('time zone and DST changes', () {
    test('the 08:00 Commute stays at 08:00 across the fall-back change', () {
      // US clocks fell back on Sunday 1 November 2026, so three of these
      // Thursdays are in PDT and two in PST.
      final thursday = DateTime.utc(2026, 11, 19);
      final history = thursdayCommutes(thursday, 5);

      final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

      expect(ranked.first.activity.id, 'commute');
      expect(ranked.first.reason?.minuteOfDay, 8 * 60);
    });

    test(
      'the 08:00 Commute stays at 08:00 across the spring-forward change',
      () {
        // US clocks sprang forward on Sunday 8 March 2026.
        final thursday = DateTime.utc(2026, 3, 19);
        final history = thursdayCommutes(thursday, 5);

        final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

        expect(ranked.first.activity.id, 'commute');
        expect(ranked.first.reason?.minuteOfDay, 8 * 60);
      },
    );

    test('a routine lived in New York is found in Los Angeles', () {
      final thursday = DateTime.utc(2026, 11, 12);
      final history = thursdayCommutes(thursday, 6, zone: ny);

      final ranked = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

      expect(ranked.first.activity.id, 'commute');
      expect(ranked.first.reason?.weekday, DateTime.thursday);
      expect(ranked.first.reason?.minuteOfDay, 8 * 60);
    });

    test('a Thursday morning in Tokyo is Thursday, not Wednesday in LA', () {
      // 08:00 Thursday in Tokyo is 15:00 Wednesday in Los Angeles.
      final thursday = DateTime.utc(2026, 11, 12);
      final history = thursdayCommutes(thursday, 6, zone: tokyo);

      final inTokyo = rankAt(
        history,
        weeklyCandidates,
        at(thursday, 8, 0, tokyo),
        zone: tokyo,
      );
      final inLa = rankAt(history, weeklyCandidates, at(thursday, 8, 0));

      expect(inTokyo.first.reason?.weekday, DateTime.thursday);
      expect(inLa.first.activity.id, 'commute');
      expect(inLa.first.reason?.weekday, DateTime.thursday);
    });

    test('the repeated hour at fall-back keeps its own wall clock', () {
      // 01:30 happens twice on 1 November 2026 in Los Angeles. Reading
      // started at the first 01:30 (PDT); the target is the second (PST).
      final firstOneThirty = DateTime.utc(2026, 11, 1, 8, 30);
      final secondOneThirty = DateTime.utc(2026, 11, 1, 9, 30);
      expect(
        wallClockAt(la, firstOneThirty.millisecondsSinceEpoch).hour,
        wallClockAt(la, secondOneThirty.millisecondsSinceEpoch).hour,
      );
      final history = [
        SuggestionObservation(
          activityId: 'reading',
          startedAtEpochMs: firstOneThirty.millisecondsSinceEpoch,
          timezoneId: la,
        ),
        SuggestionObservation(
          activityId: null,
          startedAtEpochMs: firstOneThirty.millisecondsSinceEpoch + 1800000,
          timezoneId: la,
        ),
      ];

      final ranked = rankAt(history, [
        activity('work'),
        activity('reading'),
      ], secondOneThirty.millisecondsSinceEpoch);

      expect(ranked.first.activity.id, 'reading');
      expect(ranked.first.reason?.minuteOfDay, 90);
    });
  });
}
