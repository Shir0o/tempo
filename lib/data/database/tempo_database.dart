import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/models.dart';

class TempoDatabase {
  final Database _db;

  TempoDatabase(this._db);

  Database get db => _db;

  static const int databaseVersion = 1;
  static const String databaseFileName = 'tempo.db';

  // --- DDL Constants matching specs/03-local-sqlite-schema-and-state-machine.md exactly ---

  static const String createActivitiesTable = '''
CREATE TABLE IF NOT EXISTS activities (
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
    activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL,
    ended_at_epoch_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    timezone_id TEXT NOT NULL,
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

  static const String createActiveTimerTable = '''
CREATE TABLE IF NOT EXISTS active_timer (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    activity_id TEXT NOT NULL REFERENCES activities(id),
    started_at_epoch_ms INTEGER NOT NULL,
    is_paused INTEGER NOT NULL DEFAULT 0,
    paused_at_epoch_ms INTEGER DEFAULT NULL,
    accumulated_pause_ms INTEGER NOT NULL DEFAULT 0,
    current_comment TEXT NOT NULL DEFAULT '',
    initial_tags_json TEXT NOT NULL DEFAULT '[]',
    last_heartbeat_epoch_ms INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1
);
''';

  static const String createTombstonesTable = '''
CREATE TABLE IF NOT EXISTS tombstones (
    entity_id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    deleted_at_epoch_ms INTEGER NOT NULL
);
''';

  static const List<String> createIndexes = [
    'CREATE INDEX IF NOT EXISTS idx_records_started ON records(started_at_epoch_ms);',
    'CREATE INDEX IF NOT EXISTS idx_records_activity ON records(activity_id);',
    'CREATE INDEX IF NOT EXISTS idx_records_updated ON records(updated_at_epoch_ms);',
    'CREATE INDEX IF NOT EXISTS idx_tombstones_deleted ON tombstones(deleted_at_epoch_ms);',
  ];

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(createActivitiesTable);
    await db.execute(createTagsTable);
    await db.execute(createRecordsTable);
    await db.execute(createRecordTagsTable);
    await db.execute(createActiveTimerTable);
    await db.execute(createTombstonesTable);
    for (final indexSql in createIndexes) {
      await db.execute(indexSql);
    }
  }

  static DatabaseFactory _resolveDatabaseFactory(DatabaseFactory? factory) {
    if (factory != null) return factory;

    if (!kIsWeb &&
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
      ),
    );
    return TempoDatabase(db);
  }

  /// Opens an in-memory SQLite database, ideal for tests and ephemeral sessions.
  static Future<TempoDatabase> openInMemory({
    DatabaseFactory? factory,
  }) async {
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
    await _db.insert(
      'activities',
      activity.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> updateActivity(Activity activity) async {
    await _db.update(
      'activities',
      activity.toMap(),
      where: 'id = ?',
      whereArgs: [activity.id],
    );
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

  Future<List<Activity>> getAllActivities({bool includeArchived = false}) async {
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

      await txn.delete(
        'activities',
        where: 'id = ?',
        whereArgs: [id],
      );

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
    await _db.update(
      'tags',
      tag.toMap(),
      where: 'id = ?',
      whereArgs: [tag.id],
    );
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
    final results = await _db.query(
      'tags',
      orderBy: 'name ASC',
    );
    return results.map(Tag.fromMap).toList();
  }

  Future<void> deleteTag(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.delete(
        'tags',
        where: 'id = ?',
        whereArgs: [id],
      );
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
        await txn.insert(
          'record_tags',
          {'record_id': record.id, 'tag_id': tagId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
        await txn.insert(
          'record_tags',
          {'record_id': record.id, 'tag_id': tagId},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
      await txn.delete(
        'records',
        where: 'id = ?',
        whereArgs: [id],
      );
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
  // Active Timer Operations
  // ==========================================

  Future<ActiveTimer?> getActiveTimer() async {
    final results = await _db.query(
      'active_timer',
      where: 'id = 1',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return ActiveTimer.fromMap(results.first);
  }

  Future<void> setActiveTimer(ActiveTimer timer) async {
    await _db.insert(
      'active_timer',
      timer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteActiveTimer() async {
    await _db.delete('active_timer', where: 'id = 1');
  }

  Future<void> updateHeartbeat(int heartbeatEpochMs) async {
    await _db.update(
      'active_timer',
      {'last_heartbeat_epoch_ms': heartbeatEpochMs},
      where: 'id = 1',
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
    final where =
        deletedAfterEpochMs != null ? 'deleted_at_epoch_ms > ?' : null;
    final whereArgs = deletedAfterEpochMs != null ? [deletedAfterEpochMs] : null;
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
