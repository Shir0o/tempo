import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../data/database/tempo_database.dart';
import '../../data/models/models.dart';

/// Thrown when an export was written by a format or schema version this build
/// cannot read. An unknown version is never guessed at: the consumer refuses
/// rather than importing rows it may silently drop.
class StoreExportVersionException implements Exception {
  final String message;

  const StoreExportVersionException(this.message);

  @override
  String toString() => message;
}

/// A versioned, self-contained copy of the store's history, used to seed a
/// device that has no data (CUJ 6).
///
/// The export carries Activities, Categories, Tags, Records with their ids and
/// both IANA zones, the Records' tag links, and the open Lap. It deliberately
/// carries **no** `changes` rows and **no** cursor: the consumer backfills its
/// own change log on import, so the file cannot smuggle in another device's
/// replication state.
///
/// The envelope is `{version, schema_version, sha256, payload}`. The hash
/// covers the canonical payload only, so the header stays readable without
/// recomputing it.
class StoreExport {
  /// The export container's own format version.
  static const int formatVersion = 1;

  /// Suggested file name suffix for the share sheet.
  static const String fileExtension = 'tempo-export';

  /// The `PRAGMA user_version` of the store this export was read from.
  final int schemaVersion;

  final int createdAtEpochMs;

  /// The exporting device's `store_id`, for provenance only. Adoption keeps the
  /// consuming device's own `store_id`.
  final String sourceStoreId;

  final List<Category> categories;
  final List<Activity> activities;
  final List<Tag> tags;
  final List<Record> records;
  final Lap? lap;

  /// Lowercase hex SHA-256 of the canonical payload JSON.
  final String sha256;

  StoreExport._({
    required this.schemaVersion,
    required this.createdAtEpochMs,
    required this.sourceStoreId,
    required this.categories,
    required this.activities,
    required this.tags,
    required this.records,
    required this.lap,
    required this.sha256,
  });

  /// Builds an export with a stable row order and a freshly computed hash, so
  /// the same store always produces the same bytes apart from
  /// [createdAtEpochMs].
  factory StoreExport.create({
    required int createdAtEpochMs,
    String sourceStoreId = '',
    List<Category> categories = const [],
    List<Activity> activities = const [],
    List<Tag> tags = const [],
    List<Record> records = const [],
    Lap? lap,
    int schemaVersion = TempoDatabase.databaseVersion,
  }) {
    final normalizedCategories = [...categories]
      ..sort((a, b) => a.id.compareTo(b.id));
    final normalizedActivities = [...activities]
      ..sort((a, b) => a.id.compareTo(b.id));
    final normalizedTags = [...tags]..sort((a, b) => a.id.compareTo(b.id));
    final normalizedRecords = records.map(_withSortedTagIds).toList()
      ..sort((a, b) {
        final byStart = a.startedAtEpochMs.compareTo(b.startedAtEpochMs);
        if (byStart != 0) return byStart;
        final byEnd = a.endedAtEpochMs.compareTo(b.endedAtEpochMs);
        if (byEnd != 0) return byEnd;
        return a.id.compareTo(b.id);
      });

    final payload = _payloadFor(
      createdAtEpochMs: createdAtEpochMs,
      sourceStoreId: sourceStoreId,
      categories: normalizedCategories,
      activities: normalizedActivities,
      tags: normalizedTags,
      records: normalizedRecords,
      lap: lap,
    );

    return StoreExport._(
      schemaVersion: schemaVersion,
      createdAtEpochMs: createdAtEpochMs,
      sourceStoreId: sourceStoreId,
      categories: normalizedCategories,
      activities: normalizedActivities,
      tags: normalizedTags,
      records: normalizedRecords,
      lap: lap,
      sha256: _hashPayload(payload),
    );
  }

  /// The envelope written to the file.
  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'schema_version': schemaVersion,
    'sha256': sha256,
    'payload': _payload,
  };

  String encode() => jsonEncode(toJson());

  Uint8List encodeBytes() => Uint8List.fromList(utf8.encode(encode()));

  /// Reads and fully validates an export. Throws
  /// [StoreExportVersionException] for a newer container or schema version and
  /// [FormatException] for a malformed or tampered file.
  static StoreExport decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('A store export must be a JSON object.');
    }
    final envelope = _asMap(decoded);

    final version = envelope['version'];
    if (version is! int) {
      throw const FormatException('A store export needs a numeric version.');
    }
    if (version != formatVersion) {
      throw StoreExportVersionException(
        'Unsupported store export version: $version',
      );
    }

    final schemaVersion = envelope['schema_version'];
    if (schemaVersion is! int) {
      throw const FormatException('A store export needs a schema_version.');
    }
    if (schemaVersion < 1) {
      throw StoreExportVersionException(
        'Unsupported store schema version: $schemaVersion',
      );
    }
    if (schemaVersion > TempoDatabase.databaseVersion) {
      throw StoreExportVersionException(
        'Store export is schema v$schemaVersion, newer than this app '
        '(v${TempoDatabase.databaseVersion})',
      );
    }

    final payload = envelope['payload'];
    if (payload is! Map) {
      throw const FormatException('A store export needs a payload object.');
    }
    final payloadMap = _asMap(payload);
    final expectedHash = envelope['sha256'];
    if (expectedHash is! String || expectedHash.isEmpty) {
      throw const FormatException('A store export needs a sha256.');
    }
    final actualHash = _hashPayload(payloadMap);
    if (actualHash != expectedHash) {
      throw const FormatException(
        'Store export hash does not match its payload.',
      );
    }

    final export = StoreExport._(
      schemaVersion: schemaVersion,
      createdAtEpochMs: _readInt(payloadMap, 'created_at_epoch_ms'),
      sourceStoreId: payloadMap['source_store_id'] as String? ?? '',
      categories: _parseList(
        payloadMap['categories'],
        'categories',
        Category.fromMap,
      ),
      activities: _parseList(
        payloadMap['activities'],
        'activities',
        Activity.fromMap,
      ),
      tags: _parseList(payloadMap['tags'], 'tags', Tag.fromMap),
      records: _parseRecords(payloadMap['records']),
      lap: _parseLap(payloadMap['lap']),
      sha256: expectedHash,
    );
    export.validate();
    return export;
  }

  static StoreExport decodeBytes(List<int> bytes) {
    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('Store export is not valid UTF-8.');
    }
    return decode(source);
  }

  /// Checks the referential and row-level invariants the store's foreign keys
  /// and coverage rule rely on, so a bad file is rejected before a transaction
  /// starts.
  void validate() {
    _assertUniqueIds(categories.map((row) => row.id), 'Category');
    _assertUniqueIds(activities.map((row) => row.id), 'Activity');
    _assertUniqueIds(tags.map((row) => row.id), 'Tag');
    _assertUniqueIds(records.map((row) => row.id), 'Record');

    final categoryIds = {for (final category in categories) category.id};
    final activityIds = {for (final activity in activities) activity.id};
    final tagIds = {for (final tag in tags) tag.id};

    for (final category in categories) {
      if (category.id.isEmpty) {
        throw const FormatException('A Category has an empty id.');
      }
    }
    for (final activity in activities) {
      if (activity.id.isEmpty) {
        throw const FormatException('An Activity has an empty id.');
      }
      final categoryId = activity.categoryId;
      if (categoryId != null && !categoryIds.contains(categoryId)) {
        throw FormatException(
          'Activity ${activity.id} references missing Category $categoryId',
        );
      }
    }
    for (final tag in tags) {
      if (tag.id.isEmpty) {
        throw const FormatException('A Tag has an empty id.');
      }
    }
    for (final record in records) {
      if (record.id.isEmpty) {
        throw const FormatException('A Record has an empty id.');
      }
      if (record.startedAtEpochMs > record.endedAtEpochMs) {
        throw FormatException('Record ${record.id} ends before it starts');
      }
      final activityId = record.activityId;
      if (activityId != null && !activityIds.contains(activityId)) {
        throw FormatException(
          'Record ${record.id} references missing Activity $activityId',
        );
      }
      final seen = <String>{};
      for (final tagId in record.tagIds) {
        if (!tagIds.contains(tagId)) {
          throw FormatException(
            'Record ${record.id} references missing Tag $tagId',
          );
        }
        if (!seen.add(tagId)) {
          throw FormatException(
            'Record ${record.id} links Tag $tagId more than once',
          );
        }
      }
    }
  }

  Map<String, dynamic> get _payload => _payloadFor(
    createdAtEpochMs: createdAtEpochMs,
    sourceStoreId: sourceStoreId,
    categories: categories,
    activities: activities,
    tags: tags,
    records: records,
    lap: lap,
  );

  static Map<String, dynamic> _payloadFor({
    required int createdAtEpochMs,
    required String sourceStoreId,
    required List<Category> categories,
    required List<Activity> activities,
    required List<Tag> tags,
    required List<Record> records,
    required Lap? lap,
  }) => {
    'created_at_epoch_ms': createdAtEpochMs,
    'source_store_id': sourceStoreId,
    'categories': categories.map((row) => row.toMap()).toList(),
    'activities': activities.map((row) => row.toMap()).toList(),
    'tags': tags.map((row) => row.toMap()).toList(),
    'records': records
        .map((record) => {'record': record.toMap(), 'tag_ids': record.tagIds})
        .toList(),
    'lap': lap?.toMap(),
  };

  static String _hashPayload(Map<String, dynamic> payload) =>
      crypto.sha256.convert(utf8.encode(jsonEncode(payload))).toString();

  static Record _withSortedTagIds(Record record) {
    final tagIds = record.tagIds.toSet().toList()..sort();
    return record.copyWith(tagIds: tagIds);
  }

  static List<T> _parseList<T>(
    Object? raw,
    String label,
    T Function(Map<String, dynamic>) build,
  ) {
    if (raw is! List) {
      throw FormatException('A store export needs a $label list.');
    }
    final rows = <T>[];
    for (var index = 0; index < raw.length; index++) {
      try {
        rows.add(build(_asMap(raw[index])));
      } on FormatException {
        rethrow;
      } catch (error) {
        throw FormatException('$label[$index] is invalid: $error');
      }
    }
    return rows;
  }

  static List<Record> _parseRecords(Object? raw) {
    if (raw is! List) {
      throw const FormatException('A store export needs a records list.');
    }
    final records = <Record>[];
    for (var index = 0; index < raw.length; index++) {
      try {
        final entry = _asMap(raw[index]);
        final record = _asMap(entry['record']);
        final tagIds = entry['tag_ids'];
        if (tagIds is! List) {
          throw const FormatException('a Record needs tag_ids');
        }
        records.add(
          Record.fromMap(
            record,
            tagIds: tagIds.map((id) => id.toString()).toList(),
          ),
        );
      } on FormatException {
        rethrow;
      } catch (error) {
        throw FormatException('records[$index] is invalid: $error');
      }
    }
    return records;
  }

  static Lap? _parseLap(Object? raw) {
    if (raw == null) return null;
    try {
      return Lap.fromMap(_asMap(raw));
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('lap is invalid: $error');
    }
  }

  static int _readInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int) {
      throw FormatException('A store export needs a numeric $key.');
    }
    return value;
  }

  static void _assertUniqueIds(Iterable<String> ids, String label) {
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) {
        throw FormatException('Duplicate $label id: $id');
      }
    }
  }

  @override
  String toString() =>
      'StoreExport(schemaVersion: $schemaVersion, records: ${records.length}, '
      'activities: ${activities.length}, categories: ${categories.length}, '
      'tags: ${tags.length}, sha256: $sha256)';
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  throw const FormatException('Expected a JSON object.');
}
