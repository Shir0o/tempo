import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/wearable/wearable_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('WearableSyncService', () {
    late TempoDatabase db;
    late DayRecorder dayRecorder;
    late WearableSyncService syncService;
    late MethodChannel channel;
    late List<MethodCall> methodCalls;
    late int mockTime;
    late int idCounter;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      mockTime = 1700000000000;
      idCounter = 0;

      await db.insertActivity(
        const Activity(
          id: 'act-coding',
          name: 'Coding',
          colorHex: '#2563EB',
          iconName: 'code',
          isPinned: true,
          createdAtEpochMs: 1700000000000,
          updatedAtEpochMs: 1700000000000,
        ),
      );

      await db.insertActivity(
        const Activity(
          id: 'act-workout',
          name: 'Workout',
          colorHex: '#10B981',
          iconName: 'fitness',
          isPinned: false,
          createdAtEpochMs: 1700000000000,
          updatedAtEpochMs: 1700000000000,
        ),
      );

      dayRecorder = DayRecorder(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => 'America/Los_Angeles',
      );
      await dayRecorder.initialize();

      channel = const MethodChannel(WearableSyncService.channelName);
      methodCalls = [];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            if (call.method == 'syncLap' || call.method == 'syncActivities') {
              return true;
            }
            return null;
          });

      syncService = WearableSyncService(
        dayRecorder: dayRecorder,
        database: db,
        channel: channel,
        nowUtcMs: () => mockTime,
      );
    });

    tearDown(() async {
      syncService.dispose();
      dayRecorder.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    /// Delivers one watch action the way MainActivity does, and waits for the
    /// phone to finish applying it.
    Future<void> receiveWatchAction(Map<String, dynamic> arguments) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            WearableSyncService.channelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onWatchActionReceived', arguments),
            ),
            (ByteData? reply) {},
          );
      await pumpEventQueue();
    }

    Future<List<Map<String, Object?>>> watermarks(String deviceId) =>
        db.db.query(
          'watch_watermarks',
          where: 'device_id = ?',
          whereArgs: [deviceId],
        );

    test('initialize performs initial sync with the open Lap', () async {
      syncService.initialize();
      await pumpEventQueue();

      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'syncLap');
      final args = methodCalls.first.arguments as Map;
      expect(args['lapStartedAtEpochMs'], mockTime);
      expect(args['lapStartedTimezoneId'], 'America/Los_Angeles');
      expect(args['revision'], dayRecorder.lap!.revision);
      expect(args['appliedActionSeq'], 0);
      expect(args['rejectedActionIds'], isEmpty);
      expect(args['lastActivityId'], isNull);
      expect(args.keys, hasLength(9));
    });

    test('labeling dispatches a fresh Lap snapshot to the watch', () async {
      syncService.initialize();
      await pumpEventQueue();
      methodCalls.clear();

      mockTime += 60000;
      await dayRecorder.label('act-coding');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(methodCalls.isNotEmpty, isTrue);
      final lastCall = methodCalls.last;
      expect(lastCall.method, 'syncLap');

      final args = lastCall.arguments as Map;
      expect(args['lapStartedAtEpochMs'], mockTime);
      expect(args['lapStartedTimezoneId'], 'America/Los_Angeles');
      expect(args['lastActivityId'], 'act-coding');
      expect(args['lastActivityName'], 'Coding');
      expect(args['lastActivityColorHex'], '#2563EB');
      expect(args.keys, hasLength(9));
    });

    test(
      'syncActivities dispatches serialized activity list to channel',
      () async {
        syncService.initialize();
        await pumpEventQueue();
        methodCalls.clear();

        final activities = await db.getAllActivities();
        final success = await syncService.syncActivities(activities);

        expect(success, isTrue);
        expect(methodCalls.length, 1);
        expect(methodCalls.first.method, 'syncActivities');

        final args = methodCalls.first.arguments as Map;
        final list = args['activities'] as List;
        expect(list.length, 2);
        expect(list[0]['id'], 'act-coding');
        expect(list[0]['name'], 'Coding');
        expect(list[0]['isPinned'], isTrue);
        expect(list[1]['id'], 'act-workout');
        expect(list[1]['isPinned'], isFalse);
      },
    );

    test(
      'tile slots are the three most useful Activities in the history window',
      () async {
        await db.insertActivity(
          const Activity(
            id: 'act-reading',
            name: 'Reading',
            createdAtEpochMs: 1700000000000,
            updatedAtEpochMs: 1700000000000,
          ),
        );

        // Three Workout labels, two Reading labels, one Coding label.
        for (final activityId in [
          'act-workout',
          'act-reading',
          'act-workout',
          'act-reading',
          'act-workout',
          'act-coding',
        ]) {
          mockTime += 60000;
          await dayRecorder.label(activityId);
        }

        syncService.initialize();
        await pumpEventQueue();
        methodCalls.clear();

        await syncService.syncActivities(await db.getAllActivities());

        final args = methodCalls.single.arguments as Map;
        expect(args['tileActivityIds'], [
          'act-workout',
          'act-reading',
          'act-coding',
        ]);
      },
    );

    test('tile slots decay older labels instead of dropping them', () async {
      syncService.initialize();
      await pumpEventQueue();
      methodCalls.clear();

      final oldStart = mockTime - Duration(days: 20).inMilliseconds;
      await db.insertRecord(
        Record(
          id: 'old-workout',
          activityId: 'act-workout',
          startedAtEpochMs: oldStart,
          endedAtEpochMs: oldStart + 60000,
          timezoneId: 'America/Los_Angeles',
          endTimezoneId: 'America/Los_Angeles',
          createdAtEpochMs: oldStart,
          updatedAtEpochMs: oldStart,
        ),
      );

      mockTime += 60000;
      await dayRecorder.label('act-coding');

      await syncService.syncActivities(await db.getAllActivities());

      final args = methodCalls.last.arguments as Map;
      // 'act-coding' is suggested first (recent/temporal/frequency in window),
      // followed by remaining candidate 'act-workout'.
      expect(args['tileActivityIds'], ['act-coding', 'act-workout']);
    });

    test('incoming LABEL action from the watch labels the Lap', () async {
      syncService.initialize();

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();

      await messenger.handlePlatformMessage(
        WearableSyncService.channelName,
        codec.encodeMethodCall(
          const MethodCall('onWatchActionReceived', {
            'action': 'LABEL',
            'activityId': 'act-workout',
            'timestampEpochMs': 1700000010000,
            'actionId': 'evt-125',
          }),
        ),
        (ByteData? reply) {},
      );

      final records = await db.getRecords();
      expect(records.single.activityId, 'act-workout');
      expect(dayRecorder.lap!.startedAtEpochMs, equals(mockTime));
    });

    test('incoming SPLIT action from the watch splits the Lap', () async {
      syncService.initialize();
      await dayRecorder.label('act-coding');
      mockTime += 30000;
      // The tap reached the phone ten seconds after it happened.
      const tappedAt = 1700000020000;

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();

      await messenger.handlePlatformMessage(
        WearableSyncService.channelName,
        codec.encodeMethodCall(
          const MethodCall('onWatchActionReceived', {
            'action': 'SPLIT',
            'timestampEpochMs': tappedAt,
            'actionId': 'evt-126',
          }),
        ),
        (ByteData? reply) {},
      );

      final records = await db.getRecords();
      expect(records.length, equals(2));
      expect(records.first.activityId, isNull);
      expect(records.first.endedAtEpochMs, equals(tappedAt));
      expect(dayRecorder.lap!.startedAtEpochMs, equals(tappedAt));
    });

    test(
      'incoming REPEAT labels the Lap with the last Activity again',
      () async {
        syncService.initialize();
        await pumpEventQueue();
        mockTime += 60000;
        await dayRecorder.label('act-coding');
        await pumpEventQueue();
        final firstEnd = mockTime;

        mockTime += 60000;
        await receiveWatchAction({
          'action': 'REPEAT',
          'timestampEpochMs': mockTime,
          'zoneId': 'America/Los_Angeles',
          'actionId': 'evt-repeat',
          'actionSeq': 1,
          'deviceId': 'watch-1',
        });

        final records = await db.getRecords();
        expect(records, hasLength(2));
        final repeated = records.first;
        expect(repeated.activityId, 'act-coding');
        expect(repeated.startedAtEpochMs, firstEnd);
        expect(repeated.endedAtEpochMs, mockTime);
        expect(dayRecorder.lap!.startedAtEpochMs, mockTime);
      },
    );

    test('incoming CONTINUE grows the last Record over the Lap', () async {
      syncService.initialize();
      await pumpEventQueue();
      mockTime += 60000;
      await dayRecorder.label('act-workout');
      await pumpEventQueue();

      mockTime += 60000;
      await receiveWatchAction({
        'action': 'CONTINUE',
        'timestampEpochMs': mockTime,
        'zoneId': 'America/Los_Angeles',
        'actionId': 'evt-still',
        'actionSeq': 1,
        'deviceId': 'watch-1',
      });

      final records = await db.getRecords();
      expect(records, hasLength(1));
      expect(records.single.activityId, 'act-workout');
      expect(records.single.endedAtEpochMs, mockTime);
      expect(dayRecorder.lap!.startedAtEpochMs, mockTime);
    });

    test('REPEAT with no earlier Record is rejected', () async {
      syncService.initialize();
      await pumpEventQueue();
      mockTime += 60000;
      methodCalls.clear();

      await receiveWatchAction({
        'action': 'REPEAT',
        'timestampEpochMs': mockTime,
        'zoneId': 'America/Los_Angeles',
        'actionId': 'evt-nothing',
        'actionSeq': 1,
        'deviceId': 'watch-1',
      });

      expect(await db.getRecords(), isEmpty);
      final ack =
          methodCalls.lastWhere((call) => call.method == 'syncLap').arguments
              as Map;
      expect(ack['rejectedActionIds'], contains('evt-nothing'));
    });

    test(
      'a delayed action is written at the instant and zone it was tapped',
      () async {
        syncService.initialize();
        await pumpEventQueue();
        final lapStart = mockTime;

        // The phone hears about the tap thirty minutes after it happened.
        mockTime += const Duration(minutes: 30).inMilliseconds;
        final tappedAt = mockTime - const Duration(minutes: 10).inMilliseconds;

        await receiveWatchAction({
          'action': 'LABEL',
          'activityId': 'act-workout',
          'timestampEpochMs': tappedAt,
          'zoneId': 'Europe/Berlin',
          'actionId': 'evt-delayed',
          'actionSeq': 1,
          'deviceId': 'watch-1',
        });

        final record = (await db.getRecords()).single;
        expect(record.startedAtEpochMs, lapStart);
        expect(record.endedAtEpochMs, tappedAt);
        expect(record.timezoneId, 'America/Los_Angeles');
        expect(record.endTimezoneId, 'Europe/Berlin');
        expect(dayRecorder.lap!.startedAtEpochMs, tappedAt);
      },
    );

    test(
      'an action older than the open Lap is rejected with lap-moved',
      () async {
        syncService.initialize();
        await pumpEventQueue();
        final lapStart = mockTime;

        mockTime += const Duration(minutes: 1).inMilliseconds;
        methodCalls.clear();

        await receiveWatchAction({
          'action': 'LABEL',
          'activityId': 'act-workout',
          'timestampEpochMs':
              lapStart - const Duration(minutes: 1).inMilliseconds,
          'zoneId': 'America/Los_Angeles',
          'actionId': 'evt-stale',
          'actionSeq': 2,
          'deviceId': 'watch-1',
        });

        expect(await db.getRecords(), isEmpty);
        expect(dayRecorder.lap!.startedAtEpochMs, lapStart);
        final ack =
            methodCalls.lastWhere((call) => call.method == 'syncLap').arguments
                as Map;
        expect(ack['rejectedActionIds'], ['evt-stale']);
        expect(ack['appliedActionSeq'], 0);
        expect(await watermarks('watch-1'), isEmpty);
      },
    );

    test('an applied action is acknowledged with appliedActionSeq', () async {
      syncService.initialize();
      await pumpEventQueue();
      mockTime += const Duration(minutes: 1).inMilliseconds;
      methodCalls.clear();

      await receiveWatchAction({
        'action': 'LABEL',
        'activityId': 'act-coding',
        'timestampEpochMs': mockTime,
        'zoneId': 'America/Los_Angeles',
        'actionId': 'evt-applied',
        'actionSeq': 3,
        'deviceId': 'watch-1',
      });

      expect(await db.getRecords(), hasLength(1));
      final acks = methodCalls
          .where((call) => call.method == 'syncLap')
          .map((call) => (call.arguments as Map)['appliedActionSeq']);
      expect(acks, contains(3));
      expect(await watermarks('watch-1'), [
        {'device_id': 'watch-1', 'action_seq': 3},
      ]);
    });

    test('the same action over both channels is applied once', () async {
      syncService.initialize();
      await pumpEventQueue();
      mockTime += const Duration(minutes: 1).inMilliseconds;

      final action = <String, dynamic>{
        'action': 'LABEL',
        'activityId': 'act-coding',
        'timestampEpochMs': mockTime,
        'zoneId': 'America/Los_Angeles',
        'actionId': 'evt-dupe',
        'actionSeq': 4,
        'deviceId': 'watch-1',
      };
      await receiveWatchAction(action);
      await receiveWatchAction(action);

      expect(await db.getRecords(), hasLength(1));
    });

    test(
      'a repeated LABEL at the Lap start is refused, not written as 0s',
      () async {
        syncService.initialize();
        await pumpEventQueue();
        mockTime += const Duration(minutes: 1).inMilliseconds;
        final tappedAt = mockTime;

        await receiveWatchAction({
          'action': 'LABEL',
          'activityId': 'act-coding',
          'timestampEpochMs': tappedAt,
          'zoneId': 'America/Los_Angeles',
          'actionId': 'evt-zero-first',
          'actionSeq': 1,
          'deviceId': 'watch-1',
        });
        expect(await db.getRecords(), hasLength(1));

        // A watch still on an older build re-sends the same tap with no
        // sequence, so the watermark cannot catch it. Its instant is now the
        // open Lap's start, so it would close a zero-second Record.
        await receiveWatchAction({
          'action': 'LABEL',
          'activityId': 'act-coding',
          'timestampEpochMs': tappedAt,
          'zoneId': 'America/Los_Angeles',
          'actionId': 'evt-zero-second',
          'deviceId': 'watch-1',
        });

        final records = await db.getRecords();
        expect(records, hasLength(1));
        expect(
          records.single.endedAtEpochMs - records.single.startedAtEpochMs,
          greaterThan(0),
        );
        final ack =
            methodCalls.lastWhere((call) => call.method == 'syncLap').arguments
                as Map;
        expect(ack['rejectedActionIds'], contains('evt-zero-second'));
      },
    );

    test('the watermark survives a service restart', () async {
      syncService.initialize();
      await pumpEventQueue();
      mockTime += const Duration(minutes: 1).inMilliseconds;

      final action = <String, dynamic>{
        'action': 'LABEL',
        'activityId': 'act-coding',
        'timestampEpochMs': mockTime,
        'zoneId': 'America/Los_Angeles',
        'actionId': 'evt-restart',
        'actionSeq': 7,
        'deviceId': 'watch-1',
      };
      await receiveWatchAction(action);
      expect(await db.getRecords(), hasLength(1));

      syncService.dispose();
      syncService = WearableSyncService(
        dayRecorder: dayRecorder,
        database: db,
        channel: channel,
        nowUtcMs: () => mockTime,
      );
      syncService.initialize();
      await pumpEventQueue();

      // The watch re-sends what is still pending once the phone comes back.
      await receiveWatchAction(action);

      expect(await db.getRecords(), hasLength(1));
      final acks = methodCalls
          .where((call) => call.method == 'syncLap')
          .map((call) => (call.arguments as Map)['appliedActionSeq']);
      expect(acks, contains(7));
    });

    test('channel errors during sync do not crash the service', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(
              code: 'WEAR_UNAVAILABLE',
              message: 'No watch paired',
            );
          });

      syncService.initialize();
      // Should not throw
      await dayRecorder.label('act-coding');
      await Future<void>.delayed(Duration.zero);
      expect(dayRecorder.lap, isNotNull);
      expect((await db.getRecords()).length, equals(1));
    });
  });
}
