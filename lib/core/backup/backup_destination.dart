import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// SHA-256 of [bytes] as lowercase hex. Used for generation names, manifest
/// hashes and the destination read-back check.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// One file listed inside a backup destination.
class DestinationFile {
  final String path;
  final int bytes;
  final int modifiedAtEpochMs;

  const DestinationFile({
    required this.path,
    required this.bytes,
    required this.modifiedAtEpochMs,
  });
}

class BackupDestinationException implements Exception {
  final String message;

  const BackupDestinationException(this.message);

  @override
  String toString() => message;
}

/// The chosen folder is the phone's own storage, so it would die with the
/// device. Refused at pick time and whenever a persisted destination reopens.
class BackupDestinationRefusedException extends BackupDestinationException {
  const BackupDestinationRefusedException()
    : super("the phone's own storage cannot be a backup destination");
}

/// The destination is gone or its permission was revoked. Settings shows it as
/// unreachable and asks the user to pick again.
class BackupDestinationUnavailableException extends BackupDestinationException {
  const BackupDestinationUnavailableException(String locator)
    : super('backup destination is unavailable: $locator');
}

/// A write reached the destination but did not read back as the bytes that
/// were written. The generation is never marked valid.
class BackupVerificationException extends BackupDestinationException {
  const BackupVerificationException(super.message);
}

/// The user-chosen backup folder, in the layout
/// `<destination>/tempo/<store_id>/backup-<yyyyMMddTHHmmssZ>.db` with one
/// `manifest.json` beside it. Temp files go under `<destination>/tempo/.tmp/`.
///
/// Two implementations exist because the platforms differ: a filesystem folder
/// on macOS renames atomically, while Android's Storage Access Framework has
/// no atomic rename, so a promotion copies and then verifies the destination
/// hash before the generation may be recorded as valid.
abstract class BackupDestination {
  /// What to persist in the `backup_destination` setting. A filesystem path or
  /// a SAF tree URI.
  String get locator;

  /// True when the folder looks like a cloud-synced or network location. The
  /// picker states that backups are plaintext there.
  bool get isCloudSynced;

  /// True when the folder is on the phone's own storage and must be refused.
  bool get isOwnStorage;

  /// True while the destination can be written to.
  bool get isOpen;

  /// Re-establishes access after a restart: a directory that still exists, or
  /// a SAF tree whose persisted permission is still granted.
  Future<bool> reopen();

  /// Drops any held handle. Access can be re-established with [reopen].
  Future<void> close();

  /// Writes [bytes] under `tempo/.tmp/<fileName>` and returns that
  /// destination-relative path.
  Future<String> writeTemp(String fileName, List<int> bytes);

  /// Moves [from] to [to]. Atomic on a filesystem. On SAF it copies, reads the
  /// destination back, and throws unless the hash matches [expectedSha256].
  Future<void> renameAtomically({
    required String from,
    required String to,
    String? expectedSha256,
  });

  /// Reads a destination-relative file.
  Stream<List<int>> openRead(String relativePath);

  /// Lists the files directly inside [relativeDirectory], sorted by path.
  Future<List<DestinationFile>> list(String relativeDirectory);

  /// Deletes a destination-relative file. Missing files are ignored.
  Future<void> delete(String relativePath);
}

/// A folder on the filesystem, used on macOS and desktop. `rename()` within
/// one volume is atomic, so a generation appears complete or not at all.
class FilesystemBackupDestination implements BackupDestination {
  final String rootPath;

  /// App-owned directories that must never be a destination.
  final List<String> ownStorageRoots;

  FilesystemBackupDestination({
    required String rootPath,
    this.ownStorageRoots = const [],
  }) : rootPath = p.normalize(p.absolute(rootPath));

  static const String tempoDirectoryName = 'tempo';
  static const String tempDirectoryName = '.tmp';

  @override
  String get locator => rootPath;

  @override
  bool get isOpen => Directory(rootPath).existsSync();

  @override
  bool get isOwnStorage => _isOwnStorage(rootPath, ownStorageRoots);

  @override
  bool get isCloudSynced =>
      looksCloudSynced(rootPath, mountSource: macosMountSource(rootPath));

  @override
  Future<bool> reopen() async {
    if (rootPath.isEmpty) return false;
    return Directory(rootPath).exists();
  }

  @override
  Future<void> close() async {}

  @override
  Future<String> writeTemp(String fileName, List<int> bytes) async {
    final relativePath = p.join(
      tempoDirectoryName,
      tempDirectoryName,
      _validatedName(fileName),
    );
    final file = File(_resolve(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return relativePath;
  }

  @override
  Future<void> renameAtomically({
    required String from,
    required String to,
    String? expectedSha256,
  }) async {
    final source = File(_resolve(from));
    if (!await source.exists()) {
      throw BackupDestinationException('temp file is missing: $from');
    }
    final target = File(_resolve(to));
    await target.parent.create(recursive: true);

    await source.rename(target.path);

    final expected = expectedSha256;
    if (expected != null) {
      final actual = sha256Hex(await target.readAsBytes());
      if (actual != expected) {
        await target.delete();
        throw BackupVerificationException(
          'destination hash mismatch for $to: expected $expected, got $actual',
        );
      }
    }
  }

  @override
  Stream<List<int>> openRead(String relativePath) =>
      File(_resolve(relativePath)).openRead();

  @override
  Future<List<DestinationFile>> list(String relativeDirectory) async {
    final directory = Directory(_resolve(relativeDirectory));
    if (!await directory.exists()) return const [];
    final files = <DestinationFile>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      files.add(
        DestinationFile(
          path: p.relative(entity.path, from: rootPath),
          bytes: stat.size,
          modifiedAtEpochMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  @override
  Future<void> delete(String relativePath) async {
    final file = File(_resolve(relativePath));
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _resolve(String relativePath) {
    final resolved = p.normalize(p.join(rootPath, relativePath));
    return resolved;
  }

  static String _validatedName(String fileName) {
    if (fileName.isEmpty ||
        p.basename(fileName) != fileName ||
        fileName == '.' ||
        fileName == '..') {
      throw BackupDestinationException('invalid file name: $fileName');
    }
    return fileName;
  }

  static bool _isOwnStorage(String path, List<String> roots) {
    final candidate = p.normalize(p.absolute(path));
    for (final root in roots) {
      final normalizedRoot = p.normalize(p.absolute(root));
      if (candidate == normalizedRoot ||
          p.isWithin(normalizedRoot, candidate)) {
        return true;
      }
    }
    return false;
  }
}

/// Known user-visible sync roots. A filesystem mount point alone cannot name a
/// provider, so the provider's own folder is the reliable macOS signal; a
/// network volume counts too, because the folder then leaves the machine.
bool looksCloudSynced(String path, {String? mountSource}) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  if (mountSource != null) {
    final source = mountSource.toLowerCase();
    if (source.contains('smbfs') ||
        source.contains('afpfs') ||
        source.contains('nfs') ||
        source.contains('cifs') ||
        source.contains('webdav')) {
      return true;
    }
  }
  const providerMarkers = [
    '/library/mobile documents',
    'com~apple~clouddocs',
    '/dropbox',
    '/google drive',
    '/googledrive',
    '/onedrive',
    '/box sync',
    '/pcloud',
    '/mega',
    '/sync.com',
  ];
  return providerMarkers.any(normalized.contains);
}

/// The macOS mount source of [path], used to spot network volumes. Null when
/// the probe is unavailable, in which case the path heuristic decides.
String? macosMountSource(String path) {
  if (kIsWeb || !Platform.isMacOS) return null;
  try {
    final result = Process.runSync('df', ['-P', path]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    return lines[1].split(RegExp(r'\s+')).first;
  } catch (_) {
    return null;
  }
}

/// The tree a SAF picker returned, with the provider that owns it.
class SafTree {
  final String treeUri;
  final String providerAuthority;

  const SafTree({required this.treeUri, required this.providerAuthority});
}

/// The native SAF bridge's document operations. `BackupDestinationChannel.kt`
/// implements this contract on the Android side. Tests supply a fake.
abstract class SafDocumentStore {
  /// Shows the tree picker and persists the returned URI permission.
  Future<SafTree?> pickTree();

  /// Re-checks that the persisted permission for [treeUri] still applies.
  Future<bool> reopen(String treeUri);

  Future<void> createDirectory(String treeUri, String relativeDirectory);

  Future<void> writeFile(String treeUri, String relativePath, List<int> bytes);

  Future<Uint8List> readFile(String treeUri, String relativePath);

  Future<List<DestinationFile>> list(String treeUri, String relativeDirectory);

  Future<void> delete(String treeUri, String relativePath);

  /// Releases the persisted permission, called when the user changes the
  /// destination.
  Future<void> release(String treeUri);
}

/// The default bridge to the Kotlin channel. Method names are the contract the
/// native side implements; a missing channel surfaces as
/// [BackupDestinationUnavailableException] rather than a crash.
class ChannelSafDocumentStore implements SafDocumentStore {
  static const MethodChannel channel = MethodChannel(
    'tempo/backup_destination',
  );

  const ChannelSafDocumentStore();

  @override
  Future<SafTree?> pickTree() async {
    final result = await _invoke<Map<Object?, Object?>>('pickTree');
    if (result == null) return null;
    final uri = result['treeUri'] as String?;
    final authority = result['providerAuthority'] as String?;
    if (uri == null || authority == null) return null;
    return SafTree(treeUri: uri, providerAuthority: authority);
  }

  @override
  Future<bool> reopen(String treeUri) async =>
      await _invoke<bool>('reopen', {'treeUri': treeUri}) ?? false;

  @override
  Future<void> createDirectory(String treeUri, String relativeDirectory) async {
    await _invoke<void>('createDirectory', {
      'treeUri': treeUri,
      'relativeDirectory': relativeDirectory,
    });
  }

  @override
  Future<void> writeFile(
    String treeUri,
    String relativePath,
    List<int> bytes,
  ) async {
    await _invoke<void>('writeFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  @override
  Future<Uint8List> readFile(String treeUri, String relativePath) async {
    final bytes = await _invoke<Uint8List>('readFile', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
    if (bytes == null) {
      throw BackupDestinationException('SAF file is missing: $relativePath');
    }
    return bytes;
  }

  @override
  Future<List<DestinationFile>> list(
    String treeUri,
    String relativeDirectory,
  ) async {
    final rows = await _invoke<List<Object?>>('list', {
      'treeUri': treeUri,
      'relativeDirectory': relativeDirectory,
    });
    if (rows == null) return const [];
    return rows
        .whereType<Map<Object?, Object?>>()
        .map(
          (row) => DestinationFile(
            path: row['path'] as String? ?? '',
            bytes: row['bytes'] as int? ?? 0,
            modifiedAtEpochMs: row['modifiedAtEpochMs'] as int? ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<void> delete(String treeUri, String relativePath) async {
    await _invoke<void>('delete', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
  }

  @override
  Future<void> release(String treeUri) async {
    await _invoke<void>('release', {'treeUri': treeUri});
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const BackupDestinationUnavailableException('saf');
    } on PlatformException catch (e) {
      throw BackupDestinationException(e.message ?? 'SAF $method failed');
    }
  }
}

/// A SAF tree destination. Android has no atomic rename, so a promotion is a
/// copy followed by a destination read-back hash check; only then may the
/// caller record the generation as valid.
class SafBackupDestination implements BackupDestination {
  static const Set<String> cloudProviders = {
    'com.google.android.apps.docs',
    'com.microsoft.skydrive',
    'com.dropbox.android',
    'com.box.android',
    'com.pcloud.pcloud',
    'com.mega.megasync',
  };

  /// Device-storage providers. A folder here dies with the phone, which is the
  /// one thing a backup destination exists to survive.
  static const Set<String> onDeviceProviders = {
    'com.android.externalstorage.documents',
    'com.android.providers.downloads.documents',
  };

  final String treeUri;
  final String providerAuthority;
  final SafDocumentStore store;

  SafBackupDestination({
    required this.treeUri,
    required this.providerAuthority,
    required this.store,
  });

  @override
  String get locator => treeUri;

  @override
  bool get isOwnStorage => onDeviceProviders.contains(providerAuthority);

  @override
  bool get isCloudSynced => cloudProviders.contains(providerAuthority);

  @override
  bool get isOpen => _open;

  bool _open = false;

  /// Shows the SAF tree picker. Refuses a tree on the phone's own storage.
  static Future<SafBackupDestination?> pick({
    SafDocumentStore store = const ChannelSafDocumentStore(),
  }) async {
    final tree = await store.pickTree();
    if (tree == null) return null;
    final destination = SafBackupDestination(
      treeUri: tree.treeUri,
      providerAuthority: tree.providerAuthority,
      store: store,
    );
    if (destination.isOwnStorage) {
      await store.release(tree.treeUri);
      throw const BackupDestinationRefusedException();
    }
    destination._open = true;
    return destination;
  }

  @override
  Future<bool> reopen() async {
    _open = await store.reopen(treeUri);
    return _open;
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<String> writeTemp(String fileName, List<int> bytes) async {
    _assertOpen();
    final directory = p.posix.join(
      FilesystemBackupDestination.tempoDirectoryName,
      FilesystemBackupDestination.tempDirectoryName,
    );
    await store.createDirectory(treeUri, directory);
    final relativePath = p.posix.join(directory, fileName);
    await store.writeFile(treeUri, relativePath, bytes);
    return relativePath;
  }

  @override
  Future<void> renameAtomically({
    required String from,
    required String to,
    String? expectedSha256,
  }) async {
    _assertOpen();
    final bytes = await store.readFile(treeUri, from);
    final separator = p.posix.dirname(to);
    if (separator != '.') {
      await store.createDirectory(treeUri, separator);
    }
    await store.writeFile(treeUri, to, bytes);

    final expected = expectedSha256 ?? sha256Hex(bytes);
    final actual = sha256Hex(await store.readFile(treeUri, to));
    if (actual != expected) {
      await store.delete(treeUri, to);
      throw BackupVerificationException(
        'SAF destination hash mismatch for $to: '
        'expected $expected, got $actual',
      );
    }
    await store.delete(treeUri, from);
  }

  @override
  Stream<List<int>> openRead(String relativePath) async* {
    _assertOpen();
    yield await store.readFile(treeUri, relativePath);
  }

  @override
  Future<List<DestinationFile>> list(String relativeDirectory) async {
    _assertOpen();
    final files = await store.list(treeUri, relativeDirectory);
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  @override
  Future<void> delete(String relativePath) async {
    _assertOpen();
    await store.delete(treeUri, relativePath);
  }

  void _assertOpen() {
    if (!_open) {
      throw BackupDestinationUnavailableException(treeUri);
    }
  }
}

/// Reopens a destination the user picked earlier, from the locator stored in
/// the `backup_destination` setting.
Future<BackupDestination?> openBackupDestination(String locator) async {
  if (locator.isEmpty) return null;
  if (locator.startsWith('content://')) {
    final destination = SafBackupDestination(
      treeUri: locator,
      providerAuthority: safAuthorityFromTreeUri(locator),
      store: const ChannelSafDocumentStore(),
    );
    return await destination.reopen() ? destination : null;
  }
  final destination = FilesystemBackupDestination(rootPath: locator);
  return await destination.reopen() ? destination : null;
}

/// The provider authority carried by a SAF tree URI, e.g.
/// `content://com.google.android.apps.docs.tree/...`.
String safAuthorityFromTreeUri(String treeUri) {
  final withoutScheme = treeUri.startsWith('content://')
      ? treeUri.substring('content://'.length)
      : treeUri;
  final slash = withoutScheme.indexOf('/');
  final authority = slash < 0
      ? withoutScheme
      : withoutScheme.substring(0, slash);
  // `com.google.android.apps.docs.tree` names a document tree, not the
  // provider; strip the `.tree` suffix the picker adds.
  return authority.endsWith('.tree')
      ? authority.substring(0, authority.length - '.tree'.length)
      : authority;
}

/// Shows the platform picker and returns the chosen destination.
///
/// Android goes through SAF so the grant survives a restart. The phone's own
/// storage is refused: a destination on the phone cannot outlive the phone.
Future<BackupDestination?> pickBackupDestination({
  SafDocumentStore safStore = const ChannelSafDocumentStore(),
  List<String>? ownStorageRoots,
}) async {
  if (!kIsWeb && Platform.isAndroid) {
    return SafBackupDestination.pick(store: safStore);
  }
  final selected = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose a backup folder',
  );
  if (selected == null) return null;
  final roots = ownStorageRoots ?? await _appOwnedDirectories();
  final destination = FilesystemBackupDestination(
    rootPath: selected,
    ownStorageRoots: roots,
  );
  if (destination.isOwnStorage) {
    throw const BackupDestinationRefusedException();
  }
  return destination;
}

Future<List<String>> _appOwnedDirectories() async {
  final roots = <String>[];
  for (final probe in [
    getApplicationSupportDirectory,
    getApplicationDocumentsDirectory,
    getTemporaryDirectory,
  ]) {
    try {
      roots.add((await probe()).path);
    } catch (_) {
      // A platform without the directory simply contributes no root.
    }
  }
  return roots;
}
