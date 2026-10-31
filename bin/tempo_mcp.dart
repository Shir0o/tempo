import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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
  --[no-]allow-writes Enable guarded mutation tools (start/stop timer, add manual records) (default: false).
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

  final database = await TempoDatabase.open(path: dbPath);
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
        },
      );
}
