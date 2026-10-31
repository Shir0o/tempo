# Local SQLite Schema and Timer State Machine

Type: grilling
Status: resolved
Blocked by: none

## Question

What is the canonical local SQLite database schema for `activities`, `records`, `tags`, and `active_timer`, and how does the timer state machine handle device sleep/suspension, system clock drift, time zone changes, and device reboots reliably?

## Answer

The complete SQLite schema and state machine specification is documented in [`.scratch/time-tracker/specs/03-local-sqlite-schema-and-state-machine.md`](../specs/03-local-sqlite-schema-and-state-machine.md).

### Resolved Decisions & Architecture:
1. **Schema Definition**: Normalized relational structure with `activities`, `tags`, `records`, `record_tags`, singleton `active_timer`, and an auxiliary `tombstones` table. Indexed for rapid range queries, date aggregations, and local MCP analytics.
2. **Clock Resiliency**: Monotonic UTC epoch arithmetic (`nowUtc - startedAt - accumulatedPause`) eliminates 1Hz polling loops, guarantees immunity to timezone crossings/DST shifts, and evaluates correctly when awakening from deep OS doze.
3. **Abrupt Shutdown Protection**: 60-second `HeartbeatCheckpoint` persists in `active_timer`. If the device dies or reboots abnormally, the app detects gaps $>6\text{h}$ and offers recovery/truncation options.
4. **Single-Active-Timer Semantics**: `SWITCH(new_activity_id)` automatically and atomically commits the current record, triggers live CSV export, and starts the new timer in a single SQLite transaction.
5. **Sync Deletion Hygiene**: Separate `tombstones` table keeps `records` clean for analytical speed while ensuring peer deletions across Android, Wear OS, and macOS are reconciled without item resurrections.
