import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/wearable/wearable_sync_service.dart';

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

// A watch label tapped before 00:00 is durable and can arrive after the phone
// has already split the Lap at local midnight. It must close the pre-midnight
// stretch at the tap, not be thrown away as `lap-moved`, and it must not
// disturb the new Day's open Lap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const zone = 'America/Los_Angeles';
  const workout = Activity(
    id: 'act-workout',
    name: 'Workout',
    colorHex: '#10B981',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );
  const sleep = Activity(
    id: 'act-sleep',
    name: 'Sleep',
    colorHex: '#9AA5C8',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  late TempoDatabase db;
  late DayRecorder recorder;
  late WearableSyncService syncService;
  late MethodChannel channel;
  late int nowUtc;
  late int idCounter;
  late List<Map<String, dynamic>> pendingActions;
  late List<MethodCall> methodCalls;

  setUp(() async {
    db = await TempoDatabase.openInMemory();
    await db.insertActivity(workout);
    await db.insertActivity(sleep);
    idCounter = 0;
    nowUtc = wallMs(zone, 2026, 6, 1, 22);
    recorder = DayRecorder(
      database: db,
      nowUtcMs: () => nowUtc,
      generateId: () => 'rec-${++idCounter}',
      getTimezoneId: () => zone,
      autoSplitAtMidnight: false,
    );
    await recorder.initialize();

    channel = const MethodChannel(WearableSyncService.channelName);
    methodCalls = [];
    pendingActions = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          methodCalls.add(call);
          switch (call.method) {
            case 'syncLap':
            case 'syncActivities':
            case 'pingWatch':
              return true;
            case 'drainPendingWatchActions':
              final drained = pendingActions;
              pendingActions = [];
              return drained;
          }
          return null;
        });

    syncService = WearableSyncService(
      dayRecorder: recorder,
      database: db,
      channel: channel,
      nowUtcMs: () => nowUtc,
    );
    await syncService.initialize();
    methodCalls.clear();
  });

  tearDown(() async {
    syncService.dispose();
    recorder.dispose();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

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

  /// Moves the phone past local midnight, the way the app does when it opens
  /// the next morning.
  Future<void> passMidnight(int hour) async {
    nowUtc = wallMs(zone, 2026, 6, 2, hour);
    await recorder.applyMidnightSplits();
  }

  test(
    'a 23:58 label delivered after 00:00 labels the night, not the new Day',
    () async {
      final lapStart = recorder.lap!.startedAtEpochMs;
      final midnight = wallMs(zone, 2026, 6, 2, 0);
      final tappedAt = wallMs(zone, 2026, 6, 1, 23, 58);

      await passMidnight(1);

      await receiveWatchAction({
        'action': 'LABEL',
        'activityId': workout.id,
        'timestampEpochMs': tappedAt,
        'zoneId': zone,
        'actionId': 'evt-overnight',
        'actionSeq': 1,
        'deviceId': 'watch-1',
      });

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      expect(records, hasLength(2));

      // The night is labelled up to the tap, even though the phone only heard
      // about it the next morning.
      expect(records[0].activityId, workout.id);
      expect(records[0].startedAtEpochMs, lapStart);
      expect(records[0].endedAtEpochMs, tappedAt);

      // The two minutes after the tap stay Untracked; the tap is a real edge.
      expect(records[1].activityId, isNull);
      expect(records[1].startedAtEpochMs, tappedAt);
      expect(records[1].endedAtEpochMs, midnight);

      // The new Day's open Lap is untouched.
      expect(recorder.lap!.startedAtEpochMs, midnight);

      final ack =
          methodCalls.lastWhere((call) => call.method == 'syncLap').arguments
              as Map;
      expect(ack['appliedActionSeq'], 1);
      expect(ack['rejectedActionIds'], isEmpty);
    },
  );

  test(
    'a late label covers the whole unlabelled span across earlier midnights',
    () async {
      // Start a day earlier so the phone has two MidnightSplits to absorb.
      syncService.dispose();
      recorder.dispose();
      await db.close();
      db = await TempoDatabase.openInMemory();
      await db.insertActivity(workout);
      await db.insertActivity(sleep);

      idCounter = 0;
      nowUtc = wallMs(zone, 2026, 5, 31, 22);
      recorder = DayRecorder(
        database: db,
        nowUtcMs: () => nowUtc,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => zone,
        autoSplitAtMidnight: false,
      );
      await recorder.initialize();
      syncService = WearableSyncService(
        dayRecorder: recorder,
        database: db,
        channel: channel,
        nowUtcMs: () => nowUtc,
      );
      await syncService.initialize();
      methodCalls.clear();

      final lapStart = recorder.lap!.startedAtEpochMs;
      final tappedAt = wallMs(zone, 2026, 6, 1, 23, 58);
      final midnight = wallMs(zone, 2026, 6, 2, 0);

      nowUtc = wallMs(zone, 2026, 6, 2, 1);
      await recorder.applyMidnightSplits();

      await receiveWatchAction({
        'action': 'LABEL',
        'activityId': workout.id,
        'timestampEpochMs': tappedAt,
        'zoneId': zone,
        'actionId': 'evt-two-nights',
        'actionSeq': 1,
        'deviceId': 'watch-1',
      });

      final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
      // One Record per Day (nothing crosses 00:00), both labelled; the two
      // minutes after the 23:58 tap stay Untracked.
      expect(records, hasLength(3));
      expect(records[0].activityId, workout.id);
      expect(records[0].startedAtEpochMs, lapStart);
      expect(records[0].endedAtEpochMs, wallMs(zone, 2026, 6, 1, 0));
      expect(records[1].activityId, workout.id);
      expect(records[1].startedAtEpochMs, wallMs(zone, 2026, 6, 1, 0));
      expect(records[1].endedAtEpochMs, tappedAt);
      expect(records[2].activityId, isNull);
      expect(records[2].startedAtEpochMs, tappedAt);
      expect(records[2].endedAtEpochMs, midnight);
      expect(recorder.lap!.startedAtEpochMs, midnight);
    },
  );

  test('a late "again" labels the night with the last Activity', () async {
    nowUtc = wallMs(zone, 2026, 6, 1, 22, 30);
    await recorder.label(sleep.id);
    final tappedAt = wallMs(zone, 2026, 6, 1, 23, 58);
    await passMidnight(1);
    methodCalls.clear();

    await receiveWatchAction({
      'action': 'REPEAT',
      'timestampEpochMs': tappedAt,
      'zoneId': zone,
      'actionId': 'evt-overnight-again',
      'actionSeq': 1,
      'deviceId': 'watch-1',
    });

    final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
    expect(records, hasLength(3));
    expect(records[0].activityId, sleep.id);
    expect(records[0].endedAtEpochMs, wallMs(zone, 2026, 6, 1, 22, 30));
    expect(records[1].activityId, sleep.id);
    expect(records[1].startedAtEpochMs, wallMs(zone, 2026, 6, 1, 22, 30));
    expect(records[1].endedAtEpochMs, tappedAt);
    expect(records[2].activityId, isNull);
    expect(recorder.lap!.startedAtEpochMs, wallMs(zone, 2026, 6, 2, 0));
  });

  test('a late "Still" carries the last note into the night', () async {
    nowUtc = wallMs(zone, 2026, 6, 1, 22, 30);
    await recorder.label(sleep.id, comment: 'w/ Sam');
    final tappedAt = wallMs(zone, 2026, 6, 1, 23, 58);
    await passMidnight(1);
    methodCalls.clear();

    await receiveWatchAction({
      'action': 'CONTINUE',
      'timestampEpochMs': tappedAt,
      'zoneId': zone,
      'actionId': 'evt-overnight-still',
      'actionSeq': 1,
      'deviceId': 'watch-1',
    });

    final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
    expect(records, hasLength(3));
    expect(records[1].activityId, sleep.id);
    expect(records[1].comment, 'w/ Sam');
    expect(records[1].startedAtEpochMs, wallMs(zone, 2026, 6, 1, 22, 30));
    expect(records[1].endedAtEpochMs, tappedAt);
    expect(recorder.lap!.startedAtEpochMs, wallMs(zone, 2026, 6, 2, 0));
  });

  test('a late label never overwrites time the phone already labelled', () async {
    // The phone labelled the whole stretch up to 23:59, so the 23:58 tap lands
    // inside time that already has an Activity.
    nowUtc = wallMs(zone, 2026, 6, 1, 23, 59);
    await recorder.label(sleep.id);
    final tappedAt = wallMs(zone, 2026, 6, 1, 23, 58);
    await passMidnight(1);
    methodCalls.clear();

    await receiveWatchAction({
      'action': 'LABEL',
      'activityId': workout.id,
      'timestampEpochMs': tappedAt,
      'zoneId': zone,
      'actionId': 'evt-conflict',
      'actionSeq': 1,
      'deviceId': 'watch-1',
    });

    final records = await db.getRecords(orderBy: 'started_at_epoch_ms ASC');
    expect(records, hasLength(2));
    expect(records[0].activityId, sleep.id);
    expect(records[0].endedAtEpochMs, wallMs(zone, 2026, 6, 1, 23, 59));
    expect(records[1].activityId, isNull);
    expect(recorder.lap!.startedAtEpochMs, wallMs(zone, 2026, 6, 2, 0));

    final ack =
        methodCalls.lastWhere((call) => call.method == 'syncLap').arguments
            as Map;
    expect(ack['rejectedActionIds'], contains('evt-conflict'));
  });
}
