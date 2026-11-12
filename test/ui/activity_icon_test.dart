import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/activity_icon.dart';
import 'package:tempo/ui/activity_manager_view.dart';
import 'package:tempo/ui/activity_result_row.dart';
import 'package:tempo/ui/history/history_widgets.dart';
import 'package:tempo/ui/history_view.dart';

Activity _activity(String id, String name, {String iconName = 'schedule'}) =>
    Activity(
      id: id,
      name: name,
      colorHex: '#9AA5C8',
      iconName: iconName,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('ActivityIcon', () {
    testWidgets('draws the emoji on the swatch and as a glyph', (tester) async {
      final reading = _activity('a', 'Reading', iconName: '📖');
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [ActivityIcon(reading), ActivityIcon.glyph(reading)],
          ),
        ),
      );
      expect(find.text('📖'), findsNWidgets(2));
    });

    testWidgets('treats a Material icon name as no icon', (tester) async {
      final legacy = _activity('a', 'Reading', iconName: 'book');
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [ActivityIcon(legacy), ActivityIcon.glyph(legacy)],
          ),
        ),
      );
      expect(find.text('book'), findsNothing);
      expect(find.byType(Icon), findsNothing);
      expect(ActivityIcon.has(legacy), isFalse);
    });

    testWidgets('the filter sheet row shows the emoji', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: ActivityResultRow(
              activity: _activity('a', 'Coffee', iconName: '☕'),
              durationMs: 0,
              onTap: () {},
            ),
          ),
        ),
      );
      expect(find.text('☕'), findsOneWidget);
    });
  });

  group('activity editor', () {
    late TempoDatabase db;

    setUp(() async {
      db = await TempoDatabase.openInMemory(
        factory: databaseFactoryFfiNoIsolate,
      );
    });

    tearDown(() async => db.close());

    Future<void> openNew(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ActivityManagerView(database: db)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ New').first);
      await tester.pumpAndSettle();
    }

    testWidgets('guesses an emoji from the name, steering off worn ones', (
      tester,
    ) async {
      await db.insertActivity(_activity('sleep', 'Sleep', iconName: '😴'));
      await openNew(tester);

      await tester.enterText(find.byType(TextField), 'Naps');
      await tester.pumpAndSettle();
      expect(
        find.text('Guessed from the name. Tap another to change it.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = (await db.getAllActivities()).firstWhere(
        (a) => a.name == 'Naps',
      );
      expect(saved.iconName, '💤');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('does not add a second activity with the same name', (
      tester,
    ) async {
      await db.insertActivity(_activity('r', 'Reading'));
      await openNew(tester);

      await tester.enterText(find.byType(TextField), 'reading ');
      await tester.pumpAndSettle();
      expect(
        find.text('There is already an activity called Reading.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await db.getAllActivities(), hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('the record edit sheet shows the live duration', (tester) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(_activity('a', 'Errands', iconName: '🧾'));
    final recorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await recorder.initialize();
    await recorder.label('a');

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryView(database: db, dayRecorder: recorder),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Errands').first);
    await tester.pumpAndSettle();

    final readout = find.byType(DurationReadout);
    expect(readout, findsOneWidget);

    await tester.tap(find.text('−').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: readout, matching: find.text('5m')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: readout, matching: find.text('+5m')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
