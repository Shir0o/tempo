import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/core/sync/intent_queue.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/data/models/sync_change.dart';
import 'package:tempo/ui/dashboard_view.dart';
import 'package:tempo/ui/history_view.dart';

/// Stands in for [RemoteRecordCommands]: records every proposal instead of
/// writing a Record, which is what a Mac replica must do.
class _RecordingCommands implements RecordCommands {
  final List<String> calls = [];

  @override
  Future<Record?> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) async {
    calls.add('label:$activityId');
    return null;
  }

  @override
  Future<Record?> split() async {
    calls.add('split');
    return null;
  }

  @override
  Future<Record?> continueLast() async {
    calls.add('continueLast');
    return null;
  }

  @override
  Future<Record?> relabel(String recordId, String? activityId) async {
    calls.add('relabel:$recordId:$activityId');
    return null;
  }

  @override
  Future<Record?> annotate(
    String recordId, {
    required String comment,
    required List<String> tagIds,
  }) async {
    calls.add('annotate:$recordId');
    return null;
  }

  @override
  Future<Record?> adjustEdges(
    String recordId, {
    int? startEpochMs,
    int? endEpochMs,
  }) async {
    calls.add('adjustEdges:$recordId');
    return null;
  }

  @override
  Future<Record?> clear(String recordId) async {
    calls.add('clear:$recordId');
    return null;
  }

  @override
  Future<bool> undo({String? recordId}) async {
    calls.add('undo:${recordId ?? '-'}');
    return true;
  }

  @override
  Future<Record?> merge(String leftRecordId, String rightRecordId) async {
    calls.add('merge:$leftRecordId:$rightRecordId');
    return null;
  }

  @override
  Future<Record?> splitRecord(String recordId, int atEpochMs) async {
    calls.add('splitRecord:$recordId');
    return null;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<(TempoDatabase, DayRecorder)> openStore() async {
    final db = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    await db.insertActivity(
      const Activity(
        id: 'act-code',
        name: 'Coding',
        colorHex: '#2196F3',
        isPinned: true,
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
    await db.insertActivity(
      const Activity(
        id: 'act-read',
        name: 'Reading',
        colorHex: '#4CAF50',
        isPinned: true,
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      ),
    );
    final dayRecorder = DayRecorder(database: db, autoSplitAtMidnight: false);
    await dayRecorder.initialize();
    return (db, dayRecorder);
  }

  testWidgets('the Dashboard labels through RecordCommands, not DayRecorder', (
    tester,
  ) async {
    final (db, dayRecorder) = await openStore();
    final commands = _RecordingCommands();

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(
          dayRecorder: dayRecorder,
          database: db,
          commands: commands,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('activity-block-act-code')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(commands.calls, contains('label:act-code'));
    // A replica proposes; it never writes a Record of its own.
    expect(await db.getRecords(), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('Last logged adds a note to the latest Record from Today', (
    tester,
  ) async {
    final (db, dayRecorder) = await openStore();
    await dayRecorder.label('act-code');

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardView(dayRecorder: dayRecorder, database: db),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LAST LOGGED'), findsOneWidget);
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'pharmacy run');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final records = await db.getRecords(trackedOnly: true);
    expect(records.single.comment, 'pharmacy run');
    expect(find.text('Edit note'), findsOneWidget);
    expect(find.textContaining('pharmacy run'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });

  testWidgets('a rejected intent renders its reason and can be placed at now', (
    tester,
  ) async {
    final (db, dayRecorder) = await openStore();
    // One Record on the Day, so its timeline section exists for the proposal.
    await dayRecorder.label('act-code');

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final zone = localTimezoneId();
    final queue = IntentQueue(db);
    await queue.enqueue(
      SyncIntent.label(
        intentId: 'intent-rejected',
        tappedAtEpochMs: nowMs,
        tappedAtZoneId: zone,
        expectedLapStartEpochMs:
            nowMs - const Duration(hours: 1).inMilliseconds,
        activityId: 'act-read',
      ),
    );
    await queue.markAnswered(
      'intent-rejected',
      IntentResult.rejected(IntentResult.reasonLapMoved),
    );
    await queue.enqueue(
      SyncIntent.label(
        intentId: 'intent-pending',
        tappedAtEpochMs: nowMs,
        tappedAtZoneId: zone,
        expectedLapStartEpochMs: nowMs,
        activityId: 'act-read',
      ),
    );

    final commands = _RecordingCommands();
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryView(
          database: db,
          dayRecorder: dayRecorder,
          commands: commands,
          intentQueue: queue,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Not placed · Reading'), findsOneWidget);
    expect(
      find.text('The Untracked span had already moved on the phone.'),
      findsOneWidget,
    );
    expect(find.textContaining('Pending · Reading'), findsOneWidget);

    await tester.tap(find.text('Place at now'));
    await tester.pumpAndSettle();

    // "Place at now" is a fresh proposal through the seam, with the Lap start
    // the replica shows now; it is not a rewrite of the rejected intent.
    expect(commands.calls, contains('label:act-read'));

    await tester.pumpWidget(const SizedBox.shrink());
    dayRecorder.dispose();
    await db.close();
  });
}
