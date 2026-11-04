import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

/// Database schema at v5 (prior to Category and category_id on activities).
const String _v5Activities = '''
CREATE TABLE activities (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    color_hex TEXT NOT NULL DEFAULT '#4CAF50',
    icon_name TEXT NOT NULL DEFAULT 'schedule',
    is_pinned INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v5Tags = '''
CREATE TABLE tags (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v5Records = '''
CREATE TABLE records (
    id TEXT PRIMARY KEY NOT NULL,
    activity_id TEXT REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL,
    ended_at_epoch_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    timezone_id TEXT NOT NULL,
    end_timezone_id TEXT NOT NULL DEFAULT '',
    is_midnight_split INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v5RecordTags = '''
CREATE TABLE record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''';

const String _v5Lap = '''
CREATE TABLE lap (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    started_at_epoch_ms INTEGER NOT NULL,
    started_timezone_id TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1
);
''';

const String _v5Tombstones = '''
CREATE TABLE tombstones (
    entity_id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    deleted_at_epoch_ms INTEGER NOT NULL
);
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tempo-category-migrate');
    dbPath = p.join(tempDir.path, 'tempo.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('migrates a v5 database through every schema version', () async {
    final v5Db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, version) async {
          await db.execute(_v5Activities);
          await db.execute(_v5Tags);
          await db.execute(_v5Records);
          await db.execute(_v5RecordTags);
          await db.execute(_v5Lap);
          await db.execute(_v5Tombstones);
        },
      ),
    );

    // Seed v5 data
    await v5Db.insert('activities', {
      'id': 'act-1',
      'name': 'Deep Work',
      'color_hex': '#2196F3',
      'icon_name': 'code',
      'is_pinned': 1,
      'sort_order': 0,
      'is_archived': 0,
      'created_at_epoch_ms': 1000,
      'updated_at_epoch_ms': 1000,
    });
    await v5Db.close();

    // Open through TempoDatabase which runs migrateV5ToV6
    final tempoDb = await TempoDatabase.open(path: dbPath);

    // Verify categories table exists
    final categories = await tempoDb.getCategories();
    expect(categories, isEmpty);

    // Verify existing activity preserved with null categoryId
    final activity = await tempoDb.getActivityById('act-1');
    expect(activity, isNotNull);
    expect(activity!.name, 'Deep Work');
    expect(activity.categoryId, isNull);

    // Upsert a category and assign it to the activity
    final category = Category(
      id: 'cat-1',
      name: 'Productivity',
      colorHex: '#4CAF50',
      iconName: 'folder',
      sortOrder: 1,
      createdAtEpochMs: 2000,
      updatedAtEpochMs: 2000,
    );
    await tempoDb.upsertCategory(category);

    final fetchedCat = await tempoDb.getCategoryById('cat-1');
    expect(fetchedCat, isNotNull);
    expect(fetchedCat!.name, 'Productivity');

    await tempoDb.updateActivity(activity.copyWith(categoryId: 'cat-1'));
    final updatedAct = await tempoDb.getActivityById('act-1');
    expect(updatedAct!.categoryId, 'cat-1');

    // Deleting category sets activity.categoryId to NULL via ON DELETE SET NULL
    await tempoDb.deleteCategory('cat-1');
    final afterDelCat = await tempoDb.getCategoryById('cat-1');
    expect(afterDelCat, isNull);

    final actAfterCatDeleted = await tempoDb.getActivityById('act-1');
    expect(actAfterCatDeleted!.categoryId, isNull);

    // Category deletion recorded a tombstone
    final tombstones = await tempoDb.getTombstones();
    expect(
      tombstones.any(
        (t) => t.entityId == 'cat-1' && t.entityType == 'category',
      ),
      isTrue,
    );

    // v7 adds the settings table, which every later migration path must create.
    await tempoDb.setSetting('today_activity_order', 'pinned');
    expect(await tempoDb.getSetting('today_activity_order'), equals('pinned'));

    await tempoDb.close();
  });

  test(
    'migrating to v8 aligns activity colours with their categories',
    () async {
      final v7Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, version) => TempoDatabase.createSchema(db),
        ),
      );

      await v7Db.insert('categories', {
        'id': 'cat-1',
        'name': 'Work',
        'color_hex': '#112233',
        'icon_name': 'folder',
        'sort_order': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });
      await v7Db.insert('activities', {
        'id': 'act-categorized',
        'name': 'Reading',
        'category_id': 'cat-1',
        'color_hex': '#ABCDEF',
        'icon_name': 'schedule',
        'is_pinned': 0,
        'sort_order': 0,
        'is_archived': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });
      await v7Db.insert('activities', {
        'id': 'act-loose',
        'name': 'Errands',
        'color_hex': '#ABCDEF',
        'icon_name': 'schedule',
        'is_pinned': 0,
        'sort_order': 1,
        'is_archived': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });
      await v7Db.close();

      final tempoDb = await TempoDatabase.open(path: dbPath);
      addTearDown(tempoDb.close);

      expect(
        (await tempoDb.getActivityById('act-categorized'))!.colorHex,
        '#112233',
      );
      expect((await tempoDb.getActivityById('act-loose'))!.colorHex, '#ABCDEF');
    },
  );

  test(
    'migrating to v9 backfills activities with default color to inherit parent category color',
    () async {
      final v8Db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, version) => TempoDatabase.createSchema(db),
        ),
      );

      await v8Db.insert('categories', {
        'id': 'cat-study',
        'name': 'Study',
        'color_hex': '#9C27B0',
        'icon_name': 'folder',
        'sort_order': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });

      // Activity with default color #4CAF50 and category
      await v8Db.insert('activities', {
        'id': 'act-default-color',
        'name': 'Math',
        'category_id': 'cat-study',
        'color_hex': '#4CAF50',
        'icon_name': 'schedule',
        'is_pinned': 0,
        'sort_order': 0,
        'is_archived': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });

      // Activity with custom color and category (should NOT be overwritten if already set)
      await v8Db.insert('activities', {
        'id': 'act-custom-color',
        'name': 'Physics',
        'category_id': 'cat-study',
        'color_hex': '#FF9800',
        'icon_name': 'schedule',
        'is_pinned': 0,
        'sort_order': 1,
        'is_archived': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });

      // Activity with default color but no category
      await v8Db.insert('activities', {
        'id': 'act-no-cat',
        'name': 'Random',
        'color_hex': '#4CAF50',
        'icon_name': 'schedule',
        'is_pinned': 0,
        'sort_order': 2,
        'is_archived': 0,
        'created_at_epoch_ms': 1000,
        'updated_at_epoch_ms': 1000,
      });

      await v8Db.close();

      final tempoDb = await TempoDatabase.open(path: dbPath);
      addTearDown(tempoDb.close);

      final mathAct = await tempoDb.getActivityById('act-default-color');
      expect(mathAct!.colorHex, equals('#9C27B0'));

      final physicsAct = await tempoDb.getActivityById('act-custom-color');
      expect(physicsAct!.colorHex, equals('#FF9800'));

      final noCatAct = await tempoDb.getActivityById('act-no-cat');
      expect(noCatAct!.colorHex, equals('#4CAF50'));
    },
  );
}
