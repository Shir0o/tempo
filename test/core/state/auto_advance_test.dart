import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/auto_advance.dart';

void main() {
  group('splitComment', () {
    test('splits reading, one name and no extra text', () {
      final parts = splitComment('John 3 w/ Sam');
      expect(parts.reading, 'John 3');
      expect(parts.names, ['Sam']);
      expect(parts.extra, '');
    });

    test('splits several names and trailing free text', () {
      final parts = splitComment('John 19-20 w/ Sam, Alex at church');
      expect(parts.reading, 'John 19-20');
      expect(parts.names, ['Sam', 'Alex']);
      expect(parts.extra, 'at church');
    });

    test('accepts the "with " marker and two-word names', () {
      final parts = splitComment('Lesson 4 with Sam Lee, Alex');
      expect(parts.reading, 'Lesson 4');
      expect(parts.names, ['Sam Lee', 'Alex']);
      expect(parts.extra, '');
    });

    test('marker is case-insensitive and needs no space after w/', () {
      final parts = splitComment('John 3 W/Sam');
      expect(parts.reading, 'John 3');
      expect(parts.names, ['Sam']);
    });

    test('without a marker the whole comment is the reading', () {
      final parts = splitComment('  John 3  ');
      expect(parts.reading, 'John 3');
      expect(parts.names, isEmpty);
      expect(parts.extra, '');
    });

    test('a comment that starts with the marker has an empty reading', () {
      final parts = splitComment('w/ Sam');
      expect(parts.reading, '');
      expect(parts.names, ['Sam']);
    });
  });

  group('autoAdvance', () {
    group('nothing to advance', () {
      test('empty history', () => expect(autoAdvance([]), isNull));

      test('reading without a number', () {
        expect(autoAdvance(['Coffee w/ Sam']), isNull);
      });

      test('empty last comment, even if older ones have numbers', () {
        expect(autoAdvance(['', 'John 3']), isNull);
      });
    });

    group('Bible, single chapter', () {
      test('one earlier comment steps by 1, names dropped', () {
        expect(autoAdvance(['John 1 w/ Sam']), 'John 2');
      });

      test('verses are ignored', () {
        expect(autoAdvance(['John 3:16']), 'John 4');
      });

      test('a verse range stays in its chapter', () {
        expect(autoAdvance(['John 3:16-18']), 'John 4');
      });

      test('step follows the jump from the reading before', () {
        expect(autoAdvance(['John 5', 'John 3']), 'John 7');
      });

      test('a jump of 0 steps by 1', () {
        expect(autoAdvance(['John 3', 'John 3']), 'John 4');
      });

      test('a negative jump steps by 1', () {
        expect(autoAdvance(['John 3', 'John 5']), 'John 4');
      });

      test('a non-Bible reading before steps by 1', () {
        expect(autoAdvance(['John 5', 'Lesson 3']), 'John 6');
      });

      test('the jump is measured from the end of an earlier range', () {
        expect(autoAdvance(['John 4', 'John 1-2']), 'John 6');
      });

      test('a step past the last chapter runs into the next book', () {
        expect(autoAdvance(['John 20', 'John 18']), 'Acts 1');
      });

      test('a step counts chapters across several books', () {
        // 1 John 5 -> 3 John 1 is a jump of 2; two more lands past Jude.
        expect(autoAdvance(['3 John 1', '1 John 5']), 'Revelation 1');
      });

      test('a step past Revelation wraps to Genesis', () {
        expect(autoAdvance(['Rev 21', 'Rev 19']), 'Genesis 1');
      });
    });

    group('Bible, ranges', () {
      test('same-book range keeps its length', () {
        expect(autoAdvance(['John 1-2']), 'John 3-4');
      });

      test('range crossing a book writes both parts in full', () {
        expect(autoAdvance(['John 19-20']), 'John 21, Acts 1');
      });

      test('range wholly in the next book', () {
        expect(autoAdvance(['Jn 20-21']), 'Acts 1-2');
      });

      test('range spanning three books', () {
        expect(autoAdvance(['Amos 8-9']), 'Obadiah 1, Jonah 1');
      });

      test('a range ignores the reading before it', () {
        expect(autoAdvance(['John 5-6', 'John 1']), 'John 7-8');
      });

      test('chapter range written with verses', () {
        expect(autoAdvance(['John 3:16-4:2']), 'John 5-6');
      });

      test('en dash is accepted, ASCII hyphen is written', () {
        expect(autoAdvance(['John 1–2']), 'John 3-4');
      });

      test('input spanning books, comma-joined', () {
        expect(autoAdvance(['John 21, Acts 1 w/ Sam']), 'Acts 2-3');
      });

      test('input spanning books as one hyphenated range', () {
        expect(autoAdvance(['John 21-Acts 1']), 'Acts 2-3');
      });

      test('input across the Revelation wrap', () {
        expect(autoAdvance(['Rev 22, Gen 1']), 'Gen 2-3');
      });

      test('Revelation range wraps to Genesis', () {
        expect(autoAdvance(['Revelation 21-22']), 'Genesis 1-2');
      });

      test('Psalms 149-150 runs into Proverbs', () {
        expect(autoAdvance(['Psalm 149-150']), 'Proverbs 1-2');
      });
    });

    group('Bible spelling', () {
      test('keeps the user spelling within the same book', () {
        expect(autoAdvance(['Jn 3']), 'Jn 4');
        expect(autoAdvance(['Ps 23']), 'Ps 24');
        expect(autoAdvance(['Psa 23']), 'Psa 24');
        expect(autoAdvance(['1Cor 3']), '1Cor 4');
        expect(autoAdvance(['1 Cor 3']), '1 Cor 4');
        expect(autoAdvance(['john 3']), 'john 4');
        expect(autoAdvance(['Gen. 1:1']), 'Gen. 2');
      });

      test('keeps the user spelling of the new book it already typed', () {
        expect(autoAdvance(['Jn 21, Ac 1']), 'Ac 2-3');
      });

      test('writes a newly entered book in full', () {
        expect(autoAdvance(['Exod 40']), 'Leviticus 1');
        expect(autoAdvance(['Ps 150']), 'Proverbs 1');
        expect(autoAdvance(['Prov 31']), 'Ecclesiastes 1');
        expect(autoAdvance(['Mt 28']), 'Mark 1');
        expect(autoAdvance(['Mk 16']), 'Luke 1');
        expect(autoAdvance(['Lk 24']), 'John 1');
        expect(autoAdvance(['Rom 16']), '1 Corinthians 1');
        expect(autoAdvance(['1 Cor 16']), '2 Corinthians 1');
        expect(autoAdvance(['Rev 22']), 'Genesis 1');
      });
    });

    group('Bible abbreviations', () {
      const cases = {
        'Gen 1': 'Gen 2',
        'Ex 3': 'Ex 4',
        'Exod 3': 'Exod 4',
        'Lev 1': 'Lev 2',
        'Deut 1': 'Deut 2',
        '1 Sam 1': '1 Sam 2',
        '2 Kgs 1': '2 Kgs 2',
        '1 Chr 1': '1 Chr 2',
        'Ps 1': 'Ps 2',
        'Psa 1': 'Psa 2',
        'Prov 1': 'Prov 2',
        'Eccl 1': 'Eccl 2',
        'Song 1': 'Song 2',
        'Song of Songs 1': 'Song of Songs 2',
        'Isa 1': 'Isa 2',
        'Matt 1': 'Matt 2',
        'Mt 1': 'Mt 2',
        'Mk 1': 'Mk 2',
        'Lk 1': 'Lk 2',
        'Jn 1': 'Jn 2',
        'Rom 1': 'Rom 2',
        '1 Cor 1': '1 Cor 2',
        '1Cor 1': '1Cor 2',
        '2 Cor 1': '2 Cor 2',
        'Gal 1': 'Gal 2',
        'Eph 1': 'Eph 2',
        'Phil 1': 'Phil 2',
        '1 Thess 1': '1 Thess 2',
        '2 Tim 1': '2 Tim 2',
        'Heb 1': 'Heb 2',
        'Jas 1': 'Jas 2',
        '1 Pet 1': '1 Pet 2',
        '1 Jn 1': '1 Jn 2',
        'Rev 1': 'Rev 2',
      };
      for (final entry in cases.entries) {
        test(entry.key, () => expect(autoAdvance([entry.key]), entry.value));
      }

      test('abbreviation recognised as Bible, not a plain number', () {
        // A plain-number advance would give "Ps 151".
        expect(autoAdvance(['Ps 150']), 'Proverbs 1');
        expect(autoAdvance(['Jn 21']), 'Acts 1');
      });
    });

    group('numbered books', () {
      test('1 John is not John', () {
        expect(autoAdvance(['1 John 5']), '2 John 1');
        expect(autoAdvance(['John 21']), 'Acts 1');
      });

      test('2 John and 3 John have one chapter', () {
        expect(autoAdvance(['2 Jn 1']), '3 John 1');
        expect(autoAdvance(['3 John 1']), 'Jude 1');
      });

      test('unspaced numbered book', () {
        expect(autoAdvance(['1John 5']), '2 John 1');
      });
    });

    test('canon: the last chapter of every book leads to the next book', () {
      // Independent oracle: the 66-book Protestant canon with chapter counts.
      const canon = [
        ('Genesis', 50),
        ('Exodus', 40),
        ('Leviticus', 27),
        ('Numbers', 36),
        ('Deuteronomy', 34),
        ('Joshua', 24),
        ('Judges', 21),
        ('Ruth', 4),
        ('1 Samuel', 31),
        ('2 Samuel', 24),
        ('1 Kings', 22),
        ('2 Kings', 25),
        ('1 Chronicles', 29),
        ('2 Chronicles', 36),
        ('Ezra', 10),
        ('Nehemiah', 13),
        ('Esther', 10),
        ('Job', 42),
        ('Psalms', 150),
        ('Proverbs', 31),
        ('Ecclesiastes', 12),
        ('Song of Solomon', 8),
        ('Isaiah', 66),
        ('Jeremiah', 52),
        ('Lamentations', 5),
        ('Ezekiel', 48),
        ('Daniel', 12),
        ('Hosea', 14),
        ('Joel', 3),
        ('Amos', 9),
        ('Obadiah', 1),
        ('Jonah', 4),
        ('Micah', 7),
        ('Nahum', 3),
        ('Habakkuk', 3),
        ('Zephaniah', 3),
        ('Haggai', 2),
        ('Zechariah', 14),
        ('Malachi', 4),
        ('Matthew', 28),
        ('Mark', 16),
        ('Luke', 24),
        ('John', 21),
        ('Acts', 28),
        ('Romans', 16),
        ('1 Corinthians', 16),
        ('2 Corinthians', 13),
        ('Galatians', 6),
        ('Ephesians', 6),
        ('Philippians', 4),
        ('Colossians', 4),
        ('1 Thessalonians', 5),
        ('2 Thessalonians', 3),
        ('1 Timothy', 6),
        ('2 Timothy', 4),
        ('Titus', 3),
        ('Philemon', 1),
        ('Hebrews', 13),
        ('James', 5),
        ('1 Peter', 5),
        ('2 Peter', 3),
        ('1 John', 5),
        ('2 John', 1),
        ('3 John', 1),
        ('Jude', 1),
        ('Revelation', 22),
      ];
      expect(canon, hasLength(66));
      expect(canon.fold<int>(0, (sum, b) => sum + b.$2), 1189);
      for (var i = 0; i < canon.length; i++) {
        final (name, chapters) = canon[i];
        final next = canon[(i + 1) % canon.length].$1;
        expect(autoAdvance(['$name $chapters']), '$next 1', reason: name);
      }
    });

    group('other text', () {
      test('trailing number moves by 1', () {
        expect(autoAdvance(['Lesson 4']), 'Lesson 5');
      });

      test('names after the marker are dropped', () {
        expect(autoAdvance(['Lesson 4 w/ Sam']), 'Lesson 5');
      });

      test('step follows the jump from the reading before', () {
        expect(autoAdvance(['Lesson 6', 'Lesson 4']), 'Lesson 8');
      });

      test('a jump of 0 or less steps by 1', () {
        expect(autoAdvance(['Lesson 6', 'Lesson 6']), 'Lesson 7');
        expect(autoAdvance(['Lesson 6', 'Lesson 9']), 'Lesson 7');
      });

      test('a reading before with different text steps by 1', () {
        expect(autoAdvance(['Lesson 6', 'Unit 4']), 'Lesson 7');
      });

      test('a range keeps its length', () {
        expect(autoAdvance(['Lessons 3-4']), 'Lessons 5-6');
      });

      test('only the last number moves, surrounding text kept', () {
        expect(autoAdvance(['Lesson 4 review']), 'Lesson 5 review');
        expect(autoAdvance(['Lesson 4, part 2']), 'Lesson 4, part 3');
      });

      test('a chapter that does not exist is a plain number', () {
        expect(autoAdvance(['John 22']), 'John 23');
      });

      test('zero padding is kept', () {
        expect(autoAdvance(['Week 09']), 'Week 10');
        expect(autoAdvance(['Week 05']), 'Week 06');
      });

      test('a backwards pair is not a range', () {
        expect(autoAdvance(['Meeting 2024-05']), 'Meeting 2024-06');
      });
    });
  });
}
