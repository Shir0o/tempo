# Multi-Device Replication and Recovery

- **Author:** Tempo maintainers
- **Status:** Draft
- **Date:** 2026-11-05

## Overview

Tempo keeps a continuous record of the day, midnight to midnight, on an Android phone, a macOS app, and a Pixel Watch. Today those are separate stores. The phone and the Mac share no data at all, the watch mirrors only the open Lap, and the only recovery path is a manual whole-file upload to a visible Google Drive folder.

This design makes the **phone the single writer**. The Mac becomes a read replica with a durable queue of intents, the watch stays a capture node that queues timestamped actions, and both reach the phone over the home network with no cloud account. Backup becomes automatic, verified snapshots written to a folder the user chooses.

The usage pattern behind every choice: the phone is always present and never asleep; the Mac is used at home, alongside it; there is no scenario where the Mac is used alone. The watch is used anywhere and reaches the world through the phone.

## Problem Statement

**The record is split by device.** A label made on the phone during the day never reaches the Mac, and a label made on the Mac never reaches the phone. The user has to remember which device holds which part of their day, and the two histories drift.

**Recovery depends on a button nobody presses.** There is no automatic backup. The one that exists is manual, keeps a single copy, overwrites it from both devices, and is taken by copying a database file while it is open. A reinstall on Android erases everything, and the copy that would restore it may be stale or missing recent writes.

**The watch reports the wrong moment.** A watch label tapped at 14:00 while away from the phone is written when the phone reconnects, which can be hours later. The same tap can also be applied twice, because it travels over two channels and the phone keeps no record of what it has already applied.

**Nothing explains a missing day.** If replication does not happen, no screen says why. Failures are swallowed, so the first symptom is silence.

The proposed solution is a one-way change feed from the phone, a durable intent queue on the Mac and the watch, and an automatic backup to a user-chosen folder. There is no merge, because there is only one writer.

## Goals

- A label made on the phone reaches the Mac on its next pull, in under two seconds while both apps are open on the home network, using a held request rather than a poll interval.
- A label made on the Mac is queued immediately, applied by the phone at the timestamp it was tapped **if the open Lap it was authored against has not moved**, and shown as pending until the phone confirms. Otherwise it is rejected with a reason, never silently re-placed.
- The Mac's replica is row-for-row the phone's records after each exchange: same ids, spans, zones, tags, and Lap.
- A watch label is applied at the instant it was tapped, exactly once, when it is delivered. The two loss paths — a full queue and an undecodable action — are visible to the user.
- A Record applied from an intent appears in the CSV on the phone within the 1,000 ms debounce.
- Automatic backup keeps a verified local snapshot no older than five minutes while the store is dirty, promotes one to the chosen folder at least hourly and on app pause, keeps five generations, and a restore loses at most one promotion interval.
- Neither replication nor backup requires a cloud account.
- The CSV export stays byte-compatible with the Simple Time Tracker eight-column schema (`activity name, time started, time ended, comment, categories, record tags, duration, duration minutes`), including the `Contact` tag.
- Importing a Simple Time Tracker `.backup` file preserves its tags.
- Settings states, for each client, when the last exchange succeeded, its cursor, and how many changes and intents were applied, rejected, or pending.

## Non-Goals

- A second writer on any device. The Mac never authors a Record; it proposes one.
- Merging two histories, resolving conflicts, or rebuilding a Day from events.
- Cloud sync, user accounts, or any server operated by the project.
- The watch as a full store or a history browser.
- App-level encryption of the backup. Confidentiality is delegated to the destination folder.
- Encryption of the live `tempo.db`.
- Automatic restore after a reinstall. Restore is manual.
- Launch at login for the Mac app in this release. Opening the app is the trigger.
- Background sync while the phone app is closed. Replication runs while Tempo is open on the phone.
- A backup destination on the phone's own storage. It would not survive losing the device.
- A web client, calendar overlay, or sharing between people.

## Critical User Journeys

### CUJ 1: Labelling on the phone, reading on the Mac

- **Given**: the phone and the Mac are on the home network, both apps open, paired.
- **When**: the user labels the open Lap on the phone at 09:58.
- **Then**: the phone writes the Record and its change row in one transaction; the Mac's held request returns within two seconds, applies the change, and shows the same Record and Lap start. The watch's open Lap moves through the existing Data Layer path.

### CUJ 2: Labelling on the Mac

- **Given**: same conditions; the phone is in the room with Tempo open.
- **When**: the user labels the open Lap on the Mac at 10:00.
- **Then**: the Mac writes an intent carrying the tapped time, its zone, and the Lap start it saw, and shows the Record as pending. The phone applies it at 10:00 if its Lap still starts at that instant, returns `applied`, and the Mac confirms on the next pull. If the Lap moved, the phone returns `rejected` with `lap-moved`; the Mac shows the reason and offers "place at now" as a new intent.

### CUJ 3: A label on the watch with no phone nearby

- **Given**: the watch has no path to the phone; its last known Lap started at 13:00.
- **When**: the user labels "Coffee" at 14:05 on the watch.
- **Then**: the watch records the action with 14:05 and its zone, and shows the new Lap immediately. When the phone is reachable, the action is applied at 14:05 if the Lap still starts there, acknowledged, and removed from the queue. A duplicate changes nothing.

### CUJ 4: A day away from the Mac

- **Given**: the phone left the network at 10:00; the Mac stayed at home and recorded nothing.
- **When**: the user opens Tempo on the phone at home at 18:00 and the Mac pulls.
- **Then**: one paginated pull sends the day's changes, the Mac applies them in order, and the replica matches the phone. Nothing is lost.

### CUJ 5: Reinstall and restore

- **Given**: the Android app was uninstalled; its database is gone; a verified snapshot exists in the chosen folder.
- **When**: the user reinstalls, opens Settings, re-picks the destination (the old permission is gone), and selects the newest generation.
- **Then**: the app validates the file, snapshots the current empty store, closes, replaces atomically, reissues its own device id, renews the log epoch, and relaunches. Every Day, Record, change, and tag is back. The Mac detects the new epoch and replays from zero.

### CUJ 6: The phone is lost

- **Given**: the phone is gone; its last promoted snapshot is a day old; the Mac's replica holds the most recent data.
- **When**: the user installs Tempo on a replacement phone and chooses "Set up from this Mac" in Settings.
- **Then**: the Mac writes a store export from its replica; the new phone validates it, adopts the records, backfills its change log, issues a new `device_id` and `log_epoch`, and the Mac replays from zero to confirm the two match.

## Proposed Architecture

### Roles

- **Phone**: writes Records, Activities, Categories, Tags, and the Lap through `DayRecorder`. Appends one change row per mutation in the same transaction. Runs the listener and owns the backup.
- **Mac**: applies changes in order, serves the UI from the replica, and turns every mutation into an intent. Runs the client, holds a change request open, and shows pending and rejected intents.
- **Watch**: queues timestamped actions and sends them over the Data Layer. No change feed, no replica.

### Component map

```text
┌────────────────────────── Phone (Flutter) ──────────────────────────┐
│ UI ── DayRecorder ── TempoDatabase                                  │
│        │                changes, processed_intents, watch_watermarks,│
│        │                records, lap, settings, sync_peers          │
│        ├── CsvExportEngine ──► local CSV ──► Drive "Time track"     │
│        ├── BackupService ──► snapshot ──► chosen folder             │
│        ├── SyncListener (HTTP server, mDNS advertiser, long-poll)   │
│        └── WearableSyncService ── Data Layer ──► Watch             │
└──────────────────────────────▲──────────────────────────────────────┘
                               │ home LAN, Mac dials
┌──────────────────────────────┴──── Mac (Flutter) ───────────────────┐
│ UI ── RecordCommands (interface)                                    │
│        ├── RemoteCommands ──► IntentQueue ──► SyncClient            │
│        └── reads ──► TempoDatabase (replica, intents, applied_seq)  │
│ Menu bar ── same commands and reads                                 │
└─────────────────────────────────────────────────────────────────────┘
```

The **store** is `tempo.db` with its `-wal` and `-shm` files. The phone's store is authoritative. The Mac's store is a replica: the same tables for reading, plus `intents` and `applied_seq`. No Mac code path writes records directly.

### Data model (phone)

```text
changes
  seq              INTEGER PRIMARY KEY AUTOINCREMENT
  change_id        TEXT NOT NULL UNIQUE
  kind             TEXT NOT NULL
  entity_id        TEXT NOT NULL
  at_epoch_ms      INTEGER NOT NULL
  payload_json     TEXT NOT NULL

processed_intents
  log_epoch        TEXT NOT NULL
  intent_id        TEXT NOT NULL
  entity_id        TEXT NOT NULL DEFAULT ''
  applied_at_epoch_ms INTEGER NOT NULL
  result           TEXT NOT NULL        -- 'applied' | 'rejected'
  reason           TEXT NOT NULL DEFAULT ''
  PRIMARY KEY (log_epoch, intent_id)

watch_watermarks
  device_id        TEXT PRIMARY KEY
  action_seq       INTEGER NOT NULL

sync_peers
  peer_device_id   TEXT PRIMARY KEY
  store_id         TEXT NOT NULL
  host             TEXT NOT NULL
  last_seen_epoch_ms INTEGER NOT NULL
```

Settings rows and their seeded values: `store_id` = new UUID, `device_id` = new UUID, `log_epoch` = new UUID, `backup_enabled` = `false`, `backup_destination` = `''`, `backup_generations` = `5`, `export_redact_comments` = `false`, `replicate_enabled` = `false`.

`log_epoch` is a UUID renewed by restore, bootstrap adoption, or any future log truncation. A client that sees an unfamiliar value clears its cursor and replays from zero.

Pairing secrets are **not** stored in the database. They live in platform secure storage — Android Keystore-backed preferences, macOS Keychain — keyed by peer device id. `sync_peers` holds only identity and address, so snapshots never carry a credential.

### Data model (Mac, replica)

The same `records`, `activities`, `categories`, `tags`, `record_tags`, and `lap` tables, plus:

```text
intents
  intent_id        TEXT PRIMARY KEY
  kind             TEXT NOT NULL
  payload_json     TEXT NOT NULL
  tapped_at_epoch_ms INTEGER NOT NULL
  tapped_at_zone_id TEXT NOT NULL
  expected_lap_start_epoch_ms INTEGER NOT NULL
  status           TEXT NOT NULL        -- 'pending' | 'applied' | 'rejected'
  reason           TEXT NOT NULL DEFAULT ''
```

Settings: `applied_seq`, `replica_of_store_id`, `replica_log_epoch`. Secrets live in the macOS Keychain.

## Replication

### Change kinds

| Kind | Payload |
| --- | --- |
| `category_upsert` | full Category row |
| `category_remove` | category id |
| `activity_upsert` | full Activity row |
| `activity_remove` | activity id |
| `tag_upsert` | full Tag row |
| `tag_remove` | tag id |
| `record_upsert` | full Record row plus its tag ids |
| `record_remove` | record id |
| `lap_set` | start, start zone, end zone |

A change carries the whole row. Applying it is an update-then-insert keyed by the text id, inside one transaction, in the order categories, activities, tags, records, lap. `INSERT OR REPLACE` is not used: it deletes and re-inserts, which nulls `activities.category_id`, cascades `record_tags`, and reassigns the rowid that adjacency ties rely on.

`record_remove` has two producers: `undoLast`, which removes the Record it created, and `merge`, which removes the absorbed Record. The user's delete is `record_upsert` with a null Activity, because it keeps the span.

Every delete — Activity, Category, Tag, Record — goes through one helper that writes the tombstone and the change in the same transaction.

### Applying changes

1. The Mac sends `appliedSeq` and any pending intents.
2. The phone applies each intent (below) and records the result in `processed_intents`, keyed by `(log_epoch, intent_id)`.
3. The phone returns `{storeId, logEpoch, changes, intentResults, more}`, where `changes` are rows with `seq > appliedSeq` up to the limit.
4. The Mac applies them in `seq` order with update-then-insert, advances `applied_seq`, and repeats while `more` is true.
5. An unknown change kind aborts the pull without advancing the cursor and surfaces "the phone is running a newer version".
6. If `store_id` or `log_epoch` differs from the replica's, the Mac clears the replica tables and replays from `seq = 0`.

`seq` ordering is required for convergence; the whole-row payload only makes a retry idempotent.

### Intents

Kinds: `label`, `split`, `relabel`, `annotate`, `adjust_edges`, `clear`, `undo`, `merge`, `split_record`. `sameAsLast` is a `label` with the last Activity.

Every intent carries `tapped_at_epoch_ms`, `tapped_at_zone_id`, and `expected_lap_start_epoch_ms`.

The phone applies an intent inside `_synchronized`:

- If the current Lap start equals `expected_lap_start_epoch_ms`, the action runs at `tapped_at_epoch_ms` with the intent's zone, through the same rules the phone uses locally.
- If it differs, the result is `rejected` with reason `lap-moved`. The Mac offers "place at now", which creates a new intent with the current Lap start.
- An edit that overlaps a labelled Record returns `rejected` with reason `overlap` and the existing user-facing message.
- An unknown Activity returns `rejected` with reason `unknown-activity`.
- A tapped time more than ten minutes from the phone clock returns `rejected` with reason `clock-skew`.

`IntentResult` is `{status, reason, entityId, appliedAtEpochMs}`.

Undo is a compensating command, not a reversal of in-memory state: it carries the target record id (for a Mac intent) or resolves the watch's `actionId` through `processed_intents.entity_id`, then emits `record_remove` plus `lap_set` with the prior start.

The Mac shows a pending intent as an outlined Record at its tapped time, a confirmed one as solid, and a rejected one with its reason.

### Transport and pairing

- The phone runs the HTTP server on a fixed port and advertises `_tempo._tcp` over Bonjour. The Mac browses and dials.
- Pairing: the **phone displays** the QR `tempo://pair?h=<host>&p=<port>&s=<secret>&id=<storeId>`; the **Mac scans** it. The fallback for networks that block mDNS is typing host, secret, and store id, shown as text on the phone.
- Permissions: the phone needs multicast for advertising only and no camera. The Mac needs the camera usage string and the camera entitlement for scanning.
- Requests are `POST /sync` with `{deviceId, storeId, logEpoch, appliedSeq, limit, intents}` and `HMAC-SHA256(secret, timestamp || body)`. Skew beyond five minutes is refused.
- The Mac also holds `GET /changes?since=<seq>&limit=<n>` open for up to 25 seconds; the phone completes it as soon as a change exists. This is what makes the two-second goal reachable. The 30-second poll remains as a fallback when long-polling fails.
- The response carries `{storeId, logEpoch, changes, intentResults, more}`.
- Disconnect deletes the stored secret on both sides; Settings offers "revoke all paired devices"; restore rotates the secret.
- Triggers on the Mac: open, resume, after any intent, a completed long-poll, and the fallback poll.

### Watch protocol

- Each tap gets an `intent_id` and a per-watch `actionSeq`, stored with the pending action before any network call.
- The DataItem and the message carry the same id. The phone records it in `processed_intents`, so the second copy is a no-op. DataItems are not deleted: the watch re-reads them after a queue restore, and the id is the only guard that matters.
- The phone applies the action at `timestampEpochMs` if the Lap still starts there, using the same rule as an intent. A moved Lap rejects with `lap-moved` and a visible notice.
- The Lap payload carries `appliedActionSeq` and `rejectedActionIds`. The watch removes every pending action at or below the watermark, clears rejected ids, and adopts the phone's Lap. The watermark is persisted in `watch_watermarks`, keyed by the watch's device id.
- The queue holds 50 actions. At the cap the oldest is dropped and the same notice appears. An action more than ten minutes off the phone clock is rejected as `clock-skew`.

## Backup and Restore

- Only the phone writes backups. The Mac's replica is not a backup, but it can seed a replacement phone (CUJ 6).
- `BackupService.snapshot()` probes `sqlite_version()`. On 3.27 or later it runs `VACUUM INTO`; otherwise it takes the store lock, runs `PRAGMA wal_checkpoint(TRUNCATE)`, and copies.
- The expected `MAX(changes.seq)` is captured in the same read transaction that starts the snapshot; the snapshot's value is compared to that, not to the live store.
- The snapshot is hashed with SHA-256, opened read-only, and checked with `PRAGMA integrity_check`. Coverage (no gap and no overlap within any Day) is checked too, but only reported as a warning: a faithful copy of a store with a coverage defect is still a restorable backup, and refusing it would leave the record unprotected. Keeping coverage continuous is the write paths' job.
- Two tiers, each with a named failure: a **local** rolling snapshot in app support covers a corrupted live store and dies with an uninstall; a **destination** snapshot covers an erased install. The local tier is taken five minutes after a change while dirty; promotion copies the newest verified local snapshot to the destination hourly, on app pause, and before any destructive action.
- Layout: `<destination>/tempo/<store_id>/backup-<yyyyMMddTHHmmssZ>.db` plus one `<destination>/tempo/<store_id>/manifest.json` holding an ordered list of generations, each with file, hash, bytes, schema version, creation time, and verified flag. Temp files go under `<destination>/tempo/.tmp/` and are renamed into place on macOS. On SAF the copy is not atomic: the promoted file's hash is compared to the manifest before the generation is marked valid.
- Five generations, pruned by creation time after a verified write.
- Destination: macOS uses the open panel plus a security-scoped bookmark; Android uses the SAF tree picker plus a persisted URI permission. The phone's own storage is refused as a destination. Cloud detection uses the mount point on macOS and the provider authority on Android.
- Restore: validate the generation, snapshot the current store, take exclusive access, close, replace atomically, reissue `device_id`, renew `log_epoch`, and relaunch. No in-process reopen.

### Seeding and Export

`store_export` produces a versioned file: activities, categories, tags, Records with ids and both zones, and the Lap, with a hash and schema version. It does **not** carry `changes` or a cursor; the consumer backfills changes on import. Either device can produce it, so a Mac replica can seed a replacement phone and a phone can seed a bare Mac. It travels through the OS share sheet. Import refuses to overwrite a non-empty store without confirmation.

### Import

Importing a Simple Time Tracker `.backup` file preserves its tags. The parser reads tag rows, maps them to names, and the import service creates or reuses tags by case-insensitive name and links them to the imported Records. Every imported Record, Activity, Tag, and Category emits its change row in the same transaction.

## Diagnostics

Settings lists each client with the last successful exchange, `applied_seq` (Mac) or `appliedActionSeq` (watch), and counts derived from `processed_intents` and `applied_seq`: applied, rejected, pending. The Mac shows pending and rejected intents inline on the Day. There is no separate log table; the intent outcomes are the record.

## Alternatives Considered

### Alternative A: Both devices write, with a merge

- **Pros**: the Mac could label while the phone is unavailable; no single point of loss; a second Mac is free.
- **Cons**: clipping and suppression rules are the hardest part of the system and the only place where bugs are silent; every write path must emit an event or a rebuild deletes data.
- **Reason for Rejection**: the phone is always present and never asleep, and the Mac is never used alone.

### Alternative B: Shared cloud folder as the transport

- **Pros**: works when apart; no server; survives reinstall.
- **Cons**: requires an account; puts the day in a provider's hands; minutes of propagation; silent failures.
- **Reason for Rejection**: the devices are co-located whenever both are used. Kept as a backup destination.

### Alternative C: Mac as the authority

- **Pros**: ordering is trivial.
- **Cons**: the Mac is the less available device; it becomes the single point of loss.
- **Reason for Rejection**: the phone is the always-present device.

### Alternative D: Whole-database snapshot replication

- **Pros**: no change log, no schema additions.
- **Cons**: a full copy per label; no pending overlay; the same validation as a backup.
- **Reason for Rejection**: the incremental feed is little more work and avoids copying the database per tap.

### Alternative E: SQLite Session changesets

- **Pros**: official format, no custom change schema.
- **Cons**: a compile-time option with different availability on Android and the bundled FFI build.
- **Reason for Rejection**: a portability bet for no gain.

### Alternative F: A backend service

- **Pros**: push, one order, no pairing.
- **Cons**: accounts, infrastructure, an operator to trust.
- **Reason for Rejection**: out of scope by principle.

### Alternative G: Encryption with a recovery phrase

- **Pros**: confidential wherever it lands.
- **Cons**: the user must keep the phrase or lose the backup.
- **Reason for Rejection**: the destination is the boundary; the container carries a version field so encryption can be added later.

### Alternative H: A log file beside the database

- **Pros**: appendable and inspectable.
- **Cons**: commits in two places; outside the snapshot; several processes open the store.
- **Reason for Rejection**: atomicity and snapshot inclusion matter more.

## Non-Functional Requirements

### Security and privacy

- Replication runs on the local network only, authenticated by a 256-bit pairing secret in platform secure storage, over HMAC-SHA256 with a timestamp. Skew beyond five minutes is refused; replays are harmless because change and intent ids are unique.
- Traffic is plaintext on the LAN by decision. The exposure is bounded by the home network and stated in the product copy.
- Backups are plaintext in the chosen folder. Settings says so at the picker, including when the folder looks cloud-synced.
- Pairing secrets are never written into `tempo.db` or any snapshot.
- The CSV keeps its exposure: comments may contain names after the `w/` marker. The `Contact` tag and the `w/` marker are separate conventions; the redaction switch blanks comments but does not touch tags.

### Performance

- A pull carries only changes past the Mac's cursor, in batches of 500.
- Applying a change is one update-then-insert; a day of heavy labelling is a few hundred rows.
- A change row is about 200 bytes. A heavy user produces a few hundred a day, roughly 20 MB a year. The log is not compacted in this release; 500 MB is the warning threshold, after which Settings offers an export and asks before further growth.
- The two-second goal covers a held request while both apps are open.
- Snapshots run off the UI path and only while dirty.

### Rollout and rollback

- Schema v10 is additive. A v9 build refuses to open v10; downgrade is unsupported and loses post-upgrade data. The user must keep the current version or accept that loss.
- Replication stays off until the Mac is paired; disabling it leaves `changes` in place.
- Backup stays off until a destination is chosen; the Drive CSV upload is independent.
- The watch changes are backward compatible: a phone without `appliedActionSeq` never acknowledges, and the watch keeps actions pending until the queue cap.

## Risks & Mitigations

| Failure mode | Trigger | Blast radius | Mitigation | Where it is handled |
| --- | --- | --- | --- | --- |
| Missed change row | A write path forgets to append | One stale row on the Mac until the next edit | Emit inside every transaction; a test enumerates write paths | Stage 3 items; write-path coverage test |
| Intent rejected on a moved Lap | Phone labelled during the Mac's delay | The Mac label is not applied | Explicit `lap-moved` reason and "place at now" | Intent rules; CUJ 2 |
| Queue overflow | Phone unreachable for days | Oldest watch labels lost | Cap 50, drop oldest, show notice | Watch protocol |
| Replica drift | A bug in apply | Mac shows a record the phone does not | Any mismatch is repaired by replaying from zero; Settings shows the last exchange | Compose rule 6; manual matrix |
| `log_epoch` mismatch | Phone restored | Mac replays everything | Clear and replay from zero; progress shown | Replay rule |
| Lost destination permission | Reinstall or revoked folder | Backup stops silently | Settings shows the destination unreachable; re-pick required | Backup destination |
| Interrupted restore | Crash between close and rename | No usable store | Temp, fsync, rename; keep the pre-restore snapshot | Restore |
| Watch clock skew | Watch clock minutes off | Wrong tap instant | Reject beyond ten minutes; show notice | Watch protocol |
| Phone lost | Device gone | The record is lost until a restore or seed | Promoted backup, or the Mac replica as a seed | CUJ 6; seeding |
| Phone app closed | Backgrounded | Mac cannot pull or send | The Mac shows "waiting for the phone"; stated in Settings | Accepted risk |
| Changes growth | Years of use | Store and snapshot size | 500 MB warning with export; stated estimate | Performance |

### Accepted risks

- Replication runs only while Tempo is open on the phone.
- A Mac label is not authoritative until the phone receives it. If the phone is lost before that exchange, the intent is lost with the uncommitted queue.
- Backup is plaintext in the chosen folder; the destination is the boundary.
- The Mac's replica is not a backup, though it can seed a replacement.

## Additional Resources

- `.scratch/time-tracker/concepts_brief.md` — decisions and accepted risks.
- `.scratch/time-tracker/research/03-multi-device-sync-and-recovery-gaps.md` — findings with file and line evidence.
- `CONTEXT.md` — Day, Record, Lap, Edge, MidnightSplit, Tombstone.
- `PRODUCT.md` — platform roles, privacy position, offline-first commitments.

## Future Improvements

- **Background sync on Android**: a foreground service or `WorkManager` job so the Mac does not depend on the phone app being open.
- **Compaction** of `changes` at the 500 MB trigger, with a checkpoint and an epoch bump.
- **Encryption at rest**: the container version field allows a passphrase-derived key.
- **Launch at login** on the Mac.
- **A merge**, only if the Mac ever needs to write while the phone is away.

## Detailed Implementation Plan

Each stage is shippable and testable on its own. Paths are relative to the repository root. Recovery lands before the write-path surgery, so every later change is covered by a verified snapshot.

### Stage 1 — Backup, restore, and store lifecycle

#### 1. `PRODUCT.md` (Modify)

- **Type / Scope**: Product specification.
- **Proposed Changes**: State that the phone is the single writer, the Mac a replica with a queue, and the watch a capture node. Replace the Drive-as-sync claims; an account is needed only for the optional CSV destination. Remove the peer consumer's name and state the reason. Add backup-to-chosen-folder and manual restore.

#### 2. `CONTEXT.md` (Modify)

- **Type / Scope**: Domain glossary.
- **Proposed Changes**: Add **Replica**, **Intent**, **Change**, **StoreId**, **Cursor**, and **Lap ownership**. Define that a Record has exactly one authoring device, that the Mac proposes and the phone disposes, and that the Lap has one owner. Keep **Edge** and continue to forbid "Boundary", noting that it named two different things in earlier drafts.

#### 3. `README.md` (Modify)

- **Type / Scope**: User documentation.
- **Proposed Changes**: Describe pairing, the Mac as a replica, the pending-intent state, and the backup destination. Drop the consumer's name from the interoperability section.

#### 4. `lib/data/database/store_lifecycle.dart` (Create)

- **Type / Scope**: Data ownership.
- **Proposed Changes**: One holder across processes, enforced by an advisory lock file at `<databases path>/tempo.store.lock` containing `{pid, purpose, acquired_at}`. API: `acquire({purpose})`, `release()`, `assertUnlocked()`. Normal opens rely on SQLite locking; the lock is taken for `restore` and `snapshot-fallback`, and the MCP CLI takes it for its session so a restore fails closed with "store busy: restore in progress". A lock older than 60 s with a dead pid is broken.

#### 5. `lib/main.dart` (Modify)

- **Type / Scope**: App entry.
- **Proposed Changes**: Acquire the store through `StoreLifecycle`; the headless notification path does the same; start the backup scheduler. On macOS, do not construct `DayRecorder`, do not seed Activities, and do not attach the CSV exporter; open the replica and the intent queue instead.

#### 6. `bin/tempo_mcp.dart` (Modify)

- **Type / Scope**: MCP CLI.
- **Proposed Changes**: Acquire the advisory lock before opening and fail with "store busy: restore in progress". Refuse `--allow-writes` whenever replication is enabled or a peer is paired, and say why. `lib/mcp/tempo_mcp_server.dart` is unchanged because it never opens a store.

#### 7. `lib/core/backup/backup_service.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: Snapshot with `VACUUM INTO` where supported (3.27+, probed), otherwise checkpoint and copy under the lock; capture the expected `MAX(seq)` in the same read transaction; hash; verify integrity and coverage; write local then promote; read and write the one ordered manifest; prune five generations; prepare a restore by validating a generation and snapshotting the current store.

#### 8. `lib/core/backup/backup_destination.dart` (Create)

- **Type / Scope**: Platform abstraction.
- **Proposed Changes**: `pick`, `writeTemp`, `renameAtomically`, `openRead`, `list`, `delete`, and `reopen`. Rename is atomic on macOS and copy-then-delete on SAF; the implementation verifies the destination hash before marking a generation valid. Cloud detection uses the mount point on macOS and the provider authority on Android. Refuse the phone's own storage as a destination.

#### 9. `lib/core/sync/google_drive_sync_service.dart` (Modify)

- **Type / Scope**: Existing service.
- **Proposed Changes**: Remove database backup and restore; keep the CSV upload and folder handling. Callers move to `BackupService`.

#### 10. `lib/core/export/csv_export_engine.dart` (Modify)

- **Type / Scope**: Export engine.
- **Proposed Changes**: Add a redaction mode that blanks comment text, leaving the column present and quoted.

#### 11. `lib/ui/settings_view.dart` (Modify)

- **Type / Scope**: UI.
- **Proposed Changes**: Replace the Drive backup controls with the auto-backup toggle, destination picker, generation count, redaction switch, a restore action that confirms and relaunches, and a cloud-folder warning. Backup only; the Sync section belongs to Stage 5.

#### 12. `macos/Runner/Info.plist` (Modify)

- **Type / Scope**: macOS configuration.
- **Proposed Changes**: Add `NSBonjourServices` for `_tempo._tcp`, `NSLocalNetworkUsageDescription`, and `NSCameraUsageDescription` for pairing.

#### 13. `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` (Modify)

- **Type / Scope**: macOS sandbox.
- **Proposed Changes**: Add `com.apple.security.files.bookmarks.app-scope` and `com.apple.security.device.camera`. Keep network-client, user-selected read-write, network-server, and the user-selected read-write entry already present.

#### 14. `macos/Runner/AppDelegate.swift` (Modify)

- **Type / Scope**: Native host.
- **Proposed Changes**: Add MethodChannels for destination picking and bookmark resolution. No QR rendering: the Mac scans with Flutter code and the phone displays.

#### 15. `android/app/src/main/AndroidManifest.xml` (Modify)

- **Type / Scope**: Android configuration.
- **Proposed Changes**: Add `CHANGE_WIFI_MULTICAST_STATE` and `ACCESS_NETWORK_STATE` for mDNS advertising. No camera permission: the phone displays the QR and never scans.

#### 16. `android/app/src/main/kotlin/com/tempos/tracker/BackupDestinationChannel.kt` (Create)

- **Type / Scope**: Native bridge.
- **Proposed Changes**: Implement pick, create document, write bytes, copy, delete, list children, and persist the tree permission over SAF; expose the provider authority.

#### 17. `test/core/backup_service_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Snapshot with pending writes; the fallback path; the captured-seq comparison surviving a concurrent write; coverage rejecting a corrupt file; manifest ordering; pruning; a failed validation leaving the source intact; SAF promotion verified by hash.

#### 18. `test/data/store_lifecycle_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Exclusive access during restore; a second caller receiving "busy"; a swap that closes before replacing; the MCP path failing closed; a stale lock broken.

### Stage 2 — Change feed

#### 19. `lib/data/database/migrations.dart` (Modify)

- **Type / Scope**: Schema migration.
- **Proposed Changes**: Add `migrateV9ToV10`: create `changes`, `processed_intents`, `watch_watermarks`, and `sync_peers`; seed the eight settings values listed in the Technical Plan; backfill **one `record_upsert` change per existing Record** (`change_id` = new UUID, `at_epoch_ms` = the Record's `updated_at_epoch_ms`, `entity_id` = the Record id), one per Activity, Category, and Tag, and one `lap_set` for the current Lap. No existing table is altered.

#### 20. `lib/data/database/tempo_database.dart` (Modify)

- **Type / Scope**: Data access.
- **Proposed Changes**: Bump `databaseVersion` to 10. Add the same DDL and seeds to `createSchema`, so a fresh install and a migration produce the same schema. Add accessors: append change; read changes after `seq` with a limit; highest `seq`; record and look up a processed intent; read and write the watch watermark; read and write peers; the eight settings.

#### 21. `lib/data/models/sync_change.dart` (Create)

- **Type / Scope**: Domain model.
- **Proposed Changes**: Define `SyncChange` with the nine change kinds and row payloads, `SyncIntent` with the nine intent kinds, and `IntentResult {status, reason, entityId, appliedAtEpochMs}`. Versioned JSON encode and decode; unknown kinds are rejected.

#### 22. `lib/core/state/day_recorder.dart` (Modify)

- **Type / Scope**: State layer.
- **Proposed Changes**: Add `atEpochMs` and `atZoneId` to `label` and `split`, clamped to `[lap start, now]`. Append the matching change row in the same transaction for every mutation: label, sameAsLast, split, splitRecord, merge, relabel, annotate, edge correction, clear, remove, undo, and the automatic midnight split. Rewrite `relabel`, `annotate`, and `delete` to open `_db.db.transaction` and use `_updateRecordInTxn`, because they currently call accessors that open their own. Add `applyIntent(SyncIntent) -> IntentResult`, which checks `expected_lap_start_epoch_ms`, applies at the tapped time and zone, and returns a rejection reason rather than reshaping.

#### 23. `lib/core/import/stt_import_service.dart` (Modify)

- **Type / Scope**: Import service.
- **Proposed Changes**: Emit one change per imported Record, Activity, Tag, and Category inside the existing import transaction, after tag linking. Route deletes through the same helper as the UI.

#### 24. `test/core/change_log_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Append and read after `seq` with a limit; highest seq; the backfill covering every Record, Activity, Category, Tag, and the Lap, with the stated field values; processed-intent idempotence keyed by `(log_epoch, intent_id)`; the watch watermark.

#### 25. `test/core/day_recorder_test.dart` (Modify)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Timestamp and zone at the tapped instant; future clamped to now; pre-Lap clamped to the Lap start; a duplicate intent id applied once; a change row written in the same transaction; an intent rejected with `lap-moved`; an intent rejected with `overlap`; an undo by target id removing the right Record; a midnight split emitting its change.

### Stage 3 — Watch correctness

#### 26. `lib/wearable/wearable_sync_service.dart` (Modify)

- **Type / Scope**: Platform bridge.
- **Proposed Changes**: Add `actionSeq` and `deviceId` to `WatchAction` and `fromMap`; pass the timestamp and zone; return applied or rejected with the seq; read the watermark from `watch_watermarks`; add `appliedActionSeq` and `rejectedActionIds` to the Lap payload.

#### 27. `android/app/src/main/kotlin/com/tempos/tracker/MainActivity.kt` (Modify)

- **Type / Scope**: Android host.
- **Proposed Changes**: Carry `actionSeq` and `rejectedActionIds` through `syncLap`; forward `actionSeq` and the watch device id; do not delete DataItems, because the watch re-reads them after a queue restore and the intent id is the dedupe guard.

#### 28. `android/wear/src/main/kotlin/com/tempos/tracker/wear/WearLapRepository.kt` (Modify)

- **Type / Scope**: Watch state.
- **Proposed Changes**: Persist `actionSeq` and the pending set; dequeue only on the watermark; apply `rejectedActionIds` by rolling back the optimistic Lap and showing one notice; cap the queue at 50 and drop the oldest with the same notice.

#### 29. `android/wear/src/main/kotlin/com/tempos/tracker/wear/WearableSyncListenerService.kt` (Modify)

- **Type / Scope**: Watch listener.
- **Proposed Changes**: Parse `appliedActionSeq` and `rejectedActionIds` from the Lap payload and hand them to the repository.

#### 30. `android/wear/src/main/kotlin/com/tempos/tracker/wear/QuickLogActivity.kt` and `LapActionReceiver.kt` (Modify)

- **Type / Scope**: Watch entry points.
- **Proposed Changes**: Route every label, split, and undo through the repository so each action gets an id and a sequence; undo carries its `actionId`.

#### 31. `test/wearable/wearable_sync_service_test.dart` (Modify)

- **Type / Scope**: Unit test.
- **Proposed Changes**: A delayed action applied at its own time and zone; a rejection with `lap-moved`; `appliedActionSeq` in the Lap payload; a duplicate applied once; the watermark surviving a service restart.

### Stage 4 — Seeding

#### 32. `lib/core/sync/store_export.dart` (Create)

- **Type / Scope**: Serialization.
- **Proposed Changes**: Versioned export: activities, categories, tags, Records with ids and both zones, and the Lap, with a hash and schema version. No changes and no cursor; the consumer backfills.

#### 33. `lib/core/sync/bootstrap_service.dart` (Create)

- **Type / Scope**: Service.
- **Proposed Changes**: Produce the export on either device; consume it on a bare device through `StoreLifecycle`, reissuing `device_id`, renewing `log_epoch`, and backfilling changes. Transport is the OS share sheet. Refuse to overwrite a non-empty store without confirmation.

#### 34. `test/sync/bootstrap_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Round trip preserving ids, zones, tags, and the Lap; backfilled changes reproducing the store; a non-empty store refused without confirmation; the Mac seeded from the phone and the phone seeded from the Mac's replica.

### Stage 5 — LAN replication

#### 35. `lib/core/sync/discovery.dart` (Create)

- **Type / Scope**: Networking abstraction.
- **Proposed Changes**: Interface returning the phone's host, port, and store id. Implement with `bonsoir`; include a fake for tests and the manual-entry path.

#### 36. `lib/core/sync/peer_pairing.dart` (Create)

- **Type / Scope**: Security.
- **Proposed Changes**: Generate the 256-bit secret; encode and decode `tempo://pair?h=&p=&s=&id=`; persist the peer identity in `sync_peers` and the secret in platform secure storage (Keystore-backed preferences on Android, Keychain on macOS); sign requests with HMAC-SHA256 over timestamp and body; refuse skew beyond five minutes; delete the secret on both sides at disconnect; "revoke all" and rotation on restore.

#### 37. `lib/core/sync/sync_listener.dart` (Create)

- **Type / Scope**: Phone service.
- **Proposed Changes**: The phone-side server: verify the signature, apply intents through `DayRecorder`, record results, return changes past `appliedSeq` up to `limit`, and hold a `GET /changes` request open for up to 25 s, completing it on the next change. Advertise mDNS. Bound the body to 4 MB and the read timeout to 15 s.

#### 38. `lib/core/sync/sync_client.dart` (Create)

- **Type / Scope**: Mac service.
- **Proposed Changes**: Pull on open, resume, after an intent, and on a completed long-poll; fall back to a 30 s poll when long-polling fails; paginate at 500; resend unacknowledged intents; clear and replay when `store_id` or `log_epoch` changes; surface "waiting for the phone"; back off 1 s doubling to 60 s for 5 attempts.

#### 39. `lib/core/sync/replica_applier.dart` (Create)

- **Type / Scope**: Mac data layer.
- **Proposed Changes**: Apply changes in `seq` order in the entity order categories, activities, tags, records, lap, using update-then-insert keyed by text id; tags in the same transaction; advance `applied_seq`; abort without advancing on an unknown kind. No other path writes a Record.

#### 40. `lib/core/sync/intent_queue.dart` (Create)

- **Type / Scope**: Mac queue.
- **Proposed Changes**: Create and migrate the `intents` table on macOS; enqueue with tapped time, zone, and expected Lap start; order by `(tapped_at, intent_id)`; transition to applied or rejected with a reason; resend until answered; expose pending and rejected rows to the Day view.

#### 41. `lib/core/state/record_commands.dart` (Create)

- **Type / Scope**: Seam.
- **Proposed Changes**: One interface: `label`, `split`, `relabel`, `annotate`, `adjustEdges`, `clear`, `undo`, `merge`, `splitRecord`. The phone implements it with `DayRecorder`; the Mac implements it with `IntentQueue`. Every UI write path depends on the interface.

#### 42. `lib/ui/dashboard_view.dart`, `lib/ui/history_view.dart`, `lib/desktop/ui/quick_popover_view.dart`, `lib/desktop/menu_bar_service.dart` (Modify) and `lib/desktop/pairing_view.dart` (Create)

- **Type / Scope**: UI.
- **Proposed Changes**: Route mutations through `RecordCommands`; render pending intents as outlined Records, rejected ones with their reason and a "place at now" action; add the pairing flow in `pairing_view.dart` (the phone displays, the Mac scans with `mobile_scanner`), the client list, cursors, counters, and disconnect. `lib/ui/settings_view.dart` gains the Sync section here, not in Stage 1.

#### 43. `pubspec.yaml` (Modify)

- **Type / Scope**: Dependencies.
- **Proposed Changes**: Add `bonsoir` for mDNS, `qr_flutter` for the phone's display, and `mobile_scanner` for the Mac's scan. Pin resolved versions in `pubspec.lock`; state licences before landing. No other dependencies.

#### 44. `test/sync/replication_test.dart` (Create)

- **Type / Scope**: Integration test.
- **Proposed Changes**: Two in-memory stores over loopback: changes applied in order; an unknown kind aborting without advancing; a repeated pull changing nothing; an intent applied at its tapped time; `lap-moved` rejection; a rejected overlapping edit; a paginated replay of 2,000 changes; a changed `log_epoch` forcing a full replay; an intent resend after restore; a stale intent id treated as a no-op.

#### 45. `test/sync/pairing_test.dart` (Create)

- **Type / Scope**: Unit test.
- **Proposed Changes**: Payload encode and decode; signature verification; skew rejection; a wrong secret; disconnect clearing both sides; revoke-all invalidating the stored secret.

### Stage 6 — Hardening

#### 46. `.github/workflows/ci.yml` (Modify)

- **Type / Scope**: CI.
- **Proposed Changes**: Android job: checkout, Temurin 17, Flutter action, `flutter pub get`, write `android/local.properties` with `flutter.sdk`, then `./gradlew :app:compileDebugKotlin :wear:compileDebugKotlin`. macOS job: `runs-on: macos-latest`, checkout, the Flutter action, `flutter pub get`, `flutter build macos --debug`, then `codesign --verify --deep --strict build/macos/Build/Products/Debug/tempo.app`.

### Verification Plan

- **Static analysis**: `dart analyze` with no new warnings.
- **Unit and integration tests**: `flutter test` over the listed files, including the replication loopback test and the backup suite.
- **Android build**: `cd android && ./gradlew :app:compileDebugKotlin :wear:compileDebugKotlin`.
- **macOS build**: `flutter build macos --debug`, then `codesign --verify --deep --strict build/macos/Build/Products/Debug/tempo.app`.
- **Replica invariant**: after every replication test, the Mac's `records` and `lap` equal the phone's, and `applied_seq` equals the phone's highest change.
- **Write-path coverage**: a test enumerates every mutation entry point and asserts a change row was appended.
- **Manual two-device matrix**: pair once; label on each device; leave and return; label on the watch with the phone offline; reject a Mac intent after a Lap move; restore from a generation; lose the phone and seed a replacement from the Mac; confirm the CSV on the phone contains a Mac-made Record.
- **Failure checks**: wrong pairing secret, clock skew, a destination that disappears, a corrupt snapshot, a restore while the MCP server holds the store, a changed epoch forcing a full replay, and an unknown change kind aborting the pull.
