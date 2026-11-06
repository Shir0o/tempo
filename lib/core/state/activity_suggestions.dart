import 'dart:math' as math;

import '../../data/models/models.dart';
import '../time/timezone_id.dart';

/// How far either side of a time of day a past Record's start still counts as
/// "around" it.
const Duration aroundWindow = Duration(minutes: 90);

/// How fast an old Record fades: its weight halves every [aroundHalfLife].
const Duration aroundHalfLife = Duration(days: 21);

/// The Activities most often started around [atEpochMs]'s time of day in
/// [timezoneId], best first, at most [limit].
///
/// Each past Record counts once for its Activity when its start, read in the
/// zone it was lived in, falls within [aroundWindow] of that time of day
/// (wrapping at midnight). Recent Records weigh more, halving every
/// [aroundHalfLife]. Only ids in [allowed] are returned and [exclude] never
/// is. Ties go to the Activity's latest Record.
List<String> activitiesAroundTime(
  Iterable<Record> records, {
  required int atEpochMs,
  required String timezoneId,
  required int nowEpochMs,
  required Set<String> allowed,
  String? exclude,
  int limit = 3,
}) {
  int minuteOfDay(DateTime wall) => wall.hour * 60 + wall.minute;
  final target = minuteOfDay(wallClockAt(timezoneId, atEpochMs));
  final window = aroundWindow.inMinutes;
  final halfLifeMs = aroundHalfLife.inMilliseconds;

  final score = <String, double>{};
  final latest = <String, int>{};
  for (final r in records) {
    final id = r.activityId;
    if (id == null || id == exclude || !allowed.contains(id)) continue;
    final start = minuteOfDay(wallClockAt(r.timezoneId, r.startedAtEpochMs));
    final diff = (start - target).abs();
    if (math.min(diff, 1440 - diff) > window) continue;
    final ageMs = math.max(0, nowEpochMs - r.endedAtEpochMs);
    score[id] = (score[id] ?? 0) + math.pow(0.5, ageMs / halfLifeMs);
    latest[id] = math.max(latest[id] ?? 0, r.startedAtEpochMs);
  }

  final ids = score.keys.toList()
    ..sort((a, b) {
      final byScore = score[b]!.compareTo(score[a]!);
      if (byScore != 0) return byScore;
      return latest[b]!.compareTo(latest[a]!);
    });
  return ids.take(limit).toList();
}
