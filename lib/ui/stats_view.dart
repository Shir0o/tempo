import 'package:flutter/material.dart';

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'stats_calculator.dart';
import 'theme/tempo_theme.dart';

/// Totals: Day, Week and Month breakdowns of recorded time per Activity.
class StatsView extends StatefulWidget {
  final TempoDatabase database;

  /// Whether this tab is the one on screen. Stats reload whenever it becomes
  /// active, because the app shell keeps the tab alive across switches.
  final bool isActive;

  const StatsView({super.key, required this.database, this.isActive = true});

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _initials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  /// Untracked fill on light paper and on the Night swatch.
  static const _untrackedPaper = Color(0xFFCFCFC7);
  static const _untrackedSwatch = Color(0xFFE4E4DF);
  static const _chartHeight = 150.0;

  StatsPeriod _selectedPeriod = StatsPeriod.day;
  final DateTime _referenceDate = DateTime.now();
  bool _isLoading = true;
  StatsReport? _report;
  List<Record> _allRecords = [];
  Map<String, Activity> _activitiesMap = {};

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _loadData();
  }

  @override
  void didUpdateWidget(covariant StatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _loadData();
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
    final report = _report;
    return Scaffold(
      backgroundColor: TempoColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: TempoColors.accent,
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: TempoColors.accent),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 12),
                    if (report == null || report.totalDurationMs <= 0)
                      _buildEmpty()
                    else ...[
                      _buildLedger(report),
                      const SizedBox(height: 16),
                      _buildPerActivity(report),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Totals',
            style: TempoText.screenTitle.copyWith(color: Colors.white),
          ),
          Container(
            decoration: BoxDecoration(
              color: TempoColors.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: StatsPeriod.values.map((period) {
                final isSelected = _selectedPeriod == period;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onPeriodChanged(period),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? TempoColors.accent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(
                      period.label,
                      style: TempoText.label.copyWith(
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: isSelected
                            ? TempoColors.ink
                            : TempoColors.textMuted,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          'Nothing recorded in this period.',
          style: TempoText.body.copyWith(color: TempoColors.textMuted),
        ),
      ),
    );
  }

  // --- Ledger Paper card ---------------------------------------------------

  String _rangeTitle(StatsReport report) {
    final s = report.startDate;
    final e = report.endDate;
    String dm(DateTime d) => '${d.day} ${_months[d.month - 1]}';
    switch (report.period) {
      case StatsPeriod.day:
        return dm(s);
      case StatsPeriod.week:
        return '${dm(s)} – ${dm(e)}';
      case StatsPeriod.month:
        return '${_months[s.month - 1]} ${s.year}';
    }
  }

  String _totalLabel(int ms) {
    final hours = ms / 3600000;
    if (hours >= 10) return '${hours.round()}h';
    return UiHelpers.formatDurationHuman(ms);
  }

  Widget _buildLedger(StatsReport report) {
    final dayCount = report.days.length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TempoColors.panel,
        borderRadius: BorderRadius.circular(TempoRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _rangeTitle(report),
                style: TempoText.title.copyWith(color: TempoColors.ink),
              ),
              Text(
                '${_totalLabel(report.totalDurationMs)} · '
                '$dayCount ${dayCount == 1 ? 'day' : 'days'}',
                style: TempoText.label.copyWith(color: TempoColors.ink),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (report.period == StatsPeriod.day)
            _buildDayStrip(report)
          else
            _buildColumns(report),
        ],
      ),
    );
  }

  Color _activityColor(String? id) {
    if (id == null) return _untrackedPaper;
    final a = _activitiesMap[id];
    return UiHelpers.parseHexColor(a?.colorHex);
  }

  Widget _buildDayStrip(StatsReport report) {
    final day = report.days.first;
    final dayStartMs = day.date.millisecondsSinceEpoch;
    final spans = [
      for (final seg in day.segments)
        DayStripSpan(
          start: ((seg.startedAtEpochMs - dayStartMs) / day.lengthMs).clamp(
            0.0,
            1.0,
          ),
          end:
              ((seg.startedAtEpochMs + seg.durationMs - dayStartMs) /
                      day.lengthMs)
                  .clamp(0.0, 1.0),
          color: _activityColor(seg.activityId),
          hatched: seg.activityId == null,
          semanticsLabel: seg.activityId == null
              ? 'Untracked'
              : _activitiesMap[seg.activityId]?.name ?? 'Activity',
        ),
    ];
    final labelStyle = TempoText.overline.copyWith(
      color: TempoColors.inkMuted,
      letterSpacing: 0.3,
    );
    return Column(
      children: [
        SizedBox(
          height: 44,
          width: double.infinity,
          child: CustomPaint(
            painter: DayStripPainter(
              spans: spans,
              trackColor: TempoColors.track,
              markerColor: TempoColors.ink,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('00', style: labelStyle),
            Text('12', style: labelStyle),
            Text('24', style: labelStyle),
          ],
        ),
      ],
    );
  }

  Widget _buildColumns(StatsReport report) {
    final isMonth = report.period == StatsPeriod.month;
    final maxLen = report.days.fold<int>(
      1,
      (m, d) => d.lengthMs > m ? d.lengthMs : m,
    );
    // Stack order: Activities in the per-activity list's order, Untracked last.
    final order = [
      for (final a in report.activityBreakdowns) a.activityId,
      null,
    ];
    final gap = isMonth ? 2.0 : 6.0;
    final labelStyle = TempoText.overline.copyWith(
      color: TempoColors.ink,
      letterSpacing: 0.2,
      fontWeight: FontWeight.w600,
    );

    return Column(
      children: [
        SizedBox(
          height: _chartHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < report.days.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: SizedBox(
                    height: _chartHeight * report.days[i].lengthMs / maxLen,
                    child: CustomPaint(
                      painter: _ColumnPainter(
                        parts: _columnParts(report.days[i], order),
                        radius: isMonth ? 2 : 8,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < report.days.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(
                child: OverflowBox(
                  maxWidth: 40,
                  child: Text(
                    isMonth
                        ? (i % 7 == 0 ? '${report.days[i].date.day}' : '')
                        : _initials[report.days[i].date.weekday - 1],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: labelStyle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Segments of one Day's column, bottom to top, as fractions of the Day's
  /// real length. The unrecorded remainder stays as track.
  List<_ColumnPart> _columnParts(DayBucket day, List<String?> order) {
    final byActivity = <String?, int>{};
    for (final s in day.segments) {
      byActivity[s.activityId] = (byActivity[s.activityId] ?? 0) + s.durationMs;
    }
    return [
      for (final id in order)
        if ((byActivity[id] ?? 0) > 0)
          _ColumnPart(
            fraction: byActivity[id]! / day.lengthMs,
            color: _activityColor(id),
            hatched: id == null,
          ),
    ];
  }

  // --- Time per activity ---------------------------------------------------

  Widget _buildPerActivity(StatsReport report) {
    final dayCount = report.days.isEmpty ? 1 : report.days.length;
    final largest = [
      for (final a in report.activityBreakdowns) a.durationMs,
      report.untrackedDurationMs,
    ].fold<int>(1, (m, v) => v > m ? v : m);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
          child: Text(
            'Time per activity',
            style: TempoText.title.copyWith(
              fontSize: 16,
              letterSpacing: 0,
              color: Colors.white,
            ),
          ),
        ),
        for (final stat in report.activityBreakdowns) ...[
          _buildRow(
            name: stat.name,
            color: UiHelpers.parseHexColor(stat.colorHex),
            durationMs: stat.durationMs,
            fraction: stat.durationMs / largest,
            trailing: report.period == StatsPeriod.day
                ? '${stat.sessionCount} ${stat.sessionCount == 1 ? 'record' : 'records'}'
                : '${UiHelpers.formatDurationHuman(stat.durationMs ~/ dayCount)}\na day',
          ),
          const SizedBox(height: 6),
        ],
        if (report.untrackedCount > 0)
          _buildRow(
            name: 'Untracked',
            color: _untrackedSwatch,
            hatched: true,
            durationMs: report.untrackedDurationMs,
            fraction: report.untrackedDurationMs / largest,
            trailing:
                '${report.untrackedCount} ${report.untrackedCount == 1 ? 'gap' : 'gaps'}',
          ),
      ],
    );
  }

  Widget _buildRow({
    required String name,
    required Color color,
    required int durationMs,
    required double fraction,
    required String trailing,
    bool hatched = false,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(TempoRadii.row),
      child: Stack(
        children: [
          if (hatched)
            const Positioned.fill(
              child: CustomPaint(
                painter: HatchPainter(color: Color(0x0AFFFFFF), spacing: 12),
              ),
            ),
          Container(
            color: hatched ? Colors.transparent : null,
            decoration: hatched
                ? null
                : const BoxDecoration(color: TempoColors.surface),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: color),
                        if (hatched)
                          const CustomPaint(
                            painter: HatchPainter(
                              color: Color(0x1F000000),
                              spacing: 8,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TempoText.body.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            UiHelpers.formatDurationHuman(durationMs),
                            style: TempoText.numeral.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: SizedBox(
                          height: 6,
                          child: Stack(
                            children: [
                              const Positioned.fill(
                                child: ColoredBox(color: Color(0xFF2A2A27)),
                              ),
                              FractionallySizedBox(
                                widthFactor: fraction.clamp(0.0, 1.0),
                                heightFactor: 1,
                                alignment: Alignment.centerLeft,
                                child: ColoredBox(
                                  color: hatched ? _untrackedPaper : color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 56,
                  child: Text(
                    trailing,
                    textAlign: TextAlign.right,
                    style: TempoText.overline.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                      color: TempoColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnPart {
  final double fraction;
  final Color color;
  final bool hatched;

  const _ColumnPart({
    required this.fraction,
    required this.color,
    required this.hatched,
  });
}

/// One Day's stacked column, drawn bottom to top over an empty track.
class _ColumnPainter extends CustomPainter {
  final List<_ColumnPart> parts;
  final double radius;

  const _ColumnPainter({required this.parts, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final clip = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(clip, Paint()..color = TempoColors.track);
    canvas.save();
    canvas.clipRRect(clip);
    var bottom = size.height;
    for (final part in parts) {
      final h = part.fraction * size.height;
      final rect = Rect.fromLTWH(0, bottom - h, size.width, h);
      canvas.drawRect(rect, Paint()..color = part.color);
      if (part.hatched) {
        canvas.save();
        canvas.clipRect(rect);
        canvas.translate(rect.left, rect.top);
        const HatchPainter(
          color: Color(0x26000000),
          spacing: 6,
        ).paint(canvas, rect.size);
        canvas.restore();
      }
      bottom -= h;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ColumnPainter old) =>
      old.parts != parts || old.radius != radius;
}
