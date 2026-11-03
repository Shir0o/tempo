import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/helpers/ui_helpers.dart';

Record _record({
  required int startMs,
  required int endMs,
  String timezoneId = 'America/Los_Angeles',
  String? endTimezoneId,
}) => Record(
  id: 'rec-1',
  activityId: 'act-1',
  startedAtEpochMs: startMs,
  endedAtEpochMs: endMs,
  timezoneId: timezoneId,
  endTimezoneId: endTimezoneId,
  createdAtEpochMs: endMs,
  updatedAtEpochMs: endMs,
);

void main() {
  // 2026-03-01 08:00 in Los Angeles (PST, UTC-8).
  final startMs = DateTime.utc(2026, 3, 1, 16).millisecondsSinceEpoch;

  group('formatZonedTimeRange', () {
    test('renders a same-zone record as a plain range', () {
      final record = _record(startMs: startMs, endMs: startMs + 7200000);
      expect(UiHelpers.formatZonedTimeRange(record), '08:00 – 10:00');
    });

    test('shows both zones when a record crosses them', () {
      // 08:00 PST is 11:00 EST; six UTC hours later it is 17:00 EST.
      final record = _record(
        startMs: startMs,
        endMs: startMs + 6 * 3600000,
        endTimezoneId: 'America/New_York',
      );
      expect(UiHelpers.formatZonedTimeRange(record), '08:00 PST → 17:00 EST');
      expect(record.crossesTimezones, isTrue);
    });
  });

  group('Record zones', () {
    test('elapsed time comes from UTC epochs, not wall clocks', () {
      final record = _record(
        startMs: startMs,
        endMs: startMs + 6 * 3600000,
        endTimezoneId: 'America/New_York',
      );
      expect(record.elapsedMs, 6 * 3600000);
      expect(UiHelpers.formatDurationHuman(record.elapsedMs), '6h');
    });

    test('an end zone defaults to the start zone and round-trips', () {
      final record = _record(startMs: startMs, endMs: startMs + 3600000);
      expect(record.endTimezoneId, record.timezoneId);

      final restored = Record.fromMap(record.toMap());
      expect(restored.endTimezoneId, 'America/Los_Angeles');
    });

    test('fromMap falls back to the start zone for pre-v2 rows', () {
      final map = _record(startMs: startMs, endMs: startMs + 3600000).toMap()
        ..remove('end_timezone_id');

      expect(Record.fromMap(map).endTimezoneId, 'America/Los_Angeles');
    });
  });
}
