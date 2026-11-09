import 'package:flutter/material.dart';
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
  final List<({String host, int port})> manualPeers = [];

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
  void setManualPeer({required String host, required int port}) {
    manualPeers.add((host: host, port: port));
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
  final InMemoryPeerSecretStore secrets;
  final PeerPairing pairing;
  final SyncListener listener;

  const _Phone({
    required this.database,
    required this.recorder,
    required this.secrets,
    required this.pairing,
    required this.listener,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    MobileScannerPlatform.instance = _FakeMobileScannerPlatform();
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
    final secrets = InMemoryPeerSecretStore();
    final pairing = PeerPairing(database: database, secrets: secrets);
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
      secrets: secrets,
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

  testWidgets(
    'pairing from the phone starts the listener and opens the scanner',
    (tester) async {
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
      expect(find.byType(MobileScanner), findsOneWidget);
      // The phone reads the code; it no longer shows one.
      expect(find.byType(QrImageView), findsNothing);

      await tester.tap(find.text('Type the details instead'));
      await tester.pumpAndSettle();
      expect(find.text('Store id'), findsOneWidget);
      expect(find.text('Secret, shown under the code'), findsOneWidget);

      // Typing the Mac's details stores the secret for the store it names.
      final secret = PairingInvite.generateSecret();
      final fields = find.byType(TextField);
      await tester.ensureVisible(fields.at(0));
      await tester.enterText(fields.at(0), 'store-mac');
      await tester.enterText(fields.at(1), secret);
      final pairButton = find.widgetWithText(FilledButton, 'Pair this Mac');
      await tester.ensureVisible(pairButton);
      await tester.pumpAndSettle();
      await tester.tap(pairButton);
      await tester.pumpAndSettle();

      expect(
        await phone.secrets.read(PeerPairing.peerSecretKey('store-mac')),
        secret,
      );
      // No peer row yet: the Mac has not dialled, so it has no address or id.
      expect(await phone.database.getPeers(), isEmpty);
      expect(find.text('Pair this Mac'), findsNothing);

      // The server's idle timeout is a timer in the test's fake clock; close it
      // before the body ends or the binding reports a pending timer.
      await tester.runAsync(phone.listener.stop);
      await tester.pumpAndSettle();
    },
  );

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

  testWidgets('pairing on the Mac shows a code and dials a typed address', (
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

    expect(find.text('Pair your phone'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Waiting for your phone\u2026'), findsOneWidget);
    // Showing the code starts the client, so the phone is adopted the moment
    // it scans instead of at the next backoff step.
    expect(client.applyCalls, greaterThanOrEqualTo(1));

    final manualToggle = find.text('Type the phone\u2019s address instead');
    await tester.ensureVisible(manualToggle);
    await tester.pumpAndSettle();
    await tester.tap(manualToggle);
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.ensureVisible(fields.at(0));
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '8727');
    final connect = find.text('Connect');
    await tester.ensureVisible(connect);
    await tester.pumpAndSettle();
    await tester.tap(connect);
    await tester.pumpAndSettle();

    expect(client.manualPeers, [(host: '127.0.0.1', port: 8727)]);

    // Leave the page so its poll timer is cancelled.
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}
