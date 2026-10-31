import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/state/timer_state_machine.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'activity_manager_view.dart';

/// Main mobile dashboard for 1-tap habit capture, live timer monitoring,
/// and daily productivity summary.
class DashboardView extends StatefulWidget {
  final TimerStateMachine timerStateMachine;
  final TempoDatabase database;
  final VoidCallback? onNavigateToStats;

  const DashboardView({
    super.key,
    required this.timerStateMachine,
    required this.database,
    this.onNavigateToStats,
  });

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView>
    with SingleTickerProviderStateMixin {
  Timer? _liveTicker;
  List<Activity> _activities = [];
  Map<String, int> _todayActivityDurations = {};
  int _todayTotalDurationMs = 0;
  int _todaySessionCount = 0;
  Activity? _activeActivity;
  bool _isLoading = true;

  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();

  // Guarded Stop (600ms hold) controller
  late AnimationController _stopHoldController;

  @override
  void initState() {
    super.initState();
    _stopHoldController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 600),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            _performStop();
          }
        });

    final timer = widget.timerStateMachine.activeTimer;
    if (timer != null) {
      _commentController.text = timer.currentComment;
      _resolveActiveActivity(timer.activityId);
      _startLiveTicker();
    }

    _loadData();
    widget.timerStateMachine.activeTimerNotifier.addListener(
      _onActiveTimerChanged,
    );
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _stopHoldController.dispose();
    widget.timerStateMachine.activeTimerNotifier.removeListener(
      _onActiveTimerChanged,
    );
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  void _onActiveTimerChanged() {
    final timer = widget.timerStateMachine.activeTimer;
    if (timer != null) {
      if (_commentController.text != timer.currentComment &&
          !_commentFocusNode.hasFocus) {
        _commentController.text = timer.currentComment;
      }
      _resolveActiveActivity(timer.activityId);
      _startLiveTicker();
    } else {
      _activeActivity = null;
      _stopLiveTicker();
    }
    if (mounted) setState(() {});
  }

  void _startLiveTicker() {
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.timerStateMachine.isTracking && mounted) {
        setState(() {});
      } else if (!widget.timerStateMachine.isTracking) {
        _stopLiveTicker();
      }
    });
  }

  void _stopLiveTicker() {
    _liveTicker?.cancel();
    _liveTicker = null;
  }

  Future<void> _loadData() async {
    try {
      final allActivities = await widget.database.getAllActivities(
        includeArchived: false,
      );
      final now = DateTime.now();
      final startOfToday = DateTime(
        now.year,
        now.month,
        now.day,
      ).millisecondsSinceEpoch;
      final endOfToday = DateTime(
        now.year,
        now.month,
        now.day,
        23,
        59,
        59,
        999,
      ).millisecondsSinceEpoch;

      final todayRecords = await widget.database.getRecords(
        startedAfter: startOfToday,
        startedBefore: endOfToday,
      );

      int totalMs = 0;
      final map = <String, int>{};
      for (final r in todayRecords) {
        totalMs += r.durationMs;
        map[r.activityId] = (map[r.activityId] ?? 0) + r.durationMs;
      }

      if (mounted) {
        setState(() {
          _activities = allActivities;
          _todayTotalDurationMs = totalMs;
          _todaySessionCount = todayRecords.length;
          _todayActivityDurations = map;
          _isLoading = false;
        });
      }

      final current = widget.timerStateMachine.activeTimer;
      if (current != null) {
        await _resolveActiveActivity(current.activityId);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resolveActiveActivity(String activityId) async {
    final act = await widget.database.getActivityById(activityId);
    if (mounted) {
      setState(() => _activeActivity = act);
    }
  }

  Future<void> _handleStartHabit(Activity activity) async {
    final currentTimer = widget.timerStateMachine.activeTimer;
    if (currentTimer != null && currentTimer.activityId == activity.id) {
      // Already running this activity
      return;
    }

    try {
      if (widget.timerStateMachine.isIdle) {
        await widget.timerStateMachine.start(activity.id);
      } else {
        await widget.timerStateMachine.switchActivity(activity.id);
      }
      _loadData();

      // Show 3-second Undo Grace Window
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF22222C),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            content: Row(
              children: [
                Icon(
                  UiHelpers.getIconData(activity.iconName),
                  color: UiHelpers.parseHexColor(activity.colorHex),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Started ${activity.name}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'UNDO',
              textColor: const Color(0xFF4CAF50),
              onPressed: () async {
                try {
                  await widget.timerStateMachine.undoStart();
                  _loadData();
                } catch (_) {}
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to start timer: $e')));
      }
    }
  }

  Future<void> _togglePauseResume() async {
    try {
      if (widget.timerStateMachine.isTracking) {
        await widget.timerStateMachine.pause();
      } else if (widget.timerStateMachine.isPaused) {
        await widget.timerStateMachine.resume();
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Action failed: $e')));
      }
    }
  }

  Future<void> _performStop() async {
    _stopHoldController.reset();
    try {
      await widget.timerStateMachine.stop();
      _commentController.clear();
      _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Session saved to history.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to stop timer: $e')));
      }
    }
  }

  void _onCommentChanged(String val) {
    if (widget.timerStateMachine.activeTimer != null) {
      widget.timerStateMachine.updateComment(val);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121216),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: const Color(0xFF4CAF50),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _buildTopHeader(),
              SliverToBoxAdapter(child: _buildActiveTimerHero()),
              SliverToBoxAdapter(child: _buildTodaySummaryBanner()),
              _buildHabitsSection(),
              const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tempo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  UiHelpers.formatDateHeader(DateTime.now()),
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.tune_rounded, color: Colors.white70),
              tooltip: 'Manage Habits',
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ActivityManagerView(database: widget.database),
                  ),
                );
                _loadData();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveTimerHero() {
    final activeTimer = widget.timerStateMachine.activeTimer;

    if (activeTimer == null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            Icon(
              Icons.timer_outlined,
              color: Colors.white.withValues(alpha: 0.2),
              size: 48,
            ),
            const SizedBox(height: 12),
            const Text(
              'No Active Timer',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap any habit below to start 1-tap capture',
              style: TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final durationMs = widget.timerStateMachine.currentDurationMs;
    final timeStr = UiHelpers.formatMonospaceDuration(durationMs);
    final isPaused = activeTimer.isPaused;
    final activityColor = _activeActivity != null
        ? UiHelpers.parseHexColor(_activeActivity!.colorHex)
        : const Color(0xFF4CAF50);
    final activityName = _activeActivity?.name ?? 'Tracking Activity';
    final activityIcon = UiHelpers.getIconData(_activeActivity?.iconName);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: activityColor.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: activityColor.withValues(alpha: 0.12),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Activity Badge + Status
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: activityColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(activityIcon, color: activityColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activityName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isPaused ? 'Paused' : 'Active tracking',
                      style: TextStyle(
                        color: isPaused ? Colors.amberAccent : activityColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Big Monospace Timer Display
          Center(
            child: Text(
              timeStr,
              style: TextStyle(
                color: isPaused ? Colors.white60 : Colors.white,
                fontSize: 44,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Inline editable comment field
          TextField(
            controller: _commentController,
            focusNode: _commentFocusNode,
            onChanged: _onCommentChanged,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Add note (e.g. w/ Sarah - sprint review)',
              hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              prefixIcon: const Icon(
                Icons.edit_note,
                size: 18,
                color: Colors.white38,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Action Controls: Pause/Resume and Guarded Stop
          Row(
            children: [
              // Pause / Resume Button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _togglePauseResume,
                  icon: Icon(
                    isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    size: 20,
                  ),
                  label: Text(
                    isPaused ? 'Resume' : 'Pause',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Guarded Stop Button (Hold 600ms)
              Expanded(
                child: GestureDetector(
                  onTapDown: (_) => _stopHoldController.forward(),
                  onTapUp: (_) {
                    if (_stopHoldController.status !=
                        AnimationStatus.completed) {
                      _stopHoldController.reverse();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Hold stop button for 600ms to stop.'),
                          duration: Duration(milliseconds: 1500),
                        ),
                      );
                    }
                  },
                  onTapCancel: () => _stopHoldController.reverse(),
                  child: AnimatedBuilder(
                    animation: _stopHoldController,
                    builder: (context, _) {
                      final progress = _stopHoldController.value;
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Color.lerp(
                            const Color(0xFFD32F2F),
                            const Color(0xFFB71C1C),
                            progress,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (progress > 0)
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            else
                              const Icon(
                                Icons.stop_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            const SizedBox(width: 8),
                            Text(
                              progress > 0 ? 'Hold...' : 'Hold to Stop',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTodaySummaryBanner() {
    final totalHoursStr = UiHelpers.formatDurationHuman(_todayTotalDurationMs);

    return InkWell(
      onTap: widget.onNavigateToStats,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF181820),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.insights,
                    color: Color(0xFF4CAF50),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Today's Progress",
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$_todaySessionCount sessions completed',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  totalHoursStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.white38,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHabitsSection() {
    if (_isLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
          ),
        ),
      );
    }

    if (_activities.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              const Text(
                'No activities configured yet.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ActivityManagerView(database: widget.database),
                    ),
                  );
                  _loadData();
                },
                icon: const Icon(Icons.add),
                label: const Text('Create Habits'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final activeId = widget.timerStateMachine.activeTimer?.activityId;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.35,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final activity = _activities[index];
          final isRunning = activity.id == activeId;
          final durationTodayMs = _todayActivityDurations[activity.id] ?? 0;
          final color = UiHelpers.parseHexColor(activity.colorHex);
          final icon = UiHelpers.getIconData(activity.iconName);

          return InkWell(
            onTap: () => _handleStartHabit(activity),
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isRunning
                    ? color.withValues(alpha: 0.18)
                    : const Color(0xFF1A1A22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isRunning
                      ? color
                      : Colors.white.withValues(alpha: 0.06),
                  width: isRunning ? 2.0 : 1.0,
                ),
                boxShadow: isRunning
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.25),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, color: color, size: 20),
                      ),
                      if (activity.isPinned)
                        const Icon(
                          Icons.push_pin,
                          color: Colors.white30,
                          size: 14,
                        )
                      else if (isRunning)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activity.name,
                        style: TextStyle(
                          color: isRunning
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.9),
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        durationTodayMs > 0
                            ? UiHelpers.formatDurationHuman(durationTodayMs)
                            : '0m today',
                        style: TextStyle(
                          color: isRunning ? color : Colors.white38,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }, childCount: _activities.length),
      ),
    );
  }
}
