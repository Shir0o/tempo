import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/core/state/suggestion_engine.dart';
import 'package:tempo/core/state/suggestion_feedback.dart';
import 'package:tempo/core/state/suggestion_impressions.dart';
import 'package:tempo/core/state/suggestion_loader.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/data/models/models.dart';

/// Rating a logged Record later, Tags filled in on labels without a
/// suggestion, and suggestions passed over again and again.
void main() {
  const zone = 'UTC';
  const unit = 1000000;
  const day = Duration.millisecondsPerDay;
  final now = DateTime.utc(2026, 11, 20, 8).millisecondsSinceEpoch;

  Activity activity(String id) =>
      Activity(id: id, name: id, createdAtEpochMs: 0, updatedAtEpochMs: 0);

  Record record(
    String id,
    String activityId,
    int startMs, {
    String comment = '',
    List<String> tagIds = const [],
  }) => Record(
    id: id,
    activityId: activityId,
    startedAtEpochMs: startMs,
    endedAtEpochMs: startMs + 60000,
    comment: comment,
    timezoneId: zone,
    createdAtEpochMs: startMs,
    updatedAtEpochMs: startMs,
    tagIds: tagIds,
  );

  SuggestionFeedback logged({
    String recordId = 'r1',
    String activityId = 'bible',
    List<String>? people,
    String? comment,
    List<String>? tagIds,
    SuggestionVote vote = SuggestionVote.logged,
  }) => SuggestionFeedback(
    activityId: activityId,
    vote: vote,
    givenAtEpochMs: now - day,
    targetEpochMs: now - day,
    timezoneId: zone,
    precedingActivityId: 'morning',
    people: people,
    recordId: recordId,
    comment: comment,
    tagIds: tagIds,
  );

  late TempoDatabase db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await TempoDatabase.openInMemory();
    for (final id in ['morning', 'bible', 'work', 'gym']) {
      await db.insertActivity(activity(id));
    }
  });

  tearDown(() async {
    await db.close();
  });

  group('rating a logged Record later', () {
    test('is unavailable for a Record not logged from a suggestion', () async {
      expect(await SuggestionFeedbackStore.ratingFor(db, 'r1'), isNull);
      await SuggestionFeedbackStore.rate(
        db,
        recordId: 'r1',
        vote: SuggestionVote.good,
        nowEpochMs: now,
      );
      expect(await SuggestionFeedbackStore.load(db), isEmpty);
    });

    test('stores a vote about the moment it was suggested for', () async {
      await SuggestionFeedbackStore.add(db, logged(people: ['Sam']));
      await SuggestionFeedbackStore.rate(
        db,
        recordId: 'r1',
        vote: SuggestionVote.good,
        nowEpochMs: now,
      );

      final rated = (await SuggestionFeedbackStore.load(db)).last;
      expect(rated.vote, SuggestionVote.good);
      expect(rated.recordId, 'r1');
      expect(rated.people, ['Sam']);
      expect(rated.givenAtEpochMs, now);
      expect(rated.targetEpochMs, now - day);
      expect(rated.precedingActivityId, 'morning');
      expect(
        (await SuggestionFeedbackStore.ratingFor(db, 'r1'))?.rating,
        SuggestionVote.good,
      );
    });

    test('a new rating replaces the last, and null takes it back', () async {
      await SuggestionFeedbackStore.add(db, logged());
      for (final vote in [SuggestionVote.good, SuggestionVote.notUseful]) {
        await SuggestionFeedbackStore.rate(
          db,
          recordId: 'r1',
          vote: vote,
          nowEpochMs: now,
        );
      }
      expect(
        [for (final e in await SuggestionFeedbackStore.load(db)) e.vote],
        [SuggestionVote.logged, SuggestionVote.notUseful],
      );

      await SuggestionFeedbackStore.rate(
        db,
        recordId: 'r1',
        vote: null,
        nowEpochMs: now,
      );
      expect(
        [for (final e in await SuggestionFeedbackStore.load(db)) e.vote],
        [SuggestionVote.logged],
      );
      expect((await SuggestionFeedbackStore.ratingFor(db, 'r1'))?.rating, null);
    });

    test('a rating stands in for what the edits say, Tags aside', () async {
      // A suggested Tag removed after logging.
      await db.insertRecord(record('r1', 'bible', now - day));
      await SuggestionFeedbackStore.add(db, logged(tagIds: ['phone']));
      var resolved = await SuggestionFeedbackStore.loadResolved(db);
      expect(
        [for (final v in resolved.votes) v.vote],
        [SuggestionVote.accepted],
      );
      expect([for (final t in resolved.tags) t.micros], [-unit]);

      await SuggestionFeedbackStore.rate(
        db,
        recordId: 'r1',
        vote: SuggestionVote.good,
        nowEpochMs: now,
      );
      resolved = await SuggestionFeedbackStore.loadResolved(db);
      expect([for (final v in resolved.votes) v.vote], [SuggestionVote.good]);
      expect([for (final t in resolved.tags) t.micros], [-unit]);
    });
  });

  group('Tags on labels without a suggestion', () {
    test('a tagged entry reads only how its Tags were edited', () {
      final resolved = resolveLogged(
        logged(vote: SuggestionVote.tagged, tagIds: ['phone', 'home']),
        record('r1', 'bible', now - day, tagIds: ['home', 'focus']),
      );
      expect(resolved.votes, isEmpty);
      expect(
        {for (final t in resolved.tags) t.tagId: t.micros},
        {'phone': -unit, 'home': unit ~/ 4, 'focus': unit},
      );
    });

    test('a relabeled Record says nothing about the Tags', () {
      final resolved = resolveLogged(
        logged(vote: SuggestionVote.tagged, tagIds: ['phone']),
        record('r1', 'work', now - day),
      );
      expect(resolved.votes, isEmpty);
      expect(resolved.tags, isEmpty);
    });

    test('a tagged entry is not a vote in ranking', () async {
      await db.insertRecord(record('r1', 'bible', now - day));
      await SuggestionFeedbackStore.add(
        db,
        logged(vote: SuggestionVote.tagged, tagIds: const []),
      );
      expect((await SuggestionFeedbackStore.loadResolved(db)).votes, isEmpty);
    });

    test('loadLearnedTagIds reads the same Tags Today fills in', () async {
      await db.insertTag(
        const Tag(
          id: 'contact',
          name: 'Contact',
          isContact: true,
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      await db.insertTag(
        const Tag(
          id: 'phone',
          name: 'Phone',
          createdAtEpochMs: 0,
          updatedAtEpochMs: 0,
        ),
      );
      for (var i = 1; i <= 4; i++) {
        await db.insertRecord(
          record(
            'h$i',
            'bible',
            now - i * day,
            tagIds: i <= 2 ? ['phone'] : const [],
          ),
        );
      }
      await db.insertRecord(record('w', 'work', now - day, tagIds: ['phone']));

      expect(
        await loadLearnedTagIds(db, activityId: 'bible', beforeEpochMs: now),
        ['phone'],
      );
      expect(
        await loadLearnedTagIds(
          db,
          activityId: 'bible',
          comment: 'John 3 w/ Sam',
          beforeEpochMs: now,
        ),
        ['contact'],
      );
      expect(
        await loadLearnedTagIds(db, activityId: 'gym', beforeEpochMs: now),
        isEmpty,
      );
    });
  });

  group('suggestions passed over', () {
    test('rank lower only after a few times, and at most a third', () {
      const grace = ContextualSuggestionEngine.ignoredGraceMicros;
      const total = 900000;
      expect(ContextualSuggestionEngine.applyIgnored(total, 0), total);
      expect(ContextualSuggestionEngine.applyIgnored(total, grace), total);
      expect(
        ContextualSuggestionEngine.applyIgnored(total, grace + 2 * unit),
        total * unit ~/ (unit + 300000),
      );
      expect(
        ContextualSuggestionEngine.applyIgnored(total, 100 * unit),
        total ~/ 3,
      );
    });

    test('count once more each time, start over when picked', () async {
      Future<Map<String, int>> load([int at = 0]) =>
          SuggestionImpressions.load(db, nowEpochMs: now + at);

      for (var i = 0; i < 3; i++) {
        await SuggestionImpressions.recordLabel(
          db,
          shown: ['bible', 'gym'],
          labeledActivityId: 'work',
          nowEpochMs: now,
        );
      }
      expect(await load(), {'bible': 3 * unit, 'gym': 3 * unit});

      await SuggestionImpressions.recordLabel(
        db,
        shown: ['bible', 'gym'],
        picked: 'bible',
        labeledActivityId: 'bible',
        nowEpochMs: now,
      );
      expect(await load(), {'gym': 4 * unit});
    });

    test('logged another way, a passed-over one is halved', () async {
      for (var i = 0; i < 4; i++) {
        await SuggestionImpressions.recordLabel(
          db,
          shown: ['gym'],
          nowEpochMs: now,
        );
      }
      await SuggestionImpressions.recordLabel(
        db,
        shown: ['gym'],
        labeledActivityId: 'gym',
        nowEpochMs: now,
      );
      expect(await SuggestionImpressions.load(db, nowEpochMs: now), {
        'gym': 2 * unit,
      });
    });

    test('counts fade by half in two weeks, then go', () async {
      await SuggestionImpressions.recordLabel(
        db,
        shown: ['gym'],
        nowEpochMs: now,
      );
      expect(
        (await SuggestionImpressions.load(
          db,
          nowEpochMs: now + 14 * day,
        ))['gym'],
        closeTo(unit / 2, 1000),
      );
      expect(
        await SuggestionImpressions.load(db, nowEpochMs: now + 61 * day),
        isEmpty,
      );
      await SuggestionImpressions.clear(db);
      expect(await SuggestionImpressions.load(db, nowEpochMs: now), isEmpty);
    });

    test('a note suggestion sinks, but never far enough to drop', () {
      const grace = ContextualSuggestionEngine.ignoredGraceMicros;
      expect(SuggestionImpressions.comboPenaltyMicros(grace), 0);
      expect(SuggestionImpressions.comboPenaltyMicros(grace + unit), 250000);
      expect(SuggestionImpressions.comboPenaltyMicros(50 * unit), 450000);
    });

    test('the loader ranks one passed over many times lower', () async {
      // After Morning, Bible and Gym take turns at this time of day.
      const hour = 60 * 60 * 1000;
      for (var i = 1; i <= 10; i++) {
        await db.insertRecord(record('m$i', 'morning', now - i * day - hour));
        await db.insertRecord(
          record('a$i', i.isEven ? 'bible' : 'gym', now - i * day),
        );
      }
      await db.insertRecord(record('m0', 'morning', now - hour));
      Future<List<String>> ranked() async => [
        for (final s in await loadRankedSuggestions(
          database: db,
          candidates: [activity('bible'), activity('gym')],
          nowEpochMs: now,
          timezoneId: zone,
          limit: 2,
        ))
          s.activity.id,
      ];

      final before = await ranked();
      for (var i = 0; i < 10; i++) {
        await SuggestionImpressions.recordLabel(
          db,
          shown: [before.first],
          labeledActivityId: 'work',
          nowEpochMs: now,
        );
      }
      expect(await ranked(), before.reversed.toList());
    });
  });
}
