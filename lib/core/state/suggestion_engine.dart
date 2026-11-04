import '../../data/models/models.dart';
import '../time/timezone_id.dart';

/// Contextual prediction engine that ranks activities based on:
/// 1. Markov-1 transitions (preceding activity -> next activity)
/// 2. Temporal slotting (matching local calendar hour +/- 1 on weekday vs weekend)
/// 3. Overall historical frequency fallback
///
/// Execution is pure, deterministic, and sub-millisecond for thousands of records.
class ContextualSuggestionEngine {
  const ContextualSuggestionEngine();

  List<Activity> rank({
    required List<Activity> candidates,
    required Iterable<Record> history,
    required String? precedingActivityId,
    required int targetEpochMs,
    required String timezoneId,
    int limit = 6,
  }) {
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

    // Track statistics across history
    // Markov transition counts: count of times precedingActivityId transitioned to candidate
    final markovCounts = <String, int>{};
    int markovTotal = 0;

    // Temporal slot counts: count of times candidate was logged within hour +/- 1 on same day type
    final temporalCounts = <String, int>{};

    // Overall frequency counts
    final frequencyCounts = <String, int>{};

    String? lastActivityId;

    for (final record in history) {
      final currentActivityId = record.activityId;

      // Track overall frequency for valid candidate activities
      if (currentActivityId != null &&
          candidateIndex.containsKey(currentActivityId)) {
        frequencyCounts.update(
          currentActivityId,
          (val) => val + 1,
          ifAbsent: () => 1,
        );

        // Track temporal slot match
        final recordWallClock = record.timezoneId == 'UTC'
            ? DateTime.fromMillisecondsSinceEpoch(
                record.startedAtEpochMs,
                isUtc: true,
              )
            : wallClockAt(record.timezoneId, record.startedAtEpochMs);
        final recordIsWeekend = _isWeekend(recordWallClock.weekday);

        if (recordIsWeekend == targetIsWeekend) {
          final diff = (recordWallClock.hour - targetHour).abs();
          // Match within hour +/- 1 (also accounting for 23 -> 0 wrap)
          final matchesHour = diff <= 1 || diff == 23;
          if (matchesHour) {
            temporalCounts.update(
              currentActivityId,
              (val) => val + 1,
              ifAbsent: () => 1,
            );
          }
        }
      }

      // Track Markov-1 transition:
      // If previous record had activityId == null (untracked), ignore Markov transition.
      if (precedingActivityId != null &&
          lastActivityId == precedingActivityId &&
          currentActivityId != null &&
          candidateIndex.containsKey(currentActivityId)) {
        markovCounts.update(
          currentActivityId,
          (val) => val + 1,
          ifAbsent: () => 1,
        );
        markovTotal++;
      }

      lastActivityId = currentActivityId;
    }

    // Sort active candidates using hierarchical comparison:
    // 1. Markov transition count (descending)
    // 2. Temporal slot count (descending)
    // 3. Historical frequency (descending)
    // 4. Candidate list original order (ascending)
    final sorted = List<Activity>.from(activeCandidates)
      ..sort((a, b) {
        if (precedingActivityId != null && markovTotal > 0) {
          final markovA = markovCounts[a.id] ?? 0;
          final markovB = markovCounts[b.id] ?? 0;
          if (markovA != markovB) {
            return markovB.compareTo(markovA);
          }
        }

        final tempA = temporalCounts[a.id] ?? 0;
        final tempB = temporalCounts[b.id] ?? 0;
        if (tempA != tempB) {
          return tempB.compareTo(tempA);
        }

        final freqA = frequencyCounts[a.id] ?? 0;
        final freqB = frequencyCounts[b.id] ?? 0;
        if (freqA != freqB) {
          return freqB.compareTo(freqA);
        }

        return candidateIndex[a.id]!.compareTo(candidateIndex[b.id]!);
      });

    return sorted.take(limit).toList();
  }

  static bool _isWeekend(int weekday) =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;
}
