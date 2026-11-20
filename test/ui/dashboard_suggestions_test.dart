import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/suggestion_feedback.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('pins sit in their own row and learned picks say why', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    Future<void> activity(String id, String name, {bool pinned = false}) =>
        db.insertActivity(
          Activity(
            id: id,
            name: name,
            isPinned: pinned,
            createdAtEpochMs: 0,
            updatedAtEpochMs: 0,
          ),
        );
    await activity('breakfast', 'Breakfast');
    await activity('commute', 'Commute');
    await activity('pin', 'Prayer', pinned: true);

    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600000;
    // Breakfast is followed by Commute, twice.
    var n = 0;
    Future<void> record(String activityId, int startMs) => db.insertRecord(
      Record(
        id: 'r${n++}',
        activityId: activityId,
        startedAtEpochMs: startMs,
        endedAtEpochMs: startMs + hour ~/ 2,
        timezoneId: 'America/Los_Angeles',
        createdAtEpochMs: startMs,
        updatedAtEpochMs: startMs,
      ),
    );
    await record('breakfast', now - 5 * hour);
    await record('commute', now - 4 * hour);
    await record('pin', now - 3 * hour);
    await record('breakfast', now - 2 * hour);
    await record('commute', now - 3 * hour ~/ 2);
    await record('breakfast', now - hour);

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('SUGGESTED'), findsOneWidget);
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.byKey(const ValueKey('pinned-chip-pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('suggested-chip-pin')), findsNothing);
    expect(
      find.byKey(const ValueKey('suggested-chip-commute')),
      findsOneWidget,
    );
    expect(find.text('After Breakfast'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('pinned-chip-pin')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pinned-chip-pin')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Logged Prayer'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('long-press rates a suggestion and a tap counts for it', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    for (final (id, name) in [
      ('breakfast', 'Breakfast'),
      ('commute', 'Commute'),
      ('walk', 'Walk'),
    ]) {
      await db.insertActivity(
        Activity(id: id, name: name, createdAtEpochMs: 0, updatedAtEpochMs: 0),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600000;
    var n = 0;
    Future<void> record(String activityId, int startMs) => db.insertRecord(
      Record(
        id: 'r${n++}',
        activityId: activityId,
        startedAtEpochMs: startMs,
        endedAtEpochMs: startMs + hour ~/ 2,
        timezoneId: 'America/Los_Angeles',
        createdAtEpochMs: startMs,
        updatedAtEpochMs: startMs,
      ),
    );
    await record('breakfast', now - 5 * hour);
    await record('commute', now - 4 * hour);
    await record('walk', now - 3 * hour);
    await record('breakfast', now - 2 * hour);

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final commute = find.byKey(const ValueKey('suggested-chip-commute'));
    expect(commute, findsOneWidget);

    await tester.ensureVisible(commute);
    await tester.longPress(commute);
    await tester.pumpAndSettle();
    expect(find.text('Good suggestion'), findsOneWidget);
    expect(find.text('Add a note first'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('suggestion-action-notUseful')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // Hidden for this Lap, and remembered with what came before it.
    expect(commute, findsNothing);
    final stored = await SuggestionFeedbackStore.load(db);
    expect(stored.single.activityId, 'commute');
    expect(stored.single.vote, SuggestionVote.notUseful);
    expect(stored.single.precedingActivityId, 'breakfast');

    final walk = find.byKey(const ValueKey('suggested-chip-walk'));
    expect(walk, findsOneWidget);
    await tester.ensureVisible(walk);
    await tester.tap(walk);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Logged Walk'), findsOneWidget);
    final afterTap = await SuggestionFeedbackStore.load(db);
    expect(afterTap.last.activityId, 'walk');
    expect(afterTap.last.vote, SuggestionVote.accepted);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('only Untracked time shows no learned picks', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      Activity(
        id: 'walk',
        name: 'Walk',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600000;
    await db.insertRecord(
      Record(
        id: 'gap',
        activityId: null,
        startedAtEpochMs: now - 2 * hour,
        endedAtEpochMs: now - hour,
        timezoneId: 'America/Los_Angeles',
        createdAtEpochMs: now - 2 * hour,
        updatedAtEpochMs: now - 2 * hour,
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

    expect(tester.takeException(), isNull);
    expect(find.text('SUGGESTED'), findsNothing);
    expect(find.byKey(const ValueKey('suggested-chip-walk')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('a label from elsewhere refreshes the last Activity and picks', (
    WidgetTester tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    for (final (id, name) in [
      ('bible', 'Bible'),
      ('grooming', 'Grooming'),
      ('reading', 'Reading'),
    ]) {
      await db.insertActivity(
        Activity(id: id, name: name, createdAtEpochMs: 0, updatedAtEpochMs: 0),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600000;
    var n = 0;
    Future<void> record(String activityId, int startMs) => db.insertRecord(
      Record(
        id: 'r${n++}',
        activityId: activityId,
        startedAtEpochMs: startMs,
        endedAtEpochMs: startMs + hour ~/ 2,
        timezoneId: 'America/Los_Angeles',
        createdAtEpochMs: startMs,
        updatedAtEpochMs: startMs,
      ),
    );
    // Bible is followed by Grooming, twice, and Reading came last.
    await record('bible', now - 6 * hour);
    await record('grooming', now - 11 * hour ~/ 2);
    await record('bible', now - 4 * hour);
    await record('grooming', now - 7 * hour ~/ 2);
    await record('reading', now - hour);

    final dayRecorder = DayRecorder(database: db);
    await dayRecorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Still Reading'), findsOneWidget);
    expect(find.text('After Bible'), findsNothing);

    // The watch labels the open Lap through the same DayRecorder.
    await dayRecorder.label('bible');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Still Bible'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('suggested-chip-grooming')),
      findsOneWidget,
    );
    expect(find.text('After Bible'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
