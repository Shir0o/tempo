import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../export/csv_export_engine.dart';

/// Represents an abnormal shutdown or crash recovery state detected on boot.
class CrashRecoverySession {
  final ActiveTimer activeTimer;
  final int gapMs;
  final int nowUtcMs;
  final Future<void> Function() onKeepTracking;
  final Future<Record> Function({String? finalComment}) onTruncateToHeartbeat;
  final Future<void> Function() onDiscard;

  const CrashRecoverySession({
    required this.activeTimer,
    required this.gapMs,
    required this.nowUtcMs,
    required this.onKeepTracking,
    required this.onTruncateToHeartbeat,
    required this.onDiscard,
  });

  /// Total elapsed duration in milliseconds if the timer was kept tracking until now.
  int get elapsedMsIfKept => activeTimer.calculateDurationMs(nowUtcMs);

  /// Duration in milliseconds if the timer was truncated to the last recorded heartbeat.
  int get durationMsIfTruncated {
    final ref = (activeTimer.isPaused && activeTimer.pausedAtEpochMs != null)
        ? activeTimer.pausedAtEpochMs!
        : activeTimer.lastHeartbeatEpochMs;
    final dur =
        ref - activeTimer.startedAtEpochMs - activeTimer.accumulatedPauseMs;
    return dur < 0 ? 0 : dur;
  }

  /// Option 1: Keep tracking across the gap.
  Future<void> keepTracking() => onKeepTracking();

  /// Option 2: Truncate to the last recorded heartbeat and commit as Record.
  Future<Record> truncateToHeartbeat({String? finalComment}) =>
      onTruncateToHeartbeat(finalComment: finalComment);

  /// Option 3: Discard the active timer completely.
  Future<void> discard() => onDiscard();
}

/// Core single-active-timer state machine with monotonic UTC epoch arithmetic,
/// 60-second heartbeat persistence, and crash recovery.
class TimerStateMachine {
  final TempoDatabase _db;
  final int Function() _nowUtcMs;
  final String Function() _generateId;
  final String Function() _getTimezoneId;
  final Duration _heartbeatInterval;
  final int _crashThresholdMs;
  final Future<void> Function(Record record)? onRecordCommitted;
  CsvExportEngine? csvExportEngine;

  /// Default crash threshold: 6 hours = 21,600,000 milliseconds.
  static const int defaultCrashThresholdMs = 21600000;

  /// Default heartbeat interval: 60 seconds.
  static const Duration defaultHeartbeatInterval = Duration(seconds: 60);

  final ValueNotifier<ActiveTimer?> _activeTimerNotifier =
      ValueNotifier<ActiveTimer?>(null);
  final StreamController<ActiveTimer?> _timerStreamController =
      StreamController<ActiveTimer?>.broadcast(sync: true);

  Timer? _heartbeatTimer;
  Future<void>? _lock;
  Record? _lastStoppedRecord;
  bool _isInitialized = false;

  TimerStateMachine({
    required TempoDatabase database,
    int Function()? nowUtcMs,
    String Function()? generateId,
    String Function()? getTimezoneId,
    Duration? heartbeatInterval,
    int? crashThresholdMs,
    this.onRecordCommitted,
    this.csvExportEngine,
  })  : _db = database,
        _nowUtcMs =
            nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _generateId = generateId ?? (() => const Uuid().v4()),
        _getTimezoneId = getTimezoneId ?? (() => DateTime.now().timeZoneName),
        _heartbeatInterval = heartbeatInterval ?? defaultHeartbeatInterval,
        _crashThresholdMs = crashThresholdMs ?? defaultCrashThresholdMs;

  // ==========================================
  // Public State Getters & Notifiers
  // ==========================================

  /// Attaches or updates the CSV export engine.
  void attachExportEngine(CsvExportEngine engine) {
    csvExportEngine = engine;
  }

  /// Current active timer value or null if idle.
  ActiveTimer? get activeTimer => _activeTimerNotifier.value;

  /// ValueNotifier exposing the current active timer state.
  ValueNotifier<ActiveTimer?> get activeTimerNotifier => _activeTimerNotifier;

  /// ValueListenable exposing the current active timer state.
  ValueListenable<ActiveTimer?> get activeTimerListenable => _activeTimerNotifier;

  /// Broadcast stream emitting active timer changes.
  Stream<ActiveTimer?> get timerStream => _timerStreamController.stream;

  /// Whether a timer is currently actively ticking (not paused, not idle).
  bool get isTracking => activeTimer != null && !activeTimer!.isPaused;

  /// Whether a timer currently exists in a paused state.
  bool get isPaused => activeTimer != null && activeTimer!.isPaused;

  /// Whether no timer is currently active.
  bool get isIdle => activeTimer == null;

  /// Most recently committed Record from stop, switch, or recovery truncate.
  Record? get lastStoppedRecord => _lastStoppedRecord;

  /// Calculates the current elapsed duration in milliseconds.
  int get currentDurationMs =>
      activeTimer?.calculateDurationMs(_nowUtcMs()) ?? 0;

  /// Calculates elapsed duration given an optional reference UTC timestamp.
  int calculateElapsedMs([int? nowUtc]) =>
      activeTimer?.calculateDurationMs(nowUtc ?? _nowUtcMs()) ?? 0;

  // ==========================================
  // Lifecycle & Initialization
  // ==========================================

  /// Initializes the state machine by reading the singleton from SQLite.
  /// Starts heartbeat if a non-paused active timer is restored.
  Future<ActiveTimer?> initialize() => _synchronized(() async {
        final timer = await _db.getActiveTimer();
        _updateActiveTimer(timer);
        _isInitialized = true;

        if (timer != null && !timer.isPaused) {
          _startHeartbeat();
        }
        return timer;
      });

  /// Boot-up crash recovery checker adhering to specification 3.2.
  /// If an active timer exists and (nowUtc - last_heartbeat_epoch_ms > 6 hours),
  /// detects an abnormal shutdown and returns a [CrashRecoverySession].
  /// Otherwise, resumes normal continuation and returns null.
  Future<CrashRecoverySession?> checkCrashRecovery() => _synchronized(() async {
        final timer = await _db.getActiveTimer();
        _updateActiveTimer(timer);
        _isInitialized = true;

        if (timer == null) {
          _stopHeartbeat();
          return null;
        }

        final now = _nowUtcMs();
        final gapMs = now - timer.lastHeartbeatEpochMs;

        if (gapMs > _crashThresholdMs) {
          // Crash detected: do not resume heartbeat until user decides.
          _stopHeartbeat();
          return CrashRecoverySession(
            activeTimer: timer,
            gapMs: gapMs,
            nowUtcMs: now,
            onKeepTracking: keepTracking,
            onTruncateToHeartbeat: truncateToHeartbeat,
            onDiscard: discard,
          );
        } else {
          // Normal continuation within threshold
          if (!timer.isPaused) {
            _startHeartbeat();
          }
          return null;
        }
      });

  // ==========================================
  // Core State Machine Transitions
  // ==========================================

  /// Starts tracking [activityId].
  /// If a timer is already active, invokes atomic [switchActivity].
  /// Adheres to specification 2.2 START transition.
  Future<ActiveTimer> start(
    String activityId, {
    String comment = '',
    List<String> tagIds = const [],
  }) =>
      _synchronized(() async {
        await _ensureInitializedLocked();

        final current = _activeTimerNotifier.value;
        if (current != null) {
          return _switchActivityLocked(
            activityId,
            comment: comment,
            tagIds: tagIds,
          );
        }

        final activity = await _db.getActivityById(activityId);
        if (activity == null) {
          throw ArgumentError('Activity with id "$activityId" does not exist.');
        }

        final now = _nowUtcMs();
        final newTimer = ActiveTimer(
          id: 1,
          activityId: activityId,
          startedAtEpochMs: now,
          isPaused: false,
          pausedAtEpochMs: null,
          accumulatedPauseMs: 0,
          currentComment: comment,
          initialTagIds: List.unmodifiable(tagIds),
          lastHeartbeatEpochMs: now,
          revision: 1,
        );

        await _db.setActiveTimer(newTimer);
        _updateActiveTimer(newTimer);
        _startHeartbeat();
        return newTimer;
      });

  /// Pauses a running active timer.
  /// Sets is_paused = 1, records paused_at_epoch_ms = now, updates heartbeat, and increments revision.
  /// Throws [StateError] if idle or already paused.
  Future<ActiveTimer> pause() => _synchronized(() async {
        await _ensureInitializedLocked();

        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer is currently running.');
        }
        if (current.isPaused) {
          throw StateError('Active timer is already paused.');
        }

        _stopHeartbeat();
        final now = _nowUtcMs();
        final updated = current.copyWith(
          isPaused: true,
          pausedAtEpochMs: now,
          lastHeartbeatEpochMs: now,
          revision: current.revision + 1,
        );

        await _db.setActiveTimer(updated);
        _updateActiveTimer(updated);
        return updated;
      });

  /// Resumes a paused active timer.
  /// Adds elapsed pause to accumulated_pause_ms, sets is_paused = 0, clears paused_at, and increments revision.
  /// Throws [StateError] if idle or not paused.
  Future<ActiveTimer> resume() => _synchronized(() async {
        await _ensureInitializedLocked();

        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer is currently running.');
        }
        if (!current.isPaused) {
          throw StateError('Active timer is not paused.');
        }

        final now = _nowUtcMs();
        final pausedAt = current.pausedAtEpochMs ?? current.lastHeartbeatEpochMs;
        final addedPause = (now > pausedAt) ? (now - pausedAt) : 0;

        final updated = ActiveTimer(
          id: current.id,
          activityId: current.activityId,
          startedAtEpochMs: current.startedAtEpochMs,
          isPaused: false,
          pausedAtEpochMs: null,
          accumulatedPauseMs: current.accumulatedPauseMs + addedPause,
          currentComment: current.currentComment,
          initialTagIds: current.initialTagIds,
          lastHeartbeatEpochMs: now,
          revision: current.revision + 1,
        );

        await _db.setActiveTimer(updated);
        _updateActiveTimer(updated);
        _startHeartbeat();
        return updated;
      });

  /// Updates the comment of the running active timer in-place.
  /// Throws [StateError] if idle.
  Future<ActiveTimer> updateComment(String comment) => _synchronized(() async {
        await _ensureInitializedLocked();

        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer is currently running.');
        }

        final updated = current.copyWith(
          currentComment: comment,
          revision: current.revision + 1,
        );

        await _db.setActiveTimer(updated);
        _updateActiveTimer(updated);
        return updated;
      });

  /// Stops the active timer.
  /// Calculates final duration, inserts a new [Record] with tags, and deletes [ActiveTimer] in one transaction.
  /// Throws [StateError] if no active timer is running.
  Future<Record> stop({String? finalComment}) => _synchronized(() async {
        await _ensureInitializedLocked();

        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer is currently running.');
        }

        _stopHeartbeat();
        final now = _nowUtcMs();
        final duration = current.calculateDurationMs(now);
        final referenceEnd = (current.isPaused && current.pausedAtEpochMs != null)
            ? current.pausedAtEpochMs!
            : now;

        final record = Record(
          id: _generateId(),
          activityId: current.activityId,
          startedAtEpochMs: current.startedAtEpochMs,
          endedAtEpochMs: referenceEnd,
          durationMs: duration,
          comment: finalComment ?? current.currentComment,
          timezoneId: _getTimezoneId(),
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
          tagIds: current.initialTagIds,
        );

        await _db.db.transaction((txn) async {
          await txn.insert(
            'records',
            record.toMap(),
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
          for (final tagId in record.tagIds) {
            await txn.insert(
              'record_tags',
              {'record_id': record.id, 'tag_id': tagId},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await txn.delete('active_timer', where: 'id = 1');
        });

        _lastStoppedRecord = record;
        _updateActiveTimer(null);

        await _notifyRecordCommitted(record);
        return record;
      });

  /// Atomically switches tracking to [newActivityId] in a single SQLite transaction.
  /// Commits the existing session to `records` and starts tracking the new activity.
  Future<ActiveTimer> switchActivity(
    String newActivityId, {
    String comment = '',
    List<String> tagIds = const [],
  }) =>
      _synchronized(() async {
        await _ensureInitializedLocked();
        return _switchActivityLocked(
          newActivityId,
          comment: comment,
          tagIds: tagIds,
        );
      });

  Future<ActiveTimer> _switchActivityLocked(
    String newActivityId, {
    String comment = '',
    List<String> tagIds = const [],
  }) async {
    final activity = await _db.getActivityById(newActivityId);
    if (activity == null) {
      throw ArgumentError('Activity with id "$newActivityId" does not exist.');
    }

    _stopHeartbeat();
    final now = _nowUtcMs();
    final current = _activeTimerNotifier.value;

    Record? stoppedRecord;
    if (current != null) {
      final duration = current.calculateDurationMs(now);
      final referenceEnd = (current.isPaused && current.pausedAtEpochMs != null)
          ? current.pausedAtEpochMs!
          : now;

      stoppedRecord = Record(
        id: _generateId(),
        activityId: current.activityId,
        startedAtEpochMs: current.startedAtEpochMs,
        endedAtEpochMs: referenceEnd,
        durationMs: duration,
        comment: current.currentComment,
        timezoneId: _getTimezoneId(),
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
        tagIds: current.initialTagIds,
      );
    }

    final nextRevision = (current != null) ? current.revision + 1 : 1;
    final newTimer = ActiveTimer(
      id: 1,
      activityId: newActivityId,
      startedAtEpochMs: now,
      isPaused: false,
      pausedAtEpochMs: null,
      accumulatedPauseMs: 0,
      currentComment: comment,
      initialTagIds: List.unmodifiable(tagIds),
      lastHeartbeatEpochMs: now,
      revision: nextRevision,
    );

    await _db.db.transaction((txn) async {
      final committed = stoppedRecord;
      if (committed != null) {
        await txn.insert(
          'records',
          committed.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        for (final tagId in committed.tagIds) {
          await txn.insert(
            'record_tags',
            {'record_id': committed.id, 'tag_id': tagId},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      await txn.insert(
        'active_timer',
        newTimer.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _lastStoppedRecord = stoppedRecord;
    _updateActiveTimer(newTimer);
    _startHeartbeat();

    final committed = stoppedRecord;
    if (committed != null) {
      await _notifyRecordCommitted(committed);
    }
    return newTimer;
  }

  // ==========================================
  // Crash Recovery Actions
  // ==========================================

  /// Crash recovery: Continues tracking across the abnormal shutdown gap.
  Future<void> keepTracking() => _synchronized(() async {
        await _ensureInitializedLocked();
        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer to recover.');
        }

        final now = _nowUtcMs();
        final updated = current.copyWith(
          lastHeartbeatEpochMs: now,
          revision: current.revision + 1,
        );

        await _db.setActiveTimer(updated);
        _updateActiveTimer(updated);

        if (!updated.isPaused) {
          _startHeartbeat();
        }
      });

  /// Crash recovery: Truncates the session to the last recorded heartbeat and saves as a Record.
  Future<Record> truncateToHeartbeat({String? finalComment}) =>
      _synchronized(() async {
        await _ensureInitializedLocked();
        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer to truncate.');
        }

        _stopHeartbeat();
        final now = _nowUtcMs();
        final referenceEnd =
            (current.isPaused && current.pausedAtEpochMs != null)
                ? current.pausedAtEpochMs!
                : current.lastHeartbeatEpochMs;

        final rawDuration = referenceEnd -
            current.startedAtEpochMs -
            current.accumulatedPauseMs;
        final duration = rawDuration < 0 ? 0 : rawDuration;

        final record = Record(
          id: _generateId(),
          activityId: current.activityId,
          startedAtEpochMs: current.startedAtEpochMs,
          endedAtEpochMs: referenceEnd,
          durationMs: duration,
          comment: finalComment ?? current.currentComment,
          timezoneId: _getTimezoneId(),
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
          tagIds: current.initialTagIds,
        );

        await _db.db.transaction((txn) async {
          await txn.insert(
            'records',
            record.toMap(),
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
          for (final tagId in record.tagIds) {
            await txn.insert(
              'record_tags',
              {'record_id': record.id, 'tag_id': tagId},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await txn.delete('active_timer', where: 'id = 1');
        });

        _lastStoppedRecord = record;
        _updateActiveTimer(null);

        await _notifyRecordCommitted(record);
        return record;
      });

  /// Crash recovery: Discards the active timer without saving a Record.
  Future<void> discard() => _synchronized(() async {
        await _ensureInitializedLocked();
        final current = _activeTimerNotifier.value;
        if (current == null) {
          throw StateError('No active timer to discard.');
        }

        _stopHeartbeat();
        await _db.deleteActiveTimer();
        _updateActiveTimer(null);
      });

  // ==========================================
  // Heartbeat Loop Management
  // ==========================================

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      await tickHeartbeat();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Manually executes a heartbeat update checkpoint.
  /// Useful for explicit background worker pings and deterministic testing.
  Future<void> tickHeartbeat() async {
    final current = _activeTimerNotifier.value;
    if (current == null || current.isPaused) {
      _stopHeartbeat();
      return;
    }

    final now = _nowUtcMs();
    await _db.updateHeartbeat(now);
    final updated = current.copyWith(lastHeartbeatEpochMs: now);
    _updateActiveTimer(updated);
  }

  // ==========================================
  // Helpers & Cleanup
  // ==========================================

  Future<void> _ensureInitializedLocked() async {
    if (_isInitialized) return;
    final timer = await _db.getActiveTimer();
    _updateActiveTimer(timer);
    _isInitialized = true;
  }

  void _updateActiveTimer(ActiveTimer? timer) {
    if (_activeTimerNotifier.value != timer) {
      _activeTimerNotifier.value = timer;
      _timerStreamController.add(timer);
    }
  }

  Future<void> _notifyRecordCommitted(Record record) async {
    final engine = csvExportEngine;
    if (engine != null) {
      if (engine.debounceDuration == Duration.zero) {
        await engine.scheduleExport();
      } else {
        engine.scheduleExport();
      }
    }
    if (onRecordCommitted != null) {
      await onRecordCommitted!(record);
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      completer.complete();
      if (_lock == completer.future) {
        _lock = null;
      }
    }
  }

  /// Closes streams and timers. Does not close the injected database.
  void dispose() {
    _stopHeartbeat();
    _timerStreamController.close();
    _activeTimerNotifier.dispose();
  }
}
