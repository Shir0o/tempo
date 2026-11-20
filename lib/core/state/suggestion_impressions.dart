import 'dart:convert';

import '../../data/database/tempo_database.dart';
import 'suggestion_engine.dart';

/// How often each suggestion was shown on Today and passed over, so one shown
/// again and again but never tapped slowly ranks lower.
///
/// One count per suggestion, kept on this device as JSON in the `settings`
/// table under [storageKey]: a faded count in micro-units and when it last
/// changed. A suggestion is keyed by its Activity id, a note suggestion by
/// [SuggestionFeedback.comboKey]. Counts fade like feedback does (14-day
/// half-life). Not synced or exported.
class SuggestionImpressions {
  const SuggestionImpressions._();

  static const String storageKey = 'suggestion_ignored';

  /// Counts that have faded below this are dropped.
  static const int _dropBelowMicros = 50000;

  static const int _unit = 1000000;

  /// Every count, faded to [nowEpochMs], in micro-units.
  static Future<Map<String, int>> load(
    TempoDatabase database, {
    required int nowEpochMs,
  }) async {
    final stored = await _read(database);
    return {
      for (final MapEntry(key: key, value: (micros, at)) in stored.entries)
        if (_faded(micros, at, nowEpochMs) case final value
            when value >= _dropBelowMicros)
          key: value,
    };
  }

  /// A Lap was labeled on Today while [shown] suggestions were on screen.
  ///
  /// [picked] was the one tapped, if any: its count starts again from zero.
  /// The rest were passed over and count once more, except one for
  /// [labeledActivityId], which was logged another way and so is halved.
  static Future<void> recordLabel(
    TempoDatabase database, {
    required Iterable<String> shown,
    String? picked,
    String? labeledActivityId,
    required int nowEpochMs,
  }) async {
    final keys = shown.toSet();
    if (keys.isEmpty && picked == null) return;
    final stored = await _read(database);
    // Untouched counts keep fading from when they last changed.
    final next = <String, (int, int)>{
      for (final MapEntry(key: key, value: (micros, at)) in stored.entries)
        if (_faded(micros, at, nowEpochMs) >= _dropBelowMicros)
          key: (micros, at),
    };
    for (final key in keys) {
      if (key == picked) continue;
      final value = switch (next[key]) {
        (final micros, final at) => _faded(micros, at, nowEpochMs),
        null => 0,
      };
      next[key] = (
        key == labeledActivityId ? value ~/ 2 : value + _unit,
        nowEpochMs,
      );
    }
    if (picked != null) next.remove(picked);
    await database.setSetting(
      storageKey,
      jsonEncode({
        for (final MapEntry(key: key, value: (micros, at)) in next.entries)
          key: [micros, at],
      }),
    );
  }

  /// How far a note suggestion passed over [ignoredMicros] times sinks among
  /// the notes, in feedback micro-units: nothing for the first
  /// [ContextualSuggestionEngine.ignoredGraceMicros], then a quarter of a
  /// vote for each time after, short of the half vote that leaves a note out.
  static int comboPenaltyMicros(int ignoredMicros) {
    final excess =
        ignoredMicros - ContextualSuggestionEngine.ignoredGraceMicros;
    if (excess <= 0) return 0;
    return excess ~/ 4 < _maxComboPenaltyMicros
        ? excess ~/ 4
        : _maxComboPenaltyMicros;
  }

  static const int _maxComboPenaltyMicros = 450000;

  /// Forgets every count.
  static Future<void> clear(TempoDatabase database) =>
      database.setSetting(storageKey, '');

  static int _faded(int micros, int atEpochMs, int nowEpochMs) =>
      micros *
      ContextualSuggestionEngine.decayMicros(
        nowEpochMs > atEpochMs ? nowEpochMs - atEpochMs : 0,
      ) ~/
      _unit;

  static Future<Map<String, (int, int)>> _read(TempoDatabase database) async {
    final stored = await database.getSetting(storageKey);
    if (stored == null || stored.isEmpty) return {};
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return {};
      return {
        for (final MapEntry(key: key, value: value) in decoded.entries)
          if (key is String &&
              value is List &&
              value.length == 2 &&
              value[0] is int &&
              value[1] is int)
            key: (value[0] as int, value[1] as int),
      };
    } on FormatException {
      return {};
    }
  }
}
