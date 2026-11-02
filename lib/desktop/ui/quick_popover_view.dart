import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/state/day_recorder.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';

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
  final DayRecorder dayRecorder;
  final TempoDatabase database;
  final bool enableTicker;
  final VoidCallback? onClose;
  final VoidCallback? onOpenFullWindow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onQuit;

  const QuickPopoverView({
    super.key,
    required this.dayRecorder,
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
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();

    widget.dayRecorder.lapListenable.addListener(_onLapChanged);
    _onLapChanged();
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _liveTicker = null;
    widget.dayRecorder.lapListenable.removeListener(_onLapChanged);
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
      if (widget.dayRecorder.lap != null && mounted) {
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

  Future<void> _onLapChanged() async {
    if (widget.dayRecorder.lap != null) {
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
    final comment = _commentController.text.trim();
    await widget.dayRecorder.label(activity.id, comment: comment);
    _commentController.clear();
    await _loadData();
  }

  Future<void> _labelSameAsLast() async {
    await widget.dayRecorder.sameAsLast();
    _commentController.clear();
    await _loadData();
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
    final lap = widget.dayRecorder.lap;
    final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final elapsedMs = lap?.elapsedMs(nowUtc) ?? 0;

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
              // Open Lap Banner (always present)
              if (lap != null) ...[
                _buildLapBanner(elapsedMs),
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

  Widget _buildLapBanner(int elapsedMs) {
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
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'UNTRACKED ($elapsedStr)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Inline editable comment field, applied to the next label.
          TextField(
            focusNode: _commentFocusNode,
            controller: _commentController,
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
          // Same as last
          ElevatedButton.icon(
            onPressed: _labelSameAsLast,
            icon: const Icon(Icons.repeat, size: 16, color: Colors.white),
            label: const Text(
              'Same as last (Cmd+Enter)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
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

    return InkWell(
      onTap: () => _startHabit(activity),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: Colors.transparent,
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
                style: const TextStyle(color: Colors.white, fontSize: 13),
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
