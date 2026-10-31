class Activity {
  final String id;
  final String name;
  final String colorHex;
  final String iconName;
  final bool isPinned;
  final int sortOrder;
  final bool isArchived;
  final int createdAtEpochMs;
  final int updatedAtEpochMs;

  const Activity({
    required this.id,
    required this.name,
    this.colorHex = '#4CAF50',
    this.iconName = 'schedule',
    this.isPinned = false,
    this.sortOrder = 0,
    this.isArchived = false,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'color_hex': colorHex,
    'icon_name': iconName,
    'is_pinned': isPinned ? 1 : 0,
    'sort_order': sortOrder,
    'is_archived': isArchived ? 1 : 0,
    'created_at_epoch_ms': createdAtEpochMs,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  factory Activity.fromMap(Map<String, dynamic> map) => Activity(
    id: map['id'] as String,
    name: map['name'] as String,
    colorHex: map['color_hex'] as String? ?? '#4CAF50',
    iconName: map['icon_name'] as String? ?? 'schedule',
    isPinned: (map['is_pinned'] as int? ?? 0) == 1,
    sortOrder: map['sort_order'] as int? ?? 0,
    isArchived: (map['is_archived'] as int? ?? 0) == 1,
    createdAtEpochMs: map['created_at_epoch_ms'] as int,
    updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
  );

  Activity copyWith({
    String? id,
    String? name,
    String? colorHex,
    String? iconName,
    bool? isPinned,
    int? sortOrder,
    bool? isArchived,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) => Activity(
    id: id ?? this.id,
    name: name ?? this.name,
    colorHex: colorHex ?? this.colorHex,
    iconName: iconName ?? this.iconName,
    isPinned: isPinned ?? this.isPinned,
    sortOrder: sortOrder ?? this.sortOrder,
    isArchived: isArchived ?? this.isArchived,
    createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
    updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Activity &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          colorHex == other.colorHex &&
          iconName == other.iconName &&
          isPinned == other.isPinned &&
          sortOrder == other.sortOrder &&
          isArchived == other.isArchived &&
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      colorHex.hashCode ^
      iconName.hashCode ^
      isPinned.hashCode ^
      sortOrder.hashCode ^
      isArchived.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode;

  @override
  String toString() =>
      'Activity(id: $id, name: $name, colorHex: $colorHex, iconName: $iconName, isPinned: $isPinned, sortOrder: $sortOrder, isArchived: $isArchived, createdAtEpochMs: $createdAtEpochMs, updatedAtEpochMs: $updatedAtEpochMs)';
}
