class Tombstone {
  final String entityId;
  final String entityType; // 'record', 'activity', 'tag'
  final int deletedAtEpochMs;

  const Tombstone({
    required this.entityId,
    required this.entityType,
    required this.deletedAtEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'entity_id': entityId,
    'entity_type': entityType,
    'deleted_at_epoch_ms': deletedAtEpochMs,
  };

  factory Tombstone.fromMap(Map<String, dynamic> map) => Tombstone(
    entityId: map['entity_id'] as String,
    entityType: map['entity_type'] as String,
    deletedAtEpochMs: map['deleted_at_epoch_ms'] as int,
  );

  Tombstone copyWith({
    String? entityId,
    String? entityType,
    int? deletedAtEpochMs,
  }) => Tombstone(
    entityId: entityId ?? this.entityId,
    entityType: entityType ?? this.entityType,
    deletedAtEpochMs: deletedAtEpochMs ?? this.deletedAtEpochMs,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tombstone &&
          runtimeType == other.runtimeType &&
          entityId == other.entityId &&
          entityType == other.entityType &&
          deletedAtEpochMs == other.deletedAtEpochMs;

  @override
  int get hashCode =>
      entityId.hashCode ^ entityType.hashCode ^ deletedAtEpochMs.hashCode;

  @override
  String toString() =>
      'Tombstone(entityId: $entityId, entityType: $entityType, deletedAtEpochMs: $deletedAtEpochMs)';
}
