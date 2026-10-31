# 01: SQLite Storage and Schema Migrations

Status: ready
Phase: 1 - Core Engine
Dependencies: none

## Scope
Implement the local SQLite database layer using `sqflite` (or `sqlite3` package) adhering to `specs/03-local-sqlite-schema-and-state-machine.md`.

## Deliverables
- Tables: `activities`, `tags`, `records`, `record_tags`, `active_timer`, and `tombstones`.
- DDL initialization scripts with proper foreign keys and CASCADE rules.
- Indexes on `records(started_at_epoch_ms)`, `records(activity_id)`, and `tombstones(deleted_at_epoch_ms)`.
- Unit tests validating CRUD operations, foreign key cascades, and tombstone insertions upon deletion.
