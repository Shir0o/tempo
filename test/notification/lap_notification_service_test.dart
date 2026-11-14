import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/notification/lap_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('LapNotificationService', () {
    // 2026-11-04 14:05 in Los Angeles (PST, UTC-8).
    const lapStart = 1793829900000;
    const zone = 'America/Los_Angeles';
    const undoWindow = Duration(milliseconds: 40);

    late TempoDatabase db;
    late DayRecorder dayRecorder;
    late LapNotificationService service;
    late MethodChannel channel;
    late List<Map<dynamic, dynamic>> posted;
    late int mockTime;
    late int idCounter;
    late int settledCount;

    Future<void> insertActivity(String id, int sortOrder) => db.insertActivity(
      Activity(
        id: id,
        name: 'Activity $id',
        colorHex: '#C6F432',
        sortOrder: sortOrder,
        createdAtEpochMs: lapStart,
        updatedAtEpochMs: lapStart,
      ),
    );

    Future<void> insertRecord(String activityId, int endedAt) =>
        db.insertRecord(
          Record(
            id: 'seed-${++idCounter}',
            activityId: activityId,
            startedAtEpochMs: endedAt - 60000,
            endedAtEpochMs: endedAt,
            timezoneId: zone,
            createdAtEpochMs: endedAt,
            updatedAtEpochMs: endedAt,
          ),
        );

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      mockTime = lapStart;
      idCounter = 0;
      settledCount = 0;
      posted = [];

      for (final (i, id) in ['a', 'b', 'c', 'd', 'e', 'f', 'g'].indexed) {
        await insertActivity(id, i);
      }
      await insertRecord('c', lapStart - 300000);
      await insertRecord('b', lapStart - 200000);
      await insertRecord('b', lapStart - 100000);

      dayRecorder = DayRecorder(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => zone,
        undoGraceWindow: undoWindow,
        autoSplitAtMidnight: false,
      );
      await dayRecorder.initialize();

      channel = const MethodChannel(LapNotificationService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'updateLapNotification') {
              posted.add(call.arguments as Map);
            }
            return null;
          });

      service = LapNotificationService(
        dayRecorder: dayRecorder,
        database: db,
        channel: channel,
        nowUtcMs: () => mockTime,
        onSettled: () async => settledCount++,
      )..initialize();
    });

    tearDown(() async {
      service.dispose();
      dayRecorder.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('posts the open Lap with six chips, most used first', () async {
      await service.publish();

      // b was logged last, so Repeat offers it and its chip goes last among
      // the learned ones; c is the most used of the rest.

      final state = posted.single;
      expect(state['lapStartedAtEpochMs'], lapStart);
      expect(state['since'], '14:05');
      expect(state.containsKey('lastLabel'), isFalse);
      final ids = [for (final a in state['activities'] as List) a['id']];
      expect(ids, ['c', 'a', 'b', 'd', 'e', 'f']);
      expect(state['lastActivity'], {'id': 'b', 'name': 'Activity b'});
    });

    test('omits Repeat when no labelled Record exists', () async {
      for (final record in await db.getRecords()) {
        await db.deleteRecord(record.id);
      }

      await service.publish();

      expect(posted.single.containsKey('lastActivity'), isFalse);
    });

    test(
      'chips prioritize contextual Markov transitions over raw frequency',
      () async {
        // In setUp, we have: c -> b -> b.
        // Now add: when preceding is 'd', transition to 'e'.
        await insertRecord('d', lapStart - 50000);
        await insertRecord('e', lapStart - 40000);
        await insertRecord('d', lapStart - 30000);
        await insertRecord('e', lapStart - 20000);

        // Now close current lap as 'd'. So preceding activity is 'd'.
        mockTime = lapStart + 10000;
        await dayRecorder.label('d');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // The new notification publish should rank 'e' at the top because d -> e has 2 transitions.
        expect(posted.isNotEmpty, isTrue);
        final lastNotification = posted.last;
        final ids = [
          for (final a in lastNotification['activities'] as List) a['id'],
        ];
        expect(ids.first, 'e');
      },
    );

    test(
      'a chip tap labels the Lap, offers Undo, then shows the new Lap',
      () async {
        mockTime =
            lapStart + const Duration(hours: 1, minutes: 24).inMilliseconds;
        await service.handleAction('LABEL', activityId: 'a');

        final confirmation = posted.single;
        expect(confirmation['lapStartedAtEpochMs'], mockTime);
        expect(confirmation['lastLabel'], {
          'activityName': 'Activity a',
          'colorHex': '#C6F432',
          'startedAt': '14:05',
          'endedAt': '15:29',
          'duration': '1h 24m',
          'undoUntilEpochMs': mockTime + undoWindow.inMilliseconds,
        });
        expect(settledCount, 0);

        await Future<void>.delayed(undoWindow * 3);
        expect(posted, hasLength(2));
        expect(posted.last.containsKey('lastLabel'), isFalse);
        expect(posted.last['since'], '15:29');
        expect(settledCount, 1);
      },
    );

    test('Still grows the last Record and Undo shrinks it back', () async {
      mockTime = lapStart + 60000;
      await service.handleAction('LABEL', activityId: 'a');
      final labelledAt = mockTime;

      mockTime += 60000;
      await service.handleAction('CONTINUE');
      expect(dayRecorder.lap!.startedAtEpochMs, mockTime);
      final shown = posted.last['lastLabel'] as Map;
      expect(shown['activityName'], 'Activity a');

      await service.handleAction('UNDO');
      expect(dayRecorder.lap!.startedAtEpochMs, labelledAt);
    });

    test('Undo restores the Lap and settles at once', () async {
      mockTime = lapStart + 60000;
      await service.handleAction('LABEL', activityId: 'a');
      expect((posted.single['lastLabel'] as Map)['activityName'], 'Activity a');

      await service.handleAction('UNDO');
      expect(dayRecorder.lap!.startedAtEpochMs, lapStart);
      expect(posted.last['lapStartedAtEpochMs'], lapStart);
      expect(posted.last.containsKey('lastLabel'), isFalse);
      expect(settledCount, 1);

      await Future<void>.delayed(undoWindow * 3);
      expect(settledCount, 1);
    });

    test('a label made elsewhere refreshes the notification', () async {
      mockTime = lapStart + 60000;
      await dayRecorder.label('d');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(posted.last['lapStartedAtEpochMs'], mockTime);
      expect(posted.last.containsKey('lastLabel'), isFalse);
    });
  });
}
