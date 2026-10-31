import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/mcp/pii_sanitizer.dart';
import 'package:tempo/mcp/tempo_mcp_server.dart';

void main() {
  sqfliteFfiInit();

  group('TempoMcpServer', () {
    late TempoDatabase db;
    late TempoMcpServer server;
    late PIISanitizer sanitizer;

    setUp(() async {
      db = await TempoDatabase.openInMemory(factory: databaseFactoryFfi);
      sanitizer = PIISanitizer();
      server = TempoMcpServer(
        database: db,
        sanitizer: sanitizer,
        allowWrites: false,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'handles JSON-RPC protocol handshake: initialize, ping, notifications',
      () async {
        // 1. initialize
        final initReq = jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'test-client', 'version': '1.0.0'},
          },
        });
        final initRes = await server.handleMessage(initReq);
        expect(initRes, isNotNull);
        final initJson = jsonDecode(initRes!) as Map<String, dynamic>;
        expect(initJson['jsonrpc'], equals('2.0'));
        expect(initJson['id'], equals(1));
        expect(initJson['result']['serverInfo']['name'], equals('tempo-mcp'));
        expect(initJson['result']['capabilities'], contains('tools'));

        // 2. notifications/initialized (notification -> returns null)
        final notifReq = jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        });
        final notifRes = await server.handleMessage(notifReq);
        expect(notifRes, isNull);

        // 3. ping
        final pingReq = jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'ping',
        });
        final pingRes = await server.handleMessage(pingReq);
        expect(pingRes, isNotNull);
        final pingJson = jsonDecode(pingRes!) as Map<String, dynamic>;
        expect(pingJson['id'], equals(2));
        expect(pingJson['result'], equals({}));
      },
    );

    test('returns parse error on invalid JSON and method not found on unknown method', () async {
      final parseErr = await server.handleMessage('invalid json {');
      expect(parseErr, isNotNull);
      final parseJson = jsonDecode(parseErr!) as Map<String, dynamic>;
      expect(parseJson['error']['code'], equals(-32700));

      final unknownMethodReq = jsonEncode({
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'unknown/method',
      });
      final unknownRes = await server.handleMessage(unknownMethodReq);
      expect(unknownRes, isNotNull);
      final unknownJson = jsonDecode(unknownRes!) as Map<String, dynamic>;
      expect(unknownJson['error']['code'], equals(-32601));
    });

    test(
      'tools/list lists only read tools when allowWrites is false',
      () async {
        final req = jsonEncode({
          'jsonrpc': '2.0',
          'id': 10,
          'method': 'tools/list',
        });
        final res = await server.handleMessage(req);
        final json = jsonDecode(res!) as Map<String, dynamic>;
        final tools = json['result']['tools'] as List;

        final toolNames = tools.map((t) => t['name'] as String).toList();
        expect(
          toolNames,
          containsAll([
            'get_active_timer',
            'get_daily_summary',
            'query_records',
            'analyze_trends',
          ]),
        );
        expect(toolNames, isNot(contains('start_timer')));
        expect(toolNames, isNot(contains('stop_timer')));
        expect(toolNames, isNot(contains('add_manual_record')));
      },
    );

    test(
      'tools/list includes mutation tools when allowWrites is true',
      () async {
        final writeServer = TempoMcpServer(
          database: db,
          sanitizer: sanitizer,
          allowWrites: true,
        );

        final req = jsonEncode({
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'tools/list',
        });
        final res = await writeServer.handleMessage(req);
        final json = jsonDecode(res!) as Map<String, dynamic>;
        final tools = json['result']['tools'] as List;

        final toolNames = tools.map((t) => t['name'] as String).toList();
        expect(
          toolNames,
          containsAll([
            'get_active_timer',
            'get_daily_summary',
            'query_records',
            'analyze_trends',
            'start_timer',
            'stop_timer',
            'add_manual_record',
          ]),
        );
      },
    );

    test('tools/call enforces read-only gate on mutation tools when allowWrites is false', () async {
      for (final mutationTool in [
        'start_timer',
        'stop_timer',
        'add_manual_record',
      ]) {
        final req = jsonEncode({
          'jsonrpc': '2.0',
          'id': 20,
          'method': 'tools/call',
          'params': {
            'name': mutationTool,
            'arguments': {'activity_name': 'Coding'},
          },
        });
        final res = await server.handleMessage(req);
        final json = jsonDecode(res!) as Map<String, dynamic>;
        expect(json['result']['isError'], isTrue);
        final errorText = json['result']['content'][0]['text'] as String;
        expect(
          errorText,
          contains('Mutation tool "$mutationTool" is disabled'),
        );
      }
    });

    test('tools/call get_active_timer returns empty state when idle', () async {
      final req = jsonEncode({
        'jsonrpc': '2.0',
        'id': 30,
        'method': 'tools/call',
        'params': {'name': 'get_active_timer', 'arguments': {}},
      });
      final res = await server.handleMessage(req);
      final json = jsonDecode(res!) as Map<String, dynamic>;
      expect(json['result']['isError'], isFalse);

      final payload = jsonDecode(
        json['result']['content'][0]['text'] as String,
      );
      expect(payload['is_tracking'], isFalse);
      expect(payload['activity_name'], isNull);
      expect(payload['elapsed_seconds'], equals(0));
    });

    test('tools/call get_active_timer returns active tracking status with sanitized comment', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final activity = Activity(
        id: 'act-coding',
        name: 'Coding',
        colorHex: '#4CAF50',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertActivity(activity);

      final tag = Tag(
        id: 'tag-deepwork',
        name: 'DeepWork',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertTag(tag);

      final timer = ActiveTimer(
        activityId: 'act-coding',
        startedAtEpochMs: now - 50000,
        lastHeartbeatEpochMs: now,
        currentComment: 'Architecture review w/ Alice Smith',
        initialTagIds: ['tag-deepwork'],
      );
      await db.setActiveTimer(timer);

      final req = jsonEncode({
        'jsonrpc': '2.0',
        'id': 31,
        'method': 'tools/call',
        'params': {'name': 'get_active_timer', 'arguments': {}},
      });
      final res = await server.handleMessage(req);
      final json = jsonDecode(res!) as Map<String, dynamic>;
      expect(json['result']['isError'], isFalse);

      final payload = jsonDecode(
        json['result']['content'][0]['text'] as String,
      );
      expect(payload['is_tracking'], isTrue);
      expect(payload['activity_name'], equals('Coding'));
      expect(payload['color_hex'], equals('#4CAF50'));
      expect(payload['comment'], equals('Architecture review w/ [Contact-1]'));
      expect(payload['tags'], equals(['DeepWork']));
      expect(payload['elapsed_seconds'], greaterThanOrEqualTo(50));
    });

    test(
      'tools/call get_daily_summary aggregates total hours and breakdown',
      () async {
        final dateStr = '2026-10-30';
        final baseDay = DateTime.parse('${dateStr}T10:00:00Z')
            .millisecondsSinceEpoch;

        final actCoding = Activity(
          id: 'act-c',
          name: 'Coding',
          createdAtEpochMs: baseDay,
          updatedAtEpochMs: baseDay,
        );
        final actWorkout = Activity(
          id: 'act-w',
          name: 'Workout',
          createdAtEpochMs: baseDay,
          updatedAtEpochMs: baseDay,
        );
        await db.insertActivity(actCoding);
        await db.insertActivity(actWorkout);

        // Record 1: 3 hours coding
        await db.insertRecord(
          Record(
            id: 'rec-1',
            activityId: 'act-c',
            startedAtEpochMs: baseDay,
            endedAtEpochMs: baseDay + (3 * 3600 * 1000),
            durationMs: 3 * 3600 * 1000,
            timezoneId: 'UTC',
            createdAtEpochMs: baseDay,
            updatedAtEpochMs: baseDay,
          ),
        );

        // Record 2: 1 hour workout
        await db.insertRecord(
          Record(
            id: 'rec-2',
            activityId: 'act-w',
            startedAtEpochMs: baseDay + (4 * 3600 * 1000),
            endedAtEpochMs: baseDay + (5 * 3600 * 1000),
            durationMs: 1 * 3600 * 1000,
            timezoneId: 'UTC',
            createdAtEpochMs: baseDay,
            updatedAtEpochMs: baseDay,
          ),
        );

        final req = jsonEncode({
          'jsonrpc': '2.0',
          'id': 32,
          'method': 'tools/call',
          'params': {
            'name': 'get_daily_summary',
            'arguments': {'date': dateStr},
          },
        });
        final res = await server.handleMessage(req);
        final json = jsonDecode(res!) as Map<String, dynamic>;
        final payload = jsonDecode(
          json['result']['content'][0]['text'] as String,
        );

        expect(payload['date'], equals(dateStr));
        expect(payload['total_duration_hours'], equals(4.0));
        expect(payload['total_records_count'], equals(2));

        final breakdown = payload['breakdown'] as List;
        expect(breakdown.length, equals(2));
        expect(breakdown[0]['activity'], equals('Coding'));
        expect(breakdown[0]['hours'], equals(3.0));
        expect(breakdown[0]['percentage'], equals(75.0));
        expect(breakdown[1]['activity'], equals('Workout'));
        expect(breakdown[1]['hours'], equals(1.0));
        expect(breakdown[1]['percentage'], equals(25.0));
      },
    );

    test('tools/call query_records searches records with sanitized comments and tag filters', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final act = Activity(
        id: 'act-m',
        name: 'Meeting',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertActivity(act);

      final tagContact = Tag(
        id: 't-c',
        name: 'Contact',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertTag(tagContact);

      final baseTime = DateTime.parse('2026-10-15T12:00:00Z')
          .millisecondsSinceEpoch;
      await db.insertRecord(
        Record(
          id: 'r-1',
          activityId: 'act-m',
          startedAtEpochMs: baseTime,
          endedAtEpochMs: baseTime + 1800000,
          durationMs: 1800000,
          comment: '1:1 w/ Bob Jones (reach at bob@corp.com)',
          timezoneId: 'UTC',
          createdAtEpochMs: baseTime,
          updatedAtEpochMs: baseTime,
          tagIds: ['t-c'],
        ),
      );

      final req = jsonEncode({
        'jsonrpc': '2.0',
        'id': 33,
        'method': 'tools/call',
        'params': {
          'name': 'query_records',
          'arguments': {
            'start_date': '2026-10-01',
            'end_date': '2026-10-31',
            'activity_name': 'Meeting',
            'tag': 'Contact',
            'limit': 10,
          },
        },
      });
      final res = await server.handleMessage(req);
      final json = jsonDecode(res!) as Map<String, dynamic>;
      final records =
          jsonDecode(json['result']['content'][0]['text'] as String) as List;

      expect(records.length, equals(1));
      final r0 = records[0] as Map<String, dynamic>;
      expect(r0['activity_name'], equals('Meeting'));
      expect(r0['comment'], equals('1:1 w/ [Contact-1] (reach at [EMAIL])'));
      expect(r0['tags'], equals(['Contact']));
      expect(r0['duration_seconds'], equals(1800));
    });

    test('tools/call analyze_trends outputs weekly averages, histogram, and habit streaks', () async {
      final now = DateTime.now().toUtc();
      final nowMs = now.millisecondsSinceEpoch;

      final actPinned = Activity(
        id: 'act-pin',
        name: 'Meditation',
        isPinned: true,
        createdAtEpochMs: nowMs,
        updatedAtEpochMs: nowMs,
      );
      await db.insertActivity(actPinned);

      // Log records for yesterday and today (2-day streak) at 14:00 UTC
      final todayAt14 = DateTime.utc(
        now.year,
        now.month,
        now.day,
        14,
      ).millisecondsSinceEpoch;
      final yesterdayAt14 = DateTime.utc(
        now.year,
        now.month,
        now.day - 1,
        14,
      ).millisecondsSinceEpoch;

      await db.insertRecord(
        Record(
          id: 'r-med-1',
          activityId: 'act-pin',
          startedAtEpochMs: yesterdayAt14,
          endedAtEpochMs: yesterdayAt14 + 1800000,
          durationMs: 1800000, // 0.5 hours
          timezoneId: 'UTC',
          createdAtEpochMs: yesterdayAt14,
          updatedAtEpochMs: yesterdayAt14,
        ),
      );

      await db.insertRecord(
        Record(
          id: 'r-med-2',
          activityId: 'act-pin',
          startedAtEpochMs: todayAt14,
          endedAtEpochMs: todayAt14 + 1800000,
          durationMs: 1800000, // 0.5 hours
          timezoneId: 'UTC',
          createdAtEpochMs: todayAt14,
          updatedAtEpochMs: todayAt14,
        ),
      );

      final req = jsonEncode({
        'jsonrpc': '2.0',
        'id': 34,
        'method': 'tools/call',
        'params': {
          'name': 'analyze_trends',
          'arguments': {'lookback_weeks': 4},
        },
      });
      final res = await server.handleMessage(req);
      final json = jsonDecode(res!) as Map<String, dynamic>;
      final payload = jsonDecode(
        json['result']['content'][0]['text'] as String,
      );

      expect(payload['lookback_weeks'], equals(4));
      expect(
        payload['weekly_averages']['Meditation'],
        equals(0.25),
      ); // 1 hour / 4 weeks = 0.25

      final histogram =
          payload['time_of_day_distribution'] as Map<String, dynamic>;
      expect(histogram.keys.length, equals(24));
      expect(histogram['14:00'], equals(1.0)); // 0.5 + 0.5 = 1.0 hr

      final streaks = payload['habit_streaks'] as List;
      expect(streaks.length, equals(1));
      expect(streaks[0]['activity'], equals('Meditation'));
      expect(streaks[0]['current_streak_days'], equals(2));
      expect(streaks[0]['max_streak_days'], equals(2));
    });

    test(
      'guarded write tools operate successfully when allowWrites is enabled',
      () async {
        final writeServer = TempoMcpServer(
          database: db,
          sanitizer: sanitizer,
          allowWrites: true,
        );

        // 1. start_timer
        final startReq = jsonEncode({
          'jsonrpc': '2.0',
          'id': 40,
          'method': 'tools/call',
          'params': {
            'name': 'start_timer',
            'arguments': {
              'activity_name': 'Writing',
              'comment': 'Drafting specs',
              'tags': ['Focus'],
            },
          },
        });
        final startRes = await writeServer.handleMessage(startReq);
        final startJson = jsonDecode(startRes!) as Map<String, dynamic>;
        expect(startJson['result']['isError'], isFalse);
        final startPayload = jsonDecode(
          startJson['result']['content'][0]['text'] as String,
        );
        expect(startPayload['success'], isTrue);
        expect(startPayload['activity_name'], equals('Writing'));

        // Check active timer state
        final active = await db.getActiveTimer();
        expect(active, isNotNull);
        expect(active!.currentComment, equals('Drafting specs'));

        // 2. stop_timer
        final stopReq = jsonEncode({
          'jsonrpc': '2.0',
          'id': 41,
          'method': 'tools/call',
          'params': {
            'name': 'stop_timer',
            'arguments': {'comment': 'Finished drafting'},
          },
        });
        final stopRes = await writeServer.handleMessage(stopReq);
        final stopJson = jsonDecode(stopRes!) as Map<String, dynamic>;
        expect(stopJson['result']['isError'], isFalse);
        final stopPayload = jsonDecode(
          stopJson['result']['content'][0]['text'] as String,
        );
        expect(stopPayload['success'], isTrue);
        expect(stopPayload['activity_name'], equals('Writing'));
        expect(stopPayload['comment'], equals('Finished drafting'));

        // Timer should now be stopped
        expect(await db.getActiveTimer(), isNull);

        // 3. add_manual_record
        final manualReq = jsonEncode({
          'jsonrpc': '2.0',
          'id': 42,
          'method': 'tools/call',
          'params': {
            'name': 'add_manual_record',
            'arguments': {
              'activity_name': 'Reading',
              'start_time': '2026-10-29T10:00:00Z',
              'end_time': '2026-10-29T11:00:00Z',
              'comment': 'Reading docs',
              'tags': ['Learning'],
            },
          },
        });
        final manualRes = await writeServer.handleMessage(manualReq);
        final manualJson = jsonDecode(manualRes!) as Map<String, dynamic>;
        expect(manualJson['result']['isError'], isFalse);
        final manualPayload = jsonDecode(
          manualJson['result']['content'][0]['text'] as String,
        );
        expect(manualPayload['success'], isTrue);
        expect(manualPayload['activity_name'], equals('Reading'));
        expect(manualPayload['duration_seconds'], equals(3600));

        final records = await db.getRecords();
        expect(records.any((r) => r.comment == 'Reading docs'), isTrue);
      },
    );

    test('processStream handles multi-line stdio input cleanly', () async {
      final inputLines = Stream.fromIterable([
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        '', // empty line should be ignored
        jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}),
      ]);

      final responses = await server.processStream(inputLines).toList();
      expect(responses.length, equals(2));
      final res1 = jsonDecode(responses[0]);
      final res2 = jsonDecode(responses[1]);
      expect(res1['id'], equals(1));
      expect(res2['id'], equals(2));
    });
  });
}
