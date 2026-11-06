import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/state/day_recorder.dart';
import '../core/state/suggestion_loader.dart';
import '../core/time/timezone_id.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';
import '../ui/helpers/ui_helpers.dart';

/// Keeps Android's ongoing Lap notification in step with the open Lap and
/// carries out the label, Repeat, Split and Undo taps made on it.
///
/// After a label or Split from the notification it shows the Record just
/// written with an Undo action for the [DayRecorder.undoGraceWindow], then
/// returns to the open Lap.
class LapNotificationService {
  static const String channelName = 'com.tempos.tracker/notification';

  /// How many Activity chips the expanded notification offers.
  static const int chipCount = 6;

  /// Strip Track, the fill Untracked time gets in strips.
  static const String untrackedColorHex = '#D2D2C8';

  final DayRecorder dayRecorder;
  final TempoDatabase database;
  final MethodChannel _channel;
  final int Function() _nowUtcMs;

  /// Called when a notification action no longer needs this service: its
  /// UndoGraceWindow has passed, it was undone, or it changed nothing.
  final Future<void> Function()? onSettled;

  Timer? _undoTimer;
  int _acting = 0;
  bool _isDisposed = false;

  LapNotificationService({
    required this.dayRecorder,
    required this.database,
    this.onSettled,
    MethodChannel? channel,
    int Function()? nowUtcMs,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// Registers the handler for notification taps and follows the open Lap.
  /// Call [publish] to post the current state.
  void initialize() {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
    dayRecorder.lapListenable.addListener(_onLapChanged);
  }

  /// Posts the open Lap with the ranked Activity chips. With [closed], shows
  /// that Record with an Undo action instead.
  Future<void> publish({Record? closed}) async {
    final lap = dayRecorder.lap;
    if (_isDisposed || lap == null) return;
    try {
      final activities = await database.getAllActivities();
      final repeat = await _repeatActivity();
      await _channel.invokeMethod<void>('updateLapNotification', {
        'lapStartedAtEpochMs': lap.startedAtEpochMs,
        'since': _clock(dayRecorder.lapStartTimezoneId, lap.startedAtEpochMs),
        'activities': [
          for (final activity in await _chipActivities(activities))
            {
              'id': activity.id,
              'name': activity.name,
              'colorHex': activity.colorHex,
            },
        ],
        if (repeat != null)
          'lastActivity': {'id': repeat.id, 'name': repeat.name},
        if (closed != null) 'lastLabel': await _lastLabel(closed),
      });
    } catch (e) {
      debugPrint('Lap notification update failed: $e');
    }
  }

  /// Carries out a tap on the notification: `LABEL` with [activityId],
  /// `SPLIT`, or `UNDO`.
  Future<void> handleAction(String action, {String? activityId}) async {
    Record? closed;
    _acting++;
    try {
      switch (action) {
        case 'LABEL':
          if (activityId != null) {
            closed = await dayRecorder.label(activityId);
          }
          break;
        case 'SPLIT':
          closed = await dayRecorder.split();
          break;
        case 'UNDO':
          await dayRecorder.undoLast();
          break;
      }
    } catch (e) {
      debugPrint('Notification action $action failed: $e');
    } finally {
      _acting--;
    }

    if (closed == null) {
      await _settle();
      return;
    }
    _undoTimer?.cancel();
    _undoTimer = Timer(dayRecorder.undoGraceWindow, () => unawaited(_settle()));
    await publish(closed: closed);
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onNotificationAction') {
      final args = call.arguments;
      if (args is Map) {
        await handleAction(
          args['action'] as String? ?? '',
          activityId: args['activityId'] as String?,
        );
        return true;
      }
    }
    return null;
  }

  /// Follows Lap changes made anywhere else (the app, the watch, a deep link,
  /// a MidnightSplit). Any Undo still on show would no longer reverse the
  /// Record it names, so it is dropped.
  void _onLapChanged() {
    if (_acting > 0 || _isDisposed) return;
    unawaited(_settle());
  }

  Future<void> _settle() async {
    _undoTimer?.cancel();
    _undoTimer = null;
    await publish();
    await onSettled?.call();
  }

  /// Suggested activities ranked contextually, followed by remaining user
  /// activities in their own order, up to [chipCount].
  Future<List<Activity>> _chipActivities(List<Activity> activities) async {
    final now = _nowUtcMs();
    final timezone = localTimezoneId();
    final suggested = await loadSuggestions(
      database: database,
      candidates: activities,
      nowEpochMs: now,
      timezoneId: timezone,
      limit: chipCount,
    );

    final byId = {for (final activity in activities) activity.id: activity};
    final ids = <String>{for (final s in suggested) s.id, ...byId.keys};
    return [for (final id in ids.take(chipCount)) byId[id]!];
  }

  /// The Activity the Repeat action labels the Lap with: the one on the most
  /// recent labelled Record, or null when there is nothing to repeat.
  Future<Activity?> _repeatActivity() async {
    final previous = await database.getRecords(
      trackedOnly: true,
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    if (previous.isEmpty) return null;
    final activityId = previous.first.activityId;
    return activityId == null ? null : database.getActivityById(activityId);
  }

  /// The Record shown after a tap. Its start and end read in the zones they
  /// were lived in; its duration is UTC epoch arithmetic.
  Future<Map<String, Object>> _lastLabel(Record record) async {
    final activityId = record.activityId;
    final activity = activityId == null
        ? null
        : await database.getActivityById(activityId);
    final showZones = record.crossesTimezones;
    return {
      'activityName': activity?.name ?? 'Untracked',
      'colorHex': activity?.colorHex ?? untrackedColorHex,
      'startedAt': _clock(
        record.timezoneId,
        record.startedAtEpochMs,
        withZone: showZones,
      ),
      'endedAt': _clock(
        record.endTimezoneId,
        record.endedAtEpochMs,
        withZone: showZones,
      ),
      'duration': UiHelpers.formatDurationHuman(record.durationMs),
      'undoUntilEpochMs':
          record.endedAtEpochMs + dayRecorder.undoGraceWindow.inMilliseconds,
    };
  }

  static String _clock(
    String timezoneId,
    int epochMs, {
    bool withZone = false,
  }) {
    final time = DateFormat('HH:mm').format(wallClockAt(timezoneId, epochMs));
    return withZone ? '$time ${zoneAbbreviationAt(timezoneId, epochMs)}' : time;
  }

  /// Stops following the Lap and cancels a pending return from Undo.
  void dispose() {
    _isDisposed = true;
    _undoTimer?.cancel();
    dayRecorder.lapListenable.removeListener(_onLapChanged);
  }
}
