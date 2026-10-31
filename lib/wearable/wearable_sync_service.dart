import 'dart:async';

import 'package:flutter/services.dart';

import '../core/state/timer_state_machine.dart';
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
/// Listens to TimerStateMachine and synchronizes active timer state and activities
/// over the Wearable Data Layer platform channel.
class WearableSyncService {
  static const String channelName = 'com.tempo.tracker/wearable';

  final TimerStateMachine timerStateMachine;
  final TempoDatabase? database;
  final Future<Activity?> Function(String activityId)? getActivity;
  final MethodChannel channel;

  final StreamController<WatchAction> _watchActionController =
      StreamController<WatchAction>.broadcast();

  bool _isDisposed = false;

  WearableSyncService({
    required this.timerStateMachine,
    this.database,
    this.getActivity,
    MethodChannel? channel,
  }) : channel = channel ?? const MethodChannel(channelName);

  /// Stream of raw actions received from the watch.
  Stream<WatchAction> get incomingWatchActions => _watchActionController.stream;

  /// Initializes listeners and registers the platform method call handler.
  void initialize() {
    channel.setMethodCallHandler(_handleNativeMethodCall);
    timerStateMachine.activeTimerNotifier.addListener(_onActiveTimerChanged);

    // Initial sync of current state
    _onActiveTimerChanged();
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

  /// Sends the current active timer snapshot to the watch.
  Future<void> _onActiveTimerChanged() async {
    if (_isDisposed) return;

    final timer = timerStateMachine.activeTimer;

    try {
      if (timer != null) {
        String? activityName;
        String colorHex = '#4CAF50';

        if (getActivity != null) {
          final act = await getActivity!(timer.activityId);
          if (act != null) {
            activityName = act.name;
            colorHex = act.colorHex;
          }
        } else if (database != null) {
          final act = await database!.getActivityById(timer.activityId);
          if (act != null) {
            activityName = act.name;
            colorHex = act.colorHex;
          }
        }

        await channel.invokeMethod('syncActiveTimer', {
          'isRunning': !timer.isPaused,
          'activityId': timer.activityId,
          'activityName': activityName ?? timer.activityId,
          'activityColorHex': colorHex,
          'startedAtEpochMs': timer.startedAtEpochMs,
          'isPaused': timer.isPaused,
          'accumulatedPauseMs': timer.accumulatedPauseMs,
          'revision': timer.revision,
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
            await timerStateMachine.start(
              action.activityId!,
              comment: action.comment ?? '',
            );
          }
          break;

        case 'STOP':
          if (timerStateMachine.activeTimer != null) {
            await timerStateMachine.stop(finalComment: action.comment);
          }
          break;

        case 'PAUSE':
          if (timerStateMachine.isTracking) {
            await timerStateMachine.pause();
          }
          break;

        case 'RESUME':
          if (timerStateMachine.isPaused) {
            await timerStateMachine.resume();
          }
          break;

        case 'UNDO':
          if (timerStateMachine.activeTimer != null) {
            await timerStateMachine.discard();
          }
          break;
      }
    } catch (e) {
      // Ignore transition error if state already transitioned or invalid
    }
  }

  /// Closes streams and cleans up listeners.
  void dispose() {
    _isDisposed = true;
    timerStateMachine.activeTimerNotifier.removeListener(_onActiveTimerChanged);
    _watchActionController.close();
  }
}
