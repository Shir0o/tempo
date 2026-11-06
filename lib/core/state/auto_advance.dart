/// AutoAdvance: suggesting the next reading from the comments of earlier
/// Records with the same Activity and Person (see CONTEXT.md).
///
/// Pure and deterministic. Callers pick the matching Records; this file only
/// reads their comment text.
library;

/// A Record comment split around its NameMarker:
/// `<reading> w/ <Name>, <Name> <extra words>`.
class CommentParts {
  const CommentParts({
    required this.reading,
    required this.names,
    required this.extra,
  });

  /// The text before the NameMarker, trimmed.
  final String reading;

  /// The People named after the NameMarker, in order.
  final List<String> names;

  /// Free text after the last name, trimmed.
  final String extra;
}

final _nameMarker = RegExp(r'\b(?:w/\s*|with\s+)', caseSensitive: false);

/// One name: a word, plus a second word when that one is capitalised
/// (`Sam Lee`). Anything after that is free text.
final _name = RegExp(r'^\s*([^\s,]+)(?: (\p{Lu}[^\s,]*))?', unicode: true);
final _comma = RegExp(r'^\s*,');

/// Splits [comment] into its reading, the People named after the first
/// NameMarker (`w/` or `with `), and any trailing free text.
CommentParts splitComment(String comment) {
  final marker = _nameMarker.firstMatch(comment);
  if (marker == null) {
    return CommentParts(reading: comment.trim(), names: const [], extra: '');
  }
  var rest = comment.substring(marker.end);
  final names = <String>[];
  while (true) {
    final name = _name.firstMatch(rest);
    if (name == null) break;
    names.add([name.group(1)!, ?name.group(2)].join(' '));
    rest = rest.substring(name.end);
    final comma = _comma.firstMatch(rest);
    if (comma == null) break;
    rest = rest.substring(comma.end);
  }
  return CommentParts(
    reading: comment.substring(0, marker.start).trim(),
    names: names,
    extra: rest.trim(),
  );
}

/// The suggested next reading, given [earlierComments] (most recent first)
/// of Records that already share the AutoAdvance key. Returns only the reading
/// (the text before the NameMarker), or null when the most recent reading has
/// no number to move forward.
///
/// Cadence: a range moves on by its own length; a single chapter or number
/// moves by its jump from the reading before it (1 when there is none, or the
/// jump is 0 or less). Bible references move by chapter through the 66-book
/// Protestant order, wrapping from Revelation 22 to Genesis 1.
String? autoAdvance(List<String> earlierComments) {
  if (earlierComments.isEmpty) return null;
  final last = splitComment(earlierComments[0]).reading;
  final before = earlierComments.length > 1
      ? splitComment(earlierComments[1]).reading
      : null;
  return _advanceBible(last, before) ?? _advanceNumber(last, before);
}

// ---------------------------------------------------------------------------
// Bible

class _Book {
  const _Book(this.name, this.chapters, this.aliases);
  final String name;
  final int chapters;

  /// Normalised (lowercase, no dots or spaces) abbreviations.
  final List<String> aliases;
}

const _books = <_Book>[
  _Book('Genesis', 50, ['gen', 'ge', 'gn']),
  _Book('Exodus', 40, ['exod', 'exo', 'ex']),
  _Book('Leviticus', 27, ['lev', 'le', 'lv']),
  _Book('Numbers', 36, ['num', 'nu', 'nm', 'numb']),
  _Book('Deuteronomy', 34, ['deut', 'deu', 'de', 'dt']),
  _Book('Joshua', 24, ['josh', 'jos', 'jsh']),
  _Book('Judges', 21, ['judg', 'jdg', 'jg', 'jdgs']),
  _Book('Ruth', 4, ['rth', 'ru']),
  _Book('1 Samuel', 31, ['1sam', '1sa', '1sm']),
  _Book('2 Samuel', 24, ['2sam', '2sa', '2sm']),
  _Book('1 Kings', 22, ['1kgs', '1kg', '1ki', '1kin']),
  _Book('2 Kings', 25, ['2kgs', '2kg', '2ki', '2kin']),
  _Book('1 Chronicles', 29, ['1chr', '1ch', '1chron']),
  _Book('2 Chronicles', 36, ['2chr', '2ch', '2chron']),
  _Book('Ezra', 10, ['ezr']),
  _Book('Nehemiah', 13, ['neh', 'ne']),
  _Book('Esther', 10, ['esth', 'est', 'es']),
  _Book('Job', 42, ['jb']),
  _Book('Psalms', 150, ['psalm', 'ps', 'psa', 'pss', 'psm']),
  _Book('Proverbs', 31, ['prov', 'pro', 'prv', 'pr']),
  _Book('Ecclesiastes', 12, ['eccl', 'eccles', 'ecc', 'ec', 'qoh']),
  _Book('Song of Solomon', 8, ['song', 'songofsongs', 'sos', 'ss', 'cant']),
  _Book('Isaiah', 66, ['isa', 'is']),
  _Book('Jeremiah', 52, ['jer', 'je', 'jr']),
  _Book('Lamentations', 5, ['lam', 'la']),
  _Book('Ezekiel', 48, ['ezek', 'eze', 'ezk']),
  _Book('Daniel', 12, ['dan', 'da', 'dn']),
  _Book('Hosea', 14, ['hos', 'ho']),
  _Book('Joel', 3, ['jl']),
  _Book('Amos', 9, ['am']),
  _Book('Obadiah', 1, ['obad', 'ob']),
  _Book('Jonah', 4, ['jon', 'jnh']),
  _Book('Micah', 7, ['mic', 'mc']),
  _Book('Nahum', 3, ['nah', 'na']),
  _Book('Habakkuk', 3, ['hab', 'hb']),
  _Book('Zephaniah', 3, ['zeph', 'zep', 'zp']),
  _Book('Haggai', 2, ['hag', 'hg']),
  _Book('Zechariah', 14, ['zech', 'zec', 'zc']),
  _Book('Malachi', 4, ['mal', 'ml']),
  _Book('Matthew', 28, ['matt', 'mat', 'mt']),
  _Book('Mark', 16, ['mrk', 'mar', 'mk']),
  _Book('Luke', 24, ['luk', 'lk']),
  _Book('John', 21, ['jn', 'jhn', 'joh']),
  _Book('Acts', 28, ['act', 'ac']),
  _Book('Romans', 16, ['rom', 'ro', 'rm']),
  _Book('1 Corinthians', 16, ['1cor', '1co']),
  _Book('2 Corinthians', 13, ['2cor', '2co']),
  _Book('Galatians', 6, ['gal', 'ga']),
  _Book('Ephesians', 6, ['eph', 'ephes']),
  _Book('Philippians', 4, ['phil', 'php', 'pp']),
  _Book('Colossians', 4, ['col']),
  _Book('1 Thessalonians', 5, ['1thess', '1thes', '1th']),
  _Book('2 Thessalonians', 3, ['2thess', '2thes', '2th']),
  _Book('1 Timothy', 6, ['1tim', '1ti']),
  _Book('2 Timothy', 4, ['2tim', '2ti']),
  _Book('Titus', 3, ['tit']),
  _Book('Philemon', 1, ['philem', 'phlm', 'phm']),
  _Book('Hebrews', 13, ['heb']),
  _Book('James', 5, ['jas', 'jam', 'jm']),
  _Book('1 Peter', 5, ['1pet', '1pe', '1pt']),
  _Book('2 Peter', 3, ['2pet', '2pe', '2pt']),
  _Book('1 John', 5, ['1jn', '1jhn', '1jo', '1joh']),
  _Book('2 John', 1, ['2jn', '2jhn', '2jo', '2joh']),
  _Book('3 John', 1, ['3jn', '3jhn', '3jo', '3joh']),
  _Book('Jude', 1, ['jud', 'jd']),
  _Book('Revelation', 22, ['rev', 're', 'rv', 'revelations']),
];

String _normalise(String book) =>
    book.toLowerCase().replaceAll(RegExp(r'[.\s]'), '');

/// Normalised name or alias -> index into [_books].
final Map<String, int> _bookIndex = {
  for (var i = 0; i < _books.length; i++) ...{
    _normalise(_books[i].name): i,
    for (final alias in _books[i].aliases) alias: i,
  },
};

/// Absolute chapter index (Genesis 1 = 0) of each book's first chapter.
final List<int> _bookStart = () {
  final starts = <int>[];
  var total = 0;
  for (final book in _books) {
    starts.add(total);
    total += book.chapters;
  }
  return starts;
}();

final int _totalChapters = _bookStart.last + _books.last.chapters;

int _absolute(int book, int chapter) => _bookStart[book] + chapter - 1;

int _bookOf(int absolute) {
  var book = _books.length - 1;
  while (_bookStart[book] > absolute) {
    book--;
  }
  return book;
}

const _bookPattern = r'(?:[1-3]\s*)?\p{L}[\p{L}.]*(?:\s+\p{L}[\p{L}.]*)*';

/// `Book C[:V][-[Book ]C[:V]]`, the book optional after the first segment.
final _segment = RegExp(
  '^(?:($_bookPattern)\\s*)?(\\d+)(?::(\\d+))?'
  '(?:\\s*[-–]\\s*(?:($_bookPattern)\\s*)?(\\d+)(?::(\\d+))?)?\$',
  unicode: true,
);

/// A parsed Bible reading: its chapter spans (absolute, inclusive) and how
/// the user spelled each book in it.
class _Reading {
  _Reading(this.spans, this.spelling);
  final List<(int, int)> spans;
  final Map<int, String> spelling;

  int get chapterCount =>
      spans.fold(0, (sum, span) => sum + span.$2 - span.$1 + 1);
  int get end => spans.last.$2;
}

_Reading? _parseBible(String reading) {
  final spans = <(int, int)>[];
  final spelling = <int, String>{};
  int? currentBook;
  for (final segment in reading.split(RegExp('[,;]'))) {
    final match = _segment.firstMatch(segment.trim());
    if (match == null) return null;

    final bookText = match.group(1);
    if (bookText != null) {
      currentBook = _bookIndex[_normalise(bookText)];
      if (currentBook == null) return null;
      spelling.putIfAbsent(currentBook, () => bookText);
    }
    if (currentBook == null) return null;
    final startBook = currentBook;
    final startChapter = int.tryParse(match.group(2)!);

    var endBook = startBook;
    int? endChapter = startChapter;
    final endBookText = match.group(4);
    final endNumber = match.group(5);
    if (endBookText != null) {
      final found = _bookIndex[_normalise(endBookText)];
      if (found == null) return null;
      endBook = currentBook = found;
      spelling.putIfAbsent(found, () => endBookText);
      endChapter = int.tryParse(endNumber!);
    } else if (endNumber != null) {
      // `John 3:16-18` ends at a verse; `John 3-4` and `John 3:16-4:2` end at
      // a chapter.
      final endsAtVerse = match.group(3) != null && match.group(6) == null;
      if (!endsAtVerse) endChapter = int.tryParse(endNumber);
    }

    if (!_isChapter(startBook, startChapter) ||
        !_isChapter(endBook, endChapter)) {
      return null;
    }
    final start = _absolute(startBook, startChapter!);
    final end = _absolute(endBook, endChapter!);
    if (end < start) return null;
    spans.add((start, end));
  }
  return _Reading(spans, spelling);
}

bool _isChapter(int book, int? chapter) =>
    chapter != null && chapter >= 1 && chapter <= _books[book].chapters;

String? _advanceBible(String last, String? before) {
  final reading = _parseBible(last);
  if (reading == null) return null;

  final int start;
  final int length;
  if (reading.chapterCount > 1) {
    start = reading.end + 1;
    length = reading.chapterCount;
  } else {
    final previous = before == null ? null : _parseBible(before);
    final jump = previous == null ? 1 : reading.end - previous.end;
    start = reading.end + (jump > 0 ? jump : 1);
    length = 1;
  }

  // Group the chapters by book, wrapping after Revelation 22.
  final parts = <(int, int, int)>[]; // (book, first chapter, last chapter)
  for (var i = 0; i < length; i++) {
    final absolute = (start + i) % _totalChapters;
    final book = _bookOf(absolute);
    final chapter = absolute - _bookStart[book] + 1;
    if (parts.isNotEmpty && parts.last.$1 == book) {
      parts.last = (book, parts.last.$2, chapter);
    } else {
      parts.add((book, chapter, chapter));
    }
  }
  return parts
      .map((part) {
        final (book, first, lastChapter) = part;
        final name = reading.spelling[book] ?? _books[book].name;
        return first == lastChapter
            ? '$name $first'
            : '$name $first-$lastChapter';
      })
      .join(', ');
}

// ---------------------------------------------------------------------------
// Other text

final _lastRange = RegExp(r'(\d+)\s*[-–]\s*(\d+)(?=\D*$)');
final _lastNumber = RegExp(r'\d+(?=\D*$)');

String? _advanceNumber(String last, String? before) {
  final range = _lastRange.firstMatch(last);
  if (range != null) {
    final from = int.tryParse(range.group(1)!);
    final to = int.tryParse(range.group(2)!);
    if (from != null && to != null && to >= from) {
      final length = to - from + 1;
      return last.replaceRange(
        range.start,
        range.end,
        '${to + 1}-${to + length}',
      );
    }
  }

  final number = _lastNumber.firstMatch(last);
  final value = number == null ? null : int.tryParse(number.group(0)!);
  if (number == null || value == null) return null;

  var step = 1;
  final previous = before == null ? null : _lastNumber.firstMatch(before);
  final previousValue = previous == null
      ? null
      : int.tryParse(previous.group(0)!);
  if (previous != null &&
      previousValue != null &&
      _sameText(
        before!.substring(0, previous.start),
        last.substring(0, number.start),
      )) {
    final jump = value - previousValue;
    if (jump > 0) step = jump;
  }
  // Keep zero padding (`Week 05` -> `Week 06`).
  final next = '${value + step}'.padLeft(number.group(0)!.length, '0');
  return last.replaceRange(number.start, number.end, next);
}

bool _sameText(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();
