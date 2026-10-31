import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/timer_state_machine.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/desktop/deep_link_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DeepLinkService', () {
    late TempoDatabase db;
    late TimerStateMachine stateMachine;
    late DeepLinkService deepLinkService;
    late int mockTime;
    late int idCounter;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      mockTime = 1000000000;
      idCounter = 0;

      await db.insertActivity(const Activity(
        id: 'act-coding',
        name: 'Coding',
        colorHex: '#4CAF50',
        createdAtEpochMs: 1000000000,
        updatedAtEpochMs: 1000000000,
      ));

      await db.insertActivity(const Activity(
        id: 'act-workout',
        name: 'Workout',
        colorHex: '#FF5722',
        createdAtEpochMs: 1000000000,
        updatedAtEpochMs: 1000000000,
      ));

      await db.insertTag(const Tag(
        id: 'tag-deep',
        name: 'DeepWork',
        createdAtEpochMs: 1000000000,
        updatedAtEpochMs: 1000000000,
      ));

      stateMachine = TimerStateMachine(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => 'America/Los_Angeles',
      );

      deepLinkService = DeepLinkService(
        timerStateMachine: stateMachine,
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'gen-${++idCounter}',
      );
    });

    tearDown(() async {
      stateMachine.dispose();
      await db.close();
    });

    group('tempo://start', () {
      test('starts timer with existing activity and decodes comment and tags',
          () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=Coding&comment=Review%20PR%20w/%20Alice&tags=DeepWork',
        );

        expect(success, isTrue);
        expect(stateMachine.isTracking, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-coding'));
        expect(stateMachine.activeTimer?.currentComment,
            equals('Review PR w/ Alice'));
        expect(stateMachine.activeTimer?.initialTagIds, contains('tag-deep'));
      });

      test('creates new activity and new tags when they do not exist', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=Guitar%20Practice&comment=Fingerpicking&tags=Music,Hobby',
        );

        expect(success, isTrue);
        expect(stateMachine.isTracking, isTrue);

        final activity =
            await db.getActivityById(stateMachine.activeTimer!.activityId);
        expect(activity, isNotNull);
        expect(activity!.name, equals('Guitar Practice'));

        final tags = await db.getAllTags();
        expect(tags.any((t) => t.name == 'Music'), isTrue);
        expect(tags.any((t) => t.name == 'Hobby'), isTrue);
        expect(stateMachine.activeTimer?.initialTagIds.length, equals(2));
      });

      test('supports activity UUID lookup directly', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=act-workout&comment=Chest%20Day',
        );

        expect(success, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-workout'));
        expect(stateMachine.activeTimer?.currentComment, equals('Chest Day'));
      });

      test('supports timetracker:// scheme for backwards compatibility',
          () async {
        final success = await deepLinkService.handleUrl(
          'timetracker://start?activity=Coding',
        );

        expect(success, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-coding'));
      });

      test('atomically switches when a timer is already active', () async {
        await deepLinkService.handleUrl(
          'tempo://start?activity=Coding&comment=Initial',
        );
        expect(stateMachine.activeTimer?.activityId, equals('act-coding'));

        mockTime += 60000; // 1 minute later

        final switched = await deepLinkService.handleUrl(
          'tempo://start?activity=Workout&comment=Gym',
        );

        expect(switched, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-workout'));
        expect(stateMachine.activeTimer?.currentComment, equals('Gym'));

        // Verify previous session was committed as record
        final records = await db.getRecords();
        expect(records.length, equals(1));
        expect(records.first.activityId, equals('act-coding'));
        expect(records.first.comment, equals('Initial'));
        expect(records.first.durationMs, equals(60000));
      });

      test('returns false when activity parameter is missing or empty',
          () async {
        expect(await deepLinkService.handleUrl('tempo://start'), isFalse);
        expect(
            await deepLinkService.handleUrl('tempo://start?activity='), isFalse);
        expect(await deepLinkService.handleUrl('tempo://start?activity=%20'),
            isFalse);
        expect(stateMachine.isIdle, isTrue);
      });
    });

    group('tempo://stop', () {
      test('stops running timer and persists optional comment', () async {
        await stateMachine.start('act-coding', comment: 'Draft');
        mockTime += 120000;

        final success = await deepLinkService.handleUrl(
          'tempo://stop?comment=Finished%20PR%20Review',
        );

        expect(success, isTrue);
        expect(stateMachine.isIdle, isTrue);

        final records = await db.getRecords();
        expect(records.length, equals(1));
        expect(records.first.comment, equals('Finished PR Review'));
        expect(records.first.durationMs, equals(120000));
      });

      test('stops running timer preserving current comment if none provided',
          () async {
        await stateMachine.start('act-coding', comment: 'Existing Note');
        mockTime += 30000;

        final success = await deepLinkService.handleUrl('tempo://stop');
        expect(success, isTrue);
        expect(stateMachine.isIdle, isTrue);

        final records = await db.getRecords();
        expect(records.first.comment, equals('Existing Note'));
      });

      test('handles stop gracefully when idle without error', () async {
        final success = await deepLinkService.handleUrl('tempo://stop');
        expect(success, isTrue);
        expect(stateMachine.isIdle, isTrue);
      });
    });

    group('tempo://pause and tempo://resume', () {
      test('pauses and resumes active timer cleanly', () async {
        await stateMachine.start('act-coding');
        expect(stateMachine.isTracking, isTrue);

        // Pause
        final pauseSuccess = await deepLinkService.handleUrl('tempo://pause');
        expect(pauseSuccess, isTrue);
        expect(stateMachine.isPaused, isTrue);

        // Resume
        mockTime += 10000;
        final resumeSuccess = await deepLinkService.handleUrl('tempo://resume');
        expect(resumeSuccess, isTrue);
        expect(stateMachine.isTracking, isTrue);
      });

      test('pause when idle or already paused is handled gracefully', () async {
        // Idle
        expect(await deepLinkService.handleUrl('tempo://pause'), isTrue);

        // Paused
        await stateMachine.start('act-coding');
        await stateMachine.pause();
        expect(await deepLinkService.handleUrl('tempo://pause'), isTrue);
        expect(stateMachine.isPaused, isTrue);
      });

      test('resume when idle or tracking is handled gracefully', () async {
        // Idle
        expect(await deepLinkService.handleUrl('tempo://resume'), isTrue);

        // Tracking
        await stateMachine.start('act-coding');
        expect(await deepLinkService.handleUrl('tempo://resume'), isTrue);
        expect(stateMachine.isTracking, isTrue);
      });
    });

    group('tempo://toggle', () {
      test('starts activity when idle', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://toggle?activity=Coding',
        );

        expect(success, isTrue);
        expect(stateMachine.isTracking, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-coding'));
      });

      test('stops timer when active with the same activity', () async {
        await stateMachine.start('act-coding');

        final success = await deepLinkService.handleUrl(
          'tempo://toggle?activity=Coding',
        );

        expect(success, isTrue);
        expect(stateMachine.isIdle, isTrue);
      });

      test('switches activity when active with a different activity', () async {
        await stateMachine.start('act-coding');

        final success = await deepLinkService.handleUrl(
          'tempo://toggle?activity=Workout',
        );

        expect(success, isTrue);
        expect(stateMachine.isTracking, isTrue);
        expect(stateMachine.activeTimer?.activityId, equals('act-workout'));
      });

      test('stops active timer when no activity parameter is provided',
          () async {
        await stateMachine.start('act-coding');

        final success = await deepLinkService.handleUrl('tempo://toggle');
        expect(success, isTrue);
        expect(stateMachine.isIdle, isTrue);
      });
    });

    group('Edge cases and URI variations', () {
      test('rejects unsupported URL schemes', () async {
        expect(await deepLinkService.handleUrl('http://start?activity=Coding'),
            isFalse);
        expect(await deepLinkService.handleUrl('https://stop'), isFalse);
        expect(await deepLinkService.handleUrl('file:///path/to/tempo'), isFalse);
      });

      test('rejects empty or malformed strings gracefully', () async {
        expect(await deepLinkService.handleUrl(''), isFalse);
        expect(await deepLinkService.handleUrl('   '), isFalse);
        expect(await deepLinkService.handleUrl(':::malformed:::'), isFalse);
      });

      test('handles path-based action syntax tempo:///start?activity=Coding',
          () async {
        final success = await deepLinkService.handleUrl(
          'tempo:///start?activity=Coding',
        );
        expect(success, isTrue);
        expect(stateMachine.isTracking, isTrue);
      });

      test('decodes Unicode and emoji in parameters', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=Research%20%F0%9F%9A%80&comment=%E2%9C%A8%20Testing',
        );

        expect(success, isTrue);
        final act =
            await db.getActivityById(stateMachine.activeTimer!.activityId);
        expect(act?.name, equals('Research 🚀'));
        expect(stateMachine.activeTimer?.currentComment, equals('✨ Testing'));
      });
    });
  });
}
