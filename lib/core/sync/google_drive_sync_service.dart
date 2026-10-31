import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/database/tempo_database.dart';
import '../export/csv_export_engine.dart';

/// Service managing synchronization of CSV exports and database backups with Google Drive.
/// Follows BNPB and Simple Time Tracker conventions:
/// - Target folder: root-level "Time track"
/// - CSV file: "stt_records_automatic.csv"
/// - Database backup: "tempo_backup.db"
class GoogleDriveSyncService {
  static const String timeTrackFolderName = 'Time track';
  static const String defaultCsvFileName = 'stt_records_automatic.csv';
  static const String defaultBackupFileName = 'tempo_backup.db';

  static const List<String> driveScopes = [
    drive.DriveApi.driveFileScope,
    drive.DriveApi.driveAppdataScope,
  ];

  final TempoDatabase? database;
  final GoogleSignIn? googleSignIn;
  drive.DriveApi? driveApi;
  bool autoSyncEnabled;
  DateTime? _lastSyncTime;
  String? _cachedTimeTrackFolderId;
  String? _lastError;

  GoogleDriveSyncService({
    this.database,
    this.googleSignIn,
    this.driveApi,
    this.autoSyncEnabled = true,
  });

  /// Whether the user is currently signed in and Drive API is ready.
  bool get isSignedIn => driveApi != null;

  /// Timestamp of the last successful synchronization.
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Last error message encountered during synchronization, if any.
  String? get lastError => _lastError;

  drive.DriveApi _getDriveApi() {
    final api = driveApi;
    if (api == null) {
      throw StateError(
        'Google Drive API is not initialized. Please sign in first.',
      );
    }
    return api;
  }

  /// Sets or overrides the active [drive.DriveApi], useful for dependency injection and tests.
  void setDriveApi(drive.DriveApi? api) {
    driveApi = api;
  }

  /// Initiates interactive Google Sign-In with Drive scopes.
  Future<bool> signIn() async {
    try {
      final gSignIn = googleSignIn ?? GoogleSignIn.instance;
      final account = await gSignIn.authenticate(scopeHint: driveScopes);
      final authz = await account.authorizationClient.authorizeScopes(
        driveScopes,
      );
      final client = authz.authClient(scopes: driveScopes);
      driveApi = drive.DriveApi(client);
      _lastError = null;
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Google Drive Sign-In error: $e');
      return false;
    }
  }

  /// Signs out of Google Sign-In and clears API instances.
  Future<void> signOut() async {
    try {
      final gSignIn = googleSignIn ?? GoogleSignIn.instance;
      await gSignIn.signOut();
    } catch (_) {}
    driveApi = null;
    _cachedTimeTrackFolderId = null;
  }

  /// Locates or creates the "Time track" folder at the root of Google Drive.
  Future<String> ensureTimeTrackFolder() async {
    final api = _getDriveApi();
    if (_cachedTimeTrackFolderId != null) {
      return _cachedTimeTrackFolderId!;
    }

    final query =
        "mimeType = 'application/vnd.google-apps.folder' and name = '$timeTrackFolderName' and trashed = false and 'root' in parents";

    final fileList = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id, name)',
    );

    if (fileList.files != null && fileList.files!.isNotEmpty) {
      _cachedTimeTrackFolderId = fileList.files!.first.id;
      return _cachedTimeTrackFolderId!;
    }

    // Create new "Time track" folder at Google Drive root
    final folderMetadata = drive.File()
      ..name = timeTrackFolderName
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = ['root'];

    final created = await api.files.create(folderMetadata, $fields: 'id, name');

    _cachedTimeTrackFolderId = created.id!;
    return _cachedTimeTrackFolderId!;
  }

  /// Uploads or updates [csvFile] in the "Time track" folder as [fileName].
  Future<String> syncCsvToDrive(
    File csvFile, {
    String fileName = defaultCsvFileName,
  }) async {
    final api = _getDriveApi();
    final folderId = await ensureTimeTrackFolder();

    final query =
        "name = '$fileName' and '$folderId' in parents and trashed = false";
    final fileList = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id, name)',
    );

    final length = await csvFile.length();
    final media = drive.Media(csvFile.openRead(), length);

    try {
      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final existingId = fileList.files!.first.id!;
        final updated = await api.files.update(
          drive.File(),
          existingId,
          uploadMedia: media,
          $fields: 'id, name, modifiedTime',
        );
        _lastSyncTime = DateTime.now();
        _lastError = null;
        return updated.id!;
      } else {
        final newFile = drive.File()
          ..name = fileName
          ..parents = [folderId];
        final created = await api.files.create(
          newFile,
          uploadMedia: media,
          $fields: 'id, name',
        );
        _lastSyncTime = DateTime.now();
        _lastError = null;
        return created.id!;
      }
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    }
  }

  /// Backs up the local SQLite database to Google Drive "Time track" folder.
  Future<String> backupDatabaseToDrive({
    File? dbFile,
    String fileName = defaultBackupFileName,
  }) async {
    final api = _getDriveApi();
    final folderId = await ensureTimeTrackFolder();

    final fileToBackup = dbFile ?? await _resolveLocalDbFile();
    if (!await fileToBackup.exists()) {
      throw StateError('Database file does not exist at ${fileToBackup.path}');
    }

    final query =
        "name = '$fileName' and '$folderId' in parents and trashed = false";
    final fileList = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id, name)',
    );

    final length = await fileToBackup.length();
    final media = drive.Media(fileToBackup.openRead(), length);

    try {
      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final existingId = fileList.files!.first.id!;
        final updated = await api.files.update(
          drive.File(),
          existingId,
          uploadMedia: media,
          $fields: 'id, name, modifiedTime',
        );
        _lastSyncTime = DateTime.now();
        _lastError = null;
        return updated.id!;
      } else {
        final newFile = drive.File()
          ..name = fileName
          ..parents = [folderId];
        final created = await api.files.create(
          newFile,
          uploadMedia: media,
          $fields: 'id, name',
        );
        _lastSyncTime = DateTime.now();
        _lastError = null;
        return created.id!;
      }
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    }
  }

  /// Downloads the database backup from Google Drive "Time track" folder to [targetFile].
  Future<File> restoreDatabaseFromDrive({
    File? targetFile,
    String fileName = defaultBackupFileName,
  }) async {
    final api = _getDriveApi();
    final folderId = await ensureTimeTrackFolder();

    final query =
        "name = '$fileName' and '$folderId' in parents and trashed = false";
    final fileList = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id, name)',
    );

    if (fileList.files == null || fileList.files!.isEmpty) {
      throw StateError(
        'No backup file "$fileName" found in Google Drive "Time track" folder.',
      );
    }

    final backupFileId = fileList.files!.first.id!;
    final response = await api.files.get(
      backupFileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final destination = targetFile ?? await _resolveLocalDbFile();
    if (!await destination.parent.exists()) {
      await destination.parent.create(recursive: true);
    }

    final output = destination.openWrite();
    await response.stream.pipe(output);
    await output.flush();
    await output.close();

    _lastSyncTime = DateTime.now();
    _lastError = null;
    return destination;
  }

  /// Attaches this sync service to [engine] to automatically upload the CSV file on export.
  void attachToExportEngine(CsvExportEngine engine) {
    engine.onExportCompleted = (File exportedFile) async {
      if (!autoSyncEnabled || !isSignedIn) return;
      try {
        await syncCsvToDrive(exportedFile);
      } catch (e) {
        debugPrint('Auto-sync CSV to Drive failed: $e');
      }
    };
  }

  Future<File> _resolveLocalDbFile() async {
    final dbFactory = databaseFactory;
    final dbDir = await dbFactory.getDatabasesPath();
    return File(p.join(dbDir, TempoDatabase.databaseFileName));
  }
}
