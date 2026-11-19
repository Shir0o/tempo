import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/activity_result_row.dart';
import 'package:tempo/ui/dashboard_view.dart';
import 'package:tempo/ui/history/history_widgets.dart';
import 'package:tempo/ui/history_view.dart';
import 'package:tempo/ui/stats_view.dart';
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
    name: 'light_390x844',
    logicalSize: Size(390, 844),
    textScale: 1.0,
    brightness: Brightness.light,
  ),
  AuditVariant(
    name: 'dark_390x844',
    logicalSize: Size(390, 844),
    textScale: 1.0,
    brightness: Brightness.dark,
  ),
  AuditVariant(
    name: 'small_font_1_6x_320x568',
    logicalSize: Size(320, 568),
    textScale: 1.6,
    brightness: Brightness.light,
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
      _applyVariant(tester, variant);

      // The accessibility guidelines need the semantics tree, disposed before
      // WidgetTester's end-of-test handle check runs.
      final semantics = tester.ensureSemantics();
      try {
        final app = await _pumpAuditApp(tester);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          app.recorder.dispose();
          await app.db.close();
        });

        // ------------------------------------------------------------- Today
        await _auditState(
          tester,
          variant,
          'today',
          expectVisible: find.text('Untracked'),
        );

        // ------------------------------------------------- Activity filter sheet
        await _tap(
          tester,
          find.byKey(const ValueKey('activity-filter-button')),
          scrollable: _todayScrollable,
        );
        await _auditState(
          tester,
          variant,
          'today_filter_sheet',
          expectVisible: find.text('Find an Activity'),
        );

        await tester.enterText(
          find.byKey(const ValueKey('activity-filter-field')),
          'Cod',
        );
        await _auditState(
          tester,
          variant,
          'today_filter_results',
          expectVisible: find.byType(ActivityResultRow),
        );
        await _closeTopRoute(tester, find.text('Find an Activity'));

        // ------------------------------------------------ Note sheet (long-press)
        final codingBlock = find.byKey(
          const ValueKey('activity-block-act-coding'),
        );
        await tester.scrollUntilVisible(
          codingBlock,
          160,
          scrollable: _todayScrollable,
        );
        await tester.longPress(codingBlock);
        await _auditState(
          tester,
          variant,
          'today_note_sheet',
          expectVisible: find.text('Log Coding'),
        );
        await _closeTopRoute(tester, find.text('Log Coding'));

        // ----------------------------------------------------------- History
        await _tap(tester, _navDestination('History'));
        await _auditState(
          tester,
          variant,
          'history',
          expectVisible: find.byType(HistoryDayCard),
        );

        await _tap(
          tester,
          find.byType(HistoryRecordBlock).first,
          scrollable: _historyScrollable,
        );
        await _auditState(
          tester,
          variant,
          'history_record_sheet',
          expectVisible: find.text('Only this Record changes'),
        );
        await _closeTopRoute(tester, find.text('Only this Record changes'));

        // ------------------------------------------------------------ Totals
        await _tap(tester, _navDestination('Totals'));
        await _auditState(
          tester,
          variant,
          'totals',
          expectVisible: _statsText('Totals'),
        );
        await _tap(tester, find.text('Week'));
        await _auditState(
          tester,
          variant,
          'totals_week',
          expectVisible: _statsText('Week'),
        );

        // ---------------------------------------------------------- Settings
        await _tap(tester, _navDestination('Settings'));
        await _auditState(
          tester,
          variant,
          'settings',
          expectVisible: find.text('YOUR DAY'),
        );

        await _tap(tester, find.text('Order on Today'));
        await _auditState(
          tester,
          variant,
          'settings_order_sheet',
          expectVisible: find.text('Manual order'),
        );
        await _tap(tester, find.widgetWithText(ListTile, 'A to Z'));

        await _tap(tester, find.text('Activities'));
        await _auditState(
          tester,
          variant,
          'settings_activities',
          expectVisible: find.text('Shown on Today in this order.'),
        );
      } finally {
        semantics.dispose();
      }
    });
  }
}

/// Applies a variant's viewport, text scale and platform brightness, and
/// restores the test view when the test ends.
void _applyVariant(WidgetTester tester, AuditVariant variant) {
  tester.view.physicalSize = variant.logicalSize;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.platformBrightnessTestValue = variant.brightness;
  tester.platformDispatcher.textScaleFactorTestValue = variant.textScale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

/// Pumps [TempoApp] over an in-memory store with a day of Records and an open
/// Lap, so every screen and sheet has data to lay out.
Future<({TempoDatabase db, DayRecorder recorder})> _pumpAuditApp(
  WidgetTester tester,
) async {
  final db = await TempoDatabase.openInMemory(
    factory: databaseFactoryFfiNoIsolate,
  );
  final recorder = DayRecorder(database: db, autoSplitAtMidnight: false);

  for (final activity in _testActivities) {
    await db.insertActivity(activity);
  }

  // Relative to now, so the fixture is contiguous and in the past at any hour.
  final hour = const Duration(hours: 1).inMilliseconds;
  final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
  final sleepStart = nowMs - 8 * hour;
  final sleepEnd = nowMs - 6 * hour;
  final routineStart = sleepEnd;
  final routineEnd = nowMs - 3 * hour;

  await db.insertRecord(
    Record(
      id: 'rec-sleep',
      activityId: 'act-sleep',
      startedAtEpochMs: sleepStart,
      endedAtEpochMs: sleepEnd,
      timezoneId: localTimezoneId(),
      endTimezoneId: localTimezoneId(),
      createdAtEpochMs: sleepStart,
      updatedAtEpochMs: sleepStart,
    ),
  );
  await db.insertRecord(
    Record(
      id: 'rec-routine',
      activityId: 'act-routine',
      startedAtEpochMs: routineStart,
      endedAtEpochMs: routineEnd,
      timezoneId: localTimezoneId(),
      endTimezoneId: localTimezoneId(),
      createdAtEpochMs: routineStart,
      updatedAtEpochMs: routineStart,
    ),
  );

  await db.setLap(
    Lap(startedAtEpochMs: routineEnd, startedTimezoneId: localTimezoneId()),
  );

  await recorder.initialize();

  await tester.pumpWidget(
    TempoApp(
      dayRecorder: recorder,
      database: db,
      commands: PhoneRecordCommands(dayRecorder: recorder),
      showActivityFilter: true,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  return (db: db, recorder: recorder);
}

/// Audits the state now on screen: every Flutter error (a RenderFlex overflow
/// arrives here through `tester.takeException()`), both accessibility
/// guidelines, and — only when `autoUpdateGoldenFiles` is set — a golden at
/// `test/goldens/<variant>_<screen>.png`.
Future<void> _auditState(
  WidgetTester tester,
  AuditVariant variant,
  String screen, {
  Finder? expectVisible,
}) async {
  await tester.pump();

  // Sheets that open after an async database read need a few frames.
  if (expectVisible != null) {
    for (var i = 0; i < 20 && expectVisible.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      expectVisible,
      findsWidgets,
      reason: 'The "$screen" state never opened for ${variant.name}.',
    );
  }

  // Let route and sheet transitions finish before measuring.
  await tester.pump(const Duration(milliseconds: 400));

  final exception = tester.takeException();
  expect(
    exception,
    isNull,
    reason:
        'RenderFlex overflow (or another Flutter error) in '
        '${variant.name}/$screen.',
  );

  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));

  if (autoUpdateGoldenFiles) {
    await expectLater(
      find.byType(TempoApp),
      matchesGoldenFile('goldens/${variant.name}_$screen.png'),
    );
  }
}

/// Taps [target], optionally scrolling [scrollable] until it is built.
Future<void> _tap(
  WidgetTester tester,
  Finder target, {
  Finder? scrollable,
}) async {
  if (scrollable != null) {
    await tester.scrollUntilVisible(target, 160, scrollable: scrollable);
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pops the modal route containing [anchor], then waits out its animation.
Future<void> _closeTopRoute(WidgetTester tester, Finder anchor) async {
  Navigator.of(tester.element(anchor)).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _navDestination(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Finder _statsText(String text) =>
    find.descendant(of: find.byType(StatsView), matching: find.text(text));

Finder get _todayScrollable => find
    .descendant(
      of: find.byType(DashboardView),
      matching: find.byType(Scrollable),
    )
    .first;

Finder get _historyScrollable => find
    .descendant(of: find.byType(HistoryView), matching: find.byType(Scrollable))
    .first;
