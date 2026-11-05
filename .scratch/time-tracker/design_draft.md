# Multi-Device Sync and Recovery

- **Author:** Tempo maintainers
- **Status:** Draft
- **Date:** 2026-11-04

--------------------------------------------------------------------------------

## Overview

Tempo keeps a continuous record of the day, midnight to midnight, on an Android phone, a macOS app, and a Pixel Watch. Today those are separate stores. The phone and the Mac share no data at all, the watch mirrors only the open Lap, and the only recovery path is a manual whole-file upload to a visible Google Drive folder.

This design makes the phone and the Mac converge over the home network with no cloud account, keeps the watch as a capture node that timestamps its own actions, and replaces the backup with automatic, verified snapshots written to a folder the user chooses.

The usage pattern behind every choice: the Mac is used at home, next to the phone. Outside, the phone is the only store. The watch is used anywhere and reaches the world through the phone.

## The Problem

**The record is split by device.** A label made on the phone during the day never reaches the Mac, and a label made on the Mac never reaches the phone. The user has to remember which device holds which part of their day, and the two histories drift.

**Recovery depends on a button nobody presses.** There is no automatic backup. The one that exists is manual, keeps a single copy, overwrites it from both devices, and is taken by copying a database file while it is open. A reinstall on Android erases everything, and the copy that would restore it may be stale or missing recent writes.

**The watch reports the wrong moment.** A watch label tapped at 14:00 while away from the phone is written when the phone reconnects, which can be hours later. The same tap can also be applied twice, because it travels over two channels and the phone keeps no record of what it has already applied.

**Nothing explains a missing day.** If sync does not happen, no screen says why. Failures are swallowed, so the first symptom is silence.

The proposed solution is a per-device event log inside each database, exchanged over the local network, with each Day rebuilt from its own events so both devices reach the same result. Backup becomes an automatic snapshot to a user-chosen folder, and restore becomes a deliberate action.

## Goals

- A label made on one device is visible on the other while both are on the same network, in under two seconds.
- Any two devices that exchange events converge to identical Records, and replaying the same event set a second time changes nothing.
- A watch label is written at the instant it was tapped, exactly once, including when the phone was unreachable for hours.
- A Record received from the peer appears in the CSV export within the existing debounce window.
- Automatic backup keeps a verified local snapshot no older than five minutes while the store is dirty, promotes one to the chosen folder at least hourly and on app pause, keeps five generations per device, and a manual restore reproduces the store exactly.
- Sync and backup work with no cloud account. A Google Drive destination is optional, not required.
- The CSV export stays byte-compatible with the Simple Time Tracker eight-column schema, including the `Contact` tag.
- Importing a `.backup` file preserves its tags.
- Settings can state, for each peer, when the last exchange succeeded, both cursors, and how many events were applied, duplicated, rejected, clipped, or suppressed.

## Non-Goals

- Cloud sync, user accounts, or any server operated by the project.
- The watch as a full store, a history browser, or an independent sync peer.
- App-level encryption of the backup. Confidentiality is delegated to the destination folder.
- Encryption of the live `tempo.db`.
- A log file beside the database. The log lives inside it.
- Automatic restore after a reinstall. Restore is manual.
- A web client, calendar overlay, or sharing between people.
- Changing what a Day means, or how Records are labelled and edited.

## Open Questions

- **Launch-at-login**: the Mac listener only exists while the app runs. Is opening the app when you sit down sufficient, or must it start at login?
- **Minimum Android version**: the snapshot falls back to a checkpointed copy on SQLite versions without `VACUUM INTO`. Is that fallback acceptable, or should the minimum Android version be raised so every device uses one path?
- **Peer used away from home**: if the Mac is ever used outside the home network, D2 needs a second transport. Is that a possible future, or out of scope permanently?

## Critical User Journeys

### CUJ 1: Labelling at home, on either device

- **Given**: the phone and the Mac are on the same home network, both running, already paired.
- **When**: the user labels the open Lap on the Mac at 09:58.
- **Then**: the Mac writes the Record and its event in one transaction; the phone receives the event within two seconds, rebuilds that Day, shows the same Record, and moves its Lap start to 09:58. The watch's open Lap moves to the same start through the phone.

### CUJ 2: A day away from the Mac

- **Given**: the phone left the network at 10:00 with the Lap open; the Mac stayed at home and recorded nothing.
- **When**: the phone returns at 18:00 and the apps discover each other.
- **Then**: the phone sends its day of events in one exchange, the Mac rebuilds every affected Day, and both stores match. Nothing is lost; the Mac's day is the phone's day.

### CUJ 3: A label on the watch with no phone nearby

- **Given**: the watch has no path to the phone; its last known Lap started at 13:00.
- **When**: the user labels "Coffee" at 14:05 on the watch.
- **Then**: the watch records the action with 14:05 as its own timestamp and shows the new Lap immediately. When the phone is reachable, the action is delivered, applied at 14:05 rather than at delivery time, acknowledged, and removed from the watch queue. A duplicate delivery changes nothing.

### CUJ 4: Two devices disagree

- **Given**: the Mac labelled 09:00–09:58 "Breakfast" while the phone was off the network; the phone labelled 09:00–10:30 "Commute".
- **When**: the two exchange events at 18:00.
- **Then**: the earlier claim keeps 09:00–09:58; Commute is rebuilt as 09:58–10:30. Both devices show the same result, whichever synced first. The clipped event remains in the log and is counted as clipped in diagnostics.

### CUJ 5: Reinstall and restore

- **Given**: the Android app was uninstalled; its database is gone; a verified snapshot exists in the chosen folder.
- **When**: the user reinstalls, opens Settings, picks Restore, and selects the newest generation.
- **Then**: the app validates the file, closes the store, replaces it, reissues its own device id, and relaunches. The restored history is intact, and the first sync with the Mac treats the restored device as a new writer without skipping events.

## Technical Plan (Architecture)

### Component map

```text
┌────────────────────────── Phone (Flutter) ──────────────────────────┐
│ UI ── DayRecorder ── TempoDatabase (SQLite: records, lap, settings, │
│        │                sync_events, sync_cursors, tombstones)      │
│        ├── CsvExportEngine ──► local CSV ──► Drive "Time track"     │
│        ├── BackupService ──► VACUUM INTO / checkpoint copy ──► dest │
│        ├── SyncService ──► HTTP client ─────────────┐               │
│        └── WearableSyncService ── Data Layer ──► Watch             │
└────────────────────────────────────────────────────┼────────────────┘
                                                     │ home LAN
┌────────────────────────── Mac (Flutter) ────────────┼───────────────┐
│ UI / menu bar ── DayRecorder ── TempoDatabase ──────┘               │
│                    │  SyncListener (HTTP server, mDNS advertiser)   │
│                    └── BackupService ──► user-chosen folder         │
└─────────────────────────────────────────────────────────────────────┘
```

One `StoreLifecycle` owner per process owns the open database. Everything else receives it; nothing opens the file directly. The sync layer never writes rows; it calls one method on `DayRecorder`.

### Data model

Three additions to `tempo.db` (schema v10), plus configuration rows:

```text
sync_events
  seq              INTEGER PRIMARY KEY AUTOINCREMENT   -- local insertion order
  event_id         TEXT NOT NULL UNIQUE                -- uuid, or watch actionId
  device_id        TEXT NOT NULL                       -- origin install
  kind             TEXT NOT NULL                       -- closed enum below
  event_at_epoch_ms INTEGER NOT NULL                   -- when the user acted
  payload_json     TEXT NOT NULL

sync_cursors
  peer_device_id   TEXT PRIMARY KEY
  log_epoch        TEXT NOT NULL                       -- reset guard
  last_seq         INTEGER NOT NULL

sync_suppressed                      -- claims that won no time
  event_id         TEXT PRIMARY KEY
  day_start_epoch_ms INTEGER NOT NULL
  reason           TEXT NOT NULL
```

Rows in `settings` hold `store_id` (travels with the data), `device_id` (belongs to the install), and the current `log_epoch`. `store_id` is generated once when the database is created; `device_id` is reissued whenever the store is replaced by a restore or a bootstrap.

The existing `tombstones` table stays as a local index for deletion UI, but merges read `record_delete` events, not tombstones.

### Event kinds

| Kind | Payload | Emitted by |
| --- | --- | --- |
| `category_upsert` | id, name, color, icon, sort, timestamps | category create/edit/archive |
| `activity_upsert` | id, name, category id, color, icon, pinned, archived, sort, timestamps | activity create/edit/archive |
| `tag_upsert` | id, name, color, timestamps | tag create/edit |
| `record_claim` | record id, activity id, start, end, start zone, end zone, comment, tag ids, created/updated | label, and the one-time backfill of existing Records |
| `record_relabel` | record id, activity id or null, updated | relabel |
| `record_annotate` | record id, comment, tag ids, updated | comment or tag edit |
| `record_edges` | record id, new start and/or end, updated | edge correction |
| `record_delete` | record id, deleted at | delete and undo |
| `lap_moved` | start, start zone, reason | label, split, undo, edge correction |

`record_claim` carries the record id assigned once by the originating device. A record id is never regenerated, so relabel, annotate, edge, and delete can all target it. Events that arrive for an unknown record id before its claim are held in a pending set for that exchange and retried after the claim applies.

### Merge

Every exchange ends with a rebuild of each affected Day. A Day is a pure function of the events that touch it, which is what makes replay idempotent.

1. Take the union of events from the local log and the peer, deduplicated by `event_id`, for each Day touched.
2. Apply entity upserts first, ordered by `(event_at_epoch_ms, device_id, seq)`.
3. Apply claims in the same order. A claim covers `[start, end)`. It takes the part of that span not already claimed by an earlier claim in the Day, including time currently in the open Lap. If nothing remains, write a `sync_suppressed` row and no Record.
4. Split any resulting span that crosses local midnight in the zone the claim was lived in, exactly as label does today, so both devices produce the same halves.
5. Apply relabel, annotate, edge, and delete events to the claims they target, in the same order.
6. Rebuild the Day's Records, preserving each winning claim's record id, tags, notes, both zones, and timestamps.
7. Set the Lap start to the latest `lap_moved` start. It may never move backwards, and it may never move forward over time the peer did not claim; the effective floor is the last Record's end.
8. Write the Day inside one transaction, then refresh the in-memory Lap, request an export, and notify listeners.

Ordering is by the claimed span's start, not by when the tap happened, so a late-arriving earlier claim still wins its time. Wall-clock `event_at` is payload, used for display and tiebreaks, not for deciding who owns a minute.

### Apply port

```text
DayRecorder.applyRemoteEvents(List<SyncEvent> events) -> ApplyResult
  synchronized:
    begin transaction
    rebuild affected Days (steps 1-7)
    update lap row and in-memory Lap
    commit
    request debounced export
    notify record committed (watch tile refresh, notifications)
```

`ApplyResult` reports applied, duplicate, clipped, suppressed, and rejected counts for diagnostics. Exceptions roll back the whole exchange and leave the peer's cursor unchanged, so the exchange retries rather than half-applying.

### Transport and pairing

- The Mac runs an HTTP server on a fixed port and advertises `_tempo._tcp` over Bonjour. The phone browses for the service.
- Pairing is a QR code on the Mac containing the host, port, store id, and a 256-bit shared secret. The phone scans once and stores all four. The fallback for networks that block mDNS is typing the Mac's IP and the same secret, shown as text on the Mac. Six-digit codes are not used; twenty bits is not a secret.
- Every request is `POST /sync` with a body of `{deviceId, storeId, logEpoch, cursors, events}` and `HMAC-SHA256(secret, timestamp || nonce || body)`. Requests with a clock skew over five minutes or a repeated nonce are refused.
- The response carries `{ackCursor, events, deviceId, storeId, logEpoch}`.
- If the peer's `storeId` or `logEpoch` is unknown or has changed, the caller clears that peer's cursor and sends its full log for the retention window.
- Triggers: app foreground, immediately after a local commit when a connection is open, on service resolution, on network change, and a 30-second heartbeat while connected.

### Watch protocol

- Each tap gets an `actionId` and a per-watch `actionSeq`, stored with the pending action before any network call.
- The DataItem and the message carry the same action id, so the phone applies one and ignores the other.
- The phone writes the action as a `sync_events` row in the same transaction as the Record, using `actionId` as `event_id`. That single insert is both the dedupe check and the audit trail.
- The Lap payload the phone sends to the watch carries `appliedActionSeq`; the watch removes every pending action at or below it and only then adopts the phone's Lap. A refused action (unknown Activity, timestamp outside the Lap) is acknowledged as rejected, and the watch rolls its optimistic Lap back to the phone's snapshot.
- The watch queue is capped; at the cap, the oldest action is dropped and the watch shows that a label was lost rather than silently freezing.

### Backup

- `BackupService.snapshot()` probes `sqlite_version()`. On 3.27 or later it runs `VACUUM INTO` a temp path. Otherwise it takes the store lock, runs `PRAGMA wal_checkpoint(TRUNCATE)`, and copies the file.
- The snapshot is hashed with SHA-256, opened read-only, checked with `PRAGMA integrity_check`, and checked for coverage: no gap, no overlap, Records within each Day, and the log high-water mark equal to the snapshot's cursors.
- Layout: `<destination>/tempo/<deviceId>/backup-<yyyyMMddTHHmmssZ>.db` plus `manifest.json` listing each generation with file, hash, bytes, schema version, creation time, and verified flag. Temp files are written under `<destination>/tempo/.tmp/` and renamed into place.
- Cadence: a local rolling snapshot five minutes after a change while dirty, kept cheap and never uploaded on its own; promotion to the destination hourly and on app pause. Generation count defaults to five per device at the destination, pruned by creation time and only after a verified write. Promotion reuses the newest verified local snapshot rather than taking a second one.
- Destination: macOS uses the open panel plus a security-scoped bookmark; Android uses the Storage Access Framework tree picker plus a persisted URI permission. If the destination looks like a cloud-synced folder, Settings says so in plain words.
- Restore: validate the chosen generation first, snapshot the current store so a mistaken replace is recoverable, then take exclusive store access, close, replace atomically, mark the store as needing a new `device_id` and a cleared cursor set, and relaunch. No in-process reopen.

### Export ownership

The phone is the only device that uploads the CSV to the Drive `Time track` folder. The Mac writes its own local CSV for browsing but does not upload. Applying a remote event triggers the debounced export on the phone, so a Mac-made label reaches the CSV without a separate path. An opt-in Settings switch redacts comment text in the exported CSV for users who do not need comment-based workflows; the default keeps comments, because the schema's consumers read that column.

### Diagnostics

Settings gains a Sync section listing each paired peer with: last successful exchange in each direction, both cursors, and counters for sent, applied, duplicate, rejected, clipped, suppressed, and retried. A Backup section lists the destination, the last verified snapshot, its size and hash, and the generation count. A rolling local decision log keeps the last seven days of apply results, never leaves the device, and is not included in the CSV.

## Alternatives Considered

### Alternative A: Whole-database file, last writer wins

Each device uploads its `tempo.db` to a shared location and the newest upload replaces the others.

- **Pros**: almost no new code; uses the backup mechanism that already exists; no event schema, no merge.
- **Cons**: two devices used on the same day guarantee that one side's Records disappear, and not only the overlapping minutes — everything written since the other device's last upload. There is no way to tell a deliberate deletion from a device that never had the Record.
- **Reason for Rejection**: it does not converge, it destroys history, and the failure is silent.

### Alternative B: Shared cloud folder as the sync transport

Devices exchange a per-device log through Google Drive's appdata namespace, polling on focus and on a timer.

- **Pros**: works when the devices are apart; no server; survives a reinstall because the files live with the account; already has a mocked client in the test suite.
- **Cons**: requires a Google account, which the product otherwise avoids; puts the whole day in a provider's hands; adds one to five minutes of propagation and therefore minutes of conflict exposure; failures are silent because a file that has not propagated looks exactly like a file that has not changed.
- **Reason for Rejection**: the stated usage pattern puts the Mac at home with the phone, so the one advantage it buys — working while apart — is not needed. Kept as an optional backup destination and as a documented fallback transport.

### Alternative C: Mac as the sole authority

The Mac is the only writer of record. The phone sends intents and receives state.

- **Pros**: ordering is trivial because there is one writer; conflicts disappear; client code is simpler than a merge.
- **Cons**: fails whenever the Mac is asleep or left behind, which is most of the day; makes the Mac a single point of loss; and the phone must queue every action anyway, so the queue exists either way.
- **Reason for Rejection**: the Mac is the less available device, so it cannot be the authority. The design keeps only its role as the LAN listener.

### Alternative D: SQLite Session extension changesets

Use SQLite's own changeset format to ship row deltas and resolve them with a conflict callback.

- **Pros**: official format, no custom event schema, per-row conflict hook, well tested upstream.
- **Cons**: it is a compile-time option (`ENABLE_SESSION`), and availability differs between Android's system SQLite and the bundled FFI build, so the two platforms could disagree; row deltas permit overlapping Records and cannot enforce the Day invariants.
- **Reason for Rejection**: a portability bet that still leaves the actual conflict unsolved.

### Alternative E: Row-level CRDT (cr-sqlite, Automerge)

Store Records as CRDT rows and let the library converge concurrent edits.

- **Pros**: automatic convergence on field-level edits; no bespoke merge code; mature libraries exist.
- **Cons**: this domain's conflicts are interval constraints, not concurrent field writes. A CRDT converges happily to a day where two Activities claim the same hour, and the invariant still has to be repaired afterwards. Requires native builds for each platform or a model rewrite.
- **Reason for Rejection**: high cost for a problem it does not solve.

### Alternative F: Incremental clipping instead of a Day rebuild

Apply each incoming event as it arrives and clip the loser at the moment of application, which was the first draft of D1.

- **Pros**: cheaper per exchange; no need to recompute a Day; straightforward to implement in one pass.
- **Cons**: the outcome depends on what has already been clipped, so replaying the same event set produces a different store; a claim clipped to nothing leaves later edits pointing at a Record that does not exist; and arrival order leaks into the result.
- **Reason for Rejection**: it is not idempotent, so two devices can settle on different days from the same facts.

### Alternative G: A log file beside the database

Append events to `changes-<deviceId>.ndjson` on disk, as the folder transport assumed.

- **Pros**: trivially appendable; easy to inspect by hand; no schema migration.
- **Cons**: the log and the Record are written in two places, so a crash can leave one without the other; the file sits outside the backup snapshot unless separately copied; and the app already has more than one process opening the same store, so two writers can interleave lines.
- **Reason for Rejection**: atomicity with the Record and inclusion in the snapshot both matter more than human-readable logs.

### Alternative H: App-level encryption with a recovery phrase

Encrypt the backup with a key derived from a twelve-word phrase shown once at setup.

- **Pros**: the backup is confidential wherever it lands, including a compromised cloud account; the phrase is the only secret that survives a reinstall.
- **Cons**: the user must store the phrase or lose the backup; restore needs it; and it adds key handling, versioning, and recovery flows to a feature whose main job is to exist.
- **Reason for Rejection**: rejected by decision — the destination folder is the security boundary. The container carries a version field so encryption can be added later without breaking restores.

### Alternative I: A backend service

A small hosted service to order events and resolve conflicts.

- **Pros**: push instead of polling, one authoritative order, no pairing, trivial multi-device support.
- **Cons**: requires accounts, infrastructure, and trust in an operator; contradicts the product's stated position that data stays on the user's hardware with no middlemen.
- **Reason for Rejection**: out of scope by principle, not by effort.

--------------------------------------------------------------------------------

## Non-Functional Requirements

**Security and privacy**

- Sync runs on the local network only, authenticated by a 256-bit pairing secret over HMAC-SHA256 with a timestamp and nonce. Requests with more than five minutes of skew or a reused nonce are refused.
- Traffic is plaintext on the LAN by decision. The accepted exposure is bounded by the home network and stated in the product copy.
- Backups are plaintext in the chosen folder. Settings says so in plain words at the picker, including when the folder looks cloud-synced.
- Diagnostics never leave the device, and the decision log is excluded from the CSV and from the backup manifest contents.
- The CSV keeps its current exposure: comments may contain names after `w/`, and that is a condition of Simple Time Tracker compatibility.

**Performance**

- A sync exchange carries only events past the peer's cursor. A day of heavy labelling is a few hundred small events.
- A merge rebuilds only the Days touched by the exchange, not the whole history. The cost is bounded by one Day's Records.
- The two-second goal covers a co-located exchange; it excludes the time the user takes to act.
- Snapshots are taken off the UI path and only while dirty. A snapshot must not block a label.

**Rollout and rollback**

- Schema v10 is additive: new tables and settings rows only. No existing table is rewritten, so a downgrade loses the log but not the Records.
- Sync stays off until a peer is paired. Disabling it leaves `sync_events` in place, which is harmless and keeps the audit trail.
- Backup stays off until a destination is chosen; the existing manual Drive CSV upload is independent of it.
- The watch changes are backward compatible: a phone without `appliedActionSeq` simply never acknowledges, and the watch keeps its current behaviour.

**Accepted risks, recorded by decision**

- Sync is LAN-only. A Mac-side change made after the phone leaves the network is reconciled on reunion, not delivered while apart.
- Backup is plaintext in the folder the user chooses. The destination is the security boundary, and the container carries a version field so encryption can be added later.
- The Mac listener exists only while the app runs. Opening the app when you sit down at it is the trigger.


--------------------------------------------------------------------------------

### Additional Resources

- `.scratch/time-tracker/concepts_brief.md` — the decisions and the accepted risks.
- `.scratch/time-tracker/research/03-multi-device-sync-and-recovery-gaps.md` — findings with file and line evidence.
- `CONTEXT.md` — Day, Record, Lap, Edge, MidnightSplit, Tombstone definitions.
- `PRODUCT.md` — platform roles, privacy position, offline-first commitments.

### Future Improvements

- **Encryption at rest**: the backup container carries a version field so a passphrase-derived key can be added without breaking existing restores.
- **A second transport**: the event log is transport-independent, so a shared folder can be added for the case where the Mac travels.
- **Launch at login**: `SMAppService` once the app is signed and installed.
- **Watch as a store**: only if the watch ever needs history without the phone, which would mean porting the Day rules to Kotlin.
- **Compaction**: not needed while events stay in the tens of megabytes; revisit if the log passes a stated ceiling.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

The plan is ordered so each stage is shippable and testable on its own. File paths are relative to the repository root.

### Stage 0 — Documents and import fix

#### 1. `PRODUCT.md` (Modify)

- **Type / Scope**: Product specification.
- **Proposed Changes**: Replace the Drive-as-sync claims with LAN peer sync between phone and Mac; state that an account is needed only for the optional CSV destination. Remove the peer consumer's name from the interoperability section. State that the watch is a capture node. Add backup-to-chosen-folder and manual restore to the capabilities list.

#### 2. `CONTEXT.md` (Modify)

- **Type / Scope**: Domain glossary.
- **Proposed Changes**: Add **Device**, **StoreId**, **SyncEvent**, **Cursor**, and **Lap ownership** to the language. Define that a Day may be held on more than one device and that the Lap start is a fact with one owner at a time. Keep **Edge** as the term and continue to forbid "Boundary".

#### 3. `README.md` (Modify)

- **Type / Scope**: User-facing documentation.
- **Proposed Changes**: Describe the two-device setup, the pairing step, and the backup destination. Drop the consumer's name from the interoperability section while keeping the format description.

#### 4. `lib/core/import/stt_format_parser.dart` (Modify)

- **Type / Scope**: Import parser.
- **Proposed Changes**: In `_parseBackup`, recognise the tag and record-tag record kinds, map them to tag names, and attach them to `SttRawInterval.tagNames`. Mirror the CSV path's comma handling. Leave the CSV path unchanged.

#### 5. `test/core/stt_format_parser_test.dart` (Modify)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Add backup fixtures with tags, including `Contact` and a multi-tag record, asserting the parsed `tagNames`, and a fixture with no tag rows asserting an empty list.

#### 6. `test/core/stt_import_service_test.dart` (Modify)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Assert that importing a `.backup` with tags creates the tags and links them to Records, and that an existing tag is reused rather than duplicated.

### Stage 1 — Event log foundation and watch correctness

#### 7. `lib/data/database/migrations.dart` (Modify)

- **Type / Scope**: Schema migration.
- **Proposed Changes**: Add `migrateV9ToV10`: create `sync_events`, `sync_cursors`, and `sync_suppressed`; seed `settings` rows for `store_id`, `device_id`, and `log_epoch`; backfill one `record_claim` per existing Record so history can seed a peer. No existing table is altered.

#### 8. `lib/data/database/tempo_database.dart` (Modify)

- **Type / Scope**: Data access.
- **Proposed Changes**: Bump `databaseVersion` to 10, add the DDL constants, and add typed accessors: append event, read events after a cursor, deduplicate by `event_id`, read and write cursors, write and read suppressed events, and typed getters and setters for the three settings rows. Keep all writes parameterised.

#### 9. `lib/data/models/sync_event.dart` (Create)

- **Type / Scope**: Domain model.
- **Proposed Changes**: Define `SyncEvent` with id, device id, kind, event time, and typed payloads for the nine kinds. Provide JSON encode and decode with a schema version, and a closed `SyncEventKind` enum so an unknown kind is rejected rather than ignored.

#### 10. `lib/core/state/day_recorder.dart` (Modify)

- **Type / Scope**: State layer.
- **Proposed Changes**: Add an optional `atEpochMs` to `label` and `split`, clamped to `[lap start, now]`. Emit the matching event inside the existing transaction for label, split, relabel, annotate, edge correction, delete, and undo. Accept an `eventId` so a watch action can supply its own id. Add `applyRemoteEvents` and `rebuildDay` as the only write path for peer facts, inside `_synchronized`, ending with the Lap update, the export request, and the committed notification. Keep local refusal behaviour for overlaps by routing it through the shared resolver.

#### 11. `lib/core/sync/overlap_resolver.dart` (Create)

- **Type / Scope**: Pure logic.
- **Proposed Changes**: One deterministic function that, given ordered claims for a Day, returns the spans that survive, the spans that are clipped, and the claims that are suppressed. No I/O, no clock, no database. Both `adjustEdges` and `applyRemoteEvents` call it.

#### 12. `lib/wearable/wearable_sync_service.dart` (Modify)

- **Type / Scope**: Platform bridge.
- **Proposed Changes**: Pass `action.timestampEpochMs` into `label` and `split`, return an applied or rejected result instead of swallowing exceptions, include the watch's action id as the event id, and add `appliedActionSeq` to the Lap payload.

#### 13. `android/app/src/main/kotlin/com/tempos/tracker/MainActivity.kt` (Modify)

- **Type / Scope**: Android host.
- **Proposed Changes**: Carry `appliedActionSeq` through `syncLap`; after a successful apply, delete the corresponding `/tempo/actions/` DataItem so the durable item does not replay after the 90-day ledger ages out; log rejected actions rather than dropping them.

#### 14. `android/wear/src/main/kotlin/com/tempos/tracker/wear/WearLapRepository.kt` (Modify)

- **Type / Scope**: Watch state.
- **Proposed Changes**: Add a per-watch `actionSeq` and a pending set persisted in SharedPreferences; dequeue only on the phone's acknowledgement watermark; apply a rejected result by rolling the optimistic Lap back to the last phone snapshot; cap the queue and surface a dropped label instead of freezing.

#### 15. `android/wear/src/main/kotlin/com/tempos/tracker/wear/WearableSyncListenerService.kt` (Modify)

- **Type & Scope**: Watch listener.
- **Proposed Changes**: Parse `appliedActionSeq` from the Lap payload and hand it to the repository; keep the existing flush-on-connect behaviour.

#### 16. `android/wear/src/main/kotlin/com/tempos/tracker/wear/QuickLogActivity.kt` and `LapActionReceiver.kt` (Modify)

- **Type / Scope**: Watch entry points.
- **Proposed Changes**: Route every label, split, and undo through the repository so each action receives an id and a sequence, rather than constructing actions independently.

#### 17. `test/core/day_recorder_test.dart` (Modify)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Cover the timestamp applied at the tapped instant, a future timestamp clamped to now, a timestamp before the Lap start clamped to the Lap start, duplicate event ids applying once, and an event written in the same transaction as the Record.

#### 18. `test/wearable/wearable_sync_service_test.dart` (Modify)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Cover a delayed action applied at its own time, a rejected action returning a rejection rather than `true`, and `appliedActionSeq` appearing in the Lap payload.

#### 19. `test/sync/event_log_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Cover append and read-after-cursor, deduplication by event id, the backfill of existing Records, and `store_id` and `device_id` being distinct rows.

### Stage 2 — Store lifecycle, backup and restore

#### 20. `lib/data/database/store_lifecycle.dart` (Create)

- **Type / Scope**: Data layer ownership.
- **Proposed Changes**: One owner that opens the database, takes an exclusive lock file, exposes the instance, closes it, and swaps the file. Every entry point acquires through it. `restore` is only callable while nothing else holds the store.

#### 21. `lib/main.dart` (Modify)

- **Type / Scope**: App entry.
- **Proposed Changes**: Acquire the store through `StoreLifecycle`; make the headless notification entry point do the same; refuse to start seeding when a bootstrap import is pending; start the backup scheduler and the sync client or listener per platform.

#### 22. `bin/tempo_mcp.dart` and `lib/mcp/tempo_mcp_server.dart` (Modify)

- **Type / Scope**: MCP entry point.
- **Proposed Changes**: Open the store through `StoreLifecycle` and fail cleanly with a "store busy" message while a restore is in progress, rather than opening a second connection.

#### 23. `lib/core/backup/backup_service.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: Snapshot with `VACUUM INTO` when the SQLite version allows, otherwise checkpoint and copy under the store lock; hash; verify integrity and coverage; write to a temp directory and rename; read and write the per-device manifest; prune by generation count; prepare a restore by validating a chosen generation and returning a handle for the lifecycle swap.

#### 24. `lib/core/backup/backup_destination.dart` (Create)

- **Type / Scope**: Platform abstraction.
- **Proposed Changes**: Define pick, write, list, delete, and reopen operations. Provide a macOS implementation over the filesystem and a security-scoped bookmark, and an Android implementation that delegates to a MethodChannel over the Storage Access Framework. Expose a flag when the path resolves inside a known cloud-synced location.

#### 25. `lib/core/sync/google_drive_sync_service.dart` (Modify)

- **Type / Scope**: Existing service.
- **Proposed Changes**: Remove the database backup and restore methods; keep the CSV upload and folder handling. Existing callers move to `BackupService`. This is what stops the phone and the Mac from overwriting one another's snapshot.

#### 26. `lib/core/export/csv_export_engine.dart` (Modify)

- **Type / Scope**: Export engine.
- **Proposed Changes**: Add a redaction mode that blanks comment text when the toggle is on, leaving the column present and quoted so the header and column count stay unchanged. Apply it after the existing time and tag formatting so durations and zones are untouched.

#### 27. `lib/ui/settings_view.dart` (Modify)

- **Type / Scope**: UI.
- **Proposed Changes**: Replace the Drive backup controls with an auto-backup toggle, a destination picker, a generation count, an export comment-redaction switch, a restore action that requires confirmation and relaunches, and a plain-language warning when the destination looks cloud-synced. Add a Sync section: pair a device, list peers, show last exchange and cursors, show counters, and offer a disconnect that clears the peer cursor.

#### 28. `macos/Runner/Info.plist` (Modify)

- **Type / Scope**: macOS configuration.
- **Proposed Changes**: Add `NSBonjourServices` for `_tempo._tcp` and `NSLocalNetworkUsageDescription`, so discovery prompts once and is permitted.

#### 29. `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` (Modify)

- **Type / Scope**: macOS sandbox.
- **Proposed Changes**: Add `com.apple.security.files.bookmarks.app-scope` so the chosen backup folder survives a relaunch. Keep the network-server and user-selected read-write entries already added.

#### 30. `macos/Runner/AppDelegate.swift` (Modify)

- **Type / Scope**: Native host.
- **Proposed Changes**: Add a MethodChannel for destination picking and bookmark resolution, and a second channel for the QR pairing payload display. Keep the existing status-item behaviour.

#### 31. `android/app/src/main/AndroidManifest.xml` (Modify)

- **Type / Scope**: Android configuration.
- **Proposed Changes**: Add `CHANGE_WIFI_MULTICAST_STATE` and `ACCESS_NETWORK_STATE` so mDNS and the multicast lock work with the screen off.

#### 32. `android/app/src/main/kotlin/com/tempos/tracker/BackupDestinationChannel.kt` (Create)

- **Type / Scope**: Native bridge.
- **Proposed Changes**: Implement pick, create document, write bytes, list children, delete, and persist the tree permission over the Storage Access Framework. Return stable handles rather than filesystem paths.

#### 33. `test/core/backup_service_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Cover snapshot with pending writes, the fallback path when `VACUUM INTO` is unavailable, integrity and coverage checks rejecting a corrupt file, manifest ordering, pruning after a verified write, and a restore that leaves the source intact when validation fails.

#### 34. `test/data/store_lifecycle_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Cover exclusive access, a second caller receiving "busy", a swap that closes before replacing, and a notification entry point failing closed during a restore.

### Stage 3 — Bootstrap seed

#### 35. `lib/core/sync/store_export.dart` (Create)

- **Type / Scope**: Serialization.
- **Proposed Changes**: Define the versioned store export: categories, activities, tags, Records with ids and both zones, `is_midnight_split`, tombstones, `sync_events`, and cursors. Include a hash and a schema version. This is not the CSV and not the STT backup format.

#### 36. `lib/core/sync/bootstrap_service.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: Produce the export on the phone; validate and adopt it on the Mac by writing the store, issuing a new `device_id`, and resetting cursors. Adoption goes through `StoreLifecycle` like a restore. Refuse to adopt into a non-empty store without an explicit confirmation.

#### 37. `test/sync/bootstrap_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Cover a round trip preserving ids, both zones, tags, and the Lap; a Mac with existing Records refusing silent adoption; and the new `device_id` and cleared cursors after adoption.

### Stage 4 — LAN sync

#### 38. `lib/core/sync/discovery.dart` (Create)

- **Type / Scope**: Networking abstraction.
- **Proposed Changes**: Define a discovery interface that returns peers with host, port, and store id. Provide an mDNS implementation and a fake for tests. Include the manual IP entry path.

#### 39. `lib/core/sync/peer_pairing.dart` (Create)

- **Type / Scope**: Security.
- **Proposed Changes**: Generate the 256-bit secret, encode and decode the QR payload, persist the peer record, sign requests with HMAC-SHA256 over timestamp, nonce, and body, and reject skew or replayed nonces.

#### 40. `lib/core/sync/sync_listener.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: The Mac-side HTTP server: validate the signature, hand the body to the apply port, reply with the peer's tail and the new cursor, and advertise the mDNS service. Bound request size and timeout.

#### 41. `lib/core/sync/sync_service.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: The phone-side client: triggers on foreground, post-commit, service resolution, network change, and a 30-second heartbeat; retry with backoff; clear a peer cursor when `storeId` or `logEpoch` changes; write counters for diagnostics.

#### 42. `lib/core/sync/merge_engine.dart` (Create)

- **Type / Scope**: Pure logic.
- **Proposed Changes**: Build the ordered event set for a Day, apply entity upserts, run the overlap resolver, split at midnight using the claim's own zones, apply later edits, rebuild Records preserving ids, and compute the Lap. No I/O. The output is a list of Records plus suppressed ids.

#### 43. `lib/ui/settings_view.dart` (Modify)

- **Type / Scope**: UI.
- **Proposed Changes**: Add the pairing flow (show a QR on the Mac, scan on the phone), the peer list, and the sync counters. Reuse the Sync section added in Stage 2.

#### 44. `pubspec.yaml` (Modify)

- **Type / Scope**: Dependencies.
- **Proposed Changes**: Add an mDNS package and a QR render and scan package. Pin versions; no other dependencies.

#### 45. `test/sync/merge_engine_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Property test that any two interleavings of the same event set produce identical Records and identical CSV output. Cases: the 09:00 Breakfast versus 09:58 Commute overlap, a claim clipped to zero, a 23-hour day, a 25-hour day, a six-hour zone-crossing flight, a relabel of a suppressed claim, and a delete followed by an earlier claim arriving late.

#### 46. `test/sync/transport_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Two in-memory stores over a loopback HTTP server and a fake discovery: convergence in both directions, cursor advance, replay changing nothing, a rejected signature, a stale nonce, and a `logEpoch` change forcing a full replay.

#### 47. `test/sync/pairing_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Cover QR encode and decode, signature verification, skew rejection, nonce replay rejection, and a wrong secret.

### Stage 5 — Hardening

#### 48. `.github/workflows/ci.yml` (Modify)

- **Type / Scope**: CI.
- **Proposed Changes**: Add two jobs on pull requests: `./gradlew :app:compileDebugKotlin :wear:compileDebugKotlin`, and a macOS build followed by `codesign --verify --deep --strict` on the bundle. Keep the existing analyse and test job.

#### 49. `macos/Runner/AppDelegate.swift` (Modify)

- **Type / Scope**: Native host.
- **Proposed Changes**: Only if launch-at-login is in scope: register and unregister via `SMAppService`, behind a Settings toggle. If it is not in scope, no change and the item stays in Non-Goals.

#### 50. `android/app/build.gradle.kts` (Modify, conditional)

- **Type / Scope**: Build configuration.
- **Proposed Changes**: Only if the fallback snapshot path is rejected: raise `minSdk` so every device has `VACUUM INTO`. Otherwise no change.

### Verification Plan

- **Static analysis**: `dart analyze` with no new warnings.
- **Unit and integration tests**: `flutter test` over the listed files, including the merge property test, the transport loopback test, and the backup suite.
- **Android build**: `cd android && ./gradlew :app:compileDebugKotlin :wear:compileDebugKotlin`.
- **macOS build**: `flutter build macos --debug`, then `codesign --verify --deep --strict` on the bundle.
- **Convergence invariant**: for every merge test, assert no gap and no overlap within each Day, and identical output in both sync directions.
- **Manual two-device matrix**: pair once; label on each side while co-located; carry the phone away for a day and return; label on the watch with the phone offline; delete and relabel from the peer; restore from a generation; verify the CSV on the phone contains a Mac-made Record.
- **Failure checks**: wrong pairing secret, replayed nonce, clock skew, a destination that disappears, a corrupt snapshot, and a restore attempted while the MCP server holds the store.

