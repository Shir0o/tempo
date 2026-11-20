/// What the user said, or showed, about one suggestion.
enum SuggestionVote {
  /// Marked as a good suggestion, or kept exactly as suggested.
  good('good'),

  /// Marked as not useful here, or changed after logging.
  notUseful('not_useful'),

  /// A light vote for it: kept, with small changes.
  accepted('accepted'),

  /// The Lap was labeled from this suggestion as [SuggestionFeedback.recordId].
  /// Not a vote by itself: it is read against what that Record holds now, so
  /// later edits count as feedback.
  logged('logged'),

  /// The Lap was labeled without a suggestion, as [SuggestionFeedback.recordId],
  /// with learned Tags filled in. Not a vote on the Activity: only how those
  /// Tags were edited afterwards counts.
  tagged('tagged');

  /// A vote the user gave on purpose, which wins over what edits suggest.
  bool get isExplicit => this == good || this == notUseful;

  /// Kept with the Record it was given for, and read against it later.
  bool get readsRecord => this == logged || this == tagged;

  const SuggestionVote(this.storageValue);

  final String storageValue;

  static SuggestionVote? fromStorage(Object? value) {
    for (final vote in values) {
      if (vote.storageValue == value) return vote;
    }
    return null;
  }
}

/// One vote on a suggestion, with the moment it was suggested for.
///
/// The moment is kept as the target instant in its zone and the Activity
/// before it, so the engine can tell how alike a later moment is.
///
/// With [people] set, the vote is about a note suggestion (an Activity with
/// those People, offered under WITH NOTE) rather than the Activity alone.
class SuggestionFeedback {
  final String activityId;
  final SuggestionVote vote;

  /// When the vote was given. Feedback fades from here.
  final int givenAtEpochMs;

  /// The moment the suggestion was for: the open Lap's start.
  final int targetEpochMs;
  final String timezoneId;

  /// The Activity just before [targetEpochMs], if any.
  final String? precedingActivityId;

  /// The People of a note suggestion; null for an Activity suggestion.
  final List<String>? people;

  /// For [SuggestionVote.logged] and [SuggestionVote.tagged]: the Record the
  /// label made, and the note and Tags it was given. An explicit vote given
  /// on a logged Record keeps its [recordId], so a later vote replaces it.
  final String? recordId;
  final String? comment;
  final List<String>? tagIds;

  const SuggestionFeedback({
    required this.activityId,
    required this.vote,
    required this.givenAtEpochMs,
    required this.targetEpochMs,
    required this.timezoneId,
    this.precedingActivityId,
    this.people,
    this.recordId,
    this.comment,
    this.tagIds,
  });

  /// What identifies a note suggestion: its Activity and People, any case.
  static String comboKey(String activityId, List<String> people) =>
      '$activityId\n${people.map((p) => p.toLowerCase()).join(', ')}';

  /// This entry's moment with another [vote], about the Activity alone or,
  /// with [people], about that note suggestion. [givenAtEpochMs] and
  /// [recordId] replace this entry's when given.
  SuggestionFeedback withVote(
    SuggestionVote vote, {
    List<String>? people,
    int? givenAtEpochMs,
    String? recordId,
  }) => SuggestionFeedback(
    activityId: activityId,
    vote: vote,
    givenAtEpochMs: givenAtEpochMs ?? this.givenAtEpochMs,
    targetEpochMs: targetEpochMs,
    timezoneId: timezoneId,
    precedingActivityId: precedingActivityId,
    people: people,
    recordId: recordId,
  );

  Map<String, Object?> toJson() => {
    'activity': activityId,
    'vote': vote.storageValue,
    'given': givenAtEpochMs,
    'target': targetEpochMs,
    'zone': timezoneId,
    if (precedingActivityId != null) 'after': precedingActivityId,
    if (people != null) 'people': people,
    if (recordId != null) 'record': recordId,
    if (comment != null) 'comment': comment,
    if (tagIds != null) 'tags': tagIds,
  };

  /// Decodes one stored entry, or null when it is malformed.
  static SuggestionFeedback? fromJson(Object? json) {
    if (json is! Map) return null;
    final activityId = json['activity'];
    final vote = SuggestionVote.fromStorage(json['vote']);
    final given = json['given'];
    final target = json['target'];
    final zone = json['zone'];
    final after = json['after'];
    final people = _strings(json['people']);
    final record = json['record'];
    final comment = json['comment'];
    final tags = _strings(json['tags']);
    if (activityId is! String ||
        vote == null ||
        given is! int ||
        target is! int ||
        zone is! String ||
        (after != null && after is! String) ||
        (json['people'] != null && people == null) ||
        (record != null && record is! String) ||
        (comment != null && comment is! String) ||
        (json['tags'] != null && tags == null) ||
        (vote.readsRecord && record == null)) {
      return null;
    }
    return SuggestionFeedback(
      activityId: activityId,
      vote: vote,
      givenAtEpochMs: given,
      targetEpochMs: target,
      timezoneId: zone,
      precedingActivityId: after as String?,
      people: people,
      recordId: record as String?,
      comment: comment as String?,
      tagIds: tags,
    );
  }

  static List<String>? _strings(Object? value) {
    if (value is! List) return null;
    if (value.any((item) => item is! String)) return null;
    return value.cast<String>().toList(growable: false);
  }
}
