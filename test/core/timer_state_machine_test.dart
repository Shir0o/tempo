import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/timer_state_machine.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late TempoDatabase db;
  late int mockTime;
  late String mockTimezone;
  late int idCounter;

  int mockClock() => mockTime;
  String mockIdGenerator() => 'mock-id-${++idCounter}';
  String mockTzProvider() => mockTimezone;

  const activityA = Activity(
    id: 'act-a',
    name: 'Coding',
    colorHex: '#2196F3',
    iconName: 'code',
    isPinned: true,
    sortOrder: 1,
    createdAtEpochMs: 1000000,
    updatedAtEpochMs: 1000000,
  );

  const activityB = Activity(
    id: 'act-b',
    name: 'Reading',
    colorHex: '#4CAF50',
    iconName: 'book',
    isPinned: false,
    sortOrder: 2,
    createdAtEpochMs: 1000000,
    updatedAtEpochMs: 1000000,
  );

  const tagDeepWork = Tag(
    id: 'tag-deep',
    name: 'DeepWork',
    colorHex: '#FF5722',
    createdAtEpochMs: 1000000,
    updatedAtEpochMs: 1000000,
  );

  const tagClient = Tag(
    id: 'tag-client',
    name: 'Client',
    colorHex: '#9C27B0',
    createdAtEpochMs: 1000000,
    updatedAtEpochMs: 1000000,
  );

  setUp(() async {
    db = await TempoDatabase.openInMemory();
    await db.insertActivity(activityA);
    await db.insertActivity(activityB);
    await db.insertTag(tagDeepWork);
    await db.insertTag(tagClient);

    mockTime = 1000000;
    mockTimezone = 'America/Los_Angeles';
    idCounter = 0;
  });

  tearDown(() async {
    await db.close();
  });

  TimerStateMachine createStateMachine({
    Duration heartbeatInterval = const Duration(seconds: 60),
    int? crashThresholdMs,
    Future<void> Function(Record)? onRecordCommitted,
  }) {
    return TimerStateMachine(
      database: db,
      nowUtcMs: mockClock,
      generateId: mockIdGenerator,
      getTimezoneId: mockTzProvider,
      heartbeatInterval: heartbeatInterval,
      crashThresholdMs: crashThresholdMs,
      onRecordCommitted: onRecordCommitted,
    );
  }

  group('Lifecycle: Start, Pause, Resume, Stop Cycle & Duration Math', () {
    test('full standard lifecycle calculates exact duration math', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(sm.isIdle, isTrue);
      expect(sm.isTracking, isFalse);
      expect(sm.isPaused, isFalse);
      expect(sm.activeTimer, isNull);
      expect(sm.currentDurationMs, 0);

      // 1. Start tracking Activity A at T = 1,000,000
      mockTime = 1000000;
      final started = await sm.start(
        activityA.id,
        comment: 'Initial feature code',
        tagIds: [tagDeepWork.id, tagClient.id],
      );

      expect(started.activityId, activityA.id);
      expect(started.startedAtEpochMs, 1000000);
      expect(started.isPaused, isFalse);
      expect(started.pausedAtEpochMs, isNull);
      expect(started.accumulatedPauseMs, 0);
      expect(started.currentComment, 'Initial feature code');
      expect(started.initialTagIds, equals([tagDeepWork.id, tagClient.id]));
      expect(started.lastHeartbeatEpochMs, 1000000);
      expect(started.revision, 1);

      expect(sm.isIdle, isFalse);
      expect(sm.isTracking, isTrue);
      expect(sm.isPaused, isFalse);

      // Verify active_timer row in SQLite
      final inDb = await db.getActiveTimer();
      expect(inDb, equals(started));

      // Elapsed at T = 1,030,000 (30 seconds active)
      mockTime = 1030000;
      expect(sm.currentDurationMs, 30000);

      // 2. Pause at T = 1,040,000 (after 40s active)
      mockTime = 1040000;
      final paused = await sm.pause();
      expect(paused.isPaused, isTrue);
      expect(paused.pausedAtEpochMs, 1040000);
      expect(paused.lastHeartbeatEpochMs, 1040000);
      expect(paused.revision, 2);
      expect(paused.accumulatedPauseMs, 0);

      expect(sm.isTracking, isFalse);
      expect(sm.isPaused, isTrue);

      // Elapsed while paused at T = 1,070,000 (30s later in wall-clock)
      mockTime = 1070000;
      // Duration must remain frozen at 40s!
      expect(sm.currentDurationMs, 40000);

      // 3. Resume at T = 1,080,000 (paused for 40,000 ms)
      mockTime = 1080000;
      final resumed = await sm.resume();
      expect(resumed.isPaused, isFalse);
      expect(resumed.pausedAtEpochMs, isNull);
      expect(resumed.accumulatedPauseMs, 40000);
      expect(resumed.lastHeartbeatEpochMs, 1080000);
      expect(resumed.revision, 3);

      expect(sm.isTracking, isTrue);
      expect(sm.isPaused, isFalse);

      // At T = 1,080,000, duration is still 40,000 ms
      expect(sm.currentDurationMs, 40000);

      // At T = 1,110,000 (30s after resume), duration is 70,000 ms
      mockTime = 1110000;
      expect(sm.currentDurationMs, 70000);

      // 4. Stop at T = 1,120,000 (40s after resume, total active = 80,000 ms)
      mockTime = 1120000;
      final record = await sm.stop(finalComment: 'Completed feature code');

      expect(record.id, 'mock-id-1');
      expect(record.activityId, activityA.id);
      expect(record.startedAtEpochMs, 1000000);
      expect(record.endedAtEpochMs, 1120000);
      // Duration: 1,120,000 - 1,000,000 - 40,000 = 80,000 ms
      expect(record.durationMs, 80000);
      expect(record.comment, 'Completed feature code');
      expect(record.timezoneId, 'America/Los_Angeles');
      expect(record.tagIds, equals([tagDeepWork.id, tagClient.id]));

      expect(sm.isIdle, isTrue);
      expect(sm.isTracking, isFalse);
      expect(sm.activeTimer, isNull);
      expect(sm.lastStoppedRecord, equals(record));

      // SQLite active_timer table must be cleared
      expect(await db.getActiveTimer(), isNull);

      // SQLite records table must contain the saved record and junction tags
      final savedRecord = await db.getRecordById('mock-id-1');
      expect(savedRecord, isNotNull);
      expect(savedRecord!.durationMs, 80000);
      expect(savedRecord.tagIds, containsAll([tagDeepWork.id, tagClient.id]));
    });

    test(
      'stopping a paused timer preserves duration at paused timestamp',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        mockTime = 2000000;
        await sm.start(activityA.id);

        // Active for 50,000 ms
        mockTime = 2050000;
        await sm.pause();

        // Stop 1 hour later while still paused
        mockTime = 5650000;
        final record = await sm.stop();

        expect(record.startedAtEpochMs, 2000000);
        expect(record.endedAtEpochMs, 2050000);
        expect(record.durationMs, 50000);
        expect(await db.getActiveTimer(), isNull);
      },
    );

    test('multiple pause and resume cycles accumulate accurately', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      mockTime = 100000;
      await sm.start(activityA.id); // T = 100,000

      // Run 20s -> Pause 1
      mockTime = 120000;
      await sm.pause(); // paused at 120,000

      // Pause for 10s -> Resume 1
      mockTime = 130000;
      await sm.resume(); // accumulated = 10,000

      // Run 30s -> Pause 2
      mockTime = 160000;
      await sm.pause(); // paused at 160,000

      // Pause for 15s -> Resume 2
      mockTime = 175000;
      await sm.resume(); // accumulated = 10,000 + 15,000 = 25,000

      // Run 25s -> Stop
      mockTime = 200000;
      final record = await sm.stop();

      // Total wall clock: 200,000 - 100,000 = 100,000
      // Total pause: 25,000
      // Duration: 75,000
      expect(record.durationMs, 75000);
      expect(record.endedAtEpochMs, 200000);
    });
  });

  group('Atomic Switch Behavior', () {
    test(
      'starting activity B while A is running properly saves A and starts B',
      () async {
        Record? committedViaHook;
        final sm = createStateMachine(
          onRecordCommitted: (rec) async {
            committedViaHook = rec;
          },
        );
        addTearDown(sm.dispose);

        // Start Activity A
        mockTime = 1000000;
        await sm.start(
          activityA.id,
          comment: 'Working on A',
          tagIds: [tagDeepWork.id],
        );

        // 45 seconds later, switch to Activity B via start()
        mockTime = 1045000;
        final switchedTimer = await sm.start(
          activityB.id,
          comment: 'Switching to B',
          tagIds: [tagClient.id],
        );

        expect(switchedTimer.activityId, activityB.id);
        expect(switchedTimer.startedAtEpochMs, 1045000);
        expect(switchedTimer.currentComment, 'Switching to B');
        expect(switchedTimer.initialTagIds, equals([tagClient.id]));
        expect(switchedTimer.revision, 2);

        // Verify stopped record for Activity A
        expect(sm.lastStoppedRecord, isNotNull);
        final stoppedRecord = sm.lastStoppedRecord!;
        expect(stoppedRecord.activityId, activityA.id);
        expect(stoppedRecord.startedAtEpochMs, 1000000);
        expect(stoppedRecord.endedAtEpochMs, 1045000);
        expect(stoppedRecord.durationMs, 45000);
        expect(stoppedRecord.comment, 'Working on A');
        expect(stoppedRecord.tagIds, equals([tagDeepWork.id]));
        expect(committedViaHook, equals(stoppedRecord));

        // Verify SQLite state: Exactly 1 record saved, active_timer is B
        final allRecords = await db.getRecords();
        expect(allRecords.length, 1);
        expect(allRecords.first.id, stoppedRecord.id);
        expect(allRecords.first.activityId, activityA.id);

        final activeInDb = await db.getActiveTimer();
        expect(activeInDb, isNotNull);
        expect(activeInDb!.activityId, activityB.id);
        expect(activeInDb.startedAtEpochMs, 1045000);

        // Now switchActivity called directly while B is running
        mockTime = 1070000;
        final finalSwitched = await sm.switchActivity(
          activityA.id,
          comment: 'Back to A',
        );
        expect(finalSwitched.activityId, activityA.id);
        expect(finalSwitched.startedAtEpochMs, 1070000);

        // Database should now have 2 completed records (A and B)
        final allRecordsAfter = await db.getRecords();
        expect(allRecordsAfter.length, 2);
        expect(allRecordsAfter[0].activityId, activityB.id);
        expect(allRecordsAfter[0].durationMs, 25000); // 1070000 - 1045000
        expect(allRecordsAfter[1].activityId, activityA.id);
      },
    );

    test(
      'switchActivity when idle acts as start without saving any record',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        mockTime = 500000;
        final timer = await sm.switchActivity(
          activityA.id,
          comment: 'Fresh start via switch',
        );

        expect(timer.activityId, activityA.id);
        expect(timer.startedAtEpochMs, 500000);
        expect(timer.revision, 1);
        expect(sm.lastStoppedRecord, isNull);

        final records = await db.getRecords();
        expect(records, isEmpty);
      },
    );

    test(
      'switchActivity rolls back atomically if new activity does not exist',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        mockTime = 1000000;
        await sm.start(activityA.id, comment: 'Active session');

        mockTime = 1030000;
        expect(
          () => sm.switchActivity('non-existent-activity-id'),
          throwsA(isA<ArgumentError>()),
        );

        // Verify that Activity A is still active and no record was inserted!
        final active = await db.getActiveTimer();
        expect(active, isNotNull);
        expect(active!.activityId, activityA.id);
        expect(await db.getRecords(), isEmpty);
      },
    );
  });

  group('Heartbeat Management', () {
    test(
      'tickHeartbeat updates last_heartbeat_epoch_ms in SQLite and memory',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        mockTime = 1000000;
        await sm.start(activityA.id);

        expect(sm.activeTimer!.lastHeartbeatEpochMs, 1000000);

        // 60s later: tick heartbeat
        mockTime = 1060000;
        await sm.tickHeartbeat();

        expect(sm.activeTimer!.lastHeartbeatEpochMs, 1060000);
        final inDb = await db.getActiveTimer();
        expect(inDb!.lastHeartbeatEpochMs, 1060000);
      },
    );

    test('heartbeat loop executes periodically while active', () async {
      final sm = createStateMachine(
        heartbeatInterval: const Duration(milliseconds: 20),
      );
      addTearDown(sm.dispose);

      mockTime = 1000000;
      await sm.start(activityA.id);

      mockTime = 1000050;
      // Wait for periodic timer to trigger
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final active = await db.getActiveTimer();
      expect(active!.lastHeartbeatEpochMs, 1000050);
    });

    test('pausing timer stops periodic heartbeat updates', () async {
      final sm = createStateMachine(
        heartbeatInterval: const Duration(milliseconds: 20),
      );
      addTearDown(sm.dispose);

      mockTime = 1000000;
      await sm.start(activityA.id);

      mockTime = 1020000;
      await sm.pause();

      // Advance time while paused
      mockTime = 1050000;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // last_heartbeat_epoch_ms must stay at pause time (1020000)
      final active = await db.getActiveTimer();
      expect(active!.lastHeartbeatEpochMs, 1020000);
    });
  });

  group('Boot-Up Crash Recovery (>6 Hour Gap)', () {
    test(
      'detects abnormal shutdown when gap exceeds 6 hours (21,600,000 ms)',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        // Seed an active timer into the DB as if the app crashed
        final startedTime = 1000000;
        final crashHeartbeatTime = startedTime + 3600000; // 1 hour into session
        final simulatedActiveTimer = ActiveTimer(
          activityId: activityA.id,
          startedAtEpochMs: startedTime,
          isPaused: false,
          accumulatedPauseMs: 0,
          currentComment: 'Crashed session',
          initialTagIds: [tagDeepWork.id],
          lastHeartbeatEpochMs: crashHeartbeatTime,
          revision: 1,
        );
        await db.setActiveTimer(simulatedActiveTimer);

        // Boot up 7 hours after heartbeat (gap = 25,200,000 ms > 21,600,000 ms)
        mockTime = crashHeartbeatTime + 25200000;

        final session = await sm.checkCrashRecovery();
        expect(session, isNotNull);
        expect(session!.activeTimer.activityId, activityA.id);
        expect(session.gapMs, 25200000);
        expect(session.durationMsIfTruncated, 3600000); // 1 hr
        expect(session.elapsedMsIfKept, 28800000); // 8 hrs total
      },
    );

    test(
      'Option 1: keepTracking() updates heartbeat and resumes smoothly',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        final startedTime = 1000000;
        final crashHeartbeatTime = 2000000;
        await db.setActiveTimer(
          ActiveTimer(
            activityId: activityA.id,
            startedAtEpochMs: startedTime,
            lastHeartbeatEpochMs: crashHeartbeatTime,
            currentComment: 'All-nighter session',
          ),
        );

        // Boot 8 hours later
        mockTime = crashHeartbeatTime + 28800000;
        final session = await sm.checkCrashRecovery();
        expect(session, isNotNull);

        // User elects to keep tracking
        await session!.keepTracking();

        expect(sm.isTracking, isTrue);
        expect(sm.activeTimer!.lastHeartbeatEpochMs, mockTime);
        expect(sm.activeTimer!.revision, 2);

        final inDb = await db.getActiveTimer();
        expect(inDb!.lastHeartbeatEpochMs, mockTime);
      },
    );

    test(
      'Option 2: truncateToHeartbeat() saves record at last heartbeat time',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        final startedTime = 1000000;
        final crashHeartbeatTime = startedTime + 7200000; // 2 hours in
        await db.setActiveTimer(
          ActiveTimer(
            activityId: activityA.id,
            startedAtEpochMs: startedTime,
            lastHeartbeatEpochMs: crashHeartbeatTime,
            currentComment: 'Device died on flight',
            initialTagIds: [tagClient.id],
          ),
        );

        // Boot 10 hours later
        mockTime = crashHeartbeatTime + 36000000;
        final session = await sm.checkCrashRecovery();
        expect(session, isNotNull);

        // User elects to truncate to heartbeat
        final savedRecord = await session!.truncateToHeartbeat(
          finalComment: 'Truncated after flight',
        );

        expect(savedRecord.startedAtEpochMs, startedTime);
        expect(savedRecord.endedAtEpochMs, crashHeartbeatTime);
        expect(savedRecord.durationMs, 7200000); // Exactly 2 hours!
        expect(savedRecord.comment, 'Truncated after flight');
        expect(savedRecord.tagIds, equals([tagClient.id]));

        expect(sm.isIdle, isTrue);
        expect(await db.getActiveTimer(), isNull);
        expect(await db.getRecordById(savedRecord.id), isNotNull);
      },
    );

    test(
      'Option 3: discard() deletes active timer without saving a record',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        final startedTime = 1000000;
        final crashHeartbeatTime = startedTime + 60000;
        await db.setActiveTimer(
          ActiveTimer(
            activityId: activityA.id,
            startedAtEpochMs: startedTime,
            lastHeartbeatEpochMs: crashHeartbeatTime,
          ),
        );

        mockTime = crashHeartbeatTime + 30000000; // 8+ hours
        final session = await sm.checkCrashRecovery();
        expect(session, isNotNull);

        await session!.discard();

        expect(sm.isIdle, isTrue);
        expect(await db.getActiveTimer(), isNull);
        expect(await db.getRecords(), isEmpty);
      },
    );

    test('gap <= 6 hours returns null and continues normal tracking', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      final startedTime = 1000000;
      final crashHeartbeatTime = startedTime + 3600000;
      await db.setActiveTimer(
        ActiveTimer(
          activityId: activityA.id,
          startedAtEpochMs: startedTime,
          lastHeartbeatEpochMs: crashHeartbeatTime,
        ),
      );

      // Boot only 30 minutes later (gap = 1,800,000 ms <= 21,600,000 ms)
      mockTime = crashHeartbeatTime + 1800000;
      final session = await sm.checkCrashRecovery();

      expect(session, isNull);
      expect(sm.isTracking, isTrue);
      expect(sm.activeTimer!.startedAtEpochMs, startedTime);
    });

    test('truncateToHeartbeat truncates to paused_at if timer was paused prior to crash', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      final startedTime = 1000000;
      final pauseTime = 1030000;
      final crashHeartbeatTime = 1030000;
      await db.setActiveTimer(
        ActiveTimer(
          activityId: activityA.id,
          startedAtEpochMs: startedTime,
          isPaused: true,
          pausedAtEpochMs: pauseTime,
          lastHeartbeatEpochMs: crashHeartbeatTime,
        ),
      );

      mockTime = crashHeartbeatTime + 30000000; // 8+ hours
      final session = await sm.checkCrashRecovery();
      expect(session, isNotNull);
      expect(session!.durationMsIfTruncated, 30000);

      final record = await session.truncateToHeartbeat();
      expect(record.startedAtEpochMs, startedTime);
      expect(record.endedAtEpochMs, pauseTime);
      expect(record.durationMs, 30000);
      expect(await db.getActiveTimer(), isNull);
    });

    test(
      'checkCrashRecovery when DB has no active timer returns null',
      () async {
        final sm = createStateMachine();
        addTearDown(sm.dispose);

        final session = await sm.checkCrashRecovery();
        expect(session, isNull);
        expect(sm.isIdle, isTrue);
      },
    );
  });

  group('UTC Epoch Invariance Across Time Zone and DST Shifts', () {
    test('duration calculation is 100% invariant to DST hour jumps', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      // Start at 1:30 AM before a 2:00 AM "Spring Forward" DST shift
      // Monotonic UTC timestamp = 100,000,000
      mockTime = 100000000;
      mockTimezone = 'America/Los_Angeles';
      await sm.start(activityA.id);

      // Suppose wall-clock jumps ahead 1 hour (+3,600s), but only 30 physical minutes elapse
      // UTC epoch advances by exactly 30 minutes = 1,800,000 ms
      mockTime = 100000000 + 1800000;
      expect(sm.currentDurationMs, 1800000);

      // Suppose wall-clock "Falls Back" in Autumn, but 1 physical hour elapses
      // UTC epoch advances by 3,600,000 ms
      mockTime = 100000000 + 1800000 + 3600000;
      expect(sm.currentDurationMs, 5400000);

      // Stop and verify record duration
      final record = await sm.stop();
      expect(record.durationMs, 5400000);
    });

    test('timezone change mid-tracking records the ending timezone without altering duration', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      // Start in Los Angeles
      mockTime = 1000000;
      mockTimezone = 'America/Los_Angeles';
      await sm.start(activityA.id);

      // Plane lands in London (GMT), timezone changes
      mockTime = 1000000 + 36000000; // 10 hours later
      mockTimezone = 'Europe/London';

      final record = await sm.stop();
      expect(record.durationMs, 36000000);
      expect(record.timezoneId, 'Europe/London');
    });
  });

  group('Invalid State Transitions & Error Handling', () {
    test('pause throws StateError when idle', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(() => sm.pause(), throwsA(isA<StateError>()));
    });

    test('pause throws StateError when already paused', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      await sm.start(activityA.id);
      await sm.pause();

      expect(() => sm.pause(), throwsA(isA<StateError>()));
    });

    test('resume throws StateError when idle', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(() => sm.resume(), throwsA(isA<StateError>()));
    });

    test('resume throws StateError when actively tracking', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      await sm.start(activityA.id);
      expect(() => sm.resume(), throwsA(isA<StateError>()));
    });

    test('stop throws StateError when idle', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(() => sm.stop(), throwsA(isA<StateError>()));
    });

    test('start throws ArgumentError for non-existent activity', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(() => sm.start('invalid-id'), throwsA(isA<ArgumentError>()));
    });

    test('truncateToHeartbeat, keepTracking, and discard throw StateError when idle', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      expect(() => sm.truncateToHeartbeat(), throwsA(isA<StateError>()));
      expect(() => sm.keepTracking(), throwsA(isA<StateError>()));
      expect(() => sm.discard(), throwsA(isA<StateError>()));
    });
  });

  group('Stream & ValueNotifier Reactivity', () {
    test('emits updates on start, pause, resume, stop, and switch', () async {
      final sm = createStateMachine();
      addTearDown(sm.dispose);

      final emittedStates = <ActiveTimer?>[];
      final sub = sm.timerStream.listen((state) {
        emittedStates.add(state);
      });
      addTearDown(sub.cancel);

      final notifierStates = <ActiveTimer?>[];
      void notifierListener() {
        notifierStates.add(sm.activeTimerNotifier.value);
      }

      sm.activeTimerNotifier.addListener(notifierListener);
      addTearDown(
        () => sm.activeTimerNotifier.removeListener(notifierListener),
      );

      // 1. Start A
      mockTime = 1000000;
      await sm.start(activityA.id);

      // 2. Pause A
      mockTime = 1010000;
      await sm.pause();

      // 3. Resume A
      mockTime = 1020000;
      await sm.resume();

      // 4. Switch to B
      mockTime = 1030000;
      await sm.switchActivity(activityB.id);

      // 5. Stop B
      mockTime = 1040000;
      await sm.stop();

      expect(emittedStates.length, 5);
      expect(emittedStates[0]?.activityId, activityA.id);
      expect(emittedStates[0]?.isPaused, isFalse);

      expect(emittedStates[1]?.activityId, activityA.id);
      expect(emittedStates[1]?.isPaused, isTrue);

      expect(emittedStates[2]?.activityId, activityA.id);
      expect(emittedStates[2]?.isPaused, isFalse);

      expect(emittedStates[3]?.activityId, activityB.id);
      expect(emittedStates[3]?.isPaused, isFalse);

      expect(emittedStates[4], isNull);

      // Notifier states mirror the stream
      expect(notifierStates.length, 5);
      expect(notifierStates.last, isNull);
    });
  });
}
