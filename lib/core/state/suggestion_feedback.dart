import 'dart:convert';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'auto_advance.dart';
import 'people_index.dart';
import 'suggestion_engine.dart';

/// A Tag's fit for an Activity, shown by how a suggestion's Tags were edited
/// after logging: removed (-1), added (+1) or kept (+1/4).
class TagFeedback {
  final String activityId;
  final String tagId;

  /// The vote in micro-units, before it fades.
  final int micros;
  final int givenAtEpochMs;

  const TagFeedback({
    required this.activityId,
    required this.tagId,
    required this.micros,
    required this.givenAtEpochMs,
  });
}

/// The votes to rank with: explicit ones, and those read from how Records
/// labeled from a suggestion look now.
class ResolvedFeedback {
  final List<SuggestionFeedback> votes;
  final List<TagFeedback> tags;

  const ResolvedFeedback({this.votes = const [], this.tags = const []});

  static const ResolvedFeedback none = ResolvedFeedback();
}

/// What the Record labeled from [logged] says about that suggestion now that
/// the user may have edited it. [record] is null when it was undone or
/// deleted, which says nothing.
///
/// - A different Activity counts against the suggestion (and its note).
/// - The same Activity is a light vote for it.
/// - For a note suggestion, the same People and reading count strongly for
///   it; a kept reading with other People counts lightly for it; a rewritten
///   reading counts against it.
/// - Each suggested Tag removed counts against that Tag for the Activity, each
///   one added counts for it, and each kept counts lightly for it.
ResolvedFeedback resolveLogged(SuggestionFeedback logged, Record? record) {
  if (record == null) return ResolvedFeedback.none;
  final people = logged.people;
  if (record.activityId != logged.activityId) {
    return ResolvedFeedback(
      votes: [
        logged.withVote(SuggestionVote.notUseful),
        if (people != null)
          logged.withVote(SuggestionVote.notUseful, people: people),
      ],
    );
  }

  final votes = [logged.withVote(SuggestionVote.accepted)];
  if (people != null) {
    final suggested = logged.comment ?? '';
    final sameReading =
        _normalized(splitComment(record.comment).reading) ==
        _normalized(splitComment(suggested).reading);
    final samePeople =
        SuggestionFeedback.comboKey('', peopleIn(record.comment)) ==
        SuggestionFeedback.comboKey('', peopleIn(suggested));
    final vote = !sameReading
        ? SuggestionVote.notUseful
        : samePeople
        ? SuggestionVote.good
        : SuggestionVote.accepted;
    votes.add(logged.withVote(vote, people: people));
  }

  final tags = <TagFeedback>[];
  final suggestedTags = logged.tagIds;
  if (suggestedTags != null) {
    TagFeedback tag(String id, int micros) => TagFeedback(
      activityId: logged.activityId,
      tagId: id,
      micros: micros,
      givenAtEpochMs: logged.givenAtEpochMs,
    );
    const unit = 1000000;
    for (final id in suggestedTags) {
      tags.add(tag(id, record.tagIds.contains(id) ? unit ~/ 4 : -unit));
    }
    for (final id in record.tagIds) {
      if (!suggestedTags.contains(id)) tags.add(tag(id, unit));
    }
  }
  return ResolvedFeedback(votes: votes, tags: tags);
}

String _normalized(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Net faded Tag feedback for [activityId] at [nowEpochMs], by Tag, in
/// micro-units.
Map<String, int> tagFeedbackNet(
  Iterable<TagFeedback> feedback, {
  required String activityId,
  required int nowEpochMs,
}) {
  final net = <String, int>{};
  for (final entry in feedback) {
    if (entry.activityId != activityId) continue;
    final weight =
        entry.micros *
        ContextualSuggestionEngine.decayMicros(
          nowEpochMs - entry.givenAtEpochMs,
        ) ~/
        1000000;
    if (weight == 0) continue;
    net.update(entry.tagId, (value) => value + weight, ifAbsent: () => weight);
  }
  return net;
}

/// Suggestion feedback, kept on this device as one JSON list in the
/// `settings` table under [storageKey]. It is not synced or exported.
class SuggestionFeedbackStore {
  const SuggestionFeedbackStore._();

  static const String storageKey = 'suggestion_feedback';

  /// The most entries kept. The oldest go first.
  static const int maxEntries = 500;

  /// Every stored entry, oldest first. Unreadable data reads as none.
  static Future<List<SuggestionFeedback>> load(TempoDatabase database) async {
    final stored = await database.getSetting(storageKey);
    if (stored == null || stored.isEmpty) return const [];
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return const [];
      return [for (final entry in decoded) ?SuggestionFeedback.fromJson(entry)];
    } on FormatException {
      return const [];
    }
  }

  /// Adds [feedback], dropping entries too old to count any more and the
  /// oldest beyond [maxEntries].
  static Future<void> add(
    TempoDatabase database,
    SuggestionFeedback feedback,
  ) async {
    final cutoff =
        feedback.givenAtEpochMs -
        ContextualSuggestionEngine.historyWindow.inMilliseconds;
    final kept = [
      for (final entry in await load(database))
        if (entry.givenAtEpochMs >= cutoff) entry,
      feedback,
    ];
    final trimmed = kept.length > maxEntries
        ? kept.sublist(kept.length - maxEntries)
        : kept;
    await database.setSetting(
      storageKey,
      jsonEncode([for (final entry in trimmed) entry.toJson()]),
    );
  }

  /// Every stored entry, with each logged suggestion read against its Record
  /// as it is now.
  static Future<ResolvedFeedback> loadResolved(TempoDatabase database) async {
    final entries = await load(database);
    final recordIds = [
      for (final entry in entries)
        if (entry.vote == SuggestionVote.logged) entry.recordId!,
    ];
    final records = await _recordsById(database, recordIds);
    final votes = <SuggestionFeedback>[];
    final tags = <TagFeedback>[];
    for (final entry in entries) {
      if (entry.vote != SuggestionVote.logged) {
        votes.add(entry);
        continue;
      }
      final resolved = resolveLogged(entry, records[entry.recordId]);
      votes.addAll(resolved.votes);
      tags.addAll(resolved.tags);
    }
    return ResolvedFeedback(votes: votes, tags: tags);
  }

  /// The Activity, comment and Tags of each Record in [ids] that still exists.
  static Future<Map<String, Record>> _recordsById(
    TempoDatabase database,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await database.db.query(
      'records',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final tagRows = await database.db.query(
      'record_tags',
      columns: ['record_id', 'tag_id'],
      where: 'record_id IN ($placeholders)',
      whereArgs: ids,
    );
    final tagsByRecord = <String, List<String>>{};
    for (final row in tagRows) {
      (tagsByRecord[row['record_id'] as String] ??= []).add(
        row['tag_id'] as String,
      );
    }
    return {
      for (final row in rows)
        row['id'] as String: Record.fromMap(
          row,
          tagIds: tagsByRecord[row['id']] ?? const [],
        ),
    };
  }

  /// The Activity just before [targetEpochMs], read from the Records that
  /// started before it with the chain the engine ranks with, so a Record that
  /// starts at the target (the label being given) does not count.
  static Future<String?> precedingActivityId(
    TempoDatabase database,
    int targetEpochMs,
  ) async {
    final history = await database.getSuggestionHistory(
      startedAfter:
          targetEpochMs -
          ContextualSuggestionEngine.historyWindow.inMilliseconds,
      startedBefore: targetEpochMs - 1,
    );
    return ContextualSuggestionEngine.contextFromHistory(
      history,
      targetEpochMs: targetEpochMs,
    ).precedingActivityId;
  }

  /// Forgets all feedback.
  static Future<void> clear(TempoDatabase database) =>
      database.setSetting(storageKey, '');

  /// Records [vote] on [activityId] as suggested for [targetEpochMs]: on a
  /// note suggestion when [people] is given. For [SuggestionVote.logged], pass
  /// the [recordId] the label made and the [comment] and [tagIds] it was
  /// given, so later edits to it count.
  ///
  /// The Activity before the target is read from the Records that started
  /// before it, the same chain the engine ranks with, so a Record the tap
  /// itself creates at the target does not count.
  static Future<void> record({
    required TempoDatabase database,
    required String activityId,
    required SuggestionVote vote,
    required int nowEpochMs,
    int? targetEpochMs,
    required String timezoneId,
    List<String>? people,
    String? recordId,
    String? comment,
    List<String>? tagIds,
  }) async {
    final target = targetEpochMs ?? nowEpochMs;
    final preceding = await precedingActivityId(database, target);
    await add(
      database,
      SuggestionFeedback(
        activityId: activityId,
        vote: vote,
        givenAtEpochMs: nowEpochMs,
        targetEpochMs: target,
        timezoneId: timezoneId,
        precedingActivityId: preceding,
        people: people,
        recordId: recordId,
        comment: comment,
        tagIds: tagIds,
      ),
    );
  }
}

/// A fresh vote's worth, in micro-units, at which Tag feedback overrides what
/// history alone would fill in.
const int _tagFeedbackThreshold = 500000;

/// The Tags to fill in on a suggestion of [activityId] at [beforeEpochMs].
///
/// From history: the Tags on at least half of the Activity's last four
/// Records, counting only Records that name the same first Person when
/// [people] is given. Tag feedback then drops a Tag the user keeps removing
/// and adds one they keep adding. The Contact Tag follows [people], unless
/// the user keeps removing it from this Activity.
List<String> suggestedTagIds(
  Iterable<Record> records, {
  required String activityId,
  List<String> people = const [],
  String? contactTagId,
  Iterable<TagFeedback> feedback = const [],
  required int beforeEpochMs,
}) {
  final person = people.isEmpty ? null : people.first.toLowerCase();
  final recent = [
    for (final r in records)
      if (r.activityId == activityId &&
          !r.isMidnightSplit &&
          r.startedAtEpochMs < beforeEpochMs &&
          (person == null || _firstPerson(r.comment) == person))
        r,
  ]..sort((a, b) => b.startedAtEpochMs.compareTo(a.startedAtEpochMs));
  final latest = recent.take(4).toList();

  final counts = <String, int>{};
  for (final r in latest) {
    for (final id in r.tagIds) {
      if (id == contactTagId) continue;
      counts.update(id, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  final threshold = (latest.length + 1) ~/ 2;
  final net = tagFeedbackNet(
    feedback,
    activityId: activityId,
    nowEpochMs: beforeEpochMs,
  );
  bool dropped(String id) => (net[id] ?? 0) <= -_tagFeedbackThreshold;

  final fromHistory = [
    for (final MapEntry(key: id, value: count) in counts.entries)
      if (count >= threshold && !dropped(id)) id,
  ];
  return [
    ...fromHistory,
    for (final MapEntry(key: id, value: value) in net.entries)
      if (value >= _tagFeedbackThreshold &&
          id != contactTagId &&
          !fromHistory.contains(id))
        id,
    if (contactTagId != null && people.isNotEmpty && !dropped(contactTagId))
      contactTagId,
  ];
}

String? _firstPerson(String comment) {
  final names = peopleIn(comment);
  return names.isEmpty ? null : names.first.toLowerCase();
}
