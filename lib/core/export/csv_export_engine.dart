import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';

/// Atomic Write-Flush-Rename CSV Export Engine guaranteeing 100% Simple Time Tracker
/// schema parity and zero-corruption reads for peer tools such as BNPB.
class CsvExportEngine {
  final TempoDatabase database;
  final File targetFile;
  final Duration debounceDuration;
  final String Function() _generateUuid;
  final DateTime Function(int epochMs) _epochToDateTime;

  /// Default file name matching Simple Time Tracker continuous auto-export.
  static const String defaultFileName = 'stt_records_automatic.csv';

  /// Exact 8-column header, all lowercase, comma-separated.
  static const String csvHeader =
      'activity name,time started,time ended,comment,categories,record tags,duration,duration minutes';

  /// Default trailing-edge debounce duration (1,000 milliseconds).
  static const Duration defaultDebounceDuration = Duration(milliseconds: 1000);

  Timer? _debounceTimer;
  Completer<File>? _scheduledCompleter;
  Future<File>? _lastExportFuture;
  Future<void>? _mutexLock;
  bool _isDisposed = false;
  FutureOr<void> Function(File file)? onExportCompleted;

  CsvExportEngine({
    required this.database,
    File? targetFile,
    String? targetFilePath,
    Directory? exportDirectory,
    String fileName = defaultFileName,
    this.debounceDuration = defaultDebounceDuration,
    String Function()? generateUuid,
    DateTime Function(int epochMs)? epochToDateTime,
    this.onExportCompleted,
  })  : targetFile = _resolveTargetFile(
          targetFile: targetFile,
          targetFilePath: targetFilePath,
          exportDirectory: exportDirectory,
          fileName: fileName,
        ),
        _generateUuid = generateUuid ?? (() => const Uuid().v4()),
        _epochToDateTime = epochToDateTime ??
            ((ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: false));

  /// Factory creating an engine targeting [directory] with [fileName].
  factory CsvExportEngine.toDirectory({
    required TempoDatabase database,
    required Directory directory,
    String fileName = defaultFileName,
    Duration debounceDuration = defaultDebounceDuration,
    String Function()? generateUuid,
    DateTime Function(int epochMs)? epochToDateTime,
  }) =>
      CsvExportEngine(
        database: database,
        exportDirectory: directory,
        fileName: fileName,
        debounceDuration: debounceDuration,
        generateUuid: generateUuid,
        epochToDateTime: epochToDateTime,
      );

  static File _resolveTargetFile({
    File? targetFile,
    String? targetFilePath,
    Directory? exportDirectory,
    String fileName = defaultFileName,
  }) {
    if (targetFile != null) return targetFile;
    if (targetFilePath != null) return File(targetFilePath);
    if (exportDirectory != null) {
      return File(p.join(exportDirectory.path, fileName));
    }
    throw ArgumentError(
      'One of targetFile, targetFilePath, or exportDirectory must be provided.',
    );
  }

  /// Whether this engine has been disposed.
  bool get isDisposed => _isDisposed;

  /// Whether a debounced export timer is currently pending.
  bool get isExportScheduled => _debounceTimer?.isActive ?? false;

  /// The Future of the most recently initiated export (scheduled or immediate),
  /// or null if no export has been initiated yet.
  Future<File>? get lastExportFuture => _lastExportFuture;

  // ==========================================
  // Formatting Utilities (STT Schema Parity)
  // ==========================================

  /// Formats [dt] into strict `yyyy-MM-dd HH:mm:ss` (US locale, 24h, zero-padded).
  static String formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  /// Formats duration in milliseconds to unpadded `"$hr:$min:$sec"`
  /// matching Simple Time Tracker (e.g. `0:19:9`, `1:0:0`, `0:0:0`).
  static String formatDuration(int durationMs) {
    final ms = durationMs < 0 ? 0 : durationMs;
    final totalSeconds = ms ~/ 1000;
    final hr = totalSeconds ~/ 3600;
    final min = (totalSeconds % 3600) ~/ 60;
    final sec = totalSeconds % 60;
    return '$hr:$min:$sec';
  }

  /// Formats duration in milliseconds into integer elapsed minutes (`ms ~/ 60000`).
  static int formatDurationMinutes(int durationMs) {
    final ms = durationMs < 0 ? 0 : durationMs;
    return ms ~/ 60000;
  }

  /// Escapes internal double quotes by doubling them (`""`).
  static String escapeString(String text) {
    return text.replaceAll('"', '""');
  }

  /// Quotes a string with double quotes after escaping internal quotes.
  static String quoteString(String text) {
    return '"${escapeString(text)}"';
  }

  /// Formats a single record row matching the 8-column STT CSV layout.
  String formatRecordRow({
    required Record record,
    required String activityName,
    required List<String> tagNames,
    String categories = '',
  }) {
    final startedDt = _epochToDateTime(record.startedAtEpochMs);
    final endedDt = _epochToDateTime(record.endedAtEpochMs);

    final timeStarted = formatDateTime(startedDt);
    final timeEnded = formatDateTime(endedDt);
    final durationStr = formatDuration(record.durationMs);
    final durationMinutes = formatDurationMinutes(record.durationMs);

    final quotedActivity = quoteString(activityName);
    final quotedComment = quoteString(record.comment);
    final quotedCategories = quoteString(categories);
    final quotedTags = quoteString(tagNames.join(', '));

    return '$quotedActivity,$timeStarted,$timeEnded,$quotedComment,$quotedCategories,$quotedTags,$durationStr,$durationMinutes\n';
  }

  // ==========================================
  // Serialization
  // ==========================================

  /// Generates the complete 8-column CSV content string from the database,
  /// ordered by `started_at_epoch_ms` ascending.
  Future<String> generateCsvString() async {
    final activities = await database.getAllActivities(includeArchived: true);
    final activityMap = {for (final a in activities) a.id: a};

    final allTags = await database.getAllTags();
    final tagMap = {for (final t in allTags) t.id: t.name};

    final records =
        await database.getRecords(orderBy: 'started_at_epoch_ms ASC');
    records.sort((a, b) => a.startedAtEpochMs.compareTo(b.startedAtEpochMs));

    final buffer = StringBuffer();
    buffer.write(csvHeader);
    buffer.write('\n');

    for (final record in records) {
      final activity = activityMap[record.activityId];
      final activityName = activity?.name ?? '';
      final tagNames = record.tagIds
          .map((id) => tagMap[id])
          .whereType<String>()
          .toList();

      final row = formatRecordRow(
        record: record,
        activityName: activityName,
        tagNames: tagNames,
      );
      buffer.write(row);
    }

    return buffer.toString();
  }

  // ==========================================
  // Atomic Write-Flush-Rename Pipeline
  // ==========================================

  /// Schedules a debounced export. Multiple rapid triggers within [debounceDuration]
  /// coalesce into a single file export.
  Future<File> scheduleExport() {
    if (_isDisposed) {
      throw StateError('Cannot schedule export on a disposed CsvExportEngine.');
    }

    _debounceTimer?.cancel();
    _scheduledCompleter ??= Completer<File>();

    if (debounceDuration == Duration.zero) {
      return exportImmediately();
    }

    final completer = _scheduledCompleter!;
    _lastExportFuture = completer.future;

    _debounceTimer = Timer(debounceDuration, () async {
      _debounceTimer = null;
      _scheduledCompleter = null;

      try {
        final file = await _performExport();
        completer.complete(file);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  /// Cancels any pending debounced export and immediately executes an atomic export.
  Future<File> exportImmediately() async {
    if (_isDisposed) {
      throw StateError('Cannot export on a disposed CsvExportEngine.');
    }

    _debounceTimer?.cancel();
    _debounceTimer = null;

    final completer = _scheduledCompleter;
    _scheduledCompleter = null;

    final exportAction = _performExport();
    _lastExportFuture = exportAction;

    try {
      final file = await exportAction;
      completer?.complete(file);
      return file;
    } catch (e, st) {
      completer?.completeError(e, st);
      rethrow;
    }
  }

  /// Executes the 3-step atomic export pipeline protected by a single-writer mutex:
  /// 1. Write content to sibling temporary file: `.<target_filename>.tmp.<uuid>`.
  /// 2. Flush to ensure physical byte persistence via [RandomAccessFile.flush].
  /// 3. Atomically rename/move sibling file to [targetFile].
  Future<File> _performExport() => _synchronized(() async {
        final csvContent = await generateCsvString();

        final parentDir = targetFile.parent;
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        final targetName = p.basename(targetFile.path);
        final uuid = _generateUuid();
        final tempFilePath = p.join(parentDir.path, '.$targetName.tmp.$uuid');
        final tempFile = File(tempFilePath);

        RandomAccessFile? raf;
        try {
          raf = await tempFile.open(mode: FileMode.write);
          await raf.writeString(csvContent);
          await raf.flush();
          await raf.close();
          raf = null;

          // Atomic rename: POSIX rename replaces destination file atomically.
          final renamedFile = await tempFile.rename(targetFile.path);
          await onExportCompleted?.call(renamedFile);
          return renamedFile;
        } catch (e) {
          if (raf != null) {
            try {
              await raf.close();
            } catch (_) {}
          }
          if (await tempFile.exists()) {
            try {
              await tempFile.delete();
            } catch (_) {}
          }
          rethrow;
        }
      });

  /// Single-writer mutex ensuring only one disk write executes at any time.
  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final prev = _mutexLock;
    final completer = Completer<void>();
    _mutexLock = completer.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      completer.complete();
      if (_mutexLock == completer.future) {
        _mutexLock = null;
      }
    }
  }

  /// Disposes timers and cancels any pending scheduled operations.
  void dispose() {
    _isDisposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_scheduledCompleter != null && !_scheduledCompleter!.isCompleted) {
      _scheduledCompleter!.completeError(
        StateError('CsvExportEngine was disposed.'),
      );
      _scheduledCompleter = null;
    }
  }
}
