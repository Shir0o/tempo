import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/import/stt_format_parser.dart';

void main() {
  group('SttFormatParser', () {
    test('isBackupFormat correctly identifies .backup content vs .csv', () {
      const backupSample = '''
app simple time tracker
category\t1\tSpiritual\t3\t\t
recordType\t2\tExercise\tic_fitness_center_24px\t5\t0\t\t\t\t\t\t0\t
''';
      const csvSample = '''
activity name,time started,time ended,comment,categories,record tags,duration,duration minutes
"Coding",2025-01-07 12:07:24,2025-01-07 13:41:07,"","Productivity","",1:33:43,93
''';

      expect(SttFormatParser.isBackupFormat(backupSample), isTrue);
      expect(SttFormatParser.isBackupFormat(csvSample), isFalse);
    });

    test('mapIconName maps STT drawable tokens to Material icon names', () {
      expect(
        SttFormatParser.mapIconName('ic_fitness_center_24px'),
        equals('fitness_center'),
      );
      expect(
        SttFormatParser.mapIconName('ic_directions_walk_24px'),
        equals('directions_walk'),
      );
      expect(
        SttFormatParser.mapIconName('ic_restaurant_menu_24px'),
        equals('restaurant_menu'),
      );
      expect(
        SttFormatParser.mapIconName('ic_airline_seat_individual_suite_24px'),
        equals('bed'),
      );
      expect(
        SttFormatParser.mapIconName('ic_unknown_foo_24px'),
        equals('schedule'),
      );
      expect(SttFormatParser.mapIconName(null), equals('schedule'));
    });

    test('mapColorToken maps color index integer to hex string', () {
      expect(SttFormatParser.mapColorToken('0'), equals('#F44336'));
      expect(SttFormatParser.mapColorToken('5'), equals('#2196F3'));
      expect(SttFormatParser.mapColorToken('9'), equals('#4CAF50'));
      expect(SttFormatParser.mapColorToken('999'), equals('#4CAF50'));
      expect(SttFormatParser.mapColorToken(null), equals('#4CAF50'));
    });

    test('deterministicColor returns consistent hex color for strings', () {
      final color1 = SttFormatParser.deterministicColor('Spiritual');
      final color2 = SttFormatParser.deterministicColor('Spiritual');
      final color3 = SttFormatParser.deterministicColor('spiritual');
      expect(color1, equals(color2));
      expect(color1, equals(color3));
      expect(color1.startsWith('#'), isTrue);
    });

    test('parses STT .backup file extracting categories, activities, and intervals', () {
      const backupData = '''
app simple time tracker
category\t1\tSpiritual\t3\t\t
category\t2\tEssentials\t7\t\t
typeCategory\t2\t1
typeCategory\t3\t2
recordType\t2\tPrayer\tic_sports_bar_24px\t3\t0\t\t\t\t\t\t0\t
recordType\t3\tSleep\tic_airline_seat_individual_suite_24px\t7\t0\t\t\t\t\t\t0\t
record\t101\t2\t1700000000000\t1700001800000\tMorning prayer\t
record\t102\t3\t1700001800000\t1700005400000\tResting\t
''';

      final envelope = SttFormatParser.parse(
        content: backupData,
        wallClockToEpochMs: (dt) => dt.millisecondsSinceEpoch,
        nowEpochMs: 1700000000000,
      );

      expect(envelope.categories.length, equals(2));
      expect(envelope.categories[0].name, equals('Spiritual'));
      expect(envelope.categories[0].id, equals('cat-1'));
      expect(envelope.categories[1].name, equals('Essentials'));
      expect(envelope.categories[1].id, equals('cat-2'));

      expect(envelope.activities.length, equals(2));
      final prayerAct = envelope.activities.firstWhere(
        (a) => a.name == 'Prayer',
      );
      expect(prayerAct.categoryId, equals('cat-1'));
      expect(prayerAct.iconName, equals('sports_bar'));

      final sleepAct = envelope.activities.firstWhere((a) => a.name == 'Sleep');
      expect(sleepAct.categoryId, equals('cat-2'));
      expect(sleepAct.iconName, equals('bed'));

      expect(envelope.rawIntervals.length, equals(2));
      expect(envelope.rawIntervals[0].activityName, equals('Prayer'));
      expect(envelope.rawIntervals[0].categoryName, equals('Spiritual'));
      expect(envelope.rawIntervals[0].startedAtEpochMs, equals(1700000000000));
      expect(envelope.rawIntervals[0].endedAtEpochMs, equals(1700001800000));
      expect(envelope.rawIntervals[0].comment, equals('Morning prayer'));

      expect(envelope.rawIntervals[1].activityName, equals('Sleep'));
      expect(envelope.rawIntervals[1].categoryName, equals('Essentials'));
      expect(envelope.rawIntervals[1].comment, equals('Resting'));
    });

    test(
      'parses STT .csv file synthesizing categories and resolving intervals',
      () {
        const csvData = '''
activity name,time started,time ended,comment,categories,record tags,duration,duration minutes
"Ministry",2025-01-07 11:50:23,2025-01-07 11:57:23,"Outreach","Spiritual","tag1, tag2",0:7:0,7
"Commute",2025-01-07 11:57:23,2025-01-07 12:00:24,"","Transportation ","",0:3:1,3
''';

        final envelope = SttFormatParser.parse(
          content: csvData,
          wallClockToEpochMs: (dt) => dt.millisecondsSinceEpoch,
          nowEpochMs: 1700000000000,
        );

        expect(envelope.categories.length, equals(2));
        expect(
          envelope.categories.map((c) => c.name),
          containsAll(['Spiritual', 'Transportation']),
        );

        expect(envelope.activities.length, equals(2));
        expect(
          envelope.activities.map((a) => a.name),
          containsAll(['Ministry', 'Commute']),
        );

        expect(envelope.rawIntervals.length, equals(2));
        expect(envelope.rawIntervals[0].activityName, equals('Ministry'));
        expect(envelope.rawIntervals[0].categoryName, equals('Spiritual'));
        expect(envelope.rawIntervals[0].comment, equals('Outreach'));
        expect(envelope.rawIntervals[0].tagNames, equals(['tag1', 'tag2']));

        expect(envelope.rawIntervals[1].activityName, equals('Commute'));
        expect(envelope.rawIntervals[1].categoryName, equals('Transportation'));
      },
    );

    test('handles empty or corrupted lines gracefully', () {
      const corruptedBackup = '''
random header without sense
recordType\tbad
category
record\t1\t2\tnot_a_number\talso_not
record\t2\t3\t200\t100
\t\t\t
''';

      final envelope = SttFormatParser.parse(
        content: corruptedBackup,
        wallClockToEpochMs: (dt) => dt.millisecondsSinceEpoch,
      );

      expect(envelope.categories, isEmpty);
      expect(envelope.activities, isEmpty);
      expect(envelope.rawIntervals, isEmpty);
    });
  });
}
