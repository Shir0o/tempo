import '../../data/database/tempo_database.dart';
import '../../data/models/sync_change.dart';

/// One row of the Mac's `intents` table: a proposed mutation waiting for the
/// phone's answer.
class QueuedIntent {
  final SyncIntent intent;

  /// `pending`, `applied`, or `rejected`.
  final String status;

  /// Why the phone rejected it, empty otherwise.
  final String reason;

  const QueuedIntent({
    required this.intent,
    required this.status,
    this.reason = '',
  });

  String get intentId => intent.intentId;

  int get tappedAtEpochMs => intent.tappedAtEpochMs;

  bool get isPending => status == IntentQueue.pendingStatus;

  bool get isApplied => status == IntentQueue.appliedStatus;

  bool get isRejected => status == IntentQueue.rejectedStatus;

  Map<String, dynamic> toRow() => {
    'intent_id': intent.intentId,
    'kind': intent.kind.wireName,
    'payload_json': intent.payloadJson,
    'tapped_at_epoch_ms': intent.tappedAtEpochMs,
    'tapped_at_zone_id': intent.tappedAtZoneId,
    'expected_lap_start_epoch_ms': intent.expectedLapStartEpochMs,
    'status': status,
    'reason': reason,
  };

  factory QueuedIntent.fromRow(Map<String, dynamic> row) => QueuedIntent(
    intent: SyncIntent.fromRow(row),
    status: row['status'] as String? ?? IntentQueue.pendingStatus,
    reason: row['reason'] as String? ?? '',
  );

  @override
  String toString() =>
      'QueuedIntent($intentId, kind: ${intent.kind.wireName}, status: $status, '
      'reason: $reason)';
}

/// The Mac's durable queue of mutations it has proposed but the phone has not
/// answered.
///
/// A pending row is resent on every exchange until it is answered, so the
/// queue needs no send state: the phone's `processed_intents` table is the
/// only guard that matters.
class IntentQueue {
  static const String table = 'intents';

  static const String pendingStatus = 'pending';
  static const String appliedStatus = 'applied';
  static const String rejectedStatus = 'rejected';

  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS intents (
    intent_id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    tapped_at_epoch_ms INTEGER NOT NULL,
    tapped_at_zone_id TEXT NOT NULL,
    expected_lap_start_epoch_ms INTEGER NOT NULL,
    status TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT ''
);
''';

  /// Column types for a table created by an earlier development build. They
  /// are added nullable: SQLite refuses a `NOT NULL` column without a default
  /// on a table that already holds rows. The constraints live in
  /// [createTableSql], which is what a fresh replica runs.
  static const Map<String, String> _columnTypes = {
    'intent_id': 'TEXT',
    'kind': 'TEXT',
    'payload_json': 'TEXT',
    'tapped_at_epoch_ms': 'INTEGER',
    'tapped_at_zone_id': 'TEXT',
    'expected_lap_start_epoch_ms': 'INTEGER',
    'status': 'TEXT',
    'reason': 'TEXT',
  };

  final TempoDatabase database;
  bool _ensured = false;

  IntentQueue(this.database);

  /// Creates the table on the Mac's replica, or adds any missing column.
  Future<void> ensureTable() async {
    if (_ensured) return;
    await _createOrMigrate();
    _ensured = true;
  }

  Future<void> _createOrMigrate() async {
    await database.db.execute(createTableSql);
    final existing = await database.db.rawQuery('PRAGMA table_info($table)');
    final present = {for (final row in existing) row['name'] as String};
    for (final entry in _columnTypes.entries) {
      if (present.contains(entry.key)) continue;
      await database.db.execute(
        'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }

  /// Queues an intent and returns it. The id is the phone's only guard against
  /// applying the same proposal twice, so it must be unique per tap.
  Future<QueuedIntent> enqueue(SyncIntent intent) async {
    await ensureTable();
    final queued = QueuedIntent(intent: intent, status: pendingStatus);
    await database.db.insert(table, queued.toRow());
    return queued;
  }

  /// Everything the phone has not answered yet, oldest tap first.
  Future<List<QueuedIntent>> pendingIntents() async {
    await ensureTable();
    final rows = await database.db.query(
      table,
      where: 'status = ?',
      whereArgs: [pendingStatus],
      orderBy: 'tapped_at_epoch_ms ASC, intent_id ASC',
    );
    return rows.map(QueuedIntent.fromRow).toList();
  }

  /// Rejected proposals, for the Day view to show with their reason.
  Future<List<QueuedIntent>> rejectedIntents() async {
    await ensureTable();
    final rows = await database.db.query(
      table,
      where: 'status = ?',
      whereArgs: [rejectedStatus],
      orderBy: 'tapped_at_epoch_ms ASC, intent_id ASC',
    );
    return rows.map(QueuedIntent.fromRow).toList();
  }

  /// Every proposal tapped between two instants, pending and answered alike,
  /// so a Day shows its pending outline and its rejections in place.
  Future<List<QueuedIntent>> between(int fromEpochMs, int toEpochMs) async {
    await ensureTable();
    final rows = await database.db.query(
      table,
      where: 'tapped_at_epoch_ms >= ? AND tapped_at_epoch_ms < ?',
      whereArgs: [fromEpochMs, toEpochMs],
      orderBy: 'tapped_at_epoch_ms ASC, intent_id ASC',
    );
    return rows.map(QueuedIntent.fromRow).toList();
  }

  Future<QueuedIntent?> byId(String intentId) async {
    await ensureTable();
    final rows = await database.db.query(
      table,
      where: 'intent_id = ?',
      whereArgs: [intentId],
      limit: 1,
    );
    return rows.isEmpty ? null : QueuedIntent.fromRow(rows.first);
  }

  /// Records the phone's answer. Only a pending row moves, so a duplicate
  /// answer never rewrites a decision.
  Future<void> markAnswered(String intentId, IntentResult result) async {
    await ensureTable();
    await database.db.update(
      table,
      {
        'status': result.isApplied ? appliedStatus : rejectedStatus,
        'reason': result.reason,
      },
      where: 'intent_id = ? AND status = ?',
      whereArgs: [intentId, pendingStatus],
    );
  }

  /// Records every answer from one exchange.
  Future<void> applyResults(Map<String, IntentResult> results) async {
    if (results.isEmpty) return;
    await ensureTable();
    for (final entry in results.entries) {
      await markAnswered(entry.key, entry.value);
    }
  }
}
