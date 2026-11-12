import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';

/// Captures the design-D dashboard as `screenshots/color_blocks_dashboard.png`.
///
/// Run deliberately, not in CI:
///   TEMPO_SCREENSHOT=1 flutter test test/ui/color_blocks_dashboard_screenshot_test.dart --update-goldens
///
/// It is skipped in normal runs because golden images depend on the host's
/// text rasterisation, which would make CI flaky on a different platform.
void main() {
  final capture = Platform.environment['TEMPO_SCREENSHOT'] == '1';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final loader = FontLoader('SpaceGrotesk')
      ..addFont(
        rootBundle.load('assets/fonts/SpaceGrotesk-VariableFont_wght.ttf'),
      );
    await loader.load();
  });

  testWidgets('Color Blocks dashboard screenshot', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    for (final activity in _activities) {
      await db.insertActivity(activity);
    }

    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    int at(int hour, int minute) => dayStart
        .add(Duration(hours: hour, minutes: minute))
        .millisecondsSinceEpoch;

    // A contiguous morning so the strip reads as one Day.
    await _insert(
      db,
      'Sleep',
      _activities[0],
      at(0, 0),
      at(7, 5),
      zone: 'Asia/Tokyo',
      endZone: 'Asia/Tokyo',
    );
    await _insert(db, 'Routine', _activities[1], at(7, 5), at(7, 40));
    await _insert(db, 'Meals', _activities[2], at(7, 40), at(8, 15));
    await _insert(
      db,
      'Transit',
      _activities[3],
      at(8, 15),
      at(8, 50),
      zone: 'Asia/Tokyo',
      endZone: 'America/Los_Angeles',
    );
    await _insert(db, 'Errands', _activities[4], at(8, 50), at(10, 6));

    final lapStart = at(10, 6);
    await db.setLap(
      Lap(startedAtEpochMs: lapStart, startedTimezoneId: localTimezoneId()),
    );

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: DashboardView(
          dayRecorder: dayRecorder,
          database: db,
          showActivityFilter: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(DashboardView),
      matchesGoldenFile('../../screenshots/color_blocks_dashboard.png'),
    );

    // The same screen just after a block was tapped, with the undo bar up.
    await tester.tap(find.byKey(const ValueKey('activity-block-act-errands')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(
      find.byType(DashboardView),
      matchesGoldenFile('../../screenshots/color_blocks_dashboard_undo.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  }, skip: !capture);
}

Future<void> _insert(
  TempoDatabase db,
  String name,
  Activity activity,
  int start,
  int end, {
  String? zone,
  String? endZone,
}) async {
  await db.insertRecord(
    Record(
      id: 'rec-${name.toLowerCase()}',
      activityId: activity.id,
      startedAtEpochMs: start,
      endedAtEpochMs: end,
      timezoneId: zone ?? localTimezoneId(),
      endTimezoneId: endZone ?? zone ?? localTimezoneId(),
      createdAtEpochMs: start,
      updatedAtEpochMs: start,
    ),
  );
}

const _activities = [
  Activity(
    id: 'act-sleep',
    name: 'Sleep',
    colorHex: '#5C6BC0',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-routine',
    name: 'Routine',
    colorHex: '#B0BEC5',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-meals',
    name: 'Meals',
    colorHex: '#FFB300',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-transit',
    name: 'Transit',
    colorHex: '#26A69A',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-errands',
    name: 'Errands',
    colorHex: '#EF5350',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-reading',
    name: 'Reading',
    colorHex: '#66BB6A',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
  Activity(
    id: 'act-exercise',
    name: 'Exercise',
    colorHex: '#AB47BC',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  ),
];
