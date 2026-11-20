import 'dart:convert';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'suggestion_engine.dart';

/// Suggestion feedback, kept on this device as one JSON list in the
/// `settings` table under [storageKey]. It is not synced or exported.
class SuggestionFeedbackStore {
  const SuggestionFeedbackStore._();

  static const String storageKey = 'suggestion_feedback';

  /// The most entries kept. The oldest go first.
  static const int maxEntries = 500;

  /// Every stored entry, oldest first. Unreadable data reads as none.
  static Future<List<SuggestionFeedback>> load(TempoDatabase database) async {
    final stored = await database.getSetting(storageKey);
    if (stored == null || stored.isEmpty) return const [];
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return const [];
      return [for (final entry in decoded) ?SuggestionFeedback.fromJson(entry)];
    } on FormatException {
      return const [];
    }
  }

  /// Adds [feedback], dropping entries too old to count any more and the
  /// oldest beyond [maxEntries].
  static Future<void> add(
    TempoDatabase database,
    SuggestionFeedback feedback,
  ) async {
    final cutoff =
        feedback.givenAtEpochMs -
        ContextualSuggestionEngine.historyWindow.inMilliseconds;
    final kept = [
      for (final entry in await load(database))
        if (entry.givenAtEpochMs >= cutoff) entry,
      feedback,
    ];
    final trimmed = kept.length > maxEntries
        ? kept.sublist(kept.length - maxEntries)
        : kept;
    await database.setSetting(
      storageKey,
      jsonEncode([for (final entry in trimmed) entry.toJson()]),
    );
  }

  /// Forgets all feedback.
  static Future<void> clear(TempoDatabase database) =>
      database.setSetting(storageKey, '');

  /// Records [vote] on [activityId] as suggested for [targetEpochMs].
  ///
  /// The Activity before the target is read from the Records that started
  /// before it, the same chain the engine ranks with, so a Record the tap
  /// itself creates at the target does not count.
  static Future<void> record({
    required TempoDatabase database,
    required String activityId,
    required SuggestionVote vote,
    required int nowEpochMs,
    int? targetEpochMs,
    required String timezoneId,
  }) async {
    final target = targetEpochMs ?? nowEpochMs;
    final history = await database.getSuggestionHistory(
      startedAfter:
          target - ContextualSuggestionEngine.historyWindow.inMilliseconds,
      startedBefore: target - 1,
    );
    final context = ContextualSuggestionEngine.contextFromHistory(
      history,
      targetEpochMs: target,
    );
    await add(
      database,
      SuggestionFeedback(
        activityId: activityId,
        vote: vote,
        givenAtEpochMs: nowEpochMs,
        targetEpochMs: target,
        timezoneId: timezoneId,
        precedingActivityId: context.precedingActivityId,
      ),
    );
  }
}
