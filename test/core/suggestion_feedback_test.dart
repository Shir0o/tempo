import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/core/state/suggestion_feedback.dart';
import 'package:tempo/core/state/suggestion_loader.dart';
import 'package:tempo/core/time/timezone_id.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

/// Feedback on suggestions, over the weekday morning routine of
/// suggestion_blend_test: Bible 07:00, Grooming 07:30, Breakfast 07:50, then
/// Commute on Thursdays and Work otherwise.
void main() {
  const engine = ContextualSuggestionEngine();
  const zone = 'America/Los_Angeles';
  const day = Duration.millisecondsPerDay;
  // Thursday 12 November 2026.
  final today = DateTime.utc(2026, 11, 12);
  final reference = DateTime.utc(2026, 11, 12, 16).millisecondsSinceEpoch;

  int at(DateTime date, int hour, int minute) => epochMsFromWallClock(
    DateTime.utc(date.year, date.month, date.day, hour, minute),
    zone,
    referenceEpochMs: reference,
  );

  Activity activity(String id) =>
      Activity(id: id, name: id, createdAtEpochMs: 0, updatedAtEpochMs: 0);

  final candidates = [
    for (final id in [
      'morning',
      'bible',
      'grooming',
      'breakfast',
      'commute',
      'work',
      'gym',
      'nap',
    ])
      activity(id),
  ];

  final history = <SuggestionObservation>[];
  void add(String id, DateTime date, int hour, int minute) => history.add(
    SuggestionObservation(
      activityId: id,
      startedAtEpochMs: at(date, hour, minute),
      timezoneId: zone,
    ),
  );
  for (var daysAgo = 42; daysAgo >= 1; daysAgo--) {
    final date = today.subtract(Duration(days: daysAgo));
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      continue;
    }
    add('morning', date, 6, 30);
    add('bible', date, 7, 0);
    add('grooming', date, 7, 30);
    add('breakfast', date, 7, 50);
    add(date.weekday == DateTime.thursday ? 'commute' : 'work', date, 8, 5);
  }
  add('morning', today, 6, 30);
  add('bible', today, 7, 0);

  // Labeling the Lap that started at 07:30 today, after Bible.
  final target = at(today, 7, 30);

  List<String> rank([List<SuggestionFeedback> feedback = const []]) {
    final context = ContextualSuggestionEngine.contextFromHistory(
      history,
      targetEpochMs: target,
    );
    return [
      for (final suggestion in engine.rankExplained(
        candidates: candidates,
        history: history,
        precedingActivityId: context.precedingActivityId,
        secondPrecedingActivityId: context.secondPrecedingActivityId,
        targetEpochMs: target,
        timezoneId: zone,
        feedback: feedback,
        limit: candidates.length,
      ))
        suggestion.activity.id,
    ];
  }

  SuggestionFeedback vote(
    String activityId,
    SuggestionVote vote, {
    int? targetEpochMs,
    String? after = 'bible',
    int givenAgoMs = 0,
  }) => SuggestionFeedback(
    activityId: activityId,
    vote: vote,
    givenAtEpochMs: target - givenAgoMs,
    targetEpochMs: targetEpochMs ?? target,
    timezoneId: zone,
    precedingActivityId: after,
  );

  group('ranking with feedback', () {
    test('without feedback, Grooming leads after Bible at 07:30', () {
      expect(rank().first, 'grooming');
    });

    test('not useful in the same situation drops it from the lead', () {
      final ranked = rank([vote('grooming', SuggestionVote.notUseful)]);
      expect(ranked.first, isNot('grooming'));
      expect(
        ranked.indexOf('grooming'),
        greaterThan(rank().indexOf('grooming')),
      );
    });

    test('not useful last Thursday at this time still counts', () {
      final ranked = rank([
        vote(
          'grooming',
          SuggestionVote.notUseful,
          targetEpochMs: target - 7 * day,
          givenAgoMs: 7 * day,
        ),
      ]);
      expect(ranked.first, isNot('grooming'));
    });

    test('not useful in an unrelated situation changes nothing', () {
      // Given in the evening, after another Activity.
      final ranked = rank([
        vote(
          'grooming',
          SuggestionVote.notUseful,
          targetEpochMs: at(today, 20, 0),
          after: 'work',
        ),
      ]);
      expect(ranked, rank());
    });

    test('feedback older than the history window has faded', () {
      final ranked = rank([
        vote(
          'grooming',
          SuggestionVote.notUseful,
          givenAgoMs: ContextualSuggestionEngine.historyWindowDays * day + day,
        ),
      ]);
      expect(ranked, rank());
    });

    test('only the preceding Activity matching counts for less', () {
      // Same preceding Activity, but in the evening: half the weight of a
      // vote in the same situation, so it demotes less.
      final exact = rank([vote('grooming', SuggestionVote.notUseful)]);
      final partial = rank([
        vote(
          'grooming',
          SuggestionVote.notUseful,
          targetEpochMs: at(today, 20, 0),
        ),
      ]);
      expect(
        partial.indexOf('grooming'),
        lessThanOrEqualTo(exact.indexOf('grooming')),
      );
    });

    test('good lifts an Activity, and a tap counts for less than good', () {
      // Commute trails Morning without feedback.
      final before = rank();
      expect(before.indexOf('commute'), greaterThan(before.indexOf('morning')));

      final good = rank([vote('commute', SuggestionVote.good)]);
      expect(good.indexOf('commute'), lessThan(good.indexOf('morning')));

      final tap = rank([vote('commute', SuggestionVote.accepted)]);
      expect(tap.indexOf('commute'), greaterThan(tap.indexOf('morning')));
    });

    test('good cannot overturn a routine\'s usual next step', () {
      final ranked = rank([
        for (var i = 0; i < 5; i++) vote('breakfast', SuggestionVote.good),
      ]);
      expect(ranked.first, 'grooming');
    });

    test('good never more than doubles a score', () {
      // Gym was never logged: a score of zero stays zero, so it only rises
      // above other unlogged Activities.
      final ranked = rank([
        for (var i = 0; i < 20; i++) vote('gym', SuggestionVote.good),
      ]);
      expect(ranked.indexOf('gym'), greaterThan(ranked.indexOf('commute')));
      expect(ranked.indexOf('gym'), lessThan(ranked.indexOf('nap')));
    });

    test('a disliked Activity with no score sinks below unvoted ones', () {
      expect(rank().indexOf('gym'), lessThan(rank().indexOf('nap')));
      final ranked = rank([vote('gym', SuggestionVote.notUseful)]);
      expect(ranked.indexOf('gym'), greaterThan(ranked.indexOf('nap')));
    });

    test('feedback on the preceding Activity is ignored', () {
      final ranked = rank([vote('bible', SuggestionVote.good)]);
      expect(ranked, rank());
    });
  });

  group('SuggestionFeedbackStore', () {
    late TempoDatabase db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      for (final candidate in candidates) {
        await db.insertActivity(candidate);
      }
    });

    tearDown(() async {
      await db.close();
    });

    test('keeps what was added, oldest first', () async {
      await SuggestionFeedbackStore.add(
        db,
        vote('grooming', SuggestionVote.notUseful, givenAgoMs: day),
      );
      await SuggestionFeedbackStore.add(
        db,
        vote('commute', SuggestionVote.good, after: null),
      );

      final stored = await SuggestionFeedbackStore.load(db);
      expect([for (final f in stored) f.activityId], ['grooming', 'commute']);
      expect(stored.first.vote, SuggestionVote.notUseful);
      expect(stored.first.precedingActivityId, 'bible');
      expect(stored.first.targetEpochMs, target);
      expect(stored.first.timezoneId, zone);
      expect(stored.last.precedingActivityId, isNull);
    });

    test('drops entries past the history window when adding', () async {
      await SuggestionFeedbackStore.add(
        db,
        vote('grooming', SuggestionVote.notUseful, givenAgoMs: 61 * day),
      );
      await SuggestionFeedbackStore.add(db, vote('work', SuggestionVote.good));

      final stored = await SuggestionFeedbackStore.load(db);
      expect([for (final f in stored) f.activityId], ['work']);
    });

    test('keeps at most the newest maxEntries', () async {
      for (var i = 0; i <= SuggestionFeedbackStore.maxEntries; i++) {
        await SuggestionFeedbackStore.add(
          db,
          vote('n$i', SuggestionVote.good, givenAgoMs: -i),
        );
      }
      final stored = await SuggestionFeedbackStore.load(db);
      expect(stored, hasLength(SuggestionFeedbackStore.maxEntries));
      expect(stored.first.activityId, 'n1');
    });

    test('unreadable data reads as none, and clear forgets all', () async {
      await db.setSetting(SuggestionFeedbackStore.storageKey, 'not json');
      expect(await SuggestionFeedbackStore.load(db), isEmpty);

      await db.setSetting(
        SuggestionFeedbackStore.storageKey,
        '[{"activity":"x"},{"activity":"work","vote":"good","given":1,'
        '"target":2,"zone":"UTC"}]',
      );
      final stored = await SuggestionFeedbackStore.load(db);
      expect([for (final f in stored) f.activityId], ['work']);

      await SuggestionFeedbackStore.clear(db);
      expect(await SuggestionFeedbackStore.load(db), isEmpty);
    });

    Future<void> insertRecord(String id, String activityId, int startMs) =>
        db.insertRecord(
          Record(
            id: id,
            activityId: activityId,
            startedAtEpochMs: startMs,
            endedAtEpochMs: startMs + 60000,
            timezoneId: zone,
            createdAtEpochMs: startMs,
            updatedAtEpochMs: startMs,
          ),
        );

    test('record reads the Activity before the target, not at it', () async {
      await insertRecord('r1', 'morning', at(today, 6, 30));
      await insertRecord('r2', 'bible', at(today, 7, 0));
      // The label the tap itself makes, starting at the target.
      await insertRecord('r3', 'grooming', target);

      await SuggestionFeedbackStore.record(
        database: db,
        activityId: 'grooming',
        vote: SuggestionVote.accepted,
        nowEpochMs: target + 60000,
        targetEpochMs: target,
        timezoneId: zone,
      );

      final stored = await SuggestionFeedbackStore.load(db);
      expect(stored.single.precedingActivityId, 'bible');
      expect(stored.single.vote, SuggestionVote.accepted);
      expect(stored.single.givenAtEpochMs, target + 60000);
    });

    test('the loader ranks with stored feedback', () async {
      var n = 0;
      for (final observation in history) {
        await insertRecord(
          'h${n++}',
          observation.activityId!,
          observation.startedAtEpochMs,
        );
      }

      Future<String> first() async => (await loadRankedSuggestions(
        database: db,
        candidates: candidates,
        nowEpochMs: target,
        timezoneId: zone,
        limit: 4,
      )).first.activity.id;

      expect(await first(), 'grooming');
      await SuggestionFeedbackStore.add(
        db,
        vote('grooming', SuggestionVote.notUseful),
      );
      expect(await first(), isNot('grooming'));
    });
  });

  group('edits after logging', () {
    SuggestionFeedback logged({
      List<String>? people,
      String comment = '',
      List<String>? tagIds,
    }) => SuggestionFeedback(
      activityId: 'bible',
      vote: SuggestionVote.logged,
      givenAtEpochMs: target,
      targetEpochMs: target,
      timezoneId: zone,
      precedingActivityId: 'morning',
      people: people,
      recordId: 'r1',
      comment: comment,
      tagIds: tagIds,
    );

    Record saved({
      String activityId = 'bible',
      String comment = '',
      List<String> tagIds = const [],
    }) => Record(
      id: 'r1',
      activityId: activityId,
      startedAtEpochMs: target,
      endedAtEpochMs: target + 60000,
      comment: comment,
      timezoneId: zone,
      createdAtEpochMs: target,
      updatedAtEpochMs: target,
      tagIds: tagIds,
    );

    List<String> votes(ResolvedFeedback resolved) => [
      for (final vote in resolved.votes)
        '${vote.vote.name}${vote.people == null ? '' : ' ${vote.people}'}',
    ];

    test('an undone label says nothing', () {
      final resolved = resolveLogged(logged(), null);
      expect(resolved.votes, isEmpty);
      expect(resolved.tags, isEmpty);
    });

    test('a kept Activity suggestion is a light vote for it', () {
      expect(votes(resolveLogged(logged(), saved())), ['accepted']);
    });

    test('a changed Activity counts against the suggestion and its note', () {
      final resolved = resolveLogged(
        logged(people: ['Sam'], comment: 'John 3 w/ Sam'),
        saved(activityId: 'work', comment: 'John 3 w/ Sam'),
      );
      expect(votes(resolved), ['notUseful', 'notUseful [Sam]']);
    });

    test('a note kept as suggested counts strongly for it', () {
      final resolved = resolveLogged(
        logged(people: ['Sam'], comment: 'John 3 w/ Sam'),
        saved(comment: ' John 3  w/ Sam'),
      );
      expect(votes(resolved).last, 'good [Sam]');
    });

    test('another Person with the same reading counts lightly for it', () {
      final resolved = resolveLogged(
        logged(people: ['Sam'], comment: 'John 3 w/ Sam'),
        saved(comment: 'John 3 w/ Lee'),
      );
      expect(votes(resolved).last, 'accepted [Sam]');
    });

    test('a rewritten reading counts against the note', () {
      final resolved = resolveLogged(
        logged(people: ['Sam'], comment: 'John 3 w/ Sam'),
        saved(comment: 'Acts 1 w/ Sam'),
      );
      expect(votes(resolved), ['accepted', 'notUseful [Sam]']);
    });

    test('Tag fixes count for and against each Tag', () {
      final resolved = resolveLogged(
        logged(tagIds: ['home', 'church']),
        saved(tagIds: ['church', 'travel']),
      );
      expect(
        {for (final tag in resolved.tags) tag.tagId: tag.micros},
        {'home': -1000000, 'church': 250000, 'travel': 1000000},
      );
    });

    test('entries without a record are not read back as logged', () {
      expect(
        SuggestionFeedback.fromJson({
          'activity': 'bible',
          'vote': 'logged',
          'given': 1,
          'target': 1,
          'zone': 'UTC',
        }),
        isNull,
      );
    });

    test('note feedback is keyed apart from Activity feedback', () {
      final noteVote = vote(
        'grooming',
        SuggestionVote.notUseful,
      ).withVote(SuggestionVote.notUseful, people: ['Sam']);
      // A rejected note does not demote the Activity itself.
      expect(rank([noteVote]), rank());

      final net = ContextualSuggestionEngine.feedbackNet(
        [noteVote],
        keyOf: (entry) => entry.people == null
            ? null
            : SuggestionFeedback.comboKey(entry.activityId, entry.people!),
        precedingActivityId: 'bible',
        targetEpochMs: target,
        timezoneId: zone,
      );
      expect(net, {
        SuggestionFeedback.comboKey('grooming', ['sam']): -1000000,
      });
    });
  });

  group('suggestedTagIds', () {
    var n = 0;
    Record past(
      int daysAgo,
      List<String> tagIds, {
      String activityId = 'bible',
      String comment = '',
    }) => Record(
      id: 't${n++}',
      activityId: activityId,
      startedAtEpochMs: target - daysAgo * day,
      endedAtEpochMs: target - daysAgo * day + 60000,
      comment: comment,
      timezoneId: zone,
      createdAtEpochMs: 0,
      updatedAtEpochMs: 0,
      tagIds: tagIds,
    );

    test('fills in Tags on at least half of the last four Records', () {
      final records = [
        past(1, ['home']),
        past(2, ['home', 'quiet']),
        past(3, ['quiet']),
        past(4, ['home']),
        past(5, ['old']),
        past(1, ['work'], activityId: 'work'),
      ];
      expect(
        suggestedTagIds(records, activityId: 'bible', beforeEpochMs: target),
        ['home', 'quiet'],
      );
    });

    test('a note suggestion reads Records with the same first Person', () {
      final records = [
        past(1, ['phone'], comment: 'John 3 w/ Sam'),
        past(2, ['home'], comment: 'John 2 w/ Lee'),
      ];
      expect(
        suggestedTagIds(
          records,
          activityId: 'bible',
          people: ['sam'],
          contactTagId: 'contact',
          beforeEpochMs: target,
        ),
        ['phone', 'contact'],
      );
    });

    test('Tag feedback drops a removed Tag and adds an added one', () {
      final records = [
        past(1, ['home']),
        past(2, ['home']),
      ];
      TagFeedback fix(String tagId, int micros) => TagFeedback(
        activityId: 'bible',
        tagId: tagId,
        micros: micros,
        givenAtEpochMs: target - day,
      );
      expect(
        suggestedTagIds(
          records,
          activityId: 'bible',
          people: ['Sam'],
          contactTagId: 'contact',
          feedback: [
            fix('home', -1000000),
            fix('church', 1000000),
            fix('contact', -1000000),
          ],
          beforeEpochMs: target,
        ),
        ['church'],
      );
    });
  });

  group('loadResolved', () {
    late TempoDatabase db;

    setUp(() async {
      db = await TempoDatabase.openInMemory();
      await db.insertActivity(activity('bible'));
      await db.insertActivity(activity('work'));
    });

    tearDown(() async {
      await db.close();
    });

    test('reads each logged suggestion against its Record now', () async {
      await db.insertRecord(
        Record(
          id: 'r1',
          activityId: 'work',
          startedAtEpochMs: target,
          endedAtEpochMs: target + 60000,
          timezoneId: zone,
          createdAtEpochMs: target,
          updatedAtEpochMs: target,
        ),
      );
      final origin = SuggestionFeedback(
        activityId: 'bible',
        vote: SuggestionVote.logged,
        givenAtEpochMs: target,
        targetEpochMs: target,
        timezoneId: zone,
        recordId: 'r1',
      );
      await SuggestionFeedbackStore.add(db, origin);
      await SuggestionFeedbackStore.add(
        db,
        vote('grooming', SuggestionVote.good),
      );
      // A label that was undone: its Record is gone.
      await SuggestionFeedbackStore.add(
        db,
        SuggestionFeedback(
          activityId: 'bible',
          vote: SuggestionVote.logged,
          givenAtEpochMs: target,
          targetEpochMs: target,
          timezoneId: zone,
          recordId: 'gone',
        ),
      );

      final resolved = await SuggestionFeedbackStore.loadResolved(db);
      expect(
        [for (final v in resolved.votes) (v.activityId, v.vote)],
        [
          ('bible', SuggestionVote.notUseful),
          ('grooming', SuggestionVote.good),
        ],
      );
    });
  });
}
