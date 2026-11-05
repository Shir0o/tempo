import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';

/// A batch that could not be applied, with a message the Mac can show.
class ReplicaApplyException implements Exception {
  /// True when the phone wrote a kind this build does not know: the Mac must
  /// not advance its cursor, or the unknown change would be skipped forever.
  final bool isUnknownKind;
  final String message;

  const ReplicaApplyException(this.message, {this.isUnknownKind = false});

  @override
  String toString() => message;
}

/// Applies the phone's changes to the Mac's replica.
///
/// Changes arrive in `seq` order and are applied in that order, grouped so
/// foreign keys always resolve: categories, activities, tags, records, then the
/// Lap. Every row is update-then-insert keyed by its text id, never
/// `INSERT OR REPLACE`, because a replace deletes the old row, nulls
/// `activities.category_id`, cascades `record_tags`, and reassigns the rowid.
class ReplicaApplier {
  /// The cursor. A Mac with no cursor replays from zero.
  static const String appliedSeqKey = 'applied_seq';

  /// The phone store this replica belongs to.
  static const String replicaOfStoreIdKey = 'replica_of_store_id';

  /// The phone's log epoch this replica has replayed.
  static const String replicaLogEpochKey = 'replica_log_epoch';

  final TempoDatabase database;

  ReplicaApplier(this.database);

  Future<int> appliedSeq() async =>
      int.tryParse(await database.getSetting(appliedSeqKey) ?? '') ?? 0;

  /// Applies one page of raw `changes` rows and advances the cursor in the same
  /// transaction. Nothing is written when any row cannot be read.
  Future<int> apply(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return await appliedSeq();

    final changes = <SyncChange>[];
    for (final row in rows) {
      changes.add(_parse(row));
    }

    // `seq` decides convergence; the entity order only exists so a category is
    // in place before the activity that points at it in the same page, and a
    // removal never undercuts a row the page has just written.
    final ordered = [...changes]
      ..sort((a, b) {
        final byEntity = _rank(a.kind).compareTo(_rank(b.kind));
        if (byEntity != 0) return byEntity;
        return (a.seq ?? 0).compareTo(b.seq ?? 0);
      });

    var highestSeq = await appliedSeq();
    for (final change in changes) {
      final seq = change.seq ?? highestSeq;
      if (seq > highestSeq) highestSeq = seq;
    }

    await database.db.transaction((txn) async {
      for (final change in ordered) {
        await _applyChange(txn, change);
      }
      await txn.insert('settings', {
        'key': appliedSeqKey,
        'value': '$highestSeq',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return highestSeq;
  }

  /// Clears the replica tables and replays from zero. Used when the phone's
  /// `store_id` or `log_epoch` changed under this replica.
  Future<void> reset() async {
    await database.db.transaction((txn) async {
      await txn.delete('record_tags');
      await txn.delete('records');
      await txn.delete('activities');
      await txn.delete('categories');
      await txn.delete('tags');
      await txn.delete('lap');
      await txn.insert('settings', {
        'key': appliedSeqKey,
        'value': '0',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  SyncChange _parse(Map<String, dynamic> row) {
    try {
      return SyncChange.fromRow(row);
    } on FormatException catch (e) {
      throw ReplicaApplyException(
        'this Mac is behind the phone: $e',
        isUnknownKind: true,
      );
    }
  }

  /// Upserts come first, grouped by what they depend on; removals come last.
  ///
  /// A page is in `seq` order, but its first row may point at a row later in
  /// the same page, so dependencies must be applied first. The reverse hazard
  /// matters too: an activity removal cascades to its Records, so if it ran
  /// before a Record the phone wrote earlier in the page, the Record would be
  /// deleted and then re-inserted against a missing Activity. Removals last, in
  /// `seq` order, avoid both.
  static int _rank(SyncChangeKind kind) => switch (kind) {
    SyncChangeKind.categoryUpsert => 0,
    SyncChangeKind.activityUpsert => 1,
    SyncChangeKind.tagUpsert => 2,
    SyncChangeKind.recordUpsert => 3,
    SyncChangeKind.lapSet => 4,
    SyncChangeKind.categoryRemove ||
    SyncChangeKind.activityRemove ||
    SyncChangeKind.tagRemove ||
    SyncChangeKind.recordRemove => 5,
  };

  Future<void> _applyChange(Transaction txn, SyncChange change) async {
    switch (change.kind) {
      case SyncChangeKind.categoryUpsert:
        final category = change.category;
        if (category == null) return;
        final before = await txn.query(
          'categories',
          columns: ['color_hex'],
          where: 'id = ?',
          whereArgs: [category.id],
          limit: 1,
        );
        await _upsert(txn, 'categories', category.id, category.toMap());
        final previousColor = before.isEmpty
            ? null
            : before.first['color_hex'] as String?;
        if (previousColor != null && previousColor != category.colorHex) {
          // The phone keeps a category's activities in step with its colour
          // without writing a change for each; the replica mirrors that.
          await txn.update(
            'activities',
            {
              'color_hex': category.colorHex,
              'updated_at_epoch_ms': category.updatedAtEpochMs,
            },
            where: 'category_id = ?',
            whereArgs: [category.id],
          );
        }
      case SyncChangeKind.categoryRemove:
        await txn.delete(
          'categories',
          where: 'id = ?',
          whereArgs: [change.entityId],
        );
      case SyncChangeKind.activityUpsert:
        final activity = change.activity;
        if (activity == null) return;
        await _upsert(txn, 'activities', activity.id, activity.toMap());
      case SyncChangeKind.activityRemove:
        await txn.delete(
          'activities',
          where: 'id = ?',
          whereArgs: [change.entityId],
        );
      case SyncChangeKind.tagUpsert:
        final tag = change.tag;
        if (tag == null) return;
        await _upsert(txn, 'tags', tag.id, tag.toMap());
      case SyncChangeKind.tagRemove:
        await txn.delete('tags', where: 'id = ?', whereArgs: [change.entityId]);
      case SyncChangeKind.recordUpsert:
        final record = change.record;
        if (record == null) return;
        await _upsert(txn, 'records', record.id, record.toMap());
        // Tags belong to the Record, so they are rewritten with it.
        await txn.delete(
          'record_tags',
          where: 'record_id = ?',
          whereArgs: [record.id],
        );
        for (final tagId in record.tagIds) {
          await txn.insert('record_tags', {
            'record_id': record.id,
            'tag_id': tagId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      case SyncChangeKind.recordRemove:
        await txn.delete(
          'records',
          where: 'id = ?',
          whereArgs: [change.entityId],
        );
      case SyncChangeKind.lapSet:
        final lap = change.lap;
        if (lap == null) return;
        await _upsert(txn, 'lap', lap.id, lap.toMap());
    }
  }

  Future<void> _upsert(
    DatabaseExecutor txn,
    String table,
    Object id,
    Map<String, dynamic> values,
  ) async {
    final updated = await txn.update(
      table,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await txn.insert(table, values);
    }
  }
}
