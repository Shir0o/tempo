import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/speech/speech_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tempo/speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('isAvailable maps true from the platform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isAvailable');
      return true;
    });

    expect(await const MethodChannelSpeechInput().isAvailable(), isTrue);
  });

  test('listen returns the final transcript', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listen');
      return 'Cleaning';
    });

    expect(await const MethodChannelSpeechInput().listen(), 'Cleaning');
  });

  test('a PlatformException on listen becomes null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'SPEECH_BUSY');
    });

    expect(await const MethodChannelSpeechInput().listen(), isNull);
  });

  test('missing plugin is unavailable and cancels', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(await const MethodChannelSpeechInput().isAvailable(), isFalse);
    expect(await const MethodChannelSpeechInput().listen(), isNull);
  });
}
