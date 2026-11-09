import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';
import 'package:tempo/data/models/sync_change.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late TempoDatabase db;

  setUp(() async {
    db = await TempoDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  group('TempoDatabase Schema & Tables', () {
    test('creates all expected tables and indexes', () async {
      final tables = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
      );
      final tableNames = tables.map((t) => t['name'] as String).toSet();

      expect(
        tableNames,
        containsAll([
          'activities',
          'tags',
          'records',
          'record_tags',
          'lap',
          'tombstones',
        ]),
      );

      final indexes = await db.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name;",
      );
      final indexNames = indexes.map((i) => i['name'] as String).toSet();

      expect(
        indexNames,
        containsAll([
          'idx_records_started',
          'idx_records_activity',
          'idx_records_updated',
          'idx_tombstones_deleted',
        ]),
      );
    });

    test('enforces foreign keys pragma', () async {
      final pragma = await db.db.rawQuery('PRAGMA foreign_keys;');
      expect(pragma.first.values.first, 1);
    });
  });

  group('Activities CRUD & Tombstones', () {
    test('inserts, reads, updates, and soft filters activities', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final activity = Activity(
        id: 'act-1',
        name: 'Coding',
        colorHex: '#2196F3',
        iconName: 'code',
        isPinned: true,
        sortOrder: 1,
        isArchived: false,
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );

      await db.insertActivity(activity);

      final fetched = await db.getActivityById('act-1');
      expect(fetched, isNotNull);
      expect(fetched!.name, 'Coding');
      expect(fetched.colorHex, '#2196F3');
      expect(fetched.isPinned, isTrue);

      // Update
      final updated = activity.copyWith(name: 'Deep Coding', sortOrder: 2);
      await db.updateActivity(updated);

      final fetchedUpdated = await db.getActivityById('act-1');
      expect(fetchedUpdated!.name, 'Deep Coding');
      expect(fetchedUpdated.sortOrder, 2);

      // Archived filter
      final archived = activity.copyWith(id: 'act-2', isArchived: true);
      await db.insertActivity(archived);

      final unarchivedList = await db.getAllActivities(includeArchived: false);
      expect(unarchivedList.map((a) => a.id), contains('act-1'));
      expect(unarchivedList.map((a) => a.id), isNot(contains('act-2')));

      final allList = await db.getAllActivities(includeArchived: true);
      expect(allList.map((a) => a.id), containsAll(['act-1', 'act-2']));
    });

    test(
      'deleting an activity creates tombstone and cascades to records',
      () async {
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final activity = Activity(
          id: 'act-del',
          name: 'Reading',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );
        await db.insertActivity(activity);

        final record = Record(
          id: 'rec-1',
          activityId: 'act-del',
          startedAtEpochMs: now - 3600000,
          endedAtEpochMs: now,
          comment: 'Book chapter',
          timezoneId: 'UTC',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );
        await db.insertRecord(record);

        // Verify record exists
        expect(await db.getRecordById('rec-1'), isNotNull);

        // Delete activity
        final deleteTime = now + 1000;
        await db.deleteActivity('act-del', deletedAtEpochMs: deleteTime);

        // Verify activity deleted
        expect(await db.getActivityById('act-del'), isNull);

        // Verify cascaded record deleted
        expect(await db.getRecordById('rec-1'), isNull);

        // Verify tombstones recorded for both activity and cascaded record
        final tombstones = await db.getTombstones();
        final entityIds = tombstones.map((t) => t.entityId).toList();
        expect(entityIds, containsAll(['act-del', 'rec-1']));

        final actTombstone = tombstones.firstWhere(
          (t) => t.entityId == 'act-del',
        );
        expect(actTombstone.entityType, 'activity');
        expect(actTombstone.deletedAtEpochMs, deleteTime);

        final recTombstone = tombstones.firstWhere(
          (t) => t.entityId == 'rec-1',
        );
        expect(recTombstone.entityType, 'record');
        expect(recTombstone.deletedAtEpochMs, deleteTime);
      },
    );

    test(
      'createActivity inherits category color when default colorHex is used',
      () async {
        await db.upsertCategory(
          Category(
            id: 'cat-palette',
            name: 'Health',
            colorHex: '#00BCD4',
            iconName: 'fitness_center',
            sortOrder: 0,
            createdAtEpochMs: 1000,
            updatedAtEpochMs: 1000,
          ),
        );

        final created = await db.createActivity(
          id: 'act-inherited',
          name: 'Running',
          categoryId: 'cat-palette',
        );
        expect(created.colorHex, equals('#00BCD4'));

        final fromDb = await db.getActivityById('act-inherited');
        expect(fromDb, isNotNull);
        expect(fromDb!.colorHex, equals('#00BCD4'));
      },
    );
  });

  group('Catalog change feed', () {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    Activity activity(String id, {String? categoryId}) => Activity(
      id: id,
      name: 'Activity $id',
      categoryId: categoryId,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );

    Record record(String id, String activityId) => Record(
      id: id,
      activityId: activityId,
      startedAtEpochMs: now - 3600000,
      endedAtEpochMs: now,
      timezoneId: 'UTC',
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );

    test('inserting and updating an activity emits activity_upsert', () async {
      await db.insertActivity(activity('act-feed'));
      final inserted = await db.changesAfter(0);
      final upsert = inserted.singleWhere(
        (change) => change.kind == SyncChangeKind.activityUpsert,
      );
      expect(upsert.entityId, 'act-feed');
      expect(upsert.atEpochMs, now);
      expect(upsert.activity!.name, 'Activity act-feed');

      final before = await db.highestChangeSeq();
      final renamed = activity('act-feed')
          .copyWith(name: 'Renamed', updatedAtEpochMs: now + 1);
      await db.updateActivity(renamed);

      final updated = await db.changesAfter(before);
      expect(updated, hasLength(1));
      expect(updated.single.kind, SyncChangeKind.activityUpsert);
      expect(updated.single.activity!.name, 'Renamed');
    });

    test('deleting an activity emits activity_remove and a record_remove per '
        'cascaded Record', () async {
      await db.insertActivity(activity('act-del'));
      await db.insertRecord(record('rec-a', 'act-del'));
      await db.insertRecord(record('rec-b', 'act-del'));
      final before = await db.highestChangeSeq();
      final deletedAt = now + 500;

      await db.deleteActivity('act-del', deletedAtEpochMs: deletedAt);

      final changes = await db.changesAfter(before);
      final activityRemoval = changes.singleWhere(
        (change) => change.kind == SyncChangeKind.activityRemove,
      );
      expect(activityRemoval.entityId, 'act-del');
      expect(activityRemoval.atEpochMs, deletedAt);
      expect(activityRemoval.payload['id'], 'act-del');

      expect(
        changes
            .where((change) => change.kind == SyncChangeKind.recordRemove)
            .map((change) => change.entityId)
            .toSet(),
        {'rec-a', 'rec-b'},
      );
      expect(await db.getRecordById('rec-a'), isNull);
      expect(await db.getRecordById('rec-b'), isNull);
    });

    test('deleting a category emits category_remove', () async {
      await db.upsertCategory(
        Category(
          id: 'cat-del',
          name: 'Doomed',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      final before = await db.highestChangeSeq();

      await db.deleteCategory('cat-del', deletedAtEpochMs: now + 900);

      final changes = await db.changesAfter(before);
      expect(changes, hasLength(1));
      expect(changes.single.kind, SyncChangeKind.categoryRemove);
      expect(changes.single.entityId, 'cat-del');
      expect(changes.single.atEpochMs, now + 900);
      expect(await db.getCategoryById('cat-del'), isNull);
    });

    test('deleting a tag emits tag_remove', () async {
      await db.insertTag(
        Tag(
          id: 'tag-del',
          name: 'Doomed tag',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      final before = await db.highestChangeSeq();

      await db.deleteTag('tag-del', deletedAtEpochMs: now + 700);

      final changes = await db.changesAfter(before);
      expect(changes, hasLength(1));
      expect(changes.single.kind, SyncChangeKind.tagRemove);
      expect(changes.single.entityId, 'tag-del');
      expect(changes.single.atEpochMs, now + 700);
      expect(await db.getTagById('tag-del'), isNull);
    });

    test('a category colour change emits an activity_upsert for each of its '
        'activities', () async {
      final category = Category(
        id: 'cat-color',
        name: 'Colour',
        colorHex: '#111111',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.upsertCategory(category);
      await db.insertActivity(activity('act-one', categoryId: category.id));
      await db.insertActivity(activity('act-two', categoryId: category.id));
      final before = await db.highestChangeSeq();

      await db.upsertCategory(
        category.copyWith(colorHex: '#222222', updatedAtEpochMs: now + 1),
      );

      final changes = await db.changesAfter(before);
      expect(changes.first.kind, SyncChangeKind.categoryUpsert);
      expect(changes.first.category!.colorHex, '#222222');
      final propagated = changes
          .where((change) => change.kind == SyncChangeKind.activityUpsert)
          .toList();
      expect(propagated.map((change) => change.entityId).toSet(), {
        'act-one',
        'act-two',
      });
      for (final change in propagated) {
        expect(change.activity!.colorHex, '#222222');
        expect(change.atEpochMs, now + 1);
      }
      expect((await db.getActivityById('act-one'))!.colorHex, '#222222');
    });
  });

  group('Activity archive', () {
    final now = 1730000000000;

    Activity activity(String id) => Activity(
      id: id,
      name: 'Activity $id',
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    );

    Record record(
      String id,
      String activityId, {
      String comment = '',
      List<String> tagIds = const [],
    }) => Record(
      id: id,
      activityId: activityId,
      startedAtEpochMs: now - 3600000,
      endedAtEpochMs: now,
      comment: comment,
      timezoneId: 'America/Los_Angeles',
      endTimezoneId: 'America/New_York',
      isMidnightSplit: true,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
      tagIds: tagIds,
    );

    test(
      'moves tagged records to the target and archives the source',
      () async {
        await db.insertActivity(activity('act-source'));
        await db.insertActivity(activity('act-target'));
        await db.insertTag(
          Tag(
            id: 'tag-one',
            name: 'One',
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
          ),
        );
        await db.insertTag(
          Tag(
            id: 'tag-two',
            name: 'Two',
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
          ),
        );
        await db.insertRecord(
          record(
            'rec-moved',
            'act-source',
            comment: 'Keep this note',
            tagIds: ['tag-one', 'tag-two'],
          ),
        );
        await db.insertRecord(
          record(
            'rec-already-target',
            'act-target',
            comment: 'Target history',
            tagIds: ['tag-two'],
          ),
        );
        final before = await db.highestChangeSeq();
        final archivedAt = now + 100;

        final moved = await db.archiveActivity(
          activity('act-source'),
          mergeIntoActivityId: 'act-target',
          updatedAtEpochMs: archivedAt,
        );

        expect(moved, 1);
        final source = await db.getActivityById('act-source');
        expect(source!.isArchived, isTrue);
        expect(source.updatedAtEpochMs, archivedAt);
        final target = await db.getActivityById('act-target');
        expect(target!.isArchived, isFalse);
        expect(target.updatedAtEpochMs, now);

        final movedRecord = await db.getRecordById('rec-moved');
        expect(movedRecord!.activityId, 'act-target');
        expect(movedRecord.comment, 'Keep this note');
        expect(movedRecord.startedAtEpochMs, now - 3600000);
        expect(movedRecord.endedAtEpochMs, now);
        expect(movedRecord.timezoneId, 'America/Los_Angeles');
        expect(movedRecord.endTimezoneId, 'America/New_York');
        expect(movedRecord.isMidnightSplit, isTrue);
        expect(movedRecord.tagIds, containsAll(['tag-one', 'tag-two']));
        expect(movedRecord.updatedAtEpochMs, archivedAt);

        final untouched = await db.getRecordById('rec-already-target');
        expect(untouched!.activityId, 'act-target');
        expect(untouched.updatedAtEpochMs, now);
        expect(untouched.tagIds, equals(['tag-two']));

        final changes = await db.changesAfter(before);
        expect(changes, hasLength(2));
        final recordChange = changes.singleWhere(
          (change) => change.kind == SyncChangeKind.recordUpsert,
        );
        expect(recordChange.entityId, 'rec-moved');
        expect(recordChange.atEpochMs, archivedAt);
        expect(recordChange.record!.activityId, 'act-target');
        expect(recordChange.record!.comment, 'Keep this note');
        expect(
          recordChange.record!.tagIds,
          containsAll(['tag-one', 'tag-two']),
        );
        final activityChange = changes.singleWhere(
          (change) => change.kind == SyncChangeKind.activityUpsert,
        );
        expect(activityChange.entityId, 'act-source');
        expect(activityChange.atEpochMs, archivedAt);
        expect(activityChange.activity!.isArchived, isTrue);
      },
    );

    test('archives without moving records when no target is given', () async {
      await db.insertActivity(activity('act-source'));
      await db.insertRecord(record('rec-kept', 'act-source'));
      final before = await db.highestChangeSeq();
      final archivedAt = now + 200;

      final moved = await db.archiveActivity(
        activity('act-source'),
        updatedAtEpochMs: archivedAt,
      );

      expect(moved, 0);
      expect((await db.getActivityById('act-source'))!.isArchived, isTrue);
      final kept = await db.getRecordById('rec-kept');
      expect(kept!.activityId, 'act-source');
      expect(kept.updatedAtEpochMs, now);

      final changes = await db.changesAfter(before);
      expect(changes, hasLength(1));
      expect(changes.single.kind, SyncChangeKind.activityUpsert);
      expect(changes.single.entityId, 'act-source');
      expect(changes.single.activity!.isArchived, isTrue);
      expect(changes.single.atEpochMs, archivedAt);
    });

    test('rejects same or unknown targets without writing', () async {
      await db.insertActivity(activity('act-source'));
      await db.insertRecord(record('rec-kept', 'act-source'));
      final before = await db.highestChangeSeq();

      await expectLater(
        db.archiveActivity(
          activity('act-source'),
          mergeIntoActivityId: 'act-source',
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        db.archiveActivity(
          activity('act-source'),
          mergeIntoActivityId: 'act-missing',
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect((await db.getActivityById('act-source'))!.isArchived, isFalse);
      expect((await db.getRecordById('rec-kept'))!.activityId, 'act-source');
      expect(await db.highestChangeSeq(), before);
    });
  });

  group('Tags CRUD & Tombstones', () {
    test('inserts, reads, updates, and deletes tags with tombstones', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final tag = Tag(
        id: 'tag-1',
        name: 'DeepWork',
        colorHex: '#FF5722',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );

      await db.insertTag(tag);

      final byId = await db.getTagById('tag-1');
      expect(byId, equals(tag));

      final byName = await db.getTagByName('DeepWork');
      expect(byName, equals(tag));

      // Update
      final updated = tag.copyWith(name: 'SuperDeepWork');
      await db.updateTag(updated);
      expect((await db.getTagById('tag-1'))!.name, 'SuperDeepWork');

      // Unique name constraint
      final duplicateTag = Tag(
        id: 'tag-2',
        name: 'SuperDeepWork',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      expect(
        () async => await db.insertTag(duplicateTag),
        throwsA(isA<DatabaseException>()),
      );

      // Delete and tombstone
      await db.deleteTag('tag-1', deletedAtEpochMs: now + 500);
      expect(await db.getTagById('tag-1'), isNull);

      final tombstones = await db.getTombstones();
      expect(
        tombstones.any((t) => t.entityId == 'tag-1' && t.entityType == 'tag'),
        isTrue,
      );
    });

    test('a tag named Contact adopts the flag when none is marked', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await db.insertTag(
        Tag(
          id: 'tag-contact',
          name: 'Contact',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );

      final contact = await db.getContactTag();
      expect(contact?.id, 'tag-contact');
    });

    test('marking a tag Contact clears the previous one', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await db.insertTag(
        Tag(
          id: 'tag-first',
          name: 'People',
          isContact: true,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      await db.insertTag(
        Tag(
          id: 'tag-second',
          name: 'Shared',
          isContact: true,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );

      final contact = await db.getContactTag();
      expect(contact?.id, 'tag-second');
      expect((await db.getTagById('tag-first'))!.isContact, isFalse);
    });
  });

  group('Records CRUD & Record Tags Junction', () {
    late Activity testActivity;
    late Tag testTag1;
    late Tag testTag2;

    setUp(() async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      testActivity = Activity(
        id: 'act-main',
        name: 'Research',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertActivity(testActivity);

      testTag1 = Tag(
        id: 'tag-focus',
        name: 'Focus',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      testTag2 = Tag(
        id: 'tag-client',
        name: 'Client',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );
      await db.insertTag(testTag1);
      await db.insertTag(testTag2);
    });

    test('inserts record with junction tags and retrieves them', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final record = Record(
        id: 'rec-tagged',
        activityId: testActivity.id,
        startedAtEpochMs: now - 1800000,
        endedAtEpochMs: now,
        comment: 'Client research w/ Bob',
        timezoneId: 'America/Los_Angeles',
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
        tagIds: [testTag1.id, testTag2.id],
      );

      await db.insertRecord(record);

      final fetched = await db.getRecordById('rec-tagged');
      expect(fetched, isNotNull);
      expect(fetched!.comment, 'Client research w/ Bob');
      expect(fetched.timezoneId, 'America/Los_Angeles');
      expect(fetched.tagIds, containsAll([testTag1.id, testTag2.id]));

      // Update record with modified tags
      final updated = record.copyWith(
        comment: 'Client research updated',
        tagIds: [testTag1.id],
      );
      await db.updateRecord(updated);

      final fetchedUpdated = await db.getRecordById('rec-tagged');
      expect(fetchedUpdated!.comment, 'Client research updated');
      expect(fetchedUpdated.tagIds, equals([testTag1.id]));
    });

    test('filters records by date range, activity, and pagination', () async {
      final t1 = 1000000;
      final t2 = 2000000;
      final t3 = 3000000;

      final r1 = Record(
        id: 'r1',
        activityId: testActivity.id,
        startedAtEpochMs: t1,
        endedAtEpochMs: t1 + 1000,
        timezoneId: 'UTC',
        createdAtEpochMs: t1,
        updatedAtEpochMs: t1,
        tagIds: [testTag1.id],
      );
      final r2 = Record(
        id: 'r2',
        activityId: testActivity.id,
        startedAtEpochMs: t2,
        endedAtEpochMs: t2 + 1000,
        timezoneId: 'UTC',
        createdAtEpochMs: t2,
        updatedAtEpochMs: t2,
        tagIds: [testTag2.id],
      );
      final r3 = Record(
        id: 'r3',
        activityId: testActivity.id,
        startedAtEpochMs: t3,
        endedAtEpochMs: t3 + 1000,
        timezoneId: 'UTC',
        createdAtEpochMs: t3,
        updatedAtEpochMs: t3,
      );

      await db.insertRecord(r1);
      await db.insertRecord(r2);
      await db.insertRecord(r3);

      // Started after t2
      final afterT2 = await db.getRecords(startedAfter: t2);
      expect(afterT2.map((r) => r.id), equals(['r3', 'r2'])); // Ordered DESC

      // Started before t2
      final beforeT2 = await db.getRecords(startedBefore: t2);
      expect(beforeT2.map((r) => r.id), equals(['r2', 'r1']));

      // Limit and offset
      final paged = await db.getRecords(limit: 1, offset: 1);
      expect(paged.map((r) => r.id), equals(['r2']));
      expect(paged.first.tagIds, equals([testTag2.id]));
    });

    test(
      'deleting a record removes junction rows and writes tombstone',
      () async {
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final record = Record(
          id: 'rec-del',
          activityId: testActivity.id,
          startedAtEpochMs: now,
          endedAtEpochMs: now + 500,
          timezoneId: 'UTC',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
          tagIds: [testTag1.id],
        );
        await db.insertRecord(record);

        await db.deleteRecord('rec-del', deletedAtEpochMs: now + 100);
        expect(await db.getRecordById('rec-del'), isNull);

        // Verify junction table cascade
        final junctionRows = await db.db.query(
          'record_tags',
          where: 'record_id = ?',
          whereArgs: ['rec-del'],
        );
        expect(junctionRows, isEmpty);

        // Verify tombstone
        final tombstones = await db.getTombstones();
        expect(
          tombstones.any(
            (t) => t.entityId == 'rec-del' && t.entityType == 'record',
          ),
          isTrue,
        );
      },
    );

    test(
      'foreign key constraint fails on invalid activity reference',
      () async {
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final invalidRecord = Record(
          id: 'rec-invalid',
          activityId: 'non-existent-activity',
          startedAtEpochMs: now,
          endedAtEpochMs: now + 100,
          timezoneId: 'UTC',
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );

        expect(
          () async => await db.insertRecord(invalidRecord),
          throwsA(isA<DatabaseException>()),
        );
      },
    );
  });

  group('Lap Operations & Invariants', () {
    test('manages the single-row Lap', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final lap = Lap(
        startedAtEpochMs: now - 60000,
        startedTimezoneId: 'America/Los_Angeles',
        revision: 1,
      );

      await db.setLap(lap);

      final fetched = await db.getLap();
      expect(fetched, isNotNull);
      expect(fetched!.startedAtEpochMs, equals(now - 60000));
      expect(fetched.startedTimezoneId, equals('America/Los_Angeles'));
      expect(fetched.revision, equals(1));

      // Elapsed duration uses UTC epoch arithmetic.
      expect(fetched.elapsedMs(now), equals(60000));

      // Replacing the row keeps exactly one Lap.
      await db.setLap(fetched.copyWith(revision: 2, startedAtEpochMs: now));
      final replaced = await db.getLap();
      expect(replaced!.revision, equals(2));
      expect(replaced.startedAtEpochMs, equals(now));

      final rows = await db.db.query('lap');
      expect(rows.length, equals(1));
    });

    test('violates CHECK (id = 1) constraint when id != 1', () async {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(
        () async => await db.db.rawInsert('''
          INSERT INTO lap (id, started_at_epoch_ms, started_timezone_id, revision)
          VALUES (2, $now, 'UTC', 1);
        '''),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('Tombstones purging and querying', () {
    test(
      'queries tombstones by timestamp threshold and purges old ones',
      () async {
        final t1 = 100000;
        final t2 = 200000;
        final t3 = 300000;

        await db.insertTombstone(
          Tombstone(entityId: 'e1', entityType: 'record', deletedAtEpochMs: t1),
        );
        await db.insertTombstone(
          Tombstone(
            entityId: 'e2',
            entityType: 'activity',
            deletedAtEpochMs: t2,
          ),
        );
        await db.insertTombstone(
          Tombstone(entityId: 'e3', entityType: 'tag', deletedAtEpochMs: t3),
        );

        final recent = await db.getTombstones(deletedAfterEpochMs: t1);
        expect(recent.map((t) => t.entityId), equals(['e2', 'e3']));

        // Purge older than t2
        final purgedCount = await db.purgeTombstonesOlderThan(t2);
        expect(purgedCount, 1);

        final remaining = await db.getTombstones();
        expect(remaining.map((t) => t.entityId), equals(['e2', 'e3']));
      },
    );
  });

  group('Categories', () {
    test('upserting a category keeps its activities attached', () async {
      final category = Category(
        id: 'cat-1',
        name: 'Work',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      );
      await db.upsertCategory(category);
      await db.insertActivity(
        Activity(
          id: 'act-1',
          name: 'Reading',
          categoryId: 'cat-1',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );

      await db.upsertCategory(
        category.copyWith(name: 'Deep Work', sortOrder: 2),
      );

      final activity = await db.getActivityById('act-1');
      expect(activity!.categoryId, equals('cat-1'));
      final saved = await db.getCategoryById('cat-1');
      expect(saved!.name, equals('Deep Work'));
    });

    test('activities in a category wear the category colour', () async {
      final category = Category(
        id: 'cat-1',
        name: 'Work',
        colorHex: '#111111',
        createdAtEpochMs: 0,
        updatedAtEpochMs: 0,
      );
      await db.upsertCategory(category);

      await db.insertActivity(
        Activity(
          id: 'act-1',
          name: 'Reading',
          categoryId: 'cat-1',
          colorHex: '#AAAAAA',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      await db.insertActivity(
        Activity(
          id: 'act-2',
          name: 'Writing',
          categoryId: 'cat-1',
          colorHex: '#BBBBBB',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      await db.insertActivity(
        Activity(
          id: 'act-loose',
          name: 'Errands',
          colorHex: '#CCCCCC',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );

      expect((await db.getActivityById('act-1'))!.colorHex, '#111111');
      expect((await db.getActivityById('act-2'))!.colorHex, '#111111');
      expect((await db.getActivityById('act-loose'))!.colorHex, '#CCCCCC');

      // Assigning an uncategorised activity adopts the category colour.
      final loose = await db.getActivityById('act-loose');
      await db.updateActivity(loose!.copyWith(categoryId: 'cat-1'));
      expect((await db.getActivityById('act-loose'))!.colorHex, '#111111');

      // Recolouring the category updates every activity in it.
      await db.upsertCategory(
        category.copyWith(colorHex: '#222222', updatedAtEpochMs: 1),
      );
      for (final id in ['act-1', 'act-2', 'act-loose']) {
        expect((await db.getActivityById(id))!.colorHex, '#222222');
      }
    });

    test(
      'deleting a category keeps its last colour on its activities',
      () async {
        final category = Category(
          id: 'cat-1',
          name: 'Work',
          colorHex: '#333333',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        );
        await db.upsertCategory(category);
        await db.insertActivity(
          Activity(
            id: 'act-1',
            name: 'Reading',
            categoryId: 'cat-1',
            colorHex: '#999999',
            createdAtEpochMs: 0,
            updatedAtEpochMs: 0,
          ),
        );

        await db.deleteCategory('cat-1');

        final activity = await db.getActivityById('act-1');
        expect(activity!.categoryId, isNull);
        expect(activity.colorHex, '#333333');
      },
    );
  });

  group('Settings', () {
    test('stores and overwrites values by key', () async {
      expect(await db.getSetting('today_activity_order'), isNull);

      await db.setSetting('today_activity_order', 'pinned');
      expect(await db.getSetting('today_activity_order'), equals('pinned'));

      await db.setSetting('today_activity_order', 'alphabetical');
      expect(
        await db.getSetting('today_activity_order'),
        equals('alphabetical'),
      );
    });
  });
}
