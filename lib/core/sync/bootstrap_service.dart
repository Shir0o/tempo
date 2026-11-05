import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/store_lifecycle.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';
import 'store_export.dart';

/// A bootstrap that cannot proceed, with a message the caller can show.
class BootstrapException implements Exception {
  final String message;

  const BootstrapException(this.message);

  @override
  String toString() => message;
}

/// Thrown when the target store already holds history and the caller did not
/// pass `allowOverwrite: true`. Nothing has been written when this is thrown.
class BootstrapOverwriteRefusedException extends BootstrapException {
  final int records;
  final int activities;
  final int categories;
  final int tags;
  final int changes;

  BootstrapOverwriteRefusedException({
    required this.records,
    required this.activities,
    required this.categories,
    required this.tags,
    required this.changes,
  }) : super(
         'the store is not empty and overwriting it was not confirmed '
         '(records: $records, activities: $activities, '
         'categories: $categories, tags: $tags, changes: $changes)',
       );
}

/// What an adoption wrote.
class BootstrapResult {
  /// The consuming store's own id; adoption never adopts the exporter's.
  final String storeId;

  /// The newly issued `device_id`.
  final String deviceId;

  /// The newly renewed `log_epoch`. A paired client replays from zero.
  final String logEpoch;

  final int categories;
  final int activities;
  final int tags;
  final int records;

  /// The `changes` rows backfilled by adoption.
  final int changes;

  /// Whether the target held history and was replaced (after confirmation).
  final bool overwroteExisting;

  /// The safety snapshot taken before a confirmed overwrite.
  final String? preBootstrapSnapshotPath;

  const BootstrapResult({
    required this.storeId,
    required this.deviceId,
    required this.logEpoch,
    required this.categories,
    required this.activities,
    required this.tags,
    required this.records,
    required this.changes,
    required this.overwroteExisting,
    required this.preBootstrapSnapshotPath,
  });

  @override
  String toString() =>
      'BootstrapResult(storeId: $storeId, deviceId: $deviceId, '
      'logEpoch: $logEpoch, records: $records, changes: $changes, '
      'overwroteExisting: $overwroteExisting)';
}

/// Produces a [StoreExport] on either device and adopts one on a bare device.
///
/// The export path is the transport: the caller hands the file to the OS share
/// sheet and picks the file on the other side. Adoption writes the whole
/// history in one SQLite transaction, reissues `device_id`, renews `log_epoch`,
/// forgets any replica cursor, and backfills one change row per imported entity
/// plus one `lap_set`, so the consumer's change feed is complete from the start
/// of its log.
class BootstrapService {
  /// Settings that belong to a replica's own cursor. Adoption renews the log,
  /// so a stale cursor would point into a log that no longer exists.
  static const List<String> replicaSettingKeys = [
    'applied_seq',
    'replica_of_store_id',
    'replica_log_epoch',
  ];

  final TempoDatabase database;
  final StoreLifecycle lifecycle;

  /// Where a pre-overwrite safety snapshot is written. Defaults to the store's
  /// own directory.
  final Directory? snapshotDirectory;

  final DateTime Function() _now;
  final String Function() _uuid;

  BootstrapService({
    required this.database,
    StoreLifecycle? lifecycle,
    this.snapshotDirectory,
    DateTime Function()? now,
    String Function()? uuid,
  }) : lifecycle = lifecycle ?? StoreLifecycle.instance,
       _now = now ?? DateTime.now,
       _uuid = uuid ?? (() => const Uuid().v4());

  /// Reads the store into a versioned export. Archived Activities are included,
  /// because a Record may still point at one.
  Future<StoreExport> export() async {
    final settings = await database.getSyncSettings();
    return StoreExport.create(
      createdAtEpochMs: _now().toUtc().millisecondsSinceEpoch,
      sourceStoreId: settings.storeId,
      categories: await database.getCategories(),
      activities: await database.getAllActivities(includeArchived: true),
      tags: await database.getAllTags(),
      records: await database.getRecords(
        orderBy: 'started_at_epoch_ms ASC, ended_at_epoch_ms ASC, id ASC',
      ),
      lap: await database.getLap(),
    );
  }

  /// Writes [export] to [path] as UTF-8 JSON and returns what was written.
  Future<StoreExport> exportToFile(String path) async {
    final export = await this.export();
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(export.encodeBytes(), flush: true);
    return export;
  }

  /// Validates [path] and adopts it into this store.
  Future<BootstrapResult> adoptFromFile(
    String path, {
    bool allowOverwrite = false,
  }) async {
    final bytes = await File(path).readAsBytes();
    return adopt(
      StoreExport.decodeBytes(bytes),
      allowOverwrite: allowOverwrite,
    );
  }

  /// Validates [export] and adopts it into this store.
  ///
  /// A non-empty target is refused with [BootstrapOverwriteRefusedException]
  /// unless [allowOverwrite] is true, in which case the current store is
  /// snapshotted first and then replaced.
  Future<BootstrapResult> adopt(
    StoreExport export, {
    bool allowOverwrite = false,
  }) async {
    export.validate();
    _validateCoverage(export);

    await lifecycle.assertUnlocked();

    final existing = await _occupancy();
    final nonEmpty = existing.isNonEmpty;
    if (nonEmpty && !allowOverwrite) {
      throw BootstrapOverwriteRefusedException(
        records: existing.records,
        activities: existing.activities,
        categories: existing.categories,
        tags: existing.tags,
        changes: existing.changes,
      );
    }

    final snapshotPath = nonEmpty ? await _snapshotStore() : null;

    final current = await database.getSyncSettings();
    final adopted = SyncSettings(
      storeId: current.storeId,
      deviceId: _uuid(),
      logEpoch: _uuid(),
      backupEnabled: current.backupEnabled,
      backupDestination: current.backupDestination,
      backupGenerations: current.backupGenerations,
      exportRedactComments: current.exportRedactComments,
      replicateEnabled: current.replicateEnabled,
    );
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    late int changeCount;

    await database.db.transaction((txn) async {
      if (nonEmpty) {
        // Replace the whole history, not just the rows the export happens to
        // contain, so the target cannot keep a Record the exporter does not.
        await txn.delete('record_tags');
        await txn.delete('records');
        await txn.delete('activities');
        await txn.delete('categories');
        await txn.delete('tags');
        await txn.delete('lap');
        await txn.delete('changes');
        await txn.delete('tombstones');
      }

      for (final category in export.categories) {
        await txn.insert('categories', category.toMap());
      }
      for (final activity in export.activities) {
        await txn.insert('activities', activity.toMap());
      }
      for (final tag in export.tags) {
        await txn.insert('tags', tag.toMap());
      }
      for (final record in export.records) {
        await txn.insert('records', record.toMap());
        for (final tagId in record.tagIds) {
          await txn.insert('record_tags', {
            'record_id': record.id,
            'tag_id': tagId,
          });
        }
      }
      // An adopted store is a store that has just been through a restore-like
      // swap: it always has an open Lap.
      await txn.insert(
        'lap',
        export.lap!.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await database.setSyncSettings(adopted, executor: txn);
      await txn.delete(
        'settings',
        where: 'key IN (?, ?, ?)',
        whereArgs: replicaSettingKeys,
      );

      var changes = 0;
      for (final category in export.categories) {
        await database.appendChange(
          SyncChange.categoryUpsert(
            category,
            atEpochMs: category.updatedAtEpochMs,
          ),
          executor: txn,
        );
        changes++;
      }
      for (final activity in export.activities) {
        await database.appendChange(
          SyncChange.activityUpsert(
            activity,
            atEpochMs: activity.updatedAtEpochMs,
          ),
          executor: txn,
        );
        changes++;
      }
      for (final tag in export.tags) {
        await database.appendChange(
          SyncChange.tagUpsert(tag, atEpochMs: tag.updatedAtEpochMs),
          executor: txn,
        );
        changes++;
      }
      for (final record in export.records) {
        await database.appendChange(
          SyncChange.recordUpsert(record, atEpochMs: record.updatedAtEpochMs),
          executor: txn,
        );
        changes++;
      }
      await database.appendChange(
        SyncChange.lapSet(export.lap!, atEpochMs: nowMs),
        executor: txn,
      );
      changes++;
      changeCount = changes;
    });

    return BootstrapResult(
      storeId: adopted.storeId,
      deviceId: adopted.deviceId,
      logEpoch: adopted.logEpoch,
      categories: export.categories.length,
      activities: export.activities.length,
      tags: export.tags.length,
      records: export.records.length,
      changes: changeCount,
      overwroteExisting: nonEmpty,
      preBootstrapSnapshotPath: snapshotPath,
    );
  }

  /// Every moment belongs to exactly one Record or the open Lap: adjacent
  /// Records must abut exactly, and the last one must end where the Lap starts.
  void _validateCoverage(StoreExport export) {
    final lap = export.lap;
    if (lap == null) {
      throw const BootstrapException('the export has no open Lap');
    }

    int? previousEnd;
    for (final record in export.records) {
      final start = record.startedAtEpochMs;
      final end = record.endedAtEpochMs;
      if (end < start) {
        throw BootstrapException('Record ${record.id} ends before it starts');
      }
      final previous = previousEnd;
      if (previous != null) {
        if (start < previous) {
          throw BootstrapException(
            'Records overlap: one ends at $previous, the next starts at $start',
          );
        }
        if (start > previous) {
          throw BootstrapException(
            'Coverage gap: no Record between $previous and $start',
          );
        }
      }
      previousEnd = end;
    }

    final lastEnd = previousEnd;
    if (lastEnd != null && lastEnd != lap.startedAtEpochMs) {
      throw BootstrapException(
        'The last Record ends at $lastEnd but the Lap starts at '
        '${lap.startedAtEpochMs}',
      );
    }
  }

  Future<_Occupancy> _occupancy() async {
    final rows = await database.db.rawQuery(
      'SELECT '
      '(SELECT COUNT(*) FROM records) AS records, '
      '(SELECT COUNT(*) FROM activities) AS activities, '
      '(SELECT COUNT(*) FROM categories) AS categories, '
      '(SELECT COUNT(*) FROM tags) AS tags, '
      '(SELECT COUNT(*) FROM changes) AS changes',
    );
    final row = rows.first;
    return _Occupancy(
      records: row['records'] as int? ?? 0,
      activities: row['activities'] as int? ?? 0,
      categories: row['categories'] as int? ?? 0,
      tags: row['tags'] as int? ?? 0,
      changes: row['changes'] as int? ?? 0,
    );
  }

  /// Takes a safety copy of the current store before a confirmed overwrite.
  Future<String> _snapshotStore() async {
    final directory = snapshotDirectory ?? _defaultSnapshotDirectory();
    await directory.create(recursive: true);
    final target = p.join(
      directory.path,
      'tempo.pre-bootstrap-${_now().toUtc().millisecondsSinceEpoch}-'
      '${_uuid()}.db',
    );

    final sourcePath = database.db.path;
    if (sourcePath == inMemoryDatabasePath ||
        sourcePath.startsWith('file::memory:')) {
      await database.db.execute(
        "VACUUM INTO '${target.replaceAll("'", "''")}'",
      );
    } else {
      await lifecycle.acquire(purpose: StoreLifecycle.snapshotFallbackPurpose);
      try {
        await database.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        await File(sourcePath).copy(target);
      } finally {
        await lifecycle.release();
      }
    }

    final snapshot = File(target);
    if (!await snapshot.exists() || await snapshot.length() == 0) {
      throw BootstrapException('could not snapshot the store before overwrite');
    }
    return target;
  }

  Directory _defaultSnapshotDirectory() {
    final sourcePath = database.db.path;
    if (sourcePath == inMemoryDatabasePath ||
        sourcePath.startsWith('file::memory:')) {
      return Directory(p.join(Directory.systemTemp.path, 'tempo-bootstrap'));
    }
    return Directory(p.dirname(sourcePath));
  }
}

class _Occupancy {
  final int records;
  final int activities;
  final int categories;
  final int tags;
  final int changes;

  const _Occupancy({
    required this.records,
    required this.activities,
    required this.categories,
    required this.tags,
    required this.changes,
  });

  bool get isNonEmpty =>
      records > 0 ||
      activities > 0 ||
      categories > 0 ||
      tags > 0 ||
      changes > 0;
}
