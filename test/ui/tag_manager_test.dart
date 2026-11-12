import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/tag_manager_view.dart';
import 'package:tempo/ui/theme/tempo_theme.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late TempoDatabase db;

  setUp(() async {
    db = await TempoDatabase.openInMemory(factory: databaseFactoryFfiNoIsolate);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> openManager(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTempoTheme().copyWith(
          splashFactory: InkRipple.splashFactory,
        ),
        home: TagManagerView(database: db),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows tags and marks the Contact one', (tester) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.insertTag(
      Tag(
        id: 'tag-people',
        name: 'People',
        isContact: true,
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      ),
    );
    await db.insertTag(
      Tag(
        id: 'tag-travel',
        name: 'Travel',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      ),
    );

    await openManager(tester);

    expect(find.text('People'), findsOneWidget);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Contact'), findsOneWidget);
  });

  testWidgets('the editor starts with Contact off for a new tag', (
    tester,
  ) async {
    await openManager(tester);
    expect(find.text('No tags yet.'), findsOneWidget);

    await tester.tap(find.text('+ New'));
    await tester.pumpAndSettle();

    expect(find.text('New tag'), findsOneWidget);
    expect(find.text('Contact tag'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
