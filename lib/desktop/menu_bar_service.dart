import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/state/day_recorder.dart';

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
/// - Listens to [DayRecorder.lapListenable].
/// - Formats title string across full, compact, minimal and bracket modes,
///   showing the open Lap's elapsed time.
/// - 1-second in-memory duration ticker without SQLite I/O.
/// - Bridges to native AppKit via method channel `com.tempos.tracker/menubar`.
class MenuBarService {
  static const String channelName = 'com.tempos.tracker/menubar';

  final DayRecorder dayRecorder;
  final MethodChannel _channel;
  final int Function() _nowUtcMs;

  StatusDisplayMode _displayMode = StatusDisplayMode.full;
  bool includeBrackets = true;
  Timer? _tickerTimer;

  VoidCallback? onToggleQuickMenu;
  VoidCallback? onOpenFullWindow;

  final ValueNotifier<String> _titleNotifier = ValueNotifier<String>('[⏱️]');

  MenuBarService({
    required this.dayRecorder,
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
    dayRecorder.lapListenable.addListener(_onLapChanged);
    _onLapChanged();
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
  /// The menu bar always shows the open Lap, which is unlabelled, so the title
  /// is only an elapsed-time readout. There is no pause or stop state.
  ///
  /// Examples:
  /// - Idle: `[⏱️]`
  /// - Open Lap:
  ///   - Full: `[🟢 01:24]`
  ///   - Compact: `[🟢 01:24]`
  ///   - Minimal: `[🟢]`
  static String formatTitle({
    required StatusDisplayMode mode,
    required bool isIdle,
    Duration elapsed = Duration.zero,
    bool brackets = true,
  }) {
    if (isIdle) {
      return brackets ? '[⏱️]' : '⏱️';
    }

    const indicator = '🟢';
    final timeStr = formatDurationHHMM(elapsed);

    String content;
    switch (mode) {
      case StatusDisplayMode.full:
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
              await _labelSameAsLast();
            }
          } else if (action == 'openFullWindow') {
            onOpenFullWindow?.call();
          }
          break;
      }
    });
  }

  Future<void> _labelSameAsLast() async {
    // The menu bar only labels the Lap; it never starts, stops, or pauses it.
    await dayRecorder.sameAsLast();
  }

  Future<void> _onLapChanged() async {
    final lap = dayRecorder.lap;
    if (lap == null) {
      _stopTicker();
      await _refreshTitle();
      return;
    }

    await _refreshTitle();
    _startTicker();
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
    final lap = dayRecorder.lap;
    if (lap == null) {
      _stopTicker();
      return;
    }

    final elapsedMs = lap.elapsedMs(_nowUtcMs());
    final elapsed = Duration(milliseconds: elapsedMs);
    final title = formatTitle(
      mode: _displayMode,
      isIdle: false,
      elapsed: elapsed,
      brackets: includeBrackets,
    );

    _updateTitle(title, isTracking: true);
  }

  Future<void> _refreshTitle() async {
    final lap = dayRecorder.lap;
    if (lap == null) {
      final title = formatTitle(
        mode: _displayMode,
        isIdle: true,
        brackets: includeBrackets,
      );
      _updateTitle(title, isTracking: false);
      return;
    }

    final elapsedMs = lap.elapsedMs(_nowUtcMs());
    final elapsed = Duration(milliseconds: elapsedMs);
    final title = formatTitle(
      mode: _displayMode,
      isIdle: false,
      elapsed: elapsed,
      brackets: includeBrackets,
    );

    _updateTitle(title, isTracking: true);
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
    dayRecorder.lapListenable.removeListener(_onLapChanged);
    _titleNotifier.dispose();
  }
}
