import 'dart:async';

import 'package:flutter/services.dart';

import '../core/state/day_recorder.dart';
import '../data/database/tempo_database.dart';
import '../data/models/activity.dart';

/// Represents an action received from the Wear OS companion watch.
class WatchAction {
  final String type; // "START", "STOP", "PAUSE", "RESUME", "UNDO"
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

  final DayRecorder dayRecorder;
  final TempoDatabase? database;
  final Future<Activity?> Function(String activityId)? getActivity;
  final MethodChannel channel;

  final StreamController<WatchAction> _watchActionController =
      StreamController<WatchAction>.broadcast();

  bool _isDisposed = false;

  WearableSyncService({
    required this.dayRecorder,
    this.database,
    this.getActivity,
    MethodChannel? channel,
  }) : channel = channel ?? const MethodChannel(channelName);

  /// Stream of raw actions received from the watch.
  Stream<WatchAction> get incomingWatchActions => _watchActionController.stream;

  /// Initializes listeners and registers the platform method call handler.
  void initialize() {
    channel.setMethodCallHandler(_handleNativeMethodCall);
    dayRecorder.lapListenable.addListener(_onLapChanged);

    // Initial sync of current state
    _onLapChanged();
  }

  /// Synchronizes the list of available activities with the Wear OS watch.
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
      });
      return result ?? true;
    } catch (e) {
      // Platform channel error or wearable service unavailable
      return false;
    }
  }

  /// Sends the current open Lap snapshot to the watch.
  ///
  /// The channel method name and payload shape are unchanged so the existing
  /// Wear OS companion keeps working: it now receives the Lap as an always
  /// running, unpaused session with no Activity.
  Future<void> _onLapChanged() async {
    if (_isDisposed) return;

    final lap = dayRecorder.lap;

    try {
      if (lap != null) {
        await channel.invokeMethod('syncActiveTimer', {
          'isRunning': true,
          'activityId': null,
          'activityName': null,
          'activityColorHex': null,
          'startedAtEpochMs': lap.startedAtEpochMs,
          'isPaused': false,
          'accumulatedPauseMs': 0,
          'revision': lap.revision,
          'updatedAtEpochMs': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
      } else {
        await channel.invokeMethod('syncActiveTimer', {
          'isRunning': false,
          'activityId': null,
          'activityName': null,
          'activityColorHex': null,
          'startedAtEpochMs': 0,
          'isPaused': false,
          'accumulatedPauseMs': 0,
          'revision': 0,
          'updatedAtEpochMs': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
      }
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
        case 'START':
          if (action.activityId != null && action.activityId!.isNotEmpty) {
            await dayRecorder.label(
              action.activityId!,
              comment: action.comment ?? '',
            );
          }
          break;

        case 'STOP':
          // Split is #16; until then `stop` labels the Lap with the most
          // recent Record's Activity so the watch keeps working.
          await dayRecorder.sameAsLast();
          break;

        case 'PAUSE':
        case 'RESUME':
        case 'UNDO':
          // Pause, resume and undo are retired on this surface.
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
