import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const bool _kIsWeb =
    bool.fromEnvironment('dart.library.js_util') ||
    bool.fromEnvironment('dart.library.js_interop');

/// The advisory lock a restore or a snapshot fallback takes over the store.
///
/// The lock is a file, not a SQLite lock, so it works across processes: the
/// app, a headless notification engine, and the MCP CLI all read the same
/// `<databases path>/tempo.store.lock`. Normal opens do not take it; they rely
/// on SQLite's own locking. Only the operations that must not overlap a live
/// writer take it — a restore, a checkpoint-and-copy snapshot, and an MCP
/// session.
class StoreLockInfo {
  final int pid;
  final String purpose;
  final int acquiredAtEpochMs;

  const StoreLockInfo({
    required this.pid,
    required this.purpose,
    required this.acquiredAtEpochMs,
  });

  Map<String, dynamic> toJson() => {
    'pid': pid,
    'purpose': purpose,
    'acquired_at': acquiredAtEpochMs,
  };

  static StoreLockInfo? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final pid = decoded['pid'];
      final purpose = decoded['purpose'];
      final acquiredAt = decoded['acquired_at'];
      if (pid is! int || purpose is! String || acquiredAt is! int) return null;
      return StoreLockInfo(
        pid: pid,
        purpose: purpose,
        acquiredAtEpochMs: acquiredAt,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'StoreLockInfo(pid: $pid, purpose: $purpose, '
      'acquiredAtEpochMs: $acquiredAtEpochMs)';
}

/// Thrown whenever the store is held by another holder, or by this process.
///
/// The message is the one the product shows: a restore fails closed with
/// "store busy: restore in progress" rather than swapping a database the MCP
/// server or another writer still has open.
class StoreBusyException implements Exception {
  static const String message = 'store busy: restore in progress';

  /// The holder that blocked the caller, when one could be read.
  final StoreLockInfo? holder;

  const StoreBusyException([this.holder]);

  @override
  String toString() => message;
}

/// One holder of the store's advisory lock across processes.
class StoreLifecycle {
  static const String lockFileName = 'tempo.store.lock';

  static const String restorePurpose = 'restore';
  static const String snapshotFallbackPurpose = 'snapshot-fallback';
  static const String sessionPurpose = 'session';

  /// The process-wide holder for app code. A second isolate in the same
  /// process shares it; another process reads the lock file instead.
  static final StoreLifecycle instance = StoreLifecycle();

  final String? _databasesPath;
  final DatabaseFactory? _factory;
  final Duration staleAfter;
  final bool Function(int pid)? _isProcessAlive;
  final DateTime Function() _now;

  String? _resolvedDatabasesPath;
  StoreLockInfo? _heldLock;
  String? _heldLockPath;

  StoreLifecycle({
    String? databasesPath,
    DatabaseFactory? factory,
    this.staleAfter = const Duration(seconds: 60),
    bool Function(int pid)? isProcessAlive,
    DateTime Function()? now,
  }) : _databasesPath = databasesPath, // ignore: prefer_initializing_formals
       _factory = factory, // ignore: prefer_initializing_formals
       _isProcessAlive = isProcessAlive, // ignore: prefer_initializing_formals
       _now = now ?? DateTime.now;

  /// A holder whose lock file sits beside [databaseFilePath]. Used by the MCP
  /// CLI, which may be launched with `--db-path` pointing anywhere.
  factory StoreLifecycle.forDatabasePath(
    String databaseFilePath, {
    Duration staleAfter = const Duration(seconds: 60),
    bool Function(int pid)? isProcessAlive,
    DateTime Function()? now,
  }) => StoreLifecycle(
    databasesPath: p.dirname(databaseFilePath),
    staleAfter: staleAfter,
    isProcessAlive: isProcessAlive,
    now: now,
  );

  DatabaseFactory get factory => _factory ?? _defaultFactory();

  /// The directory holding `tempo.db` and the lock file.
  Future<String> get databasesPath async {
    final configured = _databasesPath;
    if (configured != null) return configured;
    return _resolvedDatabasesPath ??= await factory.getDatabasesPath();
  }

  Future<String> get lockFilePath async =>
      p.join(await databasesPath, lockFileName);

  /// Whether this holder currently holds the lock.
  bool get isHeld => _heldLock != null;

  /// The lock this holder acquired, or null.
  StoreLockInfo? get heldLock => _heldLock;

  /// Takes the advisory lock for [purpose].
  ///
  /// Fails closed with [StoreBusyException] when another holder exists and is
  /// alive, or when it is younger than [staleAfter]. A lock older than
  /// [staleAfter] whose pid is dead is broken and replaced.
  Future<void> acquire({required String purpose}) async {
    if (_heldLock != null) {
      throw StateError(
        'this holder already has the store lock for '
        '${_heldLock!.purpose}',
      );
    }

    final lockPath = await lockFilePath;
    final existing = await _readLock(lockPath);
    if (existing != null && !_isStale(existing)) {
      throw StoreBusyException(existing);
    }

    await Directory(p.dirname(lockPath)).create(recursive: true);
    final info = StoreLockInfo(
      pid: pid,
      purpose: purpose,
      acquiredAtEpochMs: _now().millisecondsSinceEpoch,
    );
    final tempPath =
        '$lockPath.tmp.$pid.${_now().microsecondsSinceEpoch}.'
        '${Random().nextInt(1 << 20)}';
    final temp = File(tempPath);
    try {
      await temp.writeAsString(jsonEncode(info.toJson()), flush: true);
      await temp.rename(lockPath);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
    _heldLock = info;
    _heldLockPath = lockPath;
  }

  /// Releases the lock if this holder holds it. A lock written by another
  /// holder is left in place.
  Future<void> release() async {
    final held = _heldLock;
    final lockPath = _heldLockPath;
    _heldLock = null;
    _heldLockPath = null;
    if (held == null || lockPath == null) return;

    final current = await _readLock(lockPath);
    if (current == null ||
        current.pid != held.pid ||
        current.purpose != held.purpose ||
        current.acquiredAtEpochMs != held.acquiredAtEpochMs) {
      return;
    }
    try {
      await File(lockPath).delete();
    } on FileSystemException {
      // Someone else broke and replaced it between the read and the delete.
    }
  }

  /// Throws [StoreBusyException] when a live holder has the store, which is
  /// what makes a restore fail closed while the MCP server is running.
  Future<void> assertUnlocked() async {
    final existing = await _readLock(await lockFilePath);
    if (existing != null && !_isStale(existing)) {
      throw StoreBusyException(existing);
    }
  }

  /// Replaces [target] with [source] while the caller holds the restore lock.
  ///
  /// [closeStore] is invoked after the replacement copy is durable and before
  /// the target is touched, so a crash can leave at most an unused temp file:
  /// the old store stays whole until the rename. `-wal` and `-shm` files of
  /// the old store are removed, because the snapshot is a standalone file.
  Future<void> replaceStoreAtomically({
    required File source,
    required File target,
    required Future<void> Function() closeStore,
  }) async {
    final held = _heldLock;
    if (held == null || held.purpose != restorePurpose) {
      throw StateError('store replacement requires the restore lock');
    }
    if (!await source.exists()) {
      throw StateError('snapshot to restore is missing: ${source.path}');
    }

    final temp = File('${target.path}.restore');
    if (await temp.exists()) {
      await temp.delete();
    }
    await source.copy(temp.path);

    // Make the copy durable before the rename exposes it as the store.
    final handle = await temp.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }

    await closeStore();

    await temp.rename(target.path);
    for (final suffix in const ['-wal', '-shm']) {
      final leftover = File('${target.path}$suffix');
      if (await leftover.exists()) {
        await leftover.delete();
      }
    }
  }

  Future<StoreLockInfo?> _readLock(String lockPath) async {
    final file = File(lockPath);
    if (!await file.exists()) return null;
    try {
      final info = StoreLockInfo.tryParse(await file.readAsString());
      if (info != null) return info;
    } catch (_) {
      // Fall through: a lock that cannot be read still blocks until it is old
      // enough to break, so an in-flight writer is never stepped over.
    }
    return StoreLockInfo(
      pid: 0,
      purpose: 'unknown',
      acquiredAtEpochMs: _now().millisecondsSinceEpoch,
    );
  }

  bool _isStale(StoreLockInfo info) {
    final ageMs = _now().millisecondsSinceEpoch - info.acquiredAtEpochMs;
    if (ageMs < staleAfter.inMilliseconds) return false;
    return !_isAlive(info.pid);
  }

  bool _isAlive(int candidate) {
    final probe = _isProcessAlive;
    if (probe != null) return probe(candidate);
    return _defaultIsProcessAlive(candidate);
  }

  static bool _defaultIsProcessAlive(int candidate) {
    if (candidate <= 0) return false;
    if (candidate == pid) return true;
    if (Platform.isWindows) return true;
    try {
      final result = Process.runSync('ps', ['-p', '$candidate']);
      return result.exitCode == 0;
    } catch (_) {
      // Without a way to probe, assume alive so the lock is never stolen.
      return true;
    }
  }

  static DatabaseFactory _defaultFactory() {
    if (!_kIsWeb &&
        (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return databaseFactory;
  }
}
