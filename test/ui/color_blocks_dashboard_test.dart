import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('tapping an Activity block labels the Lap and shows Undo', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      Activity(
        id: 'act-errands',
        name: 'Errands',
        colorHex: '#EF5350',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();
    final lapStart = dayRecorder.lap!.startedAtEpochMs;

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Untracked'), findsOneWidget);
    expect(find.text('Errands'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('activity-block-act-errands')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Logged Errands'), findsOneWidget);
    expect(find.textContaining('Undo · '), findsOneWidget);

    final records = await db.getRecords();
    expect(records, hasLength(1));
    expect(records.single.activityId, 'act-errands');
    expect(records.single.startedAtEpochMs, lapStart);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets(
    'suggested activities row renders when suggestions exist and labels on tap',
    (WidgetTester tester) async {
      final db = await TempoDatabase.openInMemory(
        factory: databaseFactoryFfiNoIsolate,
      );
      await db.insertActivity(
        Activity(
          id: 'act-1',
          name: 'Work',
          colorHex: '#2196F3',
          iconName: 'work',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      await db.insertActivity(
        Activity(
          id: 'act-2',
          name: 'Coffee',
          colorHex: '#795548',
          iconName: '☕',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      // Seed history: Work -> Coffee
      await db.insertRecord(
        Record(
          id: 'rec-1',
          activityId: 'act-1',
          startedAtEpochMs: now - 7200000,
          endedAtEpochMs: now - 3600000,
          timezoneId: 'America/Los_Angeles',
          createdAtEpochMs: now - 3600000,
          updatedAtEpochMs: now - 3600000,
        ),
      );
      await db.insertRecord(
        Record(
          id: 'rec-2',
          activityId: 'act-2',
          startedAtEpochMs: now - 3600000,
          endedAtEpochMs: now - 1800000,
          timezoneId: 'America/Los_Angeles',
          createdAtEpochMs: now - 1800000,
          updatedAtEpochMs: now - 1800000,
        ),
      );
      // Last closed record was Work, so Coffee is predicted next!
      await db.insertRecord(
        Record(
          id: 'rec-3',
          activityId: 'act-1',
          startedAtEpochMs: now - 1800000,
          endedAtEpochMs: now - 60000,
          timezoneId: 'America/Los_Angeles',
          createdAtEpochMs: now - 60000,
          updatedAtEpochMs: now - 60000,
        ),
      );

      final dayRecorder = DayRecorder(database: db);
      await dayRecorder.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardView(dayRecorder: dayRecorder, database: db),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Suggested chip should exist
      final suggestedCoffee = find.byKey(
        const ValueKey('suggested-chip-act-2'),
      );
      expect(suggestedCoffee, findsOneWidget);
      expect(find.text('☕'), findsWidgets);

      // Tapping the suggested chip labels the lap
      await tester.tap(suggestedCoffee);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Logged Coffee'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      dayRecorder.dispose();
      await db.close();
    },
  );

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('WITH NOTE chip text stays inside the chip at ${scale}x text', (
      WidgetTester tester,
    ) async {
      final db = await TempoDatabase.openInMemory(
        factory: databaseFactoryFfiNoIsolate,
      );
      await db.insertActivity(
        Activity(
          id: 'act-out',
          name: 'Outdoors',
          colorHex: '#8E99C9',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insertRecord(
        Record(
          id: 'rec-out',
          activityId: 'act-out',
          startedAtEpochMs: now - 3600000,
          endedAtEpochMs: now - 60000,
          comment: 'w/ Britney',
          timezoneId: 'America/Los_Angeles',
          createdAtEpochMs: now - 60000,
          updatedAtEpochMs: now - 60000,
        ),
      );

      final dayRecorder = DayRecorder(database: db);
      await dayRecorder.initialize();

      tester.view.physicalSize = const Size(2400, 6000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: DashboardView(dayRecorder: dayRecorder, database: db),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final chip = find.byKey(const ValueKey('combo-chip-0'));
      expect(chip, findsOneWidget);
      final chipRect = tester.getRect(chip);
      for (final text in ['Outdoors', 'w/ Britney']) {
        final textRect = tester.getRect(
          find.descendant(of: chip, matching: find.text(text)),
        );
        expect(
          textRect.bottom,
          lessThanOrEqualTo(chipRect.bottom),
          reason: '"$text" spills below the chip',
        );
        expect(textRect.top, greaterThanOrEqualTo(chipRect.top));
      }

      await tester.pumpWidget(const SizedBox.shrink());
      dayRecorder.dispose();
      await db.close();
    });
  }
}
