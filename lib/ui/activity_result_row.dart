import 'package:flutter/material.dart';

import '../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

/// A full-width Activity row inside the filter sheet.
class ActivityResultRow extends StatelessWidget {
  final Activity activity;
  final int durationMs;
  final String? categoryName;
  final VoidCallback onTap;

  const ActivityResultRow({
    super.key,
    required this.activity,
    required this.durationMs,
    required this.onTap,
    this.categoryName,
  });

  @override
  Widget build(BuildContext context) {
    final duration = durationMs <= 0
        ? '—'
        : UiHelpers.formatDurationHuman(durationMs);
    final category = categoryName;

    return Semantics(
      button: true,
      label: '${activity.name}, $duration today. Tap to label untracked time.',
      child: InkWell(
        key: ValueKey('activity-result-${activity.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(TempoRadii.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: UiHelpers.parseHexColor(activity.colorHex),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      activity.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TempoText.body.copyWith(
                        color: TempoColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (category != null && category.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        category.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TempoText.overline.copyWith(
                          color: TempoColors.inkMuted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                duration,
                style: TempoText.label.copyWith(
                  color: TempoColors.inkMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
