import '../../data/models/models.dart';

/// How a candidate matched, in descending priority.
enum ActivityMatchStage {
  exact,
  prefix,
  substring,
  nameTokenInQuery,
  editDistance,
}

class ActivityMatch {
  final Activity activity;
  final ActivityMatchStage stage;

  const ActivityMatch({required this.activity, required this.stage});
}

/// Matches plus the untruncated count, so the sheet can say "showing N of M".
class ActivityRanking {
  final List<ActivityMatch> matches;
  final int total;

  const ActivityRanking({required this.matches, required this.total});
}

/// The query length is capped so the matcher stays bounded on pasted input.
const int activityQueryRuneLimit = 64;

/// Normalizes a query or Activity name for comparison.
///
/// Order matters: trim, lowercase, strip boundary punctuation, collapse
/// whitespace, trim again.
String normalizeActivityText(String input) {
  var value = input.trim().toLowerCase();
  value = value.replaceAll(RegExp(r'^\p{P}+|\p{P}+$', unicode: true), '');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = value.runes.toList();
  if (runes.length > activityQueryRuneLimit) {
    value = String.fromCharCodes(runes.take(activityQueryRuneLimit));
  }
  return value;
}

/// Ranks unarchived Activities for [query].
///
/// Phase 1 implements exact, prefix, substring, and name-token-in-query.
/// The edit-distance stage is reserved for Phase 3.
ActivityRanking rankActivities(
  List<Activity> catalog,
  String query, {
  int limit = 20,
}) {
  final normalizedQuery = normalizeActivityText(query);
  if (normalizedQuery.isEmpty) {
    return const ActivityRanking(matches: [], total: 0);
  }
  final queryTokens = normalizedQuery.split(' ');

  final ranked = <ActivityMatch>[];
  for (final activity in catalog) {
    if (activity.isArchived) continue;
    final name = normalizeActivityText(activity.name);
    if (name.isEmpty) continue;

    final ActivityMatchStage? stage;
    if (name == normalizedQuery) {
      stage = ActivityMatchStage.exact;
    } else if (name.startsWith(normalizedQuery)) {
      stage = ActivityMatchStage.prefix;
    } else if (name.contains(normalizedQuery)) {
      stage = ActivityMatchStage.substring;
    } else {
      final nameTokens = name.split(' ');
      stage = nameTokens.any(queryTokens.contains)
          ? ActivityMatchStage.nameTokenInQuery
          : null;
    }
    if (stage == null) continue;
    ranked.add(ActivityMatch(activity: activity, stage: stage));
  }

  ranked.sort((a, b) {
    final byStage = a.stage.index.compareTo(b.stage.index);
    if (byStage != 0) return byStage;
    final byOrder = a.activity.sortOrder.compareTo(b.activity.sortOrder);
    if (byOrder != 0) return byOrder;
    final byName = normalizeActivityText(a.activity.name)
        .compareTo(normalizeActivityText(b.activity.name));
    if (byName != 0) return byName;
    return a.activity.id.compareTo(b.activity.id);
  });

  final total = ranked.length;
  final capped = limit <= 0 ? ranked : ranked.take(limit).toList();
  return ActivityRanking(matches: capped, total: total);
}
