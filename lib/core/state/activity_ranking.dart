import '../../data/models/models.dart';

/// The ids of the Activities labelled most often in [records], most used
/// first. Ties keep the order of [activities]; Records of Activities missing
/// from [activities] (archived, deleted) are ignored.
List<String> rankActivitiesByUse(
  List<Activity> activities,
  Iterable<Record> records,
) {
  final counts = <String, int>{};
  for (final record in records) {
    final activityId = record.activityId;
    if (activityId != null) {
      counts.update(activityId, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  final order = <String, int>{
    for (var i = 0; i < activities.length; i++) activities[i].id: i,
  };
  final ranked =
      counts.entries.where((entry) => order.containsKey(entry.key)).toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          return order[a.key]!.compareTo(order[b.key]!);
        });

  return [for (final entry in ranked) entry.key];
}
