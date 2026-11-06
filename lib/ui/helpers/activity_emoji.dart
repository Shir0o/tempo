import 'dart:math' as math;

import 'ui_helpers.dart';

/// Offline emoji assignment for Activities.
///
/// The table is the whole vocabulary: the auto-assignment pass and the manual
/// picker both draw from it, so there is one set of icons in the product. It
/// deliberately favours concrete, lived activities (meals, prayer, errands)
/// over abstractions.
class ActivityEmoji {
  ActivityEmoji._();

  /// Keyword phrase (lower-case, single-space separated) to emoji.
  static const Map<String, String> table = {
    'sleep': '😴',
    'sleeping': '😴',
    'nap': '😴',
    'rest': '🌙',
    'wake': '🌅',
    'morning': '🌅',
    'breakfast': '🥣',
    'coffee': '☕',
    'tea': '🍵',
    'lunch': '🥗',
    'dinner': '🍽️',
    'meal': '🍽️',
    'cooking': '🍳',
    'cook': '🍳',
    'groceries': '🛒',
    'grocery': '🛒',
    'shopping': '🛍️',
    'errands': '🧾',
    'laundry': '🧺',
    'cleaning': '🧹',
    'chores': '🧹',
    'dishes': '🧽',
    'commute': '🚗',
    'driving': '🚗',
    'drive': '🚗',
    'transit': '🚆',
    'train': '🚆',
    'bus': '🚌',
    'flight': '✈️',
    'travel': '✈️',
    'walk': '🚶',
    'walking': '🚶',
    'run': '🏃',
    'running': '🏃',
    'workout': '🏋️',
    'gym': '🏋️',
    'exercise': '🏋️',
    'yoga': '🧘',
    'stretch': '🧘',
    'meditation': '🧘',
    'prayer': '🙏',
    'pray': '🙏',
    'prayer meeting': '🤲',
    'worship': '🕊️',
    'church': '⛪',
    'ministry': '⛪',
    'bible': '📖',
    'scripture': '📖',
    'reading': '📖',
    'read': '📖',
    'study': '📚',
    'studying': '📚',
    'class': '🎓',
    'school': '🎓',
    'lecture': '🎓',
    'homework': '✏️',
    'writing': '✍️',
    'notes': '🗒️',
    'journal': '📓',
    'planning': '🗓️',
    'coordination': '🗂️',
    'admin': '🗂️',
    'email': '📧',
    'emails': '📧',
    'inbox': '📧',
    'meeting': '👥',
    'meetings': '👥',
    'call': '📞',
    'calls': '📞',
    'phone': '📞',
    'messages': '💬',
    'texting': '💬',
    'chat': '💬',
    'coding': '💻',
    'code': '💻',
    'programming': '💻',
    'work': '💼',
    'deep work': '💼',
    'office': '💼',
    'project': '📋',
    'design': '🎨',
    'art': '🎨',
    'drawing': '✏️',
    'music': '🎵',
    'practice': '🎼',
    'television': '📺',
    'tv': '📺',
    'movie': '🎬',
    'gaming': '🎮',
    'games': '🎮',
    'friends': '👥',
    'family': '👨‍👩‍👧',
    'date': '🌹',
    'doctor': '🏥',
    'health': '❤️',
    'therapy': '🧠',
    'budget': '💰',
    'finances': '💰',
    'bills': '📄',
    'taxes': '📄',
    'service': '🤝',
    'volunteering': '🤝',
    'fellowship': '👥',
    'language': '🗣️',
    'podcast': '🎧',
    'news': '📰',
    'garden': '🌱',
    'plants': '🪴',
    'pet': '🐾',
    'dog': '🐕',
    'cat': '🐈',
    'shower': '🚿',
    'hygiene': '🚿',
  };

  /// Words that never carry the meaning of an Activity name, so they are
  /// skipped when the matcher looks for the head noun.
  static const Set<String> _stopWords = {
    'a',
    'an',
    'and',
    'at',
    'for',
    'her',
    'his',
    'in',
    'my',
    'of',
    'on',
    'our',
    'the',
    'their',
    'to',
    'with',
    'your',
  };

  static final int _maxPhraseTokens = table.keys
      .map((key) => key.split(' ').length)
      .reduce(math.max);

  /// Every emoji the table can produce, in table order, without duplicates.
  /// Used to build the picker so auto and manual share one vocabulary.
  static final List<String> vocabulary = List.unmodifiable(
    table.values.toSet().toList(),
  );

  /// Resolves an Activity name to an emoji, or null when the table has no
  /// answer.
  ///
  /// Precedence: longest known multi-word phrase, then the head noun (the last
  /// token that is not a stop word), then the nearest known token scanning
  /// right to left. `ministry reading` resolves on `reading`, while
  /// `prayer meeting` keeps its phrase.
  static String? emojiForName(String name) {
    final tokens = _tokens(name);
    if (tokens.isEmpty) return null;

    final longestPhrase = math.min(tokens.length, _maxPhraseTokens);
    for (var length = longestPhrase; length >= 2; length--) {
      for (var start = 0; start + length <= tokens.length; start++) {
        final emoji = table[tokens.sublist(start, start + length).join(' ')];
        if (emoji != null) return emoji;
      }
    }

    final content = tokens
        .where((token) => !_stopWords.contains(token))
        .toList();
    final search = content.isEmpty ? tokens : content;

    final headEmoji = table[search.last];
    if (headEmoji != null) return headEmoji;

    for (final token in search.reversed) {
      final emoji = table[token];
      if (emoji != null) return emoji;
    }
    return null;
  }

  /// The letter shown for an Activity the table cannot resolve.
  static String monogram(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  /// True when the stored icon is not an emoji yet, so the assignment pass
  /// should replace it. Material icon names and the empty string both qualify,
  /// which keeps the pass idempotent and manual picks safe.
  static bool needsIcon(String iconName) => !UiHelpers.isEmoji(iconName);

  static List<String> _tokens(String name) {
    final normalized = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    if (normalized.isEmpty) return const [];
    return normalized.split(' ');
  }
}
