import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:tempo/core/export/csv_export_engine.dart';
import 'package:tempo/core/sync/google_drive_sync_service.dart';
import 'package:tempo/data/database/tempo_database.dart';

class MockDriveHttpClient extends http.BaseClient {
  List<Map<String, dynamic>> driveFiles = [];
  final List<http.BaseRequest> recordedRequests = [];
  String? downloadMediaContent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    recordedRequests.add(request);
    final url = request.url.toString();
    final method = request.method.toUpperCase();

    // 1. Files.list: GET /drive/v3/files?q=...
    if (method == 'GET' &&
        url.contains('/drive/v3/files') &&
        !url.contains('alt=media')) {
      final qParam = request.url.queryParameters['q'] ?? '';
      List<Map<String, dynamic>> matched = [];

      if (qParam.contains("name = 'Time track'")) {
        matched = driveFiles.where((f) => f['name'] == 'Time track').toList();
      } else if (qParam.contains("name = 'stt_records_automatic.csv'")) {
        matched = driveFiles
            .where((f) => f['name'] == 'stt_records_automatic.csv')
            .toList();
      } else if (qParam.contains("name = 'tempo_backup.db'")) {
        matched = driveFiles
            .where((f) => f['name'] == 'tempo_backup.db')
            .toList();
      } else {
        matched = List.from(driveFiles);
      }

      final body = jsonEncode({'files': matched});
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    // 2. Download media: GET /drive/v3/files/{id}?alt=media
    if (method == 'GET' && url.contains('alt=media')) {
      final content = downloadMediaContent ?? 'MOCK_DATABASE_BINARY_DATA';
      return http.StreamedResponse(
        Stream.value(utf8.encode(content)),
        200,
        headers: {'content-type': 'application/octet-stream'},
      );
    }

    // 3. Create file or folder: POST (multipart or standard)
    if (method == 'POST' && url.contains('/files')) {
      // Create folder or file
      String name = 'untitled';
      String mimeType = 'text/plain';
      String id =
          'id-${DateTime.now().millisecondsSinceEpoch}-${driveFiles.length}';

      final bodyBytes = await request.finalize().toBytes();
      final bodyString = utf8.decode(bodyBytes, allowMalformed: true);
      try {
        final parsed = jsonDecode(bodyString) as Map<String, dynamic>;
        name = parsed['name'] as String? ?? name;
        mimeType = parsed['mimeType'] as String? ?? mimeType;
      } catch (_) {
        if (bodyString.contains('"name":"Time track"') ||
            bodyString.contains('"name": "Time track"')) {
          name = 'Time track';
          mimeType = 'application/vnd.google-apps.folder';
        } else if (bodyString.contains('stt_records_automatic.csv')) {
          name = 'stt_records_automatic.csv';
        } else if (bodyString.contains('tempo_backup.db')) {
          name = 'tempo_backup.db';
        }
      }

      final newFile = {'id': id, 'name': name, 'mimeType': mimeType};
      driveFiles.add(newFile);

      final body = jsonEncode(newFile);
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    // 4. Update file: PATCH or PUT to /files/{id}
    if ((method == 'PATCH' || method == 'PUT') && url.contains('/files/')) {
      final segments = request.url.pathSegments;
      final fileId = segments.isNotEmpty ? segments.last : 'updated-id';
      final body = jsonEncode({
        'id': fileId,
        'name': 'updated',
        'modifiedTime': DateTime.now().toIso8601String(),
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    // Default 200 OK
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  group('GoogleDriveSyncService Unit Tests', () {
    late Directory tempDir;
    late MockDriveHttpClient mockClient;
    late drive.DriveApi driveApi;
    late GoogleDriveSyncService syncService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tempo_gdrive_test_');
      mockClient = MockDriveHttpClient();
      driveApi = drive.DriveApi(mockClient);
      syncService = GoogleDriveSyncService(driveApi: driveApi);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('ensureTimeTrackFolder creates folder at root if not found', () async {
      expect(mockClient.driveFiles, isEmpty);

      final folderId = await syncService.ensureTimeTrackFolder();
      expect(folderId, isNotEmpty);
      expect(mockClient.driveFiles.length, 1);
      expect(mockClient.driveFiles.first['name'], 'Time track');
    });

    test(
      'ensureTimeTrackFolder returns existing folder id if present',
      () async {
        mockClient.driveFiles.add({
          'id': 'existing-folder-999',
          'name': 'Time track',
          'mimeType': 'application/vnd.google-apps.folder',
        });

        final folderId = await syncService.ensureTimeTrackFolder();
        expect(folderId, 'existing-folder-999');
      },
    );

    test('syncCsvToDrive uploads CSV file into Time track folder', () async {
      final csvFile = File('${tempDir.path}/stt_records_automatic.csv');
      await csvFile.writeAsString(
        'activity name,time started,time ended,duration\nCoding,10:00,11:00,60',
      );

      final fileId = await syncService.syncCsvToDrive(csvFile);
      expect(fileId, isNotEmpty);
      expect(syncService.lastSyncTime, isNotNull);
      expect(syncService.lastError, isNull);
    });

    test(
      'backupDatabaseToDrive and restoreDatabaseFromDrive round-trip',
      () async {
        final dummyDb = File('${tempDir.path}/tempo.db');
        await dummyDb.writeAsString('SQLITE_MOCK_DATABASE_CONTENT');

        // Backup
        final backupId = await syncService.backupDatabaseToDrive(
          dbFile: dummyDb,
        );
        expect(backupId, isNotEmpty);
        expect(syncService.lastError, isNull);

        // Setup mock restore content
        mockClient.downloadMediaContent = 'RESTORED_SQLITE_CONTENT';
        mockClient.driveFiles.add({'id': backupId, 'name': 'tempo_backup.db'});

        // Restore
        final restoredFile = File('${tempDir.path}/restored_tempo.db');
        final resultFile = await syncService.restoreDatabaseFromDrive(
          targetFile: restoredFile,
        );

        expect(await resultFile.exists(), isTrue);
        expect(await resultFile.readAsString(), 'RESTORED_SQLITE_CONTENT');
      },
    );

    test(
      'attachToExportEngine triggers automatic CSV sync upon export',
      () async {
        final db = await TempoDatabase.openInMemory();
        final csvTarget = File('${tempDir.path}/export_test.csv');
        final exportEngine = CsvExportEngine(
          database: db,
          targetFile: csvTarget,
        );

        syncService.attachToExportEngine(exportEngine);

        // Trigger export
        final exported = await exportEngine.exportImmediately();
        expect(await exported.exists(), isTrue);
        expect(syncService.lastSyncTime, isNotNull);

        await db.close();
      },
    );
  });
}
