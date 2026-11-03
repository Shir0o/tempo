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

  test('migrates database v5 to v6 creating categories table and category_id column', () async {
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

    await tempoDb.close();
  });
}
