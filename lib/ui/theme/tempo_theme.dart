import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Design D (Color Blocks) tokens shared by every Flutter surface.
/// DESIGN.md at the repo root is the normative description of these values.
class TempoColors {
  TempoColors._();

  /// Near-black ink: text on light panels, the open Lap in the strip.
  static const Color ink = Color(0xFF121210);
  static const Color inkMuted = Color(0xCC121210);
  static const Color inkFaint = Color(0x5C121210);

  /// Light paper: Lap panel, day cards, bottom sheets.
  static const Color panel = Color(0xFFE9E9E2);

  /// Lighter paper: fields and steppers placed on [panel].
  static const Color paper = Color(0xFFF7F7F4);

  /// Empty strip track and Untracked fill on light surfaces.
  static const Color track = Color(0xFFD2D2C8);

  /// The single accent: selected nav pill, open-Lap outline, undo action.
  static const Color accent = Color(0xFFC6F432);

  /// App background.
  static const Color background = Color(0xFF0B0B0A);

  /// Dark cards and rows on [background].
  static const Color surface = Color(0xFF1B1B18);

  /// Hairline between rows inside a [surface] card.
  static const Color line = Color(0xFF262622);

  /// Secondary text on dark surfaces.
  static const Color textMuted = Color(0xFFA8A8A8);

  /// Colours offered when creating or editing an Activity.
  static const List<Color> activityPalette = [
    Color(0xFF9AA5C8),
    Color(0xFFC3A6FF),
    Color(0xFFFFC94A),
    Color(0xFF5EE6D0),
    Color(0xFFC6F432),
    Color(0xFFFF8FB8),
    Color(0xFF7CC8FF),
    Color(0xFFFFB27A),
  ];
}

class TempoRadii {
  TempoRadii._();

  static const double row = 16;
  static const double block = 20;
  static const double card = 24;
  static const double sheet = 28;
  static const double pill = 999;
}

const String tempoFontFamily = 'SpaceGrotesk';

/// Text styles from DESIGN.md's type scale. Colour is left to the caller.
class TempoText {
  TempoText._();

  static const TextStyle screenTitle = TextStyle(
    fontFamily: tempoFontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.3,
    height: 1.1,
  );
  static const TextStyle title = TextStyle(
    fontFamily: tempoFontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );
  static const TextStyle body = TextStyle(
    fontFamily: tempoFontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle label = TextStyle(
    fontFamily: tempoFontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle overline = TextStyle(
    fontFamily: tempoFontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
  );
  static const TextStyle numeral = TextStyle(
    fontFamily: tempoFontFamily,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// App-wide Material theme for design D.
ThemeData buildTempoTheme() {
  const scheme = ColorScheme.dark(
    primary: TempoColors.accent,
    onPrimary: TempoColors.ink,
    secondary: TempoColors.panel,
    onSecondary: TempoColors.ink,
    surface: TempoColors.surface,
    onSurface: Colors.white,
    error: Color(0xFFFF6B5E),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: tempoFontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: TempoColors.background,
    canvasColor: TempoColors.background,
    cardColor: TempoColors.surface,
    dividerColor: TempoColors.line,
    appBarTheme: const AppBarTheme(
      backgroundColor: TempoColors.background,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? TempoColors.ink
            : TempoColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? TempoColors.accent
            : TempoColors.line,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: TempoColors.surface,
      contentTextStyle: TextStyle(
        fontFamily: tempoFontFamily,
        color: Colors.white,
        fontSize: 14,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TempoColors.panel,
      modalBarrierColor: Color(0xB3000000),
      showDragHandle: true,
      dragHandleColor: Color(0xFFC5C5BC),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(TempoRadii.sheet),
        ),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: TempoColors.panel,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: tempoFontFamily,
        color: TempoColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(
        fontFamily: tempoFontFamily,
        color: TempoColors.ink,
        fontSize: 15,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(TempoRadii.card)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: TempoColors.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: TempoColors.accent,
      indicatorShape: const StadiumBorder(),
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: tempoFontFamily,
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w600,
          color: s.contains(WidgetState.selected)
              ? Colors.white
              : TempoColors.textMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 22,
          color: s.contains(WidgetState.selected)
              ? TempoColors.ink
              : TempoColors.textMuted,
        ),
      ),
    ),
  );
}

/// Diagonal hatching: the mark of time that is not yet labeled.
class HatchPainter extends CustomPainter {
  final Color color;
  final double spacing;

  const HatchPainter({this.color = const Color(0x0F000000), this.spacing = 9});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HatchPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.spacing != spacing;
}

/// One segment of a [DayStripPainter], as fractions of the Day's length.
class DayStripSpan {
  final double start;
  final double end;
  final Color color;
  final bool hatched;
  final String semanticsLabel;
  final bool marksZoneChange;

  const DayStripSpan({
    required this.start,
    required this.end,
    required this.color,
    required this.hatched,
    required this.semanticsLabel,
    this.marksZoneChange = false,
  });
}

/// Draws the midnight-to-midnight strip: Records in their Activity colours,
/// Untracked Records hatched, the open Lap in black, zone changes marked.
class DayStripPainter extends CustomPainter {
  final List<DayStripSpan> spans;
  final Color trackColor;
  final Color markerColor;

  const DayStripPainter({
    required this.spans,
    required this.trackColor,
    required this.markerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(4),
    );
    canvas.drawRRect(track, Paint()..color = trackColor);

    canvas.save();
    canvas.clipRRect(track);
    for (final span in spans) {
      final left = span.start * size.width;
      final width = math.max(1.0, (span.end - span.start) * size.width);
      final rect = Rect.fromLTWH(left, 0, width, size.height);
      canvas.drawRect(rect, Paint()..color = span.color);
      if (span.hatched) {
        final hatch = Paint()
          ..color = const Color(0x26000000)
          ..strokeWidth = 1;
        for (double x = rect.left - size.height; x < rect.right; x += 6) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            hatch,
          );
        }
      }
      // A hairline between neighbours keeps the boundaries legible.
      canvas.drawRect(
        Rect.fromLTWH(left, 0, 1, size.height),
        Paint()..color = const Color(0x1AFFFFFF),
      );
    }
    canvas.restore();

    for (final span in spans.where((s) => s.marksZoneChange)) {
      final x = (span.end * size.width).clamp(0.0, size.width - 2);
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 2, size.height),
        Paint()..color = markerColor,
      );
      final marker = Path()
        ..moveTo(x - 3, 0)
        ..lineTo(x + 2, 0)
        ..lineTo(x - 0.5, 5)
        ..close();
      canvas.drawPath(marker, Paint()..color = markerColor);
    }
  }

  @override
  bool shouldRepaint(covariant DayStripPainter oldDelegate) =>
      oldDelegate.spans != spans || oldDelegate.trackColor != trackColor;
}
