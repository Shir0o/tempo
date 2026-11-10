import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/tempo_app.dart';

class AuditVariant {
  final String name;
  final Size logicalSize;
  final double textScale;
  final Brightness brightness;

  const AuditVariant({
    required this.name,
    required this.logicalSize,
    required this.textScale,
    required this.brightness,
  });
}

const variants = [
  AuditVariant(
    name: 'phone_light',
    logicalSize: Size(390, 844),
    textScale: 1.0,
    brightness: Brightness.light,
  ),
  AuditVariant(
    name: 'phone_dark',
    logicalSize: Size(390, 844),
    textScale: 1.0,
    brightness: Brightness.dark,
  ),
  AuditVariant(
    name: 'small_large_font',
    logicalSize: Size(320, 568),
    textScale: 1.6,
    brightness: Brightness.dark,
  ),
];

const _testActivities = [
  Activity(
    id: 'act-sleep',
    name: 'Sleep',
    colorHex: '#5C6BC0',
    iconName: 'hotel',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-routine',
    name: 'Routine',
    colorHex: '#B0BEC5',
    iconName: 'wb_sunny',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-meals',
    name: 'Meals',
    colorHex: '#FFB300',
    iconName: 'restaurant',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-coding',
    name: 'Coding',
    colorHex: '#2196F3',
    iconName: 'code',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-errands',
    name: 'Errands',
    colorHex: '#EF5350',
    iconName: 'shopping_bag',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-exercise',
    name: 'Exercise',
    colorHex: '#AB47BC',
    iconName: 'fitness_center',
    isPinned: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
];

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final loader = FontLoader('SpaceGrotesk')
      ..addFont(
        rootBundle.load('assets/fonts/SpaceGrotesk-VariableFont_wght.ttf'),
      );
    await loader.load();
  });

  for (final variant in variants) {
    testWidgets('UI/UX audit variant: ${variant.name}', (tester) async {
      tester.view.physicalSize = variant.logicalSize;
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.platformBrightnessTestValue =
          variant.brightness;
      tester.platformDispatcher.textScaleFactorTestValue = variant.textScale;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final db = await TempoDatabase.openInMemory(
        factory: databaseFactoryFfiNoIsolate,
      );
      final dayRecorder = DayRecorder(database: db, autoSplitAtMidnight: false);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        dayRecorder.dispose();
        await db.close();
      });

      for (final activity in _testActivities) {
        await db.insertActivity(activity);
      }

      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      int at(int hour, int minute) => dayStart
          .add(Duration(hours: hour, minutes: minute))
          .millisecondsSinceEpoch;

      await db.insertRecord(
        Record(
          id: 'rec-sleep',
          activityId: 'act-sleep',
          startedAtEpochMs: at(0, 0),
          endedAtEpochMs: at(7, 30),
          timezoneId: localTimezoneId(),
          endTimezoneId: localTimezoneId(),
          createdAtEpochMs: at(0, 0),
          updatedAtEpochMs: at(0, 0),
        ),
      );
      await db.insertRecord(
        Record(
          id: 'rec-routine',
          activityId: 'act-routine',
          startedAtEpochMs: at(7, 30),
          endedAtEpochMs: at(8, 15),
          timezoneId: localTimezoneId(),
          endTimezoneId: localTimezoneId(),
          createdAtEpochMs: at(7, 30),
          updatedAtEpochMs: at(7, 30),
        ),
      );

      final lapStart = at(8, 15);
      await db.setLap(
        Lap(startedAtEpochMs: lapStart, startedTimezoneId: localTimezoneId()),
      );

      await dayRecorder.initialize();

      await tester.pumpWidget(
        TempoApp(
          dayRecorder: dayRecorder,
          database: db,
          commands: PhoneRecordCommands(dayRecorder: dayRecorder),
          showActivityFilter: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Golden capture when autoUpdateGoldenFiles is true
      if (autoUpdateGoldenFiles) {
        await expectLater(
          find.byType(TempoApp),
          matchesGoldenFile('goldens/${variant.name}.png'),
        );
      }

      // Accessibility guidelines check
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }
}
