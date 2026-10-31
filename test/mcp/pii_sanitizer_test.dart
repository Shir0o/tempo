import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/data/models/active_timer.dart';
import 'package:tempo/data/models/record.dart';
import 'package:tempo/mcp/pii_sanitizer.dart';

void main() {
  group('PIISanitizer', () {
    late PIISanitizer sanitizer;

    setUp(() {
      sanitizer = PIISanitizer();
    });

    test('replaces contact names following w/ and with with pseudonyms', () {
      final input1 = 'Quarterly review w/ Alice Smith';
      final sanitized1 = sanitizer.sanitize(input1);
      expect(sanitized1, equals('Quarterly review w/ [Contact-1]'));

      final input2 = 'Coffee chat with Bob Jones';
      final sanitized2 = sanitizer.sanitize(input2);
      expect(sanitized2, equals('Coffee chat with [Contact-2]'));
    });

    test('maps repeated contact names to the same consistent pseudonym in a session', () {
      expect(sanitizer.sanitize('Sync w/ Alice Smith'), equals('Sync w/ [Contact-1]'));
      expect(sanitizer.sanitize('Call with Charlie Brown'), equals('Call with [Contact-2]'));
      expect(sanitizer.sanitize('Follow-up w/ Alice Smith'), equals('Follow-up w/ [Contact-1]'));
      expect(sanitizer.sanitize('Wrap-up with Charlie Brown'), equals('Wrap-up with [Contact-2]'));
    });

    test('masks single-word contact names properly', () {
      expect(sanitizer.sanitize('Lunch with Diana'), equals('Lunch with [Contact-1]'));
      expect(sanitizer.sanitize('Discussion w/ Diana'), equals('Discussion w/ [Contact-1]'));
    });

    test('masks email addresses with [EMAIL]', () {
      final input = 'Sent report to alice.smith@example.com and team@tempo.app';
      final sanitized = sanitizer.sanitize(input);
      expect(sanitized, equals('Sent report to [EMAIL] and [EMAIL]'));
    });

    test('masks URLs with [URL]', () {
      final input = 'Checked https://github.com/flutter/flutter and http://tempo.dev/docs';
      final sanitized = sanitizer.sanitize(input);
      expect(sanitized, equals('Checked [URL] and [URL]'));
    });

    test('masks various phone number formats with [PHONE] without masking dates or times', () {
      expect(sanitizer.sanitize('Call at +1-555-123-4567'), equals('Call at [PHONE]'));
      expect(sanitizer.sanitize('Reach me at 555-123-4567'), equals('Reach me at [PHONE]'));
      expect(sanitizer.sanitize('Office: (555) 123-4567'), equals('Office: [PHONE]'));
      expect(sanitizer.sanitize('Direct: 555.123.4567'), equals('Direct: [PHONE]'));
      expect(sanitizer.sanitize('UK: +44 20 7946 0958'), equals('UK: [PHONE]'));

      // Crucial: ISO dates, times, and hex colors must NOT be masked as phone numbers
      expect(sanitizer.sanitize('Logged session on 2026-10-31'), equals('Logged session on 2026-10-31'));
      expect(sanitizer.sanitize('Completed at 14:30:00 UTC'), equals('Completed at 14:30:00 UTC'));
      expect(sanitizer.sanitize('Accent color is #4CAF50'), equals('Accent color is #4CAF50'));
    });

    test('preserves non-PII comments verbatim', () {
      final comment = 'Refactoring SQLite database state machine and fixing unit tests';
      expect(sanitizer.sanitize(comment), equals(comment));
    });

    test('handles compound comments with names, emails, URLs, and phones together', () {
      final input =
          'Client meeting w/ Alice Smith (alice@example.com, +1-555-123-4567) about https://client.org/spec';
      final output = sanitizer.sanitize(input);
      expect(
        output,
        equals('Client meeting w/ [Contact-1] ([EMAIL], [PHONE]) about [URL]'),
      );
    });

    test('preserves Contact tag on Record while masking comment', () {
      final record = Record(
        id: 'rec-1',
        activityId: 'act-1',
        startedAtEpochMs: 1000,
        endedAtEpochMs: 2000,
        durationMs: 1000,
        comment: '1:1 w/ Alice Smith',
        timezoneId: 'UTC',
        createdAtEpochMs: 1000,
        updatedAtEpochMs: 2000,
        tagIds: const ['tag-contact', 'tag-work'],
      );

      final sanitized = sanitizer.sanitizeRecord(record);
      expect(sanitized.comment, equals('1:1 w/ [Contact-1]'));
      expect(sanitized.tagIds, contains('tag-contact'));
      expect(sanitized.tagIds, contains('tag-work'));
    });

    test('sanitizes ActiveTimer comment', () {
      final timer = ActiveTimer(
        activityId: 'act-1',
        startedAtEpochMs: 1000,
        lastHeartbeatEpochMs: 1000,
        currentComment: 'Interviewing candidate with Bob Jones',
      );

      final sanitized = sanitizer.sanitizeActiveTimer(timer);
      expect(sanitized.currentComment, equals('Interviewing candidate with [Contact-1]'));
    });

    test('returns original string when enabled is false', () {
      final disabledSanitizer = PIISanitizer(enabled: false);
      final input = 'Meeting w/ Alice Smith at alice@example.com (555-123-4567)';
      expect(disabledSanitizer.sanitize(input), equals(input));
    });

    test('reset clears contact counter and mapping', () {
      sanitizer.sanitize('w/ Alice Smith');
      expect(sanitizer.contactMap['alice smith'], equals('[Contact-1]'));

      sanitizer.reset();
      expect(sanitizer.contactMap, isEmpty);

      sanitizer.sanitize('w/ Bob Jones');
      expect(sanitizer.contactMap['bob jones'], equals('[Contact-1]'));
    });
  });
}
