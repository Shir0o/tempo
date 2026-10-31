# 03: Atomic Live CSV Export Engine

Status: ready
Phase: 1 - Core Engine
Dependencies: 01, 02

## Scope
Implement the atomic Write-Flush-Rename CSV export engine guaranteeing 100% Simple Time Tracker schema parity and zero-corruption reads for BNPB.

## Deliverables
- Serialized 8-column CSV generator (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`).
- Timestamp formatting in local device wall-clock time (`yyyy-MM-dd HH:mm:ss`).
- Atomic export pipeline: write to temporary sibling file `.stt_records_automatic.csv.tmp.<uuid>` $\to$ `fsync()` $\to$ POSIX atomic rename to `stt_records_automatic.csv`.
- 1,000ms trailing-edge debounce on record mutations to coalesce rapid edits.
- Unit and integration tests verifying byte-for-byte compatibility against BNPB's `TimeTrackerParser` and SHA-256 deduplication.
