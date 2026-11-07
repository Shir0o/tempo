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
    'bath': '🛁',
    'snack': '🍎',
    'brunch': '🥞',
    'baking': '🧁',
    'bake': '🧁',
    'swim': '🏊',
    'swimming': '🏊',
    'bike': '🚲',
    'cycling': '🚲',
    'hike': '🥾',
    'hiking': '🥾',
    'dance': '💃',
    'dancing': '💃',
    'sports': '⚽',
    'piano': '🎹',
    'guitar': '🎸',
    'singing': '🎤',
    'choir': '🎤',
    'haircut': '💈',
    'dentist': '🦷',
    'packing': '🧳',
    'moving': '📦',
    'photo': '📷',
    'photography': '📷',
    'sewing': '🧵',
    'knitting': '🧶',
    'puzzle': '🧩',
    'kids': '🧸',
    'baby': '🍼',
    'party': '🎉',
    'visit': '🏠',
    'home': '🏠',
    'relax': '🛋️',
  };

  /// Second choices for an emoji, in order, so two Activities that resolve to
  /// the same thing (Sleep and Nap, Reading and Bible) can still be told apart
  /// at a glance. Only used when the first choice is already worn.
  static const Map<String, List<String>> alternates = {
    '😴': ['💤', '🛌'],
    '🌙': ['🛋️'],
    '🍽️': ['🥘', '🍲'],
    '🥗': ['🥪', '🍱'],
    '🥣': ['🍳', '🥐'],
    '☕': ['🫖'],
    '🧹': ['🧼', '🪣'],
    '🚗': ['🚙', '🛵'],
    '🚆': ['🚇', '🚌'],
    '🚶': ['🚶‍♀️', '🌳'],
    '🏋️': ['💪', '🤸'],
    '🧘': ['🪷', '🕯️'],
    '🙏': ['🛐', '✝️'],
    '⛪': ['✝️', '🕊️'],
    '📖': ['📘', '📕', '📜'],
    '📚': ['📝', '🧑‍🎓'],
    '🎓': ['🏫'],
    '✏️': ['🖊️'],
    '🗂️': ['📁', '🧾'],
    '📧': ['📨', '📬'],
    '👥': ['🧑‍🤝‍🧑', '🗣️', '☕'],
    '📞': ['📱'],
    '💬': ['📱'],
    '💻': ['⌨️', '🖥️'],
    '💼': ['🏢', '📈'],
    '🎨': ['🖌️'],
    '🎵': ['🎶', '🎧'],
    '📺': ['🍿'],
    '🎮': ['🕹️', '🎲'],
    '🏥': ['🩺'],
    '💰': ['💳', '🏦'],
    '📄': ['🧾'],
    '🤝': ['💛'],
    '🏠': ['🏡'],
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

  /// Every emoji the table and its alternates can produce, in table order,
  /// without duplicates. Used to build the picker so auto and manual share one
  /// vocabulary.
  static final List<String> vocabulary = List.unmodifiable(
    {...table.values, for (final alts in alternates.values) ...alts}.toList(),
  );

  static final List<String> _singleWordKeys = [
    for (final key in table.keys)
      if (!key.contains(' ')) key,
  ];

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

  /// A best guess for a name [emojiForName] cannot resolve exactly: near
  /// misses of known words (plurals, `-ing`/`-ed` forms, typos, shared
  /// stems like `meditate` and `meditation`), then the same for
  /// [categoryName]. Null when nothing is close.
  static String? guess(String name, {String? categoryName}) {
    final exact = emojiForName(name);
    if (exact != null) return exact;
    final near = _nearMatch(name);
    if (near != null) return near;
    if (categoryName == null) return null;
    return emojiForName(categoryName) ?? _nearMatch(categoryName);
  }

  /// [guess], steered away from emoji in [taken] (the ones other Activities
  /// already wear) by trying the guess's [alternates]. Falls back to the
  /// shared emoji when every alternate is taken too, since a fitting
  /// duplicate beats an unrelated icon.
  static String? suggest(
    String name, {
    String? categoryName,
    Iterable<String> taken = const [],
  }) {
    final base = guess(name, categoryName: categoryName);
    if (base == null) return null;
    return distinct(base, taken);
  }

  /// [emoji], or its first alternate not in [taken].
  static String distinct(String emoji, Iterable<String> taken) {
    final used = taken.toSet();
    if (!used.contains(emoji)) return emoji;
    for (final alternate in alternates[emoji] ?? const <String>[]) {
      if (!used.contains(alternate)) return alternate;
    }
    return emoji;
  }

  /// Scans content tokens right to left (head noun first) for the closest
  /// known single word.
  static String? _nearMatch(String name) {
    final tokens = _tokens(name);
    final content = tokens
        .where((token) => !_stopWords.contains(token))
        .toList();
    for (final token in content.reversed) {
      if (token.length < 4) continue;
      for (final variant in _variants(token)) {
        final emoji = table[variant];
        if (emoji != null) return emoji;
      }
      String? best;
      var bestScore = 0;
      for (final key in _singleWordKeys) {
        final score = _closeness(token, key);
        if (score > bestScore) {
          bestScore = score;
          best = key;
        }
      }
      if (best != null) return table[best];
    }
    return null;
  }

  /// Simple English inflections of [token]: `walks` → `walk`,
  /// `dishes` → `dish`, `baking` → `bake`, `cleaned` → `clean`.
  static Iterable<String> _variants(String token) sync* {
    for (final suffix in const ['ing', 'ed', 'es', 's', 'er', 'ers']) {
      if (token.length - suffix.length < 3 || !token.endsWith(suffix)) {
        continue;
      }
      final stem = token.substring(0, token.length - suffix.length);
      yield stem;
      yield '${stem}e';
      // running → run, shopping → shop
      if (stem.length > 3 && stem[stem.length - 1] == stem[stem.length - 2]) {
        yield stem.substring(0, stem.length - 1);
      }
    }
    for (final suffix in const ['s', 'ing']) {
      yield '$token$suffix';
    }
  }

  /// How close two words are, 0 when not close enough to guess from. A long
  /// shared stem (5+ letters) or one typo in a word of 5+ letters counts.
  static int _closeness(String a, String b) {
    var prefix = 0;
    final shorter = math.min(a.length, b.length);
    while (prefix < shorter && a[prefix] == b[prefix]) {
      prefix++;
    }
    if (prefix >= 5) return prefix;
    if (shorter >= 5 && _withinOneEdit(a, b)) return 4;
    return 0;
  }

  static bool _withinOneEdit(String a, String b) {
    if ((a.length - b.length).abs() > 1) return false;
    var i = 0;
    var j = 0;
    var edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (b.length > a.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
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
