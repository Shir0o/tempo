import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The watch buffers a label as a DataItem and relies on the phone being able to
// receive it even when the Flutter UI is not running. Only a service declared
// in the manifest lets Google Play Services start the app for that event; a
// listener registered in an Activity dies with the Activity. These assertions
// pin that architectural property so it cannot be quietly removed.
const _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const _phoneSourceRoot = 'android/app/src/main/kotlin/com/tempos/tracker';

String _resolveServiceSource(String androidName) {
  final simple = androidName.startsWith('.')
      ? androidName.substring(1)
      : androidName.split('.').last;
  return '$_phoneSourceRoot/$simple.kt';
}

void main() {
  group('phone-side Wear data layer registration', () {
    final manifest = File(_manifestPath).readAsStringSync();

    test('a manifest listener can receive watch actions with no Flutter UI', () {
      final services = RegExp(r'<service\b[^>]*>.*?</service>', dotAll: true)
          .allMatches(manifest)
          .where((match) {
            return match
                .group(0)!
                .contains('com.google.android.gms.wearable.DATA_CHANGED');
          })
          .toList();

      expect(
        services,
        isNotEmpty,
        reason:
            'The phone must declare a WearableListenerService for '
            'DATA_CHANGED. Without it, a watch label that arrives while the '
            'Flutter Activity is not running is never delivered, because '
            'DataClient.addListener() only receives events for the lifetime of '
            'the Activity.',
      );

      final service = services.first.group(0)!;
      final name = RegExp(r'android:name="([^"]+)"')
          .firstMatch(service)
          ?.group(1);
      expect(name, isNotNull, reason: 'the listener needs a class name');

      final source = File(_resolveServiceSource(name!));
      expect(
        source.existsSync(),
        isTrue,
        reason: '${source.path} must exist for the manifest listener $name',
      );
      expect(
        source.readAsStringSync(),
        contains('WearableListenerService'),
        reason: '${source.path} must extend WearableListenerService',
      );
      expect(
        source.readAsStringSync(),
        contains('onDataChanged'),
        reason: '${source.path} must handle the watch action DataItem',
      );
    });

    test('the manifest listener covers the watch action path', () {
      final services = RegExp(r'<service\b[^>]*>.*?</service>', dotAll: true)
          .allMatches(manifest)
          .where((match) {
            return match
                .group(0)!
                .contains('com.google.android.gms.wearable.DATA_CHANGED');
          });
      expect(services, isNotEmpty);
      expect(
        services.first.group(0),
        contains('/tempo/actions'),
        reason: 'the listener must match the path the watch writes',
      );
    });
  });
}
