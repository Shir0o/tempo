import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/state/day_recorder.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../core/time/timezone_id.dart';
import 'helpers/ui_helpers.dart';

/// Historical records browser grouping sessions by day, with interactive
/// record editing, tag assignment, timestamp adjustment, and deletion.
class HistoryView extends StatefulWidget {
  final TempoDatabase database;
  final DayRecorder dayRecorder;

  const HistoryView({
    super.key,
    required this.database,
    required this.dayRecorder,
  });

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  bool _isLoading = true;
  List<Record> _records = [];
  Map<String, Activity> _activitiesMap = {};
  Map<String, Tag> _tagsMap = {};

  @override
  void initState() {
    super.initState();
    _loadData();
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

      if (mounted) {
        setState(() {
          _records = records;
          _activitiesMap = {for (final a in activities) a.id: a};
          _tagsMap = {for (final t in tags) t.id: t};
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Groups records by the local date in the zone each record started in.
  Map<String, List<Record>> _groupRecordsByDate() {
    final Map<String, List<Record>> grouped = {};
    for (final r in _records) {
      final dt = wallClockAt(r.timezoneId, r.startedAtEpochMs);
      final key = DateFormat('yyyy-MM-dd').format(dt);
      (grouped[key] ??= []).add(r);
    }
    return grouped;
  }

  Future<void> _openLabelUntrackedDialog(Record record) async {
    final activity = await _pickActivity(record, offerCorrections: true);
    if (activity == null) return;
    await _applyEdit(() => widget.dayRecorder.relabel(record.id, activity.id));
  }

  /// The Activity chooser. Returns null when the sheet is dismissed.
  /// [offerCorrections] adds a way into the full edit sheet, so an Untracked
  /// Record can still be split or resized.
  Future<Activity?> _pickActivity(
    Record record, {
    bool offerCorrections = false,
  }) async {
    final activities =
        _activitiesMap.values.where((activity) => !activity.isArchived).toList()
          ..sort((a, b) {
            if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
            return a.name.compareTo(b.name);
          });
    final timeRange = UiHelpers.formatZonedTimeRange(record);

    return showModalBottomSheet<Activity>(
      context: context,
      backgroundColor: const Color(0xFF1C1C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'What was it?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timeRange,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    for (final activity in activities)
                      ListTile(
                        leading: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: UiHelpers.parseHexColor(activity.colorHex),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(
                          activity.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
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
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _openEditRecordDialog(record);
                    },
                    child: const Text(
                      'Split or adjust this time',
                      style: TextStyle(color: Colors.white60, fontSize: 13),
                    ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF22222C),
      ),
    );
  }

  /// The Record that ends exactly where [record] starts, if any.
  Record? _previousRecord(Record record) {
    for (final other in _records) {
      if (other.id != record.id &&
          other.endedAtEpochMs == record.startedAtEpochMs) {
        return other;
      }
    }
    return null;
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

  Future<void> _openEditRecordDialog(Record record) async {
    final activity = _activitiesMap[record.activityId];
    final color = UiHelpers.parseHexColor(activity?.colorHex);
    final commentController = TextEditingController(text: record.comment);
    final previous = _previousRecord(record);
    final next = _nextRecord(record);

    final startClock = wallClockAt(record.timezoneId, record.startedAtEpochMs);
    final endClock = wallClockAt(record.endTimezoneId, record.endedAtEpochMs);
    final startZoneLabel = zoneAbbreviationAt(
      record.timezoneId,
      record.startedAtEpochMs,
    );
    final endZoneLabel = zoneAbbreviationAt(
      record.endTimezoneId,
      record.endedAtEpochMs,
    );
    List<String> selectedTagIds = List.from(record.tagIds);

    final allTags = _tagsMap.values.toList();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        // Every correction closes the sheet first, then applies and reports.
        Future<void> closeThenApply(Future<Object?> Function() action) async {
          if (ctx.mounted) Navigator.of(ctx).pop();
          await _applyEdit(action);
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            final durationStr = UiHelpers.formatDurationHuman(record.elapsedMs);

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            UiHelpers.getIconData(activity?.iconName),
                            color: color,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                activity?.name ?? 'Untracked',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                durationStr,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!record.isUntracked)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Color(0xFFE57373),
                            ),
                            tooltip: 'Make Untracked',
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (dCtx) => AlertDialog(
                                  backgroundColor: const Color(0xFF22222C),
                                  title: const Text(
                                    'Make this time Untracked?',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  content: const Text(
                                    'The time stays in your day, but it will need a label again.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(dCtx).pop(false),
                                      child: const Text(
                                        'Cancel',
                                        style: TextStyle(color: Colors.white60),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(dCtx).pop(true),
                                      child: const Text(
                                        'Make Untracked',
                                        style: TextStyle(
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              if (confirm == true) {
                                await closeThenApply(
                                  () => widget.dayRecorder.delete(record.id),
                                );
                              }
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Boundary row: the start resizes the previous Record, the
                    // end resizes this one. Both neighbours change together.
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          InkWell(
                            onTap: () async {
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(startClock),
                              );
                              if (time == null) return;
                              final previousRecord = previous;
                              if (previousRecord == null) {
                                _showEditMessage(
                                  'There is no earlier Record to share this '
                                  'edge with.',
                                );
                                return;
                              }
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
                              await closeThenApply(
                                () => widget.dayRecorder.moveBoundary(
                                  previousRecord.id,
                                  instant,
                                ),
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  'START · $startZoneLabel',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat('HH:mm').format(startClock),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward,
                            color: Colors.white24,
                            size: 16,
                          ),
                          InkWell(
                            onTap: () async {
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(endClock),
                              );
                              if (time == null) return;
                              final instant = epochMsFromWallClock(
                                DateTime.utc(
                                  endClock.year,
                                  endClock.month,
                                  endClock.day,
                                  time.hour,
                                  time.minute,
                                ),
                                record.endTimezoneId,
                                referenceEpochMs: record.endedAtEpochMs,
                              );
                              await closeThenApply(
                                () => widget.dayRecorder.moveBoundary(
                                  record.id,
                                  instant,
                                ),
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  'END · $endZoneLabel',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat('HH:mm').format(endClock),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Comment field
                    TextField(
                      controller: commentController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Notes / Comment',
                        labelStyle: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                        hintText: 'e.g. w/ Bob - Planning discussion',
                        hintStyle: const TextStyle(
                          color: Colors.white24,
                          fontSize: 12,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Tags selector
                    if (allTags.isNotEmpty) ...[
                      const Text(
                        'TAGS',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: allTags.map((tag) {
                          final isSelected = selectedTagIds.contains(tag.id);
                          return FilterChip(
                            label: Text(tag.name),
                            selected: isSelected,
                            selectedColor: const Color(0xFF4CAF50)
                                .withValues(alpha: 0.3),
                            checkmarkColor: Colors.white,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.white60,
                              fontSize: 11,
                            ),
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.05,
                            ),
                            side: BorderSide(
                              color: isSelected
                                  ? const Color(0xFF4CAF50)
                                  : Colors.transparent,
                            ),
                            onSelected: (selected) {
                              setModalState(() {
                                if (selected) {
                                  selectedTagIds.add(tag.id);
                                } else {
                                  selectedTagIds.remove(tag.id);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Activity, split and merge corrections
                    OutlinedButton.icon(
                      onPressed: () async {
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        final picked = await _pickActivity(record);
                        if (picked == null) return;
                        await _applyEdit(
                          () =>
                              widget.dayRecorder.relabel(record.id, picked.id),
                        );
                      },
                      icon: Icon(
                        record.isUntracked ? Icons.add : Icons.swap_horiz,
                        size: 16,
                        color: Colors.white70,
                      ),
                      label: Text(
                        record.isUntracked ? 'What was it?' : 'Change Activity',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () async {
                              final time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.fromDateTime(
                                  startClock.add(
                                    Duration(
                                      milliseconds: record.elapsedMs ~/ 2,
                                    ),
                                  ),
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
                              await closeThenApply(
                                () => widget.dayRecorder.splitRecord(
                                  record.id,
                                  instant,
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.content_cut,
                              size: 16,
                              color: Colors.white60,
                            ),
                            label: const Text(
                              'Split…',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        if (next != null)
                          Expanded(
                            child: TextButton.icon(
                              onPressed: () => closeThenApply(
                                () => widget.dayRecorder.merge(
                                  record.id,
                                  next.id,
                                ),
                              ),
                              icon: const Icon(
                                Icons.merge_type,
                                size: 16,
                                color: Colors.white60,
                              ),
                              label: const Text(
                                'Merge with next',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Save Button
                    ElevatedButton(
                      onPressed: () async {
                        await closeThenApply(
                          () => widget.dayRecorder.annotate(
                            record.id,
                            comment: commentController.text.trim(),
                            tagIds: selectedTagIds,
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        'Save note & tags',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
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
      backgroundColor: const Color(0xFF121216),
      appBar: AppBar(
        title: const Text(
          'History',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: const Color(0xFF121216),
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: const Color(0xFF4CAF50),
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
                )
              : _records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 56,
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No recorded sessions yet.',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : _buildGroupedRecordsList(),
        ),
      ),
    );
  }

  Widget _buildGroupedRecordsList() {
    final grouped = _groupRecordsByDate();
    final dateKeys = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: dateKeys.length,
      itemBuilder: (context, dateIndex) {
        final dateKey = dateKeys[dateIndex];
        final recordsForDate = grouped[dateKey]!;
        final firstDate = wallClockAt(
          recordsForDate.first.timezoneId,
          recordsForDate.first.startedAtEpochMs,
        );
        final headerTitle = UiHelpers.formatDateHeader(firstDate);

        final totalDayMs = recordsForDate.fold<int>(
          0,
          (sum, r) => sum + r.elapsedMs,
        );
        final totalDayStr = UiHelpers.formatDurationHuman(totalDayMs);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    headerTitle.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    totalDayStr,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            for (final record in recordsForDate) _buildRecordTile(record),
          ],
        );
      },
    );
  }

  Widget _buildRecordTile(Record record) {
    final isUntracked = record.isUntracked;
    final activity = isUntracked ? null : _activitiesMap[record.activityId];
    final color = isUntracked
        ? const Color(0xFF9E9E9E)
        : UiHelpers.parseHexColor(activity?.colorHex);
    final icon = isUntracked
        ? Icons.help_outline
        : UiHelpers.getIconData(activity?.iconName);
    final timeRange = UiHelpers.formatZonedTimeRange(record);
    final durationStr = UiHelpers.formatDurationHuman(record.elapsedMs);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isUntracked ? const Color(0xFF202027) : const Color(0xFF1A1A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => isUntracked
              ? _openLabelUntrackedDialog(record)
              : _openEditRecordDialog(record),
          borderRadius: BorderRadius.circular(12),
          child: CustomPaint(
            painter: isUntracked ? const _HatchPainter() : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Color strip + Icon
                  Container(
                    width: 4,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: color, size: 16),
                  ),
                  const SizedBox(width: 12),
                  // Name + Time Range + Comment
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activity?.name ?? 'Untracked',
                          style: TextStyle(
                            color: isUntracked ? Colors.white60 : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontStyle: isUntracked
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          timeRange,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (record.comment.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            record.comment,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Duration Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      durationStr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
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
}

/// Diagonal hatching that marks a Record as still needing an Activity.
class _HatchPainter extends CustomPainter {
  const _HatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    const gap = 7.0;
    for (var x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HatchPainter oldDelegate) => false;
}
