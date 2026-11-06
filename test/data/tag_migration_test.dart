import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/tempo_database.dart';

/// Database schema at v10 (before the Contact flag on tags).
const String _v10Tags = '''
CREATE TABLE tags (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);
''';

const String _v10Changes = '''
CREATE TABLE changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    change_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    at_epoch_ms INTEGER NOT NULL,
    payload_json TEXT NOT NULL
);
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tempo-tag-migrate');
    dbPath = p.join(tempDir.path, 'tempo.db');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('migrates v10 and marks the oldest tag named Contact', () async {
    final v10Db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, version) async {
          await db.execute(_v10Tags);
          await db.execute(_v10Changes);
        },
      ),
    );
    await v10Db.insert('tags', {
      'id': 'tag-travel',
      'name': 'Travel',
      'color_hex': '#2196F3',
      'created_at_epoch_ms': 1000,
      'updated_at_epoch_ms': 1000,
    });
    await v10Db.insert('tags', {
      'id': 'tag-late',
      'name': 'Contact',
      'color_hex': '#9E9E9E',
      'created_at_epoch_ms': 3000,
      'updated_at_epoch_ms': 3000,
    });
    await v10Db.insert('tags', {
      'id': 'tag-early',
      'name': 'contact',
      'color_hex': '#9E9E9E',
      'created_at_epoch_ms': 2000,
      'updated_at_epoch_ms': 2000,
    });
    await v10Db.close();

    final db = await TempoDatabase.open(path: dbPath);

    expect((await db.getContactTag())?.id, 'tag-early');
    expect((await db.getTagById('tag-travel'))!.isContact, isFalse);

    await db.close();
  });

  test('a fresh database starts with no Contact tag', () async {
    final db = await TempoDatabase.openInMemory(factory: databaseFactoryFfi);

    expect(await db.getContactTag(), isNull);

    await db.close();
  });
}
