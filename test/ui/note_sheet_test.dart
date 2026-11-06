import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/ui/note_sheet.dart';
import 'package:tempo/ui/theme/tempo_theme.dart';

void main() {
  const contact = Tag(
    id: 'c',
    name: 'Contact',
    isContact: true,
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  /// Opens the sheet; the returned function reads what it handed back.
  Future<NoteSheetResult? Function()> openSheet(
    WidgetTester tester, {
    String initialComment = '',
    String suggestedReading = '',
    String? Function(String? firstPerson)? suggestReading,
  }) async {
    NoteSheetResult? result;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        // InkRipple needs no shader, which the test backend cannot load.
        theme: buildTempoTheme().copyWith(
          splashFactory: InkRipple.splashFactory,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showNoteSheet(
                context,
                activityName: 'Reading',
                activityColor: Colors.blue,
                subtitle: '08:00–09:00 · 1h',
                tags: const [contact],
                people: const ['Sam', 'Lee'],
                initialComment: initialComment,
                suggestedReading: suggestedReading,
                suggestReading: suggestReading,
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () {
      expect(closed, isTrue);
      return result;
    };
  }

  testWidgets('choosing People writes w/ and attaches Contact', (tester) async {
    final result = await openSheet(tester, initialComment: 'John 1');

    await tester.tap(find.text('Sam'));
    await tester.pump();
    await tester.tap(find.text('Lee'));
    await tester.pump();
    expect(find.text('John 1 w/ Sam, Lee'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final note = result();
    expect(note!.comment, 'John 1 w/ Sam, Lee');
    expect(note.tagIds, ['c']);
  });

  testWidgets('removing the last Person keeps Contact', (tester) async {
    final result = await openSheet(tester, initialComment: 'Tea w/ Sam');

    await tester.tap(find.text('Lee'));
    await tester.pump();
    await tester.tap(find.text('Sam'));
    await tester.pump();
    await tester.tap(find.text('Lee'));
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final note = result();
    expect(note!.comment, 'Tea');
    expect(note.tagIds, ['c']);
  });

  testWidgets('a new first Person refreshes an untouched reading', (
    tester,
  ) async {
    const readings = {null: 'Psalm 3', 'Sam': 'John 4', 'Lee': 'Rom 2'};
    final result = await openSheet(
      tester,
      suggestedReading: 'Psalm 3',
      suggestReading: (first) => readings[first],
    );
    expect(find.text('Psalm 3'), findsOneWidget);

    await tester.tap(find.text('Sam'));
    await tester.pump();
    expect(find.text('John 4 w/ Sam'), findsOneWidget);

    // Sam stays first, so the reading stays.
    await tester.tap(find.text('Lee'));
    await tester.pump();
    expect(find.text('John 4 w/ Sam, Lee'), findsOneWidget);

    await tester.tap(find.text('Sam').first);
    await tester.pump();
    expect(find.text('Rom 2 w/ Lee'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Luke 1 w/ Lee');
    await tester.tap(find.text('Sam').first);
    await tester.pump();
    await tester.tap(find.text('Lee').first);
    await tester.pump();
    expect(find.text('Luke 1 w/ Sam'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result()!.comment, 'Luke 1 w/ Sam');
  });

  testWidgets('a saved reading is never refreshed', (tester) async {
    final result = await openSheet(
      tester,
      initialComment: 'John 9',
      suggestReading: (first) => first == null ? 'John 9' : 'Rom 2',
    );

    await tester.tap(find.text('Sam'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result()!.comment, 'John 9 w/ Sam');
  });

  testWidgets('Skip returns nothing', (tester) async {
    final result = await openSheet(tester);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(result(), isNull);
  });
}
