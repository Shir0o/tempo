import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/day_recorder.dart';
import 'package:tempo/core/sync/discovery.dart';
import 'package:tempo/core/sync/intent_queue.dart';
import 'package:tempo/core/sync/peer_pairing.dart';
import 'package:tempo/core/sync/replica_applier.dart';
import 'package:tempo/core/sync/sync_client.dart';
import 'package:tempo/core/sync/sync_listener.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/ui/settings_view.dart';

/// Records what Settings asks of the client, without dialling anything.
class _RecordingSyncClient extends SyncClient {
  int applyCalls = 0;
  int pullCalls = 0;

  _RecordingSyncClient({
    required super.database,
    required super.pairing,
    required super.applier,
    required super.queue,
    required super.discovery,
  });

  @override
  Future<bool> applyReplicationSetting() async {
    applyCalls++;
    return true;
  }

  @override
  Future<SyncPullResult> pull() async {
    pullCalls++;
    return const SyncPullResult(changesApplied: 0, appliedSeq: 0);
  }

  @override
  Future<SyncClientStats> stats() async => const SyncClientStats(
    status: SyncClientStatus.idle,
    appliedSeq: 0,
    lastSuccessEpochMs: 0,
    changesApplied: 0,
    intentsApplied: 0,
    intentsRejected: 0,
    intentsPending: 0,
  );
}

/// A camera the test can render without a platform plugin.
class _FakeMobileScannerPlatform extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream =>
      const Stream<BarcodeCapture?>.empty();

  @override
  Stream<TorchState> get torchStateStream => const Stream<TorchState>.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream<double>.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        size: Size(200, 200),
        numberOfCameras: 1,
      );

  @override
  Widget buildCameraView() => const SizedBox.square(dimension: 100);

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}
}

/// The phone's services, held together so a test can start and stop them.
class _Phone {
  final TempoDatabase database;
  final DayRecorder recorder;
  final PeerPairing pairing;
  final SyncListener listener;

  const _Phone({
    required this.database,
    required this.recorder,
    required this.pairing,
    required this.listener,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    MobileScannerPlatform.instance = _FakeMobileScannerPlatform();
    // The Mac asks its own native side for camera access before drawing the
    // scanner; without an answer the page stays on its placeholder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tempo/camera_permission'),
          (call) async => switch (call.method) {
            'status' || 'request' => 'authorized',
            _ => null,
          },
        );
  });

  Future<TempoDatabase> openStore() =>
      TempoDatabase.openInMemory(factory: databaseFactoryFfiNoIsolate);

  Future<_Phone> openPhone() async {
    final database = await openStore();
    final recorder = DayRecorder(
      database: database,
      autoSplitAtMidnight: false,
    );
    await recorder.initialize();
    final pairing = PeerPairing(
      database: database,
      secrets: InMemoryPeerSecretStore(),
    );
    final listener = SyncListener(
      database: database,
      dayRecorder: recorder,
      pairing: pairing,
      host: '127.0.0.1',
      port: 0,
    );
    return _Phone(
      database: database,
      recorder: recorder,
      pairing: pairing,
      listener: listener,
    );
  }

  Future<void> closePhone(_Phone phone) async {
    await phone.listener.stop();
    phone.recorder.dispose();
    await phone.database.close();
  }

  /// Lets a real HTTP bind or close finish inside the test's fake clock; a
  /// pump alone cannot advance dart:io.
  Future<void> letListenerWork(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  /// Settings keeps replication one level down, under "Mac & devices" on the
  /// phone and "Phone & devices" on the Mac.
  Future<void> openDevices(WidgetTester tester) async {
    final row = find.textContaining(' & devices');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Widget settings({
    required TempoDatabase database,
    SyncListener? listener,
    SyncClient? client,
    PeerPairing? pairing,
    DayRecorder? recorder,
  }) {
    return MaterialApp(
      home: SettingsView(
        database: database,
        dayRecorder: recorder,
        syncListener: listener,
        syncClient: client,
        pairing: pairing,
        lanAddressResolver: () async => '127.0.0.1',
      ),
    );
  }

  testWidgets('replication switch persists and starts the phone listener', (
    tester,
  ) async {
    final phone = await openPhone();
    addTearDown(() => closePhone(phone));

    await tester.pumpWidget(
      settings(
        database: phone.database,
        listener: phone.listener,
        pairing: phone.pairing,
        recorder: phone.recorder,
      ),
    );
    await tester.pumpAndSettle();
    await openDevices(tester);

    expect(phone.listener.isRunning, isFalse);

    await tester.tap(find.byType(Switch));
    await letListenerWork(tester);

    expect(
      await phone.database.getSetting(SyncSettingKeys.replicateEnabled),
      'true',
    );
    expect(phone.listener.isRunning, isTrue);
    expect(find.textContaining('waiting for a paired device'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await letListenerWork(tester);

    expect(
      await phone.database.getSetting(SyncSettingKeys.replicateEnabled),
      'false',
    );
    expect(phone.listener.isRunning, isFalse);
  });

  testWidgets('pairing from the phone starts the listener and shows a code', (
    tester,
  ) async {
    final phone = await openPhone();
    addTearDown(() => closePhone(phone));

    await tester.pumpWidget(
      settings(
        database: phone.database,
        listener: phone.listener,
        pairing: phone.pairing,
        recorder: phone.recorder,
      ),
    );
    await tester.pumpAndSettle();
    await openDevices(tester);

    await tester.tap(find.text('Pair a device'));
    await letListenerWork(tester);

    expect(phone.listener.isRunning, isTrue);
    expect(find.text('Pair this Mac'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('${phone.listener.boundPort}'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Revoke all'), findsOneWidget);

    // The server's idle timeout is a timer in the test's fake clock; close it
    // before the body ends or the binding reports a pending timer.
    await tester.runAsync(phone.listener.stop);
    await tester.pumpAndSettle();
  });

  testWidgets('replication switch on the Mac updates the client', (
    tester,
  ) async {
    final database = await openStore();
    final pairing = PeerPairing(
      database: database,
      secrets: InMemoryPeerSecretStore(),
    );
    final queue = IntentQueue(database);
    final client = _RecordingSyncClient(
      database: database,
      pairing: pairing,
      applier: ReplicaApplier(database),
      queue: queue,
      discovery: FakePeerDiscovery(),
    );
    addTearDown(() async {
      client.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      settings(database: database, client: client, pairing: pairing),
    );
    await tester.pumpAndSettle();
    await openDevices(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(await database.getSetting(SyncSettingKeys.replicateEnabled), 'true');
    expect(client.applyCalls, 1);
  });

  testWidgets('pairing on the Mac pulls as soon as the phone is adopted', (
    tester,
  ) async {
    final database = await openStore();
    final pairing = PeerPairing(
      database: database,
      secrets: InMemoryPeerSecretStore(),
    );
    final queue = IntentQueue(database);
    final client = _RecordingSyncClient(
      database: database,
      pairing: pairing,
      applier: ReplicaApplier(database),
      queue: queue,
      discovery: FakePeerDiscovery(),
    );
    addTearDown(() async {
      client.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      settings(database: database, client: client, pairing: pairing),
    );
    await tester.pumpAndSettle();
    await openDevices(tester);

    final pairRow = find.text('Pair a phone');
    await tester.ensureVisible(pairRow);
    await tester.pumpAndSettle();
    await tester.tap(pairRow);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Type the details instead'));
    await tester.pumpAndSettle();

    final storeId = (await database.getSyncSettings()).storeId;
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '8727');
    await tester.enterText(fields.at(2), PairingInvite.generateSecret());
    await tester.enterText(fields.at(3), storeId);
    await tester.pump();

    final pairButton = find.text('Pair this Mac');
    await tester.ensureVisible(pairButton);
    await tester.pumpAndSettle();
    await tester.tap(pairButton);
    await tester.pumpAndSettle();

    expect(client.pullCalls, 1);
    expect(await database.getPeers(), hasLength(1));
  });
}
