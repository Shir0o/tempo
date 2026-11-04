import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';

import '../../data/models/models.dart';

/// Represents a raw historical time tracking interval parsed from an STT file.
class SttRawInterval {
  final String activityName;
  final String categoryName;
  final int startedAtEpochMs;
  final int endedAtEpochMs;
  final String comment;
  final List<String> tagNames;

  const SttRawInterval({
    required this.activityName,
    this.categoryName = '',
    required this.startedAtEpochMs,
    required this.endedAtEpochMs,
    this.comment = '',
    this.tagNames = const [],
  });

  @override
  String toString() =>
      'SttRawInterval(activity: $activityName, category: $categoryName, start: $startedAtEpochMs, end: $endedAtEpochMs, comment: $comment, tags: $tagNames)';
}

/// The parsed envelope containing extracted categories, activities, and intervals.
class SttParsedEnvelope {
  final List<Category> categories;
  final List<Activity> activities;
  final List<SttRawInterval> rawIntervals;

  const SttParsedEnvelope({
    required this.categories,
    required this.activities,
    required this.rawIntervals,
  });
}

/// Pure Dart parser for Simple Time Tracker (STT) `.backup` and `.csv` files.
class SttFormatParser {
  /// STT color index (0-17) mapped to hex colors.
  static const List<String> sttColorPalette = [
    '#F44336', // 0: Red
    '#E91E63', // 1: Pink
    '#9C27B0', // 2: Purple
    '#673AB7', // 3: Deep Purple
    '#3F51B5', // 4: Indigo
    '#2196F3', // 5: Blue
    '#03A9F4', // 6: Light Blue
    '#00BCD4', // 7: Cyan
    '#009688', // 8: Teal
    '#4CAF50', // 9: Green
    '#8BC34A', // 10: Light Green
    '#CDDC39', // 11: Lime
    '#FFEB3B', // 12: Yellow
    '#FFC107', // 13: Amber
    '#FF9800', // 14: Orange
    '#FF5722', // 15: Deep Orange
    '#795548', // 16: Brown
    '#607D8B', // 17: Blue Grey
  ];

  /// Harmonious palette for synthesizing category colors from strings.
  static const List<String> harmoniousPalette = [
    '#4CAF50', // Green
    '#2196F3', // Blue
    '#FF9800', // Orange
    '#9C27B0', // Purple
    '#00BCD4', // Cyan
    '#E91E63', // Pink
    '#FFC107', // Amber
    '#3F51B5', // Indigo
    '#009688', // Teal
    '#795548', // Brown
    '#607D8B', // Blue Grey
    '#F44336', // Red
  ];

  /// Generates a deterministic harmonious color from a name string.
  static String deterministicColor(String name) {
    if (name.trim().isEmpty) return '#4CAF50';
    final bytes = md5.convert(utf8.encode(name.trim().toLowerCase())).bytes;
    final value = bytes[0] | (bytes[1] << 8);
    return harmoniousPalette[value % harmoniousPalette.length];
  }

  /// Maps an STT color token integer (or string representation) to a hex color string.
  static String mapColorToken(String? token) {
    if (token == null || token.isEmpty) return '#4CAF50';
    final index = int.tryParse(token.trim());
    if (index != null && index >= 0 && index < sttColorPalette.length) {
      return sttColorPalette[index];
    }
    return '#4CAF50';
  }

  /// Maps an STT icon drawable name (e.g. `ic_fitness_center_24px`) to a Flutter icon name.
  static String mapIconName(String? rawIcon) {
    if (rawIcon == null || rawIcon.isEmpty) return 'schedule';
    var clean = rawIcon.trim().toLowerCase();
    if (clean.startsWith('ic_')) {
      clean = clean.substring(3);
    }
    if (clean.endsWith('_24px')) {
      clean = clean.substring(0, clean.length - 5);
    }

    switch (clean) {
      case 'fitness_center':
      case 'directions_walk':
      case 'directions_run':
      case 'restaurant':
      case 'restaurant_menu':
      case 'free_breakfast':
      case 'computer':
      case 'code':
      case 'build':
      case 'delete':
      case 'shopping_cart':
      case 'shopping_bag':
      case 'local_bar':
      case 'local_hospital':
      case 'local_florist':
      case 'flight':
      case 'music_note':
      case 'music_video':
      case 'email':
      case 'translate':
      case 'snooze':
      case 'meeting_room':
      case 'terrain':
      case 'opacity':
      case 'mic':
      case 'videogame_asset':
      case 'turned_in':
      case 'turned_in_not':
      case 'assignment':
      case 'import_contacts':
      case 'lightbulb_outline':
      case 'airport_shuttle':
      case 'business_center':
      case 'settings_backup_restore':
      case 'add_task':
      case 'sync':
      case 'bakery_dining':
      case 'sports_bar':
      case 'speaker_notes':
      case 'fiber_new':
      case 'tablet':
      case 'hd':
      case 'grass':
      case 'markunread_mailbox':
      case 'check_box_outline_blank':
      case 'roofing':
      case '360':
      case 'attractions':
      case 'phonelink_off':
        return clean;
      case 'airline_seat_individual_suite':
      case 'bed':
        return 'bed';
      case 'book':
      case 'menu_book':
        return 'book';
      default:
        return 'schedule';
    }
  }

  /// Detects whether input is `.backup` (tab-delimited lines starting with tags or app header) or `.csv`.
  static bool isBackupFormat(String content) {
    final firstLine = content
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.startsWith('app simple time tracker') ||
        firstLine.startsWith('recordType\t') ||
        firstLine.startsWith('category\t') ||
        firstLine.startsWith('record\t')) {
      return true;
    }
    return false;
  }

  /// Parses an STT file content (either `.backup` or `.csv`).
  /// For `.csv`, timestamps are wall-clock local dates formatted as `yyyy-MM-dd HH:mm:ss`.
  /// [wallClockToEpochMs] converts a wall-clock local DateTime to UTC epoch ms.
  static SttParsedEnvelope parse({
    required String content,
    required int Function(DateTime wallClock) wallClockToEpochMs,
    int? nowEpochMs,
  }) {
    final now = nowEpochMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    if (isBackupFormat(content)) {
      return _parseBackup(content, now);
    } else {
      return _parseCsv(content, wallClockToEpochMs, now);
    }
  }

  static SttParsedEnvelope _parseBackup(String content, int nowEpochMs) {
    final lines = content.split('\n');
    final rawCategories = <String, Map<String, dynamic>>{}; // sttCatId -> map
    final rawTypes = <String, Map<String, dynamic>>{}; // sttTypeId -> map
    final typeToCategory = <String, String>{}; // sttTypeId -> sttCatId
    final rawIntervals = <SttRawInterval>[];

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      final recordKind = parts[0].trim();

      if (recordKind == 'category' && parts.length >= 4) {
        // category	1	Spiritual	3
        final catId = parts[1].trim();
        final name = parts[2].trim();
        final colorToken = parts[3].trim();
        if (name.isNotEmpty) {
          rawCategories[catId] = {
            'id': catId,
            'name': name,
            'color': mapColorToken(colorToken),
          };
        }
      } else if (recordKind == 'typeCategory' && parts.length >= 3) {
        // typeCategory	3	1
        final typeId = parts[1].trim();
        final catId = parts[2].trim();
        typeToCategory[typeId] = catId;
      } else if (recordKind == 'recordType' && parts.length >= 4) {
        // recordType	2	Exercise	ic_fitness_center_24px	5	0
        final typeId = parts[1].trim();
        final name = parts[2].trim();
        final iconRaw = parts[3].trim();
        final colorToken = parts.length > 4 ? parts[4].trim() : '';
        final isArchived = parts.length > 5 && parts[5].trim() == '1';

        if (name.isNotEmpty) {
          rawTypes[typeId] = {
            'id': typeId,
            'name': name,
            'icon': mapIconName(iconRaw),
            'color': mapColorToken(colorToken),
            'isArchived': isArchived,
          };
        }
      } else if (recordKind == 'record' && parts.length >= 5) {
        // record	2	4	1736279423000	1736279843000	comment
        final typeId = parts[2].trim();
        final startMs = int.tryParse(parts[3].trim());
        final endMs = int.tryParse(parts[4].trim());
        final comment = parts.length > 5 ? parts[5].trim() : '';

        if (startMs != null && endMs != null && endMs > startMs) {
          final typeData = rawTypes[typeId];
          final activityName = typeData != null
              ? typeData['name'] as String
              : 'Activity $typeId';
          final catId = typeToCategory[typeId];
          final catData = catId != null ? rawCategories[catId] : null;
          final catName = catData != null ? catData['name'] as String : '';

          rawIntervals.add(
            SttRawInterval(
              activityName: activityName,
              categoryName: catName,
              startedAtEpochMs: startMs,
              endedAtEpochMs: endMs,
              comment: comment,
            ),
          );
        }
      }
    }

    // Build Category models
    final categories = <Category>[];
    final categoryIdMap = <String, String>{}; // sttCatId -> generatedUuid
    var catSort = 0;
    for (final entry in rawCategories.entries) {
      final catData = entry.value;
      final name = catData['name'] as String;
      final color = catData['color'] as String;
      final cat = Category(
        id: 'cat-${entry.key}',
        name: name,
        colorHex: color,
        iconName: 'folder',
        sortOrder: catSort++,
        createdAtEpochMs: nowEpochMs,
        updatedAtEpochMs: nowEpochMs,
      );
      categories.add(cat);
      categoryIdMap[entry.key] = cat.id;
    }

    // Build Activity models
    final activities = <Activity>[];
    var actSort = 0;
    for (final entry in rawTypes.entries) {
      final actData = entry.value;
      final name = actData['name'] as String;
      final icon = actData['icon'] as String;
      final color = actData['color'] as String;
      final isArchived = actData['isArchived'] as bool;
      final sttCatId = typeToCategory[entry.key];
      final tempoCatId = sttCatId != null ? categoryIdMap[sttCatId] : null;
      final categoryColor = sttCatId != null
          ? (rawCategories[sttCatId]?['color'] as String?)
          : null;

      final act = Activity(
        id: 'act-${entry.key}',
        name: name,
        categoryId: tempoCatId,
        colorHex: categoryColor ?? color,
        iconName: icon,
        isArchived: isArchived,
        sortOrder: actSort++,
        createdAtEpochMs: nowEpochMs,
        updatedAtEpochMs: nowEpochMs,
      );
      activities.add(act);
    }

    return SttParsedEnvelope(
      categories: categories,
      activities: activities,
      rawIntervals: rawIntervals,
    );
  }

  static SttParsedEnvelope _parseCsv(
    String content,
    int Function(DateTime wallClock) wallClockToEpochMs,
    int nowEpochMs,
  ) {
    final rows = Csv(autoDetect: false).decode(content);

    if (rows.isEmpty) {
      return SttParsedEnvelope(
        categories: const [],
        activities: const [],
        rawIntervals: const [],
      );
    }

    // Header checking: find column indexes
    final header = rows.first
        .map((e) => e.toString().trim().toLowerCase())
        .toList();
    var actIndex = header.indexOf('activity name');
    var startIdx = header.indexOf('time started');
    var endIdx = header.indexOf('time ended');
    var commentIdx = header.indexOf('comment');
    var catIdx = header.indexOf('categories');
    var tagIdx = header.indexOf('record tags');

    // If header row is not found or standard, fallback to positions if length >= 3
    if (actIndex == -1 || startIdx == -1 || endIdx == -1) {
      actIndex = 0;
      startIdx = 1;
      endIdx = 2;
      commentIdx = 3;
      catIdx = 4;
      tagIdx = 5;
    }

    final rawIntervals = <SttRawInterval>[];
    final categoryNames = <String>{};
    final activityToCategory = <String, String>{};

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length <= endIdx) continue;

      final actName = row[actIndex].toString().trim();
      final startStr = row[startIdx].toString().trim();
      final endStr = row[endIdx].toString().trim();
      if (actName.isEmpty || startStr.isEmpty || endStr.isEmpty) continue;

      // Simple Time Tracker CSV wall-clock times are formatted as `yyyy-MM-dd HH:mm:ss`.
      // Parse with UTC indicator ('Z') so Dart constructs a pure UTC DateTime where
      // .millisecondsSinceEpoch reflects the raw wall-clock instant without host machine local zone bias.
      final startTime = DateTime.tryParse(
        startStr.endsWith('Z') ? startStr : '${startStr}Z',
      );
      final endTime = DateTime.tryParse(
        endStr.endsWith('Z') ? endStr : '${endStr}Z',
      );
      if (startTime == null || endTime == null) continue;

      final startEpochMs = wallClockToEpochMs(startTime);
      final endEpochMs = wallClockToEpochMs(endTime);
      if (endEpochMs <= startEpochMs) continue;

      final comment = commentIdx >= 0 && row.length > commentIdx
          ? row[commentIdx].toString().trim()
          : '';
      final categoryStr = catIdx >= 0 && row.length > catIdx
          ? row[catIdx].toString().trim()
          : '';
      final tagsStr = tagIdx >= 0 && row.length > tagIdx
          ? row[tagIdx].toString().trim()
          : '';

      final tagList = tagsStr.isEmpty
          ? const <String>[]
          : tagsStr
                .split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList();

      if (categoryStr.isNotEmpty) {
        categoryNames.add(categoryStr);
        if (!activityToCategory.containsKey(actName)) {
          activityToCategory[actName] = categoryStr;
        }
      } else if (!activityToCategory.containsKey(actName)) {
        activityToCategory[actName] = '';
      }

      rawIntervals.add(
        SttRawInterval(
          activityName: actName,
          categoryName: categoryStr,
          startedAtEpochMs: startEpochMs,
          endedAtEpochMs: endEpochMs,
          comment: comment,
          tagNames: tagList,
        ),
      );
    }

    // Synthesize Categories
    final categories = <Category>[];
    final catNameToId = <String, String>{};
    final catNameToColor = <String, String>{};
    var catSort = 0;
    for (final catName in categoryNames) {
      final catId = 'cat-csv-$catSort';
      final category = Category(
        id: catId,
        name: catName,
        colorHex: deterministicColor(catName),
        iconName: 'folder',
        sortOrder: catSort++,
        createdAtEpochMs: nowEpochMs,
        updatedAtEpochMs: nowEpochMs,
      );
      categories.add(category);
      catNameToId[catName] = catId;
      catNameToColor[catName] = category.colorHex;
    }

    // Synthesize Activities
    final activities = <Activity>[];
    var actSort = 0;
    for (final entry in activityToCategory.entries) {
      final actName = entry.key;
      final catName = entry.value;
      final catId = catNameToId[catName];
      final actColor = catId != null
          ? catNameToColor[catName]!
          : deterministicColor(actName);

      final act = Activity(
        id: 'act-csv-$actSort',
        name: actName,
        categoryId: catId,
        colorHex: actColor,
        iconName: 'schedule',
        sortOrder: actSort++,
        createdAtEpochMs: nowEpochMs,
        updatedAtEpochMs: nowEpochMs,
      );
      activities.add(act);
    }

    return SttParsedEnvelope(
      categories: categories,
      activities: activities,
      rawIntervals: rawIntervals,
    );
  }
}
