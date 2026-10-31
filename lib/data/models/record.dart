import 'package:flutter/foundation.dart';

class Record {
  final String id;
  final String activityId;
  final int startedAtEpochMs;
  final int endedAtEpochMs;
  final int durationMs;
  final String comment;
  final String timezoneId;
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
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
    this.tagIds = const [],
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'activity_id': activityId,
        'started_at_epoch_ms': startedAtEpochMs,
        'ended_at_epoch_ms': endedAtEpochMs,
        'duration_ms': durationMs,
        'comment': comment,
        'timezone_id': timezoneId,
        'created_at_epoch_ms': createdAtEpochMs,
        'updated_at_epoch_ms': updatedAtEpochMs,
      };

  factory Record.fromMap(
    Map<String, dynamic> map, {
    List<String> tagIds = const [],
  }) =>
      Record(
        id: map['id'] as String,
        activityId: map['activity_id'] as String,
        startedAtEpochMs: map['started_at_epoch_ms'] as int,
        endedAtEpochMs: map['ended_at_epoch_ms'] as int,
        durationMs: map['duration_ms'] as int,
        comment: map['comment'] as String? ?? '',
        timezoneId: map['timezone_id'] as String,
        createdAtEpochMs: map['created_at_epoch_ms'] as int,
        updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
        tagIds: tagIds,
      );

  Record copyWith({
    String? id,
    String? activityId,
    int? startedAtEpochMs,
    int? endedAtEpochMs,
    int? durationMs,
    String? comment,
    String? timezoneId,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
    List<String>? tagIds,
  }) =>
      Record(
        id: id ?? this.id,
        activityId: activityId ?? this.activityId,
        startedAtEpochMs: startedAtEpochMs ?? this.startedAtEpochMs,
        endedAtEpochMs: endedAtEpochMs ?? this.endedAtEpochMs,
        durationMs: durationMs ?? this.durationMs,
        comment: comment ?? this.comment,
        timezoneId: timezoneId ?? this.timezoneId,
        createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
        updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
        tagIds: tagIds ?? this.tagIds,
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
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs &&
          listEquals(tagIds, other.tagIds);

  @override
  int get hashCode =>
      id.hashCode ^
      activityId.hashCode ^
      startedAtEpochMs.hashCode ^
      endedAtEpochMs.hashCode ^
      durationMs.hashCode ^
      comment.hashCode ^
      timezoneId.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode ^
      Object.hashAll(tagIds);

  @override
  String toString() =>
      'Record(id: $id, activityId: $activityId, startedAtEpochMs: $startedAtEpochMs, endedAtEpochMs: $endedAtEpochMs, durationMs: $durationMs, comment: $comment, timezoneId: $timezoneId, tagIds: $tagIds)';
}
