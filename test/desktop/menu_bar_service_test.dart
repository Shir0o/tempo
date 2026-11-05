import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/state/record_commands.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/desktop/menu_bar_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MenuBarService - Static Title Formatting', () {
    test('idle state formatting with and without brackets', () {
      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.full,
          isIdle: true,
          brackets: true,
        ),
        equals('[⏱️]'),
      );

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.full,
          isIdle: true,
          brackets: false,
        ),
        equals('⏱️'),
      );
    });

    test('open Lap states across full, compact, minimal with brackets', () {
      // 1 hour 24 minutes (84 minutes = 5040 seconds)
      const elapsed = Duration(hours: 1, minutes: 24);

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.full,
          isIdle: false,
          elapsed: elapsed,
          brackets: true,
        ),
        equals('[🟢 01:24]'),
      );

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.compact,
          isIdle: false,
          elapsed: elapsed,
          brackets: true,
        ),
        equals('[🟢 01:24]'),
      );

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.minimal,
          isIdle: false,
          elapsed: elapsed,
          brackets: true,
        ),
        equals('[🟢]'),
      );
    });

    test('open Lap states without brackets', () {
      const elapsed = Duration(hours: 1, minutes: 24);

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.full,
          isIdle: false,
          elapsed: elapsed,
          brackets: false,
        ),
        equals('🟢 01:24'),
      );

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.compact,
          isIdle: false,
          elapsed: elapsed,
          brackets: false,
        ),
        equals('🟢 01:24'),
      );

      expect(
        MenuBarService.formatTitle(
          mode: StatusDisplayMode.minimal,
          isIdle: false,
          elapsed: elapsed,
          brackets: false,
        ),
        equals('🟢'),
      );
    });

    test('duration formatting edge cases: zero, seconds only, multi-hour', () {
      expect(MenuBarService.formatDurationHHMM(Duration.zero), equals('00:00'));

      expect(
        MenuBarService.formatDurationHHMM(const Duration(seconds: 45)),
        equals('00:00'),
      );

      expect(
        MenuBarService.formatDurationHHMM(
          const Duration(hours: 2, minutes: 5, seconds: 12),
        ),
        equals('02:05'),
      );

      expect(
        MenuBarService.formatDurationHHMM(
          const Duration(hours: 10, minutes: 0),
        ),
        equals('10:00'),
      );
    });

    test('StatusDisplayMode.fromString parses case-insensitively with full fallback', () {
      expect(
        StatusDisplayMode.fromString('full'),
        equals(StatusDisplayMode.full),
      );
      expect(
        StatusDisplayMode.fromString('FULL'),
        equals(StatusDisplayMode.full),
      );
      expect(
        StatusDisplayMode.fromString('compact'),
        equals(StatusDisplayMode.compact),
      );
      expect(
        StatusDisplayMode.fromString('COMPACT'),
        equals(StatusDisplayMode.compact),
      );
      expect(
        StatusDisplayMode.fromString('minimal'),
        equals(StatusDisplayMode.minimal),
      );
      expect(
        StatusDisplayMode.fromString('MINIMAL'),
        equals(StatusDisplayMode.minimal),
      );
      expect(
        StatusDisplayMode.fromString('unknown_mode'),
        equals(StatusDisplayMode.full),
      );
    });
  });

  group('MenuBarService - Reactive Service Lifecycle', () {
    late TempoDatabase db;
    late DayRecorder dayRecorder;
    late int mockTime;
    final channelCalls = <MethodCall>[];

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      mockTime = 1000000000;

      await db.insertActivity(
        const Activity(
          id: 'act-coding',
          name: 'Coding',
          colorHex: '#4CAF50',
          createdAtEpochMs: 1000000000,
          updatedAtEpochMs: 1000000000,
        ),
      );

      dayRecorder = DayRecorder(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'id-1',
        getTimezoneId: () => 'UTC',
      );
      await dayRecorder.initialize();

      channelCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(MenuBarService.channelName),
            (call) async {
              channelCalls.add(call);
              return null;
            },
          );
    });

    tearDown(() async {
      dayRecorder.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(MenuBarService.channelName),
            null,
          );
    });

    test('shows the Lap elapsed time and resets after a label', () async {
      final service = MenuBarService(
        commands: PhoneRecordCommands(dayRecorder: dayRecorder),
        dayRecorder: dayRecorder,
        database: db,
        nowUtcMs: () => mockTime,
      );

      expect(service.currentTitle, equals('[🟢 00:00]'));

      // Advance time by 84 minutes (1 hr 24 min)
      mockTime += const Duration(hours: 1, minutes: 24).inMilliseconds;

      // Trigger a refresh/tick
      await service.setDisplayMode(StatusDisplayMode.full);
      expect(service.currentTitle, equals('[🟢 01:24]'));

      // Labeling the Lap starts a new one at the same instant
      await dayRecorder.label('act-coding');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.currentTitle, equals('[🟢 00:00]'));

      service.dispose();
    });

    test('switches display modes dynamically', () async {
      final service = MenuBarService(
        commands: PhoneRecordCommands(dayRecorder: dayRecorder),
        dayRecorder: dayRecorder,
        database: db,
        nowUtcMs: () => mockTime,
      );

      mockTime += const Duration(hours: 1, minutes: 24).inMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await service.setDisplayMode(StatusDisplayMode.compact);
      expect(service.currentTitle, equals('[🟢 01:24]'));

      await service.setDisplayMode(StatusDisplayMode.minimal);
      expect(service.currentTitle, equals('[🟢]'));

      await service.setDisplayMode(StatusDisplayMode.full);
      expect(service.currentTitle, equals('[🟢 01:24]'));

      await service.setIncludeBrackets(false);
      expect(service.currentTitle, equals('🟢 01:24'));

      service.dispose();
    });

    test('dispatches updateStatusItem method channel calls', () async {
      final service = MenuBarService(
        commands: PhoneRecordCommands(dayRecorder: dayRecorder),
        dayRecorder: dayRecorder,
        database: db,
        nowUtcMs: () => mockTime,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final updateCalls = channelCalls
          .where((c) => c.method == 'updateStatusItem')
          .toList();
      expect(updateCalls.isNotEmpty, isTrue);
      expect(updateCalls.last.arguments['isTracking'], isTrue);
      expect(updateCalls.last.arguments['title'], startsWith('[🟢 '));

      service.dispose();
    });
  });
}
