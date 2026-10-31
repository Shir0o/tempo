import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Helper utilities for UI formatting, color parsing, and icon mapping in Tempo.
class UiHelpers {
  /// Parses a hex color string (e.g. "#4CAF50", "4CAF50", "#FF4CAF50") to [Color].
  static Color parseHexColor(String? hexString, {Color fallback = const Color(0xFF4CAF50)}) {
    if (hexString == null || hexString.isEmpty) return fallback;
    var hex = hexString.replaceAll('#', '').trim();
    if (hex.length == 6) {
      hex = 'FF$hex';
    }
    if (hex.length == 8) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        return Color(value);
      }
    }
    return fallback;
  }

  /// Converts a [Color] to uppercase hex string "#RRGGBB".
  static String toHexColor(Color color) {
    return '#${(color.toARGB32() & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// Resolves an icon name to a Material [IconData].
  static IconData getIconData(String? iconName) {
    switch (iconName?.toLowerCase().trim()) {
      case 'code':
      case 'laptop':
      case 'computer':
        return Icons.code;
      case 'fitness_center':
      case 'workout':
      case 'gym':
        return Icons.fitness_center;
      case 'directions_run':
      case 'running':
      case 'run':
        return Icons.directions_run;
      case 'book':
      case 'reading':
      case 'read':
        return Icons.menu_book;
      case 'work':
      case 'business':
        return Icons.work_outline;
      case 'school':
      case 'study':
        return Icons.school_outlined;
      case 'brush':
      case 'art':
      case 'design':
        return Icons.brush_outlined;
      case 'music_note':
      case 'music':
        return Icons.music_note;
      case 'local_cafe':
      case 'coffee':
        return Icons.local_cafe_outlined;
      case 'sports_esports':
      case 'games':
      case 'gaming':
        return Icons.sports_esports_outlined;
      case 'bed':
      case 'sleep':
        return Icons.bed_outlined;
      case 'restaurant':
      case 'food':
        return Icons.restaurant_outlined;
      case 'build':
      case 'tools':
        return Icons.build_outlined;
      case 'phone_android':
      case 'mobile':
        return Icons.phone_android;
      case 'movie':
      case 'tv':
        return Icons.movie_outlined;
      case 'pets':
        return Icons.pets_outlined;
      case 'shopping_cart':
        return Icons.shopping_cart_outlined;
      case 'schedule':
      case 'timer':
      default:
        return Icons.schedule;
    }
  }

  /// Returns the name of an icon for storage.
  static String getIconName(IconData icon) {
    if (icon == Icons.code) return 'code';
    if (icon == Icons.fitness_center) return 'fitness_center';
    if (icon == Icons.directions_run) return 'directions_run';
    if (icon == Icons.menu_book) return 'book';
    if (icon == Icons.work_outline) return 'work';
    if (icon == Icons.school_outlined) return 'school';
    if (icon == Icons.brush_outlined) return 'brush';
    if (icon == Icons.music_note) return 'music_note';
    if (icon == Icons.local_cafe_outlined) return 'local_cafe';
    if (icon == Icons.sports_esports_outlined) return 'sports_esports';
    if (icon == Icons.bed_outlined) return 'bed';
    if (icon == Icons.restaurant_outlined) return 'restaurant';
    return 'schedule';
  }

  /// Formats duration as HH:mm:ss for ticking timers.
  static String formatMonospaceDuration(int durationMs) {
    if (durationMs < 0) durationMs = 0;
    final totalSeconds = durationMs ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    final hStr = hours.toString().padLeft(2, '0');
    final mStr = minutes.toString().padLeft(2, '0');
    final sStr = seconds.toString().padLeft(2, '0');
    return '$hStr:$mStr:$sStr';
  }

  /// Formats duration in human-readable style (e.g. "2h 15m", "45m", "30s").
  static String formatDurationHuman(int durationMs) {
    if (durationMs < 0) durationMs = 0;
    final totalSeconds = durationMs ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
    if (minutes > 0) {
      return '${minutes}m';
    }
    return '${seconds}s';
  }

  /// Formats date header: "Today", "Yesterday", or "EEE, MMM d, yyyy".
  static String formatDateHeader(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final recordDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    final differenceInDays = today.difference(recordDate).inDays;
    if (differenceInDays == 0) return 'Today';
    if (differenceInDays == 1) return 'Yesterday';

    return DateFormat('EEE, MMM d, yyyy').format(dateTime);
  }

  /// Formats time range: "14:00 – 15:30".
  static String formatTimeRange(DateTime start, DateTime end) {
    final startStr = DateFormat('HH:mm').format(start);
    final endStr = DateFormat('HH:mm').format(end);
    return '$startStr – $endStr';
  }
}
