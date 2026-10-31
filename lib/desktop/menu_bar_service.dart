import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/state/timer_state_machine.dart';
import '../data/database/tempo_database.dart';

/// Display format modes for the macOS menu bar status item.
enum StatusDisplayMode {
  full,
  compact,
  minimal;

  static StatusDisplayMode fromString(String mode) {
    switch (mode.toLowerCase()) {
      case 'compact':
        return StatusDisplayMode.compact;
      case 'minimal':
        return StatusDisplayMode.minimal;
      case 'full':
      default:
        return StatusDisplayMode.full;
    }
  }
}

/// Service managing the macOS menu bar status item (`NSStatusItem`).
///
/// Features:
/// - Listens to [TimerStateMachine.activeTimerNotifier].
/// - Formats title string across full, compact, minimal, idle, and paused states.
/// - 1-second in-memory duration ticker without SQLite I/O during active tracking.
/// - Bridges to native AppKit via method channel `com.shir0o.tempo/menubar`.
class MenuBarService {
  static const String channelName = 'com.shir0o.tempo/menubar';

  final TimerStateMachine timerStateMachine;
  final TempoDatabase database;
  final MethodChannel _channel;
  final int Function() _nowUtcMs;

  StatusDisplayMode _displayMode = StatusDisplayMode.full;
  bool includeBrackets = true;
  Timer? _tickerTimer;
  String? _currentActivityId;
  String? _currentActivityName;

  VoidCallback? onToggleQuickMenu;
  VoidCallback? onOpenFullWindow;

  final ValueNotifier<String> _titleNotifier = ValueNotifier<String>('[⏱️]');

  MenuBarService({
    required this.timerStateMachine,
    required this.database,
    MethodChannel? channel,
    int Function()? nowUtcMs,
    StatusDisplayMode initialMode = StatusDisplayMode.full,
    this.includeBrackets = true,
    this.onToggleQuickMenu,
    this.onOpenFullWindow,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _displayMode = initialMode {
    _initChannelHandler();
    timerStateMachine.activeTimerNotifier.addListener(_onActiveTimerChanged);
    _onActiveTimerChanged();
  }

  // ==========================================
  // Public Properties
  // ==========================================

  StatusDisplayMode get displayMode => _displayMode;
  ValueListenable<String> get titleListenable => _titleNotifier;
  String get currentTitle => _titleNotifier.value;

  // ==========================================
  // Display Mode & Preferences
  // ==========================================

  /// Sets the display mode (full, compact, minimal) and refreshes the title.
  Future<void> setDisplayMode(StatusDisplayMode mode) async {
    _displayMode = mode;
    try {
      await _channel.invokeMethod('setStatusDisplayMode', {'mode': mode.name});
    } catch (_) {}
    await _refreshTitle();
  }

  /// Sets whether square brackets wrap the title (e.g. `[🟢 01:24]` vs `🟢 01:24`).
  Future<void> setIncludeBrackets(bool include) async {
    includeBrackets = include;
    await _refreshTitle();
  }

  // ==========================================
  // Pure Static Title Formatting
  // ==========================================

  /// Formats duration as `HH:MM`.
  static String formatDurationHHMM(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// Pure formatter for the menu bar title string.
  ///
  /// Examples:
  /// - Idle: `[⏱️]`
  /// - Active Tracking:
  ///   - Full: `[🟢 01:24 Coding]`
  ///   - Compact: `[🟢 01:24]`
  ///   - Minimal: `[🟢]`
  /// - Paused:
  ///   - Full: `[⏸️ 01:24 Coding]`
  ///   - Compact: `[⏸️ 01:24]`
  ///   - Minimal: `[⏸️]`
  static String formatTitle({
    required StatusDisplayMode mode,
    required bool isIdle,
    bool isPaused = false,
    String? activityName,
    Duration elapsed = Duration.zero,
    bool brackets = true,
  }) {
    if (isIdle) {
      return brackets ? '[⏱️]' : '⏱️';
    }

    final indicator = isPaused ? '⏸️' : '🟢';
    final timeStr = formatDurationHHMM(elapsed);
    final nameStr = activityName != null && activityName.isNotEmpty
        ? ' $activityName'
        : '';

    String content;
    switch (mode) {
      case StatusDisplayMode.full:
        content = '$indicator $timeStr$nameStr';
        break;
      case StatusDisplayMode.compact:
        content = '$indicator $timeStr';
        break;
      case StatusDisplayMode.minimal:
        content = indicator;
        break;
    }

    return brackets ? '[$content]' : content;
  }

  // ==========================================
  // Internal State & Live Ticker
  // ==========================================

  void _initChannelHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onQuickMenuAction':
          final args = call.arguments;
          final action = (args is Map) ? args['action'] as String? : null;
          if (action == 'toggle') {
            if (onToggleQuickMenu != null) {
              onToggleQuickMenu!();
            } else {
              await _defaultToggle();
            }
          } else if (action == 'openFullWindow') {
            onOpenFullWindow?.call();
          }
          break;
      }
    });
  }

  Future<void> _defaultToggle() async {
    final active = timerStateMachine.activeTimer;
    if (active == null) {
      // Idle: start first pinned habit or default
      final activities = await database.getAllActivities();
      if (activities.isNotEmpty) {
        final pinned = activities.firstWhere(
          (a) => a.isPinned,
          orElse: () => activities.first,
        );
        await timerStateMachine.start(pinned.id);
      }
    } else if (active.isPaused) {
      await timerStateMachine.resume();
    } else {
      await timerStateMachine.pause();
    }
  }

  Future<void> _onActiveTimerChanged() async {
    final timer = timerStateMachine.activeTimer;

    if (timer == null) {
      _stopTicker();
      _currentActivityId = null;
      _currentActivityName = null;
      await _refreshTitle();
      return;
    }

    // Cache activity name on change
    if (timer.activityId != _currentActivityId) {
      _currentActivityId = timer.activityId;
      final act = await database.getActivityById(timer.activityId);
      _currentActivityName = act?.name ?? '';
    }

    if (timer.isPaused) {
      _stopTicker();
      await _refreshTitle();
    } else {
      await _refreshTitle();
      _startTicker();
    }
  }

  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onSecondTick();
    });
  }

  void _stopTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = null;
  }

  /// 1-second in-memory tick: Evaluates elapsed time from UTC epoch math without SQLite queries.
  void _onSecondTick() {
    final timer = timerStateMachine.activeTimer;
    if (timer == null || timer.isPaused) {
      _stopTicker();
      return;
    }

    final elapsedMs = timer.calculateDurationMs(_nowUtcMs());
    final elapsed = Duration(milliseconds: elapsedMs);
    final title = formatTitle(
      mode: _displayMode,
      isIdle: false,
      isPaused: false,
      activityName: _currentActivityName,
      elapsed: elapsed,
      brackets: includeBrackets,
    );

    _updateTitle(title, isTracking: true);
  }

  Future<void> _refreshTitle() async {
    final timer = timerStateMachine.activeTimer;
    if (timer == null) {
      final title = formatTitle(
        mode: _displayMode,
        isIdle: true,
        brackets: includeBrackets,
      );
      _updateTitle(title, isTracking: false);
      return;
    }

    final elapsedMs = timer.calculateDurationMs(_nowUtcMs());
    final elapsed = Duration(milliseconds: elapsedMs);
    final title = formatTitle(
      mode: _displayMode,
      isIdle: false,
      isPaused: timer.isPaused,
      activityName: _currentActivityName,
      elapsed: elapsed,
      brackets: includeBrackets,
    );

    _updateTitle(title, isTracking: !timer.isPaused);
  }

  void _updateTitle(String title, {required bool isTracking}) {
    if (_titleNotifier.value != title) {
      _titleNotifier.value = title;
    }
    try {
      _channel.invokeMethod('updateStatusItem', {
        'title': title,
        'isTracking': isTracking,
      });
    } catch (_) {}
  }

  /// Closes ticker and cleans up notifiers.
  void dispose() {
    _stopTicker();
    timerStateMachine.activeTimerNotifier.removeListener(_onActiveTimerChanged);
    _titleNotifier.dispose();
  }
}
