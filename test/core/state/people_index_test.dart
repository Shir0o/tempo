import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/people_index.dart';
import 'package:tempo/data/models/models.dart';

void main() {
  const day = 24 * 60 * 60 * 1000;
  const now = 100 * day;

  Record record(
    String comment, {
    required int endedAt,
    String? activityId = 'talk',
  }) => Record(
    id: '$comment@$endedAt',
    activityId: activityId,
    startedAtEpochMs: endedAt - 60000,
    endedAtEpochMs: endedAt,
    comment: comment,
    timezoneId: 'UTC',
    createdAtEpochMs: 0,
    updatedAtEpochMs: 0,
  );

  group('peopleIn', () {
    test('reads one name after w/', () {
      expect(peopleIn('Lunch w/ Sam'), ['Sam']);
    });

    test('reads a two-word name', () {
      expect(peopleIn('John 1 w/ Sam Lee'), ['Sam Lee']);
    });

    test('reads a comma list', () {
      expect(peopleIn('John 1 w/ Sam, Lee, Ana Maria'), [
        'Sam',
        'Lee',
        'Ana Maria',
      ]);
    });

    test('reads names after "with "', () {
      expect(peopleIn('Walk with Ana'), ['Ana']);
      expect(peopleIn('With Ana'), ['Ana']);
    });

    test('stops at punctuation other than a comma', () {
      expect(peopleIn('Coffee w/ Sam. Then home'), ['Sam']);
      expect(peopleIn('Coffee w/ Sam (park)'), ['Sam']);
    });

    test('stops at lowercase words that follow the names', () {
      expect(peopleIn('John 2 w/ Sam at the park'), ['Sam']);
      expect(peopleIn('w/ Sam, then home'), ['Sam']);
    });

    test('ignores lowercase words after with', () {
      expect(peopleIn('Start with chapter one'), isEmpty);
      expect(peopleIn('Dinner with friends'), isEmpty);
    });

    test('does not read a marker inside a word', () {
      expect(peopleIn('Bandwith Sam'), isEmpty);
    });

    test('drops repeats ignoring case', () {
      expect(peopleIn('w/ Sam, Lee, SAM'), ['Sam', 'Lee']);
    });

    test('ends the list at the first word that is not a name', () {
      expect(peopleIn('w/ Sam, then Lee'), ['Sam']);
    });

    test('returns nothing for an empty comment', () {
      expect(peopleIn(''), isEmpty);
    });
  });

  group('rankPeople', () {
    test('ranks frequent people above rare ones at the same age', () {
      final records = [
        record('w/ Lee', endedAt: now - day),
        record('w/ Sam', endedAt: now - day),
        record('w/ Sam', endedAt: now - day),
      ];
      expect(rankPeople(records, nowEpochMs: now), ['Sam', 'Lee']);
    });

    test('ranks a recent person above an older one seen as often', () {
      final records = [
        record('w/ Lee', endedAt: now - 60 * day),
        record('w/ Sam', endedAt: now - day),
      ];
      expect(rankPeople(records, nowEpochMs: now), ['Sam', 'Lee']);
    });

    test('lets recency outweigh a few stale mentions', () {
      final records = [
        for (var i = 0; i < 3; i++) record('w/ Lee', endedAt: now - 90 * day),
        record('w/ Sam', endedAt: now - day),
      ];
      expect(rankPeople(records, nowEpochMs: now).first, 'Sam');
    });

    test('merges spellings and shows the most recent one', () {
      final records = [
        record('w/ SAM', endedAt: now - 5 * day),
        record('w/ Sam', endedAt: now - day),
      ];
      expect(rankPeople(records, nowEpochMs: now), ['Sam']);
    });

    test('puts people seen with the Activity first, then everyone else', () {
      final records = [
        for (var i = 0; i < 5; i++)
          record('w/ Lee', endedAt: now - day, activityId: 'walk'),
        record('w/ Sam', endedAt: now - 20 * day, activityId: 'read'),
        record('w/ Ana', endedAt: now - 2 * day, activityId: 'read'),
      ];
      expect(rankPeople(records, nowEpochMs: now, activityId: 'read'), [
        'Ana',
        'Sam',
        'Lee',
      ]);
    });

    test('honours the limit', () {
      final records = [record('w/ Sam, Lee, Ana', endedAt: now - day)];
      expect(rankPeople(records, nowEpochMs: now, limit: 2), hasLength(2));
    });

    test('breaks ties by name so the order is stable', () {
      final records = [record('w/ Sam, Ana', endedAt: now - day)];
      expect(rankPeople(records, nowEpochMs: now), ['Ana', 'Sam']);
    });
  });

  group('withPeople', () {
    test('appends w/ and the names when there is no marker', () {
      expect(withPeople('John 1', ['Sam']), 'John 1 w/ Sam');
      expect(withPeople('', ['Sam', 'Lee']), 'w/ Sam, Lee');
    });

    test('replaces the names and keeps the words around them', () {
      expect(
        withPeople('John 1 w/ Sam at the park', ['Sam', 'Lee']),
        'John 1 w/ Sam, Lee at the park',
      );
    });

    test('writes the marker as w/', () {
      expect(withPeople('Walk with Ana', ['Ana', 'Lee']), 'Walk w/ Ana, Lee');
    });

    test('keeps punctuation and words after the names', () {
      expect(
        withPeople('Coffee w/ Sam. Then home', ['Sam', 'Lee']),
        'Coffee w/ Sam, Lee. Then home',
      );
      expect(withPeople('w/ Sam, then home', ['Lee']), 'w/ Lee, then home');
      expect(withPeople('w/ Sam, then home', []), 'then home');
    });

    test('removes the marker when no one is left', () {
      expect(withPeople('John 1 w/ Sam at the park', []), 'John 1 at the park');
      expect(withPeople('w/ Sam', []), '');
    });

    test('fills a bare w/ the user already typed', () {
      expect(withPeople('John 1 w/ ', ['Sam']), 'John 1 w/ Sam');
    });

    test('leaves prose "with" alone', () {
      expect(
        withPeople('Start with chapter one', []),
        'Start with chapter one',
      );
      expect(
        withPeople('Start with chapter one', ['Sam']),
        'Start with chapter one w/ Sam',
      );
    });

    test('round-trips through peopleIn', () {
      final comment = withPeople('John 3 then tea', ['Sam Lee', 'Ana']);
      expect(peopleIn(comment), ['Sam Lee', 'Ana']);
    });
  });

  group('Contact Tag', () {
    Tag tag(String id, String name) =>
        Tag(id: id, name: name, createdAtEpochMs: 0, updatedAtEpochMs: 0);

    test('finds the Contact Tag by name, ignoring case', () {
      expect(contactTagId([tag('a', 'Travel'), tag('b', 'contact')]), 'b');
    });

    test('is null when no Contact Tag exists', () {
      expect(contactTagId([tag('a', 'Travel')]), isNull);
    });

    test('attaches it when someone is chosen', () {
      expect(tagIdsWithContact(['t'], 'c', hasPeople: true), ['t', 'c']);
      expect(tagIdsWithContact(['c'], 'c', hasPeople: true), ['c']);
    });

    test('detaches it when no one is left', () {
      expect(tagIdsWithContact(['t', 'c'], 'c', hasPeople: false), ['t']);
    });

    test('changes nothing without a Contact Tag', () {
      expect(tagIdsWithContact(['t'], null, hasPeople: true), ['t']);
    });
  });
}
