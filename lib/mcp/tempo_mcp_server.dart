import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../core/export/csv_export_engine.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';
import 'pii_sanitizer.dart';

/// Local Model Context Protocol (MCP) Server for Tempo.
///
/// Implements JSON-RPC 2.0 protocol over stdio for external AI assistants.
/// Provides rich analytical tools (active timer, daily summary, historical query,
/// trends) and guarded write tools (start, stop, manual add) gated behind `--allow-writes`.
class TempoMcpServer {
  final TempoDatabase database;
  final PIISanitizer sanitizer;
  final bool allowWrites;
  final CsvExportEngine? csvExportEngine;

  TempoMcpServer({
    required this.database,
    PIISanitizer? sanitizer,
    this.allowWrites = false,
    this.csvExportEngine,
  }) : sanitizer = sanitizer ?? PIISanitizer();

  /// Processes a stream of JSON-RPC lines from standard input and yields
  /// formatted JSON-RPC responses.
  Stream<String> processStream(Stream<String> lines) async* {
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final response = await handleMessage(trimmed);
      if (response != null) {
        yield response;
      }
    }
  }

  /// Handles a single incoming JSON-RPC 2.0 message string.
  /// Returns the JSON-RPC response string, or null if the message was a notification.
  Future<String?> handleMessage(String rawJson) async {
    Map<String, dynamic> request;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) {
        return jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {
            'code': -32600,
            'message': 'Invalid Request: root must be a JSON object',
          },
        });
      }
      request = decoded;
    } catch (_) {
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': null,
        'error': {
          'code': -32700,
          'message': 'Parse error: invalid JSON payload',
        },
      });
    }

    final id = request['id'];
    final method = request['method'] as String?;
    final params = (request['params'] as Map<String, dynamic>?) ?? {};

    // Notifications do not receive responses
    if (method == 'notifications/initialized' || method == 'initialized') {
      return null;
    }

    if (id == null && method == null) {
      return null;
    }

    try {
      switch (method) {
        case 'initialize':
          return _handleInitialize(id, params);
        case 'ping':
          return _handlePing(id);
        case 'tools/list':
          return _handleToolsList(id);
        case 'tools/call':
          return await _handleToolsCall(id, params);
        default:
          return jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Method not found: $method'},
          });
      }
    } catch (e, stack) {
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': -32603,
          'message': 'Internal error: $e',
          'data': stack.toString(),
        },
      });
    }
  }

  String _handleInitialize(dynamic id, Map<String, dynamic> params) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'tempo-mcp', 'version': '1.0.0'},
      },
    });
  }

  String _handlePing(dynamic id) {
    return jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {}});
  }

  String _handleToolsList(dynamic id) {
    final tools = <Map<String, dynamic>>[
      {
        'name': 'get_active_timer',
        'description': 'Returns the status of the currently ticking timer, elapsed seconds, activity, comment, and tags.',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'get_daily_summary',
        'description': 'Aggregates total tracked time, record count, and category breakdown for a single day.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'date': {
              'type': 'string',
              'description': 'Target date in YYYY-MM-DD format (UTC). Defaults to current day.',
            },
          },
        },
      },
      {
        'name': 'query_records',
        'description': 'Searches historical time records with date range, activity name, and tag filters with sanitized comments.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'start_date': {
              'type': 'string',
              'description': 'Inclusive start date (YYYY-MM-DD).',
            },
            'end_date': {
              'type': 'string',
              'description': 'Inclusive end date (YYYY-MM-DD).',
            },
            'activity_name': {
              'type': 'string',
              'description': 'Optional activity name filter.',
            },
            'tag': {
              'type': 'string',
              'description': 'Optional tag name filter (e.g. "Contact").',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max records to return (default: 50, max: 200).',
            },
          },
          'required': ['start_date', 'end_date'],
        },
      },
      {
        'name': 'analyze_trends',
        'description': 'Calculates multi-week habit consistency, time-of-day hourly histogram (00:00-23:00), and habit streaks.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'lookback_weeks': {
              'type': 'integer',
              'description':
                  'Number of historical weeks to analyze (default: 4).',
            },
          },
        },
      },
    ];

    if (allowWrites) {
      tools.addAll([
        {
          'name': 'start_timer',
          'description':
              'Starts the active timer for an activity (guarded write tool).',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'activity_name': {
                'type': 'string',
                'description': 'Name of the activity to track.',
              },
              'comment': {
                'type': 'string',
                'description': 'Optional comment for this session.',
              },
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Optional list of tag names.',
              },
            },
            'required': ['activity_name'],
          },
        },
        {
          'name': 'stop_timer',
          'description': 'Stops the currently active timer and records the session (guarded write tool).',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'comment': {
                'type': 'string',
                'description': 'Optional final comment to record.',
              },
            },
          },
        },
        {
          'name': 'add_manual_record',
          'description': 'Manually logs a past completed time session (guarded write tool).',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'activity_name': {
                'type': 'string',
                'description': 'Name of the activity.',
              },
              'start_time': {
                'type': 'string',
                'description': 'Start timestamp in ISO 8601 format.',
              },
              'end_time': {
                'type': 'string',
                'description': 'End timestamp in ISO 8601 format.',
              },
              'comment': {'type': 'string', 'description': 'Optional comment.'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Optional list of tag names.',
              },
            },
            'required': ['activity_name', 'start_time', 'end_time'],
          },
        },
      ]);
    }

    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {'tools': tools},
    });
  }

  Future<String> _handleToolsCall(
    dynamic id,
    Map<String, dynamic> params,
  ) async {
    final toolName = params['name'] as String?;
    final args = (params['arguments'] as Map<String, dynamic>?) ?? {};

    if (toolName == null) {
      return _errorToolResponse(
        id,
        'Missing tool name in tools/call parameters.',
      );
    }

    // Enforce mutation guard for write tools
    if (toolName == 'start_timer' ||
        toolName == 'stop_timer' ||
        toolName == 'add_manual_record') {
      if (!allowWrites) {
        return _errorToolResponse(
          id,
          'Mutation tool "$toolName" is disabled. The MCP server is running in read-only mode. Launch with --allow-writes to enable write operations.',
        );
      }
    }

    try {
      switch (toolName) {
        case 'get_active_timer':
          final result = await _getActiveTimerTool();
          return _successToolResponse(id, result);

        case 'get_daily_summary':
          final result = await _getDailySummaryTool(args);
          return _successToolResponse(id, result);

        case 'query_records':
          final result = await _queryRecordsTool(args);
          return _successToolResponse(id, result);

        case 'analyze_trends':
          final result = await _analyzeTrendsTool(args);
          return _successToolResponse(id, result);

        case 'start_timer':
          final result = await _startTimerTool(args);
          return _successToolResponse(id, result);

        case 'stop_timer':
          final result = await _stopTimerTool(args);
          return _successToolResponse(id, result);

        case 'add_manual_record':
          final result = await _addManualRecordTool(args);
          return _successToolResponse(id, result);

        default:
          return _errorToolResponse(id, 'Unknown tool: "$toolName".');
      }
    } catch (e) {
      return _errorToolResponse(id, e.toString());
    }
  }

  // ==========================================
  // Analytical Tool Implementations
  // ==========================================

  Future<Map<String, dynamic>> _getActiveTimerTool() async {
    final active = await database.getActiveTimer();
    if (active == null) {
      return {
        'is_tracking': false,
        'activity_name': null,
        'color_hex': null,
        'started_at': null,
        'elapsed_seconds': 0,
        'is_paused': false,
        'comment': '',
        'tags': <String>[],
      };
    }

    final activity = await database.getActivityById(active.activityId);
    final nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final durationMs = active.calculateDurationMs(nowUtc);

    final allTags = await database.getAllTags();
    final tagMap = {for (final t in allTags) t.id: t.name};
    final tagNames = active.initialTagIds
        .map((id) => tagMap[id] ?? id)
        .toList();

    return {
      'is_tracking': !active.isPaused,
      'activity_name': activity?.name ?? 'Unknown',
      'color_hex': activity?.colorHex ?? '#4CAF50',
      'started_at': DateTime.fromMillisecondsSinceEpoch(
        active.startedAtEpochMs,
        isUtc: true,
      ).toIso8601String(),
      'elapsed_seconds': durationMs ~/ 1000,
      'is_paused': active.isPaused,
      'comment': sanitizer.sanitize(active.currentComment),
      'tags': tagNames,
    };
  }

  Future<Map<String, dynamic>> _getDailySummaryTool(
    Map<String, dynamic> args,
  ) async {
    final dateStr =
        (args['date'] as String?)?.trim() ??
        DateTime.now().toUtc().toIso8601String().substring(0, 10);

    final parsed = DateTime.parse('${dateStr}T00:00:00Z');
    final startMs = parsed.millisecondsSinceEpoch;
    final endMs = DateTime.parse('${dateStr}T23:59:59.999Z')
        .millisecondsSinceEpoch;

    final records = await database.getRecords(
      startedAfter: startMs,
      startedBefore: endMs,
    );

    var totalDurationMs = 0;
    final activityDurations = <String, int>{};

    for (final r in records) {
      totalDurationMs += r.durationMs;
      activityDurations[r.activityId] =
          (activityDurations[r.activityId] ?? 0) + r.durationMs;
    }

    final activities = await database.getAllActivities(includeArchived: true);
    final activityMap = {for (final a in activities) a.id: a};

    final breakdown = <Map<String, dynamic>>[];
    for (final entry in activityDurations.entries) {
      final activityName = activityMap[entry.key]?.name ?? entry.key;
      final hours = entry.value / 3600000.0;
      final pct = totalDurationMs > 0
          ? (entry.value / totalDurationMs) * 100.0
          : 0.0;
      breakdown.add({
        'activity': activityName,
        'hours': double.parse(hours.toStringAsFixed(2)),
        'percentage': double.parse(pct.toStringAsFixed(1)),
      });
    }

    breakdown.sort(
      (a, b) => (b['hours'] as double).compareTo(a['hours'] as double),
    );

    final totalHours = totalDurationMs / 3600000.0;

    return {
      'date': dateStr,
      'total_duration_hours': double.parse(totalHours.toStringAsFixed(2)),
      'total_records_count': records.length,
      'breakdown': breakdown,
    };
  }

  Future<List<Map<String, dynamic>>> _queryRecordsTool(
    Map<String, dynamic> args,
  ) async {
    final startDateStr = args['start_date'] as String?;
    final endDateStr = args['end_date'] as String?;
    if (startDateStr == null || endDateStr == null) {
      throw ArgumentError('start_date and end_date are required');
    }

    final startMs = DateTime.parse('${startDateStr}T00:00:00Z')
        .millisecondsSinceEpoch;
    final endMs = DateTime.parse('${endDateStr}T23:59:59.999Z')
        .millisecondsSinceEpoch;
    final limit = (args['limit'] as int? ?? 50).clamp(1, 200);

    final activityFilter = args['activity_name'] as String?;
    final tagFilter = args['tag'] as String?;

    final allActivities = await database.getAllActivities(
      includeArchived: true,
    );
    final activityMap = {for (final a in allActivities) a.id: a};

    String? activityIdFilter;
    if (activityFilter != null && activityFilter.trim().isNotEmpty) {
      final match = allActivities.firstWhereOrNull(
        (a) => a.name.toLowerCase() == activityFilter.trim().toLowerCase(),
      );
      if (match == null) {
        return <Map<String, dynamic>>[];
      }
      activityIdFilter = match.id;
    }

    final allTags = await database.getAllTags();
    final tagMap = {for (final t in allTags) t.id: t.name};

    String? tagIdFilter;
    if (tagFilter != null && tagFilter.trim().isNotEmpty) {
      final match = allTags.firstWhereOrNull(
        (t) => t.name.toLowerCase() == tagFilter.trim().toLowerCase(),
      );
      if (match == null) {
        return <Map<String, dynamic>>[];
      }
      tagIdFilter = match.id;
    }

    final records = await database.getRecords(
      startedAfter: startMs,
      startedBefore: endMs,
      activityId: activityIdFilter,
    );

    final filtered = tagIdFilter != null
        ? records.where((r) => r.tagIds.contains(tagIdFilter)).toList()
        : records;

    final limited = filtered.take(limit).toList();

    return limited.map((r) {
      final actName = activityMap[r.activityId]?.name ?? r.activityId;
      final tagNames = r.tagIds.map((tid) => tagMap[tid] ?? tid).toList();
      return {
        'id': r.id,
        'activity_name': actName,
        'started_at': DateTime.fromMillisecondsSinceEpoch(
          r.startedAtEpochMs,
          isUtc: true,
        ).toIso8601String(),
        'ended_at': DateTime.fromMillisecondsSinceEpoch(
          r.endedAtEpochMs,
          isUtc: true,
        ).toIso8601String(),
        'duration_seconds': r.durationMs ~/ 1000,
        'comment': sanitizer.sanitize(r.comment),
        'tags': tagNames,
      };
    }).toList();
  }

  Future<Map<String, dynamic>> _analyzeTrendsTool(
    Map<String, dynamic> args,
  ) async {
    final lookbackWeeks = (args['lookback_weeks'] as int? ?? 4).clamp(1, 52);
    final nowUtc = DateTime.now().toUtc();
    final startMs =
        nowUtc.millisecondsSinceEpoch - (lookbackWeeks * 7 * 24 * 3600 * 1000);

    final records = await database.getRecords(startedAfter: startMs);
    final allActivities = await database.getAllActivities(
      includeArchived: true,
    );
    final activityMap = {for (final a in allActivities) a.id: a};

    // 1. Weekly averages
    final activityTotals = <String, int>{};
    for (final r in records) {
      activityTotals[r.activityId] =
          (activityTotals[r.activityId] ?? 0) + r.durationMs;
    }
    final weeklyAverages = <String, double>{};
    for (final entry in activityTotals.entries) {
      final actName = activityMap[entry.key]?.name ?? entry.key;
      final avgHours = (entry.value / 3600000.0) / lookbackWeeks;
      weeklyAverages[actName] = double.parse(avgHours.toStringAsFixed(2));
    }

    // 2. Time-of-day hourly distribution (00:00 - 23:00)
    final timeOfDayDistribution = <String, double>{};
    for (var h = 0; h < 24; h++) {
      final key = '${h.toString().padLeft(2, '0')}:00';
      timeOfDayDistribution[key] = 0.0;
    }
    for (final r in records) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        r.startedAtEpochMs,
        isUtc: true,
      );
      final key = '${dt.hour.toString().padLeft(2, '0')}:00';
      final hours = r.durationMs / 3600000.0;
      timeOfDayDistribution[key] = double.parse(
        ((timeOfDayDistribution[key] ?? 0.0) + hours).toStringAsFixed(2),
      );
    }

    // 3. Habit streaks (pinned habits)
    final pinnedActivities = allActivities.where((a) => a.isPinned).toList();
    final habitStreaks = <Map<String, dynamic>>[];

    for (final act in pinnedActivities) {
      final actRecords = await database.getRecords(activityId: act.id);
      final days =
          actRecords
              .map(
                (r) => DateTime.fromMillisecondsSinceEpoch(
                  r.startedAtEpochMs,
                  isUtc: true,
                ).toIso8601String().substring(0, 10),
              )
              .toSet()
              .toList()
            ..sort();

      var maxStreak = 0;
      var currentStreak = 0;

      if (days.isNotEmpty) {
        var tempStreak = 1;
        maxStreak = 1;
        for (var i = 1; i < days.length; i++) {
          final prevDate = DateTime.parse('${days[i - 1]}T00:00:00Z');
          final currDate = DateTime.parse('${days[i]}T00:00:00Z');
          if (currDate.difference(prevDate).inDays == 1) {
            tempStreak++;
            if (tempStreak > maxStreak) {
              maxStreak = tempStreak;
            }
          } else {
            tempStreak = 1;
          }
        }

        final todayStr = nowUtc.toIso8601String().substring(0, 10);
        final yesterdayStr = nowUtc
            .subtract(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10);

        if (days.contains(todayStr) || days.contains(yesterdayStr)) {
          var checkDay = days.contains(todayStr)
              ? nowUtc
              : nowUtc.subtract(const Duration(days: 1));
          while (days.contains(checkDay.toIso8601String().substring(0, 10))) {
            currentStreak++;
            checkDay = checkDay.subtract(const Duration(days: 1));
          }
        }
      }

      habitStreaks.add({
        'activity': act.name,
        'current_streak_days': currentStreak,
        'max_streak_days': maxStreak,
      });
    }

    return {
      'lookback_weeks': lookbackWeeks,
      'weekly_averages': weeklyAverages,
      'time_of_day_distribution': timeOfDayDistribution,
      'habit_streaks': habitStreaks,
    };
  }

  // ==========================================
  // Guarded Write Tools
  // ==========================================

  Future<Map<String, dynamic>> _startTimerTool(
    Map<String, dynamic> args,
  ) async {
    final activityName = args['activity_name'] as String?;
    if (activityName == null || activityName.trim().isEmpty) {
      throw ArgumentError('activity_name is required');
    }

    final comment = args['comment'] as String? ?? '';
    final rawTags = args['tags'];
    final tagNames = rawTags is List
        ? rawTags.map((e) => e.toString()).toList()
        : <String>[];

    final activity = await _getOrCreateActivity(activityName);
    final tagIds = await _getOrCreateTagIds(tagNames);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final currentTimer = await database.getActiveTimer();
    if (currentTimer != null) {
      final duration = currentTimer.calculateDurationMs(now);
      final refEnd =
          (currentTimer.isPaused && currentTimer.pausedAtEpochMs != null)
          ? currentTimer.pausedAtEpochMs!
          : now;
      final record = Record(
        id: const Uuid().v4(),
        activityId: currentTimer.activityId,
        startedAtEpochMs: currentTimer.startedAtEpochMs,
        endedAtEpochMs: refEnd,
        durationMs: duration,
        comment: currentTimer.currentComment,
        timezoneId: DateTime.now().timeZoneName,
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
        tagIds: currentTimer.initialTagIds,
      );
      await database.insertRecord(record);
      if (csvExportEngine != null) {
        await csvExportEngine!.scheduleExport();
      }
    }

    final newTimer = ActiveTimer(
      id: 1,
      activityId: activity.id,
      startedAtEpochMs: now,
      isPaused: false,
      pausedAtEpochMs: null,
      accumulatedPauseMs: 0,
      currentComment: comment,
      initialTagIds: tagIds,
      lastHeartbeatEpochMs: now,
      revision: (currentTimer != null) ? currentTimer.revision + 1 : 1,
    );

    await database.setActiveTimer(newTimer);

    return {
      'success': true,
      'activity_name': activity.name,
      'started_at': DateTime.fromMillisecondsSinceEpoch(
        newTimer.startedAtEpochMs,
        isUtc: true,
      ).toIso8601String(),
      'comment': newTimer.currentComment,
      'tags': tagNames,
    };
  }

  Future<Map<String, dynamic>> _stopTimerTool(Map<String, dynamic> args) async {
    final currentTimer = await database.getActiveTimer();
    if (currentTimer == null) {
      return {
        'success': false,
        'message': 'No active timer is currently running.',
      };
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final duration = currentTimer.calculateDurationMs(now);
    final refEnd =
        (currentTimer.isPaused && currentTimer.pausedAtEpochMs != null)
        ? currentTimer.pausedAtEpochMs!
        : now;

    final finalComment =
        (args['comment'] as String?) ?? currentTimer.currentComment;
    final record = Record(
      id: const Uuid().v4(),
      activityId: currentTimer.activityId,
      startedAtEpochMs: currentTimer.startedAtEpochMs,
      endedAtEpochMs: refEnd,
      durationMs: duration,
      comment: finalComment,
      timezoneId: DateTime.now().timeZoneName,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
      tagIds: currentTimer.initialTagIds,
    );

    await database.insertRecord(record);
    await database.deleteActiveTimer();

    if (csvExportEngine != null) {
      await csvExportEngine!.scheduleExport();
    }

    final activity = await database.getActivityById(record.activityId);

    return {
      'success': true,
      'record_id': record.id,
      'activity_name': activity?.name ?? 'Unknown',
      'duration_seconds': record.durationMs ~/ 1000,
      'comment': record.comment,
    };
  }

  Future<Map<String, dynamic>> _addManualRecordTool(
    Map<String, dynamic> args,
  ) async {
    final activityName = args['activity_name'] as String?;
    final startTimeStr = args['start_time'] as String?;
    final endTimeStr = args['end_time'] as String?;

    if (activityName == null || startTimeStr == null || endTimeStr == null) {
      throw ArgumentError(
        'activity_name, start_time, and end_time are required',
      );
    }

    final startDt = DateTime.parse(startTimeStr).toUtc();
    final endDt = DateTime.parse(endTimeStr).toUtc();
    if (endDt.isBefore(startDt)) {
      throw ArgumentError(
        'end_time must be greater than or equal to start_time',
      );
    }

    final startMs = startDt.millisecondsSinceEpoch;
    final endMs = endDt.millisecondsSinceEpoch;
    final durationMs = endMs - startMs;

    final comment = args['comment'] as String? ?? '';
    final rawTags = args['tags'];
    final tagNames = rawTags is List
        ? rawTags.map((e) => e.toString()).toList()
        : <String>[];

    final activity = await _getOrCreateActivity(activityName);
    final tagIds = await _getOrCreateTagIds(tagNames);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    final record = Record(
      id: const Uuid().v4(),
      activityId: activity.id,
      startedAtEpochMs: startMs,
      endedAtEpochMs: endMs,
      durationMs: durationMs,
      comment: comment,
      timezoneId: DateTime.now().timeZoneName,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
      tagIds: tagIds,
    );

    await database.insertRecord(record);
    if (csvExportEngine != null) {
      await csvExportEngine!.scheduleExport();
    }

    return {
      'success': true,
      'record_id': record.id,
      'activity_name': activity.name,
      'duration_seconds': durationMs ~/ 1000,
    };
  }

  // ==========================================
  // Helper Methods
  // ==========================================

  Future<Activity> _getOrCreateActivity(String name) async {
    final all = await database.getAllActivities(includeArchived: true);
    for (final a in all) {
      if (a.name.toLowerCase() == name.trim().toLowerCase()) {
        return a;
      }
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final newActivity = Activity(
      id: const Uuid().v4(),
      name: name.trim(),
      colorHex: '#4CAF50',
      iconName: 'schedule',
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );
    await database.insertActivity(newActivity);
    return newActivity;
  }

  Future<List<String>> _getOrCreateTagIds(List<String> tagNames) async {
    final tagIds = <String>[];
    final all = await database.getAllTags();
    final tagMap = {for (final t in all) t.name.toLowerCase(): t};

    for (final rawName in tagNames) {
      final cleanName = rawName.trim();
      if (cleanName.isEmpty) continue;
      final existing = tagMap[cleanName.toLowerCase()];
      if (existing != null) {
        tagIds.add(existing.id);
      } else {
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final newTag = Tag(
          id: const Uuid().v4(),
          name: cleanName,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );
        await database.insertTag(newTag);
        tagMap[cleanName.toLowerCase()] = newTag;
        tagIds.add(newTag.id);
      }
    }
    return tagIds;
  }

  String _successToolResponse(dynamic id, dynamic data) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'content': [
          {'type': 'text', 'text': jsonEncode(data)},
        ],
        'isError': false,
      },
    });
  }

  String _errorToolResponse(dynamic id, String message) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'content': [
          {'type': 'text', 'text': 'Error: $message'},
        ],
        'isError': true,
      },
    });
  }
}

extension _IterableFirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
