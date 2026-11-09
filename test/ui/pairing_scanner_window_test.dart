import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/sync/peer_pairing.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/desktop/pairing_view.dart';

/// Records the effective scan window (as a fraction of the camera texture)
/// that the scanner hands to the platform.
class _RecordingScannerPlatform extends MobileScannerPlatform {
  final List<Rect?> scanWindows = [];

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
  Future<void> updateScanWindow(Rect? window) async {
    scanWindows.add(window);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  testWidgets('the phone scanner reads the middle of the preview', (
    tester,
  ) async {
    final platform = _RecordingScannerPlatform();
    MobileScannerPlatform.instance = platform;

    final database = await TempoDatabase.openInMemory(
      factory: databaseFactoryFfiNoIsolate,
    );
    addTearDown(database.close);
    final pairing = PeerPairing(
      database: database,
      secrets: InMemoryPeerSecretStore(),
    );

    await tester.pumpWidget(
      MaterialApp(home: PhonePairingView(pairing: pairing)),
    );
    await tester.pumpAndSettle();

    expect(platform.scanWindows, isNotEmpty);
    final window = platform.scanWindows.last!;

    // A scan window smaller than half the preview means the camera is looking
    // at a dot in the corner, not at the code the user is holding.
    expect(window.width, greaterThan(0.5));
    expect(window.height, greaterThan(0.5));
    expect(window.center.dx, closeTo(0.5, 0.05));
    expect(window.center.dy, closeTo(0.5, 0.05));
  });
}
