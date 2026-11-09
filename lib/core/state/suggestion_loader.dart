import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'suggestion_engine.dart';

/// The most Records a suggestion history read will keep. The newest rows win;
/// the oldest are the most decayed, so discarding them changes little.
const int suggestionHistoryRowCap = 12000;

/// Reads the lean 60-day history, derives the context from that same snapshot,
/// and returns the ranked suggestions.
///
/// Active pinned Activities are user-declared priorities, so they always lead
/// the suggestions and remain available before any history exists.
///
/// This is the single production path for the Dashboard, the notification
/// chips, and the Wear tile. It stays a function, not a service or cache.
Future<List<Activity>> loadSuggestions({
  required TempoDatabase database,
  required List<Activity> candidates,
  required int nowEpochMs,
  required String timezoneId,
  required int limit,
}) async {
  if (limit <= 0) return const [];

  final pinned = [
    for (final activity in candidates)
      if (activity.isPinned && !activity.isArchived) activity,
  ];

  final history = await database.getSuggestionHistory(
    startedAfter:
        nowEpochMs - ContextualSuggestionEngine.historyWindow.inMilliseconds,
    startedBefore: nowEpochMs,
    limit: suggestionHistoryRowCap,
  );
  // A cold start has no contextual ranking to show, but a pinned Activity is
  // still a useful suggestion the user explicitly asked to keep within reach.
  if (history.isEmpty) {
    return pinned.take(limit).toList(growable: false);
  }

  final context = ContextualSuggestionEngine.contextFromHistory(
    history,
    targetEpochMs: nowEpochMs,
  );
  final ranked = const ContextualSuggestionEngine().rank(
    candidates: candidates,
    history: history,
    precedingActivityId: context.precedingActivityId,
    secondPrecedingActivityId: context.secondPrecedingActivityId,
    targetEpochMs: nowEpochMs,
    timezoneId: timezoneId,
    limit: limit,
  );
  if (pinned.isEmpty) return ranked;

  final pinnedIds = {for (final activity in pinned) activity.id};
  return [
    ...pinned,
    for (final activity in ranked)
      if (!pinnedIds.contains(activity.id)) activity,
  ].take(limit).toList(growable: false);
}
