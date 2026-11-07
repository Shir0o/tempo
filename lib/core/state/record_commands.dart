import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../../data/models/sync_change.dart';
import '../sync/intent_queue.dart';
import '../time/timezone_id.dart';
import 'day_recorder.dart';

/// The one interface every UI write path uses.
///
/// The phone writes through [DayRecorder]; the Mac turns each call into an
/// intent for the phone. A command returns the Record the phone wrote, or null
/// when the call only queued a proposal on a replica.
abstract class RecordCommands {
  Future<Record?> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  });

  Future<Record?> split();

  /// Extends the most recent labelled Record over the open Lap, keeping its
  /// note and tags, or labels the Lap as a new Record like it when the two
  /// don't meet. See [DayRecorder.continueLast].
  Future<Record?> continueLast();

  Future<Record?> relabel(String recordId, String? activityId);

  Future<Record?> annotate(
    String recordId, {
    required String comment,
    required List<String> tagIds,
  });

  Future<Record?> adjustEdges(
    String recordId, {
    int? startEpochMs,
    int? endEpochMs,
  });

  /// Turns a Record into an Untracked Record in place.
  Future<Record?> clear(String recordId);

  /// Reverses the most recent label or split on the phone, or the Record
  /// [recordId] on a replica. Returns whether anything was undone.
  Future<bool> undo({String? recordId});

  Future<Record?> merge(String leftRecordId, String rightRecordId);

  Future<Record?> splitRecord(String recordId, int atEpochMs);
}

/// The phone's implementation: every command runs locally through
/// [DayRecorder], in the same transaction as its change row.
class PhoneRecordCommands implements RecordCommands {
  final DayRecorder dayRecorder;
  final int Function() _nowUtcMs;
  final FutureOr<String> Function() _getTimezoneId;
  final String Function() _generateIntentId;

  PhoneRecordCommands({
    required this.dayRecorder,
    int Function()? nowUtcMs,
    FutureOr<String> Function()? getTimezoneId,
    String Function()? generateIntentId,
  }) : _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _getTimezoneId = getTimezoneId ?? localTimezoneId,
       _generateIntentId = generateIntentId ?? (() => const Uuid().v4());

  @override
  Future<Record?> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) => dayRecorder.label(activityId, comment: comment, tags: tags);

  @override
  Future<Record?> split() => dayRecorder.split();

  @override
  Future<Record?> continueLast() => dayRecorder.continueLast();

  @override
  Future<Record?> relabel(String recordId, String? activityId) =>
      dayRecorder.relabel(recordId, activityId);

  @override
  Future<Record?> annotate(
    String recordId, {
    required String comment,
    required List<String> tagIds,
  }) => dayRecorder.annotate(recordId, comment: comment, tagIds: tagIds);

  @override
  Future<Record?> adjustEdges(
    String recordId, {
    int? startEpochMs,
    int? endEpochMs,
  }) => dayRecorder.adjustEdges(
    recordId,
    startEpochMs: startEpochMs,
    endEpochMs: endEpochMs,
  );

  @override
  Future<Record?> clear(String recordId) => dayRecorder.delete(recordId);

  @override
  Future<bool> undo({String? recordId}) async {
    if (recordId == null) return dayRecorder.undoLast();
    // Undoing a Record by id is the same compensating command the Mac's undo
    // intent becomes, so it runs through the one guarded path.
    final lap = dayRecorder.lap;
    final result = await dayRecorder.applyIntent(
      SyncIntent.undoRecord(
        intentId: _generateIntentId(),
        tappedAtEpochMs: _nowUtcMs(),
        tappedAtZoneId: await _getTimezoneId(),
        expectedLapStartEpochMs: lap?.startedAtEpochMs ?? 0,
        recordId: recordId,
      ),
    );
    return result.isApplied;
  }

  @override
  Future<Record?> merge(String leftRecordId, String rightRecordId) =>
      dayRecorder.merge(leftRecordId, rightRecordId);

  @override
  Future<Record?> splitRecord(String recordId, int atEpochMs) =>
      dayRecorder.splitRecord(recordId, atEpochMs);
}

/// The Mac's implementation: each command becomes a [SyncIntent] carrying the
/// instant and zone it was tapped at and the Lap start the replica showed.
///
/// Nothing here writes a Record. The intent is durable before the call returns,
/// and the phone decides whether to place it.
class RemoteRecordCommands implements RecordCommands {
  final TempoDatabase database;
  final IntentQueue queue;
  final int Function() _nowUtcMs;
  final String Function() _zoneId;
  final String Function() _generateIntentId;

  /// Called after a proposal is queued, so the client can exchange immediately.
  final Future<void> Function()? onQueued;

  RemoteRecordCommands({
    required this.database,
    required this.queue,
    int Function()? nowUtcMs,
    String Function()? zoneId,
    String Function()? generateIntentId,
    this.onQueued,
  }) : _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _zoneId = zoneId ?? localTimezoneId,
       _generateIntentId = generateIntentId ?? (() => const Uuid().v4());

  @override
  Future<Record?> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) async => _queue(
    SyncIntent.label(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      activityId: activityId,
      comment: comment,
      tagIds: tags,
    ),
  );

  @override
  Future<Record?> split() async => _queue(
    SyncIntent.split(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
    ),
  );

  @override
  Future<Record?> continueLast() async => _queue(
    SyncIntent.continueLast(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
    ),
  );

  @override
  Future<Record?> relabel(String recordId, String? activityId) async => _queue(
    SyncIntent.relabel(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      recordId: recordId,
      activityId: activityId,
    ),
  );

  @override
  Future<Record?> annotate(
    String recordId, {
    required String comment,
    required List<String> tagIds,
  }) async => _queue(
    SyncIntent.annotate(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      recordId: recordId,
      comment: comment,
      tagIds: tagIds,
    ),
  );

  @override
  Future<Record?> adjustEdges(
    String recordId, {
    int? startEpochMs,
    int? endEpochMs,
  }) async => _queue(
    SyncIntent.adjustEdges(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      recordId: recordId,
      startEpochMs: startEpochMs,
      endEpochMs: endEpochMs,
    ),
  );

  @override
  Future<Record?> clear(String recordId) async => _queue(
    SyncIntent.clear(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      recordId: recordId,
    ),
  );

  @override
  Future<bool> undo({String? recordId}) async {
    // With no target, undo the last Record the replica knows about. The phone
    // only removes it when it is the Record immediately before the open Lap.
    final targetId = recordId ?? await _latestRecordId();
    if (targetId == null) return false;
    await _queue(
      SyncIntent.undoRecord(
        intentId: _generateIntentId(),
        tappedAtEpochMs: _nowUtcMs(),
        tappedAtZoneId: _zoneId(),
        expectedLapStartEpochMs: await _expectedLapStart(),
        recordId: targetId,
      ),
    );
    return true;
  }

  @override
  Future<Record?> merge(String leftRecordId, String rightRecordId) async =>
      _queue(
        SyncIntent.merge(
          intentId: _generateIntentId(),
          tappedAtEpochMs: _nowUtcMs(),
          tappedAtZoneId: _zoneId(),
          expectedLapStartEpochMs: await _expectedLapStart(),
          leftRecordId: leftRecordId,
          rightRecordId: rightRecordId,
        ),
      );

  @override
  Future<Record?> splitRecord(String recordId, int atEpochMs) async => _queue(
    SyncIntent.splitRecord(
      intentId: _generateIntentId(),
      tappedAtEpochMs: _nowUtcMs(),
      tappedAtZoneId: _zoneId(),
      expectedLapStartEpochMs: await _expectedLapStart(),
      recordId: recordId,
      atEpochMs: atEpochMs,
    ),
  );

  Future<Record?> _queue(SyncIntent intent) async {
    await queue.enqueue(intent);
    final callback = onQueued;
    if (callback != null) {
      // The intent is already durable; a failed exchange leaves it pending.
      unawaited(callback());
    }
    return null;
  }

  Future<int> _expectedLapStart() async =>
      (await database.getLap())?.startedAtEpochMs ?? 0;

  Future<String?> _latestRecordId() async {
    final records = await database.getRecords(
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    return records.isEmpty ? null : records.first.id;
  }
}
