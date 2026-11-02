import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../export/csv_export_engine.dart';
import '../time/timezone_id.dart';

/// Owns the always-running Lap and serializes every write that closes it into
/// a Record. There is no pause, resume, or idle state: the Lap simply continues
/// from its persisted start.
class DayRecorder {
  final TempoDatabase _db;
  final int Function() _nowUtcMs;
  final String Function() _generateId;
  final FutureOr<String> Function() _getTimezoneId;
  final Future<void> Function(Record record)? onRecordCommitted;
  CsvExportEngine? csvExportEngine;

  final ValueNotifier<Lap?> _lapNotifier = ValueNotifier<Lap?>(null);
  final StreamController<Lap?> _lapStreamController =
      StreamController<Lap?>.broadcast(sync: true);

  Future<void>? _lock;
  bool _isInitialized = false;

  DayRecorder({
    required TempoDatabase database,
    int Function()? nowUtcMs,
    String Function()? generateId,
    FutureOr<String> Function()? getTimezoneId,
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

  /// Elapsed time of the open Lap in milliseconds.
  int get currentElapsedMs => lap?.elapsedMs(_nowUtcMs()) ?? 0;

  /// Elapsed time of the open Lap at [nowUtcEpochMs].
  int elapsedMsAt(int nowUtcEpochMs) => lap?.elapsedMs(nowUtcEpochMs) ?? 0;

  /// Attaches or updates the CSV export engine.
  void attachExportEngine(CsvExportEngine engine) {
    csvExportEngine = engine;
  }

  /// Loads the persisted Lap, opening one at now if none exists yet.
  Future<Lap> initialize() => _synchronized(() => _initializeLocked());

  /// Closes the open Lap as a labelled Record ending now and opens a new Lap at
  /// the same instant. Returns the Record that was just written.
  Future<Record> label(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) => _synchronized(
    () => _labelLocked(activityId, comment: comment, tags: tags),
  );

  /// Labels the open Lap with the Activity of the most recent labelled Record.
  /// Returns null when no previous Record exists.
  Future<Record?> sameAsLast() => _synchronized(() async {
    await _ensureInitializedLocked();
    final previous = await _db.getRecords(
      limit: 1,
      orderBy: 'ended_at_epoch_ms DESC, rowid DESC',
    );
    if (previous.isEmpty) return null;
    return _labelLocked(previous.first.activityId);
  });

  Future<Lap> _initializeLocked() async {
    var current = await _db.getLap();
    if (current == null) {
      current = Lap(
        startedAtEpochMs: _nowUtcMs(),
        startedTimezoneId: await _getTimezoneId(),
        revision: 1,
      );
      await _db.setLap(current);
    }
    _updateLap(current);
    _isInitialized = true;
    return current;
  }

  Future<void> _ensureInitializedLocked() async {
    if (_isInitialized) return;
    await _initializeLocked();
  }

  Future<Record> _labelLocked(
    String activityId, {
    String comment = '',
    List<String> tags = const [],
  }) async {
    await _ensureInitializedLocked();

    final activity = await _db.getActivityById(activityId);
    if (activity == null) {
      throw ArgumentError('Activity with id "$activityId" does not exist.');
    }

    final now = _nowUtcMs();
    final current = _lapNotifier.value!;
    final endTimezoneId = await _getTimezoneId();
    final durationMs = now - current.startedAtEpochMs;

    final record = Record(
      id: _generateId(),
      activityId: activityId,
      startedAtEpochMs: current.startedAtEpochMs,
      endedAtEpochMs: now,
      durationMs: durationMs < 0 ? 0 : durationMs,
      comment: comment,
      timezoneId: current.startTimezoneOr(endTimezoneId),
      endTimezoneId: endTimezoneId,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
      tagIds: List.unmodifiable(tags),
    );

    final nextLap = Lap(
      startedAtEpochMs: now,
      startedTimezoneId: endTimezoneId,
      revision: current.revision + 1,
    );

    await _db.db.transaction((txn) async {
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
      await txn.insert(
        'lap',
        nextLap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _updateLap(nextLap);
    await _notifyRecordCommitted(record);
    return record;
  }

  void _updateLap(Lap? lap) {
    if (_lapNotifier.value != lap) {
      _lapNotifier.value = lap;
      _lapStreamController.add(lap);
    }
  }

  Future<void> _notifyRecordCommitted(Record record) async {
    final engine = csvExportEngine;
    if (engine != null) {
      if (engine.debounceDuration == Duration.zero) {
        await engine.scheduleExport();
      } else {
        engine.scheduleExport();
      }
    }
    if (onRecordCommitted != null) {
      await onRecordCommitted!(record);
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
    _lapStreamController.close();
    _lapNotifier.dispose();
  }
}
