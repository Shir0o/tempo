/// The single open, unlabeled span running from the end of the last Record to
/// now. It always runs — it cannot be paused or stopped.
class Lap {
  final int id;
  final int startedAtEpochMs;

  /// IANA zone the Lap started in, so the Record it closes into keeps the zone
  /// it was lived in even if the device moves before the Lap is labeled.
  final String startedTimezoneId;

  final int revision;

  const Lap({
    this.id = 1,
    required this.startedAtEpochMs,
    this.startedTimezoneId = '',
    this.revision = 1,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'started_at_epoch_ms': startedAtEpochMs,
    'started_timezone_id': startedTimezoneId,
    'revision': revision,
  };

  factory Lap.fromMap(Map<String, dynamic> map) => Lap(
    id: map['id'] as int? ?? 1,
    startedAtEpochMs: map['started_at_epoch_ms'] as int,
    startedTimezoneId: map['started_timezone_id'] as String? ?? '',
    revision: map['revision'] as int? ?? 1,
  );

  /// The zone this Lap actually started in, falling back to [fallback] when the
  /// start zone was not captured.
  String startTimezoneOr(String fallback) =>
      startedTimezoneId.isEmpty ? fallback : startedTimezoneId;

  Lap copyWith({
    int? startedAtEpochMs,
    String? startedTimezoneId,
    int? revision,
  }) => Lap(
    id: id,
    startedAtEpochMs: startedAtEpochMs ?? this.startedAtEpochMs,
    startedTimezoneId: startedTimezoneId ?? this.startedTimezoneId,
    revision: revision ?? this.revision,
  );

  /// Elapsed time from UTC epochs. Never derived from wall-clock times.
  int elapsedMs(int nowUtcEpochMs) {
    final elapsed = nowUtcEpochMs - startedAtEpochMs;
    return elapsed < 0 ? 0 : elapsed;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Lap &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          startedAtEpochMs == other.startedAtEpochMs &&
          startedTimezoneId == other.startedTimezoneId &&
          revision == other.revision;

  @override
  int get hashCode =>
      id.hashCode ^
      startedAtEpochMs.hashCode ^
      startedTimezoneId.hashCode ^
      revision.hashCode;

  @override
  String toString() =>
      'Lap(id: $id, startedAtEpochMs: $startedAtEpochMs, startedTimezoneId: $startedTimezoneId, revision: $revision)';
}
