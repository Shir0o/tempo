/// What the user said about one suggested Activity.
enum SuggestionVote {
  /// Marked as a good suggestion.
  good('good'),

  /// Marked as not useful here.
  notUseful('not_useful'),

  /// Tapped to label the open Lap: a light vote for it.
  accepted('accepted');

  const SuggestionVote(this.storageValue);

  final String storageValue;

  static SuggestionVote? fromStorage(Object? value) {
    for (final vote in values) {
      if (vote.storageValue == value) return vote;
    }
    return null;
  }
}

/// One vote on a suggested Activity, with the moment it was suggested for.
///
/// The moment is kept as the target instant in its zone and the Activity
/// before it, so the engine can tell how alike a later moment is.
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

  const SuggestionFeedback({
    required this.activityId,
    required this.vote,
    required this.givenAtEpochMs,
    required this.targetEpochMs,
    required this.timezoneId,
    this.precedingActivityId,
  });

  Map<String, Object?> toJson() => {
    'activity': activityId,
    'vote': vote.storageValue,
    'given': givenAtEpochMs,
    'target': targetEpochMs,
    'zone': timezoneId,
    if (precedingActivityId != null) 'after': precedingActivityId,
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
    if (activityId is! String ||
        vote == null ||
        given is! int ||
        target is! int ||
        zone is! String ||
        (after != null && after is! String)) {
      return null;
    }
    return SuggestionFeedback(
      activityId: activityId,
      vote: vote,
      givenAtEpochMs: given,
      targetEpochMs: target,
      timezoneId: zone,
      precedingActivityId: after as String?,
    );
  }
}
