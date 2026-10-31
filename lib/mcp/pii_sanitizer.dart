import '../data/models/active_timer.dart';
import '../data/models/record.dart';

/// Deterministic PII Sanitizer for the Tempo MCP Server.
///
/// Implements deterministic redaction:
/// 1. Masks contact names following `w/` and `with ` markers into session-consistent
///    pseudonyms (`[Contact-1]`, `[Contact-2]`, etc.).
/// 2. Masks email addresses (`[EMAIL]`).
/// 3. Masks phone numbers (`[PHONE]`).
/// 4. Masks URLs (`[URL]`).
/// 5. Preserves the `"Contact"` tag so LLMs understand relational time was spent
///    without exposing real identities.
class PIISanitizer {
  final bool enabled;
  final Map<String, String> _contactMap = {};
  int _contactCounter = 0;

  static final RegExp _urlRegex = RegExp(
    r'https?:\/\/[^\s()<>]+',
    caseSensitive: false,
  );

  static final RegExp _emailRegex = RegExp(
    r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
  );

  static final RegExp _phoneRegex = RegExp(
    r'(?:(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)[\s.-]?|\d{2,4}[\s.-])\d{3,4}[\s.-]\d{3,4}\b|(?:\+\d{10,14})\b)',
  );

  static final RegExp _contactMarkerRegex = RegExp(
    r'(\b(?:w\/|with)\s+)([A-Za-z]+(?:\s+[A-Za-z]+)?)',
    caseSensitive: false,
  );

  PIISanitizer({this.enabled = true});

  /// Map of known real names (lowercased) to session pseudonyms.
  Map<String, String> get contactMap => Map.unmodifiable(_contactMap);

  /// Resets the session pseudonyms mapping.
  void reset() {
    _contactMap.clear();
    _contactCounter = 0;
  }

  /// Sanitizes a comment string. If [enabled] is false or the comment is empty,
  /// returns the input unmodified.
  String sanitize(String comment) {
    if (!enabled || comment.isEmpty) {
      return comment;
    }

    // Step 1: Redact URLs first to prevent URL paths from matching other rules.
    var result = comment.replaceAllMapped(_urlRegex, (match) => '[URL]');

    // Step 2: Redact Emails.
    result = result.replaceAllMapped(_emailRegex, (match) => '[EMAIL]');

    // Step 3: Redact Phone Numbers.
    result = result.replaceAllMapped(_phoneRegex, (match) => '[PHONE]');

    // Step 4: Deterministically pseudonymize contact names following w/ or with.
    result = result.replaceAllMapped(_contactMarkerRegex, (match) {
      final prefix = match.group(1)!;
      final rawName = match.group(2)!;
      final key = rawName.trim().toLowerCase();

      final pseudonym = _contactMap.putIfAbsent(key, () {
        _contactCounter++;
        return '[Contact-$_contactCounter]';
      });

      return '$prefix$pseudonym';
    });

    return result;
  }

  /// Sanitizes the comment of a [Record], preserving all tags (including "Contact").
  Record sanitizeRecord(Record record) {
    if (!enabled) return record;
    return record.copyWith(comment: sanitize(record.comment));
  }

  /// Sanitizes comments across a list of [Record]s.
  List<Record> sanitizeRecords(List<Record> records) {
    if (!enabled) return records;
    return records.map(sanitizeRecord).toList();
  }

  /// Sanitizes the comment of an [ActiveTimer].
  ActiveTimer sanitizeActiveTimer(ActiveTimer timer) {
    if (!enabled) return timer;
    return timer.copyWith(currentComment: sanitize(timer.currentComment));
  }
}
