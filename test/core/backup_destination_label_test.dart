import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/backup/backup_destination.dart';

void main() {
  group('readableLocatorLabel', () {
    test('never shows an opaque cloud document id', () {
      const drive =
          'content://com.google.android.apps.docs.storage/tree/'
          'acc%3D1%3Bdoc%3Dencoded%3DlF2Eio65QslC8KkFP4tGQtWafHPYUE1oc_SOf'
          'D1qegf7MDzlUXkfSkmNBQ%3D%3D';
      final label = readableLocatorLabel(drive);
      expect(label, 'Google Drive folder');
      expect(label, isNot(contains('acc=')));
    });

    test('reads a path-shaped document id as its last folders', () {
      expect(
        readableLocatorLabel(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADownload%2FTempo%2Fbackups',
        ),
        'Tempo/backups',
      );
      expect(
        readableLocatorLabel(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ABackups',
        ),
        'Backups',
      );
    });

    test('an unknown provider with an opaque id reads as a chosen folder', () {
      expect(
        readableLocatorLabel('content://com.example.docs/tree/abc123'),
        'Chosen folder',
      );
    });

    test('a filesystem path shows its last two segments', () {
      expect(
        readableLocatorLabel('/Users/tony/Library/CloudStorage/Dropbox/Tempo'),
        'Dropbox/Tempo',
      );
      expect(readableLocatorLabel('/Backups'), 'Backups');
    });
  });

  test('a SAF destination names itself through the provider', () async {
    final destination = SafBackupDestination(
      treeUri: 'content://com.google.android.apps.docs.storage/tree/x',
      providerAuthority: 'com.google.android.apps.docs',
      store: _NamingStore('Drive/Backups'),
    );
    expect(await destination.readableName(), 'Drive/Backups');

    final failing = SafBackupDestination(
      treeUri: 'content://com.google.android.apps.docs.storage/tree/x',
      providerAuthority: 'com.google.android.apps.docs',
      store: _NamingStore(null, fail: true),
    );
    expect(await failing.readableName(), isNull);
  });
}

class _NamingStore extends ChannelSafDocumentStore {
  _NamingStore(this.name, {this.fail = false});

  final String? name;
  final bool fail;

  @override
  Future<String?> displayName(String treeUri) async {
    if (fail) throw const BackupDestinationException('no provider');
    return name;
  }
}
