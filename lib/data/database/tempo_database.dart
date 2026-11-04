import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';
import 'migrations.dart';

const bool _kIsWeb =
    bool.fromEnvironment('dart.library.js_util') ||
    bool.fromEnvironment('dart.library.js_interop');

class TempoDatabase {
  final Database _db;

  TempoDatabase(this._db);

  Database get db => _db;

  static const int databaseVersion = 8;
  static const String databaseFileName = 'tempo.db';

  // --- DDL Constants (schema v6) ---

  static const String createCategoriesTable = '''
CREATE TABLE IF NOT EXISTS categories (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL,
    icon_name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

  static const String createActivitiesTable = '''
CREATE TABLE IF NOT EXISTS activities (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
    color_hex TEXT NOT NULL DEFAULT '#4CAF50',
    icon_name TEXT NOT NULL DEFAULT 'schedule',
    is_pinned INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

  static const String createTagsTable = '''
CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

  static const String createRecordsTable = '''
CREATE TABLE IF NOT EXISTS records (
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

  static const String createRecordTagsTable = '''
CREATE TABLE IF NOT EXISTS record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);
''';

  static const String createTombstonesTable = '''
CREATE TABLE IF NOT EXISTS tombstones (
    entity_id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    deleted_at_epoch_ms INTEGER NOT NULL
);
''';

  static const String createSettingsTable = '''
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
''';

  static const List<String> createIndexes = [
    'CREATE INDEX IF NOT EXISTS idx_activities_category_id ON activities(category_id);',
    'CREATE INDEX IF NOT EXISTS idx_records_started ON records(started_at_epoch_ms);',
    'CREATE INDEX IF NOT EXISTS idx_records_activity ON records(activity_id);',
    'CREATE INDEX IF NOT EXISTS idx_records_updated ON records(updated_at_epoch_ms);',
    'CREATE INDEX IF NOT EXISTS idx_tombstones_deleted ON tombstones(deleted_at_epoch_ms);',
  ];

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(createCategoriesTable);
    await db.execute(createActivitiesTable);
    await db.execute(createTagsTable);
    await db.execute(createRecordsTable);
    await db.execute(createRecordTagsTable);
    await db.execute(createLapTableSql);
    await db.execute(createTombstonesTable);
    await db.execute(createSettingsTable);
    for (final indexSql in createIndexes) {
      await db.execute(indexSql);
    }
  }

  static DatabaseFactory _resolveDatabaseFactory(DatabaseFactory? factory) {
    if (factory != null) return factory;

    if (!_kIsWeb &&
        (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return databaseFactory;
  }

  /// Opens or creates the SQLite database. Supports mobile and desktop platforms.
  static Future<TempoDatabase> open({
    String? path,
    DatabaseFactory? factory,
  }) async {
    final dbFactory = _resolveDatabaseFactory(factory);
    final String dbPath =
        path ?? p.join(await dbFactory.getDatabasesPath(), databaseFileName);

    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: databaseVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await migrateV1ToV2(db);
          }
          if (oldVersion < 3) {
            await migrateV2ToV3(db);
          }
          if (oldVersion < 4) {
            await migrateV3ToV4(db);
          }
          if (oldVersion < 5) {
            await migrateV4ToV5(db);
          }
          if (oldVersion < 6) {
            await migrateV5ToV6(db);
          }
          if (oldVersion < 7) {
            await migrateV6ToV7(db);
          }
          if (oldVersion < 8) {
            await migrateV7ToV8(db);
          }
        },
      ),
    );
    return TempoDatabase(db);
  }

  /// Opens an in-memory SQLite database, ideal for tests and ephemeral sessions.
  static Future<TempoDatabase> openInMemory({DatabaseFactory? factory}) async {
    sqfliteFfiInit();
    final dbFactory = factory ?? databaseFactoryFfi;
    final db = await dbFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: databaseVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await createSchema(db);
        },
      ),
    );
    return TempoDatabase(db);
  }

  Future<void> close() async {
    await _db.close();
  }

  // ==========================================
  // Activities CRUD
  // ==========================================

  Future<void> insertActivity(Activity activity) async {
    final normalized = await _withCategoryColor(activity);
    await _db.insert(
      'activities',
      normalized.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> updateActivity(Activity activity) async {
    final normalized = await _withCategoryColor(activity);
    await _db.update(
      'activities',
      normalized.toMap(),
      where: 'id = ?',
      whereArgs: [normalized.id],
    );
  }

  /// An Activity in a Category always wears the Category's colour, so one
  /// category reads as one colour everywhere. Uncategorised Activities keep
  /// the colour chosen for them.
  Future<Activity> _withCategoryColor(Activity activity) async {
    final categoryId = activity.categoryId;
    if (categoryId == null) return activity;
    final category = await getCategoryById(categoryId);
    if (category == null) return activity;
    return activity.copyWith(colorHex: category.colorHex);
  }

  Future<Activity?> getActivityById(String id) async {
    final results = await _db.query(
      'activities',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Activity.fromMap(results.first);
  }

  Future<List<Activity>> getAllActivities({
    bool includeArchived = false,
  }) async {
    final results = await _db.query(
      'activities',
      where: includeArchived ? null : 'is_archived = 0',
      orderBy: 'sort_order ASC, name ASC',
    );
    return results.map(Activity.fromMap).toList();
  }

  Future<void> deleteActivity(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      final recordRows = await txn.query(
        'records',
        columns: ['id'],
        where: 'activity_id = ?',
        whereArgs: [id],
      );

      await txn.delete('activities', where: 'id = ?', whereArgs: [id]);

      await txn.insert(
        'tombstones',
        Tombstone(
          entityId: id,
          entityType: 'activity',
          deletedAtEpochMs: deletedAt,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final row in recordRows) {
        final recordId = row['id'] as String;
        await txn.insert(
          'tombstones',
          Tombstone(
            entityId: recordId,
            entityType: 'record',
            deletedAtEpochMs: deletedAt,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  // ==========================================
  // Categories CRUD
  // ==========================================

  Future<void> upsertCategory(Category category) async {
    await _db.transaction((txn) async {
      final before = await txn.query(
        'categories',
        columns: ['color_hex'],
        where: 'id = ?',
        whereArgs: [category.id],
        limit: 1,
      );

      // Update before inserting: INSERT OR REPLACE deletes the old row, and the
      // activities.category_id foreign key would null every assignment.
      final updated = await txn.update(
        'categories',
        category.toMap(),
        where: 'id = ?',
        whereArgs: [category.id],
      );
      if (updated == 0) {
        await txn.insert('categories', category.toMap());
        return;
      }

      final previousColor = before.isEmpty
          ? null
          : before.first['color_hex'] as String?;
      if (previousColor == null || previousColor == category.colorHex) {
        return;
      }

      // Keep the category's activities in step with its colour.
      await txn.update(
        'activities',
        {
          'color_hex': category.colorHex,
          'updated_at_epoch_ms': category.updatedAtEpochMs,
        },
        where: 'category_id = ?',
        whereArgs: [category.id],
      );
    });
  }

  Future<Category?> getCategoryById(String id) async {
    final results = await _db.query(
      'categories',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Category.fromMap(results.first);
  }

  Future<List<Category>> getCategories() async {
    final results = await _db.query(
      'categories',
      orderBy: 'sort_order ASC, name ASC',
    );
    return results.map(Category.fromMap).toList();
  }

  Future<void> deleteCategory(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.delete('categories', where: 'id = ?', whereArgs: [id]);
      await txn.insert(
        'tombstones',
        Tombstone(
          entityId: id,
          entityType: 'category',
          deletedAtEpochMs: deletedAt,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ==========================================
  // Settings
  // ==========================================

  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ==========================================
  // Tags CRUD
  // ==========================================

  Future<void> insertTag(Tag tag) async {
    await _db.insert(
      'tags',
      tag.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> updateTag(Tag tag) async {
    await _db.update('tags', tag.toMap(), where: 'id = ?', whereArgs: [tag.id]);
  }

  Future<Tag?> getTagById(String id) async {
    final results = await _db.query(
      'tags',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Tag.fromMap(results.first);
  }

  Future<Tag?> getTagByName(String name) async {
    final results = await _db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Tag.fromMap(results.first);
  }

  Future<List<Tag>> getAllTags() async {
    final results = await _db.query('tags', orderBy: 'name ASC');
    return results.map(Tag.fromMap).toList();
  }

  Future<void> deleteTag(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.delete('tags', where: 'id = ?', whereArgs: [id]);
      await txn.insert(
        'tombstones',
        Tombstone(
          entityId: id,
          entityType: 'tag',
          deletedAtEpochMs: deletedAt,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ==========================================
  // Records CRUD
  // ==========================================

  Future<void> insertRecord(Record record) async {
    await _db.transaction((txn) async {
      await txn.insert(
        'records',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      for (final tagId in record.tagIds) {
        await txn.insert('record_tags', {
          'record_id': record.id,
          'tag_id': tagId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> updateRecord(Record record) async {
    await _db.transaction((txn) async {
      await txn.update(
        'records',
        record.toMap(),
        where: 'id = ?',
        whereArgs: [record.id],
      );
      await txn.delete(
        'record_tags',
        where: 'record_id = ?',
        whereArgs: [record.id],
      );
      for (final tagId in record.tagIds) {
        await txn.insert('record_tags', {
          'record_id': record.id,
          'tag_id': tagId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<Record?> getRecordById(String id) async {
    final results = await _db.query(
      'records',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;

    final tagResults = await _db.query(
      'record_tags',
      columns: ['tag_id'],
      where: 'record_id = ?',
      whereArgs: [id],
    );
    final tagIds = tagResults.map((r) => r['tag_id'] as String).toList();
    return Record.fromMap(results.first, tagIds: tagIds);
  }

  Future<List<Record>> getRecords({
    int? startedAfter,
    int? startedBefore,
    String? activityId,
    bool trackedOnly = false,
    int? limit,
    int? offset,
    String? orderBy,
  }) async {
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (startedAfter != null) {
      whereClauses.add('started_at_epoch_ms >= ?');
      whereArgs.add(startedAfter);
    }
    if (startedBefore != null) {
      whereClauses.add('started_at_epoch_ms <= ?');
      whereArgs.add(startedBefore);
    }
    if (activityId != null) {
      whereClauses.add('activity_id = ?');
      whereArgs.add(activityId);
    }
    if (trackedOnly) {
      whereClauses.add('activity_id IS NOT NULL');
    }

    final where = whereClauses.isEmpty ? null : whereClauses.join(' AND ');
    final results = await _db.query(
      'records',
      where: where,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: orderBy ?? 'started_at_epoch_ms DESC',
      limit: limit,
      offset: offset,
    );

    if (results.isEmpty) return [];

    final recordIds = results.map((r) => r['id'] as String).toList();
    final tagMap = <String, List<String>>{};

    for (var i = 0; i < recordIds.length; i += 500) {
      final chunk = recordIds.sublist(
        i,
        (i + 500 < recordIds.length) ? i + 500 : recordIds.length,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final tagRows = await _db.query(
        'record_tags',
        where: 'record_id IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in tagRows) {
        final recordId = row['record_id'] as String;
        final tagId = row['tag_id'] as String;
        (tagMap[recordId] ??= []).add(tagId);
      }
    }

    return results
        .map((r) => Record.fromMap(r, tagIds: tagMap[r['id']] ?? const []))
        .toList();
  }

  Future<void> deleteRecord(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.delete('records', where: 'id = ?', whereArgs: [id]);
      await txn.insert(
        'tombstones',
        Tombstone(
          entityId: id,
          entityType: 'record',
          deletedAtEpochMs: deletedAt,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ==========================================
  // Lap Operations
  // ==========================================

  Future<Lap?> getLap() async {
    final results = await _db.query('lap', where: 'id = 1', limit: 1);
    if (results.isEmpty) return null;
    return Lap.fromMap(results.first);
  }

  Future<void> setLap(Lap lap) async {
    await _db.insert(
      'lap',
      lap.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ==========================================
  // Tombstones CRUD
  // ==========================================

  Future<void> insertTombstone(Tombstone tombstone) async {
    await _db.insert(
      'tombstones',
      tombstone.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Tombstone>> getTombstones({int? deletedAfterEpochMs}) async {
    final where = deletedAfterEpochMs != null
        ? 'deleted_at_epoch_ms > ?'
        : null;
    final whereArgs = deletedAfterEpochMs != null
        ? [deletedAfterEpochMs]
        : null;
    final results = await _db.query(
      'tombstones',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'deleted_at_epoch_ms ASC',
    );
    return results.map(Tombstone.fromMap).toList();
  }

  Future<int> purgeTombstonesOlderThan(int thresholdEpochMs) async {
    return await _db.delete(
      'tombstones',
      where: 'deleted_at_epoch_ms < ?',
      whereArgs: [thresholdEpochMs],
    );
  }
}
