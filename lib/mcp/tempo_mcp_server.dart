import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../core/export/csv_export_engine.dart';
import '../core/state/day_recorder.dart';
import '../core/time/timezone_id.dart';
import '../data/database/tempo_database.dart';
import '../data/models/models.dart';
import 'pii_sanitizer.dart';

/// Local Model Context Protocol (MCP) Server for Tempo.
///
/// Implements JSON-RPC 2.0 protocol over stdio for external AI assistants.
/// Read tools describe Days plainly: a Day's timeline, time per Activity over a
/// range, Untracked Records, and comparisons between Days. Write tools (label
/// the Lap, split the Lap, adjust a Record's edge) are gated behind
/// `--allow-writes`.
class TempoMcpServer {
  static const Set<String> _writeToolNames = {
    'label_lap',
    'split_lap',
    'adjust_record_edge',
  };

  final TempoDatabase database;
  final PIISanitizer sanitizer;
  final bool allowWrites;
  final CsvExportEngine? csvExportEngine;
  final String Function() zoneProvider;
  final int Function() nowUtcMs;
  final DayRecorder? _injectedRecorder;
  bool _recorderInitialized = false;

  late final DayRecorder _recorder =
      _injectedRecorder ??
      DayRecorder(
        database: database,
        nowUtcMs: nowUtcMs,
        getTimezoneId: zoneProvider,
        csvExportEngine: csvExportEngine,
      );

  TempoMcpServer({
    required this.database,
    PIISanitizer? sanitizer,
    this.allowWrites = false,
    this.csvExportEngine,
    String Function()? zoneProvider,
    int Function()? nowUtcMs,
    DayRecorder? dayRecorder,
  }) : sanitizer = sanitizer ?? PIISanitizer(),
       zoneProvider = zoneProvider ?? localTimezoneId,
       nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _injectedRecorder = dayRecorder;

  Future<DayRecorder> _readyRecorder() async {
    if (!_recorderInitialized) {
      // The recorder schedules the CSV export after every write.
      final engine = csvExportEngine;
      if (engine != null) _recorder.csvExportEngine ??= engine;
      await _recorder.initialize();
      _recorderInitialized = true;
    }
    return _recorder;
  }

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
        'name': 'get_day_timeline',
        'description':
            "Lists one Day's Records in order, each with the wall-clock times "
            'and IANA zones it started and ended in, plus the Day length, '
            'Untracked Records and the open Lap.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'date': {
              'type': 'string',
              'description': 'The Day to describe, in YYYY-MM-DD format. Defaults to today.',
            },
            'timezone': {
              'type': 'string',
              'description':
                  'IANA zone whose local midnight bounds the Day (e.g. '
                  '"America/Los_Angeles"). Defaults to this device\'s zone.',
            },
          },
        },
      },
      {
        'name': 'get_time_per_activity',
        'description':
            'Totals time per Activity over an inclusive date range, with the '
            'count and length of Untracked Records.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'start_date': {
              'type': 'string',
              'description': 'Inclusive first Day (YYYY-MM-DD).',
            },
            'end_date': {
              'type': 'string',
              'description': 'Inclusive last Day (YYYY-MM-DD).',
            },
            'timezone': {
              'type': 'string',
              'description':
                  'IANA zone used for the Day boundaries. Defaults to this '
                  "device's zone.",
            },
          },
          'required': ['start_date', 'end_date'],
        },
      },
      {
        'name': 'get_untracked_records',
        'description':
            'Lists Untracked Records (time with no Activity yet) over an '
            'inclusive date range, with their count and total length.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'start_date': {
              'type': 'string',
              'description': 'Inclusive first Day (YYYY-MM-DD).',
            },
            'end_date': {
              'type': 'string',
              'description': 'Inclusive last Day (YYYY-MM-DD).',
            },
            'timezone': {
              'type': 'string',
              'description':
                  'IANA zone used for the Day boundaries. Defaults to this '
                  "device's zone.",
            },
          },
          'required': ['start_date', 'end_date'],
        },
      },
      {
        'name': 'compare_days',
        'description':
            'Compares several Days side by side: each Day length, time per '
            'Activity, Untracked Records, and the change in each Activity\'s '
            'time between the first and last Day.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'dates': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Two or more Days to compare, in YYYY-MM-DD format. They are '
                  'reported in date order.',
            },
            'timezone': {
              'type': 'string',
              'description':
                  'IANA zone used for the Day boundaries. Defaults to this '
                  "device's zone.",
            },
          },
          'required': ['dates'],
        },
      },
      {
        'name': 'query_records',
        'description':
            'Searches Records by date range, Activity, or tag, returning start '
            'and end times in the zones they happened in with sanitized '
            'comments.',
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
              'description': 'Optional Activity name filter.',
            },
            'tag': {
              'type': 'string',
              'description': 'Optional tag name filter (e.g. "Contact").',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max Records to return (default: 50, max: 200).',
            },
            'timezone': {
              'type': 'string',
              'description':
                  'IANA zone used for the date range boundaries. Defaults to '
                  "this device's zone.",
            },
          },
          'required': ['start_date', 'end_date'],
        },
      },
    ];

    if (allowWrites) {
      tools.addAll([
        {
          'name': 'label_lap',
          'description':
              'Labels the open Lap with an existing Activity, closing it as a '
              'Record ending now and opening a new Lap. Unknown Activities '
              'are refused. Requires --allow-writes.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'activity_name': {
                'type': 'string',
                'description': 'Name of the Activity that filled the Lap.',
              },
              'comment': {
                'type': 'string',
                'description': 'Optional comment for this Record.',
              },
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Optional tag names.',
              },
            },
            'required': ['activity_name'],
          },
        },
        {
          'name': 'split_lap',
          'description':
              'Closes the open Lap as an Untracked Record and opens a new Lap '
              'at the same instant. Requires --allow-writes.',
          'inputSchema': {'type': 'object', 'properties': {}},
        },
        {
          'name': 'adjust_record_edge',
          'description':
              'Moves the start or end of one Record to a new instant. Only '
              'that Record changes: time it gives up becomes Untracked, and it '
              'may only grow into time that is already Untracked or the open '
              'Lap. Refused when the instant would overlap a labelled Record '
              'or land after now. Requires --allow-writes.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'record_id': {
                'type': 'string',
                'description': 'Id of the Record whose edge moves.',
              },
              'edge': {
                'type': 'string',
                'enum': ['start', 'end'],
                'description': 'Which edge of the Record moves.',
              },
              'new_instant': {
                'type': 'string',
                'description':
                    'New edge as an ISO 8601 instant with an explicit '
                    'offset, e.g. "2026-10-30T09:30:00Z".',
              },
            },
            'required': ['record_id', 'edge', 'new_instant'],
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
    if (_writeToolNames.contains(toolName) && !allowWrites) {
      return _errorToolResponse(
        id,
        'Mutation tool "$toolName" is disabled. The MCP server is running in read-only mode. Launch with --allow-writes to enable write operations.',
      );
    }

    try {
      switch (toolName) {
        case 'get_day_timeline':
          final result = await _getDayTimelineTool(args);
          return _successToolResponse(id, result);

        case 'get_time_per_activity':
          final result = await _getTimePerActivityTool(args);
          return _successToolResponse(id, result);

        case 'get_untracked_records':
          final result = await _getUntrackedRecordsTool(args);
          return _successToolResponse(id, result);

        case 'compare_days':
          final result = await _compareDaysTool(args);
          return _successToolResponse(id, result);

        case 'query_records':
          final result = await _queryRecordsTool(args);
          return _successToolResponse(id, result);

        case 'label_lap':
          final result = await _labelLapTool(args);
          return _successToolResponse(id, result);

        case 'split_lap':
          final result = await _splitLapTool();
          return _successToolResponse(id, result);

        case 'adjust_record_edge':
          final result = await _adjustRecordEdgeTool(args);
          return _successToolResponse(id, result);

        default:
          return _errorToolResponse(id, 'Unknown tool: "$toolName".');
      }
    } catch (e) {
      return _errorToolResponse(id, e.toString());
    }
  }

  // ==========================================
  // Read Tools
  // ==========================================

  Future<Map<String, dynamic>> _getDayTimelineTool(
    Map<String, dynamic> args,
  ) async {
    final zone = _zoneArg(args);
    final date = _optionalDate(args['date']) ?? _todayInZone(zone);
    final window = _dayWindow(date, zone);

    final records = await _recordsOverlapping(window.startMs, window.endMs);
    final activities = await _activityMap();
    final tags = await _tagMap();
    final lap = await database.getLap();
    final openLap = _describeLap(lap, window.startMs, window.endMs, zone);

    final untracked = records.where((r) => r.isUntracked);
    final labelledMs = _labelledOverlapMs(
      records,
      window.startMs,
      window.endMs,
    );
    final untrackedMs = _untrackedOverlapMs(
      untracked,
      window.startMs,
      window.endMs,
    );

    return {
      'date': date,
      'timezone': zone,
      'started_at': _isoUtc(window.startMs),
      'ended_at': _isoUtc(window.endMs),
      'day_length_seconds': (window.endMs - window.startMs) ~/ 1000,
      'labelled_seconds': labelledMs ~/ 1000,
      'untracked_records': {
        'count': untracked.length,
        'duration_seconds': untrackedMs ~/ 1000,
      },
      'open_lap': openLap,
      'records': _describeRecords(records, activities, tags),
    };
  }

  Future<Map<String, dynamic>> _getTimePerActivityTool(
    Map<String, dynamic> args,
  ) async {
    final zone = _zoneArg(args);
    final startDate = _requiredDate(args, 'start_date');
    final endDate = _requiredDate(args, 'end_date');
    final window = _rangeWindow(startDate, endDate, zone);

    final records = await _recordsOverlapping(window.startMs, window.endMs);
    final activities = await _activityMap();
    final lap = await database.getLap();
    final perActivity = <String, _ActivityTotal>{};

    for (final record in records) {
      if (record.isUntracked) continue;
      final overlapMs = _overlapMs(
        record.startedAtEpochMs,
        record.endedAtEpochMs,
        window.startMs,
        window.endMs,
      );
      if (overlapMs <= 0) continue;
      final name = _activityName(record, activities);
      final total = perActivity.putIfAbsent(name, () => _ActivityTotal());
      total.durationMs += overlapMs;
      total.recordCount += 1;
    }

    final totals = perActivity.entries.toList()
      ..sort((a, b) => b.value.durationMs.compareTo(a.value.durationMs));

    final untracked = records.where((r) => r.isUntracked).toList();
    final openLap = _describeLap(lap, window.startMs, window.endMs, zone);

    return {
      'start_date': startDate,
      'end_date': endDate,
      'timezone': zone,
      'started_at': _isoUtc(window.startMs),
      'ended_at': _isoUtc(window.endMs),
      'labelled_seconds':
          _labelledOverlapMs(records, window.startMs, window.endMs) ~/ 1000,
      'untracked_records': {
        'count': untracked.length,
        'duration_seconds':
            _untrackedOverlapMs(untracked, window.startMs, window.endMs) ~/
            1000,
      },
      'open_lap_seconds': (openLap?['elapsed_seconds_in_window'] as int?) ?? 0,
      'time_per_activity': [
        for (final entry in totals)
          {
            'activity': entry.key,
            'duration_ms': entry.value.durationMs,
            'duration_seconds': entry.value.durationMs ~/ 1000,
            'record_count': entry.value.recordCount,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _getUntrackedRecordsTool(
    Map<String, dynamic> args,
  ) async {
    final zone = _zoneArg(args);
    final startDate = _requiredDate(args, 'start_date');
    final endDate = _requiredDate(args, 'end_date');
    final window = _rangeWindow(startDate, endDate, zone);

    final records = await _recordsOverlapping(window.startMs, window.endMs);
    final untracked = records.where((r) => r.isUntracked).toList();
    final activities = await _activityMap();
    final tags = await _tagMap();
    final lap = await database.getLap();
    final openLap = _describeLap(lap, window.startMs, window.endMs, zone);

    return {
      'start_date': startDate,
      'end_date': endDate,
      'timezone': zone,
      'started_at': _isoUtc(window.startMs),
      'ended_at': _isoUtc(window.endMs),
      'count': untracked.length,
      'total_duration_seconds':
          _untrackedOverlapMs(untracked, window.startMs, window.endMs) ~/ 1000,
      'open_lap': openLap,
      'records': _describeRecords(untracked, activities, tags),
    };
  }

  Future<Map<String, dynamic>> _compareDaysTool(
    Map<String, dynamic> args,
  ) async {
    final zone = _zoneArg(args);
    final rawDates = args['dates'];
    if (rawDates is! List || rawDates.length < 2) {
      throw ArgumentError('dates must list at least two Days (YYYY-MM-DD).');
    }
    if (rawDates.length > 14) {
      throw ArgumentError('dates can compare at most fourteen Days.');
    }
    final dates = rawDates.map((value) {
      final date = _optionalDate(value);
      if (date == null) {
        throw ArgumentError('Every entry in dates must be YYYY-MM-DD.');
      }
      return date;
    }).toList()..sort();

    final activities = await _activityMap();
    final lap = await database.getLap();
    final days = <Map<String, dynamic>>[];
    final perActivityByDate = <String, Map<String, int>>{};

    for (final date in dates) {
      final window = _dayWindow(date, zone);
      final records = await _recordsOverlapping(window.startMs, window.endMs);
      final perActivity = <String, int>{};
      for (final record in records) {
        if (record.isUntracked) continue;
        final overlapMs = _overlapMs(
          record.startedAtEpochMs,
          record.endedAtEpochMs,
          window.startMs,
          window.endMs,
        );
        if (overlapMs <= 0) continue;
        final name = _activityName(record, activities);
        perActivity[name] = (perActivity[name] ?? 0) + overlapMs;
      }
      for (final entry in perActivity.entries) {
        (perActivityByDate[entry.key] ??= {})[date] = entry.value;
      }

      final untracked = records.where((r) => r.isUntracked).toList();
      final openLap = _describeLap(lap, window.startMs, window.endMs, zone);

      days.add({
        'date': date,
        'day_length_seconds': (window.endMs - window.startMs) ~/ 1000,
        'labelled_seconds':
            _labelledOverlapMs(records, window.startMs, window.endMs) ~/ 1000,
        'untracked_records': {
          'count': untracked.length,
          'duration_seconds':
              _untrackedOverlapMs(untracked, window.startMs, window.endMs) ~/
              1000,
        },
        'open_lap_seconds':
            (openLap?['elapsed_seconds_in_window'] as int?) ?? 0,
        'time_per_activity': {
          for (final entry in perActivity.entries)
            entry.key: entry.value ~/ 1000,
        },
      });
    }

    final firstDate = dates.first;
    final lastDate = dates.last;
    final entries = perActivityByDate.entries.toList()
      ..sort((a, b) {
        final totalA = a.value.values.fold<int>(0, (sum, ms) => sum + ms);
        final totalB = b.value.values.fold<int>(0, (sum, ms) => sum + ms);
        return totalB.compareTo(totalA);
      });

    return {
      'timezone': zone,
      'days': days,
      'differences': [
        for (final entry in entries)
          {
            'activity': entry.key,
            'from_date': firstDate,
            'to_date': lastDate,
            'difference_seconds':
                ((entry.value[lastDate] ?? 0) -
                    (entry.value[firstDate] ?? 0)) ~/
                1000,
          },
      ],
    };
  }

  Future<List<Map<String, dynamic>>> _queryRecordsTool(
    Map<String, dynamic> args,
  ) async {
    final zone = _zoneArg(args);
    final startDate = _requiredDate(args, 'start_date');
    final endDate = _requiredDate(args, 'end_date');
    final window = _rangeWindow(startDate, endDate, zone);
    final limit = (args['limit'] as int? ?? 50).clamp(1, 200);

    final activityFilter = args['activity_name'] as String?;
    final tagFilter = args['tag'] as String?;

    final allActivities = await database.getAllActivities(
      includeArchived: true,
    );
    final activities = {for (final a in allActivities) a.id: a.name};
    final tags = await _tagMap();

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

    String? tagIdFilter;
    if (tagFilter != null && tagFilter.trim().isNotEmpty) {
      final match = (await database.getAllTags()).firstWhereOrNull(
        (t) => t.name.toLowerCase() == tagFilter.trim().toLowerCase(),
      );
      if (match == null) {
        return <Map<String, dynamic>>[];
      }
      tagIdFilter = match.id;
    }

    final records = await _recordsOverlapping(window.startMs, window.endMs);
    final filtered = records
        .where(
          (r) =>
              (activityIdFilter == null || r.activityId == activityIdFilter) &&
              (tagIdFilter == null || r.tagIds.contains(tagIdFilter)),
        )
        .take(limit)
        .toList();

    return _describeRecords(filtered, activities, tags);
  }

  // ==========================================
  // Write Tools
  // ==========================================

  Future<Map<String, dynamic>> _labelLapTool(Map<String, dynamic> args) async {
    final activityName = (args['activity_name'] as String?)?.trim();
    if (activityName == null || activityName.isEmpty) {
      throw ArgumentError('activity_name is required.');
    }
    final comment = args['comment'] as String? ?? '';
    final rawTags = args['tags'];
    final tagNames = rawTags is List
        ? rawTags.map((e) => e.toString()).toList()
        : <String>[];

    final activity = await _findActivity(activityName);
    if (activity == null) {
      // Like the deep links, never create an Activity, so a typo cannot
      // silently change what the Lap means.
      throw ArgumentError('Unknown Activity "$activityName".');
    }
    final tagIds = await _getOrCreateTagIds(tagNames);

    final recorder = await _readyRecorder();
    final record = await recorder.label(
      activity.id,
      comment: comment,
      tags: tagIds,
    );

    return {'success': true, 'record': await _describeRecord(record)};
  }

  Future<Map<String, dynamic>> _splitLapTool() async {
    final recorder = await _readyRecorder();
    final record = await recorder.split();

    return {'success': true, 'record': await _describeRecord(record)};
  }

  Future<Map<String, dynamic>> _adjustRecordEdgeTool(
    Map<String, dynamic> args,
  ) async {
    final recordId = (args['record_id'] as String?)?.trim();
    if (recordId == null || recordId.isEmpty) {
      throw ArgumentError('record_id is required.');
    }
    final edge = (args['edge'] as String?)?.trim();
    if (edge != 'start' && edge != 'end') {
      throw ArgumentError('edge must be "start" or "end".');
    }
    final rawInstant = (args['new_instant'] as String?)?.trim();
    if (rawInstant == null || rawInstant.isEmpty) {
      throw ArgumentError(
        'new_instant is required (ISO 8601 with an offset, e.g. '
        '2026-10-30T09:30:00Z).',
      );
    }
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(rawInstant)) {
      throw ArgumentError(
        'new_instant must be an ISO 8601 instant with an explicit offset, '
        'e.g. 2026-10-30T09:30:00Z.',
      );
    }

    final newInstantMs = DateTime.parse(rawInstant)
        .toUtc()
        .millisecondsSinceEpoch;

    final recorder = await _readyRecorder();
    final record = await recorder.adjustEdges(
      recordId,
      startEpochMs: edge == 'start' ? newInstantMs : null,
      endEpochMs: edge == 'end' ? newInstantMs : null,
    );

    return {'success': true, 'record': await _describeRecord(record)};
  }

  // ==========================================
  // Day and Range Helpers
  // ==========================================

  String _zoneArg(Map<String, dynamic> args) {
    final raw = (args['timezone'] as String?)?.trim();
    final zone = (raw == null || raw.isEmpty) ? zoneProvider() : raw;
    if (utcOffsetAt(zone, nowUtcMs()) == null) {
      throw ArgumentError(
        'Unknown timezone "$zone". Use an IANA zone id such as '
        'America/Los_Angeles.',
      );
    }
    return zone;
  }

  String _requiredDate(Map<String, dynamic> args, String key) {
    final date = _optionalDate(args[key]);
    if (date == null) {
      throw ArgumentError('$key is required in YYYY-MM-DD format.');
    }
    return date;
  }

  String? _optionalDate(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw ArgumentError('Date must be a YYYY-MM-DD string.');
    }
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) {
      throw ArgumentError('Date "$raw" must be in YYYY-MM-DD format.');
    }
    final parsed = DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    if (parsed.year != int.parse(match.group(1)!) ||
        parsed.month != int.parse(match.group(2)!) ||
        parsed.day != int.parse(match.group(3)!)) {
      throw ArgumentError('Date "$raw" is not a real calendar date.');
    }
    return raw;
  }

  String _todayInZone(String zone) {
    final wall = wallClockAt(zone, nowUtcMs());
    return '${wall.year.toString().padLeft(4, '0')}-'
        '${wall.month.toString().padLeft(2, '0')}-'
        '${wall.day.toString().padLeft(2, '0')}';
  }

  ({int startMs, int endMs}) _dayWindow(String date, String zone) {
    final day = DateTime.parse('${date}T00:00:00Z');
    final noonInstant = epochMsFromWallClock(
      DateTime.utc(day.year, day.month, day.day, 12),
      zone,
      referenceEpochMs: day.millisecondsSinceEpoch,
    );
    final startMs = _localDayStartUtcMs(zone, noonInstant);
    return (startMs: startMs, endMs: nextLocalMidnightUtcMs(zone, startMs));
  }

  ({int startMs, int endMs}) _rangeWindow(
    String startDate,
    String endDate,
    String zone,
  ) {
    final startMs = _dayWindow(startDate, zone).startMs;
    final endMs = _dayWindow(endDate, zone).endMs;
    if (endMs <= startMs) {
      throw ArgumentError('end_date must not be before start_date.');
    }
    return (startMs: startMs, endMs: endMs);
  }

  /// The first instant of the local Day containing [epochMs] in [zone].
  int _localDayStartUtcMs(String zone, int epochMs) {
    final target = _wallDate(wallClockAt(zone, epochMs));
    var probe = epochMs - const Duration(hours: 30).inMilliseconds;
    var guard = 0;
    while (!_wallDate(wallClockAt(zone, probe)).isBefore(target) &&
        guard++ < 4) {
      probe -= const Duration(hours: 30).inMilliseconds;
    }
    return nextLocalMidnightUtcMs(zone, probe);
  }

  DateTime _wallDate(DateTime wall) =>
      DateTime.utc(wall.year, wall.month, wall.day);

  Future<List<Record>> _recordsOverlapping(int startMs, int endMs) async {
    final records = await database.getRecords(
      startedAfter: startMs - const Duration(hours: 30).inMilliseconds,
      startedBefore: endMs - 1,
      orderBy: 'started_at_epoch_ms ASC',
    );
    return records
        .where((r) => r.endedAtEpochMs > startMs && r.startedAtEpochMs < endMs)
        .toList();
  }

  int _labelledOverlapMs(Iterable<Record> records, int startMs, int endMs) =>
      records
          .where((r) => !r.isUntracked)
          .fold<int>(
            0,
            (sum, r) =>
                sum +
                _overlapMs(
                  r.startedAtEpochMs,
                  r.endedAtEpochMs,
                  startMs,
                  endMs,
                ),
          );

  int _untrackedOverlapMs(Iterable<Record> records, int startMs, int endMs) =>
      records
          .where((r) => r.isUntracked)
          .fold<int>(
            0,
            (sum, r) =>
                sum +
                _overlapMs(
                  r.startedAtEpochMs,
                  r.endedAtEpochMs,
                  startMs,
                  endMs,
                ),
          );

  int _overlapMs(int startA, int endA, int startB, int endB) {
    final start = startA > startB ? startA : startB;
    final end = endA < endB ? endA : endB;
    return end > start ? end - start : 0;
  }

  Map<String, dynamic>? _describeLap(
    Lap? lap,
    int windowStartMs,
    int windowEndMs,
    String fallbackZone,
  ) {
    if (lap == null || lap.startedAtEpochMs >= windowEndMs) return null;
    final zone = lap.startTimezoneOr(fallbackZone);
    final now = nowUtcMs();
    final openUntil = now < windowEndMs ? now : windowEndMs;
    final overlapStart = lap.startedAtEpochMs > windowStartMs
        ? lap.startedAtEpochMs
        : windowStartMs;
    final elapsedInWindowMs = openUntil - overlapStart;
    return {
      'started_at': _isoUtc(lap.startedAtEpochMs),
      'started_at_local': _formatWall(wallClockAt(zone, lap.startedAtEpochMs)),
      'start_timezone': zone,
      'elapsed_seconds': lap.elapsedMs(now) ~/ 1000,
      'elapsed_seconds_in_window': elapsedInWindowMs < 0
          ? 0
          : elapsedInWindowMs ~/ 1000,
    };
  }

  // ==========================================
  // Record Description
  // ==========================================

  Future<Map<String, String>> _activityMap() async {
    final activities = await database.getAllActivities(includeArchived: true);
    return {for (final a in activities) a.id: a.name};
  }

  Future<Map<String, String>> _tagMap() async {
    final tags = await database.getAllTags();
    return {for (final t in tags) t.id: t.name};
  }

  String _activityName(Record record, Map<String, String> activities) {
    final activityId = record.activityId;
    if (activityId == null) return 'Untracked';
    return activities[activityId] ?? activityId;
  }

  Future<Map<String, dynamic>> _describeRecord(Record record) async {
    final activities = await _activityMap();
    final tags = await _tagMap();
    return _describeRecords([record], activities, tags).first;
  }

  List<Map<String, dynamic>> _describeRecords(
    List<Record> records,
    Map<String, String> activities,
    Map<String, String> tags,
  ) {
    return records.map((record) {
      final startWall = wallClockAt(record.timezoneId, record.startedAtEpochMs);
      final endWall = wallClockAt(record.endTimezoneId, record.endedAtEpochMs);
      return {
        'id': record.id,
        'activity': record.isUntracked
            ? null
            : _activityName(record, activities),
        'is_untracked': record.isUntracked,
        'started_at': _isoUtc(record.startedAtEpochMs),
        'ended_at': _isoUtc(record.endedAtEpochMs),
        'started_at_local': _formatWall(startWall),
        'ended_at_local': _formatWall(endWall),
        'start_timezone': record.timezoneId,
        'end_timezone': record.endTimezoneId,
        'crosses_timezones': record.crossesTimezones,
        'duration_ms': record.elapsedMs,
        'duration_seconds': record.elapsedMs ~/ 1000,
        'comment': sanitizer.sanitize(record.comment),
        'tags': record.tagIds.map((id) => tags[id] ?? id).toList(),
      };
    }).toList();
  }

  String _isoUtc(int epochMs) => DateTime.fromMillisecondsSinceEpoch(
    epochMs,
    isUtc: true,
  ).toIso8601String();

  /// Wall-clock time without a zone suffix, because the zone travels beside it
  /// in its own field.
  String _formatWall(DateTime wall) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${wall.year.toString().padLeft(4, '0')}-${two(wall.month)}-'
        '${two(wall.day)}T${two(wall.hour)}:${two(wall.minute)}:'
        '${two(wall.second)}';
  }

  // ==========================================
  // Shared Helpers
  // ==========================================

  /// The Activity named [name], ignoring case, or null when none exists.
  Future<Activity?> _findActivity(String name) async {
    final all = await database.getAllActivities(includeArchived: true);
    for (final a in all) {
      if (a.name.toLowerCase() == name.trim().toLowerCase()) {
        return a;
      }
    }
    return null;
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

class _ActivityTotal {
  int durationMs = 0;
  int recordCount = 0;
}

extension _IterableFirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
