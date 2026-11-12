import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/backup/backup_destination.dart';
import 'core/backup/backup_service.dart';
import 'core/export/csv_export_engine.dart';
import 'core/speech/speech_input.dart';
import 'core/state/day_recorder.dart';
import 'core/state/record_commands.dart';
import 'core/sync/discovery.dart';
import 'core/sync/google_drive_sync_service.dart';
import 'core/sync/google_oauth_config.dart';
import 'core/sync/intent_queue.dart';
import 'core/sync/peer_pairing.dart';
import 'core/sync/replica_applier.dart';
import 'core/sync/sync_client.dart';
import 'core/sync/sync_listener.dart';
import 'data/database/store_lifecycle.dart';
import 'data/database/tempo_database.dart';
import 'data/models/models.dart';
import 'desktop/deep_link_service.dart';
import 'desktop/menu_bar_service.dart';
import 'notification/lap_notification_service.dart';
import 'ui/tempo_app.dart';
import 'wearable/wearable_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The Mac is a read replica. It opens the phone's tables and proposes
  // intents instead; a DayRecorder here would create a Lap and midnight
  // splits, making the Mac a second writer.
  if (!kIsWeb && Platform.isMacOS) {
    await _startReplica();
    return;
  }

  // 1-4. Open the database, CSV export and the always-running Lap
  WearableSyncService? wearableSyncService;
  SyncListener? syncListener;
  PeerPairing? pairing;
  final storeLifecycle = StoreLifecycle.instance;
  final (:database, :exportEngine, :dayRecorder) = await _openDayRecorder(
    storeLifecycle: storeLifecycle,
    // The watch tile ranks Activities by recent use, so keep its slots current.
    onRecordCommitted: (_) async {
      // A held change request on the Mac completes the moment a Record lands.
      syncListener?.notifyChanged();
      await wearableSyncService?.refreshActivities();
    },
  );
  final commands = PhoneRecordCommands(dayRecorder: dayRecorder);

  // 5. Initialize Google Drive Sync Service
  await _initializeGoogleSignIn();
  final driveSyncService = GoogleDriveSyncService(database: database);
  driveSyncService.attachToExportEngine(exportEngine);

  // 6. Automatic backup: local rolling snapshot, promoted to the destination
  final backupService = BackupService(
    database: database,
    lifecycle: storeLifecycle,
    destinationLoader: openBackupDestination,
  );
  backupService.startScheduler();
  WidgetsBinding.instance.addObserver(_BackupPauseObserver(backupService));

  // 7. Initialize Universal Deep Link Bus (tempo:// & timetracker://)
  DeepLinkService(
    commands: commands,
    database: database,
    createMissingTags: !Platform.isMacOS,
  );

  // 8. Platform-specific integrations
  if (!kIsWeb) {
    if (Platform.isAndroid) {
      // The phone is the single writer: it serves the change feed and applies
      // every intent the Mac and the watch send.
      final phonePairing = PeerPairing(
        database: database,
        secrets: const PlatformPeerSecretStore(),
      );
      pairing = phonePairing;
      await _applyPendingRestoreIdentity(database, phonePairing);
      syncListener = SyncListener(
        database: database,
        dayRecorder: dayRecorder,
        pairing: phonePairing,
        advertiser: BonsoirPeerAdvertiser(),
      );
      try {
        // `replicate_enabled` alone gates the listener; an unpaired client is
        // still refused 401, so the phone may listen before any Mac is paired.
        await syncListener.applyReplicationSetting();
      } catch (e) {
        // The phone still records the day when the port is taken; the Mac
        // reports that it is waiting for the phone.
        debugPrint('SyncListener failed to start: $e');
      }
      // Connect Wear OS Companion synchronization
      wearableSyncService = WearableSyncService(
        dayRecorder: dayRecorder,
        database: database,
      );
      // Start listening before the first frame, but do not hold the UI on the
      // startup replay of watch actions and the watch flush.
      unawaited(wearableSyncService.initialize());
      // Sync initial activities to DataClient
      database.getAllActivities().then(wearableSyncService.syncActivities);
      // Keep the ongoing Lap notification current and handle its taps
      final lapNotificationService = LapNotificationService(
        dayRecorder: dayRecorder,
        database: database,
      );
      lapNotificationService.initialize();
      lapNotificationService.publish();
    }
  }

  final isAndroid = !kIsWeb && Platform.isAndroid;
  final SpeechInput? speechInput = isAndroid
      ? const MethodChannelSpeechInput()
      : null;

  runApp(
    TempoApp(
      commands: commands,
      dayRecorder: dayRecorder,
      database: database,
      pairing: pairing,
      syncListener: syncListener,
      syncService: driveSyncService,
      backupService: backupService,
      exportEngine: exportEngine,
      showActivityFilter: isAndroid,
      speechInput: speechInput,
    ),
  );
}

/// Starts the Mac's side of replication: the phone's tables as a replica, the
/// durable intent queue, and the client that pulls changes and sends
/// proposals.
///
/// There is no DayRecorder, no CSV exporter, and no backup scheduler here.
/// Every mutation becomes an intent, and only the phone turns one into a
/// Record.
Future<void> _startReplica() async {
  await StoreLifecycle.instance.assertUnlocked();
  final database = await TempoDatabase.open();

  final queue = IntentQueue(database);
  await queue.ensureTable();
  final pairing = PeerPairing(
    database: database,
    secrets: const PlatformPeerSecretStore(),
  );
  final client = SyncClient(
    database: database,
    pairing: pairing,
    applier: ReplicaApplier(database),
    queue: queue,
    discovery: BonsoirPeerDiscovery(),
  );
  final commands = RemoteRecordCommands(
    database: database,
    queue: queue,
    // The intent is already durable; exchanging now means its answer arrives
    // without waiting for the next poll.
    onQueued: () async => client.notifyIntentQueued(),
  );

  // Same rule as the phone: the flag gates replication, never the store, so
  // the Day renders from an idle replica.
  await client.applyReplicationSetting();
  final menuBar = MenuBarService(commands: commands, database: database);
  // A finished pull may have moved the Lap; refresh the status item at once
  // instead of waiting for its minute's replica read.
  client.status.addListener(() {
    if (client.status.value == SyncClientStatus.upToDate) {
      unawaited(menuBar.refreshLap());
    }
  });
  // Deep links arrive through the same command seam as the UI: `start` queues a
  // label at the current time and `split` queues a split.
  DeepLinkService(
    commands: commands,
    database: database,
    createMissingTags: !Platform.isMacOS,
  );
  runApp(
    TempoApp(
      commands: commands,
      database: database,
      intentQueue: queue,
      syncClient: client,
      pairing: pairing,
    ),
  );
}

/// The first start after a restore reissues this device's identity: the store
/// is now the snapshot's, and keeping its `device_id` and `log_epoch` would let
/// a paired Mac keep a cursor into a log that no longer exists.
Future<void> _applyPendingRestoreIdentity(
  TempoDatabase database,
  PeerPairing pairing,
) async {
  final pending = await database.getSetting(
    BackupService.restorePendingSetting,
  );
  if (pending != 'true') return;

  await database.setSetting(SyncSettingKeys.deviceId, const Uuid().v4());
  await database.setSetting(SyncSettingKeys.logEpoch, const Uuid().v4());
  await pairing.rotateOnRestore();
  await database.setSetting(BackupService.restorePendingSetting, '');
  debugPrint(
    'Tempo: restored store adopted; device_id and log_epoch renewed, '
    'paired devices must pair again',
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

  final (:database, :exportEngine, :dayRecorder) = await _openDayRecorder(
    storeLifecycle: StoreLifecycle.instance,
  );
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
///
/// The store is only opened when no restore holds the advisory lock: a restore
/// swaps the file while this process is starting up, and opening it mid-swap
/// would bring back a store that is about to be replaced.
Future<
  ({
    TempoDatabase database,
    CsvExportEngine exportEngine,
    DayRecorder dayRecorder,
  })
>
_openDayRecorder({
  StoreLifecycle? storeLifecycle,
  Future<void> Function(Record record)? onRecordCommitted,
}) async {
  final lifecycle = storeLifecycle ?? StoreLifecycle.instance;
  await lifecycle.assertUnlocked();

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

/// Promotes a snapshot when the app leaves the foreground, so a phone left in
/// a pocket for the evening still has a fresh generation in the chosen folder.
class _BackupPauseObserver extends WidgetsBindingObserver {
  final BackupService backupService;

  _BackupPauseObserver(this.backupService);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(backupService.onAppPause());
    }
  }
}
