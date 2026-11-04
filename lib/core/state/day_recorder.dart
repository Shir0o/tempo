import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../export/csv_export_engine.dart';
import '../time/timezone_id.dart';

/// Owns the always-running Lap and serializes every write that closes it into
/// a Record. The Lap continues from its persisted start.
class DayRecorder {
  /// The interval after a label or split during which [undoLast] still works.
  static const Duration defaultUndoGraceWindow = Duration(seconds: 3);

  final TempoDatabase _db;
  final int Function() _nowUtcMs;
  final String Function() _generateId;
  final FutureOr<String> Function() _getTimezoneId;
  final Duration undoGraceWindow;

  /// Whether the recorder closes and reopens the Lap at every local midnight
  /// while it stays running. Tests that only drive the clock can turn this off;
  /// [initialize] still applies every missed split.
  final bool autoSplitAtMidnight;
  final Future<void> Function(Record record)? onRecordCommitted;
  CsvExportEngine? csvExportEngine;

  final ValueNotifier<Lap?> _lapNotifier = ValueNotifier<Lap?>(null);
  final StreamController<Lap?> _lapStreamController =
      StreamController<Lap?>.broadcast(sync: true);

  Future<void>? _lock;
  bool _isInitialized = false;
  bool _isDisposed = false;
  Timer? _midnightTimer;
  _UndoSnapshot? _lastOperation;
  String? _lastTimezoneId;

  DayRecorder({
    required TempoDatabase database,
    int Function()? nowUtcMs,
    String Function()? generateId,
    FutureOr<String> Function()? getTimezoneId,
    this.undoGraceWindow = defaultUndoGraceWindow,
    this.autoSplitAtMidnight = true,
    this.onRecordCommitted,
    this.csvExportEngine,
  }) : _db = database,
       _nowUtcMs =
           nowUtcMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _generateId = generateId ?? (() => const Uuid().v4()),
       _getTimezoneId = getTimezoneId ?? localTimezoneId;

  /// The open Lap, or null before [initialize] has run.
  Lap? get lap => _lapNotifier.value;

  /// ValueNotifier exposing the open Lap for widgets.
  ValueListenable<Lap?> get lapListenable => _lapNotifier;

  /// Broadcast stream emitting Lap changes.
  Stream<Lap?> get lapStream => _lapStreamController.stream;

  /// The zone the open Lap started in. A Lap persisted before start zones
  /// existed reads as the zone last reported by the injected zone source,
  /// which is an IANA id on every platform.
  String get lapStartTimezoneId {
    final fallback = _lastTimezoneId ?? localTimezoneId();
    return lap?.startTimezoneOr(fallback) ?? fallback;
  }

  /// Elapsed time of the open Lap in milliseconds.
  int get currentElapsedMs => lap?.elapsedMs(_nowUtcMs()) ?? 0;

  /// Elapsed time of the open Lap at [nowUtcEpochMs].
  int elapsedMsAt(int nowUtcEpochMs) => lap?.elapsedMs(nowUtcEpochMs) ?? 0;

  /// Attaches or updates the CSV export engine.
  void attachExportEngine(CsvExportEngine engine) {
    csvExportEngine = engine;
  }

  /// Loads the persisted Lap, opening one at now if none exists yet, and
  /// applies every MidnightSplit missed while the app was not running.
  Future<Lap> initialize() => _synchronized(() => _initializeLocked());

  /// Closes the Lap at every local midnight that has passed since it started
  /// and reopens it at the last one. Runs automatically at midnight while the
  /// app is open and on [initialize]; call it when the app returns to the
  /// foreground after a possible midnight.
  Future<void> applyMidnightSplits() =>
      _synchronized(() => _applyMidnightSplitsLocked());

  /// Closes the open Lap as a labelled Record ending now and opens a new Lap at
  /// the same instant. Returns the Record that was just written.
  Future<Record> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) => _synchronized(
    () => _closeLapLocked(activityId: activityId, comment: comment, tags: tags),
  );

  /// Synchronizes the in-memory Lap with the latest state in the database,
  /// re-arming midnight timers if changed. Call after external batch imports
  /// or migrations that advance the Lap.
  Future<void> reloadLapFromDatabase() => _synchronized(() async {
    final current = await _db.getLap();
    if (current != null) {
      _updateLap(current);
      await _applyMidnightSplitsLocked();
      await _armMidnightTimer();
    }
  });

  /// Closes the open Lap as an Untracked Record and opens a new Lap at the same
  /// instant, so the boundary is marked without deciding what the time was.
  Future<Record> split() => _synchronized(() => _closeLapLocked());

  /// Labels an existing Record, including an Untracked one, with [activityId].
  /// Passing null turns a labelled Record back into an Untracked Record.
  Future<Record> relabel(String recordId, String? activityId) => _synchronized(
    () async {
      await _ensureInitializedLocked();
      final record = await _recordOrThrow(recordId);
      if (activityId != null) {
        final activity = await _db.getActivityById(activityId);
        if (activity == null) {
          throw ArgumentError('Activity with id "$activityId" does not exist.');
        }
      }

      final updated = record
          .withActivity(activityId)
          .copyWith(updatedAtEpochMs: _nowUtcMs());
      await _db.updateRecord(updated);
      await _requestExport();
      return updated;
    },
  );

  /// Replaces the comment and tags of [recordId], leaving its time and
  /// Activity alone.
  Future<Record> annotate(
    String recordId, {
    required String comment,
    required List<String> tagIds,
  }) => _synchronized(() async {
    await _ensureInitializedLocked();
    final record = await _recordOrThrow(recordId);
    final updated = record.copyWith(
      comment: comment,
      tagIds: List.unmodifiable(tagIds),
      updatedAtEpochMs: _nowUtcMs(),
    );
    await _db.updateRecord(updated);
    await _requestExport();
    return updated;
  });

  /// Moves one or both Edges of [recordId] to [startEpochMs] and [endEpochMs].
  ///
  /// Only that Record changes meaning. Time it gives up becomes Untracked,
  /// merging into an adjacent Untracked Record or the open Lap when there is
  /// one; it may grow only into time that is already Untracked, so a change
  /// that would overlap a labelled Record is refused. A Record that would cross
  /// local midnight is split there, keeping its Activity, note and tags.
  Future<Record> adjustEdges(
    String recordId, {
    int? startEpochMs,
    int? endEpochMs,
  }) => _synchronized(() async {
    await _ensureInitializedLocked();
    final record = await _recordOrThrow(recordId);
    final newStart = startEpochMs ?? record.startedAtEpochMs;
    final newEnd = endEpochMs ?? record.endedAtEpochMs;
    if (newStart == record.startedAtEpochMs &&
        newEnd == record.endedAtEpochMs) {
      return record;
    }
    if (newStart >= newEnd) {
      throw const RecordEditRefused(
        'A Record needs a start before its end, so the change was not made.',
      );
    }
    final now = _nowUtcMs();
    if (newEnd != record.endedAtEpochMs && newEnd > now) {
      throw const RecordEditRefused(
        "A Record can't end after now, so the change was not made.",
      );
    }

    // Time the Record gives up becomes Untracked; time it gains must already
    // be Untracked, or belong to the open Lap.
    final lost = <(int, int, String)>[
      if (newStart > record.startedAtEpochMs)
        (record.startedAtEpochMs, newStart, record.timezoneId),
      if (newEnd < record.endedAtEpochMs)
        (newEnd, record.endedAtEpochMs, record.endTimezoneId),
    ];
    final gained = <(int, int)>[
      if (newStart < record.startedAtEpochMs)
        (newStart, record.startedAtEpochMs),
      if (newEnd > record.endedAtEpochMs) (record.endedAtEpochMs, newEnd),
    ];

    final lap = _lapNotifier.value;
    final removed = <Record>[];
    final rewritten = <Record>[];
    final created = <Record>[];
    int? lapStartMs;

    // Growing: absorb only Untracked neighbours, trimming or removing them.
    for (final (from, to) in gained) {
      for (final other in await _recordsOverlapping(from, to)) {
        if (other.id == record.id) continue;
        if (!other.isUntracked) {
          throw const RecordEditRefused(
            'That time belongs to another Record, so the change was not made.',
          );
        }
        final keepLeft = other.startedAtEpochMs < from;
        final keepRight = other.endedAtEpochMs > to;
        if (keepLeft && keepRight) {
          rewritten.add(
            other.copyWith(endedAtEpochMs: from, updatedAtEpochMs: now),
          );
          created.add(
            _untrackedRecord(
              from: to,
              to: other.endedAtEpochMs,
              timezoneId: other.timezoneId,
              endTimezoneId: other.endTimezoneId,
              now: now,
            ),
          );
        } else if (keepLeft) {
          rewritten.add(
            other.copyWith(endedAtEpochMs: from, updatedAtEpochMs: now),
          );
        } else if (keepRight) {
          rewritten.add(
            other.copyWith(startedAtEpochMs: to, updatedAtEpochMs: now),
          );
        } else {
          removed.add(other);
        }
      }
    }

    // A tail that reaches past the last Record takes time from the open Lap.
    if (newEnd > record.endedAtEpochMs &&
        lap != null &&
        newEnd > lap.startedAtEpochMs) {
      lapStartMs = newEnd;
    }

    // Shrinking: the freed span joins an adjacent Untracked span when one is
    // there, and becomes its own Untracked Record otherwise.
    for (final (from, to, zone) in lost) {
      var merged = false;
      final before = await _recordEndingAt(from);
      if (before != null && before.id != record.id && before.isUntracked) {
        final extended = before.copyWith(
          endedAtEpochMs: to,
          updatedAtEpochMs: now,
        );
        if (!_crossesMidnight(extended)) {
          rewritten.add(extended);
          merged = true;
        }
      }
      if (!merged) {
        final after = await _recordStartingAt(to);
        if (after != null && after.id != record.id && after.isUntracked) {
          final extended = after.copyWith(
            startedAtEpochMs: from,
            updatedAtEpochMs: now,
          );
          if (!_crossesMidnight(extended)) {
            rewritten.add(extended);
            merged = true;
          }
        }
      }
      if (!merged &&
          lap != null &&
          lap.startedAtEpochMs == to &&
          _sameLocalDate(
            lap.startTimezoneOr(zone),
            lap.startedAtEpochMs,
            from,
          )) {
        lapStartMs = from;
        merged = true;
      }
      if (!merged) {
        created.add(
          _untrackedRecord(
            from: from,
            to: to,
            timezoneId: zone,
            endTimezoneId: zone,
            now: now,
          ),
        );
      }
    }

    final slices = _slicesOf(record, newStart, newEnd, now);
    final updatedLap =
        lap != null && lapStartMs != null && lapStartMs != lap.startedAtEpochMs
        ? lap.copyWith(startedAtEpochMs: lapStartMs, revision: lap.revision + 1)
        : null;

    await _db.db.transaction((txn) async {
      for (final record in removed) {
        await txn.delete('records', where: 'id = ?', whereArgs: [record.id]);
        await txn.insert(
          'tombstones',
          Tombstone(
            entityId: record.id,
            entityType: 'record',
            deletedAtEpochMs: now,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final record in rewritten) {
        await _updateRecordInTxn(txn, record);
      }
      for (final record in created) {
        await _insertRecordInTxn(txn, record);
      }
      for (var i = 0; i < slices.length; i++) {
        if (i == 0) {
          await _updateRecordInTxn(txn, slices[i]);
        } else {
          await _insertRecordInTxn(txn, slices[i]);
        }
      }
      if (updatedLap != null) {
        await txn.insert(
          'lap',
          updatedLap.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });

    _lastOperation = null;
    if (updatedLap != null) _updateLap(updatedLap);
    await _requestExport();
    return slices.first;
  });

  /// Splits [recordId] at [atEpochMs] into two neighbouring Records that share
  /// its Activity, comment and tags. The earlier half keeps the original id.
  /// Refused when [atEpochMs] is not strictly inside the Record.
  Future<Record> splitRecord(String recordId, int atEpochMs) =>
      _synchronized(() async {
        await _ensureInitializedLocked();
        final record = await _recordOrThrow(recordId);
        if (atEpochMs <= record.startedAtEpochMs ||
            atEpochMs >= record.endedAtEpochMs) {
          throw const RecordEditRefused(
            "That time is outside this Record, so it can't be split there.",
          );
        }

        final now = _nowUtcMs();
        final earlier = record.copyWith(
          endedAtEpochMs: atEpochMs,
          updatedAtEpochMs: now,
        );
        // The instant a Record crossed from its start zone to its end zone is
        // not stored, so the later half starts in the zone the Record ended in.
        final later = record.copyWith(
          id: _generateId(),
          startedAtEpochMs: atEpochMs,
          timezoneId: record.endTimezoneId,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        );

        await _db.db.transaction((txn) async {
          await _updateRecordInTxn(txn, earlier);
          await _insertRecordInTxn(txn, later);
        });
        _lastOperation = null;
        await _requestExport();
        return later;
      });

  /// Joins two neighbouring Records into one, keeping the earlier Record's
  /// Activity, comment and tags and taking the later Record's end. The later
  /// Record disappears with a Tombstone.
  ///
  /// Refused when the two Records are not directly adjacent, or when they meet
  /// at a local midnight: a Record never crosses 00:00.
  Future<Record> merge(String leftRecordId, String rightRecordId) =>
      _synchronized(() async {
        await _ensureInitializedLocked();
        final first = await _recordOrThrow(leftRecordId);
        final second = await _recordOrThrow(rightRecordId);
        final earlier = first.startedAtEpochMs <= second.startedAtEpochMs
            ? first
            : second;
        final later = identical(earlier, first) ? second : first;
        if (earlier.id == later.id ||
            earlier.endedAtEpochMs != later.startedAtEpochMs) {
          throw const RecordEditRefused(
            "Those Records aren't next to each other, so they can't be merged.",
          );
        }

        final now = _nowUtcMs();
        final merged = earlier.copyWith(
          endedAtEpochMs: later.endedAtEpochMs,
          endTimezoneId: later.endTimezoneId,
          updatedAtEpochMs: now,
        );
        if (_crossesMidnight(merged)) {
          throw const RecordEditRefused(
            "Those Records are on different Days, so they can't be merged.",
          );
        }

        await _db.db.transaction((txn) async {
          await _updateRecordInTxn(txn, merged);
          await txn.delete('records', where: 'id = ?', whereArgs: [later.id]);
          await txn.insert(
            'tombstones',
            Tombstone(
              entityId: later.id,
              entityType: 'record',
              deletedAtEpochMs: now,
            ).toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        });
        _lastOperation = null;
        await _requestExport();
        return merged;
      });

  /// Turns a Record into an Untracked Record in place, so its time stays in the
  /// Day. Its Activity, comment and tags are cleared.
  Future<Record> delete(String recordId) => _synchronized(() async {
    await _ensureInitializedLocked();
    final record = await _recordOrThrow(recordId);
    if (record.isUntracked) return record;

    final updated = record
        .withActivity(null)
        .copyWith(
          comment: '',
          tagIds: const <String>[],
          updatedAtEpochMs: _nowUtcMs(),
        );
    await _db.updateRecord(updated);
    _lastOperation = null;
    await _requestExport();
    return updated;
  });

  /// Reverses the most recent [label] or [split] when called inside the
  /// [undoGraceWindow]: the Record is deleted (with a Tombstone) and the Lap is
  /// restored to its previous start. Returns false when nothing is undoable.
  Future<bool> undoLast() => _synchronized(() async {
    await _ensureInitializedLocked();
    final undo = _lastOperation;
    if (undo == null) return false;

    _lastOperation = null;
    final now = _nowUtcMs();
    if (now - undo.armedAtEpochMs > undoGraceWindow.inMilliseconds) {
      return false;
    }

    await _db.db.transaction((txn) async {
      for (final record in undo.writtenRecords) {
        await txn.delete('records', where: 'id = ?', whereArgs: [record.id]);
        await txn.insert(
          'tombstones',
          Tombstone(
            entityId: record.id,
            entityType: 'record',
            deletedAtEpochMs: now,
          ).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final record in undo.previousRecords) {
        await _updateRecordInTxn(txn, record);
      }
      await txn.insert(
        'lap',
        undo.previousLap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _updateLap(undo.previousLap);
    await _requestExport();
    await _armMidnightTimer();
    return true;
  });

  /// Labels the open Lap with the Activity of the most recent labelled Record.
  /// Returns null when no labelled Record exists.
  Future<Record?> sameAsLast() => _synchronized(() async {
    await _ensureInitializedLocked();
    final previous = await _db.getRecords(
      trackedOnly: true,
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    if (previous.isEmpty) return null;
    return _closeLapLocked(activityId: previous.first.activityId);
  });

  Future<Lap> _initializeLocked() async {
    var current = await _db.getLap();
    if (current == null) {
      current = Lap(
        startedAtEpochMs: _nowUtcMs(),
        startedTimezoneId: await _currentTimezoneId(),
        revision: 1,
      );
      await _db.setLap(current);
    }
    _updateLap(current);
    _isInitialized = true;

    // The app may have been closed across one or more midnights.
    await _applyMidnightSplitsLocked();
    await _armMidnightTimer();
    return _lapNotifier.value!;
  }

  Future<void> _ensureInitializedLocked() async {
    if (_isInitialized) return;
    await _initializeLocked();
  }

  Future<Record> _closeLapLocked({
    String? activityId,
    String comment = '',
    List<String> tags = const [],
  }) async {
    await _ensureInitializedLocked();

    if (activityId != null) {
      final activity = await _db.getActivityById(activityId);
      if (activity == null) {
        throw ArgumentError('Activity with id "$activityId" does not exist.');
      }
    }

    // Afterwards the Lap starts at or after the last local midnight, so the
    // span closed here never crosses 00:00.
    await _applyMidnightSplitsLocked();

    final current = _lapNotifier.value!;
    // A clock that moved back before the Lap started closes an empty span
    // instead of writing a Record that ends before it starts.
    final now = max(_nowUtcMs(), current.startedAtEpochMs);
    final endTimezoneId = await _currentTimezoneId();
    final startTimezoneId = current.startTimezoneOr(endTimezoneId);

    // A label covers the whole unlabeled span, including the MidnightSplit
    // halves already written since the last label. A deliberate Split is a
    // boundary the user chose, so it is never absorbed.
    final absorbed = activityId == null
        ? const <Record>[]
        : await _trailingMidnightSplits(current.startedAtEpochMs);

    final closing = Record(
      id: _generateId(),
      activityId: activityId,
      startedAtEpochMs: current.startedAtEpochMs,
      endedAtEpochMs: now,
      comment: comment,
      timezoneId: startTimezoneId,
      endTimezoneId: endTimezoneId,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
      tagIds: List.unmodifiable(tags),
    );
    final written = [closing];

    final labelled = [
      for (final record in absorbed)
        record
            .withActivity(activityId)
            .copyWith(
              comment: comment,
              tagIds: List.unmodifiable(tags),
              updatedAtEpochMs: now,
            ),
    ];

    final nextLap = Lap(
      startedAtEpochMs: now,
      startedTimezoneId: endTimezoneId,
      revision: current.revision + 1,
    );

    await _db.db.transaction((txn) async {
      for (final record in labelled) {
        await _updateRecordInTxn(txn, record);
      }
      for (final record in written) {
        await _insertRecordInTxn(txn, record);
      }
      await txn.insert(
        'lap',
        nextLap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _lastOperation = _UndoSnapshot(
      writtenRecords: written,
      previousRecords: absorbed,
      previousLap: current,
      armedAtEpochMs: now,
    );
    _updateLap(nextLap);
    for (final record in labelled) {
      await _notifyRecordCommitted(record);
    }
    for (final record in written) {
      await _notifyRecordCommitted(record);
    }
    await _armMidnightTimer();
    return closing;
  }

  /// Closes the open Lap at each local midnight it has crossed and reopens it
  /// at the last one, writing one Untracked Record per Day.
  Future<void> _applyMidnightSplitsLocked() async {
    await _ensureInitializedLocked();
    final current = _lapNotifier.value!;
    final now = _nowUtcMs();
    if (now <= current.startedAtEpochMs) return;

    // When the app returns to the foreground, the best available reading of
    // "the zone the user was in at that midnight" is the device's current
    // zone; while running, this is the zone at the instant the midnight timer
    // fires.
    final zoneAtMidnight = await _currentTimezoneId();
    var cursor = current.startedAtEpochMs;
    var cursorTimezoneId = current.startTimezoneOr(zoneAtMidnight);
    var revision = current.revision;
    final created = <Record>[];

    while (true) {
      final boundary = nextLocalMidnightUtcMs(zoneAtMidnight, cursor);
      if (boundary > now) break;
      created.add(
        Record(
          id: _generateId(),
          activityId: null,
          startedAtEpochMs: cursor,
          endedAtEpochMs: boundary,
          timezoneId: cursorTimezoneId,
          endTimezoneId: zoneAtMidnight,
          isMidnightSplit: true,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      cursor = boundary;
      cursorTimezoneId = zoneAtMidnight;
      revision += 1;
    }
    if (created.isEmpty) return;

    final nextLap = Lap(
      startedAtEpochMs: cursor,
      startedTimezoneId: cursorTimezoneId,
      revision: revision,
    );
    await _db.db.transaction((txn) async {
      for (final record in created) {
        await _insertRecordInTxn(txn, record);
      }
      await txn.insert(
        'lap',
        nextLap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    // The Lap moved, so a label still inside its undo window can no longer be
    // reversed without creating an overlap.
    _lastOperation = null;
    _updateLap(nextLap);
    for (final record in created) {
      await _notifyRecordCommitted(record);
    }
    await _armMidnightTimer();
  }

  /// Whether [record] spans a local midnight in the zone it ended in, the
  /// zone each MidnightSplit is taken in.
  bool _crossesMidnight(Record record) =>
      nextLocalMidnightUtcMs(record.endTimezoneId, record.startedAtEpochMs) <
      record.endedAtEpochMs;

  Future<Record> _recordOrThrow(String recordId) async {
    final record = await _db.getRecordById(recordId);
    if (record == null) {
      throw ArgumentError('Record with id "$recordId" does not exist.');
    }
    return record;
  }

  /// The Record that begins at [epochMs], or null when the open Lap does.
  Future<Record?> _recordStartingAt(int epochMs) async {
    final rows = await _db.db.query(
      'records',
      columns: ['id'],
      where: 'started_at_epoch_ms = ?',
      whereArgs: [epochMs],
      orderBy: 'rowid ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _db.getRecordById(rows.first['id'] as String);
  }

  /// The Record that ends at [epochMs], if any.
  Future<Record?> _recordEndingAt(int epochMs) async {
    final rows = await _db.db.query(
      'records',
      columns: ['id'],
      where: 'ended_at_epoch_ms = ?',
      whereArgs: [epochMs],
      orderBy: 'rowid ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _db.getRecordById(rows.first['id'] as String);
  }

  /// Every Record that overlaps [fromMs, toMs), oldest first, with tags.
  Future<List<Record>> _recordsOverlapping(int fromMs, int toMs) async {
    final rows = await _db.db.query(
      'records',
      columns: ['id'],
      where: 'started_at_epoch_ms < ? AND ended_at_epoch_ms > ?',
      whereArgs: [toMs, fromMs],
      orderBy: 'started_at_epoch_ms ASC',
    );
    final records = <Record>[];
    for (final row in rows) {
      final record = await _db.getRecordById(row['id'] as String);
      if (record != null) records.add(record);
    }
    return records;
  }

  /// The slices [start, end] is divided into at each local midnight, so no
  /// Record crosses 00:00. The first slice keeps [record]'s id; later slices
  /// keep its Activity, note, tags and end zone.
  List<Record> _slicesOf(Record record, int start, int end, int now) {
    final slices = <Record>[];
    var cursor = start;
    var first = true;
    while (cursor < end) {
      final midnight = nextLocalMidnightUtcMs(record.endTimezoneId, cursor);
      final sliceEnd = midnight < end ? midnight : end;
      slices.add(
        record.copyWith(
          id: first ? record.id : _generateId(),
          startedAtEpochMs: cursor,
          endedAtEpochMs: sliceEnd,
          timezoneId: first ? record.timezoneId : record.endTimezoneId,
          createdAtEpochMs: first ? record.createdAtEpochMs : now,
          updatedAtEpochMs: now,
        ),
      );
      cursor = sliceEnd;
      first = false;
    }
    return slices;
  }

  Record _untrackedRecord({
    required int from,
    required int to,
    required String timezoneId,
    required String endTimezoneId,
    required int now,
  }) => Record(
    id: _generateId(),
    activityId: null,
    startedAtEpochMs: from,
    endedAtEpochMs: to,
    timezoneId: timezoneId,
    endTimezoneId: endTimezoneId,
    createdAtEpochMs: now,
    updatedAtEpochMs: now,
  );

  /// Whether [a] and [b] fall on the same calendar date in [zone].
  bool _sameLocalDate(String zone, int a, int b) {
    final first = wallClockAt(zone, a);
    final second = wallClockAt(zone, b);
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  /// The contiguous MidnightSplit Records ending exactly at [lapStartEpochMs],
  /// oldest first. They are the earlier Days of the same unlabeled span.
  Future<List<Record>> _trailingMidnightSplits(int lapStartEpochMs) async {
    final absorbed = <Record>[];
    var cursor = lapStartEpochMs;
    while (true) {
      final rows = await _db.db.query(
        'records',
        where:
            'ended_at_epoch_ms = ? AND activity_id IS NULL '
            'AND is_midnight_split = 1',
        whereArgs: [cursor],
        limit: 1,
      );
      if (rows.isEmpty) break;
      final record = Record.fromMap(rows.first);
      if (record.startedAtEpochMs >= cursor) break;
      absorbed.insert(0, record);
      cursor = record.startedAtEpochMs;
    }
    return absorbed;
  }

  Future<void> _insertRecordInTxn(Transaction txn, Record record) async {
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
  }

  Future<void> _updateRecordInTxn(Transaction txn, Record record) async {
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
  }

  /// Arms a one-shot timer for the next local midnight so an open app splits
  /// the Lap exactly at 00:00 in the zone it is in at that moment.
  Future<void> _armMidnightTimer() async {
    _midnightTimer?.cancel();
    _midnightTimer = null;
    if (!autoSplitAtMidnight || _isDisposed) return;

    final now = _nowUtcMs();
    final zoneNow = await _currentTimezoneId();
    final boundary = nextLocalMidnightUtcMs(zoneNow, now);
    final delayMs = boundary - now;
    if (delayMs <= 0) return;

    _midnightTimer = Timer(Duration(milliseconds: delayMs), () async {
      try {
        await applyMidnightSplits();
      } catch (_) {
        // A failed split must not leave the recorder without a timer; the next
        // write or foreground pass tries again.
      } finally {
        await _armMidnightTimer();
      }
    });
  }

  Future<String> _currentTimezoneId() async {
    final zone = await _getTimezoneId();
    _lastTimezoneId = zone;
    return zone;
  }

  void _updateLap(Lap? lap) {
    if (_lapNotifier.value != lap) {
      _lapNotifier.value = lap;
      _lapStreamController.add(lap);
    }
  }

  Future<void> _notifyRecordCommitted(Record record) async {
    await _requestExport();
    if (onRecordCommitted != null) {
      await onRecordCommitted!(record);
    }
  }

  Future<void> _requestExport() async {
    final engine = csvExportEngine;
    if (engine == null) return;
    if (engine.debounceDuration == Duration.zero) {
      await engine.scheduleExport();
    } else {
      engine.scheduleExport();
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      completer.complete();
      if (_lock == completer.future) {
        _lock = null;
      }
    }
  }

  /// Closes the Lap stream and notifier. Does not close the injected database.
  void dispose() {
    _isDisposed = true;
    _midnightTimer?.cancel();
    _midnightTimer = null;
    _lapStreamController.close();
    _lapNotifier.dispose();
  }
}

/// Thrown when a correction would break the Day's continuity: a gap, an
/// overlap, or an edge pushed past its neighbour. [message] is safe to show to
/// the user as-is.
class RecordEditRefused implements Exception {
  final String message;

  const RecordEditRefused(this.message);

  @override
  String toString() => message;
}

/// The state needed to reverse one label or split.
class _UndoSnapshot {
  /// Records this operation wrote, in chronological order.
  final List<Record> writtenRecords;

  /// Earlier MidnightSplit Records the label absorbed, in their prior state.
  final List<Record> previousRecords;

  final Lap previousLap;
  final int armedAtEpochMs;

  const _UndoSnapshot({
    required this.writtenRecords,
    required this.previousRecords,
    required this.previousLap,
    required this.armedAtEpochMs,
  });
}
