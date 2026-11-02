import 'package:flutter/material.dart';
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
}
