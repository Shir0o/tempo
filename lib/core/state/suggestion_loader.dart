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
/// This is the production path for the notification chips and the Wear tile.
/// The Dashboard uses [loadRankedSuggestions] to show pinned Activities apart.
/// It stays a function, not a service or cache.
Future<List<Activity>> loadSuggestions({
  required TempoDatabase database,
  required List<Activity> candidates,
  required int nowEpochMs,
  int? targetEpochMs,
  required String timezoneId,
  required int limit,
}) async {
  if (limit <= 0) return const [];

  final pinned = [
    for (final activity in candidates)
      if (activity.isPinned && !activity.isArchived) activity,
  ];

  final ranked = [
    for (final suggestion in await loadRankedSuggestions(
      database: database,
      candidates: candidates,
      nowEpochMs: nowEpochMs,
      targetEpochMs: targetEpochMs,
      timezoneId: timezoneId,
      limit: limit,
    ))
      suggestion.activity,
  ];
  // A cold start has no contextual ranking to show, but a pinned Activity is
  // still a useful suggestion the user explicitly asked to keep within reach.
  if (ranked.isEmpty) return pinned.take(limit).toList(growable: false);
  if (pinned.isEmpty) return ranked;

  final pinnedIds = {for (final activity in pinned) activity.id};
  return [
    ...pinned,
    for (final activity in ranked)
      if (!pinnedIds.contains(activity.id)) activity,
  ].take(limit).toList(growable: false);
}

/// The learned suggestions with the reason for each, best first.
///
/// [targetEpochMs] is the moment being labeled: the open Lap's start when the
/// user labels after the fact. It defaults to [nowEpochMs]. Only Records that
/// started before [nowEpochMs] are read.
///
/// With [excludePinned], pinned Activities are left out so a caller can show
/// them on their own. Returns nothing before any history exists.
Future<List<RankedSuggestion>> loadRankedSuggestions({
  required TempoDatabase database,
  required List<Activity> candidates,
  required int nowEpochMs,
  int? targetEpochMs,
  required String timezoneId,
  required int limit,
  bool excludePinned = false,
}) async {
  if (limit <= 0) return const [];
  final target = targetEpochMs ?? nowEpochMs;

  final history = await database.getSuggestionHistory(
    startedAfter:
        target - ContextualSuggestionEngine.historyWindow.inMilliseconds,
    startedBefore: nowEpochMs,
    limit: suggestionHistoryRowCap,
  );
  if (history.isEmpty) return const [];

  final context = ContextualSuggestionEngine.contextFromHistory(
    history,
    targetEpochMs: target,
  );
  return const ContextualSuggestionEngine().rankExplained(
    candidates: [
      for (final activity in candidates)
        if (!excludePinned || !activity.isPinned) activity,
    ],
    history: history,
    precedingActivityId: context.precedingActivityId,
    secondPrecedingActivityId: context.secondPrecedingActivityId,
    targetEpochMs: target,
    timezoneId: timezoneId,
    limit: limit,
  );
}
