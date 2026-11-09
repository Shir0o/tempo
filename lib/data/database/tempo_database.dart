import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';
import '../models/sync_change.dart';
import 'migrations.dart';

const bool _kIsWeb =
    bool.fromEnvironment('dart.library.js_util') ||
    bool.fromEnvironment('dart.library.js_interop');

/// The eight settings seeded at schema v10.
class SyncSettingKeys {
  static const String storeId = 'store_id';
  static const String deviceId = 'device_id';
  static const String logEpoch = 'log_epoch';
  static const String backupEnabled = 'backup_enabled';
  static const String backupDestination = 'backup_destination';
  static const String backupGenerations = 'backup_generations';
  static const String exportRedactComments = 'export_redact_comments';
  static const String replicateEnabled = 'replicate_enabled';
}

class TempoDatabase {
  final Database _db;

  TempoDatabase(this._db);

  Database get db => _db;

  static const int databaseVersion = 12;
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
    is_contact INTEGER NOT NULL DEFAULT 0,
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
    await db.execute(createChangesTableSql);
    await db.execute(createProcessedIntentsTableSql);
    await db.execute(createWatchWatermarksTableSql);
    await db.execute(createSyncPeersTableSql);
    for (final indexSql in createIndexes) {
      await db.execute(indexSql);
    }
    await seedSyncSettings(db);
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
          if (oldVersion < 9) {
            await migrateV8ToV9(db);
          }
          if (oldVersion < 10) {
            await migrateV9ToV10(db);
          }
          if (oldVersion < 11) {
            await migrateV10ToV11(db);
          }
          if (oldVersion < 12) {
            await migrateV11ToV12(db);
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
    await _db.transaction((txn) async {
      await txn.insert(
        'activities',
        normalized.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await appendChange(
        SyncChange.activityUpsert(
          normalized,
          atEpochMs: normalized.updatedAtEpochMs,
        ),
        executor: txn,
      );
    });
  }

  /// Creates and inserts an activity, looking up and inheriting the parent
  /// category's color if [colorHex] is default (`#4CAF50`) and [categoryId] is
  /// non-null.
  Future<Activity> createActivity({
    required String id,
    required String name,
    String? categoryId,
    String colorHex = '#4CAF50',
    String iconName = 'schedule',
    bool isPinned = false,
    int sortOrder = 0,
    bool isArchived = false,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    var effectiveColor = colorHex;
    if (colorHex == '#4CAF50' && categoryId != null) {
      final category = await getCategoryById(categoryId);
      if (category != null && category.colorHex.isNotEmpty) {
        effectiveColor = category.colorHex;
      }
    }

    final activity = Activity(
      id: id,
      name: name,
      categoryId: categoryId,
      colorHex: effectiveColor,
      iconName: iconName,
      isPinned: isPinned,
      sortOrder: sortOrder,
      isArchived: isArchived,
      createdAtEpochMs: createdAtEpochMs ?? now,
      updatedAtEpochMs: updatedAtEpochMs ?? now,
    );
    await insertActivity(activity);
    return activity;
  }

  Future<void> updateActivity(Activity activity) async {
    final normalized = await _withCategoryColor(activity);
    await _db.transaction((txn) async {
      await txn.update(
        'activities',
        normalized.toMap(),
        where: 'id = ?',
        whereArgs: [normalized.id],
      );
      await appendChange(
        SyncChange.activityUpsert(
          normalized,
          atEpochMs: normalized.updatedAtEpochMs,
        ),
        executor: txn,
      );
    });
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

  /// The one path every catalog delete takes: the row, its tombstone, and its
  /// removal change commit together, so the rows and the change log can never
  /// disagree. Cascaded tombstones and changes are written in the same
  /// transaction, before the entity's own removal.
  Future<void> _deleteWithTombstone(
    DatabaseExecutor txn, {
    required String table,
    required String entityId,
    required String entityType,
    required int deletedAtEpochMs,
    required SyncChange change,
    List<Tombstone> cascadedTombstones = const [],
    List<SyncChange> cascadedChanges = const [],
  }) async {
    await txn.delete(table, where: 'id = ?', whereArgs: [entityId]);
    await txn.insert(
      'tombstones',
      Tombstone(
        entityId: entityId,
        entityType: entityType,
        deletedAtEpochMs: deletedAtEpochMs,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final tombstone in cascadedTombstones) {
      await txn.insert(
        'tombstones',
        tombstone.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final cascaded in cascadedChanges) {
      await appendChange(cascaded, executor: txn);
    }
    await appendChange(change, executor: txn);
  }

  Future<void> deleteActivity(String id, {int? deletedAtEpochMs}) async {
    final deletedAt =
        deletedAtEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // The activity's Records go with it, so each one needs its own
      // `record_remove` or a replica would keep them forever.
      final recordRows = await txn.query(
        'records',
        columns: ['id'],
        where: 'activity_id = ?',
        whereArgs: [id],
      );
      final recordIds = [for (final row in recordRows) row['id'] as String];

      await _deleteWithTombstone(
        txn,
        table: 'activities',
        entityId: id,
        entityType: 'activity',
        deletedAtEpochMs: deletedAt,
        change: SyncChange.activityRemove(id, atEpochMs: deletedAt),
        cascadedTombstones: [
          for (final recordId in recordIds)
            Tombstone(
              entityId: recordId,
              entityType: 'record',
              deletedAtEpochMs: deletedAt,
            ),
        ],
        cascadedChanges: [
          for (final recordId in recordIds)
            SyncChange.recordRemove(recordId, atEpochMs: deletedAt),
        ],
      );
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
        await appendChange(
          SyncChange.categoryUpsert(
            category,
            atEpochMs: category.updatedAtEpochMs,
          ),
          executor: txn,
        );
        return;
      }

      await appendChange(
        SyncChange.categoryUpsert(
          category,
          atEpochMs: category.updatedAtEpochMs,
        ),
        executor: txn,
      );

      final previousColor = before.isEmpty
          ? null
          : before.first['color_hex'] as String?;
      if (previousColor == null || previousColor == category.colorHex) {
        return;
      }

      // Keep the category's activities in step with its colour. Each one is
      // its own `activity_upsert`, because a replica applies the whole row.
      await txn.update(
        'activities',
        {
          'color_hex': category.colorHex,
          'updated_at_epoch_ms': category.updatedAtEpochMs,
        },
        where: 'category_id = ?',
        whereArgs: [category.id],
      );
      final recolored = await txn.query(
        'activities',
        where: 'category_id = ?',
        whereArgs: [category.id],
      );
      for (final row in recolored) {
        await appendChange(
          SyncChange.activityUpsert(
            Activity.fromMap(row),
            atEpochMs: category.updatedAtEpochMs,
          ),
          executor: txn,
        );
      }
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
      await _deleteWithTombstone(
        txn,
        table: 'categories',
        entityId: id,
        entityType: 'category',
        deletedAtEpochMs: deletedAt,
        change: SyncChange.categoryRemove(id, atEpochMs: deletedAt),
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
  // Sync change feed
  // ==========================================

  /// Appends one Change to the log and returns its `seq`. Pass the mutation's
  /// own [executor] (a [Transaction]) so the row and the change commit together.
  Future<int> appendChange(
    SyncChange change, {
    DatabaseExecutor? executor,
  }) async {
    final target = executor ?? _db;
    return target.insert('changes', change.toChangeRow());
  }

  /// The Changes past [seq], oldest first, at most [limit] of them.
  Future<List<SyncChange>> changesAfter(int seq, [int limit = 500]) async {
    final rows = await _db.query(
      'changes',
      where: 'seq > ?',
      whereArgs: [seq],
      orderBy: 'seq ASC',
      limit: limit,
    );
    return rows.map(SyncChange.fromRow).toList();
  }

  /// The highest `seq` in the log, or 0 when it is empty.
  Future<int> highestChangeSeq() async {
    final rows = await _db.rawQuery('SELECT MAX(seq) AS seq FROM changes');
    return (rows.first['seq'] as int?) ?? 0;
  }

  /// Records the outcome of an intent. The primary key is
  /// `(log_epoch, intent_id)`, so recording the same intent twice keeps one row.
  Future<void> markProcessedIntent(
    ProcessedIntent entry, {
    DatabaseExecutor? executor,
  }) async {
    final target = executor ?? _db;
    await target.insert(
      'processed_intents',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ProcessedIntent?> lookupProcessedIntent(
    String logEpoch,
    String intentId,
  ) async {
    final rows = await _db.query(
      'processed_intents',
      where: 'log_epoch = ? AND intent_id = ?',
      whereArgs: [logEpoch, intentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ProcessedIntent.fromMap(rows.first);
  }

  /// The highest watch `actionSeq` applied for [deviceId], or 0.
  Future<int> getWatchWatermark(String deviceId) async {
    final rows = await _db.query(
      'watch_watermarks',
      columns: ['action_seq'],
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return rows.first['action_seq'] as int? ?? 0;
  }

  Future<void> setWatchWatermark(String deviceId, int actionSeq) async {
    await _db.insert('watch_watermarks', {
      'device_id': deviceId,
      'action_seq': actionSeq,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertPeer(SyncPeer peer) async {
    await _db.insert(
      'sync_peers',
      peer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<SyncPeer?> getPeer(String peerDeviceId) async {
    final rows = await _db.query(
      'sync_peers',
      where: 'peer_device_id = ?',
      whereArgs: [peerDeviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncPeer.fromMap(rows.first);
  }

  Future<List<SyncPeer>> getPeers() async {
    final rows = await _db.query(
      'sync_peers',
      orderBy: 'last_seen_epoch_ms DESC',
    );
    return rows.map(SyncPeer.fromMap).toList();
  }

  Future<void> deletePeer(String peerDeviceId) async {
    await _db.delete(
      'sync_peers',
      where: 'peer_device_id = ?',
      whereArgs: [peerDeviceId],
    );
  }

  /// Every settings row, as stored.
  Future<Map<String, String>> getAllSettings() async {
    final rows = await _db.query('settings');
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  /// The eight settings seeded at schema v10.
  Future<SyncSettings> getSyncSettings() async {
    final rows = await _db.query('settings');
    final values = <String, String>{
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    return SyncSettings.fromSettingsMap(values);
  }

  Future<void> setSyncSettings(
    SyncSettings settings, {
    DatabaseExecutor? executor,
  }) async {
    final target = executor ?? _db;
    for (final entry in settings.toSettingsMap().entries) {
      await target.insert('settings', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// The current `log_epoch`. A client that sees an unfamiliar value replays
  /// from `seq = 0`.
  Future<String> getLogEpoch() async =>
      await getSetting(SyncSettingKeys.logEpoch) ?? '';

  // ==========================================
  // Tags CRUD
  // ==========================================

  Future<void> insertTag(Tag tag) async {
    await _db.transaction((txn) async {
      final effective = await _withExclusiveContact(
        txn,
        tag,
        adoptContactName: true,
      );
      await txn.insert(
        'tags',
        effective.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await appendChange(
        SyncChange.tagUpsert(effective, atEpochMs: effective.updatedAtEpochMs),
        executor: txn,
      );
    });
  }

  Future<void> updateTag(Tag tag) async {
    await _db.transaction((txn) async {
      final effective = await _withExclusiveContact(
        txn,
        tag,
        adoptContactName: false,
      );
      await txn.update(
        'tags',
        effective.toMap(),
        where: 'id = ?',
        whereArgs: [effective.id],
      );
      await appendChange(
        SyncChange.tagUpsert(effective, atEpochMs: effective.updatedAtEpochMs),
        executor: txn,
      );
    });
  }

  /// Keeps one Contact Tag at most. A new tag named "Contact" adopts the flag
  /// when no other tag has it, so an import or a deep link keeps working
  /// without the user visiting Settings first. Setting the flag on [tag]
  /// clears it on any other tag, appending a change for each so replicas
  /// converge.
  Future<Tag> _withExclusiveContact(
    DatabaseExecutor txn,
    Tag tag, {
    required bool adoptContactName,
  }) async {
    var effective = tag;
    if (!effective.isContact &&
        adoptContactName &&
        looksLikeContactTagName(effective.name)) {
      final existing = await txn.query(
        'tags',
        columns: ['id'],
        where: 'is_contact = 1',
        limit: 1,
      );
      if (existing.isEmpty) effective = effective.copyWith(isContact: true);
    }
    if (!effective.isContact) return effective;

    final others = await txn.query(
      'tags',
      where: 'is_contact = 1 AND id <> ?',
      whereArgs: [effective.id],
    );
    for (final row in others) {
      final other = Tag.fromMap(row).copyWith(
        isContact: false,
        updatedAtEpochMs: effective.updatedAtEpochMs,
      );
      await txn.update(
        'tags',
        other.toMap(),
        where: 'id = ?',
        whereArgs: [other.id],
      );
      await appendChange(
        SyncChange.tagUpsert(other, atEpochMs: other.updatedAtEpochMs),
        executor: txn,
      );
    }
    return effective;
  }

  Future<Tag?> getContactTag() async {
    final results = await _db.query(
      'tags',
      where: 'is_contact = 1',
      orderBy: 'name ASC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Tag.fromMap(results.first);
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
      await _deleteWithTombstone(
        txn,
        table: 'tags',
        entityId: id,
        entityType: 'tag',
        deletedAtEpochMs: deletedAt,
        change: SyncChange.tagRemove(id, atEpochMs: deletedAt),
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

  /// The lean history the suggestion engine needs: activity id, start instant,
  /// and start zone only. No tags, no full Record hydration.
  ///
  /// Rows are read newest-first so [limit] keeps the most recent evidence, then
  /// reversed to the ascending order the engine requires.
  Future<List<SuggestionObservation>> getSuggestionHistory({
    required int startedAfter,
    required int startedBefore,
    int? limit,
  }) async {
    final rows = await _db.query(
      'records',
      columns: ['activity_id', 'started_at_epoch_ms', 'timezone_id'],
      where: 'started_at_epoch_ms >= ? AND started_at_epoch_ms <= ?',
      whereArgs: [startedAfter, startedBefore],
      orderBy: 'started_at_epoch_ms DESC, rowid DESC',
      limit: limit,
    );
    final observations = rows
        .map(
          (row) => SuggestionObservation(
            activityId: row['activity_id'] as String?,
            startedAtEpochMs: row['started_at_epoch_ms'] as int,
            timezoneId: row['timezone_id'] as String,
          ),
        )
        .toList();
    return observations.reversed.toList(growable: false);
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
