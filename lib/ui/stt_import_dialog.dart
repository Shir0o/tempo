import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/import/stt_format_parser.dart';
import '../core/import/stt_import_service.dart';
import '../core/time/timezone_id.dart';
import '../data/database/tempo_database.dart';

/// Two-stage modal dialog for inspecting and importing Simple Time Tracker
/// (.backup or .csv) data into Tempo.
class SttImportDialog extends StatefulWidget {
  final String fileContent;
  final String fileName;
  final TempoDatabase database;
  final SttImportService importService;

  const SttImportDialog({
    super.key,
    required this.fileContent,
    required this.fileName,
    required this.database,
    required this.importService,
  });

  /// Displays the SttImportDialog modal.
  static Future<SttImportResult?> show(
    BuildContext context, {
    required String fileContent,
    required String fileName,
    required TempoDatabase database,
    required SttImportService importService,
  }) {
    return showDialog<SttImportResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SttImportDialog(
        fileContent: fileContent,
        fileName: fileName,
        database: database,
        importService: importService,
      ),
    );
  }

  @override
  State<SttImportDialog> createState() => _SttImportDialogState();
}

class _SttImportDialogState extends State<SttImportDialog> {
  late final SttParsedEnvelope _envelope;
  late final String _activeTimezone;
  late final bool _isBackupFormat;
  late final String? _dateSpanBadge;

  SttImportScope _selectedScope = SttImportScope.catalogOnly;
  bool _isImporting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _activeTimezone = widget.importService.getTimezoneId();
    _isBackupFormat =
        widget.fileName.toLowerCase().endsWith('.backup') ||
        widget.fileContent.contains('recordType\t') ||
        widget.fileContent.contains('recordType,');

    try {
      final now = widget.importService.nowUtcMs();
      _envelope = SttFormatParser.parse(
        content: widget.fileContent,
        wallClockToEpochMs: (wall) => epochMsFromWallClock(
          wall,
          _activeTimezone,
          referenceEpochMs: wall.millisecondsSinceEpoch,
        ),
        nowEpochMs: now,
      );

      // Determine date span if intervals exist
      if (_envelope.rawIntervals.isNotEmpty) {
        var minEpoch = _envelope.rawIntervals.first.startedAtEpochMs;
        var maxEpoch = _envelope.rawIntervals.first.endedAtEpochMs;
        for (final interval in _envelope.rawIntervals) {
          minEpoch = math.min(minEpoch, interval.startedAtEpochMs);
          maxEpoch = math.max(maxEpoch, interval.endedAtEpochMs);
        }

        final minDate = DateTime.fromMillisecondsSinceEpoch(
          minEpoch,
          isUtc: true,
        );
        final maxDate = DateTime.fromMillisecondsSinceEpoch(
          maxEpoch,
          isUtc: true,
        );
        final formatter = DateFormat('MMM yyyy');
        _dateSpanBadge =
            '${formatter.format(minDate)} – ${formatter.format(maxDate)}';

        // Default to full history if records exist
        _selectedScope = SttImportScope.fullHistory;
      } else {
        _dateSpanBadge = null;
        _selectedScope = SttImportScope.catalogOnly;
      }
    } catch (e) {
      _errorMessage = 'Failed to inspect file: $e';
      _envelope = const SttParsedEnvelope(
        categories: [],
        activities: [],
        rawIntervals: [],
      );
      _dateSpanBadge = null;
    }
  }

  Future<void> _handleImport() async {
    setState(() {
      _isImporting = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.importService.import(
        content: widget.fileContent,
        scope: _selectedScope,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
        _errorMessage = 'Import failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E26),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              _errorMessage != null &&
                  _envelope.activities.isEmpty &&
                  _envelope.categories.isEmpty
              ? _buildErrorView()
              : _isImporting
              ? _buildImportingView()
              : _buildDialogContent(),
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.error_outline_rounded,
          color: Colors.redAccent,
          size: 40,
        ),
        const SizedBox(height: 12),
        const Text(
          'Unable to Parse File',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _errorMessage ?? 'Unknown error occurred.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ],
    );
  }

  Widget _buildImportingView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        const SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Importing Data...',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _selectedScope == SttImportScope.fullHistory
              ? 'Reconciling continuous timeline and writing records...'
              : 'Saving categories and activities...',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildDialogContent() {
    final hasRecords = _envelope.rawIntervals.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.file_upload_outlined,
                  color: Color(0xFF4CAF50),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Import Simple Time Tracker',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      widget.fileName,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Stage 1: Inspection Summary Card
          _buildStage1SummaryCard(),
          const SizedBox(height: 16),

          // Stage 2: Scope Choice Selector
          const Text(
            'IMPORT SCOPE',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),

          _buildScopeCard(
            scope: SttImportScope.catalogOnly,
            title: 'Catalog Only (Categories & Activities)',
            subtitle: 'Sets up your activities and categories immediately. Existing history is untouched.',
            icon: Icons.category_outlined,
            enabled: true,
          ),
          const SizedBox(height: 8),

          _buildScopeCard(
            scope: SttImportScope.fullHistory,
            title: 'Full History + Catalog',
            subtitle: hasRecords
                ? 'Imports past tracking records with continuous coverage reconciliation (filling untracked gaps and midnight splits).'
                : 'No historical records detected in this file.',
            icon: Icons.history_rounded,
            enabled: hasRecords,
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 20),

          // Actions
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _handleImport,
                child: const Text('Proceed Import'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStage1SummaryCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14141B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Format Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _isBackupFormat ? 'Format: .backup' : 'Format: .csv',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Date Span Badge
              if (_dateSpanBadge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _dateSpanBadge,
                    style: const TextStyle(
                      color: Color(0xFF4CAF50),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Counts row
          Row(
            children: [
              _buildCountItem(
                'Categories',
                _envelope.categories.length.toString(),
              ),
              _buildCountDivider(),
              _buildCountItem(
                'Activities',
                _envelope.activities.length.toString(),
              ),
              if (_envelope.rawIntervals.isNotEmpty) ...[
                _buildCountDivider(),
                _buildCountItem(
                  'Records',
                  _envelope.rawIntervals.length.toString(),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 8),
          // Timezone Notice
          Row(
            children: [
              const Icon(
                Icons.schedule_rounded,
                color: Colors.white38,
                size: 14,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Timestamps will be reconciled in $_activeTimezone',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCountItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildCountDivider() {
    return Container(
      width: 1,
      height: 24,
      color: Colors.white10,
      margin: const EdgeInsets.symmetric(horizontal: 10),
    );
  }

  Widget _buildScopeCard({
    required SttImportScope scope,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool enabled,
  }) {
    final isSelected = _selectedScope == scope && enabled;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? () => setState(() => _selectedScope = scope) : null,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF4CAF50).withValues(alpha: 0.08)
                : const Color(0xFF16161E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF4CAF50)
                  : enabled
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.02),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF4CAF50)
                        : (enabled ? Colors.white38 : Colors.white12),
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF4CAF50),
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          icon,
                          size: 16,
                          color: enabled
                              ? (isSelected
                                    ? const Color(0xFF4CAF50)
                                    : Colors.white70)
                              : Colors.white24,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: enabled ? Colors.white : Colors.white38,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: enabled ? Colors.white54 : Colors.white24,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
