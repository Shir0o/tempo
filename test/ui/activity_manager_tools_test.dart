import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/activity_manager_view.dart';

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

  testWidgets('archive can move records into another activity first', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(_activity('old', 'Old', iconName: '\u{1F4D6}'));
    await db.insertActivity(_activity('new', 'New', iconName: '\u{1F4DA}'));
    await db.insertRecord(
      Record(
        id: 'rec-1',
        activityId: 'old',
        startedAtEpochMs: 1000,
        endedAtEpochMs: 2000,
        comment: 'A note',
        timezoneId: 'UTC',
        createdAtEpochMs: 1000,
        updatedAtEpochMs: 1000,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: ActivityManagerView(database: db)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Archive Old?'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('New')),
    );
    await tester.pumpAndSettle();

    final old = await db.getActivityById('old');
    expect(old!.isArchived, isTrue);
    expect(await db.getRecords(activityId: 'old'), isEmpty);
    final moved = await db.getRecords(activityId: 'new');
    expect(moved, hasLength(1));
    expect(moved.single.id, 'rec-1');
    expect(moved.single.comment, 'A note');

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('emoji tools are visible and de-duplicate shared icons', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(_activity('a', 'Sleep', iconName: '\u{1F634}'));
    await db.insertActivity(_activity('b', 'Nap', iconName: '\u{1F634}'));
    await db.insertActivity(_activity('c', 'Coffee', iconName: '\u{2615}'));

    await tester.pumpWidget(
      MaterialApp(home: ActivityManagerView(database: db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto-assign emoji'), findsOneWidget);
    expect(find.text('De-duplicate emoji'), findsOneWidget);
    expect(find.text('1 to change'), findsOneWidget);

    await tester.tap(find.text('De-duplicate emoji'));
    await tester.pumpAndSettle();

    final activities = await db.getAllActivities();
    final icons = activities.map((activity) => activity.iconName).toList();
    expect(icons.toSet(), hasLength(icons.length));
    expect(find.text('All unique'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });
}
