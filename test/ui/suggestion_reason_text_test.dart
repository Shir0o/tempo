import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/ui/helpers/suggestion_reason_text.dart';

void main() {
  String? names(String id) => {'breakfast': 'Breakfast'}[id];

  test('names the preceding Activity', () {
    expect(
      suggestionReasonText(
        const SuggestionReason.after('breakfast'),
        activityName: names,
      ),
      'After Breakfast',
    );
  });

  test('drops an After reason whose Activity has no name', () {
    expect(
      suggestionReasonText(
        const SuggestionReason.after('gone'),
        activityName: names,
      ),
      isNull,
    );
  });

  test('gives the day of the week and the typical start', () {
    expect(
      suggestionReasonText(
        const SuggestionReason.weekday(DateTime.thursday, 8 * 60 + 5),
        activityName: names,
      ),
      'Thursdays ~08:05',
    );
  });

  test('gives weekdays or weekends', () {
    expect(
      suggestionReasonText(
        const SuggestionReason.dayGroup(false, 7 * 60 + 30),
        activityName: names,
      ),
      'Weekdays ~07:30',
    );
    expect(
      suggestionReasonText(
        const SuggestionReason.dayGroup(true, 0),
        activityName: names,
      ),
      'Weekends ~00:00',
    );
  });

  test('frequent and none', () {
    expect(
      suggestionReasonText(
        const SuggestionReason.frequent(),
        activityName: names,
      ),
      'Often',
    );
    expect(suggestionReasonText(null, activityName: names), isNull);
  });
}
