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

  group('guess', () {
    test('keeps an exact match', () {
      expect(ActivityEmoji.guess('ministry reading'), '📖');
    });

    test('reads plural and -ing forms of a known word', () {
      expect(ActivityEmoji.guess('Walks'), '🚶');
      expect(ActivityEmoji.guess('Commuting'), '🚗');
      expect(ActivityEmoji.guess('Cleaned up'), '🧹');
    });

    test('tolerates one typo in a longer word', () {
      expect(ActivityEmoji.guess('excercise'), '🏋️');
    });

    test('matches a shared stem', () {
      expect(ActivityEmoji.guess('Meditate'), '🧘');
    });

    test('falls back to the category name', () {
      expect(ActivityEmoji.guess('Jiu-jitsu'), isNull);
      expect(ActivityEmoji.guess('Jiu-jitsu', categoryName: 'Exercise'), '🏋️');
    });

    test('stays null for names that are not close to anything', () {
      expect(ActivityEmoji.guess('Anna'), isNull);
      expect(ActivityEmoji.guess('S2'), isNull);
      expect(ActivityEmoji.guess(''), isNull);
    });
  });

  group('suggest and distinct', () {
    test('uses an alternate when the first choice is worn', () {
      expect(ActivityEmoji.suggest('Nap', taken: ['😴']), '💤');
      expect(ActivityEmoji.suggest('Nap', taken: ['😴', '💤']), '🛌');
    });

    test('shares the emoji when every alternate is worn too', () {
      expect(ActivityEmoji.distinct('😴', ['😴', '💤', '🛌']), '😴');
    });

    test('keeps the first choice when it is free', () {
      expect(ActivityEmoji.suggest('Nap', taken: ['📖']), '😴');
    });

    test('alternates are all in the picker vocabulary', () {
      for (final alts in ActivityEmoji.alternates.values) {
        for (final alt in alts) {
          expect(ActivityEmoji.vocabulary, contains(alt));
        }
      }
    });
  });

  group('distinctUnused', () {
    test('keeps a free base emoji', () {
      expect(ActivityEmoji.distinctUnused('😴', ['📖']), '😴');
    });

    test('uses the first unused alternate', () {
      expect(ActivityEmoji.distinctUnused('😴', ['😴', '💤']), '🛌');
    });

    test('falls back to the first free vocabulary emoji', () {
      final taken = ['😴', '💤', '🛌'];
      final expected = ActivityEmoji.vocabulary.firstWhere(
        (emoji) => !taken.contains(emoji),
      );

      expect(ActivityEmoji.distinctUnused('😴', taken), expected);
    });

    test('returns null when every vocabulary emoji is taken', () {
      expect(
        ActivityEmoji.distinctUnused('😴', ActivityEmoji.vocabulary),
        isNull,
      );
    });
  });
}
