import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';
import 'package:tempo/ui/helpers/ui_helpers.dart';
import 'package:tempo/ui/theme/tempo_theme.dart';

/// WCAG 2.x AA contrast for normal-size text.
const double _wcagAA = 4.5;

/// Bright and medium colours from the UI/UX audit fixtures. These used to be
/// misread as dark by `estimateBrightnessForColor`, so they rendered white
/// text at well under 4.5:1.
const _fixtureColors = ['#2196F3', '#EF5350', '#AB47BC', '#FFB300'];

/// Custom colours dark enough that ink would disappear.
const _darkCustomColors = ['#795548', '#263238', '#121210', '#1B1B18'];

const _gridActivities = [
  Activity(
    id: 'act-amber',
    name: 'Meals',
    colorHex: '#FFB300',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-blue',
    name: 'Coding',
    colorHex: '#2196F3',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-coral',
    name: 'Errands',
    colorHex: '#EF5350',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-purple',
    name: 'Exercise',
    colorHex: '#AB47BC',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-dark',
    name: 'Night reading',
    colorHex: '#263238',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
];

void _expectAA(Color? textColor, Color background, String label) {
  expect(textColor, isNotNull, reason: '$label needs an explicit text colour');
  final ratio = TempoColors.contrastRatio(textColor!, background);
  expect(
    ratio,
    greaterThanOrEqualTo(_wcagAA),
    reason:
        '$label is ${ratio.toStringAsFixed(2)}:1 against '
        '${background.toARGB32().toRadixString(16)}',
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('TempoColors Activity contrast', () {
    test('every palette colour keeps ink name and readable total', () {
      for (final color in TempoColors.activityPalette) {
        expect(
          TempoColors.onActivityColor(color),
          TempoColors.ink,
          reason: 'palette colour $color should take ink text',
        );
        _expectAA(TempoColors.onActivityColor(color), color, 'Palette name');
        _expectAA(
          TempoColors.secondaryOnActivityColor(color),
          color,
          'Palette total',
        );
      }
    });

    test('bright and medium fixture colours clear AA for both lines', () {
      for (final hex in _fixtureColors) {
        final color = UiHelpers.parseHexColor(hex);
        _expectAA(TempoColors.onActivityColor(color), color, '$hex name');
        _expectAA(
          TempoColors.secondaryOnActivityColor(color),
          color,
          '$hex total',
        );
      }
    });

    test('dark custom colours take white and stay above AA', () {
      for (final hex in _darkCustomColors) {
        final color = UiHelpers.parseHexColor(hex);
        expect(
          TempoColors.onActivityColor(color),
          Colors.white,
          reason: '$hex is dark enough to need white text',
        );
        _expectAA(TempoColors.onActivityColor(color), color, '$hex name');
        _expectAA(
          TempoColors.secondaryOnActivityColor(color),
          color,
          '$hex total',
        );
      }
    });
  });

  testWidgets('Today Activity blocks render AA-contrast name and total', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    for (final activity in _gridActivities) {
      await db.insertActivity(activity);
    }

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();

    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    for (final activity in _gridActivities) {
      final block = find.byKey(ValueKey('activity-block-${activity.id}'));
      expect(
        block,
        findsOneWidget,
        reason: '${activity.name} block is missing',
      );

      final material = tester.widget<Material>(
        find.ancestor(of: block, matching: find.byType(Material)).first,
      );
      final background = material.color!;
      expect(background, UiHelpers.parseHexColor(activity.colorHex));

      final texts = tester
          .widgetList<Text>(
            find.descendant(of: block, matching: find.byType(Text)),
          )
          .toList();
      expect(texts, hasLength(2));
      expect(texts.first.data, activity.name);
      for (final text in texts) {
        _expectAA(
          text.style?.color,
          background,
          '${activity.name} "${text.data}"',
        );
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
