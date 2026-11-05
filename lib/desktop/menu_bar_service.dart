import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/state/day_recorder.dart';
import '../core/state/record_commands.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';

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
/// - Listens to [DayRecorder.lapListenable] when a read surface is supplied.
/// - Formats title string across full, compact, minimal and bracket modes,
///   showing the open Lap's elapsed time.
/// - 1-second in-memory duration ticker without SQLite I/O.
/// - Bridges to native AppKit via method channel `com.tempos.tracker/menubar`.
class MenuBarService {
  static const String channelName = 'com.tempos.tracker/menubar';

  /// The seam every mutation goes through: [PhoneRecordCommands] on the phone,
  /// [RemoteRecordCommands] on the Mac's replica.
  final RecordCommands commands;

  /// The open Lap's read surface. Optional: a replica may not have one.
  final DayRecorder? dayRecorder;

  /// Where "same as last" finds the previous Activity. Optional so a preview
  /// build without a store can still show the status item.
  final TempoDatabase? database;

  final MethodChannel _channel;
  final int Function() _nowUtcMs;

  StatusDisplayMode _displayMode = StatusDisplayMode.full;
  bool includeBrackets = true;
  Timer? _tickerTimer;

  /// The Lap read from the replica when no [DayRecorder] is supplied.
  Lap? _replicaLap;
  int _ticksSinceLapRead = 0;

  /// Re-checks an empty replica for its first Lap; cancelled once one arrives.
  Timer? _replicaLapTimer;

  /// How often the replica's Lap is re-read: once a minute, one indexed row.
  static const int _replicaReadTicks = 60;

  VoidCallback? onOpenFullWindow;

  final ValueNotifier<String> _titleNotifier = ValueNotifier<String>('[⏱️]');

  MenuBarService({
    required this.commands,
    this.dayRecorder,
    this.database,
    MethodChannel? channel,
    int Function()? nowUtcMs,
    StatusDisplayMode initialMode = StatusDisplayMode.full,
    this.includeBrackets = true,
    this.onOpenFullWindow,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _displayMode = initialMode {
    _initChannelHandler();
    dayRecorder?.lapListenable.addListener(_onLapChanged);
    if (dayRecorder == null) {
      unawaited(refreshLap());
    } else {
      _onLapChanged();
    }
  }

  /// Re-reads the open Lap from the replica. Call after a pull so a label made
  /// on the phone moves the menu bar without waiting for the minute's refresh.
  Future<void> refreshLap() async {
    final db = database;
    if (db == null) return;
    final lap = await db.getLap();
    final current = _replicaLap;
    if (current?.startedAtEpochMs == lap?.startedAtEpochMs &&
        current?.revision == lap?.revision) {
      return;
    }
    _replicaLap = lap;
    if (lap != null) {
      _replicaLapTimer?.cancel();
      _replicaLapTimer = null;
    }
    await _onLapChanged();
  }

  /// While a replica has no Lap yet (before its first pull), look again every
  /// half minute instead of staying idle until the app is reopened.
  void _scheduleReplicaLapCheck() {
    if (dayRecorder != null || database == null) return;
    if (_lap != null || _replicaLapTimer != null) return;
    _replicaLapTimer = Timer(const Duration(seconds: 30), () async {
      _replicaLapTimer = null;
      await refreshLap();
      _scheduleReplicaLapCheck();
    });
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
  /// is only an elapsed-time readout.
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
          if (action == 'labelSameAsLast') {
            await _labelSameAsLast();
          } else if (action == 'openFullWindow') {
            onOpenFullWindow?.call();
          }
          break;
      }
    });
  }

  Future<void> _labelSameAsLast() async {
    // The menu bar only labels the open Lap, with the previous Activity. The
    // proposal goes through the seam so a replica queues it instead of writing.
    final db = database;
    if (db == null) return;
    final last = await db.getRecords(
      trackedOnly: true,
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    final activityId = last.isEmpty ? null : last.first.activityId;
    if (activityId == null) return;
    await commands.label(activityId);
  }

  Lap? get _lap => dayRecorder?.lap ?? _replicaLap;

  Future<void> _onLapChanged() async {
    final lap = _lap;
    if (lap == null) {
      _stopTicker();
      if (dayRecorder == null) _scheduleReplicaLapCheck();
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
    if (dayRecorder == null && ++_ticksSinceLapRead >= _replicaReadTicks) {
      _ticksSinceLapRead = 0;
      unawaited(refreshLap());
    }
    final lap = _lap;
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
    final lap = _lap;
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
    _replicaLapTimer?.cancel();
    _replicaLapTimer = null;
    dayRecorder?.lapListenable.removeListener(_onLapChanged);
    _titleNotifier.dispose();
  }
}
