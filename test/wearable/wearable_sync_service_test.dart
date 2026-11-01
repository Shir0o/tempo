import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/timer_state_machine.dart';
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
    late TimerStateMachine stateMachine;
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

      stateMachine = TimerStateMachine(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'rec-${++idCounter}',
      );
      await stateMachine.initialize();

      channel = const MethodChannel(WearableSyncService.channelName);
      methodCalls = [];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            if (call.method == 'syncActiveTimer' ||
                call.method == 'syncActivities') {
              return true;
            }
            return null;
          });

      syncService = WearableSyncService(
        timerStateMachine: stateMachine,
        database: db,
        channel: channel,
      );
    });

    tearDown(() async {
      syncService.dispose();
      stateMachine.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('initialize performs initial sync with idle state', () async {
      syncService.initialize();

      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'syncActiveTimer');
      final args = methodCalls.first.arguments as Map;
      expect(args['isRunning'], isFalse);
      expect(args['activityId'], isNull);
    });

    test(
      'starting a timer dispatches urgent active timer snapshot to watch',
      () async {
        syncService.initialize();
        methodCalls.clear();

        await stateMachine.start('act-coding');
        // Allow async activity lookup to finish
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(methodCalls.isNotEmpty, isTrue);
        final lastCall = methodCalls.last;
        expect(lastCall.method, 'syncActiveTimer');

        final args = lastCall.arguments as Map;
        expect(args['isRunning'], isTrue);
        expect(args['activityId'], 'act-coding');
        expect(args['activityName'], 'Coding');
        expect(args['activityColorHex'], '#2563EB');
        expect(args['startedAtEpochMs'], mockTime);
        expect(args['isPaused'], isFalse);
      },
    );

    test(
      'pausing and resuming timer dispatches updated state to watch',
      () async {
        syncService.initialize();
        await stateMachine.start('act-coding');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        methodCalls.clear();

        mockTime += 60000;
        await stateMachine.pause();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(methodCalls.isNotEmpty, isTrue);
        final pauseCall = methodCalls.last;
        final pauseArgs = pauseCall.arguments as Map;
        expect(pauseArgs['isRunning'], isFalse);
        expect(pauseArgs['isPaused'], isTrue);

        methodCalls.clear();
        mockTime += 30000;
        await stateMachine.resume();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(methodCalls.isNotEmpty, isTrue);
        final resumeCall = methodCalls.last;
        final resumeArgs = resumeCall.arguments as Map;
        expect(resumeArgs['isRunning'], isTrue);
        expect(resumeArgs['isPaused'], isFalse);
        expect(resumeArgs['accumulatedPauseMs'], 30000);
      },
    );

    test('stopping a timer dispatches idle state to watch', () async {
      syncService.initialize();
      await stateMachine.start('act-coding');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      methodCalls.clear();

      await stateMachine.stop();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(methodCalls.isNotEmpty, isTrue);
      final stopCall = methodCalls.last;
      final args = stopCall.arguments as Map;
      expect(args['isRunning'], isFalse);
      expect(args['activityId'], isNull);
      expect(args['activityName'], isNull);
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

    test('incoming START action from watch starts timer machine', () async {
      syncService.initialize();

      final watchActions = <WatchAction>[];
      final sub = syncService.incomingWatchActions.listen(watchActions.add);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();

      final callData = codec.encodeMethodCall(
        const MethodCall('onWatchActionReceived', {
          'action': 'START',
          'activityId': 'act-workout',
          'timestampEpochMs': 1700000010000,
          'actionId': 'evt-123',
        }),
      );

      await messenger.handlePlatformMessage(
        WearableSyncService.channelName,
        callData,
        (ByteData? reply) {},
      );

      expect(stateMachine.activeTimer, isNotNull);
      expect(stateMachine.activeTimer!.activityId, 'act-workout');
      expect(watchActions.length, 1);
      expect(watchActions.first.type, 'START');
      expect(watchActions.first.activityId, 'act-workout');

      await sub.cancel();
    });

    test('incoming STOP action from watch stops active timer', () async {
      syncService.initialize();
      await stateMachine.start('act-coding');

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codec = const StandardMethodCodec();

      final callData = codec.encodeMethodCall(
        const MethodCall('onWatchActionReceived', {
          'action': 'STOP',
          'timestampEpochMs': 1700000020000,
          'actionId': 'evt-124',
        }),
      );

      await messenger.handlePlatformMessage(
        WearableSyncService.channelName,
        callData,
        (ByteData? reply) {},
      );

      expect(stateMachine.activeTimer, isNull);
      expect(stateMachine.lastStoppedRecord, isNotNull);
      expect(stateMachine.lastStoppedRecord!.activityId, 'act-coding');
    });

    test(
      'incoming PAUSE and RESUME actions from watch transition timer',
      () async {
        syncService.initialize();
        await stateMachine.start('act-coding');

        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();

        // Pause
        await messenger.handlePlatformMessage(
          WearableSyncService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onWatchActionReceived', {
              'action': 'PAUSE',
              'timestampEpochMs': 1700000030000,
            }),
          ),
          (ByteData? reply) {},
        );
        expect(stateMachine.isPaused, isTrue);

        // Resume
        await messenger.handlePlatformMessage(
          WearableSyncService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onWatchActionReceived', {
              'action': 'RESUME',
              'timestampEpochMs': 1700000040000,
            }),
          ),
          (ByteData? reply) {},
        );
        expect(stateMachine.isTracking, isTrue);
        expect(stateMachine.isPaused, isFalse);
      },
    );

    test(
      'incoming UNDO action from watch discards timer without saving Record',
      () async {
        syncService.initialize();
        await stateMachine.start('act-coding');

        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final codec = const StandardMethodCodec();

        await messenger.handlePlatformMessage(
          WearableSyncService.channelName,
          codec.encodeMethodCall(
            const MethodCall('onWatchActionReceived', {
              'action': 'UNDO',
              'timestampEpochMs': 1700000050000,
            }),
          ),
          (ByteData? reply) {},
        );

        expect(stateMachine.activeTimer, isNull);
        expect(stateMachine.lastStoppedRecord, isNull);
      },
    );

    test(
      'channel errors during active timer change do not crash service',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              throw PlatformException(
                code: 'WEAR_UNAVAILABLE',
                message: 'No watch paired',
              );
            });

        syncService.initialize();
        // Should not throw
        await stateMachine.start('act-coding');
        await Future<void>.delayed(Duration.zero);
        expect(stateMachine.activeTimer, isNotNull);
      },
    );
  });
}
