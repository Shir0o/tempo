import 'package:flutter/material.dart';

import '../../core/export/csv_export_engine.dart';
import '../../core/sync/google_drive_sync_service.dart';
import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'activity_manager_view.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

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
  List<Activity> _activities = [];

  @override
  void initState() {
    super.initState();
    _loadActivities();
  }

  Future<void> _loadActivities() async {
    try {
      final list = await widget.database.getAllActivities(
        includeArchived: true,
      );
      if (mounted) setState(() => _activities = list);
    } catch (_) {}
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
        title: const Text('Restore Database?'),
        content: const Text(
          'Restoring from Google Drive will overwrite current local database with the cloud backup.',
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
      final file = await service.restoreDatabaseFromDrive();
      _setStatus(
        'Database restored successfully from Google Drive: ${file.path}',
      );
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
    final active = _activities.where((a) => !a.isArchived).toList();
    final archivedCount = _activities.length - active.length;

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
            _buildDriveCard(isSignedIn, lastSync, syncService != null),
            if (syncService != null) ...[
              const SizedBox(height: 12),
              _buildGroup([
                _SettingsRow(
                  title: 'Send CSV after each label',
                  subtitle: 'stt_records_automatic.csv',
                  trailing: Switch(
                    value: syncService.autoSyncEnabled,
                    onChanged: (val) {
                      setState(() => syncService.autoSyncEnabled = val);
                    },
                  ),
                ),
                _SettingsRow(
                  title: 'Back up database to Drive',
                  onTap: _isProcessing ? null : _handleBackupDatabaseNow,
                ),
                _SettingsRow(
                  title: 'Restore database from Drive',
                  onTap: _isProcessing ? null : _handleRestoreDatabaseNow,
                ),
              ]),
            ],
            const SizedBox(height: 24),
            _buildSectionHeader('DATA'),
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
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ActivityManagerView(database: widget.database),
                    ),
                  );
                  _loadActivities();
                },
              ),
              _SettingsRow(
                title: 'Export CSV to this device',
                subtitle: 'Simple Time Tracker format',
                onTap: _isProcessing ? null : _handleExportCsvNow,
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
                    'Tempo v1.0.0 (Build 1)',
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

  Widget _buildDriveCard(bool isSignedIn, DateTime? lastSync, bool hasService) {
    final String detail;
    if (!isSignedIn) {
      detail = 'Connect for BNPB sync & cloud backup';
    } else if (lastSync != null) {
      final hh = lastSync.hour.toString().padLeft(2, '0');
      final mm = lastSync.minute.toString().padLeft(2, '0');
      detail = 'CSV last sent to \u201cTime track\u201d at $hh:$mm for BNPB';
    } else {
      detail = 'Ready to send CSV to \u201cTime track\u201d for BNPB';
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TempoColors.panel,
        borderRadius: BorderRadius.circular(TempoRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: isSignedIn ? TempoColors.ink : TempoColors.track,
                  shape: BoxShape.circle,
                  border: isSignedIn
                      ? Border.all(color: TempoColors.accent, width: 3)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isSignedIn
                      ? 'Google Drive connected'
                      : 'Google Drive not connected',
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
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (isSignedIn && hasService) ...[
                Expanded(
                  child: _Pill(
                    label: 'Send CSV now',
                    filled: true,
                    onTap: _isProcessing ? null : _handleSyncCsvNow,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: _Pill(
                  label: isSignedIn ? 'Disconnect' : 'Connect',
                  filled: !isSignedIn,
                  onTap: _isProcessing ? null : _handleGoogleSignInToggle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
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

class _SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
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
            trailing ??
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
