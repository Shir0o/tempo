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

  testWidgets('a Record block on History shows its tags as chips', (
    tester,
  ) async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'a0',
        name: 'Errands',
        colorHex: '#FF8FB8',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
    for (final (id, name) in [('t1', 'Groceries'), ('t2', 'Market')]) {
      await db.insertTag(
        Tag(id: id, name: name, createdAtEpochMs: 0, updatedAtEpochMs: 0),
      );
    }
    final recorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await recorder.initialize();
    final record = await recorder.label('a0');
    await recorder.annotate(record.id, comment: '', tagIds: ['t1', 't2']);

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryView(database: db, dayRecorder: recorder),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Market'), findsOneWidget);
    // The block's screen-reader label names its tags.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            (w.properties.label ?? '').startsWith('Errands, ') &&
            w.properties.label!.endsWith(', tags Groceries, Market. Edit'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    await db.close();
  });
}
