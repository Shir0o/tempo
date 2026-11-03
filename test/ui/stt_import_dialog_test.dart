import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/import/stt_import_service.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/ui/stt_import_dialog.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('SttImportDialog', () {
    late TempoDatabase db;
    late SttImportService importService;

    setUp(() async {
      db = await TempoDatabase.openInMemory(
        factory: databaseFactoryFfiNoIsolate,
      );
      importService = SttImportService(
        database: db,
        nowUtcMs: () => 1741521600000, // 2025-03-09 12:00:00 UTC
        getTimezoneId: () => 'America/New_York',
      );
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets(
      'renders Stage 1 inspection card and Stage 2 scope selectors for .backup',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        const backupContent = '''app simple time tracker
category\t1\tWork\t3\t\t
category\t2\tPersonal\t7\t\t
typeCategory\t10\t1
typeCategory\t20\t2
recordType\t10\tCoding\tic_computer_24px\t3\t0\t\t\t\t\t\t0\t
recordType\t20\tReading\tic_book_24px\t7\t0\t\t\t\t\t\t0\t
''';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () {
                    SttImportDialog.show(
                      context,
                      fileContent: backupContent,
                      fileName: 'stt_backup_2026.backup',
                      database: db,
                      importService: importService,
                    );
                  },
                  child: const Text('Open Dialog'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();

        // Inspection Stage 1
        expect(find.text('Import Simple Time Tracker'), findsOneWidget);
        expect(find.text('stt_backup_2026.backup'), findsOneWidget);
        expect(find.text('Format: .backup'), findsOneWidget);
        expect(find.text('Categories'), findsOneWidget);
        expect(find.text('Activities'), findsOneWidget);
        expect(find.text('2'), findsNWidgets(2)); // 2 categories, 2 activities
        expect(
          find.text('Timestamps will be reconciled in America/New_York'),
          findsOneWidget,
        );

        // Stage 2
        expect(find.text('IMPORT SCOPE'), findsOneWidget);
        expect(
          find.text('Catalog Only (Categories & Activities)'),
          findsOneWidget,
        );
        expect(find.text('Full History + Catalog'), findsOneWidget);

        // Tap Proceed Import
        await tester.tap(find.text('Proceed Import'));
        await tester.pumpAndSettle();

        // Dialog closed
        expect(find.text('Import Simple Time Tracker'), findsNothing);

        // Verify categories and activities were created in database
        final categories = await db.getCategories();
        expect(categories, hasLength(2));
        expect(
          categories.map((c) => c.name),
          containsAll(['Work', 'Personal']),
        );

        final activities = await db.getAllActivities();
        expect(activities, hasLength(2));
        expect(
          activities.map((a) => a.name),
          containsAll(['Coding', 'Reading']),
        );
      },
    );

    testWidgets(
      'renders record count, date badge, and executes Full History import for CSV',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        const csvContent =
            '"activity name","time started","time ended","comment","categories","record tags","duration","duration minutes"\n'
            '"Deep Work","2025-01-10 09:00:00","2025-01-10 11:00:00","Refactor","Focus","work","02:00:00",120\n'
            '"Exercise","2025-01-10 11:30:00","2025-01-10 12:30:00","Gym","Health","cardio","01:00:00",60\n';

        SttImportResult? dialogResult;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    dialogResult = await SttImportDialog.show(
                      context,
                      fileContent: csvContent,
                      fileName: 'stt_records.csv',
                      database: db,
                      importService: importService,
                    );
                  },
                  child: const Text('Open Dialog'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Dialog'));
        await tester.pumpAndSettle();

        // Verification of Stage 1 elements
        expect(find.text('Format: .csv'), findsOneWidget);
        expect(find.text('Jan 2025 – Jan 2025'), findsOneWidget);
        expect(find.text('Records'), findsOneWidget);

        // Proceed import
        await tester.tap(find.text('Proceed Import'));
        await tester.pumpAndSettle();

        expect(dialogResult, isNotNull);
        expect(dialogResult!.categoriesImported, 2);
        expect(dialogResult!.activitiesImported, 2);
        expect(dialogResult!.recordsImported, 2);
        expect(dialogResult!.syntheticRecordsCreated, greaterThanOrEqualTo(1));
      },
    );
  });
}
