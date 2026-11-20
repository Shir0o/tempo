import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/suggestion_feedback.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';

/// Long-press on a WITH NOTE suggestion offers the same feedback as on an
/// Activity suggestion.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<(TempoDatabase, DayRecorder)> open(WidgetTester tester) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'act-out',
        name: 'Outdoors',
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
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return (db, dayRecorder);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Not useful on a note hides it and is kept with its People', (
    WidgetTester tester,
  ) async {
    final (db, dayRecorder) = await open(tester);

    final chip = find.byKey(const ValueKey('combo-chip-0'));
    expect(chip, findsOneWidget);
    await tester.longPress(chip);
    await tester.pumpAndSettle();
    expect(find.text('Edit the note first'), findsOneWidget);
    expect(find.text('Good suggestion'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('suggestion-action-notUseful')));
    await settle(tester);

    expect(chip, findsNothing);
    final stored = (await SuggestionFeedbackStore.load(db)).single;
    expect(stored.activityId, 'act-out');
    expect(stored.vote, SuggestionVote.notUseful);
    expect(stored.people, ['Britney']);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('Good suggestion on a note is kept with its People', (
    WidgetTester tester,
  ) async {
    final (db, dayRecorder) = await open(tester);

    await tester.longPress(find.byKey(const ValueKey('combo-chip-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('suggestion-action-good')));
    await settle(tester);

    final stored = (await SuggestionFeedbackStore.load(db)).single;
    expect(stored.vote, SuggestionVote.good);
    expect(stored.people, ['Britney']);
    expect(find.textContaining('This note will come up more'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('Edit the note first logs it from the suggestion', (
    WidgetTester tester,
  ) async {
    final (db, dayRecorder) = await open(tester);

    await tester.longPress(find.byKey(const ValueKey('combo-chip-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('suggestion-action-note')));
    await settle(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log Outdoors'));
    await settle(tester);

    // Remembered as suggested, so what was changed in the note counts.
    final stored = (await SuggestionFeedbackStore.load(db)).last;
    expect(stored.vote, SuggestionVote.logged);
    expect(stored.people, ['Britney']);
    expect(stored.comment, 'w/ Britney');
    expect(stored.recordId, isNotNull);
    expect(find.text('Good suggestion?'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
