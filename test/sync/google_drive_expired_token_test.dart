import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:http/http.dart' as http;
import 'package:tempo/core/sync/google_drive_sync_service.dart';

/// Answers Drive requests like Google does, rejecting the expired token with a
/// 401 + `www-authenticate` header (which `googleapis_auth` turns into
/// `AccessDeniedException: Access was denied ...`).
///
/// Folder lookups are served even for the stale token so the test reaches the
/// upload, where the expired token is rejected.
class ExpiredTokenDriveClient extends http.BaseClient {
  ExpiredTokenDriveClient({required this.freshToken});

  final String freshToken;
  final List<String> authorizationHeaders = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final authorization = request.headers['authorization'] ?? '<none>';
    authorizationHeaders.add(authorization);
    final authorized = authorization == 'Bearer $freshToken';

    if (request.method == 'GET') {
      return _json({
        'files': [
          {'id': 'folder-1', 'name': 'Time track'},
        ],
      });
    }

    if (!authorized) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"error":{"code":401}}')),
        401,
        headers: {
          'content-type': 'application/json',
          'www-authenticate':
              'Bearer realm="https://accounts.google.com/", '
              'error="invalid_token", '
              'error_description="Invalid Credentials"',
        },
      );
    }

    return _json({'id': 'backup-1', 'name': 'tempo_backup.db'});
  }

  http.StreamedResponse _json(Map<String, dynamic> body) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        200,
        headers: {'content-type': 'application/json'},
      );
}

drive.DriveApi _driveApi(http.Client transport, String accessToken) {
  final credentials = gapis.AccessCredentials(
    gapis.AccessToken(
      'Bearer',
      accessToken,
      DateTime.now().toUtc().add(const Duration(days: 365)),
    ),
    null,
    GoogleDriveSyncService.driveScopes,
  );
  return drive.DriveApi(gapis.authenticatedClient(transport, credentials));
}

void main() {
  late Directory tempDir;
  late File dbFile;
  late ExpiredTokenDriveClient transport;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tempo_expired_token_');
    dbFile = File('${tempDir.path}/tempo.db');
    await dbFile.writeAsString('SQLITE_MOCK_DATABASE_CONTENT');
    transport = ExpiredTokenDriveClient(freshToken: 'fresh-token');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('CSV sync renews an expired access token and retries once', () async {
    var renewals = 0;
    final service = GoogleDriveSyncService(
      driveApi: _driveApi(transport, 'expired-token'),
      reauthorize: () async {
        renewals++;
        return _driveApi(transport, 'fresh-token');
      },
    );

    final fileId = await service.syncCsvToDrive(dbFile);

    expect(fileId, 'backup-1');
    expect(renewals, 1);
    expect(service.lastSyncTime, isNotNull);
    expect(service.lastError, isNull);
    // The rejected token was used once, then the retry carried the new one.
    expect(transport.authorizationHeaders, contains('Bearer expired-token'));
    expect(transport.authorizationHeaders.last, 'Bearer fresh-token');
  });

  test(
    'CSV sync reports a reconnect message when renewal is unavailable',
    () async {
      final service = GoogleDriveSyncService(
        driveApi: _driveApi(transport, 'expired-token'),
        reauthorize: () async =>
            throw const GoogleDriveAccessExpiredException(),
      );

      await expectLater(
        service.syncCsvToDrive(dbFile),
        throwsA(
          predicate(
            (e) => e.toString().contains(
              'Google Drive access has expired. Reconnect to continue.',
            ),
          ),
        ),
      );
    },
  );

  test(
    'without a signed-in account the session is cleared for reconnect',
    () async {
      final service = GoogleDriveSyncService(
        driveApi: _driveApi(transport, 'expired-token'),
      );

      await expectLater(
        service.syncCsvToDrive(dbFile),
        throwsA(isA<GoogleDriveAccessExpiredException>()),
      );
      expect(service.isSignedIn, isFalse);
    },
  );
}
