import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/mcp/pii_sanitizer.dart';
import 'package:tempo/mcp/tempo_mcp_server.dart';

const String laZone = 'America/Los_Angeles';
const String nyZone = 'America/New_York';
const int hourMs = 3600000;

/// Epoch milliseconds for a wall-clock time in [zone].
int wallMs(
  String zone,
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) {
  return epochMsFromWallClock(
    DateTime.utc(year, month, day, hour, minute),
    zone,
    referenceEpochMs: DateTime.utc(year, month, day, 12).millisecondsSinceEpoch,
  );
}

Future<Map<String, dynamic>> callTool(
  TempoMcpServer server,
  String name, [
  Map<String, dynamic> arguments = const {},
]) async {
  final response = await server.handleMessage(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  final json = jsonDecode(response!) as Map<String, dynamic>;
  return json['result'] as Map<String, dynamic>;
}

Map<String, dynamic> payloadOf(Map<String, dynamic> result) =>
    jsonDecode(result['content'][0]['text'] as String) as Map<String, dynamic>;

void main() {
  sqfliteFfiInit();

  group('TempoMcpServer', () {
    late TempoDatabase db;
    late TempoMcpServer server;
    late PIISanitizer sanitizer;

    const sleep = Activity(
      id: 'act-sleep',
      name: 'Sleep',
      colorHex: '#5C6BC0',
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );
    const meals = Activity(
      id: 'act-meals',
      name: 'Meals',
      colorHex: '#FFB300',
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );
    const transit = Activity(
      id: 'act-transit',
      name: 'Transit',
      colorHex: '#26A69A',
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
    );

    Future<void> insertRecord({
      required String id,
      required String? activityId,
      required int startMs,
      required int endMs,
      String zone = laZone,
      String? endZone,
      String comment = '',
      List<String> tagIds = const [],
    }) {
      return db.insertRecord(
        Record(
          id: id,
          activityId: activityId,
          startedAtEpochMs: startMs,
          endedAtEpochMs: endMs,
          comment: comment,
          timezoneId: zone,
          endTimezoneId: endZone,
          createdAtEpochMs: startMs,
          updatedAtEpochMs: startMs,
          tagIds: tagIds,
        ),
      );
    }

    setUp(() async {
      db = await TempoDatabase.openInMemory(factory: databaseFactoryFfi);
      sanitizer = PIISanitizer();
      server = TempoMcpServer(
        database: db,
        sanitizer: sanitizer,
        allowWrites: false,
      );

      await db.insertActivity(sleep);
      await db.insertActivity(meals);
      await db.insertActivity(transit);

      // 2026-10-29 in Los Angeles: Sleep 00:00-07:00, Meals 12:00-13:00,
      // and Untracked 20:00-21:00.
      final sleepStart = wallMs(laZone, 2026, 10, 29, 0);
      await insertRecord(
        id: 'r-29-sleep',
        activityId: sleep.id,
        startMs: sleepStart,
        endMs: wallMs(laZone, 2026, 10, 29, 7),
      );
      await insertRecord(
        id: 'r-29-meals',
        activityId: meals.id,
        startMs: wallMs(laZone, 2026, 10, 29, 12),
        endMs: wallMs(laZone, 2026, 10, 29, 13),
      );
      await insertRecord(
        id: 'r-29-untracked',
        activityId: null,
        startMs: wallMs(laZone, 2026, 10, 29, 20),
        endMs: wallMs(laZone, 2026, 10, 29, 21),
      );

      // 2026-10-30 in Los Angeles: Sleep 00:00-07:00, then a six-hour Transit
      // that lands in New York, then an Untracked hour in New York.
      final transitStart = wallMs(laZone, 2026, 10, 30, 9);
      final transitEnd = transitStart + (6 * hourMs);
      await insertRecord(
        id: 'r-30-sleep',
        activityId: sleep.id,
        startMs: wallMs(laZone, 2026, 10, 30, 0),
        endMs: wallMs(laZone, 2026, 10, 30, 7),
      );
      await insertRecord(
        id: 'r-30-transit',
        activityId: transit.id,
        startMs: transitStart,
        endMs: transitEnd,
        endZone: nyZone,
      );
      await insertRecord(
        id: 'r-30-untracked',
        activityId: null,
        startMs: transitEnd,
        endMs: transitEnd + hourMs,
        zone: nyZone,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'handles JSON-RPC protocol handshake: initialize, ping, notifications',
      () async {
        final initRes = await server.handleMessage(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2024-11-05',
              'capabilities': {},
              'clientInfo': {'name': 'test-client', 'version': '1.0.0'},
            },
          }),
        );
        final initJson = jsonDecode(initRes!) as Map<String, dynamic>;
        expect(initJson['jsonrpc'], equals('2.0'));
        expect(initJson['id'], equals(1));
        expect(initJson['result']['serverInfo']['name'], equals('tempo-mcp'));
        expect(initJson['result']['capabilities'], contains('tools'));

        final notifRes = await server.handleMessage(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        expect(notifRes, isNull);

        final pingRes = await server.handleMessage(
          jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}),
        );
        final pingJson = jsonDecode(pingRes!) as Map<String, dynamic>;
        expect(pingJson['id'], equals(2));
        expect(pingJson['result'], equals({}));
      },
    );

    test('returns parse error on invalid JSON and method not found', () async {
      final parseRes = await server.handleMessage('invalid json {');
      final parseJson = jsonDecode(parseRes!) as Map<String, dynamic>;
      expect(parseJson['error']['code'], equals(-32700));

      final unknownRes = await server.handleMessage(
        jsonEncode({'jsonrpc': '2.0', 'id': 99, 'method': 'unknown/method'}),
      );
      final unknownJson = jsonDecode(unknownRes!) as Map<String, dynamic>;
      expect(unknownJson['error']['code'], equals(-32601));
    });

    test(
      'tools/list returns only plain read tools when allowWrites is false',
      () async {
        final res = await server.handleMessage(
          jsonEncode({'jsonrpc': '2.0', 'id': 10, 'method': 'tools/list'}),
        );
        final json = jsonDecode(res!) as Map<String, dynamic>;
        final tools = json['result']['tools'] as List;
        final names = tools.map((t) => t['name'] as String).toList();

        expect(
          names,
          equals([
            'get_day_timeline',
            'get_time_per_activity',
            'get_untracked_records',
            'compare_days',
            'query_records',
          ]),
        );
        expect(names, isNot(contains('label_lap')));
        expect(names, isNot(contains('split_lap')));
        expect(names, isNot(contains('adjust_record_edge')));

        final evaluative = RegExp(
          r'productiv|focus|goal|streak|habit|score',
          caseSensitive: false,
        );
        for (final tool in tools) {
          final text = '${tool['name']} ${tool['description']}';
          expect(evaluative.hasMatch(text), isFalse, reason: text);
        }
      },
    );

    test(
      'tools/list includes the write tools when allowWrites is true',
      () async {
        final writeServer = TempoMcpServer(
          database: db,
          sanitizer: sanitizer,
          allowWrites: true,
        );
        final res = await writeServer.handleMessage(
          jsonEncode({'jsonrpc': '2.0', 'id': 11, 'method': 'tools/list'}),
        );
        final json = jsonDecode(res!) as Map<String, dynamic>;
        final names = (json['result']['tools'] as List)
            .map((t) => t['name'] as String)
            .toList();

        expect(
          names,
          containsAll(['label_lap', 'split_lap', 'adjust_record_edge']),
        );
      },
    );

    test('write tools are refused when allowWrites is false', () async {
      for (final writeTool in [
        'label_lap',
        'split_lap',
        'adjust_record_edge',
      ]) {
        final result = await callTool(server, writeTool, {
          'activity_name': 'Reading',
        });
        expect(result['isError'], isTrue);
        final errorText = result['content'][0]['text'] as String;
        expect(errorText, contains('Mutation tool "$writeTool" is disabled'));
      }
    });

    test(
      "get_day_timeline describes a Day with each Record's lived zones",
      () async {
        final result = await callTool(server, 'get_day_timeline', {
          'date': '2026-10-30',
          'timezone': laZone,
        });
        expect(result['isError'], isFalse);
        final payload = payloadOf(result);

        expect(payload['date'], equals('2026-10-30'));
        expect(payload['timezone'], equals(laZone));
        expect(payload['day_length_seconds'], equals(86400));
        expect(payload['labelled_seconds'], equals((7 + 6) * 3600));
        expect(
          payload['untracked_records'],
          equals({'count': 1, 'duration_seconds': 3600}),
        );
        expect(payload['open_lap'], isNull);

        final records = payload['records'] as List;
        expect(records.length, equals(3));

        final sleepRecord = records.firstWhere((r) => r['id'] == 'r-30-sleep');
        expect(sleepRecord['activity'], equals('Sleep'));
        expect(sleepRecord['is_untracked'], isFalse);
        expect(sleepRecord['started_at_local'], equals('2026-10-30T00:00:00'));
        expect(sleepRecord['ended_at_local'], equals('2026-10-30T07:00:00'));
        expect(sleepRecord['start_timezone'], equals(laZone));
        expect(sleepRecord['end_timezone'], equals(laZone));
        expect(sleepRecord['duration_seconds'], equals(7 * 3600));

        final transitRecord = records.firstWhere(
          (r) => r['id'] == 'r-30-transit',
        );
        expect(transitRecord['activity'], equals('Transit'));
        expect(
          transitRecord['started_at_local'],
          equals('2026-10-30T09:00:00'),
        );
        expect(transitRecord['ended_at_local'], equals('2026-10-30T18:00:00'));
        expect(transitRecord['start_timezone'], equals(laZone));
        expect(transitRecord['end_timezone'], equals(nyZone));
        expect(transitRecord['crosses_timezones'], isTrue);
        // Duration comes from UTC epochs, not the wall-clock difference.
        expect(transitRecord['duration_seconds'], equals(6 * 3600));

        final untrackedRecord = records.firstWhere(
          (r) => r['id'] == 'r-30-untracked',
        );
        expect(untrackedRecord['activity'], isNull);
        expect(untrackedRecord['is_untracked'], isTrue);
        expect(untrackedRecord['start_timezone'], equals(nyZone));
        expect(untrackedRecord['end_timezone'], equals(nyZone));
        expect(untrackedRecord['duration_seconds'], equals(3600));
      },
    );

    test('get_day_timeline includes the open Lap in its start zone', () async {
      var clock = DateTime.utc(2026, 11, 5, 10).millisecondsSinceEpoch;
      const zone = 'UTC';
      final recorder = DayRecorder(
        database: db,
        nowUtcMs: () => clock,
        getTimezoneId: () => zone,
        autoSplitAtMidnight: false,
      );
      addTearDown(recorder.dispose);
      await recorder.initialize();

      final lapServer = TempoMcpServer(
        database: db,
        sanitizer: sanitizer,
        zoneProvider: () => zone,
        nowUtcMs: () => clock,
        dayRecorder: recorder,
      );
      clock += 90000;

      final payload = payloadOf(
        await callTool(lapServer, 'get_day_timeline', {
          'date': '2026-11-05',
          'timezone': zone,
        }),
      );

      final lap = payload['open_lap'] as Map<String, dynamic>;
      expect(lap['started_at_local'], equals('2026-11-05T10:00:00'));
      expect(lap['start_timezone'], equals(zone));
      expect(lap['elapsed_seconds'], equals(90));
      expect(lap['elapsed_seconds_in_window'], equals(90));
      expect(payload['records'], isEmpty);
      expect(payload['labelled_seconds'], equals(0));
      expect(
        payload['untracked_records'],
        equals({'count': 0, 'duration_seconds': 0}),
      );
    });

    test(
      'get_time_per_activity totals a range and counts Untracked Records',
      () async {
        final result = await callTool(server, 'get_time_per_activity', {
          'start_date': '2026-10-29',
          'end_date': '2026-10-30',
          'timezone': laZone,
        });
        expect(result['isError'], isFalse);
        final payload = payloadOf(result);

        expect(payload['start_date'], equals('2026-10-29'));
        expect(payload['end_date'], equals('2026-10-30'));
        expect(payload['labelled_seconds'], equals((14 + 1 + 6) * 3600));
        expect(
          payload['untracked_records'],
          equals({'count': 2, 'duration_seconds': 2 * 3600}),
        );
        expect(payload['open_lap_seconds'], equals(0));

        final totals = {
          for (final entry in payload['time_per_activity'] as List)
            entry['activity'] as String: entry,
        };
        expect(totals['Sleep']['duration_seconds'], equals(14 * 3600));
        expect(totals['Sleep']['record_count'], equals(2));
        expect(totals['Transit']['duration_seconds'], equals(6 * 3600));
        expect(totals['Transit']['record_count'], equals(1));
        expect(totals['Meals']['duration_seconds'], equals(3600));
      },
    );

    test('get_untracked_records lists their count and length', () async {
      final result = await callTool(server, 'get_untracked_records', {
        'start_date': '2026-10-29',
        'end_date': '2026-10-30',
        'timezone': laZone,
      });
      final payload = payloadOf(result);

      expect(payload['count'], equals(2));
      expect(payload['total_duration_seconds'], equals(2 * 3600));

      final records = payload['records'] as List;
      expect(records.length, equals(2));
      expect(records.every((r) => r['is_untracked'] == true), isTrue);
      expect(records.every((r) => r['activity'] == null), isTrue);
      expect(records.first['id'], equals('r-29-untracked'));
      expect(records.last['id'], equals('r-30-untracked'));
    });

    test('compare_days reports each Day and the change between them', () async {
      final result = await callTool(server, 'compare_days', {
        'dates': ['2026-10-30', '2026-10-29'],
        'timezone': laZone,
      });
      final payload = payloadOf(result);

      final days = payload['days'] as List;
      expect(days.length, equals(2));
      expect(days[0]['date'], equals('2026-10-29'));
      expect(days[1]['date'], equals('2026-10-30'));
      expect(
        days[0]['time_per_activity'],
        equals({'Sleep': 7 * 3600, 'Meals': 3600}),
      );
      expect(
        days[1]['time_per_activity'],
        equals({'Sleep': 7 * 3600, 'Transit': 6 * 3600}),
      );
      expect(
        days[1]['untracked_records'],
        equals({'count': 1, 'duration_seconds': 3600}),
      );

      final differences = {
        for (final entry in payload['differences'] as List)
          entry['activity'] as String: entry,
      };
      expect(differences['Sleep']['difference_seconds'], equals(0));
      expect(differences['Transit']['difference_seconds'], equals(6 * 3600));
      expect(differences['Meals']['difference_seconds'], equals(-3600));
      expect(differences['Sleep']['from_date'], equals('2026-10-29'));
      expect(differences['Sleep']['to_date'], equals('2026-10-30'));
    });

    test(
      'read output sanitizes comments with stable contact pseudonyms',
      () async {
        final contactTag = Tag(
          id: 'tag-contact',
          name: 'Contact',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        );
        await db.insertTag(contactTag);
        final start = wallMs(laZone, 2026, 11, 2, 9);
        await insertRecord(
          id: 'r-pii-1',
          activityId: meals.id,
          startMs: start,
          endMs: start + hourMs,
          comment: '1:1 w/ Bob Jones (reach bob@corp.com)',
          tagIds: [contactTag.id],
        );
        await insertRecord(
          id: 'r-pii-2',
          activityId: meals.id,
          startMs: start + hourMs,
          endMs: start + (2 * hourMs),
          comment: 'Lunch with Alice Wu',
          tagIds: [contactTag.id],
        );
        await insertRecord(
          id: 'r-pii-3',
          activityId: meals.id,
          startMs: start + (2 * hourMs),
          endMs: start + (3 * hourMs),
          comment: 'Dinner w/ Bob Jones',
          tagIds: [contactTag.id],
        );

        final timeline = payloadOf(
          await callTool(server, 'get_day_timeline', {
            'date': '2026-11-02',
            'timezone': laZone,
          }),
        );
        final comments = {
          for (final record in timeline['records'] as List)
            record['id'] as String: record['comment'],
        };
        expect(
          comments['r-pii-1'],
          equals('1:1 w/ [Contact-1] (reach [EMAIL])'),
        );
        expect(comments['r-pii-2'], equals('Lunch with [Contact-2]'));
        expect(comments['r-pii-3'], equals('Dinner w/ [Contact-1]'));

        final taggedResponse = await callTool(server, 'query_records', {
          'start_date': '2026-11-02',
          'end_date': '2026-11-02',
          'tag': 'Contact',
          'timezone': laZone,
        });
        final queried =
            jsonDecode(taggedResponse['content'][0]['text'] as String) as List;
        expect(queried.length, equals(3));
        expect(queried.first['comment'], contains('[Contact-1]'));
        expect(
          queried.first['started_at_local'],
          equals('2026-11-02T09:00:00'),
        );
        expect(queried.first['tags'], equals(['Contact']));
      },
    );

    test('label_lap refuses an unknown Activity without creating it', () async {
      var clock = wallMs(laZone, 2026, 11, 3, 8);
      final recorder = DayRecorder(
        database: db,
        nowUtcMs: () => clock,
        getTimezoneId: () => laZone,
        autoSplitAtMidnight: false,
      );
      addTearDown(recorder.dispose);
      await recorder.initialize();
      final lapStart = recorder.lap!.startedAtEpochMs;
      final activitiesBefore = await db.getAllActivities(includeArchived: true);
      final recordsBefore = await db.getRecords();

      final writeServer = TempoMcpServer(
        database: db,
        sanitizer: sanitizer,
        allowWrites: true,
        zoneProvider: () => laZone,
        nowUtcMs: () => clock,
        dayRecorder: recorder,
      );

      clock += hourMs;
      final result = await callTool(writeServer, 'label_lap', {
        'activity_name': 'Reding',
      });
      expect(result['isError'], isTrue);
      expect(
        result['content'][0]['text'] as String,
        contains('Unknown Activity "Reding"'),
      );
      expect(
        await db.getAllActivities(includeArchived: true),
        hasLength(activitiesBefore.length),
      );
      expect(await db.getRecords(), hasLength(recordsBefore.length));
      expect(recorder.lap!.startedAtEpochMs, lapStart);

      // An existing Activity matches regardless of case.
      final labelled = payloadOf(
        await callTool(writeServer, 'label_lap', {'activity_name': 'meals'}),
      );
      expect((labelled['record'] as Map)['activity'], equals('Meals'));
    });

    test('write tools keep the Day continuous and surface refusals', () async {
      await db.insertActivity(
        const Activity(
          id: 'act-reading',
          name: 'Reading',
          colorHex: '#26A69A',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      var clock = wallMs(laZone, 2026, 11, 3, 8);
      final recorder = DayRecorder(
        database: db,
        nowUtcMs: () => clock,
        getTimezoneId: () => laZone,
        autoSplitAtMidnight: false,
      );
      addTearDown(recorder.dispose);
      await recorder.initialize();

      final writeServer = TempoMcpServer(
        database: db,
        sanitizer: sanitizer,
        allowWrites: true,
        zoneProvider: () => laZone,
        nowUtcMs: () => clock,
        dayRecorder: recorder,
      );

      clock += 2 * hourMs;
      final labelled = payloadOf(
        await callTool(writeServer, 'label_lap', {
          'activity_name': 'Reading',
          'comment': '1:1 w/ Bob Jones',
          'tags': ['Contact'],
        }),
      );
      expect(labelled['success'], isTrue);
      var reading = labelled['record'] as Map<String, dynamic>;
      expect(reading['activity'], equals('Reading'));
      expect(reading['duration_seconds'], equals(2 * 3600));
      expect(reading['started_at_local'], equals('2026-11-03T08:00:00'));
      expect(reading['start_timezone'], equals(laZone));
      expect(reading['comment'], equals('1:1 w/ [Contact-1]'));

      clock += hourMs;
      final split = payloadOf(await callTool(writeServer, 'split_lap'));
      expect(split['success'], isTrue);
      final untracked = split['record'] as Map<String, dynamic>;
      expect(untracked['is_untracked'], isTrue);
      expect(untracked['activity'], isNull);
      expect(untracked['duration_seconds'], equals(3600));

      clock += hourMs;
      await callTool(writeServer, 'label_lap', {'activity_name': 'Meals'});

      final dayStart = wallMs(laZone, 2026, 11, 3, 0);
      Future<List<Record>> readDay() async {
        final all = await db.getRecords();
        return all.where((r) => r.startedAtEpochMs >= dayStart).toList()
          ..sort((a, b) => a.startedAtEpochMs.compareTo(b.startedAtEpochMs));
      }

      var records = await readDay();
      expect(records.length, equals(3));
      for (var i = 0; i < records.length - 1; i++) {
        expect(
          records[i].endedAtEpochMs,
          equals(records[i + 1].startedAtEpochMs),
        );
      }
      expect(records.first.id, equals(reading['id']));

      final boundaryInstant = records.first.startedAtEpochMs + 9000000;
      final moved = payloadOf(
        await callTool(writeServer, 'adjust_record_edge', {
          'record_id': records.first.id,
          'edge': 'end',
          'new_instant': DateTime.fromMillisecondsSinceEpoch(
            boundaryInstant,
            isUtc: true,
          ).toIso8601String(),
        }),
      );
      expect(moved['success'], isTrue);
      reading = moved['record'] as Map<String, dynamic>;
      expect(reading['duration_seconds'], equals(9000));

      records = await readDay();
      expect(records.length, equals(3));
      expect(records[0].endedAtEpochMs, equals(boundaryInstant));
      expect(records[1].startedAtEpochMs, equals(boundaryInstant));
      expect(records[1].durationMs, equals(1800000));
      expect(records[2].startedAtEpochMs, equals(records[1].endedAtEpochMs));

      final pastNeighbour = await callTool(writeServer, 'adjust_record_edge', {
        'record_id': records.first.id,
        'edge': 'end',
        'new_instant': DateTime.fromMillisecondsSinceEpoch(
          records[2].startedAtEpochMs + 1800000,
          isUtc: true,
        ).toIso8601String(),
      });
      expect(pastNeighbour['isError'], isTrue);
      expect(
        pastNeighbour['content'][0]['text'] as String,
        contains('another Record'),
      );

      // The newest Record may grow into the open Lap.
      clock += hourMs;
      final intoOpenLap = payloadOf(
        await callTool(writeServer, 'adjust_record_edge', {
          'record_id': records[2].id,
          'edge': 'end',
          'new_instant': DateTime.fromMillisecondsSinceEpoch(
            records[2].endedAtEpochMs + 1800000,
            isUtc: true,
          ).toIso8601String(),
        }),
      );
      expect(intoOpenLap['success'], isTrue);
      expect(
        recorder.lap!.startedAtEpochMs,
        equals(records[2].endedAtEpochMs + 1800000),
      );
    });

    test('processStream handles multi-line stdio input cleanly', () async {
      final inputLines = Stream.fromIterable([
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        '',
        jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}),
      ]);

      final responses = await server.processStream(inputLines).toList();
      expect(responses.length, equals(2));
      final res1 = jsonDecode(responses[0]) as Map<String, dynamic>;
      final res2 = jsonDecode(responses[1]) as Map<String, dynamic>;
      expect(res1['id'], equals(1));
      expect(res2['id'], equals(2));
    });
  });
}
