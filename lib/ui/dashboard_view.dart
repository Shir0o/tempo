import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/state/day_recorder.dart';
import '../../core/time/timezone_id.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'activity_manager_view.dart';
import 'helpers/ui_helpers.dart';

/// Phone home screen, laid out as design D (Color Blocks): a hatched Lap panel
/// over a 00–24 strip of the Day, then a 3-column grid of Activity blocks.
/// Tapping a block labels the open Lap; an undo bar stays for three seconds.
class DashboardView extends StatefulWidget {
  final DayRecorder dayRecorder;
  final TempoDatabase database;
  final VoidCallback? onNavigateToStats;
  final VoidCallback? onOpenHistory;

  const DashboardView({
    super.key,
    required this.dayRecorder,
    required this.database,
    this.onNavigateToStats,
    this.onOpenHistory,
  });

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

const Color _ink = Color(0xFF121210);
const Color _inkMuted = Color(0x8A121210);
const Color _inkFaint = Color(0x5C121210);
const Color _panel = Color(0xFFE9E9E2);
const Color _track = Color(0xFFD2D2C8);
const Color _accent = Color(0xFFC6F432);
const Color _background = Color(0xFF0B0B0A);
const Color _surface = Color(0xFF1B1B18);
const String _fontFamily = 'SpaceGrotesk';

/// The three-second window an undo bar offers, matching
/// [DayRecorder.defaultUndoGraceWindow].
const Duration _undoWindow = DayRecorder.defaultUndoGraceWindow;

class _Span {
  final double start;
  final double end;
  final Color color;
  final bool hatched;
  final String semanticsLabel;
  final bool marksZoneChange;

  const _Span({
    required this.start,
    required this.end,
    required this.color,
    required this.hatched,
    required this.semanticsLabel,
    this.marksZoneChange = false,
  });
}

class _UndoState {
  final String message;
  final DateTime deadline;

  const _UndoState({required this.message, required this.deadline});

  int get secondsLeft {
    final ms = deadline.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return 0;
    return math.min(_undoWindow.inSeconds, (ms / 1000).ceil());
  }
}

class _DashboardViewState extends State<DashboardView>
    with WidgetsBindingObserver {
  Timer? _liveTicker;
  List<Activity> _activities = [];
  Map<String, Activity> _activitiesById = {};
  List<Record> _todayRecords = [];
  Map<String, int> _todayActivityDurations = {};
  int _loggedTodayMs = 0;
  Activity? _lastActivity;
  _UndoState? _undo;
  bool _isLoading = true;

  int _dayStartMs = 0;
  int _dayEndMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLiveTicker();
    _loadData();
    widget.dayRecorder.lapListenable.addListener(_onLapChanged);
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.dayRecorder.lapListenable.removeListener(_onLapChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startLiveTicker();
      setState(() {});
    } else {
      _liveTicker?.cancel();
      _liveTicker = null;
    }
  }

  void _onLapChanged() {
    if (mounted) setState(() {});
  }

  /// Rebuilds once a second so the elapsed time and the undo countdown move.
  void _startLiveTicker() {
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_undo != null && _undo!.secondsLeft == 0) _undo = null;
      });
    });
  }

  Future<void> _loadData() async {
    try {
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      final dayEnd = DateTime(now.year, now.month, now.day + 1);
      final dayStartMs = dayStart.millisecondsSinceEpoch;
      final dayEndMs = dayEnd.millisecondsSinceEpoch;

      final activities = await widget.database.getAllActivities(
        includeArchived: false,
      );
      final archived = await widget.database.getAllActivities(
        includeArchived: true,
      );

      // Bound the query to the last two days so the strip can also show a
      // record that began yesterday and crossed midnight into today.
      final candidates = await widget.database.getRecords(
        startedAfter: dayStartMs - const Duration(days: 2).inMilliseconds,
        startedBefore: dayEndMs,
        orderBy: 'started_at_epoch_ms ASC',
      );
      final todayRecords = candidates
          .where(
            (r) =>
                r.startedAtEpochMs < dayEndMs && r.endedAtEpochMs > dayStartMs,
          )
          .toList();

      final durations = <String, int>{};
      var loggedMs = 0;
      for (final r in todayRecords) {
        final start = math.max(r.startedAtEpochMs, dayStartMs);
        final end = math.min(r.endedAtEpochMs, dayEndMs);
        final ms = math.max(0, end - start);
        final activityId = r.activityId;
        if (activityId == null) continue;
        loggedMs += ms;
        durations[activityId] = (durations[activityId] ?? 0) + ms;
      }

      final last = await widget.database.getRecords(
        trackedOnly: true,
        limit: 1,
        orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
      );
      final lastActivityId = last.isEmpty ? null : last.first.activityId;
      final activitiesById = {for (final a in archived) a.id: a};

      if (mounted) {
        setState(() {
          _activities = activities;
          _activitiesById = activitiesById;
          _todayRecords = todayRecords;
          _todayActivityDurations = durations;
          _loggedTodayMs = loggedMs;
          _lastActivity = activitiesById[lastActivityId];
          _dayStartMs = dayStartMs;
          _dayEndMs = dayEndMs;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _labelActivity(Activity activity) async {
    try {
      final record = await widget.dayRecorder.label(activity.id);
      await _loadData();
      _showUndo('Logged ${activity.name} ${_rangeLabel(record)}', record);
    } catch (e) {
      _showError('Failed to label the Lap: $e');
    }
  }

  Future<void> _labelSameAsLast() async {
    try {
      final record = await widget.dayRecorder.sameAsLast();
      if (record == null) {
        _showError('There is no earlier Record to repeat yet.');
        return;
      }
      await _loadData();
      final name = _activitiesById[record.activityId]?.name ?? 'Record';
      _showUndo('Logged $name ${_rangeLabel(record)}', record);
    } catch (e) {
      _showError('Failed to label the Lap: $e');
    }
  }

  Future<void> _split() async {
    try {
      final record = await widget.dayRecorder.split();
      await _loadData();
      final at = DateFormat('HH:mm')
          .format(wallClockAt(record.endTimezoneId, record.endedAtEpochMs));
      _showUndo('Split at $at', record);
    } catch (e) {
      _showError('Failed to split the Lap: $e');
    }
  }

  Future<void> _undoLast() async {
    try {
      final undone = await widget.dayRecorder.undoLast();
      if (!mounted) return;
      setState(() => _undo = null);
      if (undone) {
        await _loadData();
      } else {
        _showError('That label can no longer be undone.');
      }
    } catch (e) {
      _showError('Failed to undo: $e');
    }
  }

  void _showUndo(String message, Record? record) {
    if (record == null || !mounted) return;
    setState(() {
      _undo = _UndoState(
        message: message,
        deadline: DateTime.now().add(_undoWindow),
      );
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _rangeLabel(Record record) {
    final start = DateFormat('HH:mm')
        .format(wallClockAt(record.timezoneId, record.startedAtEpochMs));
    final end = DateFormat('HH:mm')
        .format(wallClockAt(record.endTimezoneId, record.endedAtEpochMs));
    return '$start–$end';
  }

  @override
  Widget build(BuildContext context) {
    final undo = _undo;
    return Scaffold(
      backgroundColor: _background,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _loadData,
            color: _accent,
            backgroundColor: _surface,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildLapPanel()),
                SliverToBoxAdapter(child: _buildGridHeading()),
                _buildActivityGrid(),
                SliverPadding(
                  padding: EdgeInsets.only(bottom: undo == null ? 32 : 104),
                ),
              ],
            ),
          ),
          if (undo != null && undo.secondsLeft > 0)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _buildUndoBar(undo),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- Lap panel

  Widget _buildLapPanel() {
    final now = DateTime.now();
    final lap = widget.dayRecorder.lap;
    final elapsedMs = widget.dayRecorder.currentElapsedMs;
    final since = lap == null
        ? '--:--'
        : DateFormat('HH:mm').format(
            wallClockAt(
              lap.startTimezoneOr(localTimezoneId()),
              lap.startedAtEpochMs,
            ),
          );

    final topInset = MediaQuery.of(context).padding.top;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: Container(
        color: _panel,
        child: CustomPaint(
          painter: const _HatchPainter(),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, topInset + 14, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPanelHeader(now),
                const SizedBox(height: 18),
                const Text(
                  'Untracked',
                  style: TextStyle(
                    fontFamily: _fontFamily,
                    color: _ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                  ),
                ),
                Text(
                  'since $since',
                  style: const TextStyle(
                    fontFamily: _fontFamily,
                    color: _inkMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  UiHelpers.formatMonospaceDuration(elapsedMs),
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: _fontFamily,
                    color: _ink,
                    fontSize: 58,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -2,
                    height: 1.05,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 14),
                _buildDayStrip(),
                const SizedBox(height: 18),
                _buildPanelActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelHeader(DateTime now) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('EEEE d MMMM').format(now),
                style: const TextStyle(
                  fontFamily: _fontFamily,
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${UiHelpers.formatDurationHuman(_loggedTodayMs)} logged',
                style: const TextStyle(
                  fontFamily: _fontFamily,
                  color: _inkMuted,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: _openActivityManager,
          style: TextButton.styleFrom(
            foregroundColor: _ink,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: const TextStyle(
              fontFamily: _fontFamily,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          child: const Text('ACTIVITIES'),
        ),
      ],
    );
  }

  Widget _buildDayStrip() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final spans = _buildSpans();
        return Semantics(
          container: true,
          button: widget.onOpenHistory != null,
          label:
              'Today from midnight, ${_todayRecords.length} records. '
              'Tap to open the Day for editing.',
          child: GestureDetector(
            onTap: widget.onOpenHistory,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 30,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _DayStripPainter(
                            spans: spans,
                            trackColor: _track,
                            markerColor: _ink,
                          ),
                        ),
                      ),
                      for (final span in spans)
                        Positioned(
                          left: (span.start * width).clamp(0, width),
                          width: math.max(
                            1.0,
                            ((span.end - span.start) * width).clamp(1.0, width),
                          ),
                          top: 0,
                          height: 30,
                          child: Semantics(
                            container: true,
                            label: span.semanticsLabel,
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                _buildStripLabels(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStripLabels() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('00', style: _stripLabelStyle),
        Text('06', style: _stripLabelStyle),
        Text('12', style: _stripLabelStyle),
        Text('18', style: _stripLabelStyle),
        Text('24', style: _stripLabelStyle),
      ],
    );
  }

  Widget _buildPanelActions() {
    final last = _lastActivity;
    final lastColor = last == null
        ? _accent
        : UiHelpers.parseHexColor(last.colorHex);

    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _split,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              foregroundColor: _ink,
              side: const BorderSide(color: _ink, width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontFamily: _fontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('Split'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: last == null ? null : _labelSameAsLast,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              backgroundColor: _ink,
              foregroundColor: _panel,
              disabledBackgroundColor: const Color(0x33121210),
              disabledForegroundColor: _inkFaint,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(
                fontFamily: _fontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: lastColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    last == null
                        ? 'Same as last'
                        : 'Same as last: ${last.name}',
                    maxLines: 1,
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

  List<_Span> _buildSpans() {
    final dayLength = _dayEndMs - _dayStartMs;
    if (dayLength <= 0) return const [];
    double fraction(int epochMs) =>
        ((epochMs - _dayStartMs) / dayLength).clamp(0.0, 1.0);

    final spans = <_Span>[];
    for (final r in _todayRecords) {
      final start = fraction(r.startedAtEpochMs);
      final end = math.max(fraction(r.endedAtEpochMs), start);
      final activity = _activitiesById[r.activityId];
      final label = activity?.name ?? 'Untracked';
      final timeRange =
          '${DateFormat('HH:mm').format(wallClockAt(r.timezoneId, r.startedAtEpochMs))}'
          ' to '
          '${DateFormat('HH:mm').format(wallClockAt(r.endTimezoneId, r.endedAtEpochMs))}';
      final zoneNote = r.crossesTimezones
          ? ', zone changed ${zoneAbbreviationAt(r.timezoneId, r.startedAtEpochMs)}'
                ' to ${zoneAbbreviationAt(r.endTimezoneId, r.endedAtEpochMs)}'
          : '';
      spans.add(
        _Span(
          start: start,
          end: end,
          color: activity == null
              ? _track
              : UiHelpers.parseHexColor(activity.colorHex),
          hatched: activity == null,
          semanticsLabel:
              '$label, $timeRange$zoneNote, '
              '${UiHelpers.formatDurationHuman(r.durationMs)}',
          marksZoneChange: r.crossesTimezones,
        ),
      );
    }

    final lap = widget.dayRecorder.lap;
    if (lap != null) {
      final start = fraction(lap.startedAtEpochMs);
      final end = fraction(DateTime.now().toUtc().millisecondsSinceEpoch);
      spans.add(
        _Span(
          start: start,
          end: math.max(end, start),
          color: _ink,
          hatched: false,
          semanticsLabel:
              'Open Lap since '
              '${DateFormat('HH:mm').format(wallClockAt(lap.startTimezoneOr(localTimezoneId()), lap.startedAtEpochMs))}, '
              '${UiHelpers.formatDurationHuman(widget.dayRecorder.currentElapsedMs)}',
        ),
      );
    }
    return spans;
  }

  // ------------------------------------------------------------- Grid section

  Widget _buildGridHeading() {
    final lap = widget.dayRecorder.lap;
    final since = lap == null
        ? '--:--'
        : DateFormat('HH:mm').format(
            wallClockAt(
              lap.startTimezoneOr(localTimezoneId()),
              lap.startedAtEpochMs,
            ),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'What was it?',
            style: TextStyle(
              fontFamily: _fontFamily,
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Text.rich(
                TextSpan(
                  text: 'Tap to log ',
                  style: const TextStyle(color: Colors.white60),
                  children: [
                    TextSpan(
                      text: '$since → now',
                      style: const TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontFamily: _fontFamily,
                  fontSize: 12.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActivityGrid() {
    if (_isLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            ),
          ),
        ),
      );
    }

    if (_activities.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'No Activities yet.',
                style: TextStyle(
                  fontFamily: _fontFamily,
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _openActivityManager,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: _accent,
                  side: BorderSide(color: _accent.withValues(alpha: 0.6)),
                ),
                child: const Text('Create Activities'),
              ),
            ],
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final activity = _activities[index];
          final durationMs = _todayActivityDurations[activity.id] ?? 0;
          return _buildActivityBlock(activity, durationMs);
        }, childCount: _activities.length),
      ),
    );
  }

  Widget _buildActivityBlock(Activity activity, int durationMs) {
    final color = UiHelpers.parseHexColor(activity.colorHex);
    final dark = ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    final textColor = dark ? Colors.white : _ink;
    final total = durationMs <= 0
        ? '0m'
        : UiHelpers.formatDurationHuman(durationMs);

    return Semantics(
      button: true,
      label:
          '${activity.name}, $total today. Tap to label the open Lap as '
          '${activity.name}.',
      child: ExcludeSemantics(
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('activity-block-${activity.id}'),
            onTap: () => _labelActivity(activity),
            onLongPress: _openActivityManager,
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    activity.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: _fontFamily,
                      color: textColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(
                    total,
                    style: TextStyle(
                      fontFamily: _fontFamily,
                      color: dark
                          ? Colors.white70
                          : _ink.withValues(alpha: 0.66),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ Undo bar

  Widget _buildUndoBar(_UndoState undo) {
    return Material(
      color: _surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                undo.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: _fontFamily,
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            TextButton(
              onPressed: _undoLast,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: _accent,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontFamily: _fontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              child: Text('Undo · ${undo.secondsLeft}'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openActivityManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ActivityManagerView(database: widget.database),
      ),
    );
    _loadData();
  }
}

const TextStyle _stripLabelStyle = TextStyle(
  fontFamily: _fontFamily,
  color: _inkFaint,
  fontSize: 9.5,
  fontWeight: FontWeight.w500,
  letterSpacing: 0.4,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Diagonal hatching over the light Lap panel.
class _HatchPainter extends CustomPainter {
  const _HatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0F000000)
      ..strokeWidth = 1;
    const spacing = 9.0;
    for (double x = -size.height; x < size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Draws the midnight-to-midnight strip: Records in their Activity colours,
/// Untracked Records hatched, the open Lap in black, zone changes marked.
class _DayStripPainter extends CustomPainter {
  final List<_Span> spans;
  final Color trackColor;
  final Color markerColor;

  const _DayStripPainter({
    required this.spans,
    required this.trackColor,
    required this.markerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(4),
    );
    canvas.drawRRect(track, Paint()..color = trackColor);

    canvas.save();
    canvas.clipRRect(track);
    for (final span in spans) {
      final left = span.start * size.width;
      final width = math.max(1.0, (span.end - span.start) * size.width);
      final rect = Rect.fromLTWH(left, 0, width, size.height);
      canvas.drawRect(rect, Paint()..color = span.color);
      if (span.hatched) {
        final hatch = Paint()
          ..color = const Color(0x26000000)
          ..strokeWidth = 1;
        for (double x = rect.left - size.height; x < rect.right; x += 6) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            hatch,
          );
        }
      }
      // A hairline between neighbours keeps the boundaries legible.
      canvas.drawRect(
        Rect.fromLTWH(left, 0, 1, size.height),
        Paint()..color = const Color(0x1AFFFFFF),
      );
    }
    canvas.restore();

    for (final span in spans.where((s) => s.marksZoneChange)) {
      final x = (span.end * size.width).clamp(0.0, size.width - 2);
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 2, size.height),
        Paint()..color = markerColor,
      );
      final marker = Path()
        ..moveTo(x - 3, 0)
        ..lineTo(x + 2, 0)
        ..lineTo(x - 0.5, 5)
        ..close();
      canvas.drawPath(marker, Paint()..color = markerColor);
    }
  }

  @override
  bool shouldRepaint(covariant _DayStripPainter oldDelegate) =>
      oldDelegate.spans != spans || oldDelegate.trackColor != trackColor;
}
