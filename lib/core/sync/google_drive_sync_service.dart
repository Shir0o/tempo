import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

import '../../data/database/tempo_database.dart';
import '../export/csv_export_engine.dart';

/// Obtains a Drive API bound to a freshly authorized access token.
typedef DriveReauthorizer = Future<drive.DriveApi> Function();

/// Raised when Drive rejects the cached access token and a new one cannot be
/// obtained without the user signing in again.
class GoogleDriveAccessExpiredException implements Exception {
  const GoogleDriveAccessExpiredException();

  @override
  String toString() =>
      'Google Drive access has expired. Reconnect to continue.';
}

/// Service managing synchronization of CSV exports with Google Drive.
/// Follows BNPB and Simple Time Tracker conventions:
/// - Target folder: root-level "Time track"
/// - CSV file: "stt_records_automatic.csv"
///
/// Database backup and restore are not part of this service: recovery lives in
/// `BackupService`, which snapshots the store and promotes verified generations
/// to a folder the user chooses.
class GoogleDriveSyncService {
  static const String timeTrackFolderName = 'Time track';
  static const String defaultCsvFileName = 'stt_records_automatic.csv';

  static const List<String> driveScopes = [
    drive.DriveApi.driveFileScope,
    drive.DriveApi.driveAppdataScope,
  ];

  final TempoDatabase? database;
  final GoogleSignIn? googleSignIn;

  /// Overrides how a fresh Drive client is obtained after the access token
  /// expires; tests inject a client on a fake transport.
  final DriveReauthorizer? reauthorize;
  drive.DriveApi? driveApi;
  GoogleSignInAccount? _account;
  bool autoSyncEnabled;
  DateTime? _lastSyncTime;
  String? _cachedTimeTrackFolderId;
  String? _lastError;

  GoogleDriveSyncService({
    this.database,
    this.googleSignIn,
    this.driveApi,
    this.autoSyncEnabled = true,
    this.reauthorize,
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
      _account = account;
      driveApi = drive.DriveApi(authz.authClient(scopes: driveScopes));
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
    _account = null;
    driveApi = null;
    _cachedTimeTrackFolderId = null;
  }

  /// Runs [action] with the Drive API, renewing the access token once if Google
  /// rejects the cached one as expired.
  ///
  /// Access tokens live about an hour, but [signIn] caches a client that never
  /// refreshes, so the first call after expiry comes back as a 401 surfaced by
  /// `googleapis_auth` as [gapis.AccessDeniedException].
  Future<T> _withDriveApi<T>(
    Future<T> Function(drive.DriveApi api) action,
  ) async {
    try {
      return await action(_getDriveApi());
    } on gapis.AccessDeniedException {
      driveApi = await (reauthorize ?? _reauthorizeFromAccount)();
      return await action(_getDriveApi());
    }
  }

  /// Asks the signed-in account for a new access token without prompting.
  ///
  /// `authorizationForScopes` returns null when Google needs the user to
  /// interact; that (and a missing account) means the user has to reconnect.
  Future<drive.DriveApi> _reauthorizeFromAccount() async {
    final account = _account;
    if (account != null) {
      final authz = await account.authorizationClient.authorizationForScopes(
        driveScopes,
      );
      if (authz != null) {
        return driveApi = drive.DriveApi(authz.authClient(scopes: driveScopes));
      }
    }
    driveApi = null;
    throw const GoogleDriveAccessExpiredException();
  }

  /// Locates or creates the "Time track" folder at the root of Google Drive.
  Future<String> ensureTimeTrackFolder() =>
      _withDriveApi(_ensureTimeTrackFolder);

  Future<String> _ensureTimeTrackFolder(drive.DriveApi api) async {
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
    try {
      return await _withDriveApi((api) async {
        final folderId = await _ensureTimeTrackFolder(api);

        final query =
            "name = '$fileName' and '$folderId' in parents and trashed = false";
        final fileList = await api.files.list(
          q: query,
          spaces: 'drive',
          $fields: 'files(id, name)',
        );

        // Built per attempt: a rejected upload may have consumed the stream.
        final media = drive.Media(csvFile.openRead(), await csvFile.length());

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
      });
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    }
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
}
