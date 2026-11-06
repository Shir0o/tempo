import 'dart:async';

import 'package:flutter/services.dart';

/// The platform speech seam.
abstract class SpeechInput {
  Future<bool> isAvailable();

  /// Returns the final transcript, or null when cancelled or unavailable.
  Future<String?> listen();
}

class UnavailableSpeechInput implements SpeechInput {
  const UnavailableSpeechInput();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String?> listen() async => null;
}

/// Android implementation over the `tempo/speech` channel.
///
/// Tempo records no audio: the recognizer activity owns the microphone and
/// returns text. Failures collapse to false or null, never to a thrown future,
/// so the sheet can leave the field unchanged.
class MethodChannelSpeechInput implements SpeechInput {
  static const MethodChannel _channel = MethodChannel('tempo/speech');
  static const Duration _timeout = Duration(seconds: 60);

  const MethodChannelSpeechInput();

  @override
  Future<bool> isAvailable() async {
    try {
      final available = await _channel.invokeMethod<bool>('isAvailable');
      return available ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> listen() async {
    try {
      return await _channel.invokeMethod<String>('listen').timeout(_timeout);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
