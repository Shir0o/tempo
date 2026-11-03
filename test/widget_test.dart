import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/activity.dart';
import 'package:tempo/ui/tempo_app.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('TempoApp smoke test displays dashboard shell', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'act-test-1',
        name: 'Coding',
        colorHex: '#2196F3',
        iconName: 'code',
        isPinned: true,
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );

    final dayRecorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await dayRecorder.initialize();

    await tester.pumpWidget(TempoApp(dayRecorder: dayRecorder, database: db));

    // Initial frame + data load
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify the Color Blocks dashboard and the bottom navigation tabs
    expect(find.text('What was it?'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Totals'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // Verify the open Lap and the pinned activity are rendered
    expect(find.text('Untracked'), findsOneWidget);
    expect(find.text('Coding'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
