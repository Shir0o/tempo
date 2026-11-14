import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/models/models.dart';

/// A weekday morning routine where Thursday differs: after Breakfast comes
/// Commute on Thursdays and Work on the other weekdays.
void main() {
  const engine = ContextualSuggestionEngine();
  const zone = 'America/Los_Angeles';
  // Thursday 12 November 2026.
  final today = DateTime.utc(2026, 11, 12);
  final reference = DateTime.utc(2026, 11, 12, 16).millisecondsSinceEpoch;

  int at(DateTime day, int hour, int minute) => epochMsFromWallClock(
    DateTime.utc(day.year, day.month, day.day, hour, minute),
    zone,
    referenceEpochMs: reference,
  );

  Activity activity(String id) =>
      Activity(id: id, name: id, createdAtEpochMs: 0, updatedAtEpochMs: 0);

  final candidates = [
    for (final id in [
      'morning',
      'bible',
      'grooming',
      'breakfast',
      'commute',
      'work',
    ])
      activity(id),
  ];

  /// Six weeks of weekday mornings before [today], then [todaySoFar].
  List<SuggestionObservation> history(List<(String, int, int)> todaySoFar) {
    final observations = <SuggestionObservation>[];
    void add(String id, DateTime day, int hour, int minute) => observations.add(
      SuggestionObservation(
        activityId: id,
        startedAtEpochMs: at(day, hour, minute),
        timezoneId: zone,
      ),
    );

    for (var daysAgo = 42; daysAgo >= 1; daysAgo--) {
      final day = today.subtract(Duration(days: daysAgo));
      if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
        continue;
      }
      add('morning', day, 6, 30);
      add('bible', day, 7, 0);
      add('grooming', day, 7, 30);
      add('breakfast', day, 7, 50);
      if (day.weekday == DateTime.thursday) {
        add('commute', day, 8, 5);
      } else {
        add('work', day, 8, 30);
      }
    }
    for (final (id, hour, minute) in todaySoFar) {
      add(id, today, hour, minute);
    }
    return observations;
  }

  List<RankedSuggestion> rankAt(
    List<SuggestionObservation> observations,
    int hour,
    int minute,
  ) {
    final target = at(today, hour, minute);
    final context = ContextualSuggestionEngine.contextFromHistory(
      observations,
      targetEpochMs: target,
    );
    return engine.rankExplained(
      candidates: candidates,
      history: observations,
      precedingActivityId: context.precedingActivityId,
      secondPrecedingActivityId: context.secondPrecedingActivityId,
      targetEpochMs: target,
      timezoneId: zone,
      limit: 4,
    );
  }

  test('Thursday after Breakfast suggests Commute, not Work', () {
    final ranked = rankAt(
      history([
        ('morning', 6, 30),
        ('bible', 7, 0),
        ('grooming', 7, 30),
        ('breakfast', 7, 50),
      ]),
      8,
      2,
    );

    expect(ranked.first.activity.id, 'commute');
  });

  test('Thursday Commute explains itself by the day and time', () {
    // Breakfast skipped today, so the sequence says little about Commute and
    // the Thursday slot carries it.
    final ranked = rankAt(
      history([('morning', 6, 30), ('bible', 7, 0), ('grooming', 7, 30)]),
      8,
      5,
    );

    final commute = ranked.firstWhere((s) => s.activity.id == 'commute');
    expect(ranked.indexOf(commute), lessThan(2));
    expect(commute.reason?.kind, SuggestionReasonKind.weekday);
    expect(commute.reason?.weekday, DateTime.thursday);
    expect(commute.reason?.minuteOfDay, 8 * 60 + 5);
  });

  test('after Bible reading suggests Grooming and says why', () {
    final ranked = rankAt(
      history([('morning', 6, 30), ('bible', 7, 0)]),
      7,
      30,
    );

    expect(ranked.first.activity.id, 'grooming');
    expect(ranked.first.reason?.kind, SuggestionReasonKind.after);
    expect(ranked.first.reason?.activityId, 'bible');
  });

  test('another weekday after Breakfast still suggests Work', () {
    // Friday 13 November 2026.
    final friday = DateTime.utc(2026, 11, 13);
    final observations = history([
      ('morning', 6, 30),
      ('bible', 7, 0),
      ('grooming', 7, 30),
      ('breakfast', 7, 50),
    ]);
    // Move today's four Records from Thursday to Friday.
    final moved = [
      for (final o in observations)
        if (o.startedAtEpochMs >= at(today, 0, 0))
          SuggestionObservation(
            activityId: o.activityId,
            startedAtEpochMs: o.startedAtEpochMs + Duration.millisecondsPerDay,
            timezoneId: zone,
          )
        else
          o,
    ];
    final target = at(friday, 8, 2);
    final ranked = engine.rankExplained(
      candidates: candidates,
      history: moved,
      precedingActivityId: 'breakfast',
      secondPrecedingActivityId: 'grooming',
      targetEpochMs: target,
      timezoneId: zone,
    );

    expect(ranked.first.activity.id, 'work');
  });

  test('no history gives no reason', () {
    final ranked = engine.rankExplained(
      candidates: candidates,
      history: const [],
      precedingActivityId: null,
      targetEpochMs: at(today, 8, 0),
      timezoneId: zone,
    );

    expect(ranked.every((s) => s.reason == null), isTrue);
  });
}
