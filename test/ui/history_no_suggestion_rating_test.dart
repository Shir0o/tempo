import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/suggestion_feedback.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/history_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('a Record logged from a suggestion has no rating to give', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'a0',
        name: 'Errands',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
    final recorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await recorder.initialize();
    final record = await recorder.label('a0');
    await SuggestionFeedbackStore.add(
      db,
      SuggestionFeedback(
        activityId: 'a0',
        vote: SuggestionVote.logged,
        givenAtEpochMs: record.startedAtEpochMs,
        targetEpochMs: record.startedAtEpochMs,
        timezoneId: record.timezoneId,
        recordId: record.id,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryView(database: db, dayRecorder: recorder),
      ),
    );
    await tester.pumpAndSettle();

    // Only the bar right after logging asks; the edit sheet does not.
    await tester.tap(find.text('Errands').first);
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('SUGGESTED BY TEMPO'), findsNothing);
    expect(find.text('Good suggestion'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });

  testWidgets('a Record not logged from a suggestion has nothing to rate', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'a0',
        name: 'Errands',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
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
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('SUGGESTED BY TEMPO'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
