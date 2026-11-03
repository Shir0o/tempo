class Category {
  final String id;
  final String name;
  final String colorHex;
  final String iconName;
  final int sortOrder;
  final int createdAtEpochMs;
  final int updatedAtEpochMs;

  const Category({
    required this.id,
    required this.name,
    this.colorHex = '#4CAF50',
    this.iconName = 'folder',
    this.sortOrder = 0,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'color_hex': colorHex,
    'icon_name': iconName,
    'sort_order': sortOrder,
    'created_at_epoch_ms': createdAtEpochMs,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  factory Category.fromMap(Map<String, dynamic> map) => Category(
    id: map['id'] as String,
    name: map['name'] as String,
    colorHex: map['color_hex'] as String? ?? '#4CAF50',
    iconName: map['icon_name'] as String? ?? 'folder',
    sortOrder: map['sort_order'] as int? ?? 0,
    createdAtEpochMs: map['created_at_epoch_ms'] as int,
    updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
  );

  Category copyWith({
    String? id,
    String? name,
    String? colorHex,
    String? iconName,
    int? sortOrder,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) => Category(
    id: id ?? this.id,
    name: name ?? this.name,
    colorHex: colorHex ?? this.colorHex,
    iconName: iconName ?? this.iconName,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
    updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Category &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          colorHex == other.colorHex &&
          iconName == other.iconName &&
          sortOrder == other.sortOrder &&
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      colorHex.hashCode ^
      iconName.hashCode ^
      sortOrder.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode;

  @override
  String toString() =>
      'Category(id: $id, name: $name, colorHex: $colorHex, iconName: $iconName, sortOrder: $sortOrder, createdAtEpochMs: $createdAtEpochMs, updatedAtEpochMs: $updatedAtEpochMs)';
}
