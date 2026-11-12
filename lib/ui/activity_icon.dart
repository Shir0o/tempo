import 'package:material_ui/material_ui.dart';

import '../data/models/models.dart';
import 'helpers/ui_helpers.dart';
import 'theme/tempo_theme.dart';

/// The one way an Activity's icon is drawn, so its emoji reads the same on
/// Today, in the filter sheet, the picker, History and Activities.
///
/// The default form is a swatch: the Activity's colour with its emoji
/// centred on it, or plain colour when it has no emoji yet. [ActivityIcon.glyph]
/// draws the emoji alone for surfaces already filled with the Activity's
/// colour (blocks), and draws nothing when there is no emoji.
///
/// Only emoji count as icons. Legacy Material icon names (`schedule`, `book`)
/// are treated as "no icon yet", the same rule the auto-assign pass uses.
class ActivityIcon extends StatelessWidget {
  final String iconName;
  final Color? color;
  final double size;
  final bool bordered;

  /// Swatch for [activity]: its colour with its emoji.
  ActivityIcon(
    Activity activity, {
    super.key,
    this.size = 24,
    this.bordered = false,
  }) : iconName = activity.iconName,
       color = UiHelpers.parseHexColor(activity.colorHex);

  /// Swatch from parts, for previews of an Activity that is not saved yet.
  const ActivityIcon.parts({
    super.key,
    required this.iconName,
    required Color this.color,
    this.size = 24,
    this.bordered = false,
  });

  /// The emoji alone, for surfaces already in the Activity's colour.
  ActivityIcon.glyph(Activity activity, {super.key, this.size = 16})
    : iconName = activity.iconName,
      color = null,
      bordered = false;

  /// True when [activity] wears an emoji, so callers can skip the gap
  /// around a [ActivityIcon.glyph] that would draw nothing.
  static bool has(Activity? activity) =>
      activity != null && emojiOf(activity.iconName) != null;

  /// The emoji an Activity wears, or null when it has none yet.
  static String? emojiOf(String iconName) =>
      UiHelpers.isEmoji(iconName) ? iconName.trim() : null;

  @override
  Widget build(BuildContext context) {
    final emoji = emojiOf(iconName);
    final tileColor = color;
    if (tileColor == null) {
      if (emoji == null) return const SizedBox.shrink();
      return ExcludeSemantics(child: _emoji(emoji, size));
    }
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tileColor,
          borderRadius: BorderRadius.circular(size * 0.32),
          border: bordered
              ? Border.all(color: TempoColors.ink, width: 2)
              : null,
        ),
        child: emoji == null ? null : _emoji(emoji, size * 0.58),
      ),
    );
  }

  static Widget _emoji(String emoji, double fontSize) => Text(
    emoji,
    textAlign: TextAlign.center,
    textScaler: TextScaler.noScaling,
    style: TextStyle(fontSize: fontSize, height: 1.0),
  );
}
