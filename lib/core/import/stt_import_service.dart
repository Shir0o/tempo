import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../../data/models/sync_change.dart';
import '../export/csv_export_engine.dart';
import '../state/people_index.dart';
import '../time/timezone_id.dart';
import 'stt_format_parser.dart';

/// Scope for STT data import.
enum SttImportScope { catalogOnly, fullHistory }

/// Result summary of an import execution.
class SttImportResult {
  final int categoriesImported;
  final int activitiesImported;
  final int recordsImported;
  final int syntheticRecordsCreated;
  final int skippedDueToCollision;

  const SttImportResult({
    required this.categoriesImported,
    required this.activitiesImported,
    required this.recordsImported,
    required this.syntheticRecordsCreated,
    required this.skippedDueToCollision,
  });

  @override
  String toString() =>
      'SttImportResult(categories: $categoriesImported, activities: $activitiesImported, records: $recordsImported, synthetic: $syntheticRecordsCreated, skipped: $skippedDueToCollision)';
}

/// Service coordinating ingestion of Simple Time Tracker backups and CSVs.
class SttImportService {
  final TempoDatabase database;
  final CsvExportEngine? csvExportEngine;
  final int Function() nowUtcMs;
  final String Function() generateId;
  final String Function() getTimezoneId;

  SttImportService({
    required this.database,
    this.csvExportEngine,
    int Function()? nowUtcMs,
    String Function()? generateId,
    String Function()? getTimezoneId,
  }) : nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       generateId = generateId ?? (() => const Uuid().v4()),
       getTimezoneId = getTimezoneId ?? localTimezoneId;

  /// Executes import of file content in the requested scope.
  Future<SttImportResult> import({
    required String content,
    required SttImportScope scope,
  }) async {
    final activeTz = getTimezoneId();
    final now = nowUtcMs();

    // Parse envelope
    final envelope = SttFormatParser.parse(
      content: content,
      wallClockToEpochMs: (wall) => epochMsFromWallClock(
        wall,
        activeTz,
        referenceEpochMs: wall.millisecondsSinceEpoch,
      ),
      nowEpochMs: now,
    );

    // Upsert any tags present in the raw intervals (e.g. from STT CSV "record tags")
    final uniqueTagNames = <String>{};
    for (final interval in envelope.rawIntervals) {
      for (final t in interval.tagNames) {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty) {
          uniqueTagNames.add(trimmed);
        }
      }
    }

    var recordsImported = 0;
    var syntheticCount = 0;
    var skippedCollisions = 0;
    var importedHistory = false;

    // One transaction for the whole import, so a Category, Activity, Tag or
    // Record and its change row commit together.
    await database.db.transaction((txn) async {
      // 1. Non-destructive merge-update of Categories and Activities
      final categoryMapping = await _upsertCategories(
        envelope.categories,
        now,
        txn,
      );
      final activityMapping = await _upsertActivities(
        envelope.activities,
        categoryMapping,
        now,
        txn,
      );
      final tagMapping = await _upsertTags(uniqueTagNames.toList(), now, txn);
      var contactTagId = tagMapping.contactTagId;
      if (scope == SttImportScope.fullHistory &&
          contactTagId == null &&
          envelope.rawIntervals.any((i) => peopleIn(i.comment).isNotEmpty)) {
        contactTagId = await _ensureContactTag(txn, now);
      }

      if (scope == SttImportScope.fullHistory &&
          envelope.rawIntervals.isNotEmpty) {
        importedHistory = true;
        final reconciliation = await _reconcileAndInsertHistory(
          intervals: envelope.rawIntervals,
          activityMapping: activityMapping,
          tagMapping: tagMapping.byName,
          contactTagId: contactTagId,
          activeTz: activeTz,
          now: now,
          txn: txn,
        );
        recordsImported = reconciliation.recordsImported;
        syntheticCount = reconciliation.syntheticRecordsCreated;
        skippedCollisions = reconciliation.skippedDueToCollision;
      }
    });

    if (importedHistory && csvExportEngine != null) {
      csvExportEngine!.scheduleExport();
    }

    return SttImportResult(
      categoriesImported: envelope.categories.length,
      activitiesImported: envelope.activities.length,
      recordsImported: recordsImported,
      syntheticRecordsCreated: syntheticCount,
      skippedDueToCollision: skippedCollisions,
    );
  }

  /// Upserts categories non-destructively: case-insensitive name match against existing.
  /// Returns a map of imported categoryId -> effective categoryId in database.
  Future<Map<String, String>> _upsertCategories(
    List<Category> imported,
    int nowEpochMs,
    Transaction txn,
  ) async {
    final existing = (await txn.query('categories')).map(Category.fromMap);
    final existingByName = <String, Category>{
      for (final cat in existing) cat.name.trim().toLowerCase(): cat,
    };

    final idMapping = <String, String>{};

    for (final imp in imported) {
      final key = imp.name.trim().toLowerCase();
      final match = existingByName[key];
      if (match != null) {
        // Category already exists; preserve existing ID
        idMapping[imp.id] = match.id;
      } else {
        final newCat = imp.copyWith(
          id: generateId(),
          createdAtEpochMs: nowEpochMs,
          updatedAtEpochMs: nowEpochMs,
        );
        await txn.insert('categories', newCat.toMap());
        await database.appendChange(
          SyncChange.categoryUpsert(newCat, atEpochMs: nowEpochMs),
          executor: txn,
        );
        existingByName[key] = newCat;
        idMapping[imp.id] = newCat.id;
      }
    }

    return idMapping;
  }

  /// Upserts activities non-destructively: case-insensitive name match.
  /// Returns a map of activity name (lowercase) -> effective activityId in database.
  Future<Map<String, String>> _upsertActivities(
    List<Activity> imported,
    Map<String, String> categoryMapping,
    int nowEpochMs,
    Transaction txn,
  ) async {
    final existing = (await txn.query('activities'))
        .map(Activity.fromMap)
        .toList();
    final existingByName = <String, Activity>{
      for (final act in existing) act.name.trim().toLowerCase(): act,
    };

    final nameToIdMapping = <String, String>{
      for (final act in existing) act.name.trim().toLowerCase(): act.id,
    };

    final categoryColors = <String, String>{
      for (final row in await txn.query(
        'categories',
        columns: ['id', 'color_hex'],
      ))
        row['id'] as String: row['color_hex'] as String? ?? '',
    };

    for (final imp in imported) {
      final key = imp.name.trim().toLowerCase();
      final match = existingByName[key];
      final targetCatId = imp.categoryId != null
          ? categoryMapping[imp.categoryId]
          : null;
      final targetCatColor = targetCatId == null
          ? null
          : categoryColors[targetCatId];

      if (match != null) {
        // If existing activity has no category, but imported one has, link it non-destructively
        if (match.categoryId == null && targetCatId != null) {
          final updated = match.copyWith(
            categoryId: targetCatId,
            colorHex: targetCatColor,
            updatedAtEpochMs: nowEpochMs,
          );
          await txn.update(
            'activities',
            updated.toMap(),
            where: 'id = ?',
            whereArgs: [updated.id],
          );
          await database.appendChange(
            SyncChange.activityUpsert(updated, atEpochMs: nowEpochMs),
            executor: txn,
          );
          existingByName[key] = updated;
        }
        nameToIdMapping[key] = match.id;
      } else {
        final newAct = imp.copyWith(
          id: generateId(),
          categoryId: targetCatId,
          colorHex: targetCatColor,
          createdAtEpochMs: nowEpochMs,
          updatedAtEpochMs: nowEpochMs,
        );
        await txn.insert('activities', newAct.toMap());
        await database.appendChange(
          SyncChange.activityUpsert(newAct, atEpochMs: nowEpochMs),
          executor: txn,
        );
        existingByName[key] = newAct;
        nameToIdMapping[key] = newAct.id;
      }
    }

    return nameToIdMapping;
  }

  /// Upserts tags non-destructively: exact name match against existing.
  /// Returns the effective tag id for each name, plus the Contact Tag's id.
  ///
  /// A tag named "Contact" adopts the Contact flag when nothing else has it,
  /// so importing a Simple Time Tracker file keeps relational Records marked
  /// without the user visiting Settings first.
  Future<({Map<String, String> byName, String? contactTagId})> _upsertTags(
    List<String> tagNames,
    int nowEpochMs,
    Transaction txn,
  ) async {
    final rows = await txn.query('tags');
    final existingByName = <String, Tag>{
      for (final row in rows) (row['name'] as String): Tag.fromMap(row),
    };
    var contactTagId = existingByName.values
        .where((tag) => tag.isContact)
        .map((tag) => tag.id)
        .firstOrNull;
    final tagMapping = <String, String>{};
    for (final tag in tagNames) {
      final existing = existingByName[tag];
      if (existing != null) {
        if (contactTagId == null && looksLikeContactTagName(tag)) {
          final adopted = existing.copyWith(
            isContact: true,
            updatedAtEpochMs: nowEpochMs,
          );
          await txn.update(
            'tags',
            adopted.toMap(),
            where: 'id = ?',
            whereArgs: [adopted.id],
          );
          await database.appendChange(
            SyncChange.tagUpsert(adopted, atEpochMs: nowEpochMs),
            executor: txn,
          );
          existingByName[tag] = adopted;
          contactTagId = adopted.id;
        }
        tagMapping[tag] = existing.id;
      } else {
        final adoptContact =
            contactTagId == null && looksLikeContactTagName(tag);
        final newId = generateId();
        final newTag = Tag(
          id: newId,
          name: tag,
          colorHex: '#9E9E9E',
          isContact: adoptContact,
          createdAtEpochMs: nowEpochMs,
          updatedAtEpochMs: nowEpochMs,
        );
        await txn.insert('tags', newTag.toMap());
        await database.appendChange(
          SyncChange.tagUpsert(newTag, atEpochMs: nowEpochMs),
          executor: txn,
        );
        existingByName[tag] = newTag;
        tagMapping[tag] = newId;
        if (adoptContact) contactTagId = newId;
      }
    }
    return (byName: tagMapping, contactTagId: contactTagId);
  }

  /// Returns the Contact Tag's id, creating or adopting "Contact" when the
  /// import names People but the file carries no Contact tag.
  Future<String> _ensureContactTag(Transaction txn, int nowEpochMs) async {
    final existing = (await txn.query('tags')).map(Tag.fromMap).toList();
    final marked = existing.where((tag) => tag.isContact).firstOrNull;
    if (marked != null) return marked.id;

    final named = existing
        .where((tag) => looksLikeContactTagName(tag.name))
        .firstOrNull;
    final contact = named != null
        ? named.copyWith(isContact: true, updatedAtEpochMs: nowEpochMs)
        : Tag(
            id: generateId(),
            name: 'Contact',
            isContact: true,
            createdAtEpochMs: nowEpochMs,
            updatedAtEpochMs: nowEpochMs,
          );
    if (named != null) {
      await txn.update(
        'tags',
        contact.toMap(),
        where: 'id = ?',
        whereArgs: [contact.id],
      );
    } else {
      await txn.insert('tags', contact.toMap());
    }
    await database.appendChange(
      SyncChange.tagUpsert(contact, atEpochMs: nowEpochMs),
      executor: txn,
    );
    return contact.id;
  }

  /// Continuous coverage reconciliation and batch insertion.
  Future<_ReconciliationSummary> _reconcileAndInsertHistory({
    required List<SttRawInterval> intervals,
    required Map<String, String> activityMapping,
    required Map<String, String> tagMapping,
    required String? contactTagId,
    required String activeTz,
    required int now,
    required Transaction txn,
  }) async {
    // 1. Sort intervals chronologically
    final sorted = List<SttRawInterval>.from(intervals)
      ..sort((a, b) => a.startedAtEpochMs.compareTo(b.startedAtEpochMs));

    if (sorted.isEmpty) {
      return const _ReconciliationSummary(0, 0, 0);
    }

    // 2. Clamp range: earliest midnight to latest midnight / pre-lap
    final lapRows = await txn.query('lap', where: 'id = 1', limit: 1);
    final lap = lapRows.isEmpty ? null : Lap.fromMap(lapRows.first);
    final lapStart = lap?.startedAtEpochMs ?? now;

    // Earliest start
    final earliestStart = sorted.first.startedAtEpochMs;
    // Earliest local midnight: start of the day for earliest record
    final earliestMidnight = _startOfLocalDayUtcMs(activeTz, earliestStart);

    // Latest boundary: Clamp before current Lap, unless imported records extend
    // past lapStart up towards `now`. If imported intervals reach beyond lapStart,
    // latestCeiling extends up to `now` (clamped to the end of imported history or `now`),
    // and the open Lap is advanced afterwards to maintain continuous coverage.
    final latestImportEnd = sorted.last.endedAtEpochMs;
    var latestCeiling = lapStart;
    if (latestImportEnd > lapStart) {
      latestCeiling = math.min(now, latestImportEnd);
    }
    if (latestCeiling > now) latestCeiling = now;

    // 3. Resolve historical intervals, split at local midnight (00:00)
    final candidateRecords = <Record>[];
    for (final raw in sorted) {
      // If interval starts after or at latestCeiling, drop it
      if (raw.startedAtEpochMs >= latestCeiling) continue;

      var startMs = math.max(raw.startedAtEpochMs, earliestMidnight);
      var endMs = math.min(raw.endedAtEpochMs, latestCeiling);
      if (endMs <= startMs) continue;

      final actKey = raw.activityName.trim().toLowerCase();
      final actId = activityMapping[actKey];
      final recordTagIds = raw.tagNames
          .map((t) => tagMapping[t.trim()])
          .whereType<String>()
          .toList();
      if (contactTagId != null &&
          !recordTagIds.contains(contactTagId) &&
          peopleIn(raw.comment).isNotEmpty) {
        recordTagIds.add(contactTagId);
      }

      // Split multi-day spans across local midnight
      var cursor = startMs;
      while (cursor < endMs) {
        final boundary = nextLocalMidnightUtcMs(activeTz, cursor);
        final segmentEnd = math.min(endMs, boundary);
        final isMidnightSplit = segmentEnd == boundary && segmentEnd < endMs;

        candidateRecords.add(
          Record(
            id: generateId(),
            activityId: actId,
            startedAtEpochMs: cursor,
            endedAtEpochMs: segmentEnd,
            comment: cursor == startMs ? raw.comment : '',
            timezoneId: activeTz,
            endTimezoneId: activeTz,
            isMidnightSplit: isMidnightSplit,
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
            tagIds: recordTagIds,
          ),
        );

        cursor = segmentEnd;
      }
    }

    if (candidateRecords.isEmpty) {
      return const _ReconciliationSummary(0, 0, 0);
    }

    // 4. Query every existing Tempo Record that overlaps
    // [earliestMidnight, latestCeiling). A Record that starts before the window
    // still occupies time inside it, so filtering on the start alone would let
    // an imported interval land on top of it.
    // Existing tracked user records (activityId != null) take absolute precedence.
    // Pre-existing synthetic untracked gaps (activityId == null) that collide with imported
    // historical activities are removed and replaced so imported records are not blocked.
    final allExistingInRange = (await txn.query(
      'records',
      where: 'started_at_epoch_ms < ? AND ended_at_epoch_ms > ?',
      whereArgs: [latestCeiling, earliestMidnight],
      orderBy: 'started_at_epoch_ms ASC',
    )).map(Record.fromMap).toList();

    final existingTrackedRecords = allExistingInRange
        .where((r) => r.activityId != null)
        .toList();

    // Filter candidate records that collide with existing tracked records
    final nonColliding = <Record>[];
    var skippedCollisions = 0;

    for (final cand in candidateRecords) {
      final collides = existingTrackedRecords.any((exist) {
        return cand.startedAtEpochMs < exist.endedAtEpochMs &&
            cand.endedAtEpochMs > exist.startedAtEpochMs;
      });
      if (collides) {
        skippedCollisions++;
      } else {
        nonColliding.add(cand);
      }
    }

    // Remove pre-existing synthetic untracked records in the imported range that collide with nonColliding
    for (final cand in nonColliding) {
      final collidingUntracked = allExistingInRange.where((exist) {
        return exist.activityId == null &&
            cand.startedAtEpochMs < exist.endedAtEpochMs &&
            cand.endedAtEpochMs > exist.startedAtEpochMs;
      }).toList();
      for (final untracked in collidingUntracked) {
        await txn.delete('records', where: 'id = ?', whereArgs: [untracked.id]);
        await txn.insert(
          'tombstones',
          Tombstone(
            entityId: untracked.id,
            entityType: 'record',
            deletedAtEpochMs: now,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await database.appendChange(
          SyncChange.recordRemove(untracked.id, atEpochMs: now),
          executor: txn,
        );
        allExistingInRange.remove(untracked);
      }
    }

    // 5. Combine nonColliding with the Records that already cover the window to
    // synthesize gaps. Surviving Untracked Records are part of that coverage:
    // leaving them out would write a second Untracked Record over the same span
    // on every re-import.
    final survivingUntracked = allExistingInRange
        .where((record) => record.activityId == null)
        .toList();
    final allEvents = <_IntervalSpan>[
      for (final r in existingTrackedRecords)
        _IntervalSpan(
          r.startedAtEpochMs,
          r.endedAtEpochMs,
          isExisting: true,
          record: r,
        ),
      for (final r in survivingUntracked)
        _IntervalSpan(
          r.startedAtEpochMs,
          r.endedAtEpochMs,
          isExisting: true,
          record: r,
        ),
      for (final r in nonColliding)
        _IntervalSpan(
          r.startedAtEpochMs,
          r.endedAtEpochMs,
          isExisting: false,
          record: r,
        ),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // Deduplicate/chain spans and synthesize Untracked Records (activity_id: null)
    final recordsToInsert = <Record>[];
    var syntheticCount = 0;
    var cursorEpochMs = earliestMidnight;

    for (final span in allEvents) {
      if (span.start > cursorEpochMs) {
        // Gap detected! Synthesize untracked records, splitting across midnight if needed
        var gapCursor = cursorEpochMs;
        final gapEnd = math.min(span.start, latestCeiling);

        while (gapCursor < gapEnd) {
          final boundary = nextLocalMidnightUtcMs(activeTz, gapCursor);
          final segEnd = math.min(gapEnd, boundary);

          recordsToInsert.add(
            Record(
              id: generateId(),
              activityId: null,
              startedAtEpochMs: gapCursor,
              endedAtEpochMs: segEnd,
              timezoneId: activeTz,
              endTimezoneId: activeTz,
              isMidnightSplit: segEnd == boundary && segEnd < gapEnd,
              createdAtEpochMs: now,
              updatedAtEpochMs: now,
            ),
          );
          syntheticCount++;
          gapCursor = segEnd;
        }
        cursorEpochMs = gapEnd;
      }

      if (!span.isExisting) {
        recordsToInsert.add(span.record!);
      }

      if (span.end > cursorEpochMs) {
        cursorEpochMs = span.end;
      }
    }

    // Final gap between last record and latestCeiling (up to open Lap)
    if (cursorEpochMs < latestCeiling) {
      var gapCursor = cursorEpochMs;
      while (gapCursor < latestCeiling) {
        final boundary = nextLocalMidnightUtcMs(activeTz, gapCursor);
        final segEnd = math.min(latestCeiling, boundary);

        recordsToInsert.add(
          Record(
            id: generateId(),
            activityId: null,
            startedAtEpochMs: gapCursor,
            endedAtEpochMs: segEnd,
            timezoneId: activeTz,
            endTimezoneId: activeTz,
            isMidnightSplit: segEnd == boundary && segEnd < latestCeiling,
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
          ),
        );
        syntheticCount++;
        gapCursor = segEnd;
      }
    }

    // 6. Insert the reconciled Records, each with its change row, in the
    // import's own transaction.
    for (final rec in recordsToInsert) {
      await txn.insert(
        'records',
        rec.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (rec.tagIds.isNotEmpty) {
        for (final tagId in rec.tagIds) {
          await txn.insert('record_tags', {
            'record_id': rec.id,
            'tag_id': tagId,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await database.appendChange(
        SyncChange.recordUpsert(rec, atEpochMs: now),
        executor: txn,
      );
    }

    // 7. If imported history advanced past or met the open Lap start time,
    // advance the open Lap to latestCeiling to maintain continuous coverage.
    if (lap != null && latestCeiling > lap.startedAtEpochMs) {
      final updatedLap = Lap(
        id: lap.id,
        startedAtEpochMs: latestCeiling,
        startedTimezoneId: lap.startedTimezoneId,
        revision: lap.revision + 1,
      );
      await txn.insert(
        'lap',
        updatedLap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await database.appendChange(
        SyncChange.lapSet(updatedLap, atEpochMs: now),
        executor: txn,
      );
    }

    final trackedImported = recordsToInsert
        .where((r) => r.activityId != null)
        .length;
    return _ReconciliationSummary(
      trackedImported,
      syntheticCount,
      skippedCollisions,
    );
  }

  /// Calculates the start of the local calendar day (00:00:00) in UTC epoch ms.
  int _startOfLocalDayUtcMs(String timezoneId, int epochMs) {
    final wall = wallClockAt(timezoneId, epochMs);
    final localMidnight = DateTime.utc(wall.year, wall.month, wall.day);
    return epochMsFromWallClock(
      localMidnight,
      timezoneId,
      referenceEpochMs: epochMs,
    );
  }
}

class _IntervalSpan {
  final int start;
  final int end;
  final bool isExisting;
  final Record? record;

  const _IntervalSpan(
    this.start,
    this.end, {
    required this.isExisting,
    this.record,
  });
}

class _ReconciliationSummary {
  final int recordsImported;
  final int syntheticRecordsCreated;
  final int skippedDueToCollision;

  const _ReconciliationSummary(
    this.recordsImported,
    this.syntheticRecordsCreated,
    this.skippedDueToCollision,
  );
}
