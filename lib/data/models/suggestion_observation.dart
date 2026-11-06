/// The subset of a Record that the suggestion engine needs.
///
/// Keeping this separate from [Record] lets the history read select only the
/// three columns the engine uses, instead of hydrating full Records and tags on
/// every Lap change.
class SuggestionObservation {
  /// The Activity, or null for an Untracked Record.
  final String? activityId;

  /// The Record's start instant in UTC epoch milliseconds.
  final int startedAtEpochMs;

  /// The IANA zone the Record started in.
  final String timezoneId;

  const SuggestionObservation({
    required this.activityId,
    required this.startedAtEpochMs,
    required this.timezoneId,
  });
}
