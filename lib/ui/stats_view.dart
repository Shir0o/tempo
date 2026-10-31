import 'package:flutter/material.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'stats_calculator.dart';

/// Comprehensive statistics screen offering Day, Week, and Month breakdowns
/// with activity distribution bars and core productivity metrics.
class StatsView extends StatefulWidget {
  final TempoDatabase database;

  const StatsView({super.key, required this.database});

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  StatsPeriod _selectedPeriod = StatsPeriod.day;
  final DateTime _referenceDate = DateTime.now();
  bool _isLoading = true;
  StatsReport? _report;
  List<Record> _allRecords = [];
  Map<String, Activity> _activitiesMap = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (!_isLoading && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final activities = await widget.database.getAllActivities(
        includeArchived: true,
      );
      final records = await widget.database.getRecords(limit: 5000);

      final map = {for (final a in activities) a.id: a};
      final report = StatsCalculator.calculate(
        records: records,
        activitiesMap: map,
        period: _selectedPeriod,
        referenceDate: _referenceDate,
      );

      if (mounted) {
        setState(() {
          _allRecords = records;
          _activitiesMap = map;
          _report = report;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onPeriodChanged(StatsPeriod period) {
    if (_selectedPeriod == period) return;
    setState(() {
      _selectedPeriod = period;
      _report = StatsCalculator.calculate(
        records: _allRecords,
        activitiesMap: _activitiesMap,
        period: _selectedPeriod,
        referenceDate: _referenceDate,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121216),
      appBar: AppBar(
        title: const Text(
          'Statistics',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: const Color(0xFF121216),
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: const Color(0xFF4CAF50),
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  children: [
                    _buildPeriodSelector(),
                    const SizedBox(height: 16),
                    _buildSummaryMetrics(),
                    const SizedBox(height: 20),
                    _buildBreakdownSection(),
                    const SizedBox(height: 32),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C24),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: StatsPeriod.values.map((period) {
          final isSelected = _selectedPeriod == period;
          return Expanded(
            child: GestureDetector(
              onTap: () => _onPeriodChanged(period),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF4CAF50)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  period.label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white60,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryMetrics() {
    final report = _report;
    if (report == null) return const SizedBox.shrink();

    final totalFormatted = UiHelpers.formatDurationHuman(
      report.totalDurationMs,
    );
    final avgFormatted = UiHelpers.formatDurationHuman(
      report.averageSessionDurationMs,
    );
    final mostActive = report.mostActiveHabit?.name ?? '—';
    final mostActiveColor = report.mostActiveHabit != null
        ? UiHelpers.parseHexColor(report.mostActiveHabit!.colorHex)
        : Colors.white38;

    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            title: 'TOTAL TRACKED',
            value: totalFormatted,
            icon: Icons.timer,
            accentColor: const Color(0xFF4CAF50),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricCard(
            title: 'MOST ACTIVE',
            value: mostActive,
            icon: Icons.star_rounded,
            accentColor: mostActiveColor,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricCard(
            title: 'AVG SESSION',
            value: avgFormatted,
            icon: Icons.access_time_rounded,
            accentColor: const Color(0xFF2196F3),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accentColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildBreakdownSection() {
    final report = _report;
    if (report == null || report.activityBreakdowns.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        alignment: Alignment.center,
        child: Column(
          children: [
            Icon(
              Icons.pie_chart_outline,
              size: 48,
              color: Colors.white.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 12),
            const Text(
              'No time logged for this period.',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'HABIT BREAKDOWN',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: report.activityBreakdowns.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final stat = report.activityBreakdowns[index];
            final color = UiHelpers.parseHexColor(stat.colorHex);
            final icon = UiHelpers.getIconData(stat.iconName);
            final durationStr = UiHelpers.formatDurationHuman(stat.durationMs);

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, color: color, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          stat.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        durationStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${stat.percentage.toStringAsFixed(1)}%',
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: stat.percentage / 100.0,
                      backgroundColor: Colors.white10,
                      color: color,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${stat.sessionCount} ${stat.sessionCount == 1 ? 'session' : 'sessions'}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
