import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/state/day_recorder.dart';
import '../../data/models/tag.dart';
import '../helpers/ui_helpers.dart';
import '../theme/tempo_theme.dart';

/// Strip track on a Night Card (the dark day header). Not in the shared theme.
const Color historyDarkTrack = Color(0xFF2A2A27);

/// Untracked paper inside History blocks and the edit sheet's swatch.
const Color historyHatch = Color(0x1F000000);

const TextStyle _gutterStyle = TextStyle(
  fontFamily: tempoFontFamily,
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: TempoColors.textMuted,
  fontFeatures: [FontFeature.tabularFigures()],
);

const TextStyle _blockNameStyle = TextStyle(
  fontFamily: tempoFontFamily,
  fontSize: 16,
  fontWeight: FontWeight.w700,
  color: TempoColors.ink,
);

const TextStyle _blockDurationStyle = TextStyle(
  fontFamily: tempoFontFamily,
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: TempoColors.ink,
  fontFeatures: [FontFeature.tabularFigures()],
);

const TextStyle _blockEndStyle = TextStyle(
  fontFamily: tempoFontFamily,
  fontSize: 11,
  fontWeight: FontWeight.w500,
  color: TempoColors.inkMuted,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Header card for one Day: title, meta and its 00–24 strip. Today sits on
/// Ledger Paper; earlier Days on a Night Card.
class HistoryDayCard extends StatelessWidget {
  final String title;
  final String meta;
  final bool isLive;
  final List<DayStripSpan> spans;
  final String semanticsLabel;

  const HistoryDayCard({
    super.key,
    required this.title,
    required this.meta,
    required this.isLive,
    required this.spans,
    required this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isLive ? TempoColors.ink : Colors.white;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isLive ? TempoColors.panel : TempoColors.surface,
        borderRadius: BorderRadius.circular(TempoRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TempoText.title.copyWith(color: textColor),
                ),
              ),
              Text(
                meta,
                style: TempoText.label.copyWith(
                  color: isLive ? TempoColors.ink : TempoColors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          HistoryDayStrip(
            spans: spans,
            trackColor: isLive ? TempoColors.paper : historyDarkTrack,
            markerColor: isLive ? TempoColors.ink : Colors.white,
            semanticsLabel: semanticsLabel,
          ),
        ],
      ),
    );
  }
}

/// The 00–24 strip with a screen-reader label for the Day and each span.
class HistoryDayStrip extends StatelessWidget {
  final List<DayStripSpan> spans;
  final Color trackColor;
  final Color markerColor;
  final String semanticsLabel;

  const HistoryDayStrip({
    super.key,
    required this.spans,
    required this.trackColor,
    required this.markerColor,
    required this.semanticsLabel,
  });

  static const double _height = 16;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return SizedBox(
            height: _height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: DayStripPainter(
                      spans: spans,
                      trackColor: trackColor,
                      markerColor: markerColor,
                    ),
                  ),
                ),
                for (final span in spans)
                  Positioned(
                    left: (span.start * width).clamp(0, width),
                    width: math.max(
                      1.0,
                      ((span.end - span.start) * width).clamp(1.0, width),
                    ),
                    top: 0,
                    height: _height,
                    child: Semantics(
                      container: true,
                      label: span.semanticsLabel,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One row of the two-column timeline: a 48px lived-zone time gutter and a
/// block beside it.
class HistoryTimelineRow extends StatelessWidget {
  final String time;
  final Widget block;

  const HistoryTimelineRow({
    super.key,
    required this.time,
    required this.block,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: ExcludeSemantics(child: Text(time, style: _gutterStyle)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: block),
        ],
      ),
    );
  }
}

/// A labeled Record: Activity colour, ink text, name left, duration right,
/// optional end time below it, optional note and both lived times when the
/// Record crosses zones, then a chip per tag.
class HistoryRecordBlock extends StatelessWidget {
  final String name;
  final Color color;
  final String duration;
  final String? endLabel;
  final String? zonedRange;
  final String note;
  final List<Tag> tags;
  final String semanticsLabel;
  final VoidCallback onTap;

  const HistoryRecordBlock({
    super.key,
    required this.name,
    required this.color,
    required this.duration,
    this.endLabel,
    required this.zonedRange,
    required this.note,
    this.tags = const [],
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final secondary = TempoText.label.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: TempoColors.ink,
    );
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: _blockNameStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(duration, style: _blockDurationStyle),
                          if (endLabel != null)
                            Text(endLabel!, style: _blockEndStyle),
                        ],
                      ),
                    ],
                  ),
                  if (zonedRange != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      zonedRange!,
                      style: secondary.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: secondary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [for (final tag in tags) _TagChip(tag: tag)],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tag on a Record block: a translucent ink pill with the tag's colour as
/// a small swatch. Display only; the block itself is the tap target.
class _TagChip extends StatelessWidget {
  final Tag tag;

  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.only(left: 7, right: 9),
      decoration: BoxDecoration(
        color: TempoColors.ink.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(TempoRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: UiHelpers.parseHexColor(tag.colorHex),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            tag.name,
            style: TempoText.label.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: TempoColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// An Untracked Record: hatched paper, "Untracked · 20m" and an ink
/// "What was it?" pill. The whole block opens labeling.
class HistoryUntrackedBlock extends StatelessWidget {
  final String duration;
  final String? endLabel;
  final String? zonedRange;
  final String note;
  final String semanticsLabel;
  final VoidCallback onTap;

  const HistoryUntrackedBlock({
    super.key,
    required this.duration,
    this.endLabel,
    required this.zonedRange,
    required this.note,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final secondary = TempoText.label.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: TempoColors.ink,
    );
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        color: TempoColors.panel,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: CustomPaint(
            painter: const HatchPainter(color: historyHatch, spacing: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Untracked · $duration',
                            style: _blockNameStyle.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: TempoColors.ink,
                            borderRadius: BorderRadius.circular(
                              TempoRadii.pill,
                            ),
                          ),
                          child: Text(
                            'What was it?',
                            style: TempoText.label.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (endLabel != null)
                      Text(endLabel!, style: _blockEndStyle),
                    if (zonedRange != null)
                      Text(
                        zonedRange!,
                        style: secondary.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    if (note.isNotEmpty)
                      Text(
                        note,
                        style: secondary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Today's open Untracked stretch: a Night block with a 2px lime outline and a
/// live timer.
class HistoryOpenLapBlock extends StatefulWidget {
  final DayRecorder dayRecorder;
  final String since;

  const HistoryOpenLapBlock({
    super.key,
    required this.dayRecorder,
    required this.since,
  });

  @override
  State<HistoryOpenLapBlock> createState() => _HistoryOpenLapBlockState();
}

class _HistoryOpenLapBlockState extends State<HistoryOpenLapBlock> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsedMs = widget.dayRecorder.currentElapsedMs;
    return Semantics(
      container: true,
      label:
          'Untracked since ${widget.since}, '
          '${UiHelpers.formatDurationHuman(elapsedMs)}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: TempoColors.background,
          borderRadius: BorderRadius.circular(TempoRadii.row),
          border: Border.all(color: TempoColors.accent, width: 2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Untracked',
                style: _blockNameStyle.copyWith(color: Colors.white),
              ),
            ),
            Text(
              UiHelpers.formatMonospaceDuration(elapsedMs),
              style: _blockDurationStyle.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// Uppercase field label used inside the edit sheet.
class SheetOverline extends StatelessWidget {
  final String text;

  const SheetOverline(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TempoText.overline.copyWith(color: TempoColors.inkMuted),
    );
  }
}

/// A start or end stepper on Insert Paper: overline with the zone and Day,
/// ± circle buttons around the time, and what the move does.
class EdgeStepper extends StatelessWidget {
  final String overline;
  final String time;
  final String caption;
  final String edgeName;
  final VoidCallback? onEarlier;
  final VoidCallback? onLater;
  final VoidCallback? onPickTime;

  const EdgeStepper({
    super.key,
    required this.overline,
    required this.time,
    required this.caption,
    required this.edgeName,
    required this.onEarlier,
    required this.onLater,
    required this.onPickTime,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPickTime != null;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TempoColors.paper,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: SheetOverline(overline),
          ),
          Row(
            children: [
              _CircleStep(
                symbol: '−',
                semanticsLabel: '$edgeName 5 minutes earlier',
                onTap: onEarlier,
              ),
              Expanded(
                child: Semantics(
                  button: enabled,
                  label: '$edgeName $time, choose a time',
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: onPickTime,
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 48,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            time,
                            style: TempoText.numeral.copyWith(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.8,
                              color: enabled
                                  ? TempoColors.ink
                                  : TempoColors.inkFaint,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _CircleStep(
                symbol: '+',
                semanticsLabel: '$edgeName 5 minutes later',
                onTap: onLater,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              caption,
              style: TempoText.label.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: TempoColors.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleStep extends StatelessWidget {
  final String symbol;
  final String semanticsLabel;
  final VoidCallback? onTap;

  const _CircleStep({
    required this.symbol,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? TempoColors.inkFaint : TempoColors.ink;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
              child: Text(
                symbol,
                style: TextStyle(
                  fontFamily: tempoFontFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A selectable pill: ink fill and white text when selected, Insert Paper
/// otherwise, with an optional colour swatch. The tap target is 48dp tall.
class SheetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? swatch;
  final VoidCallback onTap;
  final double height;

  const SheetChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.swatch,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 48,
          child: Center(
            widthFactor: 1,
            child: Container(
              height: height,
              padding: EdgeInsets.only(
                left: swatch == null ? 12 : 10,
                right: 14,
              ),
              decoration: BoxDecoration(
                color: selected ? TempoColors.ink : TempoColors.paper,
                borderRadius: BorderRadius.circular(TempoRadii.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (swatch != null) ...[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: swatch,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: TempoText.label.copyWith(
                      fontSize: height >= 36 ? 14 : 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? Colors.white : TempoColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outline pill on paper: 2px ink border, 44px visual, 48dp target.
class SheetOutlineButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SheetOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null ? TempoColors.inkFaint : TempoColors.ink;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.padded,
        foregroundColor: TempoColors.ink,
        disabledForegroundColor: TempoColors.inkFaint,
        side: BorderSide(color: color, width: 2),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: tempoFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
