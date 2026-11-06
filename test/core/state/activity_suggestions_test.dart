import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/activity_suggestions.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  const day = 24 * 60 * 60 * 1000;
  // 2026-11-05 00:00 UTC.
  final base = DateTime.utc(2026, 11, 5).millisecondsSinceEpoch;
  int at(int daysAgo, int hour, [int minute = 0]) =>
      base - daysAgo * day + (hour * 60 + minute) * 60 * 1000;

  var n = 0;
  Record rec(String? activityId, int start, {String zone = 'UTC'}) => Record(
    id: 'r${n++}',
    activityId: activityId,
    startedAtEpochMs: start,
    endedAtEpochMs: start + 30 * 60 * 1000,
    timezoneId: zone,
    createdAtEpochMs: start,
    updatedAtEpochMs: start,
  );

  List<String> rank(
    List<Record> records, {
    int hour = 9,
    String? exclude,
    Set<String>? allowed,
  }) => activitiesAroundTime(
    records,
    atEpochMs: at(0, hour),
    timezoneId: 'UTC',
    nowEpochMs: at(0, 12),
    allowed: allowed ?? {'commute', 'coffee', 'errands', 'sleep', 'dinner'},
    exclude: exclude,
  );

  test('ranks Activities started around this time of day', () {
    final records = [
      rec('commute', at(1, 8, 45)),
      rec('commute', at(2, 8, 50)),
      rec('coffee', at(1, 9, 30)),
      rec('dinner', at(1, 19)),
      rec('sleep', at(1, 0)),
    ];
    expect(rank(records), ['commute', 'coffee']);
  });

  test('wraps around midnight', () {
    final records = [rec('sleep', at(1, 23, 30))];
    expect(rank(records, hour: 0), ['sleep']);
  });

  test('skips the current, archived and Untracked', () {
    final records = [
      rec('errands', at(1, 9)),
      rec('gone', at(1, 9)),
      rec(null, at(1, 9)),
      rec('coffee', at(1, 9)),
    ];
    expect(rank(records, exclude: 'errands'), ['coffee']);
  });

  test('recent Records outweigh old ones', () {
    final records = [
      rec('coffee', at(60, 9)),
      rec('coffee', at(61, 9)),
      rec('commute', at(1, 9)),
    ];
    expect(rank(records).first, 'commute');
  });

  test('reads each start in the zone it was lived in', () {
    // 17:00 UTC is 09:00 in Los Angeles in November.
    final records = [rec('coffee', at(1, 17), zone: 'America/Los_Angeles')];
    expect(rank(records), ['coffee']);
  });

  test('keeps at most three', () {
    final records = [
      for (final a in ['commute', 'coffee', 'errands', 'sleep'])
        rec(a, at(1, 9)),
    ];
    expect(rank(records), hasLength(3));
  });
}
