import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/core/state/activity_matcher.dart';
import 'package:tempo/data/models/models.dart';

Activity activity(
  String id,
  String name, {
  int sortOrder = 0,
  bool archived = false,
}) => Activity(
  id: id,
  name: name,
  sortOrder: sortOrder,
  isArchived: archived,
  createdAtEpochMs: 0,
  updatedAtEpochMs: 0,
);

void main() {
  group('normalizeActivityText', () {
    test(
      'trims, lowercases, strips boundary punctuation, collapses spaces',
      () {
        expect(normalizeActivityText('  "  Cleaning   Up " '), 'cleaning up');
      },
    );

    test('keeps internal punctuation', () {
      expect(
        normalizeActivityText('Walk the dog, slowly'),
        'walk the dog, slowly',
      );
    });

    test('clips to 64 runes', () {
      final long = 'a' * 100;
      expect(normalizeActivityText(long).runes.length, 64);
    });
  });

  group('rankActivities', () {
    final cleaning = activity('a1', 'Cleaning', sortOrder: 1);
    final cleanHouse = activity('a2', 'Clean house', sortOrder: 2);
    final laundry = activity('a3', 'Laundry', sortOrder: 3);

    test('exact match ranks first', () {
      final ranking = rankActivities([cleaning, cleanHouse], 'Cleaning');
      expect(ranking.matches.first.activity.id, 'a1');
      expect(ranking.matches.first.stage, ActivityMatchStage.exact);
    });

    test('prefix matches a name that starts with the query', () {
      final ranking = rankActivities([cleaning, cleanHouse], 'clean');
      expect(
        ranking.matches.map((m) => m.activity.id),
        containsAll(<String>['a1', 'a2']),
      );
      expect(
        ranking.matches.every((m) => m.stage == ActivityMatchStage.prefix),
        isTrue,
      );
    });

    test('substring matches mid-word', () {
      final ranking = rankActivities([cleaning], 'lean');
      expect(ranking.matches.single.stage, ActivityMatchStage.substring);
    });

    test('a name token inside a spoken phrase matches', () {
      final ranking = rankActivities([cleaning], 'um cleaning the kitchen');
      expect(ranking.matches.single.stage, ActivityMatchStage.nameTokenInQuery);
    });

    test('archived Activities are excluded', () {
      final archived = activity('a9', 'Cleaning', archived: true);
      expect(rankActivities([archived], 'cleaning').matches, isEmpty);
    });

    test('empty and punctuation-only queries return nothing', () {
      expect(rankActivities([cleaning], '').matches, isEmpty);
      expect(rankActivities([cleaning], '!!!').matches, isEmpty);
    });

    test('total is reported before the limit', () {
      final catalog = [
        cleaning,
        cleanHouse,
        activity('a4', 'Clean the car'),
        activity('a5', 'Clean windows'),
      ];
      final ranking = rankActivities(catalog, 'clean', limit: 2);
      expect(ranking.matches, hasLength(2));
      expect(ranking.total, 4);
    });

    test('duplicate names tie-break by sort order then id', () {
      final one = activity('b2', 'Cleaning', sortOrder: 1);
      final two = activity('b1', 'Cleaning', sortOrder: 1);
      final first = activity('b0', 'Cleaning', sortOrder: 0);
      final ranking = rankActivities([one, two, first], 'cleaning');
      expect(ranking.matches.map((m) => m.activity.id).toList(), [
        'b0',
        'b1',
        'b2',
      ]);
    });

    test('arbitrary unicode and very long input never throw', () {
      final catalog = [cleaning, laundry];
      for (final query in <String>[
        '😀😀😀',
        'e\u0301' * 200,
        'x' * 10000,
        '\u0000',
      ]) {
        expect(() => rankActivities(catalog, query), returnsNormally);
      }
    });

    test('the checked-in corpus reaches the top-three target', () {
      final catalogJson = jsonDecode(
        File('test/fixtures/activity_catalog_40.json').readAsStringSync(),
      ) as List<dynamic>;
      final corpusJson = jsonDecode(
        File('test/fixtures/activity_match_corpus.json').readAsStringSync(),
      ) as List<dynamic>;

      final catalog = catalogJson.map((raw) {
        final map = raw as Map<String, dynamic>;
        return Activity(
          id: map['id'] as String,
          name: map['name'] as String,
          categoryId: map['categoryId'] as String?,
          isArchived: map['isArchived'] as bool? ?? false,
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        );
      }).toList();

      var positives = 0;
      var topThreeHits = 0;
      var negativeViolations = 0;

      for (final raw in corpusJson) {
        final entry = raw as Map<String, dynamic>;
        final phrase = entry['phrase'] as String;
        final expected = entry['expectedActivityId'] as String?;
        final ranking = rankActivities(catalog, phrase);
        if (expected == null) {
          if (ranking.matches.isNotEmpty) negativeViolations++;
          continue;
        }
        positives++;
        final topThree = ranking.matches
            .take(3)
            .map((m) => m.activity.id)
            .toList();
        if (topThree.contains(expected)) topThreeHits++;
      }

      expect(positives, 38);
      expect(negativeViolations, 0);
      expect(topThreeHits / positives, greaterThanOrEqualTo(0.9));
    });
  });
}
