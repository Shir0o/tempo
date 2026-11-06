import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/state/activity_suggestions.dart';
import '../../core/state/auto_advance.dart';
import '../../core/state/day_recorder.dart';
import '../../core/state/note_suggestions.dart';
import '../../core/state/people_index.dart';
import '../../core/state/record_commands.dart';
import '../../core/sync/intent_queue.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../../data/models/sync_change.dart';
import '../core/time/timezone_id.dart';
import 'helpers/ui_helpers.dart';
import 'history/activity_picker_sheet.dart';
import 'history/history_widgets.dart';
import 'note_sheet.dart';
import 'theme/tempo_theme.dart';

/// History: each Day as a header card with its 00–24 strip, then a timeline
/// of its Records in lived-zone times. Tapping a Record opens the edit sheet;
/// tapping an Untracked Record labels it.
///
/// On the Mac's replica the Day also shows the proposals the phone has not
/// answered: a pending one outlined at its tapped time, a rejected one with the
/// phone's reason and a way to place it at the current time.
class HistoryView extends StatefulWidget {
  final TempoDatabase database;

  /// The phone's always-running Lap. Null on the Mac, which reads the Lap from
  /// the replica and never opens one of its own.
  final DayRecorder? dayRecorder;

  /// Every mutation goes through this seam. Defaults to the phone's
  /// [PhoneRecordCommands]; the Mac passes [RemoteRecordCommands].
  final RecordCommands? commands;

  /// The Mac's queue of proposed mutations. Null on the phone, where there is
  /// nothing pending.
  final IntentQueue? intentQueue;

  const HistoryView({
    super.key,
    required this.database,
    this.dayRecorder,
    this.commands,
    this.intentQueue,
  });

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  late final RecordCommands _commands = widget.commands ?? _phoneCommands();

  bool _isLoading = true;
  List<Record> _records = [];
  Map<String, Activity> _activitiesMap = {};
  Map<String, Tag> _tagsMap = {};
  List<Category> _categories = const [];
  List<QueuedIntent> _intents = const [];

  /// The Lap read from the replica on a Mac, where no DayRecorder exists.
  Lap? _replicaLap;

  RecordCommands _phoneCommands() {
    final recorder = widget.dayRecorder;
    if (recorder == null) {
      throw StateError('HistoryView needs commands or a DayRecorder.');
    }
    return PhoneRecordCommands(dayRecorder: recorder);
  }

  Lap? get _lap => widget.dayRecorder?.lap ?? _replicaLap;

  int get _elapsedMs =>
      _lap?.elapsedMs(DateTime.now().toUtc().millisecondsSinceEpoch) ?? 0;

  @override
  void initState() {
    super.initState();
    _loadData();
    widget.dayRecorder?.lapListenable.addListener(_onLapChanged);
  }

  @override
  void dispose() {
    widget.dayRecorder?.lapListenable.removeListener(_onLapChanged);
    super.dispose();
  }

  /// A new Lap means a Record was closed somewhere else; show it.
  void _onLapChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    if (!_isLoading && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final records = await widget.database.getRecords(
        orderBy: 'started_at_epoch_ms DESC',
        limit: 1000,
      );
      final activities = await widget.database.getAllActivities(
        includeArchived: true,
      );
      final tags = await widget.database.getAllTags();
      final categories = await widget.database.getCategories();
      final replicaLap = widget.dayRecorder == null
          ? await widget.database.getLap()
          : null;

      // Proposals the phone has not answered, or refused, so the Day can show
      // them in place. A queue that cannot be read must not hide the Records.
      var intents = <QueuedIntent>[];
      final queue = widget.intentQueue;
      if (queue != null) {
        try {
          intents = [
            ...await queue.pendingIntents(),
            ...await queue.rejectedIntents(),
          ]..sort((a, b) => a.tappedAtEpochMs.compareTo(b.tappedAtEpochMs));
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _records = records;
          _activitiesMap = {for (final a in activities) a.id: a};
          _tagsMap = {for (final t in tags) t.id: t};
          _categories = categories;
          _intents = intents;
          _replicaLap = replicaLap;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  static String _dayKey(String timezoneId, int epochMs) =>
      DateFormat('yyyy-MM-dd').format(wallClockAt(timezoneId, epochMs));

  /// Groups records by the local date in the zone each record started in.
  Map<String, List<Record>> _groupRecordsByDate() {
    final Map<String, List<Record>> grouped = {};
    for (final r in _records) {
      (grouped[_dayKey(r.timezoneId, r.startedAtEpochMs)] ??= []).add(r);
    }
    return grouped;
  }

  /// Activities offered for labeling: pinned first, then by name.
  List<Activity> _chooserActivities() {
    return _activitiesMap.values
        .where((activity) => !activity.isArchived)
        .toList()
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return a.name.compareTo(b.name);
      });
  }

  Future<void> _openLabelUntrackedDialog(Record record) async {
    final activity = await _pickActivity(record, offerCorrections: true);
    if (activity == null) return;
    await _applyEdit(() => _commands.relabel(record.id, activity.id));
  }

  /// The Activity chooser. Returns null when the sheet is dismissed.
  /// [offerCorrections] adds a way into the full edit sheet, so an Untracked
  /// Record can still be split or resized.
  Future<Activity?> _pickActivity(
    Record record, {
    bool offerCorrections = false,
  }) async {
    final activities = _chooserActivities();
    final timeRange = UiHelpers.formatZonedTimeRange(record);

    return showModalBottomSheet<Activity>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'What was it?',
                      style: TempoText.title.copyWith(
                        color: TempoColors.ink,
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Untracked · $timeRange',
                      style: TempoText.label.copyWith(
                        color: TempoColors.inkMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: [
                    for (final activity in activities)
                      ListTile(
                        minTileHeight: 52,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(TempoRadii.row),
                        ),
                        leading: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: UiHelpers.parseHexColor(activity.colorHex),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        title: Text(
                          activity.name,
                          style: TempoText.body.copyWith(
                            color: TempoColors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () => Navigator.of(ctx).pop(activity),
                      ),
                  ],
                ),
              ),
              if (offerCorrections)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: TempoColors.ink,
                      minimumSize: const Size(0, 48),
                      textStyle: TempoText.label,
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _openEditRecordDialog(record);
                    },
                    child: const Text('Split or adjust this time'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Runs a correction, then reloads. Refusals are shown in plain language.
  Future<bool> _applyEdit(Future<Object?> Function() action) async {
    try {
      await action();
      if (mounted) await _loadData();
      return true;
    } on RecordEditRefused catch (error) {
      _showEditMessage(error.message);
      return false;
    } on ArgumentError catch (error) {
      _showEditMessage(
        error.message?.toString() ?? 'That edit is not possible.',
      );
      return false;
    }
  }

  void _showEditMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The Record that starts exactly where [record] ends, if any.
  Record? _nextRecord(Record record) {
    for (final other in _records) {
      if (other.id != record.id &&
          other.startedAtEpochMs == record.endedAtEpochMs) {
        return other;
      }
    }
    return null;
  }

  String _recordName(Record record) =>
      _activitiesMap[record.activityId]?.name ?? 'Untracked';

  /// The edit sheet. Start, end, Activity, note and tags are staged and
  /// applied on Save; Split, Merge next and Untrack apply at once.
  Future<void> _openEditRecordDialog(Record record) async {
    final commentController = TextEditingController(text: record.comment);
    final next = _nextRecord(record);
    final startClock = wallClockAt(record.timezoneId, record.startedAtEpochMs);
    final stepMs = const Duration(minutes: 5).inMilliseconds;

    var pendingStartMs = record.startedAtEpochMs;
    var pendingEndMs = record.endedAtEpochMs;
    var pendingActivityId = record.activityId;
    List<String> selectedTagIds = List.from(record.tagIds);

    final allTags = _tagsMap.values.toList();
    final contactId = contactTagId(allTags);
    final savedReading = splitComment(record.comment).reading;
    final people = rankPeople(
      _records,
      nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      activityId: record.activityId,
    );
    final activities = _chooserActivities();
    final current = _activitiesMap[record.activityId];
    if (current != null && current.isArchived) activities.insert(0, current);
    // A few Activities usually started around this Record's time of day, so
    // the common relabel is one tap; the rest wait behind the picker.
    final aroundIds = activitiesAroundTime(
      _records.where((r) => r.id != record.id),
      atEpochMs: record.startedAtEpochMs,
      timezoneId: record.timezoneId,
      nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      allowed: {for (final a in activities) a.id},
    );
    final around = [for (final id in aroundIds) _activitiesMap[id]!];
    final aroundLabel = 'Around ${DateFormat('HH:mm').format(startClock)}';

    /// Asks for a wall-clock time in [zone] on the date of [currentMs] and
    /// returns its instant, or null when dismissed. A time that falls on the
    /// wrong side of the other edge is read as the neighbouring Day, so
    /// "22:00 → 02:00" works without a date field.
    Future<int?> pickInstant(
      BuildContext context,
      String zone,
      int currentMs, {
      required bool isEndEdge,
    }) async {
      final clock = wallClockAt(zone, currentMs);
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(clock),
      );
      if (time == null) return null;
      var wall = DateTime.utc(
        clock.year,
        clock.month,
        clock.day,
        time.hour,
        time.minute,
      );
      var instant = epochMsFromWallClock(
        wall,
        zone,
        referenceEpochMs: currentMs,
      );
      if (isEndEdge && instant <= pendingStartMs) {
        wall = wall.add(const Duration(days: 1));
      } else if (!isEndEdge && instant >= pendingEndMs) {
        wall = wall.subtract(const Duration(days: 1));
      } else {
        return instant;
      }
      instant = epochMsFromWallClock(wall, zone, referenceEpochMs: currentMs);
      return instant;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        // Every correction closes the sheet first, then applies and reports.
        Future<void> closeThenApply(Future<Object?> Function() action) async {
          if (ctx.mounted) Navigator.of(ctx).pop();
          await _applyEdit(action);
        }

        Future<void> save() async {
          final comment = commentController.text.trim();
          final tagIds = List<String>.of(selectedTagIds);
          final activityId = pendingActivityId;
          final startMs = pendingStartMs;
          final endMs = pendingEndMs;
          if (ctx.mounted) Navigator.of(ctx).pop();

          // Note and tags go through the commands seam so the CSV export
          // follows on the phone and a replica queues a proposal.
          if (!await _applyEdit(
            () =>
                _commands.annotate(record.id, comment: comment, tagIds: tagIds),
          )) {
            return;
          }
          if (activityId != null && activityId != record.activityId) {
            final ok = await _applyEdit(
              () => _commands.relabel(record.id, activityId),
            );
            if (!ok) return;
          }
          // Both edges move together. Only this Record changes; time it gives
          // up becomes Untracked and time it takes must already be Untracked.
          final startChanged = startMs != record.startedAtEpochMs;
          final endChanged = endMs != record.endedAtEpochMs;
          if (startChanged || endChanged) {
            await _applyEdit(
              () => _commands.adjustEdges(
                record.id,
                startEpochMs: startChanged ? startMs : null,
                endEpochMs: endChanged ? endMs : null,
              ),
            );
          }
        }

        Future<void> split(BuildContext context) async {
          final time = await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(
              startClock.add(Duration(milliseconds: record.elapsedMs ~/ 2)),
            ),
          );
          if (time == null) return;
          final instant = epochMsFromWallClock(
            DateTime.utc(
              startClock.year,
              startClock.month,
              startClock.day,
              time.hour,
              time.minute,
            ),
            record.timezoneId,
            referenceEpochMs: record.startedAtEpochMs,
          );
          await closeThenApply(() => _commands.splitRecord(record.id, instant));
        }

        Future<void> untrack(BuildContext context) async {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (dCtx) => AlertDialog(
              title: const Text('Make this time Untracked?'),
              content: const Text(
                'The time stays in your day, but it will need a label again.',
              ),
              actions: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: TempoColors.ink),
                  onPressed: () => Navigator.of(dCtx).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: TempoColors.ink,
                    textStyle: TempoText.label.copyWith(fontSize: 14),
                  ),
                  onPressed: () => Navigator.of(dCtx).pop(true),
                  child: const Text('Make Untracked'),
                ),
              ],
            ),
          );

          if (confirm == true) {
            await closeThenApply(() => _commands.clear(record.id));
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            final pendingActivity = _activitiesMap[pendingActivityId];
            final isUntracked = pendingActivityId == null;
            final name = pendingActivity?.name ?? 'Untracked';
            final dateLabel = DateFormat('EEE d MMM')
                .format(wallClockAt(record.timezoneId, pendingStartMs));
            final durationStr = UiHelpers.formatDurationHuman(
              math.max(0, pendingEndMs - pendingStartMs),
            );
            final startTime = DateFormat('HH:mm')
                .format(wallClockAt(record.timezoneId, pendingStartMs));
            final endTime = DateFormat('HH:mm')
                .format(wallClockAt(record.endTimezoneId, pendingEndMs));
            final startZoneLabel = zoneAbbreviationAt(
              record.timezoneId,
              pendingStartMs,
            );
            final endZoneLabel = zoneAbbreviationAt(
              record.endTimezoneId,
              pendingEndMs,
            );
            final startWall = wallClockAt(record.timezoneId, pendingStartMs);
            final endWall = wallClockAt(record.endTimezoneId, pendingEndMs);
            final spansDays =
                startWall.year != endWall.year ||
                startWall.month != endWall.month ||
                startWall.day != endWall.day;
            final startDayLabel = spansDays
                ? DateFormat('EEE d MMM').format(startWall)
                : null;
            final endDayLabel = spansDays
                ? DateFormat('EEE d MMM').format(endWall)
                : null;
            final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

            // The staged Activity, the Record's own when it differs, then the
            // suggestions: at most four chips before "All".
            final rowActivities = <Activity>[
              ?pendingActivity,
              if (current != null && current.id != pendingActivityId) current,
              ...around.where(
                (a) => a.id != pendingActivityId && a.id != current?.id,
              ),
            ].take(4).toList();

            Future<void> pickActivity() async {
              final picked = await showActivityPicker(
                context,
                activities: activities,
                categories: _categories,
                suggestions: around,
                currentId: pendingActivityId,
                subtitle: '$startTime–$endTime · now $name',
                aroundLabel: aroundLabel,
              );
              if (picked == null) return;
              setModalState(() => pendingActivityId = picked.id);
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header, with Change opening the Activity picker.
                      Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              container: true,
                              label: '$name, $dateLabel, $durationStr',
                              excludeSemantics: true,
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    clipBehavior: Clip.antiAlias,
                                    decoration: BoxDecoration(
                                      color: isUntracked
                                          ? TempoColors.track
                                          : UiHelpers.parseHexColor(
                                              pendingActivity?.colorHex,
                                            ),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: TempoColors.ink,
                                        width: 2,
                                      ),
                                    ),
                                    child: isUntracked
                                        ? const CustomPaint(
                                            painter: HatchPainter(
                                              color: historyHatch,
                                              spacing: 6,
                                            ),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: tempoFontFamily,
                                            fontSize: 30,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -1.2,
                                            height: 1.05,
                                            color: TempoColors.ink,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '$dateLabel · $durationStr',
                                          style: TempoText.label.copyWith(
                                            color: TempoColors.inkMuted,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SheetOutlineButton(
                            label: 'Change',
                            onPressed: pickActivity,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Edge steppers: each moves one edge of this Record.
                      // Time it gives up becomes Untracked; it only grows into
                      // time that is already Untracked.
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: EdgeStepper(
                                overline:
                                    'Start · $startZoneLabel'
                                    '${startDayLabel == null ? '' : ' · $startDayLabel'}',
                                edgeName: 'Start',
                                time: startTime,
                                caption: 'only this Record changes',
                                onEarlier: () => setModalState(
                                  () => pendingStartMs -= stepMs,
                                ),
                                onLater: pendingStartMs + stepMs < pendingEndMs
                                    ? () => setModalState(
                                        () => pendingStartMs += stepMs,
                                      )
                                    : null,
                                onPickTime: () async {
                                  final ms = await pickInstant(
                                    context,
                                    record.timezoneId,
                                    pendingStartMs,
                                    isEndEdge: false,
                                  );
                                  if (ms == null) return;
                                  setModalState(() => pendingStartMs = ms);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: EdgeStepper(
                                overline:
                                    'End · $endZoneLabel'
                                    '${endDayLabel == null ? '' : ' · $endDayLabel'}',
                                edgeName: 'End',
                                time: endTime,
                                caption: 'only this Record changes',
                                onEarlier:
                                    pendingEndMs - stepMs > pendingStartMs
                                    ? () => setModalState(
                                        () => pendingEndMs -= stepMs,
                                      )
                                    : null,
                                onLater: pendingEndMs + stepMs <= nowMs
                                    ? () => setModalState(
                                        () => pendingEndMs += stepMs,
                                      )
                                    : null,
                                onPickTime: () async {
                                  final ms = await pickInstant(
                                    context,
                                    record.endTimezoneId,
                                    pendingEndMs,
                                    isEndEdge: true,
                                  );
                                  if (ms == null) return;
                                  setModalState(() => pendingEndMs = ms);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Note and tags
                      SheetOverline(allTags.isEmpty ? 'Note' : 'Note & tags'),
                      const SizedBox(height: 2),
                      PeopleChips(
                        comment: commentController,
                        suggestions: people,
                        // AutoAdvance from the Records before this one,
                        // unless the Record already has a reading.
                        suggestReading: savedReading.isNotEmpty
                            ? null
                            : (first) => pendingActivityId == null
                                  ? null
                                  : suggestedReading(
                                      _records,
                                      activityId: pendingActivityId!,
                                      firstPerson: first,
                                      beforeEpochMs: record.startedAtEpochMs,
                                    ),
                        onPeopleChanged: (names) => setModalState(
                          () => selectedTagIds = tagIdsWithContact(
                            selectedTagIds,
                            contactId,
                            hasPeople: names.isNotEmpty,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: commentController,
                        cursorColor: TempoColors.ink,
                        style: TempoText.body.copyWith(color: TempoColors.ink),
                        decoration: InputDecoration(
                          hintText: 'Add a note',
                          hintStyle: TempoText.body.copyWith(
                            color: TempoColors.inkFaint,
                          ),
                          filled: true,
                          fillColor: TempoColors.paper,
                          contentPadding: const EdgeInsets.all(14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(TempoRadii.row),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      if (allTags.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final tag in allTags)
                              SheetChip(
                                label: tag.name,
                                height: 32,
                                selected: selectedTagIds.contains(tag.id),
                                onTap: () => setModalState(() {
                                  if (selectedTagIds.contains(tag.id)) {
                                    selectedTagIds.remove(tag.id);
                                  } else {
                                    selectedTagIds.add(tag.id);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 14),
                      // Activity: the current one, a few usually started
                      // around this time, and the full picker behind "All".
                      const SheetOverline('Activity'),
                      const SizedBox(height: 2),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final activity in rowActivities) ...[
                              SheetChip(
                                label: activity.name,
                                swatch: UiHelpers.parseHexColor(
                                  activity.colorHex,
                                ),
                                selected: activity.id == pendingActivityId,
                                onTap: () => setModalState(
                                  () => pendingActivityId = activity.id,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            SheetChip(
                              label: 'All ${activities.length}',
                              selected: false,
                              onTap: pickActivity,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Split, merge and untrack apply at once.
                      Row(
                        children: [
                          Expanded(
                            child: SheetOutlineButton(
                              label: 'Split…',
                              onPressed: () => split(context),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SheetOutlineButton(
                              label: 'Merge next',
                              onPressed: next == null
                                  ? null
                                  : () => closeThenApply(
                                      () => _commands.merge(record.id, next.id),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SheetOutlineButton(
                              label: 'Untrack',
                              onPressed: record.isUntracked
                                  ? null
                                  : () => untrack(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      FilledButton(
                        onPressed: save,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          backgroundColor: TempoColors.ink,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                            fontFamily: tempoFontFamily,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TempoColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: Colors.white,
          backgroundColor: TempoColors.surface,
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: TempoColors.textMuted,
                  ),
                )
              : _records.isEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                  children: [
                    _buildScreenTitle(),
                    const SizedBox(height: 48),
                    Center(
                      child: Text(
                        'Nothing recorded yet.',
                        style: TempoText.body.copyWith(
                          color: TempoColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                )
              : _buildGroupedRecordsList(),
        ),
      ),
    );
  }

  Widget _buildScreenTitle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      child: Text(
        'History',
        style: TempoText.screenTitle.copyWith(color: Colors.white),
      ),
    );
  }

  Widget _buildGroupedRecordsList() {
    var grouped = _groupRecordsByDate();
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final todayKey = _dayKey(localTimezoneId(), nowMs);

    final lap = _lap;
    String? lapKey;
    if (lap != null) {
      lapKey = _dayKey(
        lap.startTimezoneOr(localTimezoneId()),
        lap.startedAtEpochMs,
      );
      if (!grouped.containsKey(lapKey)) {
        grouped = {lapKey: <Record>[], ...grouped};
      }
    }
    final dateKeys = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      itemCount: dateKeys.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildScreenTitle();
        final dateKey = dateKeys[index - 1];
        return _buildDay(
          // Day sections run newest first; inside a Day the rows run newest
          // first too, with the open Lap above them.
          grouped[dateKey]!.reversed.toList(),
          isToday: dateKey == todayKey,
          lap: dateKey == lapKey ? lap : null,
          nowMs: nowMs,
          intents: [
            for (final queued in _intents)
              if (_dayKey(
                    queued.intent.tappedAtZoneId,
                    queued.tappedAtEpochMs,
                  ) ==
                  dateKey)
                queued,
          ],
        );
      },
    );
  }

  /// One Day: its header card and strip, then the timeline of its Records and,
  /// on the Day the open Lap belongs to, the Lap itself.
  Widget _buildDay(
    List<Record> records, {
    required bool isToday,
    required Lap? lap,
    required int nowMs,
    List<QueuedIntent> intents = const [],
  }) {
    final lapZone = lap?.startTimezoneOr(localTimezoneId());

    // The Day runs from local midnight in the zone it began in to local
    // midnight in the zone it ended in, so travel days are 21–27h long.
    final firstZone = records.isNotEmpty ? records.first.timezoneId : lapZone!;
    final firstMs = records.isNotEmpty
        ? records.first.startedAtEpochMs
        : lap!.startedAtEpochMs;
    final lastZone = lap != null ? lapZone! : records.last.endTimezoneId;
    final lastAnchorMs = lap != null
        ? lap.startedAtEpochMs
        : records.last.endedAtEpochMs - 1;
    final lastEndMs = records.isNotEmpty ? records.last.endedAtEpochMs : 0;

    final firstWall = wallClockAt(firstZone, firstMs);
    final dayStartMs = math.min(
      epochMsFromWallClock(
        DateTime.utc(firstWall.year, firstWall.month, firstWall.day),
        firstZone,
        referenceEpochMs: firstMs,
      ),
      firstMs,
    );
    final dayEndMs = math.max(
      nextLocalMidnightUtcMs(lastZone, lastAnchorMs),
      lastEndMs,
    );
    final dayLengthMs = dayEndMs - dayStartMs;
    final dayLength = UiHelpers.formatDurationHuman(dayLengthMs);

    final title = DateFormat('EEE d MMM').format(firstWall);
    final zoneRoute = firstZone == lastZone
        ? ''
        : ' · ${zoneAbbreviationAt(firstZone, dayStartMs)}'
              ' → ${zoneAbbreviationAt(lastZone, dayEndMs - 1)}';
    final meta = isToday
        ? 'Today · $dayLength$zoneRoute'
        : '$dayLength$zoneRoute';

    final lapSince = lap == null
        ? null
        : DateFormat('HH:mm')
              .format(wallClockAt(lapZone!, lap.startedAtEpochMs));

    final spans = _buildSpans(
      records,
      dayStartMs: dayStartMs,
      dayLengthMs: dayLengthMs,
      lap: lap,
      lapSince: lapSince,
      lapColor: isToday ? TempoColors.ink : Colors.white,
      nowMs: nowMs,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HistoryDayCard(
            title: title,
            meta: meta,
            isLive: isToday,
            spans: spans,
            semanticsLabel:
                '$title${isToday ? ', today' : ''}, a $dayLength day'
                '$zoneRoute, ${records.length} records',
          ),
          const SizedBox(height: 10),
          // The open-Lap block needs the phone's live ticker; the replica
          // shows the Lap in the strip above instead.
          if (lap != null && widget.dayRecorder != null)
            HistoryTimelineRow(
              time: lapSince!,
              block: HistoryOpenLapBlock(
                dayRecorder: widget.dayRecorder!,
                since: lapSince,
              ),
            ),
          for (final record in records.reversed)
            HistoryTimelineRow(
              time: DateFormat(
                'HH:mm',
              ).format(wallClockAt(record.timezoneId, record.startedAtEpochMs)),
              block: _buildRecordBlock(record),
            ),
          for (final queued in intents)
            HistoryTimelineRow(
              time: DateFormat('HH:mm').format(
                wallClockAt(
                  queued.intent.tappedAtZoneId,
                  queued.tappedAtEpochMs,
                ),
              ),
              block: _buildIntentBlock(queued),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- Pending proposals

  /// A proposal at its tapped time: outlined while the phone has not answered,
  /// outlined in the refusal colour with the reason once it has.
  Widget _buildIntentBlock(QueuedIntent queued) {
    final rejected = queued.isRejected;
    final title = _intentTitle(queued.intent);
    final accentColor = rejected
        ? const Color(0xFFE5534B)
        : TempoColors.inkMuted;

    return Semantics(
      container: true,
      label: rejected
          ? '$title was not placed. ${_rejectionText(queued.reason)}'
          : '$title is pending, waiting for the phone',
      child: Container(
        key: ValueKey('intent-${queued.intentId}'),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(TempoRadii.row),
          border: Border.all(color: accentColor, width: 1.4),
        ),
        child: Row(
          children: [
            Icon(
              rejected ? Icons.error_outline_rounded : Icons.schedule_rounded,
              size: 18,
              color: rejected ? accentColor : TempoColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rejected ? 'Not placed · $title' : 'Pending · $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TempoText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rejected
                        ? _rejectionText(queued.reason)
                        : 'Waiting for the phone',
                    style: TempoText.label.copyWith(
                      color: TempoColors.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            if (rejected)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: TempoColors.accent,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: TempoText.label.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => _placeAtNow(queued),
                child: const Text('Place at now'),
              ),
          ],
        ),
      ),
    );
  }

  String _intentTitle(SyncIntent intent) {
    switch (intent.kind) {
      case SyncIntentKind.label:
        return _activitiesMap[intent.activityId]?.name ?? 'Label';
      case SyncIntentKind.split:
        return 'Split';
      case SyncIntentKind.relabel:
        return 'Relabel';
      case SyncIntentKind.annotate:
        return 'Note';
      case SyncIntentKind.adjustEdges:
        return 'Edge change';
      case SyncIntentKind.clear:
        return 'Untrack';
      case SyncIntentKind.undo:
        return 'Undo';
      case SyncIntentKind.merge:
        return 'Merge';
      case SyncIntentKind.splitRecord:
        return 'Split';
    }
  }

  /// The phone's refusal in plain language.
  String _rejectionText(String reason) {
    switch (reason) {
      case IntentResult.reasonLapMoved:
        return 'The Untracked span had already moved on the phone.';
      case IntentResult.reasonOverlap:
        return 'That edit would overlap a labelled Record.';
      case IntentResult.reasonUnknownActivity:
        return 'That Activity no longer exists on the phone.';
      case IntentResult.reasonClockSkew:
        return 'The Mac and phone clocks differ by more than ten minutes.';
      case IntentResult.reasonUnknownRecord:
        return 'That Record is not on the phone.';
      default:
        return reason.isEmpty ? 'The phone did not place it.' : reason;
    }
  }

  /// Proposes the same change again at the current time, against the Lap start
  /// the replica shows now.
  Future<void> _placeAtNow(QueuedIntent queued) async {
    final intent = queued.intent;
    final ok = await _applyEdit(() async {
      switch (intent.kind) {
        case SyncIntentKind.label:
          await _commands.label(
            intent.activityId ?? '',
            comment: intent.comment,
            tags: intent.tagIds,
          );
        case SyncIntentKind.split:
          await _commands.split();
        case SyncIntentKind.relabel:
          await _commands.relabel(intent.recordId!, intent.activityId);
        case SyncIntentKind.annotate:
          await _commands.annotate(
            intent.recordId!,
            comment: intent.comment,
            tagIds: intent.tagIds,
          );
        case SyncIntentKind.adjustEdges:
          await _commands.adjustEdges(
            intent.recordId!,
            startEpochMs: intent.startEpochMs,
            endEpochMs: intent.endEpochMs,
          );
        case SyncIntentKind.clear:
          await _commands.clear(intent.recordId!);
        case SyncIntentKind.undo:
          await _commands.undo(recordId: intent.recordId);
        case SyncIntentKind.merge:
          await _commands.merge(intent.leftRecordId!, intent.rightRecordId!);
        case SyncIntentKind.splitRecord:
          await _commands.splitRecord(
            intent.recordId!,
            intent.atEpochMs ?? intent.tappedAtEpochMs,
          );
      }
      return null;
    });
    if (ok && mounted) {
      _showEditMessage('Queued for the phone at the current time.');
    }
  }

  List<DayStripSpan> _buildSpans(
    List<Record> records, {
    required int dayStartMs,
    required int dayLengthMs,
    required Lap? lap,
    required String? lapSince,
    required Color lapColor,
    required int nowMs,
  }) {
    if (dayLengthMs <= 0) return const [];
    double fraction(int epochMs) =>
        ((epochMs - dayStartMs) / dayLengthMs).clamp(0.0, 1.0);

    final spans = <DayStripSpan>[];
    for (final r in records) {
      final start = fraction(r.startedAtEpochMs);
      final end = math.max(fraction(r.endedAtEpochMs), start);
      final activity = r.isUntracked ? null : _activitiesMap[r.activityId];
      final zoneNote = r.crossesTimezones
          ? ', zone changed ${zoneAbbreviationAt(r.timezoneId, r.startedAtEpochMs)}'
                ' to ${zoneAbbreviationAt(r.endTimezoneId, r.endedAtEpochMs)}'
          : '';
      spans.add(
        DayStripSpan(
          start: start,
          end: end,
          color: r.isUntracked
              ? TempoColors.track
              : UiHelpers.parseHexColor(activity?.colorHex),
          hatched: r.isUntracked,
          semanticsLabel:
              '${_recordName(r)}, ${UiHelpers.formatZonedTimeRange(r)}'
              '$zoneNote, ${UiHelpers.formatDurationHuman(r.elapsedMs)}',
          marksZoneChange: r.crossesTimezones,
        ),
      );
    }

    if (lap != null) {
      final start = fraction(lap.startedAtEpochMs);
      spans.add(
        DayStripSpan(
          start: start,
          end: math.max(fraction(nowMs), start),
          color: lapColor,
          hatched: false,
          semanticsLabel:
              'Untracked since $lapSince, '
              '${UiHelpers.formatDurationHuman(_elapsedMs)}',
        ),
      );
    }
    return spans;
  }

  Widget _buildRecordBlock(Record record) {
    final timeRange = UiHelpers.formatZonedTimeRange(record);
    final durationStr = UiHelpers.formatDurationHuman(record.elapsedMs);
    final zonedRange = record.crossesTimezones ? timeRange : null;
    final noteLabel = record.comment.isEmpty ? '' : ', ${record.comment}';
    // The gutter already shows the start; show the end beside the duration.
    final endLabel = record.crossesTimezones
        ? null
        : 'until ${DateFormat('HH:mm').format(wallClockAt(record.endTimezoneId, record.endedAtEpochMs))}';

    if (record.isUntracked) {
      return HistoryUntrackedBlock(
        duration: durationStr,
        endLabel: endLabel,
        zonedRange: zonedRange,
        note: record.comment,
        semanticsLabel:
            'Untracked, $timeRange, $durationStr$noteLabel. What was it?',
        onTap: () => _openLabelUntrackedDialog(record),
      );
    }

    final activity = _activitiesMap[record.activityId];
    final name = _recordName(record);
    return HistoryRecordBlock(
      name: name,
      color: UiHelpers.parseHexColor(activity?.colorHex),
      duration: durationStr,
      endLabel: endLabel,
      zonedRange: zonedRange,
      note: record.comment,
      semanticsLabel: '$name, $timeRange, $durationStr$noteLabel. Edit',
      onTap: () => _openEditRecordDialog(record),
    );
  }
}
