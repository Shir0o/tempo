import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/export/csv_export_engine.dart';
import 'core/state/day_recorder.dart';
import 'core/sync/google_drive_sync_service.dart';
import 'core/sync/google_oauth_config.dart';
import 'data/database/tempo_database.dart';
import 'data/models/models.dart';
import 'desktop/deep_link_service.dart';
import 'desktop/menu_bar_service.dart';
import 'notification/lap_notification_service.dart';
import 'ui/tempo_app.dart';
import 'wearable/wearable_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1-4. Open the database, CSV export and the always-running Lap
  WearableSyncService? wearableSyncService;
  final (:database, :exportEngine, :dayRecorder) = await _openDayRecorder(
    // The watch tile ranks Activities by recent use, so keep its slots current.
    onRecordCommitted: (_) async {
      await wearableSyncService?.refreshActivities();
    },
  );

  // 5. Initialize Google Drive Sync Service
  await _initializeGoogleSignIn();
  final driveSyncService = GoogleDriveSyncService(database: database);
  driveSyncService.attachToExportEngine(exportEngine);

  // 6. Initialize Universal Deep Link Bus (tempo:// & timetracker://)
  DeepLinkService(dayRecorder: dayRecorder, database: database);

  // 7. Platform-specific integrations
  if (!kIsWeb) {
    if (Platform.isAndroid) {
      // Connect Wear OS Companion synchronization
      wearableSyncService = WearableSyncService(
        dayRecorder: dayRecorder,
        database: database,
      );
      wearableSyncService.initialize();
      // Sync initial activities to DataClient
      database.getAllActivities().then(wearableSyncService.syncActivities);
      // Keep the ongoing Lap notification current and handle its taps
      final lapNotificationService = LapNotificationService(
        dayRecorder: dayRecorder,
        database: database,
      );
      lapNotificationService.initialize();
      lapNotificationService.publish();
    } else if (Platform.isMacOS) {
      // Connect macOS menu bar status item
      MenuBarService(dayRecorder: dayRecorder);
    }
  }

  runApp(
    TempoApp(
      dayRecorder: dayRecorder,
      database: database,
      syncService: driveSyncService,
      exportEngine: exportEngine,
    ),
  );
}

/// Runs in a headless engine when the ongoing Lap notification is tapped while
/// the app is not running. The tap goes through the same DayRecorder setup as
/// [main]; once its UndoGraceWindow has passed and the CSV export is written,
/// Android destroys the engine.
@pragma('vm:entry-point')
Future<void> notificationActionMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel(LapNotificationService.channelName);

  final (:database, :exportEngine, :dayRecorder) = await _openDayRecorder();
  LapNotificationService(
    dayRecorder: dayRecorder,
    database: database,
    onSettled: () async {
      // The Record must reach the live CSV export before the engine goes.
      try {
        if (exportEngine.isExportScheduled) {
          await exportEngine.exportImmediately();
        } else {
          await exportEngine.lastExportFuture;
        }
      } catch (e) {
        debugPrint('CSV export after a notification action failed: $e');
      }
      await channel.invokeMethod<void>('headlessSettled');
    },
  ).initialize();
  await channel.invokeMethod<void>('headlessReady');
}

/// Opens the database and the CSV export engine and starts the DayRecorder
/// over them, so the app and a headless notification action write the Day
/// the same way.
Future<
  ({
    TempoDatabase database,
    CsvExportEngine exportEngine,
    DayRecorder dayRecorder,
  })
>
_openDayRecorder({
  Future<void> Function(Record record)? onRecordCommitted,
}) async {
  // 1. Open local SQLite database
  final database = await TempoDatabase.open();

  // 2. Seed initial starter activities if first launch
  await _seedDefaultActivitiesIfEmpty(database);

  // 3. Initialize CSV Export Engine
  Directory exportDir;
  try {
    exportDir = await getApplicationDocumentsDirectory();
  } catch (_) {
    exportDir = Directory.current;
  }
  final exportFile = File(
    p.join(exportDir.path, CsvExportEngine.defaultFileName),
  );
  final exportEngine = CsvExportEngine(
    database: database,
    targetFile: exportFile,
  );

  // 4. Open the always-running Lap
  final dayRecorder = DayRecorder(
    database: database,
    csvExportEngine: exportEngine,
    getTimezoneId: () async =>
        (await FlutterTimezone.getLocalTimezone()).identifier,
    onRecordCommitted: onRecordCommitted,
  );
  await dayRecorder.initialize();
  return (
    database: database,
    exportEngine: exportEngine,
    dayRecorder: dayRecorder,
  );
}

/// Prepares the shared [GoogleSignIn] instance before the sync service uses it.
///
/// Android identifies the app through the registered package + signing
/// fingerprints but still needs the web client ID as `serverClientId`. macOS
/// uses the iOS-type client, whose reversed ID is registered as a URL scheme
/// in `macos/Runner/Info.plist`.
Future<void> _initializeGoogleSignIn() async {
  if (kIsWeb) return;
  try {
    await GoogleSignIn.instance.initialize(
      clientId: Platform.isMacOS ? googleMacosClientId : null,
      serverClientId: Platform.isAndroid ? googleWebClientId : null,
    );
  } catch (e) {
    // Sign-in will report the failure through Settings rather than blocking
    // app startup on a cloud configuration problem.
    debugPrint('GoogleSignIn initialization failed: $e');
  }
}

Future<void> _seedDefaultActivitiesIfEmpty(TempoDatabase db) async {
  final existing = await db.getAllActivities(includeArchived: true);
  if (existing.isNotEmpty) return;

  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  const uuid = Uuid();

  final defaultActivities = [
    Activity(
      id: uuid.v4(),
      name: 'Coding',
      colorHex: '#2196F3',
      iconName: 'code',
      isPinned: true,
      sortOrder: 0,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    ),
    Activity(
      id: uuid.v4(),
      name: 'Reading',
      colorHex: '#4CAF50',
      iconName: 'book',
      isPinned: true,
      sortOrder: 1,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    ),
    Activity(
      id: uuid.v4(),
      name: 'Workout',
      colorHex: '#FF9800',
      iconName: 'fitness_center',
      isPinned: true,
      sortOrder: 2,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    ),
    Activity(
      id: uuid.v4(),
      name: 'Deep Work',
      colorHex: '#9C27B0',
      iconName: 'work',
      isPinned: true,
      sortOrder: 3,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    ),
    Activity(
      id: uuid.v4(),
      name: 'General',
      colorHex: '#607D8B',
      iconName: 'schedule',
      isPinned: false,
      sortOrder: 4,
      isArchived: false,
      createdAtEpochMs: now,
      updatedAtEpochMs: now,
    ),
  ];

  for (final act in defaultActivities) {
    await db.insertActivity(act);
  }
}
