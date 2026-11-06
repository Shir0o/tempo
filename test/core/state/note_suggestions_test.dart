import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/note_suggestions.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;

  var nextId = 0;

  /// A Record of [activityId] starting at [startMs] and lasting an hour.
  Record at(
    int startMs,
    String comment, {
    String? activityId = 'read',
    String zone = 'UTC',
    bool isMidnightSplit = false,
  }) => Record(
    id: 'r${nextId++}',
    activityId: activityId,
    startedAtEpochMs: startMs,
    endedAtEpochMs: startMs + hour,
    comment: comment,
    timezoneId: zone,
    isMidnightSplit: isMidnightSplit,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  /// The instant [wall] (read as wall-clock fields) happens in [zone].
  int wallIn(String zone, DateTime wall) => epochMsFromWallClock(
    wall,
    zone,
    referenceEpochMs: wall.millisecondsSinceEpoch,
  );

  group('suggestedReading', () {
    final now = DateTime.utc(2026, 11, 4, 20).millisecondsSinceEpoch;

    test('advances from the same Activity and first Person', () {
      final records = [
        at(now - 9 * day, 'John 3 w/ Sam'),
        at(now - 2 * day, 'John 5 w/ Sam'),
        at(now - day, 'Rom 1 w/ Ana'),
      ];
      expect(
        suggestedReading(
          records,
          activityId: 'read',
          firstPerson: 'Sam',
          beforeEpochMs: now,
        ),
        'John 7',
      );
    });

    test('matches the first Person only, ignoring case', () {
      final records = [
        at(now - 3 * day, 'John 3 w/ Sam'),
        at(now - day, 'Acts 9 w/ Ana, Sam'),
      ];
      expect(
        suggestedReading(
          records,
          activityId: 'read',
          firstPerson: 'sam',
          beforeEpochMs: now,
        ),
        'John 4',
      );
    });

    test('with no Person, falls back to the Activity with no one named', () {
      final records = [
        at(now - 3 * day, 'Psalm 1'),
        at(now - 2 * day, 'Psalm 2'),
        at(now - day, 'John 3 w/ Sam'),
        at(now - day + hour, ''),
      ];
      expect(
        suggestedReading(records, activityId: 'read', beforeEpochMs: now),
        'Psalm 3',
      );
    });

    test('ignores other Activities and Records not before the cut-off', () {
      final records = [
        at(now - 2 * day, 'John 3 w/ Sam'),
        at(now - day, 'Lesson 8 w/ Sam', activityId: 'piano'),
        at(now, 'John 9 w/ Sam'),
      ];
      expect(
        suggestedReading(
          records,
          activityId: 'read',
          firstPerson: 'Sam',
          beforeEpochMs: now,
        ),
        'John 4',
      );
    });

    test('is null with no match or no number to move', () {
      expect(
        suggestedReading(
          [at(now - day, 'John 3 w/ Ana')],
          activityId: 'read',
          firstPerson: 'Sam',
          beforeEpochMs: now,
        ),
        isNull,
      );
      expect(
        suggestedReading(
          [at(now - day, 'Coffee w/ Sam')],
          activityId: 'read',
          firstPerson: 'Sam',
          beforeEpochMs: now,
        ),
        isNull,
      );
    });

    test('counts a Record split at midnight once', () {
      final records = [
        at(now - 9 * day, 'John 3 w/ Sam'),
        at(now - 2 * day - hour, 'John 5 w/ Sam', isMidnightSplit: true),
        at(now - 2 * day, 'John 5 w/ Sam'),
      ];
      expect(
        suggestedReading(
          records,
          activityId: 'read',
          firstPerson: 'Sam',
          beforeEpochMs: now,
        ),
        'John 7',
      );
    });
  });

  group('withSuggestedReading', () {
    test('fills an empty reading', () {
      expect(
        withSuggestedReading('w/ Sam', previous: null, next: 'John 4'),
        'John 4 w/ Sam',
      );
    });

    test('replaces a reading that is still the old suggestion', () {
      expect(
        withSuggestedReading(
          'John 4 w/ Ana',
          previous: 'John 4',
          next: 'Rom 2',
        ),
        'Rom 2 w/ Ana',
      );
      expect(
        withSuggestedReading('John 4', previous: 'John 4', next: 'Rom 2'),
        'Rom 2',
      );
    });

    test('never overwrites a typed reading', () {
      expect(
        withSuggestedReading(
          'Luke 1 w/ Ana',
          previous: 'John 4',
          next: 'Rom 2',
        ),
        'Luke 1 w/ Ana',
      );
    });

    test('drops the old suggestion when there is no new one', () {
      expect(
        withSuggestedReading('John 4 w/ Ana', previous: 'John 4', next: null),
        'w/ Ana',
      );
    });

    test('keeps free text after the names', () {
      expect(
        withSuggestedReading(
          'John 4 w/ Ana at church',
          previous: 'John 4',
          next: 'Rom 2',
        ),
        'Rom 2 w/ Ana at church',
      );
    });
  });

  group('recurringNote', () {
    // Wednesday 4 November 2026, 19:30 UTC.
    final target = DateTime.utc(2026, 11, 4, 19, 30).millisecondsSinceEpoch;
    int weeksBefore(int weeks, {int minutes = -30}) =>
        target - weeks * 7 * day + minutes * 60 * 1000;

    RecurringNote? match(List<Record> records, {String? activityId = 'read'}) =>
        recurringNote(
          records,
          activityId: activityId,
          targetEpochMs: target,
          targetZoneId: 'UTC',
        );

    test('matches on 2 of the last 4 weekdays and advances the reading', () {
      final note = match([
        at(weeksBefore(3), 'John 3 w/ Sam'),
        at(weeksBefore(1), 'John 4 w/ Sam'),
      ]);
      expect(note, isNotNull);
      expect(note!.activityId, 'read');
      expect(note.people, ['Sam']);
      expect(note.comment, 'John 5 w/ Sam');
    });

    test('needs at least 2 of the last 4 weekdays', () {
      expect(match([at(weeksBefore(1), 'John 4 w/ Sam')]), isNull);
      // The fifth Wednesday back is outside the last four.
      expect(
        match([
          at(weeksBefore(5), 'John 3 w/ Sam'),
          at(weeksBefore(1), 'John 4 w/ Sam'),
        ]),
        isNull,
      );
      // Two Records on one Wednesday are one day.
      expect(
        match([
          at(weeksBefore(1, minutes: -50), 'John 3 w/ Sam'),
          at(weeksBefore(1, minutes: 20), 'John 4 w/ Sam'),
        ]),
        isNull,
      );
    });

    test('counts only starts within an hour of the target time', () {
      expect(
        match([
          at(weeksBefore(2, minutes: -90), 'John 3 w/ Sam'),
          at(weeksBefore(1), 'John 4 w/ Sam'),
        ]),
        isNull,
      );
      expect(
        match([
          at(weeksBefore(2, minutes: 60), 'John 3 w/ Sam'),
          at(weeksBefore(1, minutes: -60), 'John 4 w/ Sam'),
        ]),
        isNotNull,
      );
    });

    test('counts only the same weekday', () {
      expect(
        match([
          at(weeksBefore(1) - day, 'John 3 w/ Sam'),
          at(weeksBefore(1), 'John 4 w/ Sam'),
        ]),
        isNull,
      );
    });

    test('counts only the same Activity', () {
      expect(
        match([
          at(weeksBefore(2), 'John 3 w/ Sam', activityId: 'walk'),
          at(weeksBefore(1), 'John 4 w/ Sam'),
        ]),
        isNull,
      );
    });

    test("reads each Record's weekday and hour in its own start zone", () {
      final nyTarget = wallIn(
        'America/New_York',
        DateTime.utc(2026, 11, 4, 19),
      );
      final records = [
        // Wednesday 19:00 in Tokyo: the lived weekday and hour match.
        at(
          wallIn('Asia/Tokyo', DateTime.utc(2026, 10, 21, 19)),
          'John 3 w/ Sam',
          zone: 'Asia/Tokyo',
        ),
        at(
          wallIn('America/New_York', DateTime.utc(2026, 10, 28, 19)),
          'John 4 w/ Sam',
          zone: 'America/New_York',
        ),
      ];
      final note = recurringNote(
        records,
        activityId: 'read',
        targetEpochMs: nyTarget,
        targetZoneId: 'America/New_York',
      );
      expect(note?.comment, 'John 5 w/ Sam');

      // Wednesday 19:00 New York instant, but lived as Thursday 08:00 in
      // Tokyo: it does not count.
      final shifted = [
        at(
          wallIn('America/New_York', DateTime.utc(2026, 10, 21, 19)),
          'John 3 w/ Sam',
          zone: 'Asia/Tokyo',
        ),
        records[1],
      ];
      expect(
        recurringNote(
          shifted,
          activityId: 'read',
          targetEpochMs: nyTarget,
          targetZoneId: 'America/New_York',
        ),
        isNull,
      );
    });

    test('offers a note without a number as written', () {
      final note = match([
        at(weeksBefore(4), 'Choir practice'),
        at(weeksBefore(2), 'Choir practice'),
      ]);
      expect(note?.comment, 'Choir practice');
      expect(note?.people, isEmpty);
    });

    test('advances a numbered note that names no one', () {
      final note = match([
        at(weeksBefore(2), 'Lesson 4'),
        at(weeksBefore(1), 'Lesson 5'),
      ]);
      expect(note?.comment, 'Lesson 6');
    });

    test('moves the reading from the latest Record with that Person', () {
      final note = match([
        at(weeksBefore(2), 'John 3 w/ Sam at church'),
        at(weeksBefore(1), 'John 4 w/ Sam at church'),
        // An extra Saturday meeting, not on the weekday.
        at(weeksBefore(1) + 3 * day, 'John 5 w/ Sam'),
      ]);
      expect(note?.comment, 'John 6 w/ Sam at church');
    });

    test('with no Activity given, takes the best match of any Activity', () {
      final note = match([
        at(weeksBefore(3), 'Lesson 2 w/ Ana', activityId: 'piano'),
        at(weeksBefore(2), 'Lesson 3 w/ Ana', activityId: 'piano'),
        at(weeksBefore(1), 'Lesson 4 w/ Ana', activityId: 'piano'),
        at(weeksBefore(2), 'John 3 w/ Sam'),
        at(weeksBefore(1), 'John 4 w/ Sam'),
      ], activityId: null);
      expect(note?.activityId, 'piano');
      expect(note?.comment, 'Lesson 5 w/ Ana');
    });
  });

  group('comboSuggestions', () {
    final target = DateTime.utc(2026, 11, 4, 19, 30).millisecondsSinceEpoch;

    List<RecurringNote> combos(List<Record> records, List<String> ids) =>
        comboSuggestions(
          records,
          activityIds: ids,
          targetEpochMs: target,
          targetZoneId: 'UTC',
        );

    test('puts the RecurringNote first, then the latest combo', () {
      final records = [
        at(target - 14 * day, 'Lesson 2 w/ Ana', activityId: 'piano'),
        at(target - 7 * day, 'Lesson 3 w/ Ana', activityId: 'piano'),
        at(target - 2 * day, 'John 3 w/ Sam'),
        at(target - day, 'Walk w/ Lee', activityId: 'walk'),
      ];
      final result = combos(records, ['read', 'walk']);
      expect(
        [for (final c in result) c.comment],
        ['Lesson 4 w/ Ana', 'w/ Lee'],
      );
      expect(result[1].people, ['Lee']);
    });

    test('without a RecurringNote, takes the two latest distinct combos', () {
      final records = [
        at(target - 5 * day, 'John 2 w/ Sam'),
        at(target - 4 * day, 'Coffee w/ Ana', activityId: 'cafe'),
        at(target - 3 * day, 'John 3 w/ Sam'),
        at(target - 2 * day, 'Psalm 9'),
        at(target - day, 'Walk w/ Lee', activityId: 'walk'),
      ];
      expect(
        [
          for (final c in combos(records, ['read', 'walk'])) c.comment,
        ],
        ['w/ Lee', 'John 4 w/ Sam'],
      );
    });

    test('does not repeat the RecurringNote as a latest combo', () {
      final records = [
        at(target - 14 * day, 'John 3 w/ Sam'),
        at(target - 7 * day, 'John 4 w/ Sam'),
      ];
      expect(
        [
          for (final c in combos(records, ['read'])) c.comment,
        ],
        ['John 5 w/ Sam'],
      );
    });
  });
}
