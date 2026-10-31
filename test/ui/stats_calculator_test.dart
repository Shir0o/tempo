import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/data/models/activity.dart';
import 'package:tempo/data/models/record.dart';
import 'package:tempo/ui/stats_calculator.dart';

void main() {
  group('StatsCalculator Unit Tests', () {
    final now = DateTime(2026, 10, 31, 14, 0, 0); // Saturday
    final codingActivity = Activity(
      id: 'act-coding',
      name: 'Coding',
      colorHex: '#2196F3',
      iconName: 'code',
      isPinned: true,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );
    final readingActivity = Activity(
      id: 'act-reading',
      name: 'Reading',
      colorHex: '#4CAF50',
      iconName: 'book',
      isPinned: true,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );
    final workoutActivity = Activity(
      id: 'act-workout',
      name: 'Workout',
      colorHex: '#FF9800',
      iconName: 'fitness_center',
      isPinned: false,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );

    final activitiesMap = {
      codingActivity.id: codingActivity,
      readingActivity.id: readingActivity,
      workoutActivity.id: workoutActivity,
    };

    test('Period range calculation boundaries', () {
      // Day
      final dayRange = StatsCalculator.getPeriodRange(StatsPeriod.day, now);
      expect(dayRange.start, DateTime(2026, 10, 31, 0, 0, 0));
      expect(dayRange.end, DateTime(2026, 10, 31, 23, 59, 59, 999));

      // Week (Monday Oct 26 to Sunday Nov 1)
      final weekRange = StatsCalculator.getPeriodRange(StatsPeriod.week, now);
      expect(weekRange.start, DateTime(2026, 10, 26, 0, 0, 0));
      expect(weekRange.end, DateTime(2026, 11, 1, 23, 59, 59, 999));

      // Month (Oct 1 to Oct 31)
      final monthRange = StatsCalculator.getPeriodRange(StatsPeriod.month, now);
      expect(monthRange.start, DateTime(2026, 10, 1, 0, 0, 0));
      expect(monthRange.end, DateTime(2026, 10, 31, 23, 59, 59, 999));
    });

    test('Handles zero records cleanly without errors', () {
      final report = StatsCalculator.calculate(
        records: const [],
        activitiesMap: activitiesMap,
        period: StatsPeriod.day,
        referenceDate: now,
      );

      expect(report.totalDurationMs, 0);
      expect(report.sessionCount, 0);
      expect(report.averageSessionDurationMs, 0);
      expect(report.mostActiveHabit, isNull);
      expect(report.activityBreakdowns, isEmpty);
      expect(report.totalDurationHours, 0.0);
      expect(report.averageDurationMinutes, 0.0);
    });

    test('Single record calculates 100% distribution and average', () {
      final record = Record(
        id: 'rec-1',
        activityId: 'act-coding',
        startedAtEpochMs: DateTime(2026, 10, 31, 10, 0).millisecondsSinceEpoch,
        endedAtEpochMs: DateTime(2026, 10, 31, 12, 0).millisecondsSinceEpoch,
        durationMs: 7200000, // 2 hours
        comment: 'Feature development',
        timezoneId: 'UTC',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      );

      final report = StatsCalculator.calculate(
        records: [record],
        activitiesMap: activitiesMap,
        period: StatsPeriod.day,
        referenceDate: now,
      );

      expect(report.totalDurationMs, 7200000);
      expect(report.totalDurationHours, 2.0);
      expect(report.sessionCount, 1);
      expect(report.averageSessionDurationMs, 7200000);
      expect(report.averageDurationMinutes, 120.0);
      expect(report.mostActiveHabit, isNotNull);
      expect(report.mostActiveHabit!.activityId, 'act-coding');
      expect(report.mostActiveHabit!.name, 'Coding');
      expect(report.mostActiveHabit!.percentage, 100.0);
      expect(report.mostActiveHabit!.sessionCount, 1);
    });

    test('Multiple activities aggregate accurately and sort descending', () {
      // Oct 31 records:
      // Coding: 3 hours (10,800,000 ms)
      // Reading: 1 hour (3,600,000 ms)
      // Workout: 30 min (1,800,000 ms) in 2 sessions of 15 min
      // Total: 4.5 hours = 16,200,000 ms
      final records = [
        Record(
          id: 'r1',
          activityId: 'act-coding',
          startedAtEpochMs: DateTime(2026, 10, 31, 9, 0).millisecondsSinceEpoch,
          endedAtEpochMs: DateTime(2026, 10, 31, 12, 0).millisecondsSinceEpoch,
          durationMs: 10800000,
          comment: '',
          timezoneId: 'UTC',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
        Record(
          id: 'r2',
          activityId: 'act-reading',
          startedAtEpochMs: DateTime(2026, 10, 31, 13, 0).millisecondsSinceEpoch,
          endedAtEpochMs: DateTime(2026, 10, 31, 14, 0).millisecondsSinceEpoch,
          durationMs: 3600000,
          comment: '',
          timezoneId: 'UTC',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
        Record(
          id: 'r3',
          activityId: 'act-workout',
          startedAtEpochMs: DateTime(2026, 10, 31, 15, 0).millisecondsSinceEpoch,
          endedAtEpochMs: DateTime(2026, 10, 31, 15, 15).millisecondsSinceEpoch,
          durationMs: 900000,
          comment: '',
          timezoneId: 'UTC',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
        Record(
          id: 'r4',
          activityId: 'act-workout',
          startedAtEpochMs: DateTime(2026, 10, 31, 15, 30).millisecondsSinceEpoch,
          endedAtEpochMs: DateTime(2026, 10, 31, 15, 45).millisecondsSinceEpoch,
          durationMs: 900000,
          comment: '',
          timezoneId: 'UTC',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      ];

      final report = StatsCalculator.calculate(
        records: records,
        activitiesMap: activitiesMap,
        period: StatsPeriod.day,
        referenceDate: now,
      );

      expect(report.totalDurationMs, 16200000);
      expect(report.totalDurationHours, 4.5);
      expect(report.sessionCount, 4);
      expect(report.averageSessionDurationMs, (16200000 / 4).round());

      expect(report.activityBreakdowns.length, 3);
      // Sorted descending by duration
      expect(report.activityBreakdowns[0].name, 'Coding');
      expect(report.activityBreakdowns[0].durationMs, 10800000);
      expect(report.activityBreakdowns[0].percentage, closeTo((10800000 / 16200000) * 100, 0.01));
      expect(report.activityBreakdowns[0].sessionCount, 1);

      expect(report.activityBreakdowns[1].name, 'Reading');
      expect(report.activityBreakdowns[1].durationMs, 3600000);
      expect(report.activityBreakdowns[1].percentage, closeTo((3600000 / 16200000) * 100, 0.01));

      expect(report.activityBreakdowns[2].name, 'Workout');
      expect(report.activityBreakdowns[2].durationMs, 1800000);
      expect(report.activityBreakdowns[2].percentage, closeTo((1800000 / 16200000) * 100, 0.01));
      expect(report.activityBreakdowns[2].sessionCount, 2);

      // Percentages sum to 100%
      final sumPct = report.activityBreakdowns.fold<double>(0.0, (sum, a) => sum + a.percentage);
      expect(sumPct, closeTo(100.0, 0.01));

      // Most active habit is Coding
      expect(report.mostActiveHabit?.activityId, 'act-coding');
    });

    test('Filters out records from outside the period window', () {
      final inPeriod = Record(
        id: 'in',
        activityId: 'act-coding',
        startedAtEpochMs: DateTime(2026, 10, 31, 12, 0).millisecondsSinceEpoch,
        endedAtEpochMs: DateTime(2026, 10, 31, 13, 0).millisecondsSinceEpoch,
        durationMs: 3600000,
        comment: '',
        timezoneId: 'UTC',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      );
      final outPeriod = Record(
        id: 'out',
        activityId: 'act-coding',
        startedAtEpochMs: DateTime(2026, 10, 30, 23, 0).millisecondsSinceEpoch,
        endedAtEpochMs: DateTime(2026, 10, 31, 0, 0).millisecondsSinceEpoch,
        durationMs: 3600000,
        comment: '',
        timezoneId: 'UTC',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      );

      final report = StatsCalculator.calculate(
        records: [inPeriod, outPeriod],
        activitiesMap: activitiesMap,
        period: StatsPeriod.day,
        referenceDate: now,
      );

      expect(report.sessionCount, 1);
      expect(report.totalDurationMs, 3600000);
    });
  });
}
