import 'package:material_ui/material_ui.dart';
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

  testWidgets('a tag made in the edit sheet is staged and saved', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'a0',
        name: 'Errands',
        colorHex: '#FFB27A',
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

    // With no tags yet, the sheet still offers one.
    expect(find.text('TAGS'), findsOneWidget);
    await tester.tap(find.text('+ New tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Travel');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final tag = (await db.getAllTags()).single;
    expect(tag.name, 'Travel');
    expect(find.text('Travel'), findsOneWidget);
    // Staged, not yet on the Record.
    expect((await db.getRecords()).single.tagIds, isEmpty);

    // The sheet scrolls; Save sits below the 600px test viewport.
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await db.getRecords()).single.tagIds, [tag.id]);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
