import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/activity.dart';
import 'package:tempo/ui/tempo_app.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('Totals shows a record labelled after the app started', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'act-coding',
        name: 'Coding',
        colorHex: '#2196F3',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );

    final dayRecorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await dayRecorder.initialize();

    await tester.pumpWidget(
      TempoApp(
        dayRecorder: dayRecorder,
        database: db,
        commands: PhoneRecordCommands(dayRecorder: dayRecorder),
      ),
    );
    // Initial frame + the Totals tab's first (empty) load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Label the open Lap after the Totals tab has already loaded.
    await dayRecorder.label('act-coding');
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Totals'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing recorded in this period.'), findsNothing);
    expect(find.text('Time per activity'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
