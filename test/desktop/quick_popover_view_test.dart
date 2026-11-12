import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/desktop/ui/quick_popover_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<(TempoDatabase, DayRecorder)> setUpRecorder() async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'act-errands',
        name: 'Errands',
        colorHex: '#EF5350',
        isPinned: true,
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );

    final dayRecorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await dayRecorder.initialize();
    return (db, dayRecorder);
  }

  Future<void> pumpPopover(
    WidgetTester tester,
    TempoDatabase db,
    DayRecorder dayRecorder,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickPopoverView(
            dayRecorder: dayRecorder,
            database: db,
            enableTicker: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('number keys label the Lap and show the undo bar', (
    tester,
  ) async {
    final (db, dayRecorder) = await setUpRecorder();
    final lapStart = dayRecorder.lap!.startedAtEpochMs;

    await pumpPopover(tester, db, dayRecorder);
    expect(find.textContaining('Untracked since'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();

    final records = await db.getRecords();
    expect(records, hasLength(1));
    expect(records.single.activityId, equals('act-errands'));
    expect(records.single.startedAtEpochMs, equals(lapStart));
    expect(find.textContaining('Undo · '), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('Split closes the Lap as an Untracked Record and can be undone', (
    tester,
  ) async {
    final (db, dayRecorder) = await setUpRecorder();

    await pumpPopover(tester, db, dayRecorder);

    await tester.tap(find.text('Split'));
    await tester.pumpAndSettle();

    var records = await db.getRecords();
    expect(records, hasLength(1));
    expect(records.single.isUntracked, isTrue);
    expect(find.textContaining('Undo · '), findsOneWidget);

    await tester.tap(find.textContaining('Undo · '));
    await tester.pumpAndSettle();

    records = await db.getRecords();
    expect(records, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
