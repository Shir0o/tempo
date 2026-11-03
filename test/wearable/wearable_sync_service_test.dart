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

    test('initialize performs initial sync with the open Lap', () async {
      syncService.initialize();

      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'syncLap');
      final args = methodCalls.first.arguments as Map;
      expect(args['lapStartedAtEpochMs'], mockTime);
      expect(args['lapStartedTimezoneId'], 'America/Los_Angeles');
      expect(args['revision'], dayRecorder.lap!.revision);
      expect(args.keys, hasLength(4));
    });

    test('labeling dispatches a fresh Lap snapshot to the watch', () async {
      syncService.initialize();
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
      expect(args.keys, hasLength(4));
    });

    test(
      'syncActivities dispatches serialized activity list to channel',
      () async {
        syncService.initialize();
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
      'tile slots are the three most-used Activities of the last 14 days',
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

    test('tile slots ignore labels older than 14 days', () async {
      syncService.initialize();
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
      expect(args['tileActivityIds'], ['act-coding']);
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

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();

      await messenger.handlePlatformMessage(
        WearableSyncService.channelName,
        codec.encodeMethodCall(
          const MethodCall('onWatchActionReceived', {
            'action': 'SPLIT',
            'timestampEpochMs': 1700000020000,
            'actionId': 'evt-126',
          }),
        ),
        (ByteData? reply) {},
      );

      final records = await db.getRecords();
      expect(records.length, equals(2));
      expect(records.first.activityId, isNull);
      expect(dayRecorder.lap!.startedAtEpochMs, equals(mockTime));
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
