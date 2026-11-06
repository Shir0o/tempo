import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'suggestion_engine.dart';

/// The most Records a suggestion history read will keep. The newest rows win;
/// the oldest are the most decayed, so discarding them changes little.
const int suggestionHistoryRowCap = 12000;

/// Reads the lean 60-day history, derives the context from that same snapshot,
/// and returns the ranked suggestions.
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
  final history = await database.getSuggestionHistory(
    startedAfter:
        nowEpochMs - ContextualSuggestionEngine.historyWindow.inMilliseconds,
    startedBefore: nowEpochMs,
    limit: suggestionHistoryRowCap,
  );
  if (history.isEmpty) return const [];

  final context = ContextualSuggestionEngine.contextFromHistory(
    history,
    targetEpochMs: nowEpochMs,
  );
  return const ContextualSuggestionEngine().rank(
    candidates: candidates,
    history: history,
    precedingActivityId: context.precedingActivityId,
    secondPrecedingActivityId: context.secondPrecedingActivityId,
    targetEpochMs: nowEpochMs,
    timezoneId: timezoneId,
    limit: limit,
  );
}
