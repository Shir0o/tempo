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
///   on the same day of the week, blended 2:1 with weekday-versus-weekend, and
///   counting a start more the closer it is to the target's minute. When
///   that day of the week has too little history, weekday-versus-weekend alone.
///
/// Each signal is a share of its own evidence (0..1), so an Activity strong on
/// both outranks one strong on only one. Sequence weighs slightly more than
/// time, and overall frequency is a light tie-breaker.
///
/// The user's feedback on past suggestions then scales each score: a vote
/// counts fully in the same situation (the same preceding Activity, within an
/// hour on the same day of the week) and much less as the situation differs.
/// Not useful cuts a score hard, good raises it up to double, and tapping a
/// suggestion is a light good. Feedback fades like history does.
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

  /// Within the window, a start counts fully at the target's minute and falls
  /// off linearly to half at the window's edge, so at 08:00 a Commute that
  /// starts at 08:00 outranks Work that starts at 08:30.
  static int _slotWeight(int weightMicros, int offsetMinutes) =>
      weightMicros *
      (2 * _slotWindowMinutes - offsetMinutes.abs()) ~/
      (2 * _slotWindowMinutes);

  /// The day of the week joins a signal once that signal has seen it at least
  /// twice and still holds one fresh observation's worth of decayed mass, the
  /// same bar a trigram pair must clear.
  static const int _weekdayMinObservations = 2;
  static const int _weekdayMinMass = _microsPerUnit;

  /// What one fresh vote in the very same situation is worth.
  static int _voteMicros(SuggestionVote vote) => switch (vote) {
    SuggestionVote.good => _microsPerUnit,
    SuggestionVote.notUseful => -_microsPerUnit,
    SuggestionVote.accepted => _microsPerUnit ~/ 4,
    SuggestionVote.logged => 0,
  };

  /// Net good feedback multiplies a score by up to this many times.
  static const int _maxFeedbackBoost = 2;

  /// Each unit of net not-useful feedback divides a score by this much more:
  /// one fresh vote in the same situation leaves a twenty-first of it, enough
  /// to drop even a routine's usual next step.
  static const int _feedbackDemotion = 20;

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

  /// How much an observation or vote [ageMs] old still counts, in
  /// micro-units: the 14-day half-life, and nothing past the window.
  static int decayMicros(int ageMs) =>
      _weightMicrosForAge(ageMs < 0 ? 0 : ageMs ~/ Duration.millisecondsPerDay);

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
    Iterable<SuggestionFeedback> feedback = const [],
    int limit = 6,
  }) => [
    for (final suggestion in rankExplained(
      candidates: candidates,
      history: history,
      precedingActivityId: precedingActivityId,
      secondPrecedingActivityId: secondPrecedingActivityId,
      targetEpochMs: targetEpochMs,
      timezoneId: timezoneId,
      feedback: feedback,
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
    Iterable<SuggestionFeedback> feedback = const [],
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
        final slotWeight = _slotWeight(weightMicros, offset);
        if (_isWeekend(recordWallClock.weekday) == targetIsWeekend) {
          groupSlotMass += slotWeight;
          if (isCandidate) {
            add(groupSlotScore, activityId, slotWeight);
            add(groupSlotOffset, activityId, slotWeight * offset);
          }
        }
        if (recordWallClock.weekday == targetWeekday) {
          daySlotMass += slotWeight;
          daySlotObservations++;
          if (isCandidate) {
            add(daySlotScore, activityId, slotWeight);
            add(daySlotOffset, activityId, slotWeight * offset);
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
      // The day of the week counts twice: six Thursdays without Breakfast at
      // 08:00 outweigh Breakfast at 08:00 on the other weekdays.
      final time = weekdayActive
          ? (2 * dayShare + groupShare) ~/ 3
          : groupShare;

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

    // Votes on the Activity alone; votes on a note suggestion are ranked
    // with the notes.
    final feedbackNet = _feedbackNet(
      feedback,
      keyOf: (entry) =>
          entry.people == null &&
              candidateIndex.containsKey(entry.activityId) &&
              entry.activityId != precedingActivityId
          ? entry.activityId
          : null,
      precedingActivityId: precedingActivityId,
      targetEpochMs: targetEpochMs,
      targetMinute: targetMinute,
      targetWeekday: targetWeekday,
    );
    for (final MapEntry(key: id, value: net) in feedbackNet.entries) {
      totals[id] = _applyFeedback(totals[id]!, net);
    }

    final sorted = List<Activity>.from(activeCandidates)
      ..sort((a, b) {
        final byTotal = totals[b.id]!.compareTo(totals[a.id]!);
        if (byTotal != 0) return byTotal;
        // With no score to scale, feedback still orders: a disliked
        // Activity sinks below ones nobody has voted on.
        final byFeedback = (feedbackNet[b.id] ?? 0).compareTo(
          feedbackNet[a.id] ?? 0,
        );
        if (byFeedback != 0) return byFeedback;
        return candidateIndex[a.id]!.compareTo(candidateIndex[b.id]!);
      });

    return [
      for (final activity in sorted.take(limit))
        RankedSuggestion(activity, reasons[activity.id]),
    ];
  }

  /// Net decayed feedback per key, in micro-units (one fresh vote in the very
  /// same situation is 1 000 000), scaled by how alike each vote's situation
  /// is to the target's. [keyOf] names what a vote is about, or null to skip
  /// it; the Today page keys note suggestions with
  /// [SuggestionFeedback.comboKey].
  static Map<String, int> feedbackNet(
    Iterable<SuggestionFeedback> feedback, {
    required String? Function(SuggestionFeedback entry) keyOf,
    required String? precedingActivityId,
    required int targetEpochMs,
    required String timezoneId,
  }) {
    final target = wallClockAt(timezoneId, targetEpochMs);
    return _feedbackNet(
      feedback,
      keyOf: keyOf,
      precedingActivityId: precedingActivityId,
      targetEpochMs: targetEpochMs,
      targetMinute: target.hour * 60 + target.minute,
      targetWeekday: target.weekday,
    );
  }

  static Map<String, int> _feedbackNet(
    Iterable<SuggestionFeedback> feedback, {
    required String? Function(SuggestionFeedback entry) keyOf,
    required String? precedingActivityId,
    required int targetEpochMs,
    required int targetMinute,
    required int targetWeekday,
  }) {
    final net = <String, int>{};
    for (final entry in feedback) {
      if (entry.vote == SuggestionVote.logged) continue;
      final id = keyOf(entry);
      if (id == null) continue;
      final ageMs = targetEpochMs - entry.givenAtEpochMs;
      final decay = _weightMicrosForAge(
        ageMs < 0 ? 0 : ageMs ~/ Duration.millisecondsPerDay,
      );
      if (decay == 0) continue;

      final similarity = _feedbackSimilarity(
        entry,
        precedingActivityId: precedingActivityId,
        targetMinute: targetMinute,
        targetWeekday: targetWeekday,
      );
      if (similarity == 0) continue;

      final weight =
          _voteMicros(entry.vote) *
          decay ~/
          _microsPerUnit *
          similarity ~/
          _microsPerUnit;
      net.update(id, (value) => value + weight, ifAbsent: () => weight);
    }
    return net;
  }

  /// How alike a vote's situation is to the target's, 0..1 in micro-units.
  /// Half of the match is the same preceding Activity, half the time of day,
  /// which counts fully within the hour on the same day of the week, half on
  /// another day of the same kind (weekday or weekend), and a quarter
  /// otherwise.
  static int _feedbackSimilarity(
    SuggestionFeedback entry, {
    required String? precedingActivityId,
    required int targetMinute,
    required int targetWeekday,
  }) {
    final sequence = entry.precedingActivityId == precedingActivityId
        ? _microsPerUnit
        : 0;

    final wallClock = entry.timezoneId == 'UTC'
        ? DateTime.fromMillisecondsSinceEpoch(entry.targetEpochMs, isUtc: true)
        : wallClockAt(entry.timezoneId, entry.targetEpochMs);
    var offset = wallClock.hour * 60 + wallClock.minute - targetMinute;
    if (offset > 720) offset -= 1440;
    if (offset <= -720) offset += 1440;
    var time = 0;
    if (offset.abs() <= _slotWindowMinutes) {
      time = _slotWeight(_microsPerUnit, offset);
      if (wallClock.weekday != targetWeekday) {
        time ~/= _isWeekend(wallClock.weekday) == _isWeekend(targetWeekday)
            ? 2
            : 4;
      }
    }
    // Squared, so a vote counts fully in the same situation but only a
    // quarter where half of it matches.
    final similarity = (sequence + time) ~/ 2;
    return similarity * similarity ~/ _microsPerUnit;
  }

  /// [total] scaled by net feedback [net]: raised by half of each unit of good,
  /// up to [_maxFeedbackBoost] times, or divided down for not useful.
  static int _applyFeedback(int total, int net) {
    if (net >= 0) {
      final boost = math.min(
        net ~/ 2,
        (_maxFeedbackBoost - 1) * _microsPerUnit,
      );
      return total * (_microsPerUnit + boost) ~/ _microsPerUnit;
    }
    return total *
        _microsPerUnit ~/
        (_microsPerUnit + _feedbackDemotion * -net);
  }

  /// [minute] rounded to five minutes and wrapped into one day.
  static int _roundedMinute(int minute) {
    final wrapped = minute % 1440;
    return (((wrapped + 2) ~/ 5) * 5) % 1440;
  }

  static bool _isWeekend(int weekday) =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;
}
