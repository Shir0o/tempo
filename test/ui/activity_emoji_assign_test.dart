import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/activity_manager_view.dart';

Activity _activity(String id, String name) => Activity(
  id: id,
  name: name,
  colorHex: '#9AA5C8',
  iconName: 'schedule',
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('one press assigns emoji, then sweeps what is left', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(_activity('act-reading', 'Ministry Reading'));
    await db.insertActivity(_activity('act-anna', 'Anna'));

    await tester.pumpWidget(
      MaterialApp(home: ActivityManagerView(database: db)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto-assign emoji'), findsOneWidget);
    expect(find.text('1 need an icon'), findsOneWidget);

    await tester.tap(find.text('Auto-assign emoji'));
    await tester.pumpAndSettle();

    final afterAssign = await db.getAllActivities(includeArchived: true);
    expect(afterAssign.firstWhere((a) => a.id == 'act-reading').iconName, '📖');
    expect(
      afterAssign.firstWhere((a) => a.id == 'act-anna').iconName,
      'schedule',
    );

    // The sweep lists only the unresolved Activity.
    expect(find.text('1 activity has no match yet.'), findsOneWidget);

    final sheet = find.byType(BottomSheet);
    await tester.tap(find.descendant(of: sheet, matching: find.text('Anna')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('🙏'));
    await tester.pumpAndSettle();

    final afterPick = await db.getAllActivities(includeArchived: true);
    expect(afterPick.firstWhere((a) => a.id == 'act-anna').iconName, '🙏');
    expect(find.byType(BottomSheet), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });
}
