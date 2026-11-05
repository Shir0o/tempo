# Tempo Multi-Device Sync and Recovery

- **Author**: Tempo maintainers
- **Date**: 2026-11-04
- **Status**: Finalized 2026-11-04 after a six-lens Goldfish review. D2 and D6a are kept as accepted risks by decision; launch-at-login is deferred to the draft.
- **Evidence base**: `.scratch/time-tracker/research/03-multi-device-sync-and-recovery-gaps.md`

## Overview

Tempo records the whole day, midnight to midnight, on Android, macOS, and a Pixel Watch. Today the phone and the Mac are separate SQLite stores with no path between them, and the watch mirrors only the open Lap over the Wear Data Layer. Recovery is a manual whole-file upload to a visible Google Drive folder.

This proposal makes the phone and the Mac converge over the home LAN with no cloud account; keeps the watch as a timestamped, deduplicated capture node; and replaces the backup with automatic, verified, multi-generation snapshots written to a folder the user chooses.

The usage model that drives every choice: the Mac is used at home, alongside the phone. Outside, the phone is the only store. The watch works anywhere and always reaches the phone.

## Analysis

The first draft described a good shape with an underspecified core. Six lenses converged on the same three weaknesses, plus a set of concrete platform gaps.

**The merge was not convergent.** "Earliest claim wins, ordered by event time" left two things undefined: whether "claim" means when the tap happened or the span it covers, and what happens to a claim that is clipped to nothing. Clipping was described as a write onto already-derived Records, so replaying the same event against an already-clipped store produced a different result. That contradicts the claim that replay is idempotent, and it makes the outcome depend on arrival order — the exact problem the rule existed to remove. **Correction**: the event log is the source of truth and a Day is rebuilt from its ordered events (D1). Ordering is by the claimed span's start, then device id, then sequence; wall-clock event time is payload, not ordering.

**The log had no home and no schema.** The draft said "a per-device log, one writer per file, no locks" — language left over from the folder transport that D2 removed. It never said whether the log is a file or a table, and a sidecar file would sit outside the backup snapshot and outside the transaction that writes the Record. The event types also could not carry Activities, Categories, or Tags, and `records.activity_id` is a foreign key, so a Record from the peer would abort on apply. **Correction**: the log is two tables in `tempo.db`, written in the same transaction as the Record, with entity upserts in the event set (D12).

**Nothing owned the apply.** A sync applier writing rows directly would bypass the per-instance lock, the in-memory Lap cache, the undo snapshot, the midnight timer, and the export trigger — all five at once. **Correction**: one apply port on `DayRecorder`, inside the existing lock and one transaction (D13). Sync code holds no write handle.

Beyond those, the reviews found: the open Lap is moved by undo and edge edits with no event, so it cannot be derived from the last Record's end (D14); local edits refuse an overlap while remote edits silently clip it, giving two policies for one question (D15); a restored or seeded store inherits the source's device id and cursors, so two live stores share one writer identity (D16); bootstrap was named in one sentence and had no artifact, and neither the CSV nor the `.backup` format can carry ids, zones, or tags (D17); `VACUUM INTO` does not exist on Android below API 29, which is where the only-copy backup would be needed (D18); restore has at least four database openers and cannot close them all (D19); the app has no diagnostics to explain a missing day (D20); the LAN needs Info.plist and manifest declarations that do not exist, and a six-digit code is about twenty bits of entropy (D21); and a Record applied from the peer never reaches the CSV (D22).

## Goals vs Non-Goals

**In scope**

- Phone and Mac converge over the home LAN; no cloud account, no server.
- A deterministic merge with no conflict screen, where the event log is the source of truth for a Day.
- Watch actions applied at the instant they were tapped, exactly once, with an acknowledgement.
- Automatic backup to a user-chosen folder: verified snapshot, generations, manual restore.
- The CSV export stays byte-compatible with Simple Time Tracker, without naming the consumer in product copy.
- `.backup` import preserves tags.
- Enough sync diagnostics in Settings to explain a missing or duplicated day.

**Out of scope**

- Cloud sync, accounts, any server.
- The watch as a full store or a history browser.
- App-level encryption of the backup; confidentiality is delegated to the destination.
- Encrypting the live `tempo.db`.
- A sidecar log file. The log lives in the database.
- A web client, calendar overlay, or multi-user sharing.
- Automatic restore after reinstall.

## Alternatives Weighed

- **Whole-database file, last writer wins.** Smallest effort, loses a full day whenever devices alternate. Rejected.
- **Shared cloud folder (Drive appdata).** Works when apart, but adds an account, puts the day in a provider's hands, adds minutes of conflict exposure, and fails silently. Rejected for sync; retained as a backup destination.
- **Mac as the sole authority.** Simple ordering, but fails whenever the Mac is asleep and makes it a single point of loss. Kept only in the narrow sense that the Mac is the LAN listener; both sides remain full stores.
- **SQLite session changesets.** Official row deltas with a conflict callback, but a compile-time option whose availability differs between Android's system SQLite and the bundled FFI build, and row deltas still permit overlapping Records.
- **CRDT (cr-sqlite, Automerge).** Converges field edits but not interval constraints; high build cost for no gain on the actual conflict.
- **Backend.** Would solve everything, violates the no-account principle.
- **Encryption with a recovery phrase.** Rejected by decision; see the dissent at the end.

## Key Decisions

- **D1 — Merge.** The event log is the source of truth for a Day. On merge, each affected Day is rebuilt from that Day's ordered events. Ordering is by the claimed span's `started_at_epoch_ms`, then device id, then sequence. A later claim takes only time still unclaimed within the Day, including the open Lap. A claim that takes nothing stays in the log as a suppressed event and is not silently dropped. Records are a projection, so replay is idempotent and both devices converge.
- **D1a — Loss scope.** Accepted loss covers reinstall only. Devices must converge.
- **D2 — Transport.** Sync is LAN-only: the Mac listens, the phone dials, no cloud account. See the dissent.
- **D3 — Watch role.** A durable capture node: timestamped actions, deduplicated by a per-watch sequence, acknowledged with a watermark, applied in `(timestamp, actionId)` order.
- **D5 — Restore.** No automatic restore. Recovery is automatic backup plus a manual Restore action.
- **D6/D6a — Confidentiality.** No app-level encryption; the destination folder is the boundary.
- **D7 — Backup configuration.** Auto-backup toggle plus a chosen destination folder.
- **D8 — Export exposure.** Accept the plaintext CSV as a compatibility requirement; add an opt-in comment-redaction toggle.
- **D9 — Device roles.** macOS is a home companion, Android the mobile node, the watch reaches the world through the phone.
- **D10 — Naming.** Do not name the peer consumer in product copy.
- **D11 — First pairing.** The phone seeds; the Mac starts empty.
- **D12 — Log storage and schema.** `sync_events(seq, event_id, device_id, kind, event_at_epoch_ms, payload_json)` and `sync_cursors(peer_device_id, log_epoch, last_seq)` live in `tempo.db`, written in the same transaction as the Record. Event kinds include `activity_upsert`, `category_upsert`, `tag_upsert`, `record_claim`, `record_relabel`, `record_edges`, `record_delete`, `lap_moved`, and watch actions. Device id is a row in the existing `settings` table.
- **D13 — Apply port.** `DayRecorder.applyRemoteEvents(...)` runs inside the existing `_synchronized` lock and one transaction, re-reads the Lap inside it, and ends with `_updateLap`, `_requestExport`, and `_notifyRecordCommitted`. `core/sync` depends on that interface and holds no `TempoDatabase` write reference.
- **D14 — Open Lap.** The Lap start is a synced fact emitted as `lap_moved` by label, split, undo, and edge edits. A peer may never move it backwards, nor forward over time the peer did not claim. It is not derived from the last Record's end.
- **D15 — One overlap policy.** A single deterministic resolver serves both local `adjustEdges` (which turns a would-be clip into the existing refusal) and remote apply, so the same overlap is classified identically whatever path it arrives by.
- **D16 — Identity.** `store_id` travels with the data; `device_id` belongs to the install and is reissued on restore. Cursors clear on identity change, and each log carries a `log_epoch` so a peer replays from zero after a restore instead of skipping by sequence.
- **D17 — Bootstrap.** A one-shot, versioned store export: activities, categories, tags, Records with ids and both zones, tombstones, the event log, and cursors. It is not the CSV and not the `.backup` format.
- **D18 — Snapshot capability.** Probe the SQLite version; use `VACUUM INTO` where available and a checkpointed copy taken under the store lock where it is not. Verify with coverage invariants (no gap, no overlap, cursor high-water mark matches) rather than `integrity_check` alone.
- **D19 — Store lifecycle.** One owner in `lib/data/database/` opens, closes, and swaps the store. Every entry point (app, notification action, MCP CLI) acquires through it. Restore takes exclusive access, validates, replaces atomically, and relaunches; there is no in-process reopen path.
- **D20 — Diagnostics.** Settings shows peer state, last successful exchange in each direction, both cursors, and counters for sent, applied, duplicate, rejected, clipped, and suppressed. A rolling local decision log is kept for about a week.
- **D21 — LAN declarations and pairing.** macOS gets `NSBonjourServices` and `NSLocalNetworkUsageDescription`; Android gets `CHANGE_WIFI_MULTICAST_STATE`. Pairing uses a QR code or a PAKE, because six digits is about twenty bits. A manual IP connect exists for routers that block mDNS.
- **D22 — Export ownership.** The phone is the only publisher of the CSV. Applying a remote event still triggers the export on whichever device owns it.

Defaults unless challenged: snapshot every 5 minutes while dirty and on app pause, promoted to the destination hourly; keep 5 verified generations per device; per-device filenames under a per-device manifest; random UUID device id; 90-day decision-log retention.

## Dissent recorded and accepted

- **D2, LAN-only.** One reviewer argues this is a product bet dressed as an architectural consequence: a MacBook is portable, and a hotel or café changes the answer. The stated pattern (Mac at home, phone outside) supports LAN, and the log format is transport-independent, so a folder transport can be added later without a rewrite. **Accepted risk: Mac-side changes made after the phone leaves the network stay invisible until reunion.**
- **D6a, no encryption.** One reviewer argues that "the destination is the boundary" contradicts the product's data-sovereignty claim, and that the snapshot concentrates the whole history, including the `w/` names the sanitizer exists to protect, into one plaintext file. **Accepted risk, kept by decision.** The backup container gets a version field so encryption can be added later without breaking restores; no payload sealing is in scope now.
- **Launch-at-login, deferred.** The listener exists only while the Mac app runs. The working assumption for the draft is that this is acceptable: the Mac is opened when you sit down at it, and the phone syncs then. `SMAppService` registration needs a signed, installed bundle, so it belongs with release hardening if it is wanted at all.

## Staging

0. **Documents and import fix** — amend `PRODUCT.md` and `CONTEXT.md` for LAN sync and Lap ownership, replace "Boundary" with "Edge", and accept tags in the `.backup` importer.
1. **Watch correctness** — the watch action writes a `sync_events` row from the start, so the dedupe ledger and the future log are the same table; apply its own timestamp; acknowledge with a watermark.
2. **Backup** — store lifecycle, capability-probed snapshot, destination picker with bookmark entitlement, generations, restart-based restore, minimal diagnostics.
3. **Seed** — the bootstrap export and its import, so the Mac shows the phone's history before any live sync exists.
4. **LAN sync** — mDNS and manual connect, QR pairing, delta endpoint, cursors and `log_epoch`, Day rebuild, Lap events.
5. **Hardening** — launch-at-login decision, signing and notarization, CI jobs for Kotlin and macOS builds, the two-device manual matrix.
