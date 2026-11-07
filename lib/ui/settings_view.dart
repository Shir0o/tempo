import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_version.dart';
import '../../core/backup/backup_destination.dart';
import '../../core/backup/backup_service.dart';
import '../../core/export/csv_export_engine.dart';
import '../../core/import/stt_import_service.dart';
import '../../core/state/day_recorder.dart';
import '../../core/state/today_order.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../core/sync/intent_queue.dart';
import '../../core/sync/peer_pairing.dart';
import '../../core/sync/replica_applier.dart';
import '../../core/sync/sync_client.dart';
import '../../core/sync/sync_listener.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import '../../data/models/sync_change.dart';
import '../desktop/pairing_view.dart';
import 'activity_manager_view.dart';
import 'category_manager_view.dart';
import 'helpers/ui_helpers.dart';
import 'stt_import_dialog.dart';
import 'tag_manager_view.dart';
import 'theme/tempo_theme.dart';

/// Settings screen for the CSV export to Google Drive, automatic backup and
/// restore, replication diagnostics, imports, and activity customization.
class SettingsView extends StatefulWidget {
  final TempoDatabase database;
  final DayRecorder? dayRecorder;
  final GoogleDriveSyncService? syncService;
  final BackupService? backupService;
  final CsvExportEngine? exportEngine;

  /// The Mac's replication client, for the Sync section's status, cursor and
  /// intent counts. Null on the phone, which runs the listener instead.
  final SyncClient? syncClient;

  /// The phone's replication listener. Null on the Mac. When present, Settings
  /// offers "Pair a device" and the replication switch drives the listener.
  final SyncListener? syncListener;

  /// Resolves the phone's LAN address for the pairing code. Overridable so a
  /// test does not depend on the runner's network interfaces.
  final Future<String?> Function()? lanAddressResolver;

  /// The Mac's pairing, for disconnecting a client and revoking all.
  final PeerPairing? pairing;

  /// The Today page's order, shared with the dashboard. Optional so previews and
  /// isolated tests can omit it.
  final ValueNotifier<TodayOrder>? todayOrder;

  /// Bumped after activities or categories change, so the Today page reloads.
  final ValueNotifier<int>? catalogRevision;

  const SettingsView({
    super.key,
    required this.database,
    this.dayRecorder,
    this.syncService,
    this.backupService,
    this.exportEngine,
    this.syncClient,
    this.syncListener,
    this.lanAddressResolver,
    this.pairing,
    this.todayOrder,
    this.catalogRevision,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _isProcessing = false;
  List<Activity> _activities = [];
  List<Category> _categories = [];

  // Backup settings, mirrored from the store so the switches and the folder
  // row render without a database read on every frame.
  bool _backupEnabled = false;
  bool _redactComments = false;
  String _destinationLocator = '';
  int _generations = 5;
  BackupDestination? _destination;
  BackupGeneration? _lastGeneration;
  int _keptGenerations = 0;
  bool _destinationUnreachable = false;

  // Replication diagnostics, mirrored from the client and `sync_peers` so the
  // Sync section renders without a store read on every frame.
  List<SyncPeer> _peers = const [];
  SyncClientStats? _syncStats;
  bool _syncLoading = false;
  bool _isReplica = false;
  bool _replicateEnabled = false;

  /// Bumped on every rebuild so an open second-level page redraws with it.
  final ValueNotifier<int> _revision = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _loadActivities();
    _loadExportSettings();
    _loadBackupSettings();
    _loadSyncDiagnostics();
    widget.todayOrder?.addListener(_onTodayOrderChanged);
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  @override
  void dispose() {
    widget.todayOrder?.removeListener(_onTodayOrderChanged);
    _revision.dispose();
    super.dispose();
  }

  Future<void> _loadExportSettings() async {
    try {
      final redact = await widget.database.getSetting(
        SyncSettingKeys.exportRedactComments,
      );
      if (mounted) setState(() => _redactComments = redact == 'true');
    } catch (_) {
      // The export setting is optional; a read failure keeps the default.
    }
  }

  void _onTodayOrderChanged() {
    if (mounted) setState(() {});
  }

  /// Tells the Today page that its catalog changed elsewhere.
  void _bumpCatalog() {
    final revision = widget.catalogRevision;
    if (revision != null) revision.value += 1;
  }

  Future<void> _loadActivities() async {
    try {
      final list = await widget.database.getAllActivities(
        includeArchived: true,
      );
      final categories = await widget.database.getCategories();
      if (mounted) {
        setState(() {
          _activities = list;
          _categories = categories;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadSyncDiagnostics() async {
    final client = widget.syncClient;
    final pairing = widget.pairing;

    if (mounted) setState(() => _syncLoading = true);
    try {
      final peers = await widget.database.getPeers();
      final settings = await widget.database.getSyncSettings();
      final replicaOf =
          await widget.database.getSetting(
            ReplicaApplier.replicaOfStoreIdKey,
          ) ??
          '';
      // The Mac is always a replica, even before its first pull; detecting it
      // by the platform is what lets Settings offer pairing on a fresh install.
      final isReplica =
          Platform.isMacOS ||
          replicaOf.isNotEmpty ||
          peers.isNotEmpty ||
          client != null ||
          pairing != null;

      // The client owns the live status; a replica whose client was not handed
      // in still reports the same counts from the same intents table.
      final stats = client == null
          ? (isReplica || pairing != null ? await _statsFromStore() : null)
          : await client.stats();

      if (!mounted) return;
      setState(() {
        _peers = peers;
        _isReplica = isReplica || pairing != null || client != null;
        _replicateEnabled = settings.replicateEnabled;
        _syncStats = stats;
        _syncLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _syncLoading = false);
    }
  }

  /// The counters Settings shows when no [SyncClient] was handed in: the same
  /// two sources the client reads, `applied_seq` and the intents table.
  Future<SyncClientStats?> _statsFromStore() async {
    var applied = 0;
    var rejected = 0;
    var pending = 0;
    try {
      final rows = await widget.database.db.rawQuery(
        'SELECT status, COUNT(*) AS total FROM ${IntentQueue.table} '
        'GROUP BY status',
      );
      for (final row in rows) {
        final total = row['total'] as int? ?? 0;
        switch (row['status']) {
          case IntentQueue.appliedStatus:
            applied = total;
          case IntentQueue.rejectedStatus:
            rejected = total;
          case IntentQueue.pendingStatus:
            pending = total;
        }
      }
    } catch (_) {
      // No intents table on a phone store; the counters stay at zero.
    }

    final appliedSeq =
        int.tryParse(
          await widget.database.getSetting(ReplicaApplier.appliedSeqKey) ?? '',
        ) ??
        0;

    return SyncClientStats(
      status: SyncClientStatus.idle,
      appliedSeq: appliedSeq,
      lastSuccessEpochMs: 0,
      changesApplied: 0,
      intentsApplied: applied,
      intentsRejected: rejected,
      intentsPending: pending,
    );
  }

  /// Forgets one paired phone: its secret and its row, so it must pair again.
  Future<void> _disconnectPeer(SyncPeer peer) async {
    final pairing = widget.pairing;
    if (pairing == null) return;
    try {
      await pairing.forget(peer.peerDeviceId, peerStoreId: peer.storeId);
      await _loadSyncDiagnostics();
      _setStatus('Disconnected from ${peer.host}.');
    } catch (e) {
      _setStatus('Could not disconnect: $e');
    }
  }

  Future<void> _revokeAllPeers() async {
    final pairing = widget.pairing;
    if (pairing == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Revoke every paired device?'),
        content: const Text('Each paired device must pair again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: TempoColors.inkMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text(
              'Revoke all',
              style: TextStyle(
                color: TempoColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await pairing.revokeAll();
      await _loadSyncDiagnostics();
      _setStatus('Every paired device was revoked.');
    } catch (e) {
      _setStatus('Could not revoke the paired devices: $e');
    }
  }

  /// The Mac's side: scans the phone's code and, once adopted, exchanges at
  /// once so the replica starts filling instead of waiting for the loop.
  Future<void> _openPairing() async {
    final pairing = widget.pairing;
    if (pairing == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingView(
          pairing: pairing,
          onPaired: (_) => unawaited(_pullAfterPairing()),
        ),
      ),
    );
    await _loadSyncDiagnostics();
  }

  /// The phone's side: the listener must be bound before the code is drawn, so
  /// the invite carries a port the Mac can dial.
  Future<void> _openPhonePairing() async {
    final listener = widget.syncListener;
    final pairing = widget.pairing;
    if (listener == null || pairing == null) return;

    setState(() => _isProcessing = true);
    try {
      final port = listener.isRunning
          ? listener.boundPort
          : await listener.start();
      final resolved = await (widget.lanAddressResolver ?? _lanAddressFor)();
      final host = resolved != null && resolved.isNotEmpty
          ? resolved
          : (listener.host == SyncListener.defaultHost
                ? '127.0.0.1'
                : listener.host);
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PairingInviteView(
            pairing: pairing,
            host: host,
            port: port,
            onRevokeAll: pairing.revokeAll,
          ),
        ),
      );
      await _loadSyncDiagnostics();
    } catch (e) {
      // A port already in use, or a listener that cannot bind, is the usual
      // reason no code can be shown; say which rather than staying silent.
      _setStatus('Replication is not running: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// The phone's LAN address, skipping the addresses a Mac cannot dial.
  static Future<String?> _lanAddressFor() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback && !address.isLinkLocal) {
            return address.address;
          }
        }
      }
    } catch (_) {
      // No interfaces readable; the caller falls back to the bind host.
    }
    return null;
  }

  Future<void> _pullAfterPairing() async {
    final client = widget.syncClient;
    if (client == null) {
      await _loadSyncDiagnostics();
      return;
    }
    try {
      await client.pull();
      _setStatus('Paired. The first exchange is done.');
    } catch (e) {
      // Pairing succeeded even when the phone is not answering yet; the client
      // keeps trying, so this is a waiting message rather than a failure.
      _setStatus('Paired. Waiting for the phone: $e');
    }
    await _loadSyncDiagnostics();
  }

  Future<void> _setReplicateEnabled(bool value) async {
    setState(() => _replicateEnabled = value);
    try {
      await widget.database.setSetting(
        SyncSettingKeys.replicateEnabled,
        value ? 'true' : 'false',
      );
      // The flag gates both sides; hand it back to whichever service this
      // device runs so the change takes effect without a restart.
      final listener = widget.syncListener;
      final client = widget.syncClient;
      if (listener != null) {
        await listener.applyReplicationSetting();
      } else if (client != null) {
        await client.applyReplicationSetting();
      }
      await _loadSyncDiagnostics();
      if (!mounted) return;
      if (!value) {
        _setStatus('Replication is off.');
      } else if (_peers.isEmpty) {
        _setStatus('Replication is on. Waiting for a paired device.');
      } else {
        _setStatus('Replication is on.');
      }
    } catch (e) {
      if (mounted) setState(() => _replicateEnabled = !value);
      // Keep the store and the switch in agreement: a failure to start or stop
      // must not leave the flag on while the service is not running.
      try {
        await widget.database.setSetting(
          SyncSettingKeys.replicateEnabled,
          value ? 'false' : 'true',
        );
      } catch (_) {
        // The switch's own message already says the setting could not change.
      }
      _setStatus('Could not change replication: $e');
    }
  }

  void _setStatus(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _handleGoogleSignInToggle() async {
    final service = widget.syncService;
    if (service == null) return;

    setState(() => _isProcessing = true);
    try {
      if (service.isSignedIn) {
        await service.signOut();
        _setStatus('Disconnected from Google Drive.');
      } else {
        final success = await service.signIn();
        if (success) {
          _setStatus('Connected to Google Drive ("Time track" folder ready).');
        } else {
          _setStatus(service.lastError ?? 'Sign-in cancelled or failed.');
        }
      }
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleSyncCsvNow() async {
    final service = widget.syncService;
    final engine = widget.exportEngine;
    if (service == null || engine == null) return;

    setState(() => _isProcessing = true);
    try {
      final file = await engine.exportImmediately();
      final id = await service.syncCsvToDrive(file);
      _setStatus('Successfully synced CSV to Google Drive (ID: $id)');
    } catch (e) {
      _setStatus('Sync failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _loadBackupSettings() async {
    final service = widget.backupService;
    if (service == null) return;

    try {
      final enabled = await widget.database.getSetting(
        BackupService.backupEnabledSetting,
      );
      final locator =
          await widget.database.getSetting(BackupService.destinationSetting) ??
          '';
      final generations = int.tryParse(
        await widget.database.getSetting(BackupService.generationsSetting) ??
            '',
      );
      // Reopen the folder so an erased permission reads as unreachable here
      // rather than as silence when the next promotion runs.
      BackupDestination? destination;
      if (locator.isNotEmpty) {
        try {
          destination = await openBackupDestination(locator);
        } catch (_) {
          destination = null;
        }
        if (destination != null) service.destination = destination;
      }

      BackupGeneration? last;
      var kept = 0;
      if (destination != null) {
        try {
          final manifest = await service.readManifest();
          kept = manifest.generations.length;
          for (final generation in manifest.generations) {
            if (generation.verified) {
              last = generation;
              break;
            }
          }
        } catch (_) {
          // An unreadable manifest is rebuilt by the next verified promotion.
        }
      }

      if (!mounted) return;
      setState(() {
        _backupEnabled = enabled == 'true';
        _destinationLocator = locator;
        _destination = destination;
        _destinationUnreachable = locator.isNotEmpty && destination == null;
        _generations = generations == null || generations <= 0
            ? service.defaultGenerations
            : generations;
        _lastGeneration = last;
        _keptGenerations = kept;
      });
    } catch (_) {
      // Backup settings are optional; a read failure keeps the defaults.
    }
  }

  Future<void> _refreshLastGeneration() async {
    final service = widget.backupService;
    if (service == null || service.destination == null) return;
    try {
      final manifest = await service.readManifest();
      BackupGeneration? last;
      for (final generation in manifest.generations) {
        if (generation.verified) {
          last = generation;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _lastGeneration = last;
        _keptGenerations = manifest.generations.length;
        _destinationUnreachable = false;
      });
    } catch (_) {}
  }

  /// Picks a folder, persists it and hands it to the service. Returns false when
  /// the user cancelled or the folder was refused.
  Future<bool> _chooseBackupDestination() async {
    final service = widget.backupService;
    if (service == null) return false;

    setState(() => _isProcessing = true);
    try {
      final picked = await pickBackupDestination();
      if (picked == null) {
        _setStatus('No backup folder chosen.');
        return false;
      }
      service.destination = picked;
      await widget.database.setSetting(
        BackupService.destinationSetting,
        picked.locator,
      );
      if (!mounted) return false;
      setState(() {
        _destination = picked;
        _destinationLocator = picked.locator;
        _destinationUnreachable = false;
      });
      await _refreshLastGeneration();
      return true;
    } catch (e) {
      _setStatus('Could not use that folder: $e');
      return false;
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _setBackupEnabled(bool value) async {
    // Automatic backup needs somewhere to write, so the switch asks for a
    // folder first instead of turning on with no effect.
    if (value && _destinationLocator.isEmpty) {
      final picked = await _chooseBackupDestination();
      if (!picked) return;
    }
    setState(() => _backupEnabled = value);
    try {
      await widget.database.setSetting(
        BackupService.backupEnabledSetting,
        value ? 'true' : 'false',
      );
    } catch (_) {
      _setStatus('Could not save the backup setting.');
    }
  }

  Future<void> _chooseGenerations() async {
    const options = [3, 5, 10];
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Backups kept',
                style: TempoText.title.copyWith(
                  color: TempoColors.ink,
                  fontSize: 22,
                ),
              ),
            ),
            for (final count in options)
              ListTile(
                minTileHeight: 56,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(TempoRadii.row),
                ),
                title: Text(
                  count == 1 ? '1 generation' : '$count generations',
                  style: TempoText.body.copyWith(
                    color: TempoColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: count == _generations
                    ? const Icon(Icons.check_rounded, color: TempoColors.ink)
                    : null,
                onTap: () => Navigator.of(ctx).pop(count),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _generations = chosen);
    try {
      await widget.database.setSetting(
        BackupService.generationsSetting,
        '$chosen',
      );
    } catch (_) {
      _setStatus('Could not save the backup setting.');
    }
  }

  Future<void> _setRedactComments(bool value) async {
    setState(() => _redactComments = value);
    try {
      await widget.database.setSetting(
        SyncSettingKeys.exportRedactComments,
        value ? 'true' : 'false',
      );
      _setStatus('CSV comment redaction saved.');
    } catch (_) {
      _setStatus('Could not save the export setting.');
    }
  }

  Future<void> _handleBackupNow() async {
    final service = widget.backupService;
    if (service == null) {
      _setStatus('Backup is not available on this device.');
      return;
    }

    if (service.destination == null) {
      final picked = await _chooseBackupDestination();
      if (!picked) return;
    }

    setState(() => _isProcessing = true);
    try {
      await service.snapshot();
      final generation = await service.promote();
      await _refreshLastGeneration();
      _setStatus(
        generation == null
            ? 'Snapshot written locally; promotion will retry.'
            : 'Backup written to the chosen folder.',
      );
    } catch (e) {
      _setStatus('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleRestoreDatabaseNow() async {
    final service = widget.backupService;
    if (service == null) {
      _setStatus('Restore is not available on this device.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Restore Database?'),
        content: const Text(
          'Restoring will replace the current database with the newest '
          'verified backup from the chosen folder. Restart Tempo afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: TempoColors.inkMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text(
              'Restore',
              style: TextStyle(
                color: TempoColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isProcessing = true);
    try {
      final manifest = await service.readManifest();
      BackupGeneration? target;
      for (final generation in manifest.generations) {
        if (generation.verified) {
          target = generation;
          break;
        }
      }
      if (target == null) {
        _setStatus('No verified backup found in the chosen folder.');
        return;
      }
      final prepared = await service.prepareRestore(target);
      await service.applyPreparedRestore(
        prepared,
        target: service.databaseFile,
        closeStore: widget.database.close,
      );
      _setStatus('Database restored. Restart Tempo to use it.');
    } catch (e) {
      _setStatus('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleExportCsvNow() async {
    final engine = widget.exportEngine;
    if (engine == null) return;

    setState(() => _isProcessing = true);
    try {
      final file = await engine.exportImmediately();
      _setStatus('Exported CSV: ${file.path}');
    } catch (e) {
      _setStatus('Export failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _openActivityManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ActivityManagerView(database: widget.database),
      ),
    );
    await _loadActivities();
    _bumpCatalog();
  }

  Future<void> _openCategoryManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CategoryManagerView(database: widget.database),
      ),
    );
    await _loadActivities();
    _bumpCatalog();
  }

  Future<void> _openTagManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagManagerView(database: widget.database),
      ),
    );
    _bumpCatalog();
  }

  Future<void> _chooseTodayOrder() async {
    final notifier = widget.todayOrder;
    final current = notifier?.value ?? TodayOrder.categories;
    final chosen = await showModalBottomSheet<TodayOrder>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Order on Today',
                style: TempoText.title.copyWith(
                  color: TempoColors.ink,
                  fontSize: 22,
                ),
              ),
            ),
            for (final order in TodayOrder.values)
              ListTile(
                minTileHeight: 56,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(TempoRadii.row),
                ),
                title: Text(
                  order.label,
                  style: TempoText.body.copyWith(
                    color: TempoColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  order.description,
                  style: TempoText.label.copyWith(color: TempoColors.inkMuted),
                ),
                trailing: order == current
                    ? const Icon(Icons.check_rounded, color: TempoColors.ink)
                    : null,
                onTap: () => Navigator.of(ctx).pop(order),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (chosen == null || notifier == null) return;
    notifier.value = chosen;
    try {
      await widget.database.setSetting(
        TodayOrder.storageKey,
        chosen.storageValue,
      );
    } catch (_) {
      _setStatus('Could not save the order.');
    }
  }

  Future<void> _handleImportSimpleTimeTracker() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'backup', 'txt'],
      );

      if (files.isEmpty) return;
      final pickedPath = files.first.path;
      if (pickedPath == null) return;

      final file = File(pickedPath);
      final rawContent = await file.readAsString(encoding: utf8);
      if (!mounted) return;

      final importService = SttImportService(
        database: widget.database,
        csvExportEngine: widget.exportEngine,
      );

      final importResult = await SttImportDialog.show(
        context,
        fileContent: rawContent,
        fileName: files.first.name,
        database: widget.database,
        importService: importService,
      );

      if (importResult != null && mounted) {
        _loadActivities();
        await widget.dayRecorder?.reloadLapFromDatabase();
        _bumpCatalog();
        final recordNote = importResult.recordsImported > 0
            ? ', ${importResult.recordsImported} records'
            : '';
        _setStatus(
          'Imported ${importResult.categoriesImported} categories, '
          '${importResult.activitiesImported} activities$recordNote.',
        );
      }
    } catch (e) {
      _setStatus('Import failed: $e');
    }
  }

  /// Opens one of Settings' second-level pages. The page rebuilds whenever this
  /// state does, so its switches and statuses stay live.
  Future<void> _openPage(String title, List<Widget> Function() body) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            _SettingsPage(title: title, revision: _revision, body: body),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _activities.where((a) => !a.isArchived).toList();
    final archivedCount = _activities.length - active.length;
    final hasExport = widget.syncService != null || widget.exportEngine != null;
    final hasDevices = _isReplica || widget.syncListener != null;

    return Scaffold(
      backgroundColor: TempoColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              'Settings',
              style: TempoText.screenTitle.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('YOUR DAY'),
            _buildGroup([
              _SettingsRow(
                title: 'Activities',
                subtitle: _activities.isEmpty
                    ? null
                    : '${active.length} active · $archivedCount archived',
                leading: _ColourBars(
                  colors: [
                    for (final a in active.take(3))
                      UiHelpers.parseHexColor(a.colorHex),
                  ],
                ),
                opensPage: true,
                onTap: _openActivityManager,
              ),
              _SettingsRow(
                title: 'Categories',
                subtitle: _categories.isEmpty
                    ? 'Group activities on Today'
                    : '${_categories.length} groups',
                leading: _ColourBars(
                  colors: [
                    for (final c in _categories.take(3))
                      UiHelpers.parseHexColor(c.colorHex),
                  ],
                ),
                opensPage: true,
                onTap: _openCategoryManager,
              ),
              _SettingsRow(
                title: 'Tags',
                subtitle: 'Labels, and which one is the Contact tag',
                opensPage: true,
                onTap: _openTagManager,
              ),
              _SettingsRow(
                title: 'Order on Today',
                subtitle:
                    (widget.todayOrder?.value ?? TodayOrder.categories).label,
                opensPage: true,
                onTap: _chooseTodayOrder,
              ),
            ]),
            const SizedBox(height: 24),
            _buildSectionHeader('DATA'),
            _buildGroup([
              if (hasExport)
                _SettingsRow(
                  title: _exportTitle,
                  subtitle: _exportSummary(),
                  opensPage: true,
                  onTap: () => _openPage(_exportTitle, _buildExportPage),
                ),
              if (widget.backupService != null)
                _SettingsRow(
                  title: 'Backup',
                  subtitle: _backupSummary(),
                  opensPage: true,
                  onTap: () => _openPage('Backup', _buildBackupPage),
                ),
              if (hasDevices)
                _SettingsRow(
                  title: _devicesTitle,
                  subtitle: _devicesSummary(),
                  opensPage: true,
                  onTap: () => _openPage(_devicesTitle, _buildDevicesPage),
                ),
              _SettingsRow(
                title: 'Import from Simple Time Tracker',
                subtitle: 'Pick a .backup or .csv file',
                trailing: const _RowAction(label: 'Choose file'),
                onTap: _isProcessing ? null : _handleImportSimpleTimeTracker,
              ),
            ]),
            const SizedBox(height: 24),
            _buildSectionHeader('ABOUT'),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TempoColors.surface,
                borderRadius: BorderRadius.circular(TempoRadii.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tempo keeps your record on this device, in SQLite and CSV. No account, no tracking.',
                    style: TempoText.body.copyWith(
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Tempo $appVersion',
                    style: TempoText.label.copyWith(
                      color: TempoColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _exportTitle => widget.syncService == null
      ? 'Spreadsheet export'
      : 'Spreadsheet in Drive';

  String get _devicesTitle =>
      widget.syncListener != null ? 'Mac & devices' : 'Phone & devices';

  String _exportSummary() {
    final service = widget.syncService;
    if (service == null) return 'Save your record as a spreadsheet';
    if (!service.isSignedIn) return 'Not connected';
    if (!service.autoSyncEnabled) return 'Connected · automatic updates off';
    final last = service.lastSyncTime;
    if (last == null) return 'Connected';
    return 'Up to date · ${_clock(last)}';
  }

  String _backupSummary() {
    if (!_backupEnabled) return 'Off';
    if (_destinationUnreachable) return 'On · the folder needs choosing again';
    final last = _lastGeneration;
    if (last == null) return 'On · no backup yet';
    return 'On · ${_formatBackupTime(last.createdAtEpochMs)}';
  }

  String _devicesSummary() {
    if (!_replicateEnabled) return 'Sync off';
    if (_peers.isEmpty) return 'On · not paired yet';
    if (widget.syncListener != null) {
      return _peers.length == 1
          ? '${_peers.first.host} · paired'
          : '${_peers.length} devices paired';
    }
    return _syncStatusText();
  }

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  /// The CSV export: what the file is and who reads it, the Drive connection,
  /// and the one-off copy to this device.
  List<Widget> _buildExportPage() {
    final service = widget.syncService;
    final engine = widget.exportEngine;
    final isSignedIn = service?.isSignedIn ?? false;

    return [
      if (service != null) ...[
        _buildDriveCard(service, isSignedIn),
        const SizedBox(height: 16),
      ],
      _buildGroup([
        if (service != null && isSignedIn)
          _SettingsRow(
            title: 'Update after each label',
            subtitle: 'The file refreshes a moment after you label time',
            trailing: Switch(
              value: service.autoSyncEnabled,
              onChanged: (val) {
                setState(() => service.autoSyncEnabled = val);
              },
            ),
          ),
        _SettingsRow(
          title: 'Leave notes out',
          subtitle: 'The comment column stays empty; tags are kept',
          trailing: Switch(
            value: _redactComments,
            onChanged: _isProcessing ? null : _setRedactComments,
          ),
        ),
        if (service != null && isSignedIn && engine != null)
          _SettingsRow(
            title: 'Update now',
            subtitle: 'Only needed if automatic updates are off',
            trailing: const _RowAction(label: 'Update'),
            onTap: _isProcessing ? null : _handleSyncCsvNow,
          ),
      ]),
      if (engine != null) ...[
        const SizedBox(height: 24),
        _buildSectionHeader('OTHER WAYS'),
        _buildGroup([
          _SettingsRow(
            title: 'Save a copy to this device',
            subtitle: 'The same spreadsheet, as a file you keep',
            trailing: const _RowAction(label: 'Save'),
            onTap: _isProcessing ? null : _handleExportCsvNow,
          ),
        ]),
      ],
      if (service != null && isSignedIn) ...[
        const SizedBox(height: 24),
        _buildGroup([
          _SettingsRow(
            title: 'Disconnect Google Drive',
            subtitle: 'Stops updating the file; it stays in your Drive',
            onTap: _isProcessing ? null : _handleGoogleSignInToggle,
          ),
        ]),
      ],
    ];
  }

  List<Widget> _buildBackupPage() {
    return [
      _buildBackupCard(),
      if (_destinationUnreachable) ...[
        const SizedBox(height: 8),
        _buildBackupNote(
          'The backup folder cannot be reached. Choose it again so '
          'automatic backups can resume.',
          icon: Icons.folder_off_rounded,
        ),
      ],
      if (_destination?.isCloudSynced ?? false) ...[
        const SizedBox(height: 8),
        _buildBackupNote(
          'This folder syncs to a cloud service. Backups are '
          'unencrypted there, so the service can read them.',
          icon: Icons.cloud_rounded,
        ),
      ],
      const SizedBox(height: 16),
      _buildBackupGroup(),
      const SizedBox(height: 24),
      _buildGroup([
        _SettingsRow(
          title: 'Restore from backup',
          subtitle: 'Replaces this device’s record with a verified backup',
          onTap: _isProcessing ? null : _handleRestoreDatabaseNow,
        ),
      ]),
    ];
  }

  /// The replication state for this device: the switch that gates it, the
  /// paired devices, and on the Mac the cursor and intent counters one level
  /// down.
  List<Widget> _buildDevicesPage() {
    final isPhone = widget.syncListener != null;

    final pairedRows = <Widget>[
      for (final peer in _peers)
        _SettingsRow(
          title: peer.host,
          subtitle:
              'store ${_shortStoreId(peer.storeId)} · last seen '
              '${_formatBackupTime(peer.lastSeenEpochMs)}',
          trailing: widget.pairing == null
              ? const SizedBox.shrink()
              : _RowAction(
                  label: 'Disconnect',
                  onTap: _syncLoading ? null : () => _disconnectPeer(peer),
                ),
        ),
      if (isPhone)
        _SettingsRow(
          title: _peers.isEmpty ? 'Pair a device' : 'Pair another device',
          subtitle: 'Show a code the Mac scans once',
          onTap: widget.pairing == null || _isProcessing
              ? null
              : _openPhonePairing,
        ),
      if (!isPhone && _peers.isEmpty)
        _SettingsRow(
          title: 'Pair a phone',
          subtitle: widget.pairing == null
              ? 'Not paired yet'
              : 'Scan the code Tempo shows on the phone',
          onTap: widget.pairing == null ? null : _openPairing,
        ),
      if (!isPhone && widget.pairing != null && _peers.isNotEmpty)
        _SettingsRow(
          title: 'Pair another phone',
          subtitle: 'Scan the code Tempo shows on the phone',
          onTap: _syncLoading ? null : _openPairing,
        ),
    ];

    final moreRows = <Widget>[
      if (!isPhone)
        _SettingsRow(
          title: 'Technical details',
          subtitle: 'Last exchange, cursor, queued changes',
          opensPage: true,
          onTap: () => _openPage('Technical details', _buildSyncDetailsPage),
        ),
      if (widget.pairing != null && _peers.isNotEmpty)
        _SettingsRow(
          title: 'Unpair every device',
          subtitle: 'Each paired device must pair again',
          onTap: _syncLoading ? null : _revokeAllPeers,
        ),
    ];

    return [
      _buildGroup([
        _SettingsRow(
          title: 'Sync with paired devices',
          subtitle: _replicationSubtitle(isPhone),
          trailing: Switch(
            value: _replicateEnabled,
            onChanged: _syncLoading || _isProcessing
                ? null
                : _setReplicateEnabled,
          ),
        ),
      ]),
      if (pairedRows.isNotEmpty) ...[
        const SizedBox(height: 24),
        _buildSectionHeader('PAIRED'),
        _buildGroup(pairedRows),
      ],
      if (moreRows.isNotEmpty) ...[
        const SizedBox(height: 24),
        _buildGroup(moreRows),
      ],
    ];
  }

  List<Widget> _buildSyncDetailsPage() {
    final stats = _syncStats;
    final appliedSeq = stats?.appliedSeq ?? 0;
    final applied = stats?.intentsApplied ?? 0;
    final rejected = stats?.intentsRejected ?? 0;
    final pending = stats?.intentsPending ?? 0;
    final lastExchange = stats == null || stats.lastSuccessEpochMs <= 0
        ? 'No exchange yet'
        : _formatBackupTime(stats.lastSuccessEpochMs);

    return [
      _buildGroup([
        _SettingsRow(
          title: 'Last exchange',
          subtitle: lastExchange,
          trailing: const SizedBox.shrink(),
        ),
        _SettingsRow(
          title: 'Cursor',
          subtitle: 'applied_seq $appliedSeq',
          trailing: const SizedBox.shrink(),
        ),
        _SettingsRow(
          title: 'Intents',
          subtitle:
              '$applied applied · $rejected rejected · '
              '$pending pending',
          trailing: const SizedBox.shrink(),
        ),
      ]),
    ];
  }

  /// Drive connection on paper: what the file is for, where it lives, when it
  /// last changed, and the one button that matters in this state.
  Widget _buildDriveCard(GoogleDriveSyncService service, bool isSignedIn) {
    final lastSync = service.lastSyncTime;
    final status = !isSignedIn
        ? 'Google Drive not connected'
        : lastSync == null
        ? 'Connected · not updated yet'
        : 'Updated at ${_clock(lastSync)}';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TempoColors.panel,
        borderRadius: BorderRadius.circular(TempoRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tempo keeps a spreadsheet copy of your record in your Google '
            'Drive, so other apps can read it. BNPB reads this file.',
            style: TempoText.body.copyWith(
              color: TempoColors.ink,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: TempoColors.paper,
              borderRadius: BorderRadius.circular(TempoRadii.row),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.description_outlined,
                  color: TempoColors.ink,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Time track /',
                        style: TempoText.label.copyWith(
                          color: TempoColors.inkMuted,
                        ),
                      ),
                      Text(
                        'stt_records_automatic.csv',
                        style: TempoText.label.copyWith(
                          color: TempoColors.ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isSignedIn ? TempoColors.ink : TempoColors.track,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: TempoText.label.copyWith(
                    color: TempoColors.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          if (!isSignedIn) ...[
            const SizedBox(height: 14),
            _Pill(
              label: 'Connect Google Drive',
              filled: true,
              onTap: _isProcessing ? null : _handleGoogleSignInToggle,
            ),
          ],
        ],
      ),
    );
  }

  /// The newest verified backup on paper, with the one action anyone needs.
  Widget _buildBackupCard() {
    final last = _lastGeneration;
    final title = last == null
        ? 'No backup yet'
        : 'Backed up ${_formatBackupTime(last.createdAtEpochMs)}';
    final detail = _destinationLocator.isEmpty
        ? 'Choose a folder outside this device to keep copies in.'
        : last == null
        ? 'Copies go to ${_destinationLabel()}.'
        : 'A checked copy of this device’s record. '
              '$_keptGenerations kept in ${_destinationLabel()}.';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TempoColors.panel,
        borderRadius: BorderRadius.circular(TempoRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                last == null
                    ? Icons.history_rounded
                    : Icons.check_circle_outline_rounded,
                color: TempoColors.ink,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TempoText.title.copyWith(color: TempoColors.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: TempoText.label.copyWith(
              color: TempoColors.inkMuted,
              fontWeight: FontWeight.w500,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          _Pill(
            label: 'Back up now',
            filled: true,
            onTap: _isProcessing ? null : _handleBackupNow,
          ),
        ],
      ),
    );
  }

  Widget _buildBackupGroup() {
    final autoSubtitle = !_backupEnabled
        ? 'Off'
        : _destinationUnreachable
        ? 'On, but the folder needs to be chosen again'
        : 'Keeps a current copy while Tempo is open';

    return _buildGroup([
      _SettingsRow(
        title: 'Back up automatically',
        subtitle: autoSubtitle,
        trailing: Switch(
          value: _backupEnabled,
          onChanged: _isProcessing ? null : _setBackupEnabled,
        ),
      ),
      _SettingsRow(
        title: 'Folder',
        subtitle: _destinationLocator.isEmpty
            ? 'Somewhere off this device is safest'
            : null,
        trailing: _RowValue(
          _destinationLocator.isEmpty ? 'Choose' : _destinationLabel(),
        ),
        onTap: _isProcessing ? null : _chooseBackupDestination,
      ),
      _SettingsRow(
        title: 'Copies to keep',
        trailing: _RowValue('$_generations'),
        onTap: _chooseGenerations,
      ),
    ]);
  }

  /// One line under the switch. The phone has no exchange status to report, so
  /// it says whether it is serving and whether anyone is paired; the Mac keeps
  /// the client's own status.
  String _replicationSubtitle(bool isPhone) {
    if (!_replicateEnabled) {
      return isPhone
          ? 'Off \u00b7 this phone does not serve the Mac'
          : 'Off \u00b7 this Mac does not exchange with the phone';
    }
    if (_peers.isEmpty) return 'On \u00b7 waiting for a paired device';
    if (isPhone) return 'On \u00b7 listening for paired devices';
    return '${_syncStatusText()} \u00b7 runs while Tempo is open on the phone';
  }

  String _syncStatusText() {
    switch (_syncStats?.status) {
      case SyncClientStatus.syncing:
        return 'Exchanging';
      case SyncClientStatus.waitingForPhone:
        return 'Waiting for the phone';
      case SyncClientStatus.upToDate:
        return 'Up to date with the phone';
      case SyncClientStatus.failed:
        return 'Last exchange failed';
      case SyncClientStatus.idle:
      case null:
        return 'Not exchanging yet';
    }
  }

  String _shortStoreId(String storeId) =>
      storeId.length <= 8 ? storeId : storeId.substring(0, 8);

  /// A quiet line under the backup card for conditions the rows cannot state:
  /// a folder that looks cloud-synced, and a folder that no longer opens.
  Widget _buildBackupNote(String message, {required IconData icon}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TempoColors.surface,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        border: Border.all(color: TempoColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: TempoColors.textMuted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TempoText.label.copyWith(
                color: TempoColors.textMuted,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The folder's own name, which is all that fits on one row. A SAF locator is
  /// a tree URI whose last segment decodes to `primary:backups`.
  String _destinationLabel() {
    final locator = _destinationLocator;
    if (locator.startsWith('content://')) {
      try {
        final last = Uri.decodeComponent(locator.split('/').last);
        final name = last.split(':').last;
        if (name.isNotEmpty) return name;
      } catch (_) {}
      return 'Folder chosen';
    }
    final segments = locator.split('/').where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? locator : segments.last;
  }

  String _formatBackupTime(int epochMs) {
    final at = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final difference = today.difference(day).inDays;
    if (difference == 0) return 'Today $time';
    if (difference == 1) return 'Yesterday $time';
    return '${at.year}-${two(at.month)}-${two(at.day)} $time';
  }

  Widget _buildGroup(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          const Divider(height: 1, thickness: 1, color: TempoColors.line),
        );
      }
      children.add(rows[i]);
    }
    return Material(
      color: TempoColors.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(TempoRadii.row),
      child: Column(children: children),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: TempoText.overline.copyWith(color: TempoColors.textMuted),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  const _Pill({required this.label, required this.filled, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: filled ? TempoColors.ink : Colors.transparent,
        shape: StadiumBorder(
          side: filled
              ? BorderSide.none
              : const BorderSide(color: TempoColors.ink, width: 1.5),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Center(
              child: Text(
                label,
                style: TempoText.body.copyWith(
                  color: filled ? Colors.white : TempoColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A second-level Settings page: back to Settings, the title, then [body],
/// rebuilt whenever [revision] changes.
class _SettingsPage extends StatelessWidget {
  final String title;
  final ValueNotifier<int> revision;
  final List<Widget> Function() body;

  const _SettingsPage({
    required this.title,
    required this.revision,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TempoColors.background,
      body: SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, _, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('Settings'),
                  style: TextButton.styleFrom(
                    foregroundColor: TempoColors.textMuted,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.only(right: 12),
                    textStyle: TempoText.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TempoText.screenTitle.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 20),
              ...body(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small outline pill at the end of a row that acts right away, so it reads
/// as a button rather than a way into another page. Without [onTap] it only
/// labels the row's own tap.
class _RowAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _RowAction({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: ShapeDecoration(
        shape: const StadiumBorder(side: BorderSide(color: Colors.white24)),
      ),
      child: Text(
        label,
        style: TempoText.label.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (onTap == null) return pill;
    return InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(widthFactor: 1, child: pill),
      ),
    );
  }
}

/// The current value at the end of a row whose tap changes it.
class _RowValue extends StatelessWidget {
  final String value;

  const _RowValue(this.value);

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: TempoText.body.copyWith(
        color: TempoColors.textMuted,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Shows a chevron. Only rows that open another page set it; rows that act
  /// right away or show a value never do.
  final bool opensPage;

  const _SettingsRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.opensPage = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TempoText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TempoText.label.copyWith(
                        color: TempoColors.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
            if (trailing == null && opensPage)
              const Icon(
                Icons.chevron_right_rounded,
                color: TempoColors.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}

class _ColourBars extends StatelessWidget {
  final List<Color> colors;

  const _ColourBars({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in colors)
          Container(
            width: 5,
            height: 22,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}
