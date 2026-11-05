import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tempo/data/database/store_lifecycle.dart';
import 'package:tempo/data/database/tempo_database.dart';
import 'package:tempo/mcp/pii_sanitizer.dart';
import 'package:tempo/mcp/tempo_mcp_server.dart';

void printUsage() {
  stdout.writeln('''
Tempo Model Context Protocol (MCP) Server.

Usage: tempo-mcp [flags]

Flags:
  --db-path <path>    Path to the SQLite database file.
  --[no-]sanitize-pii Redact contact names, emails, and phone numbers (default: true).
  --[no-]allow-writes Enable write tools (label the Lap, split the Lap, adjust a Record's edge) (default: false).
  -h, --help          Show this usage message.
''');
}

Future<void> main(List<String> args) async {
  String? dbPath;
  bool sanitizePii = true;
  bool allowWrites = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') {
      printUsage();
      exit(0);
    } else if (arg == '--db-path' && i + 1 < args.length) {
      dbPath = args[++i];
    } else if (arg.startsWith('--db-path=')) {
      dbPath = arg.substring('--db-path='.length);
    } else if (arg == '--sanitize-pii') {
      sanitizePii = true;
    } else if (arg == '--no-sanitize-pii') {
      sanitizePii = false;
    } else if (arg == '--allow-writes') {
      allowWrites = true;
    } else if (arg == '--no-allow-writes') {
      allowWrites = false;
    }
  }

  // Initialize SQLite FFI backend for desktop CLI execution
  sqfliteFfiInit();

  // The MCP session holds the advisory lock, so a restore fails closed instead
  // of swapping the store out from under a reader that is mid-query.
  final lifecycle = dbPath != null
      ? StoreLifecycle.forDatabasePath(dbPath)
      : StoreLifecycle(factory: databaseFactoryFfi);
  try {
    await lifecycle.acquire(purpose: StoreLifecycle.sessionPurpose);
  } on StoreBusyException catch (e) {
    stderr.writeln(e.toString());
    exit(1);
  }

  final database = await TempoDatabase.open(path: dbPath);

  if (allowWrites) {
    final refusal = await _writeRefusal(database);
    if (refusal != null) {
      allowWrites = false;
      stderr.writeln('--allow-writes refused: $refusal');
    }
  }

  final sanitizer = PIISanitizer(enabled: sanitizePii);
  final server = TempoMcpServer(
    database: database,
    sanitizer: sanitizer,
    allowWrites: allowWrites,
  );

  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) async {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return;
          final response = await server.handleMessage(trimmed);
          if (response != null) {
            stdout.writeln(response);
          }
        },
        onDone: () async {
          await database.close();
          await lifecycle.release();
        },
      );
}

/// Why write tools must stay off, or null when they may be enabled.
///
/// Replication makes the phone the single writer: a write from this process
/// would bypass the change log and never reach the Mac. A paired peer means
/// the same store is about to be replicated.
Future<String?> _writeRefusal(TempoDatabase database) async {
  final replication = await database.getSetting('replicate_enabled');
  if (replication == 'true') {
    return 'replication is enabled, so the phone app is the only writer';
  }
  final peers = await database.db.query(
    'sqlite_master',
    columns: ['name'],
    where: "type = 'table' AND name = 'sync_peers'",
    limit: 1,
  );
  if (peers.isEmpty) return null;
  final paired = await database.db.query('sync_peers', limit: 1);
  if (paired.isNotEmpty) {
    return 'a peer is paired with this store, so the phone app is the only '
        'writer';
  }
  return null;
}
