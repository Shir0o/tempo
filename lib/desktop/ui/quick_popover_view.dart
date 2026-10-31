import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/state/timer_state_machine.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';

/// Keyboard-navigable macOS Menu Bar Quick Popover View.
///
/// Implements the specification wireframe from:
/// `05-desktop-macos-menu-bar-and-automation-spec.md`
///
/// Keyboard hierarchy:
/// - `1`-`9`: Quick start pinned habit N and dismiss popover.
/// - `Space`: Toggles Pause/Resume on active timer.
/// - `Cmd + Enter`: Stops active timer.
/// - `/`: Focuses the search input.
/// - `Escape`: Dismisses popover.
/// - `Cmd + O`: Opens the full window.
/// - `Cmd + Q`: Quits the application.
class QuickPopoverView extends StatefulWidget {
  final TimerStateMachine timerStateMachine;
  final TempoDatabase database;
  final bool enableTicker;
  final VoidCallback? onClose;
  final VoidCallback? onOpenFullWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;

  const QuickPopoverView({
    super.key,
    required this.timerStateMachine,
    required this.database,
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
  final FocusNode _rootFocusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _commentFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();

  Timer? _liveTicker;
  List<Activity> _pinnedActivities = [];
  List<Activity> _recentActivities = [];
  Map<String, int> _weeklyDurations = {};
  Activity? _activeActivity;
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();

    widget.timerStateMachine.activeTimerNotifier.addListener(
      _onActiveTimerChanged,
    );
    _onActiveTimerChanged();
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _liveTicker = null;
    widget.timerStateMachine.activeTimerNotifier.removeListener(
      _onActiveTimerChanged,
    );
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
      if (widget.timerStateMachine.isTracking && mounted) {
        setState(() {});
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

    // Compute weekly durations from records since start of week
    final startOfWeekMs = _getStartOfWeekEpochMs();
    final weekRecords = await widget.database.getRecords(
      startedAfter: startOfWeekMs,
    );

    final durations = <String, int>{};
    for (final r in weekRecords) {
      durations[r.activityId] = (durations[r.activityId] ?? 0) + r.durationMs;
    }

    // Determine recent activities from latest records
    final recentRecords = await widget.database.getRecords(limit: 30);
    final recentIds = <String>{};
    for (final r in recentRecords) {
      if (!pinned.any((p) => p.id == r.activityId)) {
        recentIds.add(r.activityId);
      }
    }

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
        _weeklyDurations = durations;
        _isLoading = false;
      });
    }
  }

  int _getStartOfWeekEpochMs() {
    final now = DateTime.now();
    final daysSinceMonday = (now.weekday - 1);
    final monday = DateTime(now.year, now.month, now.day - daysSinceMonday);
    return monday.toUtc().millisecondsSinceEpoch;
  }

  Future<void> _onActiveTimerChanged() async {
    final active = widget.timerStateMachine.activeTimer;
    if (active == null) {
      _liveTicker?.cancel();
      _liveTicker = null;
      _activeActivity = null;
      _commentController.text = '';
    } else {
      _commentController.text = active.currentComment;
      final act = await widget.database.getActivityById(active.activityId);
      if (mounted) {
        setState(() {
          _activeActivity = act;
        });
      }
      if (!active.isPaused && _liveTicker == null) {
        _startLiveTicker();
      } else if (active.isPaused) {
        _liveTicker?.cancel();
        _liveTicker = null;
      }
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

    // Cmd + Enter: Stop active timer
    if (isCmdPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      if (widget.timerStateMachine.activeTimer != null) {
        _stopTimer();
        return KeyEventResult.handled;
      }
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

    // Space: Toggle pause / resume
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePauseResume();
      return KeyEventResult.handled;
    }

    // Number keys 1-9: Start pinned habit
    final keyChar = event.logicalKey.keyLabel;
    if (keyChar.length == 1 && RegExp(r'^[1-9]$').hasMatch(keyChar)) {
      final idx = int.parse(keyChar) - 1;
      if (idx < _pinnedActivities.length) {
        _startHabit(_pinnedActivities[idx]);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  // ==========================================
  // Actions
  // ==========================================

  Future<void> _startHabit(Activity activity) async {
    await widget.timerStateMachine.start(activity.id);
    await _loadData();
  }

  Future<void> _togglePauseResume() async {
    final active = widget.timerStateMachine.activeTimer;
    if (active == null) {
      if (_pinnedActivities.isNotEmpty) {
        await _startHabit(_pinnedActivities.first);
      }
    } else if (active.isPaused) {
      await widget.timerStateMachine.resume();
    } else {
      await widget.timerStateMachine.pause();
    }
  }

  Future<void> _stopTimer() async {
    if (widget.timerStateMachine.activeTimer == null) return;
    final comment = _commentController.text.trim();
    await widget.timerStateMachine.stop(
      finalComment: comment.isNotEmpty ? comment : null,
    );
    await _loadData();
  }

  void _onCommentChanged(String val) {
    if (widget.timerStateMachine.activeTimer != null) {
      widget.timerStateMachine.updateComment(val);
    }
  }

  void _closePopover() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      const MethodChannel('com.tempo.tracker/menubar')
          .invokeMethod('closeWindow')
          .catchError((_) => null);
    }
  }

  void _openFullWindow() {
    if (widget.onOpenFullWindow != null) {
      widget.onOpenFullWindow!();
    } else {
      const MethodChannel('com.tempo.tracker/menubar')
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
        await _startHabit(a);
        _searchController.clear();
        setState(() => _searchQuery = '');
        return;
      }
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
    await _startHabit(newActivity);
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  // ==========================================
  // Formatting Helpers
  // ==========================================

  String _formatElapsedDuration(int durationMs) {
    final dur = Duration(milliseconds: durationMs);
    final hours = dur.inHours;
    final minutes = dur.inMinutes.remainder(60);
    final seconds = dur.inSeconds.remainder(60);
    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String _formatWeeklySummary(int durationMs) {
    final minutes = (durationMs / 60000).round();
    final hours = minutes ~/ 60;
    final remMin = minutes % 60;
    if (hours > 0) {
      return '${hours}h ${remMin.toString().padLeft(2, '0')}m/wk';
    } else {
      return '${remMin}m/wk';
    }
  }

  // ==========================================
  // Build Methods
  // ==========================================

  @override
  Widget build(BuildContext context) {
    final activeTimer = widget.timerStateMachine.activeTimer;
    final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final elapsedMs = activeTimer?.calculateDurationMs(nowUtc) ?? 0;

    return Focus(
      focusNode: _rootFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Container(
        width: 380,
        constraints: const BoxConstraints(maxHeight: 600),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E24),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Active Timer Banner (if active)
              if (activeTimer != null) ...[
                _buildActiveTimerBanner(activeTimer, elapsedMs),
                const Divider(height: 1, color: Colors.white12),
              ],

              // Search Bar
              _buildSearchInput(),
              const Divider(height: 1, color: Colors.white12),

              // Scrollable Habits & Recent Activities
              Flexible(
                child: _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          _buildPinnedHabitsSection(),
                          if (_recentActivities.isNotEmpty &&
                              _searchQuery.isEmpty) ...[
                            const SizedBox(height: 8),
                            _buildRecentActivitiesSection(),
                          ],
                        ],
                      ),
              ),

              const Divider(height: 1, color: Colors.white12),

              // Footer Toolbar
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTimerBanner(ActiveTimer timer, int elapsedMs) {
    final actName = _activeActivity?.name ?? 'Tracking';
    final isPaused = timer.isPaused;
    final dotColor = isPaused
        ? const Color(0xFFFFB300)
        : const Color(0xFF4CAF50);
    final elapsedStr = _formatElapsedDuration(elapsedMs);

    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF262630),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
              Expanded(
                child: Text(
                  '${actName.toUpperCase()} ($elapsedStr)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: _togglePauseResume,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isPaused ? '▶️ Resume' : '⏸️ Pause',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Inline editable comment field
          TextField(
            focusNode: _commentFocusNode,
            controller: _commentController,
            onChanged: _onCommentChanged,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              hintText: 'Notes: e.g. w/ Alice - PR Review',
              hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
              border: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white12),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white12),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF4CAF50)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Stop Button
          ElevatedButton.icon(
            onPressed: _stopTimer,
            icon: const Icon(Icons.stop, size: 16, color: Colors.white),
            label: const Text(
              'Stop (Cmd+Enter)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8),
              minimumSize: const Size(double.infinity, 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchInput() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        focusNode: _searchFocusNode,
        controller: _searchController,
        onChanged: (val) => setState(() => _searchQuery = val),
        onSubmitted: _onSearchSubmitted,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white54),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          hintText: 'Search or create activity... (/)',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          border: InputBorder.none,
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.clear,
                    size: 16,
                    color: Colors.white54,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildPinnedHabitsSection() {
    final filtered = _searchQuery.isEmpty
        ? _pinnedActivities
        : _pinnedActivities
              .where(
                (a) =>
                    a.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Text(
            'PINNED HABITS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              _searchQuery.isNotEmpty
                  ? '+ Press Enter to create "${_searchQuery.trim()}"'
                  : 'No pinned habits yet.',
              style: TextStyle(
                color: _searchQuery.isNotEmpty
                    ? const Color(0xFF4CAF50)
                    : Colors.white30,
                fontSize: 12,
              ),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++)
            _buildHabitRow(filtered[i], i < 9 ? i + 1 : null),
      ],
    );
  }

  Widget _buildHabitRow(Activity activity, int? hotkeyNumber) {
    final durationMs = _weeklyDurations[activity.id] ?? 0;
    final weeklyText = _formatWeeklySummary(durationMs);
    final isCurrent =
        widget.timerStateMachine.activeTimer?.activityId == activity.id;

    return InkWell(
      onTap: () => _startHabit(activity),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: isCurrent
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.transparent,
        child: Row(
          children: [
            if (hotkeyNumber != null)
              Container(
                width: 22,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$hotkeyNumber',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else
              const SizedBox(width: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                activity.name,
                style: TextStyle(
                  color: isCurrent ? const Color(0xFF4CAF50) : Colors.white,
                  fontSize: 13,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                weeklyText,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentActivitiesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Text(
            'RECENT ACTIVITIES',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ),
        for (final act in _recentActivities)
          InkWell(
            onTap: () => _startHabit(act),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              child: Row(
                children: [
                  const Text(
                    '• ',
                    style: TextStyle(color: Colors.white38, fontSize: 14),
                  ),
                  Expanded(
                    child: Text(
                      act.name,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: const Color(0xFF18181D),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildFooterButton('⌘O', 'Open', _openFullWindow),
          _buildFooterButton('⌘,', 'Settings', () {
            widget.onOpenSettings?.call();
          }),
          _buildFooterButton('⌘Q', 'Quit', _quitApp),
        ],
      ),
    );
  }

  Widget _buildFooterButton(String hotkey, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                hotkey,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
