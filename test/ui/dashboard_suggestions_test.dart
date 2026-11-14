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
}
