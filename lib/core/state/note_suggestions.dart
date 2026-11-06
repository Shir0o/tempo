/// Which earlier Records feed AutoAdvance and RecurringNote suggestions
/// (see CONTEXT.md). Pure and deterministic: callers load the Records and
/// show the results.
///
/// A MidnightSplit half carries the same note as the Record after it, so it is
/// skipped: one meeting counts once.
library;

import '../../data/models/models.dart';
import '../time/timezone_id.dart';
import 'auto_advance.dart';
import 'people_index.dart';

/// A note to offer for one Activity: the full comment (reading, People and
/// any free text) and the People it names.
class RecurringNote {
  final String activityId;
  final String comment;
  final List<String> people;

  const RecurringNote({
    required this.activityId,
    required this.comment,
    required this.people,
  });
}

/// The AutoAdvance reading for a new Record of [activityId], from the Records
/// that started before [beforeEpochMs]. The key is the Activity plus
/// [firstPerson] (the first Person named, any case); with no Person, the
/// Activity's Records that name no one. Null when nothing matches or the
/// latest reading has no number.
String? suggestedReading(
  Iterable<Record> records, {
  required String activityId,
  String? firstPerson,
  required int beforeEpochMs,
}) {
  final person = firstPerson?.toLowerCase();
  final matching = [
    for (final r in records)
      if (_counts(r) &&
          r.activityId == activityId &&
          r.startedAtEpochMs < beforeEpochMs &&
          _firstPerson(r.comment) == person)
        r,
  ];
  return autoAdvance(_latestFirst(matching));
}

/// [comment] with its reading (the text before the NameMarker) set to [next]
/// when that reading is empty or still the [previous] suggestion. A reading
/// the user typed is returned unchanged. With no [next], an untouched
/// suggestion is removed.
String withSuggestedReading(
  String comment, {
  required String? previous,
  required String? next,
}) {
  final reading = splitComment(comment).reading;
  if (reading.isNotEmpty && reading != previous) return comment;
  return _withReading(comment, next ?? '');
}

/// The RecurringNote for the moment [targetEpochMs], read in [targetZoneId]:
/// a note for the same Activity that started on the same weekday within an
/// hour of the target's time of day, on at least 2 of the last 4 such
/// weekdays before the target's date. Each Record's weekday and hour are read
/// in its own start zone.
///
/// A note is the same when it names the same People; one that names no one
/// is the same when its text matches apart from its numbers. With
/// [activityId] null, any Activity may match; the note seen on the most days
/// wins, then the most recent. The latest matching note is offered with its
/// reading moved on by AutoAdvance (keyed on its first Person), or as written
/// when it has no number.
RecurringNote? recurringNote(
  Iterable<Record> records, {
  String? activityId,
  required int targetEpochMs,
  required String targetZoneId,
}) {
  final target = wallClockAt(targetZoneId, targetEpochMs);
  final targetMinutes = target.hour * 60 + target.minute;
  final weekdays = {
    for (var week = 1; week <= 4; week++)
      DateTime.utc(target.year, target.month, target.day - 7 * week),
  };

  final days = <String, Set<DateTime>>{};
  final latest = <String, Record>{};
  for (final r in records) {
    if (!_counts(r)) continue;
    if (activityId != null && r.activityId != activityId) continue;
    final wall = wallClockAt(r.timezoneId, r.startedAtEpochMs);
    final date = DateTime.utc(wall.year, wall.month, wall.day);
    if (!weekdays.contains(date)) continue;
    if ((wall.hour * 60 + wall.minute - targetMinutes).abs() > 60) continue;
    final key = '${r.activityId}\n${_noteKey(r.comment)}';
    (days[key] ??= {}).add(date);
    final seen = latest[key];
    if (seen == null || r.startedAtEpochMs > seen.startedAtEpochMs) {
      latest[key] = r;
    }
  }

  String? best;
  for (final key in days.keys) {
    if (days[key]!.length < 2) continue;
    if (best == null) {
      best = key;
      continue;
    }
    final byDays = days[key]!.length.compareTo(days[best]!.length);
    final byRecency = latest[key]!.startedAtEpochMs.compareTo(
      latest[best]!.startedAtEpochMs,
    );
    if (byDays > 0 || (byDays == 0 && byRecency > 0)) best = key;
  }
  if (best == null) return null;

  final note = latest[best]!;
  final people = peopleIn(note.comment);
  final String? reading;
  if (people.isNotEmpty) {
    reading = suggestedReading(
      records,
      activityId: note.activityId!,
      firstPerson: people.first,
      beforeEpochMs: targetEpochMs,
    );
  } else {
    final noteKey = _noteKey(note.comment);
    reading = autoAdvance(
      _latestFirst([
        for (final r in records)
          if (_counts(r) &&
              r.activityId == note.activityId &&
              r.startedAtEpochMs < targetEpochMs &&
              _noteKey(r.comment) == noteKey)
            r,
      ]),
    );
  }
  return RecurringNote(
    activityId: note.activityId!,
    comment: reading == null
        ? note.comment.trim()
        : _withReading(note.comment, reading),
    people: people,
  );
}

/// Up to [limit] combo suggestions for the Today row: the RecurringNote of
/// any Activity first, then the latest Records of [activityIds] that name
/// People, one per Activity and set of People. A combo offers its People and,
/// when AutoAdvance finds one, the next reading.
List<RecurringNote> comboSuggestions(
  Iterable<Record> records, {
  required List<String> activityIds,
  required int targetEpochMs,
  required String targetZoneId,
  int limit = 2,
}) {
  final result = <RecurringNote>[];
  final seen = <String>{};
  String comboKey(String activityId, List<String> people) =>
      '$activityId\n${people.map((p) => p.toLowerCase()).join(', ')}';

  final recurring = recurringNote(
    records,
    targetEpochMs: targetEpochMs,
    targetZoneId: targetZoneId,
  );
  if (recurring != null) {
    result.add(recurring);
    seen.add(comboKey(recurring.activityId, recurring.people));
  }

  final candidates = _latestFirstRecords([
    for (final r in records)
      if (_counts(r) &&
          r.startedAtEpochMs < targetEpochMs &&
          activityIds.contains(r.activityId))
        r,
  ]);
  for (final r in candidates) {
    if (result.length >= limit) break;
    final people = peopleIn(r.comment);
    if (people.isEmpty || !seen.add(comboKey(r.activityId!, people))) continue;
    final reading = suggestedReading(
      records,
      activityId: r.activityId!,
      firstPerson: people.first,
      beforeEpochMs: targetEpochMs,
    );
    result.add(
      RecurringNote(
        activityId: r.activityId!,
        comment: withPeople(reading ?? '', people),
        people: people,
      ),
    );
  }
  return result.take(limit).toList();
}

bool _counts(Record r) =>
    r.activityId != null && !r.isMidnightSplit && r.comment.trim().isNotEmpty;

String? _firstPerson(String comment) {
  final people = peopleIn(comment);
  return people.isEmpty ? null : people.first.toLowerCase();
}

/// What makes two notes "the same" for a RecurringNote: the People named, or
/// for a note that names no one, its text with numbers blanked.
String _noteKey(String comment) {
  final people = peopleIn(comment);
  if (people.isNotEmpty) {
    return 'w/ ${people.map((p) => p.toLowerCase()).join(', ')}';
  }
  return comment
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\d+'), '#')
      .replaceAll(RegExp(r'\s+'), ' ');
}

List<Record> _latestFirstRecords(List<Record> records) =>
    records..sort((a, b) => b.startedAtEpochMs.compareTo(a.startedAtEpochMs));

List<String> _latestFirst(List<Record> records) => [
  for (final r in _latestFirstRecords(records)) r.comment,
];

/// [comment] with the text before its NameMarker replaced by [reading].
String _withReading(String comment, String reading) {
  final trimmed = comment.trim();
  final rest = trimmed.substring(splitComment(comment).reading.length).trim();
  if (reading.isEmpty) return rest;
  if (rest.isEmpty) return reading;
  return '$reading $rest';
}
