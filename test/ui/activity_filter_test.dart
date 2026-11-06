import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/speech/speech_input.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/dashboard_view.dart';

class FakeSpeech implements SpeechInput {
  final String transcript;
  FakeSpeech(this.transcript);

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> listen() async => transcript;
}

Activity activity(String id, String name, {int sortOrder = 0}) => Activity(
  id: id,
  name: name,
  sortOrder: sortOrder,
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

Future<TempoDatabase> seededDatabase() async {
  final db = await TempoDatabase.openInMemory(
    factory: databaseFactoryFfiNoIsolate,
  );
  await db.insertActivity(activity('a1', 'Cleaning'));
  await db.insertActivity(activity('a2', 'Laundry', sortOrder: 1));
  return db;
}

Future<void> openFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('activity-filter-button')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('typing filters and pressing a row labels exactly once', (
    tester,
  ) async {
    final db = await seededDatabase();
    final recorder = DayRecorder(database: db);
    await recorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(
          dayRecorder: recorder,
          database: db,
          showActivityFilter: true,
        ),
      ),
    );
    await tester.pump();

    await openFilter(tester);
    expect(find.text('Find an Activity'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('activity-filter-field')),
      'clea',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('activity-result-a1')), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-result-a2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('activity-result-a1')));
    await tester.pumpAndSettle();

    expect(find.text('Find an Activity'), findsNothing);
    final records = await db.getRecords();
    expect(records, hasLength(1));
    expect(records.single.activityId, 'a1');

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });

  testWidgets('the clear control empties the query and keeps the sheet open', (
    tester,
  ) async {
    final db = await seededDatabase();
    final recorder = DayRecorder(database: db);
    await recorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(
          dayRecorder: recorder,
          database: db,
          showActivityFilter: true,
        ),
      ),
    );
    await tester.pump();
    await openFilter(tester);

    await tester.enterText(
      find.byKey(const ValueKey('activity-filter-field')),
      'clea',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('activity-filter-clear')));
    await tester.pump();

    expect(find.text('Find an Activity'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-result-a1')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });

  testWidgets('the magnifier is absent when the capability is off', (
    tester,
  ) async {
    final db = await seededDatabase();
    final recorder = DayRecorder(database: db);
    await recorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: recorder, database: db),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('activity-filter-button')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });

  testWidgets('a miss offers Clear and Manage Activities', (tester) async {
    final db = await seededDatabase();
    final recorder = DayRecorder(database: db);
    await recorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(
          dayRecorder: recorder,
          database: db,
          showActivityFilter: true,
        ),
      ),
    );
    await tester.pump();
    await openFilter(tester);

    await tester.enterText(
      find.byKey(const ValueKey('activity-filter-field')),
      'zzzz',
    );
    await tester.pump();

    expect(
      find.textContaining('No unarchived Activity matches'),
      findsOneWidget,
    );
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Manage Activities'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });

  testWidgets('a transcript fills the field without labeling', (tester) async {
    final db = await seededDatabase();
    final recorder = DayRecorder(database: db);
    await recorder.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(
          dayRecorder: recorder,
          database: db,
          showActivityFilter: true,
          speechInput: FakeSpeech('Laundry'),
        ),
      ),
    );
    await tester.pump();
    await openFilter(tester);

    await tester.tap(find.byKey(const ValueKey('activity-filter-mic')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('activity-result-a2')), findsOneWidget);
    expect(await db.getRecords(), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
