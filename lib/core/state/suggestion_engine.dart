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

/// Contextual prediction engine that ranks activities based on:
/// 1. Markov-2 transitions ((A_t-2, A_t-1) -> A_t) when the pair is established
/// 2. Markov-1 transitions (A_t-1 -> A_t) as the backoff
/// 3. Temporal slotting (matching local calendar hour +/- 1 on weekday vs weekend)
/// 4. Overall historical frequency fallback
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
  /// this much decayed mass before it can outrank Markov-1.
  static const int _pairMinObservations = 2;
  static const int _pairMinContextMass = _microsPerUnit;

  /// A candidate enters the Markov-2 tier only when its trigram score is at
  /// least one tenth of the pair's context mass. This stops a single old
  /// outcome from outranking a strong Markov-1 sequence.
  static const int _trigramMinShareDenominator = 10;

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
  }) {
    assert(
      secondPrecedingActivityId == null || precedingActivityId != null,
      'A second preceding Activity needs a preceding Activity.',
    );

    // 1. Candidate filtering: Filter out archived activities
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

    // 2. Pre-calculate target temporal context
    final targetWallClock = wallClockAt(timezoneId, targetEpochMs);
    final targetHour = targetWallClock.hour; // 0..23
    final targetIsWeekend = _isWeekend(targetWallClock.weekday);

    // Decayed scores. Candidate-only counters drive the ranking; contextMass
    // measures how well the preceding pair is established in real life,
    // including outcomes that are archived or not offered as candidates.
    final frequencyScore = <String, int>{};
    final temporalScore = <String, int>{};
    final bigramScore = <String, int>{};
    final trigramScore = <String, int>{};
    var contextMass = 0;
    var pairObservations = 0;

    // Chain state, in runs rather than observations.
    String? previousRunId;
    String? secondPreviousRunId;
    String? currentRunId;

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

      // Overall frequency for a run.
      if (isCandidate) {
        frequencyScore.update(
          activityId,
          (value) => value + weightMicros,
          ifAbsent: () => weightMicros,
        );

        // Temporal slot match, using the run's start in its own zone.
        final recordWallClock = observation.timezoneId == 'UTC'
            ? DateTime.fromMillisecondsSinceEpoch(
                observation.startedAtEpochMs,
                isUtc: true,
              )
            : wallClockAt(observation.timezoneId, observation.startedAtEpochMs);
        if (_isWeekend(recordWallClock.weekday) == targetIsWeekend) {
          final diff = (recordWallClock.hour - targetHour).abs();
          // Match within hour +/- 1, including the 23:00 -> 00:00 wrap.
          if (diff <= 1 || diff == 23) {
            temporalScore.update(
              activityId,
              (value) => value + weightMicros,
              ifAbsent: () => weightMicros,
            );
          }
        }
      }

      // Markov-1 transition from the query's preceding Activity into this run.
      if (precedingActivityId != null &&
          previousRunId == precedingActivityId &&
          isCandidate) {
        bigramScore.update(
          activityId,
          (value) => value + weightMicros,
          ifAbsent: () => weightMicros,
        );
      }

      // Markov-2 transition into this run, gated on the query pair.
      if (precedingActivityId != null &&
          secondPrecedingActivityId != null &&
          previousRunId == precedingActivityId &&
          secondPreviousRunId == secondPrecedingActivityId) {
        contextMass += weightMicros;
        pairObservations++;
        if (isCandidate) {
          trigramScore.update(
            activityId,
            (value) => value + weightMicros,
            ifAbsent: () => weightMicros,
          );
        }
      }

      secondPreviousRunId = previousRunId;
      previousRunId = activityId;
      currentRunId = activityId;
    }

    // A pair must be seen at least twice and still carry one fresh
    // observation's worth of decayed mass before it can outrank Markov-1.
    final trigramActive =
        precedingActivityId != null &&
        secondPrecedingActivityId != null &&
        pairObservations >= _pairMinObservations &&
        contextMass >= _pairMinContextMass;

    // Sort active candidates using hierarchical comparison:
    // 1. Markov-2 score (descending) when the pair is established and the
    //    candidate carries at least one tenth of the pair's context mass
    // 2. Markov-1 score (descending)
    // 3. Temporal slot score (descending)
    // 4. Decayed frequency score (descending)
    // 5. Candidate list original order (ascending)
    final sorted = List<Activity>.from(activeCandidates)
      ..sort((a, b) {
        if (trigramActive) {
          final triA = trigramScore[a.id] ?? 0;
          final triB = trigramScore[b.id] ?? 0;
          final strongA = triA * _trigramMinShareDenominator >= contextMass;
          final strongB = triB * _trigramMinShareDenominator >= contextMass;
          if (strongA != strongB) {
            return strongA ? -1 : 1;
          }
          if (strongA && triA != triB) {
            return triB.compareTo(triA);
          }
        }

        final bigramA = bigramScore[a.id] ?? 0;
        final bigramB = bigramScore[b.id] ?? 0;
        if (bigramA != bigramB) {
          return bigramB.compareTo(bigramA);
        }

        final temporalA = temporalScore[a.id] ?? 0;
        final temporalB = temporalScore[b.id] ?? 0;
        if (temporalA != temporalB) {
          return temporalB.compareTo(temporalA);
        }

        final frequencyA = frequencyScore[a.id] ?? 0;
        final frequencyB = frequencyScore[b.id] ?? 0;
        if (frequencyA != frequencyB) {
          return frequencyB.compareTo(frequencyA);
        }

        return candidateIndex[a.id]!.compareTo(candidateIndex[b.id]!);
      });

    return sorted.take(limit).toList();
  }

  static bool _isWeekend(int weekday) =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;
}
