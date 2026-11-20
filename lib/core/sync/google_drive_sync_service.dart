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
/// - Target folder: root-level "Time track"
/// - CSV file: "tempo_records_automatic.csv"
///
/// Database backup and restore are not part of this service: recovery lives in
/// `BackupService`, which snapshots the store and promotes verified generations
/// to a folder the user chooses.
class GoogleDriveSyncService {
  static const String timeTrackFolderName = 'Time track';
  static const String defaultCsvFileName = 'tempo_records_automatic.csv';

  /// The CSV's name before it was renamed. An existing file by this name is
  /// renamed in place on the next upload, so the folder keeps one CSV.
  static const String legacyCsvFileName = 'stt_records_automatic.csv';

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

  /// Tail of the upload queue: one upload at a time, so a manual sync and an
  /// automatic one cannot both find no CSV and each create one.
  Future<void>? _uploadQueue;

  /// The bytes and file id of the last successful upload, so an export whose
  /// CSV did not change (an Untracked Split, a repeated manual sync) is not
  /// sent again as a new Drive revision.
  Uint8List? _lastUploadedBytes;
  String? _lastUploadedFileId;

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

  /// Set while the user has Drive connected, so a relaunch knows it may ask
  /// Google for the previous session without showing an account sheet.
  static const String connectedSetting = 'google_drive_connected';

  Future<bool>? _restoreAttempt;

  /// Restores the session saved by the last [signIn] without user interaction.
  ///
  /// Called at launch and again when Settings opens; both share one attempt.
  /// Gated on [connectedSetting] because Android's lightweight path falls back
  /// to an account sheet when no previously authorized account exists, and
  /// people who never connected Drive must not see that at startup.
  Future<bool> restorePreviousSession() =>
      _restoreAttempt ??= _restorePreviousSession();

  Future<bool> _restorePreviousSession() async {
    try {
      final db = database;
      if (db == null) return false;
      if (await db.getSetting(connectedSetting) != 'true') return false;

      final gSignIn = googleSignIn ?? GoogleSignIn.instance;
      final attempt = gSignIn.attemptLightweightAuthentication();
      // Web reports a restored sign-in on the authentication events stream.
      if (attempt == null) return false;
      final account = await attempt;
      if (account == null) return false;

      // Kept so an expired access token can still be renewed later.
      _account = account;
      final authz = await account.authorizationClient.authorizationForScopes(
        driveScopes,
      );
      if (authz == null) {
        _lastError = 'Google Drive needs to be reconnected.';
        return false;
      }
      driveApi = drive.DriveApi(authz.authClient(scopes: driveScopes));
      _lastError = null;
      return true;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Google Drive session restore failed: $e');
      return false;
    }
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
      await database?.setSetting(connectedSetting, 'true');
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
    _lastUploadedBytes = null;
    _lastUploadedFileId = null;
    _restoreAttempt = null;
    await database?.setSetting(connectedSetting, 'false');
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

    // Oldest first, so an earlier duplicate always resolves to the same one.
    final fileList = await api.files.list(
      q: query,
      spaces: 'drive',
      orderBy: 'createdTime',
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
  }) {
    final previous = _uploadQueue;
    final upload = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      return _syncCsvToDrive(csvFile, fileName);
    }();
    _uploadQueue = upload;
    return upload;
  }

  Future<String> _syncCsvToDrive(File csvFile, String fileName) async {
    try {
      // Read once: the export engine may rename a newer CSV over this path
      // mid-upload, and a stream of one file sized by another fails.
      final bytes = await csvFile.readAsBytes();
      final lastId = _lastUploadedFileId;
      if (lastId != null &&
          fileName == defaultCsvFileName &&
          listEquals(bytes, _lastUploadedBytes)) {
        _lastSyncTime = DateTime.now();
        _lastError = null;
        return lastId;
      }

      final id = await _withDriveApi((api) async {
        final folderId = await _ensureTimeTrackFolder(api);

        Future<drive.FileList> findByName(String name) => api.files.list(
          q: "name = '$name' and '$folderId' in parents and trashed = false",
          spaces: 'drive',
          orderBy: 'createdTime',
          $fields: 'files(id, name)',
        );

        var fileList = await findByName(fileName);
        // Renamed below, so it keeps its id and revision history.
        var renameFromLegacy = false;
        if ((fileList.files?.isEmpty ?? true) &&
            fileName == defaultCsvFileName) {
          fileList = await findByName(legacyCsvFileName);
          renameFromLegacy = fileList.files?.isNotEmpty ?? false;
        }

        // Built per attempt: a rejected upload may have consumed the stream.
        final media = drive.Media(Stream.value(bytes), bytes.length);

        if (fileList.files != null && fileList.files!.isNotEmpty) {
          final existingId = fileList.files!.first.id!;
          final updated = await api.files.update(
            renameFromLegacy ? (drive.File()..name = fileName) : drive.File(),
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
      if (fileName == defaultCsvFileName) {
        _lastUploadedBytes = bytes;
        _lastUploadedFileId = id;
      }
      return id;
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
