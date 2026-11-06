import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/history_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  const names = [
    'Errands', 'Sleep', 'Commute', 'Cooking', 'Reading', 'Walk', //
    'Laundry', 'Piano', 'Garden', 'Groceries', 'Shower', 'Nap',
  ];

  testWidgets('Activity hides behind All; the picker searches and relabels', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    for (final (i, name) in names.indexed) {
      await db.insertActivity(
        Activity(
          id: 'a$i',
          name: name,
          colorHex: '#FFB27A',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
    }
    final recorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await recorder.initialize();
    await recorder.label('a0');

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryView(database: db, dayRecorder: recorder),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Errands').first);
    await tester.pumpAndSettle();

    // The sheet no longer lists every Activity.
    expect(find.text('All ${names.length}'), findsOneWidget);
    expect(find.text('Garden'), findsNothing);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.text('Change Activity'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'gar');
    await tester.pumpAndSettle();
    expect(find.text('Piano'), findsNothing);
    await tester.tap(find.text('Garden'));
    await tester.pumpAndSettle();

    // Back on the edit sheet with Garden staged, not yet saved.
    expect(find.text('Change Activity'), findsNothing);
    expect((await db.getRecords()).single.activityId, 'a0');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await db.getRecords()).single.activityId, 'a8');

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
