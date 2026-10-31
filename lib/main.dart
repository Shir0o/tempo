import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/export/csv_export_engine.dart';
import 'core/state/timer_state_machine.dart';
import 'core/sync/google_drive_sync_service.dart';
import 'data/database/tempo_database.dart';
import 'data/models/models.dart';
import 'desktop/deep_link_service.dart';
import 'desktop/menu_bar_service.dart';
import 'ui/tempo_app.dart';
import 'wearable/wearable_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // 4. Initialize Core Timer State Machine
  final timerStateMachine = TimerStateMachine(
    database: database,
    csvExportEngine: exportEngine,
  );

  // Check for boot-up crash recovery (>6 hours) and resume or recover
  final crashSession = await timerStateMachine.checkCrashRecovery();
  if (crashSession != null) {
    // By default, truncate to last heartbeat on boot if abnormal shutdown
    try {
      await crashSession.truncateToHeartbeat();
    } catch (_) {}
  } else {
    await timerStateMachine.initialize();
  }

  // 5. Initialize Google Drive Sync Service
  final driveSyncService = GoogleDriveSyncService(database: database);
  driveSyncService.attachToExportEngine(exportEngine);

  // 6. Initialize Universal Deep Link Bus (tempo:// & timetracker://)
  DeepLinkService(timerStateMachine: timerStateMachine, database: database);

  // 7. Platform-specific integrations
  if (!kIsWeb) {
    if (Platform.isAndroid) {
      // Connect Wear OS Companion synchronization
      final wearableSyncService = WearableSyncService(
        timerStateMachine: timerStateMachine,
        database: database,
      );
      wearableSyncService.initialize();
      // Sync initial activities to DataClient
      database.getAllActivities().then(wearableSyncService.syncActivities);
    } else if (Platform.isMacOS) {
      // Connect macOS menu bar status item
      MenuBarService(timerStateMachine: timerStateMachine, database: database);
    }
  }

  runApp(
    TempoApp(
      timerStateMachine: timerStateMachine,
      database: database,
      syncService: driveSyncService,
      exportEngine: exportEngine,
    ),
  );
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
