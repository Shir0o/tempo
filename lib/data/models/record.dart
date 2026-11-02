bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  if (identical(a, b)) return true;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class Record {
  final String id;

  /// The Record's Activity, or null for an Untracked Record.
  final String? activityId;
  final int startedAtEpochMs;
  final int endedAtEpochMs;
  final int durationMs;
  final String comment;

  /// IANA zone the Record started in.
  final String timezoneId;

  /// IANA zone the Record ended in. Defaults to [timezoneId] for Records that
  /// never crossed a zone and for rows written before end zones existed.
  final String endTimezoneId;

  final int createdAtEpochMs;
  final int updatedAtEpochMs;
  final List<String> tagIds;

  const Record({
    required this.id,
    required this.activityId,
    required this.startedAtEpochMs,
    required this.endedAtEpochMs,
    required this.durationMs,
    this.comment = '',
    required this.timezoneId,
    String? endTimezoneId,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
    this.tagIds = const [],
  }) : endTimezoneId = endTimezoneId ?? timezoneId;

  /// Whether this Record still needs an Activity.
  bool get isUntracked => activityId == null;

  /// True elapsed time from UTC epochs. Never derived from wall-clock times,
  /// so a 6h flight across zones is always 6h.
  int get elapsedMs {
    final elapsed = endedAtEpochMs - startedAtEpochMs;
    return elapsed < 0 ? 0 : elapsed;
  }

  /// Whether the Record started and ended in different zones.
  bool get crossesTimezones => endTimezoneId != timezoneId;

  Map<String, dynamic> toMap() => {
    'id': id,
    'activity_id': activityId,
    'started_at_epoch_ms': startedAtEpochMs,
    'ended_at_epoch_ms': endedAtEpochMs,
    'duration_ms': durationMs,
    'comment': comment,
    'timezone_id': timezoneId,
    'end_timezone_id': endTimezoneId,
    'created_at_epoch_ms': createdAtEpochMs,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  factory Record.fromMap(
    Map<String, dynamic> map, {
    List<String> tagIds = const [],
  }) {
    final timezoneId = map['timezone_id'] as String;
    final storedEndZone = map['end_timezone_id'] as String?;
    return Record(
      id: map['id'] as String,
      activityId: map['activity_id'] as String?,
      startedAtEpochMs: map['started_at_epoch_ms'] as int,
      endedAtEpochMs: map['ended_at_epoch_ms'] as int,
      durationMs: map['duration_ms'] as int,
      comment: map['comment'] as String? ?? '',
      timezoneId: timezoneId,
      endTimezoneId: (storedEndZone == null || storedEndZone.isEmpty)
          ? timezoneId
          : storedEndZone,
      createdAtEpochMs: map['created_at_epoch_ms'] as int,
      updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
      tagIds: tagIds,
    );
  }

  Record copyWith({
    String? id,
    String? activityId,
    int? startedAtEpochMs,
    int? endedAtEpochMs,
    int? durationMs,
    String? comment,
    String? timezoneId,
    String? endTimezoneId,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
    List<String>? tagIds,
  }) => Record(
    id: id ?? this.id,
    activityId: activityId ?? this.activityId,
    startedAtEpochMs: startedAtEpochMs ?? this.startedAtEpochMs,
    endedAtEpochMs: endedAtEpochMs ?? this.endedAtEpochMs,
    durationMs: durationMs ?? this.durationMs,
    comment: comment ?? this.comment,
    timezoneId: timezoneId ?? this.timezoneId,
    endTimezoneId: endTimezoneId ?? this.endTimezoneId,
    createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
    updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    tagIds: tagIds ?? this.tagIds,
  );

  /// Returns a copy whose Activity is [activityId], which may be null to turn
  /// the Record back into an Untracked Record.
  Record withActivity(String? activityId) => Record(
    id: id,
    activityId: activityId,
    startedAtEpochMs: startedAtEpochMs,
    endedAtEpochMs: endedAtEpochMs,
    durationMs: durationMs,
    comment: comment,
    timezoneId: timezoneId,
    endTimezoneId: endTimezoneId,
    createdAtEpochMs: createdAtEpochMs,
    updatedAtEpochMs: updatedAtEpochMs,
    tagIds: tagIds,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Record &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          activityId == other.activityId &&
          startedAtEpochMs == other.startedAtEpochMs &&
          endedAtEpochMs == other.endedAtEpochMs &&
          durationMs == other.durationMs &&
          comment == other.comment &&
          timezoneId == other.timezoneId &&
          endTimezoneId == other.endTimezoneId &&
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs &&
          _listEquals(tagIds, other.tagIds);

  @override
  int get hashCode =>
      id.hashCode ^
      activityId.hashCode ^
      startedAtEpochMs.hashCode ^
      endedAtEpochMs.hashCode ^
      durationMs.hashCode ^
      comment.hashCode ^
      timezoneId.hashCode ^
      endTimezoneId.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode ^
      Object.hashAll(tagIds);

  @override
  String toString() =>
      'Record(id: $id, activityId: $activityId, startedAtEpochMs: $startedAtEpochMs, endedAtEpochMs: $endedAtEpochMs, durationMs: $durationMs, comment: $comment, timezoneId: $timezoneId, endTimezoneId: $endTimezoneId, tagIds: $tagIds)';
}
