import 'package:flutter/material.dart';
import '../../core/export/csv_export_engine.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../data/database/tempo_database.dart';
import 'activity_manager_view.dart';
import 'helpers/ui_helpers.dart';

/// Settings screen for managing Google Drive cloud synchronization,
/// manual exports, database backups, and activity customization.
class SettingsView extends StatefulWidget {
  final TempoDatabase database;
  final GoogleDriveSyncService? syncService;
  final CsvExportEngine? exportEngine;

  const SettingsView({
    super.key,
    required this.database,
    this.syncService,
    this.exportEngine,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _isProcessing = false;

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

  Future<void> _handleBackupDatabaseNow() async {
    final service = widget.syncService;
    if (service == null) return;

    setState(() => _isProcessing = true);
    try {
      final id = await service.backupDatabaseToDrive();
      _setStatus('Database backup completed to Google Drive (ID: $id)');
    } catch (e) {
      _setStatus('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleRestoreDatabaseNow() async {
    final service = widget.syncService;
    if (service == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF22222C),
        title: const Text('Restore Database?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Restoring from Google Drive will overwrite current local database with the cloud backup.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Restore', style: TextStyle(color: Color(0xFF4CAF50))),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isProcessing = true);
    try {
      final file = await service.restoreDatabaseFromDrive();
      _setStatus('Database restored successfully from Google Drive: ${file.path}');
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

  @override
  Widget build(BuildContext context) {
    final syncService = widget.syncService;
    final isSignedIn = syncService?.isSignedIn ?? false;
    final lastSync = syncService?.lastSyncTime;

    return Scaffold(
      backgroundColor: const Color(0xFF121216),
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF121216),
        elevation: 0,
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // Google Drive Sync Group
          _buildSectionHeader('GOOGLE DRIVE CLOUD SYNC'),
          Material(
            color: const Color(0xFF1A1A22),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSignedIn
                          ? const Color(0xFF4CAF50).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.cloud_sync_outlined,
                      color: isSignedIn ? const Color(0xFF4CAF50) : Colors.white54,
                      size: 22,
                    ),
                  ),
                  title: Text(
                    isSignedIn ? 'Connected to Google Drive' : 'Google Drive Disconnected',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isSignedIn
                        ? (lastSync != null
                            ? 'Last synced: ${UiHelpers.formatDateHeader(lastSync)} ${lastSync.hour}:${lastSync.minute.toString().padLeft(2, '0')}'
                            : 'Ready for auto-sync')
                        : 'Connect for BNPB sync & cloud backup',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  trailing: TextButton(
                    onPressed: _isProcessing ? null : _handleGoogleSignInToggle,
                    child: Text(
                      isSignedIn ? 'Disconnect' : 'Connect',
                      style: TextStyle(
                        color: isSignedIn ? Colors.redAccent : const Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (syncService != null) ...[
                  const Divider(color: Colors.white10, height: 1),
                  SwitchListTile(
                    title: const Text('Automatic CSV Cloud Push', style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: const Text('Pushes stt_records_automatic.csv to "Time track" on timer stop', style: TextStyle(color: Colors.white38, fontSize: 11)),
                    value: syncService.autoSyncEnabled,
                    activeTrackColor: const Color(0xFF4CAF50),
                    onChanged: (val) {
                      setState(() => syncService.autoSyncEnabled = val);
                    },
                  ),
                  const Divider(color: Colors.white10, height: 1),
                  ListTile(
                    leading: const Icon(Icons.upload_file, color: Colors.white70, size: 20),
                    title: const Text('Sync CSV to Drive Now', style: TextStyle(color: Colors.white, fontSize: 13)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                    onTap: _isProcessing ? null : _handleSyncCsvNow,
                  ),
                  const Divider(color: Colors.white10, height: 1),
                  ListTile(
                    leading: const Icon(Icons.backup_outlined, color: Colors.white70, size: 20),
                    title: const Text('Backup Database to Drive', style: TextStyle(color: Colors.white, fontSize: 13)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                    onTap: _isProcessing ? null : _handleBackupDatabaseNow,
                  ),
                  const Divider(color: Colors.white10, height: 1),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore, color: Colors.white70, size: 20),
                    title: const Text('Restore Database from Drive', style: TextStyle(color: Colors.white, fontSize: 13)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                    onTap: _isProcessing ? null : _handleRestoreDatabaseNow,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Data & Habits Management
          _buildSectionHeader('HABITS & DATA'),
          Material(
            color: const Color(0xFF1A1A22),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.tune_rounded, color: Color(0xFF4CAF50), size: 20),
                  title: const Text('Manage Habits & Colors', style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: const Text('Customize activity icons, colors, and pinned status', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ActivityManagerView(database: widget.database),
                      ),
                    );
                  },
                ),
                const Divider(color: Colors.white10, height: 1),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined, color: Colors.white70, size: 20),
                  title: const Text('Export CSV Locally', style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text(
                    widget.exportEngine != null
                        ? widget.exportEngine!.targetFile.path
                        : 'stt_records_automatic.csv',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                  onTap: _isProcessing ? null : _handleExportCsvNow,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // About & Privacy
          _buildSectionHeader('ABOUT TEMPO'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Color(0xFF4CAF50), size: 18),
                    SizedBox(width: 8),
                    Text(
                      '100% Offline-First & Private',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tempo stores all tracking data directly on your hardware in SQLite and CSV formats. No accounts or surveillance telemetry. Cloud sync occurs exclusively via your personal Google Drive or local peer sync.',
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tempo v1.0.0 (Build 1)',
                  style: TextStyle(color: Colors.white24, fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
