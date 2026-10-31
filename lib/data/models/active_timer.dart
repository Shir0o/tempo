import 'dart:convert';

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  if (identical(a, b)) return true;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class ActiveTimer {
  final int id;
  final String activityId;
  final int startedAtEpochMs;
  final bool isPaused;
  final int? pausedAtEpochMs;
  final int accumulatedPauseMs;
  final String currentComment;
  final List<String> initialTagIds;
  final int lastHeartbeatEpochMs;
  final int revision;

  const ActiveTimer({
    this.id = 1,
    required this.activityId,
    required this.startedAtEpochMs,
    this.isPaused = false,
    this.pausedAtEpochMs,
    this.accumulatedPauseMs = 0,
    this.currentComment = '',
    this.initialTagIds = const [],
    required this.lastHeartbeatEpochMs,
    this.revision = 1,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'activity_id': activityId,
        'started_at_epoch_ms': startedAtEpochMs,
        'is_paused': isPaused ? 1 : 0,
        'paused_at_epoch_ms': pausedAtEpochMs,
        'accumulated_pause_ms': accumulatedPauseMs,
        'current_comment': currentComment,
        'initial_tags_json': jsonEncode(initialTagIds),
        'last_heartbeat_epoch_ms': lastHeartbeatEpochMs,
        'revision': revision,
      };

  factory ActiveTimer.fromMap(Map<String, dynamic> map) {
    List<String> tags = const [];
    final tagsJson = map['initial_tags_json'];
    if (tagsJson is String && tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson);
        if (decoded is List) {
          tags = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return ActiveTimer(
      id: map['id'] as int? ?? 1,
      activityId: map['activity_id'] as String,
      startedAtEpochMs: map['started_at_epoch_ms'] as int,
      isPaused: (map['is_paused'] as int? ?? 0) == 1,
      pausedAtEpochMs: map['paused_at_epoch_ms'] as int?,
      accumulatedPauseMs: map['accumulated_pause_ms'] as int? ?? 0,
      currentComment: map['current_comment'] as String? ?? '',
      initialTagIds: tags,
      lastHeartbeatEpochMs: map['last_heartbeat_epoch_ms'] as int,
      revision: map['revision'] as int? ?? 1,
    );
  }

  /// Evaluates elapsed duration in milliseconds based on UTC epoch arithmetic.
  /// Matches specification section 3.1:
  /// elapsedMs = (is_paused ? paused_at : nowUtc) - started_at - accumulated_pause
  int calculateDurationMs(int nowUtcEpochMs) {
    final referenceTime =
        isPaused && pausedAtEpochMs != null ? pausedAtEpochMs! : nowUtcEpochMs;
    final duration = referenceTime - startedAtEpochMs - accumulatedPauseMs;
    return duration < 0 ? 0 : duration;
  }

  ActiveTimer copyWith({
    int? id,
    String? activityId,
    int? startedAtEpochMs,
    bool? isPaused,
    int? pausedAtEpochMs,
    bool clearPausedAt = false,
    int? accumulatedPauseMs,
    String? currentComment,
    List<String>? initialTagIds,
    int? lastHeartbeatEpochMs,
    int? revision,
  }) =>
      ActiveTimer(
        id: id ?? this.id,
        activityId: activityId ?? this.activityId,
        startedAtEpochMs: startedAtEpochMs ?? this.startedAtEpochMs,
        isPaused: isPaused ?? this.isPaused,
        pausedAtEpochMs:
            clearPausedAt ? null : (pausedAtEpochMs ?? this.pausedAtEpochMs),
        accumulatedPauseMs: accumulatedPauseMs ?? this.accumulatedPauseMs,
        currentComment: currentComment ?? this.currentComment,
        initialTagIds: initialTagIds ?? this.initialTagIds,
        lastHeartbeatEpochMs: lastHeartbeatEpochMs ?? this.lastHeartbeatEpochMs,
        revision: revision ?? this.revision,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveTimer &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          activityId == other.activityId &&
          startedAtEpochMs == other.startedAtEpochMs &&
          isPaused == other.isPaused &&
          pausedAtEpochMs == other.pausedAtEpochMs &&
          accumulatedPauseMs == other.accumulatedPauseMs &&
          currentComment == other.currentComment &&
          lastHeartbeatEpochMs == other.lastHeartbeatEpochMs &&
          revision == other.revision &&
          _listEquals(initialTagIds, other.initialTagIds);

  @override
  int get hashCode =>
      id.hashCode ^
      activityId.hashCode ^
      startedAtEpochMs.hashCode ^
      isPaused.hashCode ^
      pausedAtEpochMs.hashCode ^
      accumulatedPauseMs.hashCode ^
      currentComment.hashCode ^
      lastHeartbeatEpochMs.hashCode ^
      revision.hashCode ^
      Object.hashAll(initialTagIds);

  @override
  String toString() =>
      'ActiveTimer(id: $id, activityId: $activityId, startedAtEpochMs: $startedAtEpochMs, isPaused: $isPaused, pausedAtEpochMs: $pausedAtEpochMs, accumulatedPauseMs: $accumulatedPauseMs, currentComment: $currentComment, initialTagIds: $initialTagIds, lastHeartbeatEpochMs: $lastHeartbeatEpochMs, revision: $revision)';
}
