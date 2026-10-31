class Tag {
  final String id;
  final String name;
  final String colorHex;
  final int createdAtEpochMs;
  final int updatedAtEpochMs;

  const Tag({
    required this.id,
    required this.name,
    this.colorHex = '#9E9E9E',
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'color_hex': colorHex,
    'created_at_epoch_ms': createdAtEpochMs,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  factory Tag.fromMap(Map<String, dynamic> map) => Tag(
    id: map['id'] as String,
    name: map['name'] as String,
    colorHex: map['color_hex'] as String? ?? '#9E9E9E',
    createdAtEpochMs: map['created_at_epoch_ms'] as int,
    updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
  );

  Tag copyWith({
    String? id,
    String? name,
    String? colorHex,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) => Tag(
    id: id ?? this.id,
    name: name ?? this.name,
    colorHex: colorHex ?? this.colorHex,
    createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
    updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tag &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          colorHex == other.colorHex &&
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      colorHex.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode;

  @override
  String toString() =>
      'Tag(id: $id, name: $name, colorHex: $colorHex, createdAtEpochMs: $createdAtEpochMs, updatedAtEpochMs: $updatedAtEpochMs)';
}
