import 'dart:async';

import 'package:flutter/services.dart';

import '../core/state/day_recorder.dart';
import '../core/state/suggestion_loader.dart';
import '../core/time/timezone_id.dart';
import '../data/database/tempo_database.dart';
import '../data/models/activity.dart';
import '../data/models/record.dart';
import '../data/models/sync_change.dart';

/// Represents an action received from the Wear OS companion watch.
class WatchAction {
  /// "LABEL" labels the open Lap; "SPLIT" closes it as an Untracked Record;
  /// "CONTINUE" grows the last Record ("Still"); "REPEAT" labels the Lap with
  /// the last Record's Activity again; "UNDO" reverses the last label.
  final String type;
  final String? activityId;

  /// The instant the tap happened, in UTC epoch milliseconds. The Record is
  /// written for this moment, not for when the phone received it.
  final int timestampEpochMs;

  /// The zone the tap happened in, so the Record's end lands in the zone the
  /// user was actually in.
  final String? zoneId;
  final String? actionId;

  /// Per-watch monotonic counter. The phone acknowledges with the highest
  /// sequence it has applied, and the watch drops everything at or below it.
  final int actionSeq;

  /// The watch that tapped, so its acknowledgement watermark is keyed by
  /// device in `watch_watermarks`.
  final String? deviceId;

  /// For an UNDO, the id of the label it reverses.
  final String? undoesActionId;
  final String? comment;

  const WatchAction({
    required this.type,
    this.activityId,
    required this.timestampEpochMs,
    this.zoneId,
    this.actionId,
    this.actionSeq = 0,
    this.deviceId,
    this.undoesActionId,
    this.comment,
  });

  factory WatchAction.fromMap(Map<dynamic, dynamic> map) {
    return WatchAction(
      type: map['action'] as String? ?? 'UNKNOWN',
      activityId: map['activityId'] as String?,
      timestampEpochMs:
          (map['timestampEpochMs'] as num?)?.toInt() ??
          DateTime.now().toUtc().millisecondsSinceEpoch,
      zoneId: map['zoneId'] as String?,
      actionId: map['actionId'] as String?,
      actionSeq: (map['actionSeq'] as num?)?.toInt() ?? 0,
      deviceId: map['deviceId'] as String?,
      undoesActionId: map['undoesActionId'] as String?,
      comment: map['comment'] as String?,
    );
  }

  @override
  String toString() =>
      'WatchAction(type: $type, activityId: $activityId, '
      'timestamp: $timestampEpochMs, actionSeq: $actionSeq, '
      'deviceId: $deviceId)';
}

/// The outcome of one watch action: what the phone applied at the tap's own
/// instant, or why it refused, so the watch can drop the action and roll its
/// optimistic Lap back.
class WatchActionResult {
  final String actionId;
  final int actionSeq;

  /// [IntentResult.appliedStatus] or [IntentResult.rejectedStatus].
  final String status;

  /// Empty when applied; a stable reason such as `lap-moved` when rejected.
  final String reason;
  final String? entityId;
  final int? appliedAtEpochMs;

  const WatchActionResult({
    required this.actionId,
    required this.actionSeq,
    required this.status,
    this.reason = '',
    this.entityId,
    this.appliedAtEpochMs,
  });

  bool get isApplied => status == IntentResult.appliedStatus;

  @override
  String toString() =>
      'WatchActionResult(actionId: $actionId, actionSeq: $actionSeq, '
      'status: $status, reason: $reason)';
}

/// Service bridging the Flutter application with the Wear OS companion app.
/// Listens to DayRecorder and synchronizes the open Lap and activities
/// over the Wearable Data Layer platform channel.
class WearableSyncService {
  static const String channelName = 'com.tempos.tracker/wearable';

  /// How many Activities the watch tile offers.
  static const int tileActivityCount = 3;

  final DayRecorder dayRecorder;
  final TempoDatabase? database;
  final Future<Activity?> Function(String activityId)? getActivity;
  final MethodChannel channel;
  final int Function() _nowUtcMs;

  final StreamController<WatchAction> _watchActionController =
      StreamController<WatchAction>.broadcast();

  /// The watch whose watermark this service acknowledges. Learned from the
  /// actions themselves; the phone never learns a watch id any other way.
  String? _watchDeviceId;

  /// Ids the phone refused, sent with the next Lap payload so the watch can
  /// drop them instead of queueing them forever.
  final List<String> _rejectedActionIds = <String>[];

  /// A tap arrives twice, on the DataItem and the message channel. Serializing
  /// the handling is what makes the watermark a real duplicate guard: the
  /// second copy reads a watermark the first has already advanced.
  Future<void>? _actionLock;

  bool _isDisposed = false;

  WearableSyncService({
    required this.dayRecorder,
    this.database,
    this.getActivity,
    MethodChannel? channel,
    int Function()? nowUtcMs,
  }) : channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// Stream of raw actions received from the watch.
  Stream<WatchAction> get incomingWatchActions => _watchActionController.stream;

  /// Initializes listeners and registers the platform method call handler.
  ///
  /// Actions the phone's native listener buffered while this engine was not
  /// running are replayed first, then the watch is asked to flush anything it
  /// still has queued. Both use the same serialized action path as a live tap,
  /// so the per-watch watermark drops anything already applied.
  Future<void> initialize() async {
    channel.setMethodCallHandler(_handleNativeMethodCall);
    dayRecorder.lapListenable.addListener(_onLapChanged);

    // Initial sync of current state
    await _onLapChanged();
    await _replayPendingWatchActions();
    await _pingWatch();
  }

  Future<void> _replayPendingWatchActions() async {
    if (_isDisposed) return;
    try {
      final pending = await channel.invokeMethod<List<dynamic>>(
        'drainPendingWatchActions',
      );
      if (pending == null || pending.isEmpty) return;
      for (final entry in pending) {
        if (entry is Map) {
          await _ingestWatchAction(WatchAction.fromMap(entry));
        }
      }
    } catch (_) {
      // An older phone build has no inbox; the watch queue retries.
    }
  }

  /// Asks every connected watch to re-send its unacknowledged actions. This is
  /// what turns a label taken while the phone app was closed into a Record.
  Future<void> _pingWatch() async {
    if (_isDisposed) return;
    try {
      await channel.invokeMethod<void>('pingWatch');
    } catch (_) {
      // The watch is unreachable; it flushes on the next peer connection.
    }
  }

  /// Synchronizes the list of available activities, and the tile's ranked
  /// slots, with the Wear OS watch.
  Future<bool> syncActivities(List<Activity> activities) async {
    if (_isDisposed) return false;
    try {
      final list = activities
          .map(
            (a) => {
              'id': a.id,
              'name': a.name,
              'colorHex': a.colorHex,
              'iconName': a.iconName,
              'isPinned': a.isPinned,
            },
          )
          .toList();

      final result = await channel.invokeMethod<bool>('syncActivities', {
        'activities': list,
        'tileActivityIds': await _tileActivityIds(activities),
      });
      return result ?? true;
    } catch (e) {
      // Platform channel error or wearable service unavailable
      return false;
    }
  }

  /// Re-reads Activities from the database and pushes them, plus the tile's
  /// ranked slots, to the watch. Call after a Record is committed so the tile
  /// follows what the user actually labels.
  Future<void> refreshActivities() async {
    final db = database;
    if (_isDisposed || db == null) return;
    try {
      await syncActivities(await db.getAllActivities());
    } catch (_) {
      // Activity refresh is best effort; the next sync retries.
    }
  }

  /// The ids of the top suggested Activities over the engine's history window
  /// using [loadSuggestions], filling remaining slots with remaining activities.
  Future<List<String>> _tileActivityIds(List<Activity> activities) async {
    final db = database;
    if (db == null) return const [];

    final now = _nowUtcMs();
    final timezone = localTimezoneId();
    final suggested = await loadSuggestions(
      database: db,
      candidates: activities,
      nowEpochMs: now,
      timezoneId: timezone,
      limit: tileActivityCount,
    );

    final byId = {for (final activity in activities) activity.id: activity};
    final ids = <String>{for (final s in suggested) s.id, ...byId.keys};
    return ids.take(tileActivityCount).toList(growable: false);
  }

  /// Sends the open Lap snapshot to the watch, with the acknowledgement
  /// watermark and any ids the phone refused.
  Future<void> _onLapChanged() async {
    if (_isDisposed) return;

    final rejectedActionIds = List<String>.from(_rejectedActionIds);
    final deviceId = _watchDeviceId;

    try {
      final lastActivity = await _lastActivity();
      final appliedActionSeq = deviceId == null || deviceId.isEmpty
          ? 0
          : await _readWatermark(deviceId);
      // Read the Lap after every await so the snapshot sent is the current one,
      // not the one from when this listener first fired.
      final lap = dayRecorder.lap;
      final now = _nowUtcMs();
      await channel.invokeMethod('syncLap', {
        'lapStartedAtEpochMs': lap?.startedAtEpochMs ?? 0,
        'lapStartedTimezoneId': lap?.startedTimezoneId ?? '',
        'revision': lap?.revision ?? 0,
        'updatedAtEpochMs': now,
        'appliedActionSeq': appliedActionSeq,
        'rejectedActionIds': rejectedActionIds,
        'lastActivityId': lastActivity?.id,
        'lastActivityName': lastActivity?.name,
        'lastActivityColorHex': lastActivity?.colorHex,
      });
      if (rejectedActionIds.isNotEmpty) {
        _rejectedActionIds.removeWhere(rejectedActionIds.contains);
      }
    } catch (_) {
      // Platform channel or watch unreachable; offline buffer will sync upon reconnection
    }
  }

  /// The Activity on the most recent labelled Record, so the watch can offer
  /// "Still `Activity`" and "`Activity` again" beside its Activity pills.
  Future<Activity?> _lastActivity() async {
    final db = database;
    if (db == null) return null;
    try {
      final last = await db.getRecords(
        trackedOnly: true,
        limit: 1,
        orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
      );
      final activityId = last.isEmpty ? null : last.first.activityId;
      if (activityId == null) return null;
      return await db.getActivityById(activityId);
    } catch (_) {
      return null;
    }
  }

  /// Handles incoming actions dispatched from the Wear OS companion.
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onWatchActionReceived') {
      final args = call.arguments;
      if (args is Map) {
        return _ingestWatchAction(WatchAction.fromMap(args));
      }
    }
    return null;
  }

  /// Applies one watch action and returns the acknowledgement shape the native
  /// side reads before it drops its durable copy.
  Future<Map<String, dynamic>> _ingestWatchAction(WatchAction action) async {
    _watchActionController.add(action);
    final result = await _serialized(() => _executeWatchAction(action));
    return {
      'status': result.status,
      'reason': result.reason,
      'actionId': result.actionId,
      'actionSeq': result.actionSeq,
    };
  }

  /// Applies [action] at the instant it was tapped, or refuses it with a
  /// reason. Never swallows the outcome: a refusal becomes a rejected id the
  /// watch can act on.
  Future<WatchActionResult> _executeWatchAction(WatchAction action) async {
    if (action.deviceId != null && action.deviceId!.isNotEmpty) {
      _watchDeviceId = action.deviceId;
    }

    final type = action.type.toUpperCase();
    if (type != 'LABEL' &&
        type != 'SPLIT' &&
        type != 'UNDO' &&
        type != 'CONTINUE' &&
        type != 'REPEAT') {
      return _reject(action, 'unknown-action');
    }

    // The DataItem and the message carry the same tap. The second copy is a
    // no-op that only re-acknowledges the sequence already applied.
    final watermark = await _currentWatermark();
    if (action.actionSeq > 0 && action.actionSeq <= watermark) {
      await _onLapChanged();
      return WatchActionResult(
        actionId: action.actionId ?? '',
        actionSeq: action.actionSeq,
        status: IntentResult.appliedStatus,
        reason: 'duplicate',
      );
    }

    // A frame of reference mismatch is a clock problem; lateness is not. A
    // watch action is durable and may legitimately arrive hours after it was
    // tapped (the phone was in another room, or off). Only a tap stamped in
    // the future can be wrong, so only that is refused here. A tap that is
    // older than the open Lap belongs to time already closed, and the Lap
    // start check below refuses it for the right reason.
    const maxClockSkewMs = 10 * 60 * 1000;
    if (action.timestampEpochMs - _nowUtcMs() > maxClockSkewMs) {
      return await _reject(action, IntentResult.reasonClockSkew);
    }

    // A tap that is not strictly after the open Lap's start contributes no
    // time: applying it would write a zero-second Record. A duplicate delivery
    // of the label that opened the Lap looks exactly like this (its tap instant
    // equals the Lap start), so it is refused rather than written. Older taps
    // belong to time the phone has already closed and are refused for the same
    // reason.
    await dayRecorder.initialize();
    final lap = dayRecorder.lap;

    // A MidnightSplit moves the open Lap to 00:00, but a tap before midnight
    // is still durable time in the Day it was lived in. Label the closed
    // stretch up to the tap instead of throwing the night away. "Still" and
    // "again" carry no Activity, so they resolve against the last tracked
    // Record, exactly as their live paths do.
    if (type != 'UNDO' &&
        lap != null &&
        lap.startedAtEpochMs > action.timestampEpochMs) {
      final late = await _lateActionLabel(action, type);
      if (late != null) {
        final record = await dayRecorder.labelClosedSpan(
          late.id,
          atEpochMs: action.timestampEpochMs,
          atZoneId: action.zoneId,
          comment: late.comment,
          tags: late.tags,
          intentId: action.actionId,
        );
        if (record != null) return await _applied(action, entityId: record.id);
      }
      return await _reject(action, IntentResult.reasonLapMoved);
    }

    if (type != 'UNDO' &&
        lap != null &&
        lap.startedAtEpochMs >= action.timestampEpochMs) {
      return await _reject(action, IntentResult.reasonLapMoved);
    }

    try {
      switch (type) {
        case 'LABEL':
          final activityId = action.activityId;
          if (activityId == null || activityId.isEmpty) {
            return await _reject(action, IntentResult.reasonUnknownActivity);
          }
          if (!await _activityExists(activityId)) {
            return await _reject(action, IntentResult.reasonUnknownActivity);
          }
          final record = await dayRecorder.label(
            activityId,
            comment: action.comment ?? '',
            atEpochMs: action.timestampEpochMs,
            atZoneId: action.zoneId,
            intentId: action.actionId,
          );
          return await _applied(action, entityId: record.id);

        case 'SPLIT':
          final record = await dayRecorder.split(
            atEpochMs: action.timestampEpochMs,
            atZoneId: action.zoneId,
            intentId: action.actionId,
          );
          return await _applied(action, entityId: record.id);

        case 'CONTINUE':
          final record = await dayRecorder.continueLast(
            atEpochMs: action.timestampEpochMs,
            atZoneId: action.zoneId,
            intentId: action.actionId,
          );
          if (record == null) return await _reject(action, 'nothing-to-repeat');
          return await _applied(action, entityId: record.id);

        case 'REPEAT':
          final record = await dayRecorder.sameAsLast(
            atEpochMs: action.timestampEpochMs,
            atZoneId: action.zoneId,
            intentId: action.actionId,
          );
          if (record == null) return await _reject(action, 'nothing-to-repeat');
          return await _applied(action, entityId: record.id);

        case 'UNDO':
          final undone = await dayRecorder.undoLast();
          if (!undone) return await _reject(action, 'nothing-to-undo');
          return await _applied(action);
      }
    } on ArgumentError {
      return await _reject(action, IntentResult.reasonUnknownActivity);
    } catch (_) {
      return await _reject(action, 'failed');
    }

    return await _reject(action, 'unknown-action');
  }

  /// Runs one action at a time, so the two copies of a tap cannot both read the
  /// watermark before either writes it.
  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _actionLock;
    final completer = Completer<void>();
    _actionLock = completer.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      completer.complete();
      if (identical(_actionLock, completer.future)) _actionLock = null;
    }
  }

  Future<WatchActionResult> _applied(
    WatchAction action, {
    String? entityId,
  }) async {
    final deviceId = _watchDeviceId;
    if (deviceId != null && deviceId.isNotEmpty && action.actionSeq > 0) {
      await _writeWatermark(deviceId, action.actionSeq);
    }
    await _onLapChanged();
    return WatchActionResult(
      actionId: action.actionId ?? '',
      actionSeq: action.actionSeq,
      status: IntentResult.appliedStatus,
      entityId: entityId,
      appliedAtEpochMs: action.timestampEpochMs,
    );
  }

  Future<WatchActionResult> _reject(WatchAction action, String reason) async {
    final actionId = action.actionId;
    if (actionId != null &&
        actionId.isNotEmpty &&
        !_rejectedActionIds.contains(actionId)) {
      _rejectedActionIds.add(actionId);
    }
    // A refusal does not move the Lap, so the watch only learns about it if
    // the snapshot is pushed here.
    await _onLapChanged();
    return WatchActionResult(
      actionId: actionId ?? '',
      actionSeq: action.actionSeq,
      status: IntentResult.rejectedStatus,
      reason: reason,
    );
  }

  /// The Activity, note and tags a tap made before the open Lap started should
  /// apply. A plain LABEL carries its own Activity; "Still" and "again" carry
  /// none and resolve against the most recent tracked Record, the same source
  /// their live paths use.
  Future<({String id, String comment, List<String> tags})?> _lateActionLabel(
    WatchAction action,
    String type,
  ) async {
    switch (type) {
      case 'LABEL':
        final activityId = action.activityId;
        if (activityId == null ||
            activityId.isEmpty ||
            !await _activityExists(activityId)) {
          return null;
        }
        return (
          id: activityId,
          comment: action.comment ?? '',
          tags: const <String>[],
        );
      case 'REPEAT':
      case 'CONTINUE':
        final last = await _lastTrackedRecord();
        final activityId = last?.activityId;
        if (last == null || activityId == null) return null;
        return (
          id: activityId,
          comment: type == 'CONTINUE' ? last.comment : '',
          tags: type == 'CONTINUE' ? last.tagIds : const <String>[],
        );
    }
    return null;
  }

  /// The most recent labelled Record, with the note and tags "Still" carries
  /// forward.
  Future<Record?> _lastTrackedRecord() async {
    final db = database;
    if (db == null) return null;
    try {
      final records = await db.getRecords(
        trackedOnly: true,
        limit: 1,
        orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
      );
      return records.isEmpty ? null : records.first;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _activityExists(String activityId) async {
    final db = database;
    if (db == null) return true;
    return await db.getActivityById(activityId) != null;
  }

  /// The highest sequence already applied for this watch, read from the store
  /// so a restart of the phone app does not re-apply or lose the watermark.
  Future<int> _currentWatermark() async {
    final deviceId = _watchDeviceId;
    if (deviceId == null || deviceId.isEmpty) return 0;
    return _readWatermark(deviceId);
  }

  Future<int> _readWatermark(String deviceId) async {
    final db = database;
    if (db == null) return 0;
    return db.getWatchWatermark(deviceId);
  }

  Future<void> _writeWatermark(String deviceId, int actionSeq) async {
    final db = database;
    if (db == null) return;
    if (await _readWatermark(deviceId) >= actionSeq) return;
    await db.setWatchWatermark(deviceId, actionSeq);
  }

  /// Closes streams and cleans up listeners.
  void dispose() {
    _isDisposed = true;
    dayRecorder.lapListenable.removeListener(_onLapChanged);
    _watchActionController.close();
  }
}
