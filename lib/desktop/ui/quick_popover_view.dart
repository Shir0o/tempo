import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/state/day_recorder.dart';
import '../../core/state/record_commands.dart';
import '../../core/time/timezone_id.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../../ui/helpers/ui_helpers.dart';
import '../../ui/theme/tempo_theme.dart';

/// The three-second window an undo bar offers after a label or Split.
const Duration _undoWindow = DayRecorder.defaultUndoGraceWindow;

class _UndoState {
  final String message;
  final DateTime deadline;

  /// Optional pieces for the "Logged X HH:MM–HH:MM" form of the bar.
  final String? subject;
  final String? range;

  /// False for a proposal waiting on the phone: there is no Record to undo yet.
  final bool undoable;

  const _UndoState({
    required this.message,
    required this.deadline,
    this.subject,
    this.range,
    this.undoable = true,
  });

  int get secondsLeft {
    final ms = deadline.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return 0;
    final seconds = (ms / 1000).ceil();
    return seconds > _undoWindow.inSeconds ? _undoWindow.inSeconds : seconds;
  }
}

/// Keyboard-navigable macOS Menu Bar Quick Popover View.
///
/// Implements the specification wireframe from:
/// `05-desktop-macos-menu-bar-and-automation-spec.md`
///
/// Keyboard hierarchy:
/// - `1`-`9`: Label the open Lap with pinned Activity N and dismiss popover.
/// - `Cmd + Enter`: Label the open Lap with the most recent Activity.
/// - `/`: Focuses the search input.
/// - `Escape`: Dismisses popover.
/// - `Cmd + O`: Opens the full window.
/// - `Cmd + Q`: Quits the application.
class QuickPopoverView extends StatefulWidget {
  /// The phone's always-running Lap. Null on the Mac, which reads the Lap from
  /// the replica and never opens one of its own.
  final DayRecorder? dayRecorder;
  final TempoDatabase database;

  /// Every mutation goes through this seam. Defaults to the phone's
  /// [PhoneRecordCommands]; the Mac passes [RemoteRecordCommands].
  final RecordCommands? commands;

  final bool enableTicker;
  final VoidCallback? onClose;
  final VoidCallback? onOpenFullWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;

  const QuickPopoverView({
    super.key,
    this.dayRecorder,
    required this.database,
    this.commands,
    this.enableTicker = true,
    this.onClose,
    this.onOpenFullWindow,
    this.onOpenSettings,
    this.onQuit,
  });

  @override
  State<QuickPopoverView> createState() => _QuickPopoverViewState();
}

class _QuickPopoverViewState extends State<QuickPopoverView> {
  late final RecordCommands _commands = widget.commands ?? _phoneCommands();

  /// The Lap read from the replica on a Mac, where no DayRecorder exists.
  Lap? _replicaLap;

  RecordCommands _phoneCommands() {
    final recorder = widget.dayRecorder;
    if (recorder == null) {
      throw StateError('QuickPopoverView needs commands or a DayRecorder.');
    }
    return PhoneRecordCommands(dayRecorder: recorder);
  }

  Lap? get _lap => widget.dayRecorder?.lap ?? _replicaLap;

  final FocusNode _rootFocusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _commentFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();

  Timer? _liveTicker;
  _UndoState? _undo;
  List<Activity> _pinnedActivities = [];
  List<Activity> _recentActivities = [];
  Map<String, int> _todayDurations = {};
  Map<String, Activity> _activitiesById = {};
  List<Record> _todayRecords = [];
  Color? _lastActivityColor;
  String? _lastActivityId;
  int _dayStartMs = 0;
  int _dayEndMs = 0;
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();

    widget.dayRecorder?.lapListenable.addListener(_onLapChanged);
    _onLapChanged();
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _liveTicker = null;
    widget.dayRecorder?.lapListenable.removeListener(_onLapChanged);
    _rootFocusNode.dispose();
    _searchFocusNode.dispose();
    _commentFocusNode.dispose();
    _searchController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _startLiveTicker() {
    if (!widget.enableTicker) return;
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_lap != null && mounted) {
        setState(() {
          if (_undo != null && _undo!.secondsLeft == 0) _undo = null;
        });
      } else {
        _liveTicker?.cancel();
        _liveTicker = null;
      }
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final allActivities = await widget.database.getAllActivities();
    final pinned = allActivities.where((a) => a.isPinned).toList();

    // Today's Records (local midnight to midnight), including one that began
    // yesterday and crossed midnight into today.
    final now = DateTime.now();
    final dayStartMs = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    final dayEndMs = DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).millisecondsSinceEpoch;
    final candidates = await widget.database.getRecords(
      startedAfter: dayStartMs - const Duration(days: 2).inMilliseconds,
      startedBefore: dayEndMs,
      orderBy: 'started_at_epoch_ms ASC',
    );
    final todayRecords = candidates
        .where(
          (r) => r.startedAtEpochMs < dayEndMs && r.endedAtEpochMs > dayStartMs,
        )
        .toList();

    final durations = <String, int>{};
    for (final r in todayRecords) {
      final activityId = r.activityId;
      if (activityId == null) continue;
      final int ms = math.max<int>(
        0,
        math.min(r.endedAtEpochMs, dayEndMs) -
            math.max<int>(r.startedAtEpochMs, dayStartMs),
      );
      durations[activityId] = (durations[activityId] ?? 0) + ms;
    }

    final everyActivity = {
      for (final a in await widget.database.getAllActivities(
        includeArchived: true,
      ))
        a.id: a,
    };
    final lastTracked = await widget.database.getRecords(
      trackedOnly: true,
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    final lastActivity = lastTracked.isEmpty
        ? null
        : everyActivity[lastTracked.first.activityId];

    // Determine recent activities from latest records
    final recentRecords = await widget.database.getRecords(limit: 30);
    final recentIds = <String>{};
    for (final r in recentRecords) {
      final activityId = r.activityId;
      if (activityId == null) continue;
      if (!pinned.any((p) => p.id == activityId)) {
        recentIds.add(activityId);
      }
    }

    // A Mac reads the Lap from the replica; it must never open one itself.
    final replicaLap = widget.dayRecorder == null
        ? await widget.database.getLap()
        : null;

    final recent = <Activity>[];
    for (final id in recentIds) {
      final act = await widget.database.getActivityById(id);
      if (act != null && !act.isArchived) {
        recent.add(act);
      }
      if (recent.length >= 5) break;
    }

    if (mounted) {
      setState(() {
        _pinnedActivities = pinned;
        _recentActivities = recent;
        _todayDurations = durations;
        _activitiesById = everyActivity;
        _todayRecords = todayRecords;
        _lastActivityColor = lastActivity == null
            ? null
            : UiHelpers.parseHexColor(lastActivity.colorHex);
        _lastActivityId = lastActivity?.id;
        _replicaLap = replicaLap;
        _dayStartMs = dayStartMs;
        _dayEndMs = dayEndMs;
        _isLoading = false;
      });
    }
  }

  Future<void> _onLapChanged() async {
    if (_lap != null) {
      _startLiveTicker();
    } else {
      _liveTicker?.cancel();
      _liveTicker = null;
    }
    if (mounted) setState(() {});
  }

  // ==========================================
  // Keyboard Handler
  // ==========================================

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final isCmdPressed = HardwareKeyboard.instance.isMetaPressed;

    // Escape: unfocus or close popover
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
        return KeyEventResult.handled;
      }
      if (_commentFocusNode.hasFocus) {
        _commentFocusNode.unfocus();
        return KeyEventResult.handled;
      }
      _closePopover();
      return KeyEventResult.handled;
    }

    // Cmd + Enter: Label the Lap with the most recent Activity
    if (isCmdPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _labelSameAsLast();
      return KeyEventResult.handled;
    }

    // Cmd + O: Open full window
    if (isCmdPressed && event.logicalKey == LogicalKeyboardKey.keyO) {
      _openFullWindow();
      return KeyEventResult.handled;
    }

    // Cmd + Q: Quit
    if (isCmdPressed && event.logicalKey == LogicalKeyboardKey.keyQ) {
      _quitApp();
      return KeyEventResult.handled;
    }

    // If focused on search input or comment input, allow normal typing
    if (_searchFocusNode.hasFocus || _commentFocusNode.hasFocus) {
      return KeyEventResult.ignored;
    }

    // '/' focuses search input
    if (event.logicalKey == LogicalKeyboardKey.slash) {
      _searchFocusNode.requestFocus();
      return KeyEventResult.handled;
    }

    // Space: Label the Lap with the most recent Activity
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _labelSameAsLast();
      return KeyEventResult.handled;
    }

    // Number keys 1-9: Label the open Lap with pinned Activity N
    final keyChar = event.logicalKey.keyLabel;
    if (keyChar.length == 1 && RegExp(r'^[1-9]$').hasMatch(keyChar)) {
      final idx = int.parse(keyChar) - 1;
      if (idx < _pinnedActivities.length) {
        _labelWith(_pinnedActivities[idx]);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  // ==========================================
  // Actions
  // ==========================================

  Future<void> _labelWith(Activity activity) async {
    final comment = _commentController.text.trim();
    final record = await _commands.label(activity.id, comment: comment);
    _commentController.clear();
    await _loadData();
    if (record == null) {
      _showPending('${activity.name} is waiting for the phone');
      return;
    }
    _showUndo('Logged ${activity.name}', record, subject: activity.name);
  }

  Future<void> _labelSameAsLast() async {
    final lastId = _lastActivityId;
    if (lastId == null) return;
    final record = await _commands.label(lastId);
    _commentController.clear();
    await _loadData();
    if (record == null) {
      _showPending(
        '${_activitiesById[lastId]?.name ?? 'Same as last'} is waiting for '
        'the phone',
      );
      return;
    }
    _showUndo(
      'Logged same as last',
      record,
      subject: _activitiesById[record.activityId]?.name,
    );
  }

  Future<void> _split() async {
    final record = await _commands.split();
    await _loadData();
    if (record == null) {
      _showPending('The split is waiting for the phone');
      return;
    }
    _showUndo('Split at the current time', record);
  }

  Future<void> _undoLast() async {
    final undone = await _commands.undo();
    if (!mounted) return;
    setState(() => _undo = null);
    if (undone) {
      await _loadData();
    }
  }

  /// A proposal with no answer yet: state where it went, and offer no Undo
  /// because there is no Record to reverse.
  void _showPending(String message) {
    if (!mounted) return;
    setState(() {
      _undo = _UndoState(
        message: message,
        deadline: DateTime.now().add(_undoWindow),
        undoable: false,
      );
    });
  }

  void _showUndo(String message, Record record, {String? subject}) {
    if (!mounted) return;
    final fmt = DateFormat('HH:mm');
    final range =
        '${fmt.format(wallClockAt(record.timezoneId, record.startedAtEpochMs))}'
        '–${fmt.format(wallClockAt(record.endTimezoneId, record.endedAtEpochMs))}';
    setState(() {
      _undo = _UndoState(
        message: message,
        deadline: DateTime.now().add(_undoWindow),
        subject: subject,
        range: range,
      );
    });
  }

  void _closePopover() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      const MethodChannel('com.tempos.tracker/menubar')
          .invokeMethod('closeWindow')
          .catchError((_) => null);
    }
  }

  void _openFullWindow() {
    if (widget.onOpenFullWindow != null) {
      widget.onOpenFullWindow!();
    } else {
      const MethodChannel('com.tempos.tracker/menubar')
          .invokeMethod('openFullWindow')
          .catchError((_) => null);
    }
  }

  void _quitApp() {
    if (widget.onQuit != null) {
      widget.onQuit!();
    } else {
      SystemNavigator.pop();
    }
  }

  Future<void> _onSearchSubmitted(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    // Check if matches existing activity
    final all = await widget.database.getAllActivities(includeArchived: true);
    for (final a in all) {
      if (a.name.toLowerCase() == trimmed.toLowerCase()) {
        await _labelWith(a);
        _searchController.clear();
        setState(() => _searchQuery = '');
        return;
      }
    }

    // A replica has no way to propose a new Activity; only the phone's
    // DayRecorder can create one and publish it.
    if (widget.dayRecorder == null) {
      _showPending('Create “$trimmed” on the phone, then label it here');
      return;
    }

    // Create and start new activity
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final newActivity = Activity(
      id: const Uuid().v4(),
      name: trimmed,
      colorHex: '#4CAF50',
      iconName: 'schedule',
      isPinned: false,
      sortOrder: all.length,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );
    await widget.database.insertActivity(newActivity);
    await _labelWith(newActivity);
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  // ==========================================
  // Formatting Helpers
  // ==========================================

  String _formatElapsedDuration(int durationMs) {
    final dur = Duration(milliseconds: durationMs);
    final mm = dur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = dur.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${dur.inHours}:$mm:$ss';
  }

  String _formatTodayTotal(int durationMs) {
    if (durationMs <= 0) return '—';
    final minutes = (durationMs / 60000).round();
    final hours = minutes ~/ 60;
    final remMin = minutes % 60;
    return hours > 0 ? '${hours}h ${remMin}m' : '${remMin}m';
  }

  List<DayStripSpan> _buildStripSpans() {
    final dayLength = _dayEndMs - _dayStartMs;
    if (dayLength <= 0) return const [];
    double fraction(int epochMs) =>
        ((epochMs - _dayStartMs) / dayLength).clamp(0.0, 1.0);

    final spans = <DayStripSpan>[];
    for (final r in _todayRecords) {
      final start = fraction(r.startedAtEpochMs);
      final end = math.max(fraction(r.endedAtEpochMs), start);
      final activity = _activitiesById[r.activityId];
      spans.add(
        DayStripSpan(
          start: start,
          end: end,
          color: activity == null
              ? TempoColors.track
              : UiHelpers.parseHexColor(activity.colorHex),
          hatched: activity == null,
          semanticsLabel: activity?.name ?? 'Untracked',
          marksZoneChange: r.crossesTimezones,
        ),
      );
    }
    final lap = _lap;
    if (lap != null) {
      final start = fraction(lap.startedAtEpochMs);
      final end = fraction(DateTime.now().toUtc().millisecondsSinceEpoch);
      spans.add(
        DayStripSpan(
          start: start,
          end: math.max(end, start),
          color: TempoColors.ink,
          hatched: false,
          semanticsLabel: 'Untracked',
        ),
      );
    }
    return spans;
  }

  // ==========================================
  // Build Methods
  // ==========================================

  @override
  Widget build(BuildContext context) {
    final lap = _lap;
    final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final elapsedMs = lap?.elapsedMs(nowUtc) ?? 0;

    return Focus(
      focusNode: _rootFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Container(
        width: 360,
        constraints: const BoxConstraints(maxHeight: 600),
        decoration: BoxDecoration(
          color: TempoColors.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TempoColors.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (lap != null) _buildLapPanel(lap, elapsedMs),
              Flexible(
                child: _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TempoColors.accent,
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        children: [
                          _buildSearchInput(),
                          const SizedBox(height: 6),
                          _buildOnTodaySection(),
                          if (_recentActivities.isNotEmpty &&
                              _searchQuery.isEmpty) ...[
                            const SizedBox(height: 8),
                            _buildRecentActivitiesSection(),
                          ],
                          if (lap != null) ...[
                            const SizedBox(height: 8),
                            _buildNoteField(),
                          ],
                        ],
                      ),
              ),
              if (_undo != null) _buildUndoBar(_undo!),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLapPanel(Lap lap, int elapsedMs) {
    final since = DateFormat('HH:mm').format(
      wallClockAt(lap.startTimezoneOr(localTimezoneId()), lap.startedAtEpochMs),
    );
    final dotColor = _lastActivityColor ?? TempoColors.accent;
    final pillShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(TempoRadii.pill),
    );

    return Container(
      decoration: const BoxDecoration(
        color: TempoColors.panel,
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(TempoRadii.block),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: const HatchPainter(spacing: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      'Untracked since $since',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TempoText.title.copyWith(
                        color: TempoColors.ink,
                        fontSize: 22,
                        letterSpacing: -0.66,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('EEE d MMM').format(DateTime.now()),
                    style: TempoText.label.copyWith(
                      color: TempoColors.ink,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _formatElapsedDuration(elapsedMs),
                style: TempoText.numeral.copyWith(
                  color: TempoColors.ink,
                  fontSize: 44,
                  letterSpacing: -2.2,
                  height: 1,
                ),
              ),
              const SizedBox(height: 10),
              if (_dayEndMs > _dayStartMs)
                SizedBox(
                  height: 10,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: CustomPaint(
                      painter: DayStripPainter(
                        spans: _buildStripSpans(),
                        trackColor: TempoColors.paper,
                        markerColor: TempoColors.ink,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _split,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TempoColors.ink,
                      side: const BorderSide(color: TempoColors.ink, width: 2),
                      minimumSize: const Size(0, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: pillShape,
                      textStyle: TempoText.label.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: const Text('Split'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _labelSameAsLast,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: TempoColors.ink,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(double.infinity, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: pillShape,
                        textStyle: TempoText.label.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: dotColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Flexible(
                            child: Text(
                              'Same as last',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '⌘↩',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint, {Widget? suffix}) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: TempoColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintText: hint,
      hintStyle: TempoText.body.copyWith(
        color: TempoColors.textMuted,
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      suffixIcon: suffix,
      suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
    );
  }

  Widget _keyBadge(String label, {bool selected = false}) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? TempoColors.accent : TempoColors.line,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TempoText.numeral.copyWith(
          color: selected ? TempoColors.ink : TempoColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildNoteField() {
    // Inline editable comment field, applied to the next label.
    return TextField(
      focusNode: _commentFocusNode,
      controller: _commentController,
      style: TempoText.body.copyWith(color: Colors.white, fontSize: 14),
      cursorColor: TempoColors.accent,
      decoration: _fieldDecoration('Add a note'),
    );
  }

  Widget _buildUndoBar(_UndoState undo) {
    final baseStyle = TempoText.label.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w400,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: TempoColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: undo.subject != null && undo.range != null
                ? Text.rich(
                    TextSpan(
                      style: baseStyle,
                      children: [
                        const TextSpan(text: 'Logged '),
                        TextSpan(
                          text: undo.subject,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: ' ${undo.range}'),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    undo.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: baseStyle,
                  ),
          ),
          TextButton(
            onPressed: undo.undoable ? _undoLast : null,
            style: TextButton.styleFrom(
              foregroundColor: TempoColors.accent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: TempoText.label.copyWith(fontWeight: FontWeight.w700),
            ),
            child: undo.undoable
                ? Text('Undo · ${undo.secondsLeft}')
                : const Text('Pending'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchInput() {
    return TextField(
      focusNode: _searchFocusNode,
      controller: _searchController,
      onChanged: (val) => setState(() => _searchQuery = val),
      onSubmitted: _onSearchSubmitted,
      style: TempoText.body.copyWith(color: Colors.white, fontSize: 14),
      cursorColor: TempoColors.accent,
      decoration: _fieldDecoration(
        'What was it? Search or add',
        suffix: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _searchQuery.isNotEmpty
              ? InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(
                      Icons.clear,
                      size: 16,
                      color: TempoColors.textMuted,
                    ),
                  ),
                )
              : _keyBadge('/'),
        ),
      ),
    );
  }

  Widget _buildSectionHeading(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Text(
        text.toUpperCase(),
        style: TempoText.overline.copyWith(
          color: TempoColors.textMuted,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildOnTodaySection() {
    final filtered = _searchQuery.isEmpty
        ? _pinnedActivities
        : _pinnedActivities
              .where(
                (a) =>
                    a.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeading('On Today'),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              _searchQuery.isNotEmpty
                  ? '+ Press Enter to create "${_searchQuery.trim()}"'
                  : 'No pinned activities yet.',
              style: TempoText.label.copyWith(
                color: _searchQuery.isNotEmpty
                    ? TempoColors.accent
                    : TempoColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++)
            _buildActivityRow(
              filtered[i],
              hotkeyNumber: i < 9 ? i + 1 : null,
              selected: i == 0,
            ),
      ],
    );
  }

  Widget _buildActivityRow(
    Activity activity, {
    int? hotkeyNumber,
    bool selected = false,
    bool showBadge = true,
  }) {
    final total = _formatTodayTotal(_todayDurations[activity.id] ?? 0);

    return Material(
      color: selected ? TempoColors.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _labelWith(activity),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              if (showBadge && hotkeyNumber != null)
                _keyBadge('$hotkeyNumber', selected: selected)
              else
                const SizedBox(width: 22),
              const SizedBox(width: 10),
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: UiHelpers.parseHexColor(activity.colorHex),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  activity.name,
                  style: TempoText.body.copyWith(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                total,
                style: TempoText.numeral.copyWith(
                  color: TempoColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentActivitiesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeading('Recent'),
        for (final act in _recentActivities)
          _buildActivityRow(act, showBadge: false),
      ],
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: _buildFooterButton('⌘O', 'Open', _openFullWindow)),
          Flexible(
            child: _buildFooterButton('⌘,', 'Settings', () {
              widget.onOpenSettings?.call();
            }),
          ),
          Flexible(child: _buildFooterButton('⌘Q', 'Quit', _quitApp)),
        ],
      ),
    );
  }

  Widget _buildFooterButton(String hotkey, String label, VoidCallback onTap) {
    final style = TempoText.label.copyWith(
      color: TempoColors.textMuted,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          label.isEmpty ? hotkey : '$label  $hotkey',
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
