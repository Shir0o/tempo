import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';

/// Historical records browser grouping sessions by day, with interactive
/// record editing, tag assignment, timestamp adjustment, and deletion.
class HistoryView extends StatefulWidget {
  final TempoDatabase database;

  const HistoryView({super.key, required this.database});

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

  /// Groups records by date string key "YYYY-MM-DD"
  Map<String, List<Record>> _groupRecordsByDate() {
    final Map<String, List<Record>> grouped = {};
    for (final r in _records) {
      final dt = DateTime.fromMillisecondsSinceEpoch(r.startedAtEpochMs);
      final key = DateFormat('yyyy-MM-dd').format(dt);
      (grouped[key] ??= []).add(r);
    }
    return grouped;
  }

  Future<void> _openEditRecordDialog(Record record) async {
    final activity = _activitiesMap[record.activityId];
    final color = UiHelpers.parseHexColor(activity?.colorHex);
    final commentController = TextEditingController(text: record.comment);

    DateTime startDateTime = DateTime.fromMillisecondsSinceEpoch(
      record.startedAtEpochMs,
    );
    DateTime endDateTime = DateTime.fromMillisecondsSinceEpoch(
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
        return StatefulBuilder(
          builder: (context, setModalState) {
            final durationMs =
                endDateTime.millisecondsSinceEpoch -
                startDateTime.millisecondsSinceEpoch;
            final durationStr = UiHelpers.formatDurationHuman(durationMs);

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
                                activity?.name ?? 'Record Details',
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
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Color(0xFFE57373),
                          ),
                          tooltip: 'Delete Record',
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (dCtx) => AlertDialog(
                                backgroundColor: const Color(0xFF22222C),
                                title: const Text(
                                  'Delete Record?',
                                  style: TextStyle(color: Colors.white),
                                ),
                                content: const Text(
                                  'This record will be permanently deleted and a tombstone recorded.',
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
                                      'Delete',
                                      style: TextStyle(color: Colors.redAccent),
                                    ),
                                  ),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              await widget.database.deleteRecord(record.id);
                              if (ctx.mounted) Navigator.of(ctx).pop();
                              _loadData();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Timestamp Picker Row
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
                                initialTime: TimeOfDay.fromDateTime(
                                  startDateTime,
                                ),
                              );
                              if (time != null) {
                                setModalState(() {
                                  startDateTime = DateTime(
                                    startDateTime.year,
                                    startDateTime.month,
                                    startDateTime.day,
                                    time.hour,
                                    time.minute,
                                  );
                                  if (endDateTime.isBefore(startDateTime)) {
                                    endDateTime = startDateTime.add(
                                      const Duration(minutes: 30),
                                    );
                                  }
                                });
                              }
                            },
                            child: Column(
                              children: [
                                const Text(
                                  'START',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat('HH:mm').format(startDateTime),
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
                                initialTime: TimeOfDay.fromDateTime(
                                  endDateTime,
                                ),
                              );
                              if (time != null) {
                                setModalState(() {
                                  endDateTime = DateTime(
                                    endDateTime.year,
                                    endDateTime.month,
                                    endDateTime.day,
                                    time.hour,
                                    time.minute,
                                  );
                                  if (endDateTime.isBefore(startDateTime)) {
                                    startDateTime = endDateTime.subtract(
                                      const Duration(minutes: 30),
                                    );
                                  }
                                });
                              }
                            },
                            child: Column(
                              children: [
                                const Text(
                                  'END',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  DateFormat('HH:mm').format(endDateTime),
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

                    // Save Button
                    ElevatedButton(
                      onPressed: () async {
                        final updated = record.copyWith(
                          comment: commentController.text.trim(),
                          startedAtEpochMs:
                              startDateTime.millisecondsSinceEpoch,
                          endedAtEpochMs: endDateTime.millisecondsSinceEpoch,
                          durationMs:
                              endDateTime.millisecondsSinceEpoch -
                              startDateTime.millisecondsSinceEpoch,
                          updatedAtEpochMs: DateTime.now()
                              .toUtc()
                              .millisecondsSinceEpoch,
                          tagIds: selectedTagIds,
                        );

                        await widget.database.updateRecord(updated);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        _loadData();
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
                        'Save Changes',
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
        final firstDate = DateTime.fromMillisecondsSinceEpoch(
          recordsForDate.first.startedAtEpochMs,
        );
        final headerTitle = UiHelpers.formatDateHeader(firstDate);

        final totalDayMs = recordsForDate.fold<int>(
          0,
          (sum, r) => sum + r.durationMs,
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
    final activity = _activitiesMap[record.activityId];
    final color = UiHelpers.parseHexColor(activity?.colorHex);
    final icon = UiHelpers.getIconData(activity?.iconName);
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      record.startedAtEpochMs,
    );
    final endTime = DateTime.fromMillisecondsSinceEpoch(record.endedAtEpochMs);
    final timeRange = UiHelpers.formatTimeRange(startTime, endTime);
    final durationStr = UiHelpers.formatDurationHuman(record.durationMs);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openEditRecordDialog(record),
          borderRadius: BorderRadius.circular(12),
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
                        activity?.name ?? 'Unknown Activity',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
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
    );
  }
}
