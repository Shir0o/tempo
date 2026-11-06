/// Whether [name] is the conventional Contact Tag name. Only used to adopt the
/// tag when it is first created; after that the Contact Tag is whichever tag
/// carries [Tag.isContact].
bool looksLikeContactTagName(String name) =>
    name.trim().toLowerCase() == 'contact';

class Tag {
  final String id;
  final String name;
  final String colorHex;

  /// Whether this is the Contact Tag: the one attached to a Record whose
  /// comment names People (after `w/` or `with `). At most one tag carries it.
  final bool isContact;

  final int createdAtEpochMs;
  final int updatedAtEpochMs;

  const Tag({
    required this.id,
    required this.name,
    this.colorHex = '#9E9E9E',
    this.isContact = false,
    required this.createdAtEpochMs,
    required this.updatedAtEpochMs,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'color_hex': colorHex,
    'is_contact': isContact ? 1 : 0,
    'created_at_epoch_ms': createdAtEpochMs,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  factory Tag.fromMap(Map<String, dynamic> map) => Tag(
    id: map['id'] as String,
    name: map['name'] as String,
    colorHex: map['color_hex'] as String? ?? '#9E9E9E',
    isContact: (map['is_contact'] as int? ?? 0) == 1,
    createdAtEpochMs: map['created_at_epoch_ms'] as int,
    updatedAtEpochMs: map['updated_at_epoch_ms'] as int,
  );

  Tag copyWith({
    String? id,
    String? name,
    String? colorHex,
    bool? isContact,
    int? createdAtEpochMs,
    int? updatedAtEpochMs,
  }) => Tag(
    id: id ?? this.id,
    name: name ?? this.name,
    colorHex: colorHex ?? this.colorHex,
    isContact: isContact ?? this.isContact,
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
          isContact == other.isContact &&
          createdAtEpochMs == other.createdAtEpochMs &&
          updatedAtEpochMs == other.updatedAtEpochMs;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      colorHex.hashCode ^
      isContact.hashCode ^
      createdAtEpochMs.hashCode ^
      updatedAtEpochMs.hashCode;

  @override
  String toString() =>
      'Tag(id: $id, name: $name, colorHex: $colorHex, isContact: $isContact, createdAtEpochMs: $createdAtEpochMs, updatedAtEpochMs: $updatedAtEpochMs)';
}
