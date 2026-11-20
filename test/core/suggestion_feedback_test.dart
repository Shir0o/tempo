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
}
