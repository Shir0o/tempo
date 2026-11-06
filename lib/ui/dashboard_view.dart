import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/state/auto_advance.dart';
import '../../core/state/day_recorder.dart';
import '../../core/state/note_suggestions.dart';
import '../../core/state/people_index.dart';
import '../../core/state/record_commands.dart';
import '../../core/state/suggestion_loader.dart';
import '../../core/state/today_order.dart';
import '../../core/time/timezone_id.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'activity_manager_view.dart';
import 'helpers/activity_order.dart';
import 'helpers/ui_helpers.dart';
import 'note_sheet.dart';
import 'theme/tempo_theme.dart';

/// Phone home screen, laid out as design D (Color Blocks): a hatched Lap panel
/// over a 00–24 strip of the Day, then a 3-column grid of Activity blocks.
/// Tapping a block labels the open Lap; an undo bar stays for three seconds.
class DashboardView extends StatefulWidget {
  /// The phone's always-running Lap. Null on the Mac, which reads the Lap from
  /// the replica and never opens one of its own.
  final DayRecorder? dayRecorder;
  final TempoDatabase database;

  /// Every mutation goes through this seam. Defaults to the phone's
  /// [PhoneRecordCommands] when a [DayRecorder] is supplied; the Mac passes
  /// [RemoteRecordCommands] so a tap becomes an intent.
  final RecordCommands? commands;

  final VoidCallback? onNavigateToStats;
  final VoidCallback? onOpenHistory;

  /// The Today page's block order. Falls back to [TodayOrder.categories] when
  /// the app does not provide one (tests, previews).
  final ValueListenable<TodayOrder>? todayOrder;

  /// Bumped whenever activities or categories change elsewhere in the app, so
  /// this page can reload its catalog.
  final ValueListenable<int>? catalogRevision;

  const DashboardView({
    super.key,
    this.dayRecorder,
    required this.database,
    this.commands,
    this.onNavigateToStats,
    this.onOpenHistory,
    this.todayOrder,
    this.catalogRevision,
  });

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

const Color _ink = TempoColors.ink;
const Color _inkMuted = TempoColors.inkMuted;
const Color _inkFaint = TempoColors.inkFaint;
const Color _panel = TempoColors.panel;
const Color _track = TempoColors.track;
const Color _accent = TempoColors.accent;
const Color _background = TempoColors.background;
const Color _surface = TempoColors.surface;
const String _fontFamily = tempoFontFamily;

/// The three-second window an undo bar offers, matching
/// [DayRecorder.defaultUndoGraceWindow].
const Duration _undoWindow = DayRecorder.defaultUndoGraceWindow;

class _UndoState {
  final String message;
  final DateTime deadline;

  /// The Record the label or split just closed.
  final Record record;

  const _UndoState({
    required this.message,
    required this.deadline,
    required this.record,
  });

  int get secondsLeft {
    final ms = deadline.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return 0;
    return math.min(_undoWindow.inSeconds, (ms / 1000).ceil());
  }
}

class _DashboardViewState extends State<DashboardView>
    with WidgetsBindingObserver {
  /// The seam this page writes through: the injected commands, or the phone's
  /// DayRecorder-backed implementation when none was supplied.
  late final RecordCommands _commands = widget.commands ?? _phoneCommands();

  /// The Lap read from the replica on a Mac, where no DayRecorder exists.
  Lap? _replicaLap;

  Timer? _liveTicker;
  List<Activity> _activities = [];
  Map<String, Activity> _activitiesById = {};
  List<Category> _categories = [];
  List<Record> _todayRecords = [];
  Map<String, int> _todayActivityDurations = {};
  List<Activity> _suggestedActivities = [];

  /// Combo chips (Activity, People and note) ahead of [_suggestedActivities].
  List<RecurringNote> _combos = [];
  String? _contactTagId;
  int _comboLoad = 0;
  int _loggedTodayMs = 0;
  Activity? _lastActivity;
  _UndoState? _undo;
  bool _isLoading = true;

  int _dayStartMs = 0;
  int _dayEndMs = 0;

  RecordCommands _phoneCommands() {
    final recorder = widget.dayRecorder;
    if (recorder == null) {
      throw StateError('DashboardView needs commands or a DayRecorder.');
    }
    return PhoneRecordCommands(dayRecorder: recorder);
  }

  /// The open Lap: the phone's live notifier, or the replica's last row.
  Lap? get _lap => widget.dayRecorder?.lap ?? _replicaLap;

  int get _elapsedMs =>
      _lap?.elapsedMs(DateTime.now().toUtc().millisecondsSinceEpoch) ?? 0;

  String get _lapStartZoneId =>
      _lap?.startTimezoneOr(localTimezoneId()) ?? localTimezoneId();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLiveTicker();
    _loadData();
    widget.dayRecorder?.lapListenable.addListener(_onLapChanged);
    widget.todayOrder?.addListener(_onOrderChanged);
    widget.catalogRevision?.addListener(_onCatalogChanged);
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.dayRecorder?.lapListenable.removeListener(_onLapChanged);
    widget.todayOrder?.removeListener(_onOrderChanged);
    widget.catalogRevision?.removeListener(_onCatalogChanged);
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

  /// The Today page's order changed in Settings; re-lay out the same catalog.
  void _onOrderChanged() {
    if (mounted) setState(() {});
  }

  /// Activities or categories changed elsewhere; reload them.
  void _onCatalogChanged() {
    if (mounted) _loadData();
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
      final categories = await widget.database.getCategories();

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

      // A Mac reads the Lap from the replica; it must never open one itself.
      final replicaLap = widget.dayRecorder == null
          ? await widget.database.getLap()
          : null;

      final suggested = await loadSuggestions(
        database: widget.database,
        candidates: activities,
        nowEpochMs: now.millisecondsSinceEpoch,
        timezoneId: localTimezoneId(),
        limit: 4,
      );

      if (mounted) {
        setState(() {
          _activities = activities;
          _activitiesById = activitiesById;
          _categories = categories;
          _todayRecords = todayRecords;
          _todayActivityDurations = durations;
          _suggestedActivities = suggested;
          _loggedTodayMs = loggedMs;
          _lastActivity = activitiesById[lastActivityId];
          _replicaLap = replicaLap;
          _dayStartMs = dayStartMs;
          _dayEndMs = dayEndMs;
          _isLoading = false;
        });
        unawaited(_loadCombos(activities, suggested));
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _labelActivity(
    Activity activity, {
    String comment = '',
    List<String> tagIds = const [],
  }) async {
    try {
      final record = await _commands.label(
        activity.id,
        comment: comment,
        tags: tagIds,
      );
      await _loadData();
      if (record == null) {
        _showQueued('${activity.name} is waiting for the phone.');
        return;
      }
      _showUndo('Logged ${activity.name} ${_rangeLabel(record)}', record);
    } catch (e) {
      _showError('Failed to label the Lap: $e');
    }
  }

  Future<void> _labelSameAsLast() async {
    final last = _lastActivity;
    if (last == null) {
      _showError('There is no earlier Record to repeat yet.');
      return;
    }
    try {
      final record = await _commands.label(last.id);
      await _loadData();
      if (record == null) {
        _showQueued('${last.name} is waiting for the phone.');
        return;
      }
      final name = _activitiesById[record.activityId]?.name ?? 'Record';
      _showUndo('Logged $name ${_rangeLabel(record)}', record);
    } catch (e) {
      _showError('Failed to label the Lap: $e');
    }
  }

  Future<void> _split() async {
    try {
      final record = await _commands.split();
      await _loadData();
      if (record == null) {
        _showQueued('The split is waiting for the phone.');
        return;
      }
      final at = DateFormat('HH:mm')
          .format(wallClockAt(record.endTimezoneId, record.endedAtEpochMs));
      _showUndo('Split at $at', record);
    } catch (e) {
      _showError('Failed to split the Lap: $e');
    }
  }

  Future<void> _undoLast() async {
    try {
      final undone = await _commands.undo();
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

  /// A proposal the phone has not answered yet; the undo bar would target the
  /// wrong Record, so this only states where the label went.
  void _showQueued(String message) {
    if (!mounted) return;
    setState(() => _undo = null);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showUndo(String message, Record? record) {
    if (record == null || !mounted) return;
    setState(() {
      _undo = _UndoState(
        message: message,
        deadline: DateTime.now().add(_undoWindow),
        record: record,
      );
    });
  }

  /// A year of tracked Records, latest first: where People, AutoAdvance
  /// readings and RecurringNotes are read from.
  Future<List<Record>> _noteHistory() {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    return widget.database.getRecords(
      trackedOnly: true,
      startedAfter: nowMs - const Duration(days: 365).inMilliseconds,
      orderBy: 'ended_at_epoch_ms DESC',
      limit: 2000,
    );
  }

  /// The Tags and the People to offer in the note sheet, People seen with
  /// [activityId] first, and the Records they were read from.
  Future<({List<Tag> tags, List<String> people, List<Record> records})>
  _noteChoices(String? activityId) async {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final tags = await widget.database.getAllTags();
    final records = await _noteHistory();
    return (
      tags: tags,
      people: rankPeople(records, nowEpochMs: nowMs, activityId: activityId),
      records: records,
    );
  }

  /// The comment the note sheet prefills for [activityId] at [targetEpochMs]
  /// (read in [zoneId]): the RecurringNote when one matches, else the
  /// AutoAdvance reading of the Activity with no Person.
  String _notePrefill(
    List<Record> records,
    String activityId,
    int targetEpochMs,
    String zoneId,
  ) {
    return recurringNote(
          records,
          activityId: activityId,
          targetEpochMs: targetEpochMs,
          targetZoneId: zoneId,
        )?.comment ??
        suggestedReading(
          records,
          activityId: activityId,
          beforeEpochMs: targetEpochMs,
        ) ??
        '';
  }

  /// The combo chips, loaded after the page is drawn (like the note sheet's
  /// People) so the year of history they read never holds up the Lap panel
  /// or the grid. The moment matched is the open Lap's start, the time the
  /// Lap's Record will start at.
  Future<void> _loadCombos(
    List<Activity> activities,
    List<Activity> suggested,
  ) async {
    final load = ++_comboLoad;
    try {
      final tags = await widget.database.getAllTags();
      final active = {for (final a in activities) a.id};
      final records = [
        for (final r in await _noteHistory())
          if (active.contains(r.activityId)) r,
      ];
      final combos = comboSuggestions(
        records,
        activityIds: [for (final a in suggested) a.id],
        targetEpochMs:
            _lap?.startedAtEpochMs ??
            DateTime.now().toUtc().millisecondsSinceEpoch,
        targetZoneId: _lapStartZoneId,
      );
      if (!mounted || load != _comboLoad) return;
      setState(() {
        _combos = combos;
        _contactTagId = contactTagId(tags);
      });
    } catch (_) {
      // Combo chips are optional; the plain chips still show.
    }
  }

  /// A combo chip: labels the Lap with its Activity, note and People, and the
  /// Contact Tag when it names someone.
  Future<void> _labelCombo(Activity activity, RecurringNote combo) {
    return _labelActivity(
      activity,
      comment: combo.comment,
      tagIds: tagIdsWithContact(
        const [],
        _contactTagId,
        hasPeople: combo.people.isNotEmpty,
      ),
    );
  }

  /// "Add note" on the undo bar: People, comment and Tags for the Record the
  /// label just closed, saved through the annotate command.
  Future<void> _addNote(Record record) async {
    setState(() => _undo = null);
    final activity = _activitiesById[record.activityId];
    try {
      final choices = await _noteChoices(record.activityId);
      if (!mounted) return;
      final activityId = record.activityId!;
      final prefill = record.comment.isEmpty
          ? _notePrefill(
              choices.records,
              activityId,
              record.startedAtEpochMs,
              record.timezoneId,
            )
          : '';
      final note = await showNoteSheet(
        context,
        activityName: activity?.name ?? 'Record',
        activityColor: UiHelpers.parseHexColor(activity?.colorHex),
        subtitle:
            '${_rangeLabel(record)} · '
            '${UiHelpers.formatDurationHuman(record.durationMs)}',
        tags: choices.tags,
        people: choices.people,
        initialComment: record.comment,
        initialTagIds: peopleIn(prefill).isEmpty
            ? record.tagIds
            : tagIdsWithContact(
                record.tagIds,
                contactTagId(choices.tags),
                hasPeople: true,
              ),
        suggestedReading: prefill,
        suggestReading: (first) => suggestedReading(
          choices.records,
          activityId: activityId,
          firstPerson: first,
          beforeEpochMs: record.startedAtEpochMs,
        ),
      );
      if (note == null) return;
      final saved = await _commands.annotate(
        record.id,
        comment: note.comment,
        tagIds: note.tagIds,
      );
      await _loadData();
      if (saved == null) _showQueued('The note is waiting for the phone.');
    } catch (e) {
      _showError('Failed to save the note: $e');
    }
  }

  /// Long-press on an Activity block: the note sheet before logging. Logging
  /// labels the Lap with the note and Tags in one command, so a replica
  /// queues a single proposal.
  Future<void> _noteThenLabel(Activity activity) async {
    final lap = _lap;
    final since = lap == null
        ? '--:--'
        : DateFormat('HH:mm')
              .format(wallClockAt(_lapStartZoneId, lap.startedAtEpochMs));
    try {
      final choices = await _noteChoices(activity.id);
      if (!mounted) return;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final prefill = _notePrefill(
        choices.records,
        activity.id,
        lap?.startedAtEpochMs ?? nowMs,
        _lapStartZoneId,
      );
      final note = await showNoteSheet(
        context,
        activityName: activity.name,
        activityColor: UiHelpers.parseHexColor(activity.colorHex),
        subtitle: '$since–now · ${UiHelpers.formatDurationHuman(_elapsedMs)}',
        tags: choices.tags,
        people: choices.people,
        initialTagIds: tagIdsWithContact(
          const [],
          contactTagId(choices.tags),
          hasPeople: peopleIn(prefill).isNotEmpty,
        ),
        suggestedReading: prefill,
        suggestReading: (first) => suggestedReading(
          choices.records,
          activityId: activity.id,
          firstPerson: first,
          beforeEpochMs: nowMs,
        ),
        confirmLabel: 'Log ${activity.name}',
        dismissLabel: 'Cancel',
      );
      if (note == null) return;
      await _labelActivity(
        activity,
        comment: note.comment,
        tagIds: note.tagIds,
      );
    } catch (e) {
      _showError('Failed to open the note: $e');
    }
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
                SliverToBoxAdapter(child: _buildSuggestedActivitiesRow()),
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
    final lap = _lap;
    final elapsedMs = _elapsedMs;
    final since = lap == null
        ? '--:--'
        : DateFormat('HH:mm')
              .format(wallClockAt(_lapStartZoneId, lap.startedAtEpochMs));

    final topInset = MediaQuery.of(context).padding.top;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: Container(
        color: _panel,
        child: CustomPaint(
          painter: const HatchPainter(),
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
                          painter: DayStripPainter(
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

  List<DayStripSpan> _buildSpans() {
    final dayLength = _dayEndMs - _dayStartMs;
    if (dayLength <= 0) return const [];
    double fraction(int epochMs) =>
        ((epochMs - _dayStartMs) / dayLength).clamp(0.0, 1.0);

    final spans = <DayStripSpan>[];
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
        DayStripSpan(
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

    final lap = _lap;
    if (lap != null) {
      final start = fraction(lap.startedAtEpochMs);
      final end = fraction(DateTime.now().toUtc().millisecondsSinceEpoch);
      spans.add(
        DayStripSpan(
          start: start,
          end: math.max(end, start),
          color: _ink,
          hatched: false,
          semanticsLabel:
              'Untracked since '
              '${DateFormat('HH:mm').format(wallClockAt(_lapStartZoneId, lap.startedAtEpochMs))}, '
              '${UiHelpers.formatDurationHuman(_elapsedMs)}',
        ),
      );
    }
    return spans;
  }

  // ------------------------------------------------------------- Grid section

  Widget _buildGridHeading() {
    final lap = _lap;
    final since = lap == null
        ? '--:--'
        : DateFormat('HH:mm')
              .format(wallClockAt(_lapStartZoneId, lap.startedAtEpochMs));

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

  /// Suggestions in two rows: Activity-with-note combos under WITH NOTE,
  /// plain Activities under ACTIVITY. A row with nothing to offer is hidden.
  Widget _buildSuggestedActivitiesRow() {
    final combos = [
      for (final combo in _combos)
        if (_activitiesById[combo.activityId] case final activity?)
          (activity, combo),
    ];
    if (combos.isEmpty && _suggestedActivities.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (combos.isNotEmpty) ...[
          _buildSuggestionOverline('WITH NOTE'),
          _buildSuggestionRow(
            height: 64,
            children: [
              for (final (index, (activity, combo)) in combos.indexed)
                _buildComboChip(index, activity, combo),
            ],
          ),
        ],
        if (_suggestedActivities.isNotEmpty) ...[
          _buildSuggestionOverline('ACTIVITY'),
          _buildSuggestionRow(
            height: 48,
            children: [
              for (final activity in _suggestedActivities)
                _buildSuggestedChip(activity),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSuggestionOverline(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: _fontFamily,
          color: TempoColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.88,
        ),
      ),
    );
  }

  Widget _buildSuggestionRow({
    required double height,
    required List<Widget> children,
  }) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) => children[index],
      ),
    );
  }

  Widget _buildSuggestedChip(Activity activity) {
    final color = UiHelpers.parseHexColor(activity.colorHex);
    return Semantics(
      button: true,
      label: 'Suggested: ${activity.name}. Tap to label untracked time.',
      child: Material(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey('suggested-chip-${activity.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => _labelActivity(activity),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                if (activity.iconName.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  UiHelpers.buildIconOrEmoji(
                    iconName: activity.iconName,
                    color: Colors.white,
                    size: 14,
                  ),
                ],
                const SizedBox(width: 6),
                Text(
                  activity.name,
                  style: const TextStyle(
                    fontFamily: _fontFamily,
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Activity name over `<reading> · w/ <names>`: one tap labels the Lap
  /// with all of it.
  Widget _buildComboChip(int index, Activity activity, RecurringNote combo) {
    final reading = splitComment(combo.comment).reading;
    final detail = [
      if (reading.isNotEmpty) reading,
      if (combo.people.isNotEmpty) 'w/ ${combo.people.join(', ')}',
    ].join(' · ');
    final label = [activity.name, if (detail.isNotEmpty) detail].join(' · ');
    return Semantics(
      button: true,
      label: 'Suggested: $label. Tap to label untracked time.',
      child: ExcludeSemantics(
        child: Material(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: ValueKey('combo-chip-$index'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => _labelCombo(activity, combo),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: UiHelpers.parseHexColor(activity.colorHex),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activity.name,
                        style: const TextStyle(
                          fontFamily: _fontFamily,
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          style: const TextStyle(
                            fontFamily: _fontFamily,
                            color: TempoColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
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

    final sections = activitySections(
      activities: _activities,
      categories: _categories,
      order: widget.todayOrder?.value ?? TodayOrder.categories,
    );

    return SliverMainAxisGroup(
      slivers: [
        for (final section in sections) ...[
          if (section.label != null)
            SliverToBoxAdapter(child: _buildSectionHeader(section)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisExtent: 56,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final activity = section.activities[index];
                final durationMs = _todayActivityDurations[activity.id] ?? 0;
                return _buildActivityBlock(activity, durationMs);
              }, childCount: section.activities.length),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(ActivitySection section) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 20, 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: section.color ?? Colors.white38,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              section.label!.toUpperCase(),
              style: const TextStyle(
                fontFamily: _fontFamily,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Colors.white54,
              ),
            ),
          ),
        ],
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
          '${activity.name}, $total today. Tap to label the untracked time as '
          '${activity.name}. Long-press to add a note first.',
      child: ExcludeSemantics(
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('activity-block-${activity.id}'),
            onTap: () => _labelActivity(activity),
            onLongPress: () => _noteThenLabel(activity),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Center(
                      child: activity.iconName.isEmpty
                          ? const SizedBox.shrink()
                          : UiHelpers.buildIconOrEmoji(
                              iconName: activity.iconName,
                              color: textColor.withValues(alpha: 0.8),
                              size: 16,
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      activity.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: _fontFamily,
                        color: textColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    total,
                    style: TextStyle(
                      fontFamily: _fontFamily,
                      color: textColor.withValues(alpha: 0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
            if (undo.record.activityId != null)
              TextButton(
                onPressed: () => _addNote(undo.record),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(
                    fontFamily: _fontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: const Text('Add note'),
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
