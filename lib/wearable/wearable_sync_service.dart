import 'dart:async';

import 'package:flutter/services.dart';

import '../core/state/day_recorder.dart';
import '../core/state/suggestion_engine.dart';
import '../core/time/timezone_id.dart';
import '../data/database/tempo_database.dart';
import '../data/models/activity.dart';

/// Represents an action received from the Wear OS companion watch.
class WatchAction {
  /// "LABEL" labels the open Lap; "SPLIT" closes it as an Untracked Record.
  final String type;
  final String? activityId;
  final int timestampEpochMs;
  final String? actionId;
  final String? comment;

  const WatchAction({
    required this.type,
    this.activityId,
    required this.timestampEpochMs,
    this.actionId,
    this.comment,
  });

  factory WatchAction.fromMap(Map<dynamic, dynamic> map) {
    return WatchAction(
      type: map['action'] as String? ?? 'UNKNOWN',
      activityId: map['activityId'] as String?,
      timestampEpochMs:
          (map['timestampEpochMs'] as num?)?.toInt() ??
          DateTime.now().toUtc().millisecondsSinceEpoch,
      actionId: map['actionId'] as String?,
      comment: map['comment'] as String?,
    );
  }

  @override
  String toString() =>
      'WatchAction(type: $type, activityId: $activityId, timestamp: $timestampEpochMs)';
}

/// Service bridging the Flutter application with the Wear OS companion app.
/// Listens to DayRecorder and synchronizes the open Lap and activities
/// over the Wearable Data Layer platform channel.
class WearableSyncService {
  static const String channelName = 'com.tempos.tracker/wearable';

  /// The window the watch tile ranks Activities over.
  static const Duration tileActivityWindow = Duration(days: 14);

  /// How many Activities the watch tile offers.
  static const int tileActivityCount = 3;

  final DayRecorder dayRecorder;
  final TempoDatabase? database;
  final Future<Activity?> Function(String activityId)? getActivity;
  final MethodChannel channel;
  final int Function() _nowUtcMs;

  final StreamController<WatchAction> _watchActionController =
      StreamController<WatchAction>.broadcast();

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
  void initialize() {
    channel.setMethodCallHandler(_handleNativeMethodCall);
    dayRecorder.lapListenable.addListener(_onLapChanged);

    // Initial sync of current state
    _onLapChanged();
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

  /// The ids of the top suggested Activities over [tileActivityWindow] using
  /// [ContextualSuggestionEngine], filling remaining slots with remaining activities.
  Future<List<String>> _tileActivityIds(List<Activity> activities) async {
    final db = database;
    if (db == null) return const [];

    final now = _nowUtcMs();
    final timezone = localTimezoneId();
    final since = now - tileActivityWindow.inMilliseconds;

    final history = await db.getRecords(
      startedAfter: since,
      orderBy: 'started_at_epoch_ms ASC',
    );

    final lastClosed = await db.getRecords(
      trackedOnly: true,
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    final precedingActivityId = lastClosed.isNotEmpty
        ? lastClosed.first.activityId
        : null;

    final suggested = const ContextualSuggestionEngine().rank(
      candidates: activities,
      history: history,
      precedingActivityId: precedingActivityId,
      targetEpochMs: now,
      timezoneId: timezone,
      limit: tileActivityCount,
    );

    final byId = {for (final activity in activities) activity.id: activity};
    final ids = <String>{for (final s in suggested) s.id, ...byId.keys};
    return ids.take(tileActivityCount).toList(growable: false);
  }

  /// Sends the open Lap snapshot to the watch.
  Future<void> _onLapChanged() async {
    if (_isDisposed) return;

    final lap = dayRecorder.lap;
    final now = _nowUtcMs();

    try {
      await channel.invokeMethod('syncLap', {
        'lapStartedAtEpochMs': lap?.startedAtEpochMs ?? 0,
        'lapStartedTimezoneId': lap?.startedTimezoneId ?? '',
        'revision': lap?.revision ?? 0,
        'updatedAtEpochMs': now,
      });
    } catch (_) {
      // Platform channel or watch unreachable; offline buffer will sync upon reconnection
    }
  }

  /// Handles incoming actions dispatched from the Wear OS companion.
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onWatchActionReceived') {
      final args = call.arguments;
      if (args is Map) {
        final action = WatchAction.fromMap(args);
        _watchActionController.add(action);
        await _executeWatchAction(action);
        return true;
      }
    }
    return null;
  }

  Future<void> _executeWatchAction(WatchAction action) async {
    try {
      switch (action.type.toUpperCase()) {
        case 'LABEL':
          if (action.activityId != null && action.activityId!.isNotEmpty) {
            await dayRecorder.label(
              action.activityId!,
              comment: action.comment ?? '',
            );
          }
          break;

        case 'SPLIT':
          await dayRecorder.split();
          break;

        case 'UNDO':
          await dayRecorder.undoLast();
          break;
      }
    } catch (e) {
      // Ignore transition error if state already transitioned or invalid
    }
  }

  /// Closes streams and cleans up listeners.
  void dispose() {
    _isDisposed = true;
    dayRecorder.lapListenable.removeListener(_onLapChanged);
    _watchActionController.close();
  }
}
