import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/store_lifecycle.dart';
import '../../data/database/tempo_database.dart';
import 'backup_destination.dart';

/// One entry of the destination manifest.
class BackupGeneration {
  /// File name inside `<destination>/tempo/<store_id>/`.
  final String file;

  /// SHA-256 of the file, lowercase hex.
  final String sha256;
  final int bytes;

  /// `PRAGMA user_version` of the snapshot.
  final int schemaVersion;

  /// Snapshot creation instant, UTC epoch milliseconds.
  final int createdAtEpochMs;

  /// False until the promoted file was read back and matched [sha256].
  final bool verified;

  const BackupGeneration({
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.schemaVersion,
    required this.createdAtEpochMs,
    required this.verified,
  });

  Map<String, dynamic> toJson() => {
    'file': file,
    'hash': sha256,
    'bytes': bytes,
    'schemaVersion': schemaVersion,
    'createdAt': createdAtEpochMs,
    'verified': verified,
  };

  static BackupGeneration? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final file = raw['file'];
    final hash = raw['hash'];
    final bytes = raw['bytes'];
    final schemaVersion = raw['schemaVersion'];
    final createdAt = raw['createdAt'];
    final verified = raw['verified'];
    if (file is! String ||
        hash is! String ||
        bytes is! int ||
        schemaVersion is! int ||
        createdAt is! int) {
      return null;
    }
    return BackupGeneration(
      file: file,
      sha256: hash,
      bytes: bytes,
      schemaVersion: schemaVersion,
      createdAtEpochMs: createdAt,
      verified: verified is bool ? verified : false,
    );
  }
}

/// The one ordered manifest per store. [generations] is newest first, so
/// `generations.first` is the restore target and pruning removes from the end.
class BackupManifest {
  static const int formatVersion = 1;

  final String storeId;
  final List<BackupGeneration> generations;

  const BackupManifest({required this.storeId, required this.generations});

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    final storeId = json['storeId'];
    final raw = json['generations'];
    final generations = <BackupGeneration>[];
    if (raw is List) {
      for (final entry in raw) {
        final generation = BackupGeneration.tryFromJson(entry);
        if (generation != null) generations.add(generation);
      }
    }
    generations.sort(
      (a, b) => b.createdAtEpochMs.compareTo(a.createdAtEpochMs),
    );
    return BackupManifest(
      storeId: storeId is String ? storeId : '',
      generations: generations,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'storeId': storeId,
    'generations': generations.map((g) => g.toJson()).toList(),
  };
}

/// A verified snapshot on the local tier.
class BackupSnapshot {
  final File file;
  final String sha256;
  final int bytes;
  final int schemaVersion;

  /// `MAX(changes.seq)` read in the read transaction that began the snapshot.
  /// Zero when the store has no `changes` table yet.
  final int capturedSeq;

  /// `MAX(changes.seq)` found inside the snapshot. Null when the store has no
  /// `changes` table yet.
  final int? verifiedSeq;

  final int createdAtEpochMs;

  const BackupSnapshot({
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.schemaVersion,
    required this.capturedSeq,
    required this.verifiedSeq,
    required this.createdAtEpochMs,
  });
}

/// A destination generation that passed validation, with the current store
/// already snapshotted so an interrupted restore still has a way back.
class PreparedRestore {
  final BackupGeneration generation;
  final BackupSnapshot preRestoreSnapshot;

  /// The validated bytes staged inside app support, ready to replace the store.
  final File stagedFile;

  const PreparedRestore({
    required this.generation,
    required this.preRestoreSnapshot,
    required this.stagedFile,
  });
}

/// Snapshots, verifies, promotes, prunes and prepares restores for the phone's
/// store.
///
/// The store is written only by the phone. Two tiers exist and each covers a
/// different loss: a rolling local snapshot in app support covers a corrupted
/// live store but dies with an uninstall; a promoted generation in the user's
/// folder covers an erased install.
class BackupService {
  static const String backupEnabledSetting = 'backup_enabled';
  static const String destinationSetting = 'backup_destination';
  static const String generationsSetting = 'backup_generations';

  /// Written into the store that replaces the old one, so the next start
  /// reissues this device's identity instead of keeping the restored one.
  static const String restorePendingSetting = 'restore_pending';

  final TempoDatabase database;
  final StoreLifecycle lifecycle;
  final DatabaseFactory factory;

  final Directory? _localDirectoryOverride;
  final String? _storeIdOverride;
  final int defaultGenerations;
  final DateTime Function() _now;
  final String Function() _uuid;
  final Future<BackupDestination?> Function(String locator)? destinationLoader;
  final bool? _supportsVacuumIntoOverride;

  /// Test seam: runs between capturing `MAX(changes.seq)` and copying the
  /// store, so a concurrent write can be exercised deterministically.
  Future<void> Function()? beforeSnapshotCopy;

  final Duration dirtyInterval;
  final Duration promotionInterval;

  BackupDestination? _destination;
  Timer? _scheduler;
  bool _tickRunning = false;
  String? _storeId;
  int? _lastSnapshotMarker;
  DateTime? _lastLocalSnapshotAt;
  DateTime? _lastPromotionAt;

  Future<void> _tail = Future<void>.value();

  BackupService({
    required this.database,
    StoreLifecycle? lifecycle,
    DatabaseFactory? factory,
    Directory? localDirectory,
    BackupDestination? destination,
    String? storeId,
    this.defaultGenerations = 5,
    DateTime Function()? now,
    String Function()? uuid,
    this.destinationLoader,
    bool? supportsVacuumInto,
    this.dirtyInterval = const Duration(minutes: 5),
    this.promotionInterval = const Duration(hours: 1),
  }) : lifecycle = lifecycle ?? StoreLifecycle.instance,
       factory = factory ?? (lifecycle ?? StoreLifecycle.instance).factory,
       _localDirectoryOverride = localDirectory,
       _storeIdOverride = storeId, // ignore: prefer_initializing_formals
       _destination = destination, // ignore: prefer_initializing_formals
       _now = now ?? DateTime.now,
       _uuid = uuid ?? (() => const Uuid().v4()),
       _supportsVacuumIntoOverride = supportsVacuumInto;

  BackupDestination? get destination => _destination;

  /// The live store file, handed to [applyPreparedRestore] by Settings.
  File get databaseFile => File(database.db.path);

  /// Sets the chosen destination. The phone's own storage is refused.
  set destination(BackupDestination? value) {
    if (value != null && value.isOwnStorage) {
      throw const BackupDestinationRefusedException();
    }
    _destination = value;
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  /// Snapshots while dirty and promotes at most once per [promotionInterval]
  /// while `backup_enabled` is true and a destination is reachable.
  void startScheduler({Duration tick = const Duration(minutes: 1)}) {
    _scheduler?.cancel();
    _scheduler = Timer.periodic(tick, (_) {
      unawaited(_tick());
    });
  }

  Future<void> stopScheduler() async {
    _scheduler?.cancel();
    _scheduler = null;
  }

  /// Promotion on app pause, so leaving the app never waits for the hour.
  Future<void> onAppPause() async {
    if (!await _isBackupEnabled()) return;
    await _runGuarded(promote);
  }

  /// Snapshot and promote before a destructive action: a restore, an import
  /// that replaces the store, or anything else that can lose data.
  Future<void> beforeDestructiveAction() async {
    await _runGuarded(() async {
      if (await _loadDestination() == null) {
        await snapshot();
      } else {
        await promote();
      }
    });
  }

  Future<void> _tick() async {
    if (_tickRunning) return;
    _tickRunning = true;
    try {
      if (!await _isBackupEnabled()) return;
      final destination = await _loadDestination();
      if (destination == null) return;

      final now = _now();
      if (await _isDirty()) {
        final last = _lastLocalSnapshotAt;
        if (last == null || now.difference(last) >= dirtyInterval) {
          await _runGuarded(snapshot);
        }
      }

      final lastPromotion = await _lastPromotedAt();
      if (lastPromotion == null ||
          now.difference(lastPromotion) >= promotionInterval) {
        await _runGuarded(promote);
      }
    } finally {
      _tickRunning = false;
    }
  }

  Future<void> _runGuarded(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('Backup: $e');
    }
  }

  Future<bool> _isBackupEnabled() async =>
      await database.getSetting(backupEnabledSetting) == 'true';

  Future<DateTime?> _lastPromotedAt() async {
    final remembered = _lastPromotionAt;
    if (remembered != null) return remembered;
    final manifest = await readManifest();
    if (manifest.generations.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      manifest.generations.first.createdAtEpochMs,
      isUtc: true,
    );
  }

  Future<bool> _isDirty() async {
    final marker = await _currentMarker();
    final last = _lastSnapshotMarker;
    return last == null || marker != last;
  }

  /// The change-log head when the `changes` table exists, otherwise the newest
  /// Record or Lap timestamp. The log lands in Stage 2; until then the marker
  /// still notices edits.
  Future<int> _currentMarker() async {
    final captured = await _captureChangeSeq();
    if (captured.supported) return captured.seq;
    final stampRows = await database.db.rawQuery(
      'SELECT COALESCE(MAX(updated_at_epoch_ms), 0) AS stamp FROM records',
    );
    var marker = stampRows.first['stamp'] as int;
    final lapRows = await database.db.query(
      'lap',
      columns: ['started_at_epoch_ms'],
      where: 'id = 1',
      limit: 1,
    );
    if (lapRows.isNotEmpty) {
      marker = max(marker, lapRows.first['started_at_epoch_ms'] as int);
    }
    return marker;
  }

  // ---------------------------------------------------------------------------
  // Snapshot
  // ---------------------------------------------------------------------------

  /// Takes, verifies and replaces the rolling local snapshot.
  Future<BackupSnapshot> snapshot() => _serialized(_snapshot);

  Future<BackupSnapshot> _snapshot({String fileName = 'snapshot.db'}) async {
    final storeDirectory = await _localStoreDirectory();
    await storeDirectory.create(recursive: true);
    final createdAt = _now().toUtc();
    final temp = File(p.join(storeDirectory.path, 'snapshot-${_uuid()}.db'));
    if (await temp.exists()) await temp.delete();

    final captured = await _captureChangeSeq();
    try {
      final hook = beforeSnapshotCopy;
      if (hook != null) await hook();

      await _copyStoreTo(temp);

      final bytes = await temp.length();
      final hash = await _sha256OfFile(temp);
      final verified = await _verifySnapshotFile(
        temp,
        expectedSeq: captured.supported ? captured.seq : null,
      );

      final target = File(p.join(storeDirectory.path, fileName));
      await temp.rename(target.path);

      _lastSnapshotMarker = await _currentMarker();
      _lastLocalSnapshotAt = createdAt;
      return BackupSnapshot(
        file: target,
        sha256: hash,
        bytes: bytes,
        schemaVersion: verified.schemaVersion,
        capturedSeq: captured.seq,
        verifiedSeq: verified.verifiedSeq,
        createdAtEpochMs: createdAt.millisecondsSinceEpoch,
      );
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> _copyStoreTo(File target) async {
    if (await _supportsVacuumInto()) {
      final quoted = target.path.replaceAll("'", "''");
      await database.db.execute("VACUUM INTO '$quoted'");
      return;
    }

    // No VACUUM INTO: checkpoint and copy, which must not race a restore.
    await lifecycle.acquire(purpose: StoreLifecycle.snapshotFallbackPurpose);
    try {
      await database.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await File(database.db.path).copy(target.path);
    } finally {
      await lifecycle.release();
    }
  }

  Future<bool> _supportsVacuumInto() async {
    final override = _supportsVacuumIntoOverride;
    if (override != null) return override;
    final rows = await database.db.rawQuery(
      'SELECT sqlite_version() AS version',
    );
    final raw = rows.first['version'] as String;
    final parts = raw.split('.');
    final major = int.tryParse(parts.isEmpty ? '' : parts[0]) ?? 0;
    final minor = int.tryParse(parts.length < 2 ? '' : parts[1]) ?? 0;
    return major > 3 || (major == 3 && minor >= 27);
  }

  Future<({bool supported, int seq})> _captureChangeSeq() async {
    if (!await _hasChangesTable(database.db)) {
      return (supported: false, seq: 0);
    }
    var seq = 0;
    // The same read transaction that starts the snapshot: the value the
    // snapshot must reach, never the live store's value after the copy.
    await database.db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(seq), 0) AS seq FROM changes',
      );
      seq = rows.first['seq'] as int;
    });
    return (supported: true, seq: seq);
  }

  Future<({int schemaVersion, int? verifiedSeq})> _verifySnapshotFile(
    File file, {
    required int? expectedSeq,
  }) async {
    final snapshot = await factory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final integrity = await snapshot.rawQuery('PRAGMA integrity_check;');
      final verdict = integrity.isEmpty
          ? ''
          : '${integrity.first.values.first}';
      if (verdict != 'ok') {
        throw BackupVerificationException(
          'integrity check failed for ${p.basename(file.path)}: $verdict',
        );
      }

      final versionRows = await snapshot.rawQuery('PRAGMA user_version;');
      final schemaVersion = versionRows.first.values.first as int? ?? 0;

      int? verifiedSeq;
      if (await _hasChangesTable(snapshot)) {
        final rows = await snapshot.rawQuery(
          'SELECT COALESCE(MAX(seq), 0) AS seq FROM changes',
        );
        verifiedSeq = rows.first['seq'] as int;
        if (expectedSeq != null && verifiedSeq < expectedSeq) {
          throw BackupVerificationException(
            'snapshot is behind the store: captured seq $expectedSeq, '
            'found $verifiedSeq',
          );
        }
      } else if (expectedSeq != null) {
        throw const BackupVerificationException(
          'snapshot has no changes table',
        );
      }

      await _checkCoverage(snapshot);
      return (schemaVersion: schemaVersion, verifiedSeq: verifiedSeq);
    } finally {
      await snapshot.close();
    }
  }

  /// Every moment belongs to exactly one Record or the open Lap: adjacent
  /// Records must abut exactly. A gap or an overlap fails the snapshot.
  Future<void> _checkCoverage(Database snapshot) async {
    final rows = await snapshot.rawQuery(
      'SELECT started_at_epoch_ms, ended_at_epoch_ms FROM records '
      'ORDER BY started_at_epoch_ms ASC, ended_at_epoch_ms ASC',
    );
    int? previousEnd;
    for (final row in rows) {
      final start = row['started_at_epoch_ms'] as int;
      final end = row['ended_at_epoch_ms'] as int;
      if (end < start) {
        throw BackupVerificationException(
          'record ends before it starts at $start',
        );
      }
      final previous = previousEnd;
      if (previous != null) {
        if (start < previous) {
          throw BackupVerificationException(
            'overlapping Records: one ends at $previous, the next starts at '
            '$start',
          );
        }
        if (start > previous) {
          throw BackupVerificationException(
            'gap in coverage: no Record between $previous and $start',
          );
        }
      }
      previousEnd = end;
    }
  }

  Future<bool> _hasChangesTable(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = 'changes'",
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Promotion and the manifest
  // ---------------------------------------------------------------------------

  /// Promotes the newest verified local snapshot to the destination, writes
  /// one generation into the manifest, then prunes beyond the generation
  /// limit. Returns null when no destination is configured.
  Future<BackupGeneration?> promote() => _serialized(_promote);

  Future<BackupGeneration?> _promote() async {
    final destination = await _loadDestination();
    if (destination == null) return null;
    if (!await destination.reopen()) {
      throw BackupDestinationUnavailableException(destination.locator);
    }
    if (destination.isOwnStorage) {
      throw const BackupDestinationRefusedException();
    }

    final snapshot = await _snapshot();
    final storeId = await _storeIdValue();
    final directory = p.posix.join('tempo', storeId);

    final manifest = await readManifest();
    final taken = <String>{
      for (final generation in manifest.generations) generation.file,
      for (final file in await destination.list(directory))
        p.posix.basename(file.path),
    };
    final fileName = _uniqueGenerationName(
      DateTime.fromMillisecondsSinceEpoch(
        snapshot.createdAtEpochMs,
        isUtc: true,
      ),
      taken,
    );

    final tempName = '${_uuid()}.db';
    final bytes = await snapshot.file.readAsBytes();
    final tempPath = await destination.writeTemp(tempName, bytes);
    await destination.renameAtomically(
      from: tempPath,
      to: p.posix.join(directory, fileName),
      expectedSha256: snapshot.sha256,
    );

    final generation = BackupGeneration(
      file: fileName,
      sha256: snapshot.sha256,
      bytes: snapshot.bytes,
      schemaVersion: snapshot.schemaVersion,
      createdAtEpochMs: snapshot.createdAtEpochMs,
      verified: true,
    );
    final limit = await _generationLimit();
    final ordered = <BackupGeneration>[
      generation,
      ...manifest.generations.where((g) => g.file != fileName),
    ]..sort((a, b) => b.createdAtEpochMs.compareTo(a.createdAtEpochMs));
    final kept = ordered.take(limit).toList();
    final pruned = ordered.skip(limit).toList();

    await _writeManifest(
      BackupManifest(storeId: storeId, generations: kept),
      destination,
    );
    for (final stale in pruned) {
      await destination.delete(p.posix.join(directory, stale.file));
    }

    _lastPromotionAt = _now();
    return generation;
  }

  Future<BackupManifest> readManifest() async {
    final empty = BackupManifest(
      storeId: await _storeIdValue(),
      generations: const [],
    );
    final destination = await _loadDestination();
    if (destination == null || !destination.isOpen) return empty;
    try {
      final manifestPath = await _manifestPath();
      final present = (await destination.list(p.posix.dirname(manifestPath)))
          .any((file) => file.path == manifestPath);
      if (!present) return empty;
      final bytes = await _readAll(destination.openRead(manifestPath));
      if (bytes.isEmpty) return empty;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return empty;
      return BackupManifest.fromJson(decoded);
    } catch (e) {
      // A missing or unreadable manifest is rebuilt from the next verified
      // write; the generations themselves are untouched.
      debugPrint('Backup manifest unreadable: $e');
      return empty;
    }
  }

  Future<void> _writeManifest(
    BackupManifest manifest,
    BackupDestination destination,
  ) async {
    final bytes = utf8.encode(jsonEncode(manifest.toJson()));
    final expected = sha256Hex(bytes);
    final tempPath = await destination.writeTemp('manifest.json', bytes);
    await destination.renameAtomically(
      from: tempPath,
      to: await _manifestPath(),
      expectedSha256: expected,
    );
  }

  Future<String> _manifestPath() async =>
      p.posix.join('tempo', await _storeIdValue(), 'manifest.json');

  String _uniqueGenerationName(DateTime createdAt, Set<String> taken) {
    var instant = createdAt.toUtc();
    var name = 'backup-${_formatUtcTimestamp(instant)}.db';
    while (taken.contains(name)) {
      instant = instant.add(const Duration(seconds: 1));
      name = 'backup-${_formatUtcTimestamp(instant)}.db';
    }
    return name;
  }

  static String _formatUtcTimestamp(DateTime utc) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}'
        '${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  Future<int> _generationLimit() async {
    final stored = await database.getSetting(generationsSetting);
    final parsed = int.tryParse(stored ?? '');
    if (parsed == null || parsed <= 0) return defaultGenerations;
    return parsed;
  }

  // ---------------------------------------------------------------------------
  // Restore
  // ---------------------------------------------------------------------------

  /// Validates [generation] against the manifest and the bytes on the
  /// destination, stages it in app support, then snapshots the current store so
  /// an interrupted restore still has a way back.
  ///
  /// Nothing is written and no snapshot is taken when validation fails.
  Future<PreparedRestore> prepareRestore(BackupGeneration generation) =>
      _serialized(() => _prepareRestore(generation));

  Future<PreparedRestore> _prepareRestore(BackupGeneration generation) async {
    final destination = await _loadDestination();
    if (destination == null) {
      throw const BackupDestinationUnavailableException('none configured');
    }
    if (!await destination.reopen()) {
      throw BackupDestinationUnavailableException(destination.locator);
    }

    final manifest = await readManifest();
    final entry = manifest.generations
        .where((candidate) => candidate.file == generation.file)
        .toList();
    if (entry.isEmpty) {
      throw BackupVerificationException(
        'generation ${generation.file} is not in the manifest',
      );
    }
    final prepared = entry.first;
    if (!prepared.verified) {
      throw BackupVerificationException(
        'generation ${prepared.file} was never verified',
      );
    }

    final path = p.posix.join('tempo', await _storeIdValue(), prepared.file);
    final bytes = await _readAll(destination.openRead(path));
    if (bytes.length != prepared.bytes) {
      throw BackupVerificationException(
        'generation ${prepared.file} is ${bytes.length} bytes, '
        'manifest says ${prepared.bytes}',
      );
    }
    final hash = sha256Hex(bytes);
    if (hash != prepared.sha256) {
      throw BackupVerificationException(
        'generation ${prepared.file} hash mismatch: '
        'manifest ${prepared.sha256}, file $hash',
      );
    }

    final storeDirectory = await _localStoreDirectory();
    await storeDirectory.create(recursive: true);
    final staged = File(p.join(storeDirectory.path, 'restore-${_uuid()}.db'));
    await staged.writeAsBytes(bytes, flush: true);

    try {
      final verified = await _verifySnapshotFile(staged, expectedSeq: null);
      if (verified.schemaVersion > TempoDatabase.databaseVersion) {
        throw BackupVerificationException(
          'generation ${prepared.file} is schema v${verified.schemaVersion}, '
          'newer than this app (v${TempoDatabase.databaseVersion})',
        );
      }
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }

    final preRestore = await _snapshot(fileName: 'pre-restore.db');

    return PreparedRestore(
      generation: prepared,
      preRestoreSnapshot: preRestore,
      stagedFile: staged,
    );
  }

  /// Closes the live store and swaps [prepared]'s staged file into place while
  /// holding the restore lock. The caller reopens the store, reissues
  /// `device_id`, renews `log_epoch`, and relaunches; there is no in-process
  /// reopen here.
  Future<void> applyPreparedRestore(
    PreparedRestore prepared, {
    required File target,
    required Future<void> Function() closeStore,
  }) => _serialized(() async {
    await lifecycle.acquire(purpose: StoreLifecycle.restorePurpose);
    try {
      // The flag rides in with the file being swapped in, so a crash can never
      // leave a restored store that still claims the identity it was backed up
      // under.
      await _markRestorePending(prepared.stagedFile);
      await lifecycle.replaceStoreAtomically(
        source: prepared.stagedFile,
        target: target,
        closeStore: closeStore,
      );
      if (await prepared.stagedFile.exists()) {
        await prepared.stagedFile.delete();
      }
    } finally {
      await lifecycle.release();
    }
  });

  /// Stamps a staged store with the flag the next start reads. It is written
  /// before the swap, so the replacement carries it atomically and nothing
  /// reopens the live store afterwards.
  Future<void> _markRestorePending(File staged) async {
    final restored = await factory.openDatabase(
      staged.path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await restored.insert('settings', {
        'key': restorePendingSetting,
        'value': 'true',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } finally {
      await restored.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------

  /// The destination from Settings, reopened on first use.
  Future<BackupDestination?> _loadDestination() async {
    final configured = _destination;
    if (configured != null) return configured;
    final loader = destinationLoader;
    if (loader == null) return null;
    final locator = await database.getSetting(destinationSetting);
    if (locator == null || locator.isEmpty) return null;
    final loaded = await loader(locator);
    _destination = loaded;
    return loaded;
  }

  Future<String> _storeIdValue() async {
    final override = _storeIdOverride;
    if (override != null) return override;
    final cached = _storeId;
    if (cached != null) return cached;
    final stored = await database.getSetting('store_id') ?? 'default';
    _storeId = stored;
    return stored;
  }

  Future<Directory> _localDirectory() async {
    final configured = _localDirectoryOverride;
    if (configured != null) return configured;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'backup'));
  }

  Future<Directory> _localStoreDirectory() async =>
      Directory(p.join((await _localDirectory()).path, await _storeIdValue()));

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List> _readAll(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
