import 'dart:math' as math;

import '../../data/models/models.dart';
import '../time/timezone_id.dart';

/// The two Activities immediately before the one being suggested.
///
/// Both are run ids: consecutive observations with the same Activity (a
/// MidnightSplit, or a label repeated without an intervening Activity) count
/// as one step.
class SuggestionContext {
  final String? precedingActivityId;
  final String? secondPrecedingActivityId;

  const SuggestionContext({
    this.precedingActivityId,
    this.secondPrecedingActivityId,
  });
}

/// Why an Activity was suggested: the signal that carried most of its score.
enum SuggestionReasonKind {
  /// It usually follows the preceding Activity.
  after,

  /// It usually starts around this time on this day of the week.
  weekday,

  /// It usually starts around this time on weekdays, or on weekends.
  dayGroup,

  /// It is simply logged often.
  frequent,
}

class SuggestionReason {
  final SuggestionReasonKind kind;

  /// The preceding Activity, for [SuggestionReasonKind.after].
  final String? activityId;

  /// The day of the week (`DateTime.monday`..`DateTime.sunday`), for
  /// [SuggestionReasonKind.weekday].
  final int? weekday;

  /// Whether the slot is the weekend, for [SuggestionReasonKind.dayGroup].
  final bool? isWeekend;

  /// The typical local start, in minutes after midnight, rounded to five
  /// minutes, for the two time kinds.
  final int? minuteOfDay;

  const SuggestionReason.after(String this.activityId)
    : kind = SuggestionReasonKind.after,
      weekday = null,
      isWeekend = null,
      minuteOfDay = null;

  const SuggestionReason.weekday(int this.weekday, int this.minuteOfDay)
    : kind = SuggestionReasonKind.weekday,
      activityId = null,
      isWeekend = null;

  const SuggestionReason.dayGroup(bool this.isWeekend, int this.minuteOfDay)
    : kind = SuggestionReasonKind.dayGroup,
      activityId = null,
      weekday = null;

  const SuggestionReason.frequent()
    : kind = SuggestionReasonKind.frequent,
      activityId = null,
      weekday = null,
      isWeekend = null,
      minuteOfDay = null;
}

/// A ranked Activity and why it ranked, or no reason when nothing in the
/// history speaks for it.
class RankedSuggestion {
  final Activity activity;
  final SuggestionReason? reason;

  const RankedSuggestion(this.activity, this.reason);
}

/// Contextual prediction engine that blends two kinds of evidence:
///
/// - **Sequence**: what usually follows the preceding Activity. Markov-2
///   ((A_t-2, A_t-1) -> A_t) is interpolated with Markov-1 (A_t-1 -> A_t)
///   when the pair is established; otherwise Markov-1 alone. Once the
///   target's day of the week has enough transitions of its own, they are
///   blended in, because a routine can differ by day (after Breakfast:
///   Commute on Thursdays, Work otherwise).
/// - **Time**: what usually starts within an hour of the target's local time,
///   on the same day of the week, blended with weekday-versus-weekend. When
///   that day of the week has too little history, weekday-versus-weekend alone.
///
/// Each signal is a share of its own evidence (0..1), so an Activity strong on
/// both outranks one strong on only one. Sequence weighs slightly more than
/// time, and overall frequency is a light tie-breaker.
///
/// Every observation is weighted by a 14-day half-life over a 60-day window.
/// Weights are held as integer micro-units so equal scores compare exactly and
/// the candidate-order tie-breaker stays stable.
///
/// Execution is pure, deterministic, and targeted under 2 ms for thousands of
/// observations. [history] must be ordered ascending by start time (callers use
/// `started_at_epoch_ms ASC, rowid ASC`).
class ContextualSuggestionEngine {
  const ContextualSuggestionEngine();

  /// The history window callers should query.
  static const int historyWindowDays = 60;
  static const Duration historyWindow = Duration(days: historyWindowDays);

  /// A weight halves every this many days.
  static const int _halfLifeDays = 14;

  /// One full-weight observation.
  static const int _microsPerUnit = 1000000;

  /// A trigram pair must have at least this many completed observations and
  /// this much decayed mass before it takes part.
  static const int _pairMinObservations = 2;
  static const int _pairMinContextMass = _microsPerUnit;

  /// A candidate takes trigram credit only when its trigram score is at least
  /// one tenth of the pair's context mass. This stops a single old outcome
  /// from riding on an established pair.
  static const int _trigramMinShareDenominator = 10;

  /// With an established pair, sequence is 7 parts trigram to 3 parts bigram.
  static const int _trigramParts = 7;
  static const int _bigramParts = 3;

  /// A past start counts for the time signal within this many minutes of the
  /// target's local time of day, either side.
  static const int _slotWindowMinutes = 60;

  /// The day of the week joins a signal once that signal has seen it at least
  /// twice and still holds one fresh observation's worth of decayed mass, the
  /// same bar a trigram pair must clear.
  static const int _weekdayMinObservations = 2;
  static const int _weekdayMinMass = _microsPerUnit;

  /// Signal weights in the blended score.
  static const int _sequenceWeight = 10;
  static const int _timeWeight = 8;
  static const int _frequencyWeight = 1;

  /// Decay weight for a whole day of age, in micro-units. Index 0 is today.
  static final List<int> _weightMicrosByDay = List<int>.unmodifiable(
    List<int>.generate(
      historyWindowDays + 1,
      (day) => (math.pow(0.5, day / _halfLifeDays) * _microsPerUnit).round(),
    ),
  );

  static int _weightMicrosForAge(int ageDays) {
    if (ageDays < 0 || ageDays > historyWindowDays) return 0;
    return _weightMicrosByDay[ageDays];
  }

  /// [score] as a share of [mass], in micro-units.
  static int _share(int score, int mass) =>
      mass <= 0 ? 0 : score * _microsPerUnit ~/ mass;

  /// The last two run ids in [history], skipping future and out-of-window
  /// observations and resetting at Untracked Records.
  ///
  /// This follows the same chain rule as [rank], so the context cannot name a
  /// run the chain rejected. Callers pass this result back into [rank] so both
  /// come from the same snapshot.
  static SuggestionContext contextFromHistory(
    Iterable<SuggestionObservation> history, {
    required int targetEpochMs,
  }) {
    String? preceding;
    String? second;
    for (final observation in history) {
      final activityId = observation.activityId;
      final ageMs = targetEpochMs - observation.startedAtEpochMs;
      if (activityId == null ||
          ageMs < 0 ||
          ageMs > historyWindow.inMilliseconds) {
        preceding = null;
        second = null;
        continue;
      }
      if (activityId == preceding) continue;
      second = preceding;
      preceding = activityId;
    }
    return SuggestionContext(
      precedingActivityId: preceding,
      secondPrecedingActivityId: second,
    );
  }

  List<Activity> rank({
    required List<Activity> candidates,
    required Iterable<SuggestionObservation> history,
    required String? precedingActivityId,
    String? secondPrecedingActivityId,
    required int targetEpochMs,
    required String timezoneId,
    int limit = 6,
  }) => [
    for (final suggestion in rankExplained(
      candidates: candidates,
      history: history,
      precedingActivityId: precedingActivityId,
      secondPrecedingActivityId: secondPrecedingActivityId,
      targetEpochMs: targetEpochMs,
      timezoneId: timezoneId,
      limit: limit,
    ))
      suggestion.activity,
  ];

  /// [rank], with the reason each Activity ranked where it did.
  List<RankedSuggestion> rankExplained({
    required List<Activity> candidates,
    required Iterable<SuggestionObservation> history,
    required String? precedingActivityId,
    String? secondPrecedingActivityId,
    required int targetEpochMs,
    required String timezoneId,
    int limit = 6,
  }) {
    assert(
      secondPrecedingActivityId == null || precedingActivityId != null,
      'A second preceding Activity needs a preceding Activity.',
    );

    final activeCandidates = candidates
        .where((activity) => !activity.isArchived)
        .toList();
    if (activeCandidates.isEmpty || limit <= 0) {
      return const [];
    }

    // Preserve original index for deterministic tie-breaking
    final candidateIndex = <String, int>{
      for (var i = 0; i < activeCandidates.length; i++)
        activeCandidates[i].id: i,
    };

    final targetWallClock = wallClockAt(timezoneId, targetEpochMs);
    final targetMinute = targetWallClock.hour * 60 + targetWallClock.minute;
    final targetWeekday = targetWallClock.weekday;
    final targetIsWeekend = _isWeekend(targetWeekday);

    // Decayed scores. Scores count candidates only; each mass counts every
    // run it covers, including outcomes that are archived or not offered, so
    // a share measures how much of real life the candidate accounts for.
    final frequencyScore = <String, int>{};
    final daySlotScore = <String, int>{};
    final groupSlotScore = <String, int>{};
    final bigramScore = <String, int>{};
    final dayBigramScore = <String, int>{};
    final trigramScore = <String, int>{};
    // Weighted sums of signed minute offsets from the target, for the typical
    // start shown in a reason.
    final daySlotOffset = <String, int>{};
    final groupSlotOffset = <String, int>{};
    var frequencyMass = 0;
    var daySlotMass = 0;
    var groupSlotMass = 0;
    var bigramMass = 0;
    var dayBigramMass = 0;
    var daySlotObservations = 0;
    var dayBigramObservations = 0;
    var contextMass = 0;
    var pairObservations = 0;

    // Chain state, in runs rather than observations.
    String? previousRunId;
    String? secondPreviousRunId;
    String? currentRunId;

    void add(Map<String, int> scores, String id, int weight) {
      scores.update(id, (value) => value + weight, ifAbsent: () => weight);
    }

    for (final observation in history) {
      final activityId = observation.activityId;

      // An Untracked Record is unknown time. It breaks the training chain and
      // contributes no score.
      if (activityId == null) {
        previousRunId = null;
        secondPreviousRunId = null;
        currentRunId = null;
        continue;
      }

      // A MidnightSplit or a repeated label continues the current run.
      if (activityId == currentRunId) {
        continue;
      }

      final ageMs = targetEpochMs - observation.startedAtEpochMs;
      // A Record that starts after the target or outside the history window is
      // not evidence about the past. It also breaks the chain rather than
      // bridging the Activity before it to the Activity after it.
      if (ageMs < 0 || ageMs > historyWindow.inMilliseconds) {
        previousRunId = null;
        secondPreviousRunId = null;
        currentRunId = null;
        continue;
      }

      final ageDays = ageMs ~/ Duration.millisecondsPerDay;
      final weightMicros = _weightMicrosForAge(ageDays);
      if (weightMicros == 0) {
        previousRunId = null;
        secondPreviousRunId = null;
        currentRunId = null;
        continue;
      }

      final isCandidate = candidateIndex.containsKey(activityId);

      frequencyMass += weightMicros;
      if (isCandidate) add(frequencyScore, activityId, weightMicros);

      // Time slot match, using the run's start in its own zone.
      final recordWallClock = observation.timezoneId == 'UTC'
          ? DateTime.fromMillisecondsSinceEpoch(
              observation.startedAtEpochMs,
              isUtc: true,
            )
          : wallClockAt(observation.timezoneId, observation.startedAtEpochMs);
      var offset =
          recordWallClock.hour * 60 + recordWallClock.minute - targetMinute;
      // Wrap so 23:50 is ten minutes before 00:00, not 23h50 after it.
      if (offset > 720) offset -= 1440;
      if (offset <= -720) offset += 1440;
      if (offset.abs() <= _slotWindowMinutes) {
        if (_isWeekend(recordWallClock.weekday) == targetIsWeekend) {
          groupSlotMass += weightMicros;
          if (isCandidate) {
            add(groupSlotScore, activityId, weightMicros);
            add(groupSlotOffset, activityId, weightMicros * offset);
          }
        }
        if (recordWallClock.weekday == targetWeekday) {
          daySlotMass += weightMicros;
          daySlotObservations++;
          if (isCandidate) {
            add(daySlotScore, activityId, weightMicros);
            add(daySlotOffset, activityId, weightMicros * offset);
          }
        }
      }

      // Markov-1 transition from the query's preceding Activity into this run.
      if (precedingActivityId != null && previousRunId == precedingActivityId) {
        bigramMass += weightMicros;
        if (isCandidate) add(bigramScore, activityId, weightMicros);
        if (recordWallClock.weekday == targetWeekday) {
          dayBigramMass += weightMicros;
          dayBigramObservations++;
          if (isCandidate) add(dayBigramScore, activityId, weightMicros);
        }
      }

      // Markov-2 transition into this run, gated on the query pair.
      if (precedingActivityId != null &&
          secondPrecedingActivityId != null &&
          previousRunId == precedingActivityId &&
          secondPreviousRunId == secondPrecedingActivityId) {
        contextMass += weightMicros;
        pairObservations++;
        if (isCandidate) add(trigramScore, activityId, weightMicros);
      }

      secondPreviousRunId = previousRunId;
      previousRunId = activityId;
      currentRunId = activityId;
    }

    // A pair must be seen at least twice and still carry one fresh
    // observation's worth of decayed mass before it takes part.
    final trigramActive =
        precedingActivityId != null &&
        secondPrecedingActivityId != null &&
        pairObservations >= _pairMinObservations &&
        contextMass >= _pairMinContextMass;
    final weekdayActive =
        daySlotObservations >= _weekdayMinObservations &&
        daySlotMass >= _weekdayMinMass;
    final weekdaySequenceActive =
        dayBigramObservations >= _weekdayMinObservations &&
        dayBigramMass >= _weekdayMinMass;

    final totals = <String, int>{};
    final reasons = <String, SuggestionReason?>{};
    for (final activity in activeCandidates) {
      final id = activity.id;

      final bigramShare = _share(bigramScore[id] ?? 0, bigramMass);
      var sequence = bigramShare;
      if (trigramActive) {
        final trigram = trigramScore[id] ?? 0;
        final strong = trigram * _trigramMinShareDenominator >= contextMass;
        final trigramShare = strong ? _share(trigram, contextMass) : 0;
        sequence =
            (_trigramParts * trigramShare + _bigramParts * bigramShare) ~/
            (_trigramParts + _bigramParts);
      }
      if (weekdaySequenceActive) {
        final dayShare = _share(dayBigramScore[id] ?? 0, dayBigramMass);
        sequence = (sequence + dayShare) ~/ 2;
      }

      final groupShare = _share(groupSlotScore[id] ?? 0, groupSlotMass);
      final dayShare = _share(daySlotScore[id] ?? 0, daySlotMass);
      final time = weekdayActive ? (dayShare + groupShare) ~/ 2 : groupShare;

      final frequency = _share(frequencyScore[id] ?? 0, frequencyMass);

      // Runs collapse a repeated label, so the next run is never the
      // preceding Activity; Still and Again already repeat it in one tap.
      if (id == precedingActivityId) {
        totals[id] = 0;
        reasons[id] = null;
        continue;
      }

      final sequencePart = _sequenceWeight * sequence;
      final timePart = _timeWeight * time;
      totals[id] = sequencePart + timePart + _frequencyWeight * frequency;

      SuggestionReason? reason;
      if (sequencePart > 0 && sequencePart >= timePart) {
        reason = SuggestionReason.after(precedingActivityId!);
      } else if (timePart > 0) {
        final useDay = weekdayActive && (daySlotScore[id] ?? 0) > 0;
        final score = useDay ? daySlotScore[id]! : groupSlotScore[id]!;
        final offsetSum = useDay ? daySlotOffset[id]! : groupSlotOffset[id]!;
        final minute = _roundedMinute(targetMinute + offsetSum ~/ score);
        reason = useDay
            ? SuggestionReason.weekday(targetWeekday, minute)
            : SuggestionReason.dayGroup(targetIsWeekend, minute);
      } else if (frequency > 0) {
        reason = const SuggestionReason.frequent();
      }
      reasons[id] = reason;
    }

    final sorted = List<Activity>.from(activeCandidates)
      ..sort((a, b) {
        final byTotal = totals[b.id]!.compareTo(totals[a.id]!);
        if (byTotal != 0) return byTotal;
        return candidateIndex[a.id]!.compareTo(candidateIndex[b.id]!);
      });

    return [
      for (final activity in sorted.take(limit))
        RankedSuggestion(activity, reasons[activity.id]),
    ];
  }

  /// [minute] rounded to five minutes and wrapped into one day.
  static int _roundedMinute(int minute) {
    final wrapped = minute % 1440;
    return (((wrapped + 2) ~/ 5) * 5) % 1440;
  }

  static bool _isWeekend(int weekday) =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;
}
