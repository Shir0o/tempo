import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'models.dart';

/// The nine kinds a Change can carry. A Change always carries the whole row.
enum SyncChangeKind {
  categoryUpsert('category_upsert'),
  categoryRemove('category_remove'),
  activityUpsert('activity_upsert'),
  activityRemove('activity_remove'),
  tagUpsert('tag_upsert'),
  tagRemove('tag_remove'),
  recordUpsert('record_upsert'),
  recordRemove('record_remove'),
  lapSet('lap_set');

  const SyncChangeKind(this.wireName);

  /// The value stored in `changes.kind` and sent over the wire.
  final String wireName;

  static SyncChangeKind? tryParse(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

/// One row of the phone's append-only change log.
///
/// A Change is written in the same transaction as the mutation it describes, so
/// the log can never disagree with the store. Applying a Change is an
/// update-then-insert keyed by the text id, in `seq` order.
class SyncChange {
  /// The version of the encoded `payload_json`.
  static const int formatVersion = 1;

  final String changeId;
  final SyncChangeKind kind;
  final String entityId;
  final int atEpochMs;

  /// The change's body: the whole row, or an id for a removal.
  final Map<String, dynamic> payload;

  /// Set when the Change was read back from the log.
  final int? seq;

  const SyncChange({
    required this.changeId,
    required this.kind,
    required this.entityId,
    required this.atEpochMs,
    required this.payload,
    this.seq,
  });

  factory SyncChange.categoryUpsert(
    Category category, {
    required int atEpochMs,
    String? changeId,
  }) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: SyncChangeKind.categoryUpsert,
    entityId: category.id,
    atEpochMs: atEpochMs,
    payload: {'category': category.toMap()},
  );

  factory SyncChange.categoryRemove(
    String categoryId, {
    required int atEpochMs,
    String? changeId,
  }) => _remove(SyncChangeKind.categoryRemove, categoryId, atEpochMs, changeId);

  factory SyncChange.activityUpsert(
    Activity activity, {
    required int atEpochMs,
    String? changeId,
  }) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: SyncChangeKind.activityUpsert,
    entityId: activity.id,
    atEpochMs: atEpochMs,
    payload: {'activity': activity.toMap()},
  );

  factory SyncChange.activityRemove(
    String activityId, {
    required int atEpochMs,
    String? changeId,
  }) => _remove(SyncChangeKind.activityRemove, activityId, atEpochMs, changeId);

  factory SyncChange.tagUpsert(
    Tag tag, {
    required int atEpochMs,
    String? changeId,
  }) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: SyncChangeKind.tagUpsert,
    entityId: tag.id,
    atEpochMs: atEpochMs,
    payload: {'tag': tag.toMap()},
  );

  factory SyncChange.tagRemove(
    String tagId, {
    required int atEpochMs,
    String? changeId,
  }) => _remove(SyncChangeKind.tagRemove, tagId, atEpochMs, changeId);

  /// A full Record row plus its tag ids. An upsert with a null Activity is the
  /// user's delete: the span stays in the Day as an Untracked Record.
  factory SyncChange.recordUpsert(
    Record record, {
    required int atEpochMs,
    String? changeId,
  }) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: SyncChangeKind.recordUpsert,
    entityId: record.id,
    atEpochMs: atEpochMs,
    payload: {'record': record.toMap(), 'tag_ids': record.tagIds},
  );

  factory SyncChange.recordRemove(
    String recordId, {
    required int atEpochMs,
    String? changeId,
  }) => _remove(SyncChangeKind.recordRemove, recordId, atEpochMs, changeId);

  /// The open Lap: its start, its start zone, and the zone it was in when this
  /// change was written. [revision] lets a replica compare row for row.
  factory SyncChange.lapSet(
    Lap lap, {
    required int atEpochMs,
    String? endTimezoneId,
    String? changeId,
  }) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: SyncChangeKind.lapSet,
    entityId: 'lap',
    atEpochMs: atEpochMs,
    payload: {
      'lap': {
        'started_at_epoch_ms': lap.startedAtEpochMs,
        'started_timezone_id': lap.startedTimezoneId,
        'end_timezone_id': endTimezoneId ?? lap.startedTimezoneId,
        'revision': lap.revision,
      },
    },
  );

  static SyncChange _remove(
    SyncChangeKind kind,
    String entityId,
    int atEpochMs,
    String? changeId,
  ) => SyncChange(
    changeId: changeId ?? _newId(),
    kind: kind,
    entityId: entityId,
    atEpochMs: atEpochMs,
    payload: {'id': entityId},
  );

  Category? get category => payload['category'] is Map
      ? Category.fromMap(_asMap(payload['category']))
      : null;

  Activity? get activity => payload['activity'] is Map
      ? Activity.fromMap(_asMap(payload['activity']))
      : null;

  Tag? get tag =>
      payload['tag'] is Map ? Tag.fromMap(_asMap(payload['tag'])) : null;

  Record? get record => payload['record'] is Map
      ? Record.fromMap(_asMap(payload['record']), tagIds: tagIds)
      : null;

  List<String> get tagIds {
    final raw = payload['tag_ids'];
    if (raw is! List) return const [];
    return raw.map((id) => id.toString()).toList(growable: false);
  }

  Lap? get lap {
    final raw = payload['lap'];
    if (raw is! Map) return null;
    final map = _asMap(raw);
    return Lap(
      startedAtEpochMs: map['started_at_epoch_ms'] as int,
      startedTimezoneId: map['started_timezone_id'] as String? ?? '',
      revision: map['revision'] as int? ?? 1,
    );
  }

  /// The columns of one `changes` row, without the autoincrement `seq`.
  Map<String, dynamic> toChangeRow() => {
    'change_id': changeId,
    'kind': kind.wireName,
    'entity_id': entityId,
    'at_epoch_ms': atEpochMs,
    'payload_json': encodePayload(payload),
  };

  /// Reads one `changes` row. Throws [FormatException] for an unknown kind or a
  /// payload written by an incompatible version.
  factory SyncChange.fromRow(Map<String, dynamic> row) {
    final kind = SyncChangeKind.tryParse(row['kind'] as String);
    if (kind == null) {
      throw FormatException('Unknown change kind: ${row['kind']}');
    }
    return SyncChange(
      changeId: row['change_id'] as String,
      kind: kind,
      entityId: row['entity_id'] as String,
      atEpochMs: row['at_epoch_ms'] as int,
      payload: decodePayload(row['payload_json'] as String),
      seq: row['seq'] as int?,
    );
  }

  static String encodePayload(Map<String, dynamic> payload) =>
      jsonEncode({'version': formatVersion, 'payload': payload});

  static Map<String, dynamic> decodePayload(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('A change payload must be a JSON object.');
    }
    final envelope = _asMap(decoded);
    if (envelope['version'] != formatVersion) {
      throw FormatException(
        'Unsupported change payload version: ${envelope['version']}',
      );
    }
    final payload = envelope['payload'];
    if (payload is! Map) {
      throw const FormatException('A change payload must wrap a JSON object.');
    }
    return _asMap(payload);
  }

  @override
  String toString() =>
      'SyncChange(seq: $seq, kind: ${kind.wireName}, entityId: $entityId, atEpochMs: $atEpochMs)';
}

/// The ten kinds a client may propose. The Mac and the watch never write a
/// Record; they send a SyncIntent and the phone decides.
enum SyncIntentKind {
  label('label'),
  split('split'),
  relabel('relabel'),
  annotate('annotate'),
  adjustEdges('adjust_edges'),
  clear('clear'),
  undo('undo'),
  merge('merge'),
  splitRecord('split_record'),
  continueLast('continue_last');

  const SyncIntentKind(this.wireName);

  final String wireName;

  static SyncIntentKind? tryParse(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

/// A proposed mutation carrying the instant and zone it was authored at, and
/// the Lap start the author saw.
class SyncIntent {
  static const int formatVersion = 1;

  final String intentId;
  final SyncIntentKind kind;
  final int tappedAtEpochMs;
  final String tappedAtZoneId;
  final int expectedLapStartEpochMs;
  final Map<String, dynamic> payload;

  const SyncIntent({
    required this.intentId,
    required this.kind,
    required this.tappedAtEpochMs,
    required this.tappedAtZoneId,
    required this.expectedLapStartEpochMs,
    this.payload = const {},
  });

  factory SyncIntent.label({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String activityId,
    String comment = '',
    List<String> tagIds = const [],
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.label,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'activity_id': activityId, 'comment': comment, 'tag_ids': tagIds},
  );

  factory SyncIntent.split({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.split,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
  );

  factory SyncIntent.continueLast({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.continueLast,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
  );

  factory SyncIntent.relabel({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
    String? activityId,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.relabel,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'record_id': recordId, 'activity_id': activityId},
  );

  factory SyncIntent.annotate({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
    required String comment,
    required List<String> tagIds,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.annotate,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'record_id': recordId, 'comment': comment, 'tag_ids': tagIds},
  );

  factory SyncIntent.adjustEdges({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
    int? startEpochMs,
    int? endEpochMs,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.adjustEdges,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {
      'record_id': recordId,
      'start_epoch_ms': startEpochMs,
      'end_epoch_ms': endEpochMs,
    },
  );

  factory SyncIntent.clear({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.clear,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'record_id': recordId},
  );

  /// Undo by the Record a Mac created.
  factory SyncIntent.undoRecord({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.undo,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'record_id': recordId},
  );

  /// Undo by the watch's `actionId`, resolved through `processed_intents`.
  factory SyncIntent.undoAction({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String actionId,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.undo,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'action_id': actionId},
  );

  factory SyncIntent.merge({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String leftRecordId,
    required String rightRecordId,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.merge,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'left_record_id': leftRecordId, 'right_record_id': rightRecordId},
  );

  factory SyncIntent.splitRecord({
    required String intentId,
    required int tappedAtEpochMs,
    required String tappedAtZoneId,
    required int expectedLapStartEpochMs,
    required String recordId,
    required int atEpochMs,
  }) => SyncIntent(
    intentId: intentId,
    kind: SyncIntentKind.splitRecord,
    tappedAtEpochMs: tappedAtEpochMs,
    tappedAtZoneId: tappedAtZoneId,
    expectedLapStartEpochMs: expectedLapStartEpochMs,
    payload: {'record_id': recordId, 'at_epoch_ms': atEpochMs},
  );

  String? get activityId => payload['activity_id'] as String?;

  String? get recordId => payload['record_id'] as String?;

  String? get leftRecordId => payload['left_record_id'] as String?;

  String? get rightRecordId => payload['right_record_id'] as String?;

  String? get actionId => payload['action_id'] as String?;

  String get comment => payload['comment'] as String? ?? '';

  List<String> get tagIds {
    final raw = payload['tag_ids'];
    if (raw is! List) return const [];
    return raw.map((id) => id.toString()).toList(growable: false);
  }

  int? get startEpochMs => payload['start_epoch_ms'] as int?;

  int? get endEpochMs => payload['end_epoch_ms'] as int?;

  int? get atEpochMs => payload['at_epoch_ms'] as int?;

  /// The versioned body stored in the Mac's `intents.payload_json`.
  String get payloadJson =>
      jsonEncode({'version': formatVersion, 'payload': payload});

  /// The full envelope used on the wire.
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'intent_id': intentId,
    'kind': kind.wireName,
    'tapped_at_epoch_ms': tappedAtEpochMs,
    'tapped_at_zone_id': tappedAtZoneId,
    'expected_lap_start_epoch_ms': expectedLapStartEpochMs,
    'payload': payload,
  };

  factory SyncIntent.fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw FormatException(
        'Unsupported intent envelope version: ${json['version']}',
      );
    }
    final kind = SyncIntentKind.tryParse(json['kind'] as String);
    if (kind == null) {
      throw FormatException('Unknown intent kind: ${json['kind']}');
    }
    final payload = json['payload'];
    return SyncIntent(
      intentId: json['intent_id'] as String,
      kind: kind,
      tappedAtEpochMs: json['tapped_at_epoch_ms'] as int,
      tappedAtZoneId: json['tapped_at_zone_id'] as String,
      expectedLapStartEpochMs: json['expected_lap_start_epoch_ms'] as int,
      payload: payload is Map ? _asMap(payload) : const {},
    );
  }

  /// Reads one row of the Mac's `intents` table.
  factory SyncIntent.fromRow(Map<String, dynamic> row) {
    final kind = SyncIntentKind.tryParse(row['kind'] as String);
    if (kind == null) {
      throw FormatException('Unknown intent kind: ${row['kind']}');
    }
    final decoded = jsonDecode(row['payload_json'] as String);
    if (decoded is! Map) {
      throw const FormatException('An intent payload must be a JSON object.');
    }
    final envelope = _asMap(decoded);
    if (envelope['version'] != formatVersion) {
      throw FormatException(
        'Unsupported intent payload version: ${envelope['version']}',
      );
    }
    return SyncIntent(
      intentId: row['intent_id'] as String,
      kind: kind,
      tappedAtEpochMs: row['tapped_at_epoch_ms'] as int,
      tappedAtZoneId: row['tapped_at_zone_id'] as String,
      expectedLapStartEpochMs: row['expected_lap_start_epoch_ms'] as int,
      payload: _asMap(envelope['payload']),
    );
  }

  @override
  String toString() =>
      'SyncIntent($intentId, kind: ${kind.wireName}, tappedAt: $tappedAtEpochMs)';
}

/// The phone's answer to an intent.
class IntentResult {
  static const String appliedStatus = 'applied';
  static const String rejectedStatus = 'rejected';

  static const String reasonLapMoved = 'lap-moved';
  static const String reasonOverlap = 'overlap';
  static const String reasonUnknownActivity = 'unknown-activity';
  static const String reasonClockSkew = 'clock-skew';
  static const String reasonUnknownRecord = 'unknown-record';

  /// `applied` or `rejected`.
  final String status;
  final String reason;

  /// The Record or entity the intent produced, when it produced one.
  final String entityId;
  final int appliedAtEpochMs;

  const IntentResult({
    required this.status,
    this.reason = '',
    this.entityId = '',
    this.appliedAtEpochMs = 0,
  });

  factory IntentResult.applied({
    String entityId = '',
    required int appliedAtEpochMs,
  }) => IntentResult(
    status: appliedStatus,
    entityId: entityId,
    appliedAtEpochMs: appliedAtEpochMs,
  );

  factory IntentResult.rejected(String reason, {String entityId = ''}) =>
      IntentResult(status: rejectedStatus, reason: reason, entityId: entityId);

  bool get isApplied => status == appliedStatus;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntentResult &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          reason == other.reason &&
          entityId == other.entityId &&
          appliedAtEpochMs == other.appliedAtEpochMs;

  @override
  int get hashCode =>
      status.hashCode ^
      reason.hashCode ^
      entityId.hashCode ^
      appliedAtEpochMs.hashCode;

  @override
  String toString() =>
      'IntentResult(status: $status, reason: $reason, entityId: $entityId, appliedAtEpochMs: $appliedAtEpochMs)';
}

/// One row of `processed_intents`: the guard that makes an intent or a watch
/// action apply exactly once. Keyed by `(log_epoch, intent_id)`.
class ProcessedIntent {
  final String logEpoch;
  final String intentId;
  final String entityId;
  final int appliedAtEpochMs;
  final String result;
  final String reason;

  const ProcessedIntent({
    required this.logEpoch,
    required this.intentId,
    this.entityId = '',
    required this.appliedAtEpochMs,
    required this.result,
    this.reason = '',
  });

  Map<String, dynamic> toMap() => {
    'log_epoch': logEpoch,
    'intent_id': intentId,
    'entity_id': entityId,
    'applied_at_epoch_ms': appliedAtEpochMs,
    'result': result,
    'reason': reason,
  };

  factory ProcessedIntent.fromMap(Map<String, dynamic> map) => ProcessedIntent(
    logEpoch: map['log_epoch'] as String,
    intentId: map['intent_id'] as String,
    entityId: map['entity_id'] as String? ?? '',
    appliedAtEpochMs: map['applied_at_epoch_ms'] as int,
    result: map['result'] as String,
    reason: map['reason'] as String? ?? '',
  );

  IntentResult toIntentResult() => IntentResult(
    status: result,
    reason: reason,
    entityId: entityId,
    appliedAtEpochMs: appliedAtEpochMs,
  );

  @override
  String toString() =>
      'ProcessedIntent(logEpoch: $logEpoch, intentId: $intentId, result: $result)';
}

/// A paired client's identity and address. Pairing secrets live in platform
/// secure storage, never here.
class SyncPeer {
  /// The port a phone's replication listener binds, and the one a pairing row
  /// falls back to when it carries none.
  static const int defaultPort = 8727;

  final String peerDeviceId;
  final String storeId;
  final String host;
  final int port;
  final int lastSeenEpochMs;

  const SyncPeer({
    required this.peerDeviceId,
    required this.storeId,
    required this.host,
    this.port = defaultPort,
    required this.lastSeenEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'peer_device_id': peerDeviceId,
    'store_id': storeId,
    'host': host,
    'port': port,
    'last_seen_epoch_ms': lastSeenEpochMs,
  };

  factory SyncPeer.fromMap(Map<String, dynamic> map) => SyncPeer(
    peerDeviceId: map['peer_device_id'] as String,
    storeId: map['store_id'] as String,
    host: map['host'] as String,
    port: map['port'] as int? ?? defaultPort,
    lastSeenEpochMs: map['last_seen_epoch_ms'] as int,
  );

  @override
  String toString() =>
      'SyncPeer(peerDeviceId: $peerDeviceId, storeId: $storeId, '
      'host: $host:$port)';
}

/// The eight settings seeded at v10, read and written as one record.
class SyncSettings {
  final String storeId;
  final String deviceId;
  final String logEpoch;
  final bool backupEnabled;
  final String backupDestination;
  final int backupGenerations;
  final bool exportRedactComments;
  final bool replicateEnabled;

  const SyncSettings({
    this.storeId = '',
    this.deviceId = '',
    this.logEpoch = '',
    this.backupEnabled = false,
    this.backupDestination = '',
    this.backupGenerations = 5,
    this.exportRedactComments = false,
    this.replicateEnabled = false,
  });

  factory SyncSettings.fromSettingsMap(Map<String, String?> values) =>
      SyncSettings(
        storeId: values['store_id'] ?? '',
        deviceId: values['device_id'] ?? '',
        logEpoch: values['log_epoch'] ?? '',
        backupEnabled: values['backup_enabled'] == 'true',
        backupDestination: values['backup_destination'] ?? '',
        backupGenerations:
            int.tryParse(values['backup_generations'] ?? '') ?? 5,
        exportRedactComments: values['export_redact_comments'] == 'true',
        replicateEnabled: values['replicate_enabled'] == 'true',
      );

  Map<String, String> toSettingsMap() => {
    'store_id': storeId,
    'device_id': deviceId,
    'log_epoch': logEpoch,
    'backup_enabled': backupEnabled ? 'true' : 'false',
    'backup_destination': backupDestination,
    'backup_generations': backupGenerations.toString(),
    'export_redact_comments': exportRedactComments ? 'true' : 'false',
    'replicate_enabled': replicateEnabled ? 'true' : 'false',
  };
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  throw const FormatException('Expected a JSON object.');
}

String _newId() => const Uuid().v4();
