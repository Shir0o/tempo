import '../data/models/activity.dart';
import '../data/models/record.dart';

/// Available time windows for statistical aggregation.
enum StatsPeriod {
  day,
  week,
  month;

  String get label {
    switch (this) {
      case StatsPeriod.day:
        return 'Day';
      case StatsPeriod.week:
        return 'Week';
      case StatsPeriod.month:
        return 'Month';
    }
  }
}

/// Breakdown metrics for a single activity within a reporting period.
class ActivityStat {
  final String activityId;
  final String name;
  final String colorHex;
  final String iconName;
  final int durationMs;
  final double percentage; // 0.0 to 100.0
  final int sessionCount;

  const ActivityStat({
    required this.activityId,
    required this.name,
    required this.colorHex,
    required this.iconName,
    required this.durationMs,
    required this.percentage,
    required this.sessionCount,
  });

  double get durationHours => durationMs / (1000 * 60 * 60);

  @override
  String toString() =>
      'ActivityStat($name: ${durationHours.toStringAsFixed(1)}h, ${percentage.toStringAsFixed(1)}%)';
}

/// Aggregated report for a given period.
class StatsReport {
  final StatsPeriod period;
  final DateTime startDate;
  final DateTime endDate;
  final int totalDurationMs;
  final int sessionCount;
  final int averageSessionDurationMs;
  final ActivityStat? mostActiveHabit;
  final List<ActivityStat> activityBreakdowns;

  const StatsReport({
    required this.period,
    required this.startDate,
    required this.endDate,
    required this.totalDurationMs,
    required this.sessionCount,
    required this.averageSessionDurationMs,
    required this.mostActiveHabit,
    required this.activityBreakdowns,
  });

  double get totalDurationHours => totalDurationMs / (1000 * 60 * 60);
  double get averageDurationMinutes => averageSessionDurationMs / (1000 * 60);
}

/// Pure business logic engine for calculating time tracking statistics.
class StatsCalculator {
  /// Computes the start and end boundary of the given [period] relative to [referenceDate].
  static ({DateTime start, DateTime end}) getPeriodRange(
    StatsPeriod period,
    DateTime referenceDate,
  ) {
    switch (period) {
      case StatsPeriod.day:
        final start = DateTime(
          referenceDate.year,
          referenceDate.month,
          referenceDate.day,
        );
        final end = DateTime(
          referenceDate.year,
          referenceDate.month,
          referenceDate.day,
          23,
          59,
          59,
          999,
        );
        return (start: start, end: end);

      case StatsPeriod.week:
        // Week starts on Monday (ISO-8601 convention: weekday 1 = Monday, 7 = Sunday)
        final diff = referenceDate.weekday - 1;
        final monday = referenceDate.subtract(Duration(days: diff));
        final start = DateTime(monday.year, monday.month, monday.day);
        final sunday = start.add(const Duration(days: 6));
        final end = DateTime(
          sunday.year,
          sunday.month,
          sunday.day,
          23,
          59,
          59,
          999,
        );
        return (start: start, end: end);

      case StatsPeriod.month:
        final start = DateTime(referenceDate.year, referenceDate.month, 1);
        final nextMonth = DateTime(
          referenceDate.year,
          referenceDate.month + 1,
          1,
        );
        final lastDay = nextMonth.subtract(const Duration(days: 1));
        final end = DateTime(
          lastDay.year,
          lastDay.month,
          lastDay.day,
          23,
          59,
          59,
          999,
        );
        return (start: start, end: end);
    }
  }

  /// Calculates a [StatsReport] from a collection of records.
  static StatsReport calculate({
    required List<Record> records,
    required Map<String, Activity> activitiesMap,
    required StatsPeriod period,
    DateTime? referenceDate,
  }) {
    final ref = referenceDate ?? DateTime.now();
    final range = getPeriodRange(period, ref);
    final startMs = range.start.millisecondsSinceEpoch;
    final endMs = range.end.millisecondsSinceEpoch;

    // Filter records overlapping or started within the period window
    final periodRecords = records.where((r) {
      return r.startedAtEpochMs >= startMs && r.startedAtEpochMs <= endMs;
    }).toList();

    int totalDurationMs = 0;
    final durationByActivity = <String, int>{};
    final countByActivity = <String, int>{};

    for (final r in periodRecords) {
      totalDurationMs += r.durationMs;
      durationByActivity[r.activityId] =
          (durationByActivity[r.activityId] ?? 0) + r.durationMs;
      countByActivity[r.activityId] = (countByActivity[r.activityId] ?? 0) + 1;
    }

    final breakdowns = <ActivityStat>[];
    for (final entry in durationByActivity.entries) {
      final actId = entry.key;
      final actDuration = entry.value;
      final activity = activitiesMap[actId];
      final name = activity?.name ?? 'Unknown Activity';
      final colorHex = activity?.colorHex ?? '#4CAF50';
      final iconName = activity?.iconName ?? 'schedule';
      final percentage = totalDurationMs > 0
          ? (actDuration / totalDurationMs) * 100.0
          : 0.0;
      final count = countByActivity[actId] ?? 0;

      breakdowns.add(
        ActivityStat(
          activityId: actId,
          name: name,
          colorHex: colorHex,
          iconName: iconName,
          durationMs: actDuration,
          percentage: percentage,
          sessionCount: count,
        ),
      );
    }

    // Sort descending by duration
    breakdowns.sort((a, b) => b.durationMs.compareTo(a.durationMs));

    final sessionCount = periodRecords.length;
    final averageSessionDurationMs = sessionCount > 0
        ? (totalDurationMs / sessionCount).round()
        : 0;
    final mostActiveHabit = breakdowns.isNotEmpty ? breakdowns.first : null;

    return StatsReport(
      period: period,
      startDate: range.start,
      endDate: range.end,
      totalDurationMs: totalDurationMs,
      sessionCount: sessionCount,
      averageSessionDurationMs: averageSessionDurationMs,
      mostActiveHabit: mostActiveHabit,
      activityBreakdowns: breakdowns,
    );
  }
}
