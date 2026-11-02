import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
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
    late DayRecorder dayRecorder;
    late DeepLinkService deepLinkService;
    late int mockTime;
    late int idCounter;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      mockTime = 1000000000;
      idCounter = 0;

      await db.insertActivity(
        const Activity(
          id: 'act-coding',
          name: 'Coding',
          colorHex: '#4CAF50',
          createdAtEpochMs: 1000000000,
          updatedAtEpochMs: 1000000000,
        ),
      );

      await db.insertActivity(
        const Activity(
          id: 'act-workout',
          name: 'Workout',
          colorHex: '#FF5722',
          createdAtEpochMs: 1000000000,
          updatedAtEpochMs: 1000000000,
        ),
      );

      await db.insertTag(
        const Tag(
          id: 'tag-deep',
          name: 'DeepWork',
          createdAtEpochMs: 1000000000,
          updatedAtEpochMs: 1000000000,
        ),
      );

      dayRecorder = DayRecorder(
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'rec-${++idCounter}',
        getTimezoneId: () => 'America/Los_Angeles',
      );
      await dayRecorder.initialize();

      deepLinkService = DeepLinkService(
        dayRecorder: dayRecorder,
        database: db,
        nowUtcMs: () => mockTime,
        generateId: () => 'gen-${++idCounter}',
      );
    });

    tearDown(() async {
      dayRecorder.dispose();
      await db.close();
    });

    group('tempo://start', () {
      test('labels the open Lap with the Activity, comment and tags', () async {
        mockTime += 60000;

        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=Coding&comment=Review%20PR%20w/%20Alice&tags=DeepWork',
        );

        expect(success, isTrue);
        final records = await db.getRecords();
        expect(records.length, equals(1));
        expect(records.first.activityId, equals('act-coding'));
        expect(records.first.comment, equals('Review PR w/ Alice'));
        expect(records.first.tagIds, contains('tag-deep'));
        expect(records.first.startedAtEpochMs, equals(1000000000));
        expect(records.first.endedAtEpochMs, equals(1000060000));
        expect(dayRecorder.lap!.startedAtEpochMs, equals(1000060000));
      });

      test(
        'creates new activity and new tags when they do not exist',
        () async {
          final success = await deepLinkService.handleUrl(
            'tempo://start?activity=Guitar%20Practice&comment=Fingerpicking&tags=Music,Hobby',
          );

          expect(success, isTrue);
          final records = await db.getRecords();
          expect(records.length, equals(1));

          final activity = await db.getActivityById(records.first.activityId!);
          expect(activity, isNotNull);
          expect(activity!.name, equals('Guitar Practice'));

          final tags = await db.getAllTags();
          expect(tags.any((t) => t.name == 'Music'), isTrue);
          expect(tags.any((t) => t.name == 'Hobby'), isTrue);
          expect(records.first.tagIds.length, equals(2));
        },
      );

      test('supports activity UUID lookup directly', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=act-workout&comment=Chest%20Day',
        );

        expect(success, isTrue);
        final records = await db.getRecords();
        expect(records.first.activityId, equals('act-workout'));
        expect(records.first.comment, equals('Chest Day'));
      });

      test(
        'supports timetracker:// scheme for backwards compatibility',
        () async {
          final success = await deepLinkService.handleUrl(
            'timetracker://start?activity=Coding',
          );

          expect(success, isTrue);
          final records = await db.getRecords();
          expect(records.first.activityId, equals('act-coding'));
        },
      );

      test('closes the previous Lap when a second start arrives', () async {
        await deepLinkService.handleUrl(
          'tempo://start?activity=Coding&comment=Initial',
        );

        mockTime += 60000; // 1 minute later

        final switched = await deepLinkService.handleUrl(
          'tempo://start?activity=Workout&comment=Gym',
        );

        expect(switched, isTrue);
        expect(dayRecorder.lap!.startedAtEpochMs, equals(1000060000));

        final records = await db.getRecords();
        expect(records.length, equals(2));
        final coding = records.firstWhere((r) => r.activityId == 'act-coding');
        expect(coding.comment, equals('Initial'));
        expect(coding.durationMs, equals(0));
        final workout = records.firstWhere(
          (r) => r.activityId == 'act-workout',
        );
        expect(workout.comment, equals('Gym'));
        expect(workout.durationMs, equals(60000));
      });

      test(
        'returns false when activity parameter is missing or empty',
        () async {
          expect(await deepLinkService.handleUrl('tempo://start'), isFalse);
          expect(
            await deepLinkService.handleUrl('tempo://start?activity='),
            isFalse,
          );
          expect(
            await deepLinkService.handleUrl('tempo://start?activity=%20'),
            isFalse,
          );
          expect(await db.getRecords(), isEmpty);
        },
      );
    });

    group('tempo://stop', () {
      test('splits the open Lap into an Untracked Record', () async {
        await deepLinkService.handleUrl('tempo://start?activity=Coding');
        mockTime += 120000;

        final success = await deepLinkService.handleUrl('tempo://stop');

        expect(success, isTrue);

        final records = await db.getRecords();
        expect(records.length, equals(2));
        final stopped = records.firstWhere(
          (r) => r.startedAtEpochMs == 1000000000,
        );
        expect(stopped.activityId, isNull);
        expect(stopped.durationMs, equals(120000));
        expect(dayRecorder.lap!.startedAtEpochMs, equals(1000120000));
      });

      test('splits with no previous Record without error', () async {
        final success = await deepLinkService.handleUrl('tempo://stop');
        expect(success, isTrue);
        final records = await db.getRecords();
        expect(records.length, equals(1));
        expect(records.single.activityId, isNull);
        expect(dayRecorder.lap!.startedAtEpochMs, equals(1000000000));
      });

      test('tempo://split is an alias for the same Split', () async {
        mockTime += 60000;
        expect(await deepLinkService.handleUrl('tempo://split'), isTrue);

        final records = await db.getRecords();
        expect(records.single.activityId, isNull);
        expect(records.single.durationMs, equals(60000));
      });
    });

    group('retired pause and resume links', () {
      test('pause and resume are no longer recognised', () async {
        expect(await deepLinkService.handleUrl('tempo://pause'), isFalse);
        expect(await deepLinkService.handleUrl('tempo://resume'), isFalse);
        expect(await db.getRecords(), isEmpty);
      });
    });

    group('tempo://toggle', () {
      test('labels the open Lap when an activity is provided', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://toggle?activity=Coding',
        );

        expect(success, isTrue);
        final records = await db.getRecords();
        expect(records.single.activityId, equals('act-coding'));
      });

      test(
        'labels the open Lap with the last Activity without a parameter',
        () async {
          await deepLinkService.handleUrl('tempo://start?activity=Coding');
          mockTime += 30000;

          final success = await deepLinkService.handleUrl('tempo://toggle');
          expect(success, isTrue);

          final records = await db.getRecords();
          expect(records.length, equals(2));
          expect(records.first.activityId, equals('act-coding'));
        },
      );
    });

    group('Edge cases and URI variations', () {
      test('rejects unsupported URL schemes', () async {
        expect(
          await deepLinkService.handleUrl('http://start?activity=Coding'),
          isFalse,
        );
        expect(await deepLinkService.handleUrl('https://stop'), isFalse);
        expect(
          await deepLinkService.handleUrl('file:///path/to/tempo'),
          isFalse,
        );
      });

      test('rejects empty or malformed strings gracefully', () async {
        expect(await deepLinkService.handleUrl(''), isFalse);
        expect(await deepLinkService.handleUrl('   '), isFalse);
        expect(await deepLinkService.handleUrl(':::malformed:::'), isFalse);
      });

      test(
        'handles path-based action syntax tempo:///start?activity=Coding',
        () async {
          final success = await deepLinkService.handleUrl(
            'tempo:///start?activity=Coding',
          );
          expect(success, isTrue);
          expect((await db.getRecords()).length, equals(1));
        },
      );

      test('decodes Unicode and emoji in parameters', () async {
        final success = await deepLinkService.handleUrl(
          'tempo://start?activity=Research%20%F0%9F%9A%80&comment=%E2%9C%A8%20Testing',
        );

        expect(success, isTrue);
        final records = await db.getRecords();
        final act = await db.getActivityById(records.first.activityId!);
        expect(act?.name, equals('Research 🚀'));
        expect(records.first.comment, equals('✨ Testing'));
      });
    });
  });
}
