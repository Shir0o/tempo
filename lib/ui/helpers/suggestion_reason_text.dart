import '../../core/state/suggestion_engine.dart';

const List<String> _weekdaysPlural = [
  'Mondays',
  'Tuesdays',
  'Wednesdays',
  'Thursdays',
  'Fridays',
  'Saturdays',
  'Sundays',
];

/// The one-line "why" under a suggestion chip, such as "After Breakfast" or
/// "Thursdays ~08:05". Null when there is nothing worth saying.
///
/// [activityName] names the preceding Activity for an "After" reason; when it
/// returns null the reason is dropped rather than shown without a name.
String? suggestionReasonText(
  SuggestionReason? reason, {
  required String? Function(String activityId) activityName,
}) {
  if (reason == null) return null;
  String clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
  switch (reason.kind) {
    case SuggestionReasonKind.after:
      final name = activityName(reason.activityId!);
      return name == null ? null : 'After $name';
    case SuggestionReasonKind.weekday:
      return '${_weekdaysPlural[reason.weekday! - 1]} '
          '~${clock(reason.minuteOfDay!)}';
    case SuggestionReasonKind.dayGroup:
      return '${reason.isWeekend! ? 'Weekends' : 'Weekdays'} '
          '~${clock(reason.minuteOfDay!)}';
    case SuggestionReasonKind.frequent:
      return 'Often';
  }
}
