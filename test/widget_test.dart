import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/timer_state_machine.dart';
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

    final sm = TimerStateMachine(database: db);
    await sm.initialize();

    await tester.pumpWidget(TempoApp(timerStateMachine: sm, database: db));

    // Initial frame + data load
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify Tempo brand title and bottom navigation tabs
    expect(find.text('Tempo'), findsOneWidget);
    expect(find.text('Tracking'), findsOneWidget);
    expect(find.text('Statistics'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // Verify pinned activity 'Coding' is rendered
    expect(find.text('Coding'), findsOneWidget);

    sm.dispose();
    await db.close();
  });
}
