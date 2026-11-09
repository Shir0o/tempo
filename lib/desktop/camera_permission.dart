import 'dart:async';

import 'package:flutter/services.dart';

/// How macOS sees this app's camera access, as AVFoundation reports it.
enum CameraPermission { authorized, denied, restricted, notDetermined }

/// Asks macOS for the camera before a scanner is put on screen.
///
/// A camera is never granted by default: the system shows its one prompt only
/// when the app calls `AVCaptureDevice.requestAccess`. mobile_scanner's macOS
/// `start` does not, so the first scan would fail without ever asking. The
/// native side owns that prompt; this is its whole surface.
class CameraAccess {
  static const MethodChannel _channel = MethodChannel(
    'tempo/camera_permission',
  );

  const CameraAccess._();

  /// The current authorization, asking nothing.
  static Future<CameraPermission> status() async {
    try {
      final raw = await _channel
          .invokeMethod<String>('status')
          // A channel with no native side never answers at all: an engine
          // without the plugin, or a test harness. Fall through to the
          // scanner's own error state rather than an empty page.
          .timeout(const Duration(seconds: 5));
      return _parse(raw);
    } on TimeoutException {
      return CameraPermission.authorized;
    } on MissingPluginException {
      // No native check on this platform (iOS, Android, tests): the scanner's
      // own path handles the prompt.
      return CameraPermission.authorized;
    } on PlatformException {
      return CameraPermission.authorized;
    }
  }

  /// Shows the system prompt when macOS has not been asked yet. Returns the
  /// state afterwards, which may still be denied.
  static Future<CameraPermission> request() async {
    try {
      return _parse(await _channel.invokeMethod<String>('request'));
    } on MissingPluginException {
      return CameraPermission.authorized;
    } on PlatformException {
      return CameraPermission.denied;
    }
  }

  /// Opens System Settings at Privacy & Security → Camera.
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // Nothing to open off the Mac.
    } on PlatformException {
      // The pane could not be opened; the message on screen still says where.
    }
  }

  static CameraPermission _parse(String? raw) => switch (raw) {
    'authorized' => CameraPermission.authorized,
    'denied' => CameraPermission.denied,
    'restricted' => CameraPermission.restricted,
    _ => CameraPermission.notDetermined,
  };
}
