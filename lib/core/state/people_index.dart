import 'dart:math' as math;

import '../../data/models/models.dart';
import 'auto_advance.dart';

/// People drawn from past comments: the names written after a NameMarker
/// (`w/` or `with `). There is no table of People; this reads them back out of
/// Records and writes them into a comment.
///
/// The comment is split by [splitComment]. On top of that, a Person's name
/// starts with a capital letter and holds only letters, apostrophes and
/// hyphens, so "dinner with friends" names no one and "w/ Sam." names Sam.
/// The first name that does not look like a Person ends the list.

final RegExp _person = RegExp(
  r"^\p{Lu}[\p{L}\p{M}'’\-]*(?: \p{Lu}[\p{L}\p{M}'’\-]*)?",
  unicode: true,
);

/// A comment split around its People. [hasMarker] is false when there is no
/// NameMarker, or when the word after it is not a name (prose "with").
class _PeopleSplit {
  final String reading;
  final List<String> names;
  final String extra;
  final bool hasMarker;

  const _PeopleSplit(this.reading, this.names, this.extra, this.hasMarker);
}

_PeopleSplit _split(String comment) {
  final parts = splitComment(comment);
  final hasMarker = parts.names.isNotEmpty || parts.reading != comment.trim();
  final names = <String>[];
  var extra = parts.extra;
  for (var i = 0; i < parts.names.length; i++) {
    final raw = parts.names[i];
    final match = _person.firstMatch(raw);
    if (match == null && names.isEmpty) {
      return _PeopleSplit(comment.trim(), const [], '', false);
    }
    final kept = match?.group(0) ?? '';
    if (kept.isNotEmpty) names.add(kept);
    if (kept.length < raw.length) {
      // The rest of this name and the names after it are free text again.
      final rest = [
        if (kept.isEmpty) ', $raw' else raw.substring(kept.length),
        for (final later in parts.names.skip(i + 1)) ', $later',
      ].join();
      extra = extra.isEmpty ? rest : '$rest $extra';
      break;
    }
  }
  return _PeopleSplit(parts.reading, names, extra, hasMarker);
}

/// How fast an old mention fades when ranking: its weight halves every
/// [peopleHalfLife].
const Duration peopleHalfLife = Duration(days: 14);

/// Every Person named after the first NameMarker in [comment], in order,
/// without repeats (ignoring case).
List<String> peopleIn(String comment) {
  final seen = <String>{};
  return [
    for (final name in _split(comment).names)
      if (seen.add(name.toLowerCase())) name,
  ];
}

/// The People in [records]' comments, best first, at most [limit].
///
/// Each mention counts for more the more recent its Record's end is, so the
/// score mixes how often and how lately someone was named. With [activityId],
/// People named on that Activity's Records come first (ranked among
/// themselves), then everyone else. Ties go to the latest mention, then to
/// the name. A name is shown as it was last written.
List<String> rankPeople(
  Iterable<Record> records, {
  required int nowEpochMs,
  String? activityId,
  int limit = 8,
}) {
  final global = <String, double>{};
  final scoped = <String, double>{};
  final lastSeen = <String, int>{};
  final spelling = <String, String>{};
  final halfLifeMs = peopleHalfLife.inMilliseconds;

  for (final record in records) {
    if (record.comment.isEmpty) continue;
    final ageMs = math.max(0, nowEpochMs - record.endedAtEpochMs);
    final weight = math.pow(0.5, ageMs / halfLifeMs).toDouble();
    for (final name in peopleIn(record.comment)) {
      final key = name.toLowerCase();
      global.update(key, (s) => s + weight, ifAbsent: () => weight);
      if (activityId != null && record.activityId == activityId) {
        scoped.update(key, (s) => s + weight, ifAbsent: () => weight);
      }
      if (record.endedAtEpochMs >= (lastSeen[key] ?? -1)) {
        lastSeen[key] = record.endedAtEpochMs;
        spelling[key] = name;
      }
    }
  }

  int compare(String a, String b) {
    final aScoped = scoped.containsKey(a);
    final bScoped = scoped.containsKey(b);
    if (aScoped != bScoped) return aScoped ? -1 : 1;
    final scores = aScoped ? scoped : global;
    final byScore = scores[b]!.compareTo(scores[a]!);
    if (byScore != 0) return byScore;
    final byRecency = lastSeen[b]!.compareTo(lastSeen[a]!);
    if (byRecency != 0) return byRecency;
    return a.compareTo(b);
  }

  final keys = global.keys.toList()..sort(compare);
  return [for (final key in keys.take(limit)) spelling[key]!];
}

/// [comment] with its People set to [names], laid out as
/// `<reading> w/ <names> <extra words>`.
///
/// The names after the NameMarker are replaced and the marker is written as
/// `w/`; with no names left the marker goes too. With no marker (or only prose
/// "with"), ` w/ <names>` is added at the end and the rest is left as typed.
String withPeople(String comment, List<String> names) {
  final split = _split(comment);
  if (!split.hasMarker) {
    return names.isEmpty ? comment : _join(comment, 'w/ ${names.join(', ')}');
  }
  if (names.isEmpty) {
    return _join(
      split.reading,
      split.extra.replaceFirst(RegExp(r'^[,\s]+'), ''),
    );
  }
  final people = _join(split.reading, 'w/ ${names.join(', ')}');
  // Punctuation that followed the last name stays attached to it.
  return split.extra.startsWith(RegExp(r'[,.;:!?)]'))
      ? '$people${split.extra}'
      : _join(people, split.extra);
}

/// [left] and [right] joined by one space, with no space at either end.
String _join(String left, String right) {
  final l = left.trim();
  final r = right.trim();
  if (l.isEmpty) return r;
  if (r.isEmpty) return l;
  return '$l $r';
}

/// The id of the Contact Tag, or null when none is marked in Settings.
String? contactTagId(Iterable<Tag> tags) {
  for (final tag in tags) {
    if (tag.isContact) return tag.id;
  }
  return null;
}

/// [tagIds] with the Contact Tag attached when [hasPeople].
///
/// Only ever adds: removing the names from a comment keeps the tag, so a
/// Record that was shared stays marked until the user removes it.
List<String> tagIdsWithContact(
  List<String> tagIds,
  String? contactId, {
  required bool hasPeople,
}) {
  if (contactId == null || !hasPeople || tagIds.contains(contactId)) {
    return tagIds;
  }
  return [...tagIds, contactId];
}
