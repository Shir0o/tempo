import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/ui/helpers/activity_emoji.dart';

void main() {
  group('emojiForName', () {
    test('resolves a single-word domain name', () {
      expect(ActivityEmoji.emojiForName('coordination'), '🗂️');
    });

    test('uses the head noun, not the first word', () {
      expect(ActivityEmoji.emojiForName('ministry reading'), '📖');
    });

    test('resolves a possessive phrase on its head noun', () {
      expect(ActivityEmoji.emojiForName('personal prayer'), '🙏');
    });

    test('prefers a known phrase over a known head noun', () {
      expect(ActivityEmoji.emojiForName('prayer meeting'), '🤲');
    });

    test('ignores case and punctuation', () {
      expect(ActivityEmoji.emojiForName('Groceries!'), '🛒');
    });

    test('skips stop words when looking for the head noun', () {
      expect(ActivityEmoji.emojiForName('time with family'), '👨‍👩‍👧');
    });

    test('returns null for a name the table does not know', () {
      expect(ActivityEmoji.emojiForName('Anna'), isNull);
      expect(ActivityEmoji.emojiForName('S2'), isNull);
    });

    test('returns null for blank input', () {
      expect(ActivityEmoji.emojiForName(''), isNull);
      expect(ActivityEmoji.emojiForName('   '), isNull);
    });
  });

  group('monogram', () {
    test('uses the first letter, upper-cased', () {
      expect(ActivityEmoji.monogram('personal prayer'), 'P');
      expect(ActivityEmoji.monogram('errands'), 'E');
    });

    test('falls back to a question mark when there is nothing to show', () {
      expect(ActivityEmoji.monogram(''), '?');
      expect(ActivityEmoji.monogram('   '), '?');
    });
  });

  group('needsIcon', () {
    test('is true for the placeholder and for Material icon names', () {
      expect(ActivityEmoji.needsIcon('schedule'), isTrue);
      expect(ActivityEmoji.needsIcon('book'), isTrue);
      expect(ActivityEmoji.needsIcon(''), isTrue);
    });

    test('is false for an icon that already reads as emoji', () {
      expect(ActivityEmoji.needsIcon('🙏'), isFalse);
      expect(ActivityEmoji.needsIcon('📖'), isFalse);
    });
  });

  test('vocabulary is de-duplicated and non-empty', () {
    final vocab = ActivityEmoji.vocabulary;
    expect(vocab, isNotEmpty);
    expect(vocab.toSet().length, vocab.length);
  });
}
