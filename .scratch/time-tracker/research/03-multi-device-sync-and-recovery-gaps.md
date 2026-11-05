# Gap Analysis: Multi-Device Sync and Reinstall Recovery

- **Status**: Note, not a spec. Findings are verified against the current tree; decisions are open. **Post-Goldfish corrections live in `.scratch/time-tracker/concepts_brief.md`; where the two disagree, the brief wins.**
- **Date**: 2026-11-04
- **Scope**: Android ↔ macOS ↔ Pixel Watch as independent nodes, plus first-launch recovery after an app reinstall.
- **Out of scope**: calendar overlay, legacy STT SQLite migration, any server or account backend.

## What exists today

| Path | Behavior |
| --- | --- |
| Phone → watch | `lib/wearable/wearable_sync_service.dart` → MethodChannel `com.tempos.tracker/wearable` → `MainActivity.kt` writes DataItems `/tempo/lap` (urgent) and `/tempo/activities` (batched). Watch stores both in SharedPreferences. |
| Watch → phone | `WearLapRepository.dispatchAction` writes `/tempo/actions/{uuid}` urgently and also sends `/tempo/action` over MessageClient. Phone forwards to Dart and applies the action. |
| Phone/Mac → Drive | `GoogleDriveSyncService`: CSV to `Time track/stt_records_automatic.csv` after each export; whole `tempo.db` to `Time track/tempo_backup.db` on a manual button. |
| Drive → device | Manual restore only: download `tempo_backup.db` and overwrite the live local file. |
| Phone ↔ Mac | Nothing. Two independent SQLite files, no shared identifiers, no delta transport. |

## Findings

### F1 — No phone ↔ Mac sync path (blocker)

There is no transport, no merge, and no shared change log between the two Flutter instances. Drive carries a CSV and a whole-database snapshot; both are one-way artifacts, not state exchange. Logging on the phone and continuing on the Mac is impossible today.

### F2 — Whole-file snapshot upload is lossy under two writers (blocker)

`backupDatabaseToDrive` replaces a single `tempo_backup.db` (`lib/core/sync/google_drive_sync_service.dart:181-233`). Two devices uploading produce last-writer-wins on the entire database. Any sync built on this shape will silently erase another device's Records. Verification: restore unconditionally overwrites the target file with no merge (`:236-276`).

### F3 — No change log, origin, or idempotency (blocker)

`records` carries `updated_at_epoch_ms`, and `tombstones` is written on delete, edit, and undo (`lib/core/state/day_recorder.dart:323, 436, 488`), but nothing reads tombstones and no delta stream exists. There is no device id column on any table, so a merge cannot tell "deleted here" from "never existed there". Watch actions carry an `actionId` that the phone never records, so replays are not detectable.

### F4 — The world assumes exactly one open Lap (domain change)

`CONTEXT.md` states every moment belongs to one Record or *the* open Lap. Three independent writers can each hold an open Lap whose starts disagree. There is no rule for which boundary survives a merge, and no channel for a Mac Boundary edit to reach the phone or watch.

### F5 — Watch action timestamps are discarded (correctness)

`_executeWatchAction` calls `dayRecorder.label(activityId)` with no timestamp (`lib/wearable/wearable_sync_service.dart:202-225`), and `label()` accepts none (`lib/core/state/day_recorder.dart:99-105`). A label tapped at 14:00 while out of range is written at reconnect time. This defeats the purpose of the offline queue.

### F6 — Watch actions can be applied twice (correctness)

The same tap travels as a DataItem and a MessageClient message (`WearLapRepository.kt:255-290`); both arrive at `MainActivity.onDataChanged` / `onMessageReceived` (`MainActivity.kt:245-278`). The phone has no dedupe ledger, so a duplicate `LABEL` runs twice. The offline flush re-sends entries, widening the window.

### F7 — Watch Lap state can be rewound by a stale snapshot (correctness)

`WearLapRepository.updateFromPhone` applies whatever arrives and never compares `revision` or `updatedAtEpochMs`. The watch also restores its own prior Lap on undo with no grace-window check on the phone side.

### F8 — The watch cannot be an independent store (architecture)

It has no Record table, no history, and no Dart `DayRecorder`. It holds a Lap anchor, an Activity list, and an action queue. Making it a full peer means reimplementing coverage, MidnightSplit, and Boundary rules in Kotlin. Making it a durable capture node is three fixes (F5, F6, plus ack-before-dequeue) and no model duplication.

### F9 — Backup copies a live database (data loss)

`backupDatabaseToDrive` reads `tempo.db` while sqflite holds it open, with no checkpoint, no `VACUUM INTO`, and no integrity check. Recent WAL frames may be absent from the copy.

### F10 — Restore replaces the file under an open connection (data loss)

`restoreDatabaseFromDrive` writes over the live file, and the Settings handler only shows a status line (`lib/ui/settings_view.dart:160-205`). There is no close, no reopen, and no restart, so the running app can keep serving the old page cache.

### F11 — Reinstall recovery does not exist (blocker for the stated goal)

Nothing restores on first launch. The user must sign in and press Restore, from a backup that only exists if they pressed Backup. Android uninstall wipes `tempo.db`; macOS keeps Application Support, so only Android loses data. Both scopes are already requested (`google_drive_sync_service.dart:24-27`) but `drive.appdata` is unused, and the "Time track" folder is user-visible and single-slot.

### F12 — No trust model for clocks or ordering

Merge ordering would rest on each device's wall clock, and watch event times are already being replaced by phone-now (F5). Event time must come from the observing device and never be rewritten; conflicting edits need a tiebreak that is not raw skew.

### F13 — The backup and the export are plaintext in a visible Drive folder (security)

`tempo_backup.db` and `stt_records_automatic.csv` both land in the root-level, user-visible `Time track` folder (`lib/core/sync/google_drive_sync_service.dart:20-22, 181-233`). The database contains comments, `w/` contact markers, zones, and full day history in the clear. Google's at-rest encryption does not protect against a compromised account, a shared machine, or any process holding the user's Drive grant. The CSV cannot be encrypted without breaking the BNPB contract; the database snapshot can and should be.

Key custody is the unresolved part. Auto-backup, restore after uninstall, and a key that never reaches the cloud cannot all hold at once: a key held only in the Android Keystore is destroyed by uninstall, which makes the encrypted backup unreadable in exactly the case D5 relies on; a key stored beside the backup in Drive gives no protection against a Drive breach. Only a secret the user holds (passphrase or recovery phrase) survives both. The local `tempo.db` is also unencrypted today, so a stolen laptop exposes the same data without touching Drive.

### F14 — The `.backup` importer drops tags (data)

The CSV importer reads the `record tags` column, splits on commas, and creates tags, so `"Contact"` already survives (`lib/core/import/stt_format_parser.dart:408-418`, covered by tests). The tab-delimited `.backup` importer handles `category`, `typeCategory`, `recordType`, and `record`, and never reads a tag kind or sets `tagNames` (`:205-278`). Any tags in a backup file are lost on import.

### F15 — Release entitlements cannot listen on the LAN (resolved 2026-11-04)

`macos/Runner/DebugProfile.entitlements` granted `com.apple.security.network.server`; `macos/Runner/Release.entitlements` did not. A release build therefore could not bind the listener the LAN design depends on, silently. **Resolved**: `network.server` added to `Release.entitlements`, verified present on the built bundle.

### F16 — Neither entitlements file can write to a user-picked folder (partly resolved 2026-11-04)

The sandbox is on in both configurations, and neither requested `com.apple.security.files.user-selected.read-write`. **Resolved for the current launch**: the entitlement is now in both files. Still missing for R6: `com.apple.security.files.bookmarks.app-scope`, which is what lets the app reopen the chosen folder after a relaunch without asking again.

### F17 — The macOS build cannot complete as configured (resolved 2026-11-04)

`flutter build macos --debug` failed with `"Runner" has entitlements that require signing with a development certificate`, because both files requested `keychain-access-groups` = `$(AppIdentifierPrefix)com.google.GIDSignIn` while the project signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`). **Resolved**: the block is removed from both files. Debug and Release both build, `codesign --verify --deep --strict` passes, and the Release bundle launches. Remaining risk: macOS Google Sign-In has not been exercised since the change; it should be signed in once manually. If it fails, the alternative is to enable Keychain Sharing for the App ID and sign with team `6BT38LL46U`.

## Workstreams to resolve the findings

- **A. Multi-writer store (F1-F4, F12)**: device identity, per-device append-only change log with tombstones, idempotency keys, merge rules, and a Boundary edit that propagates as an event rather than a state push.
- **B. Lap ownership (F4)**: which device holds the open Lap after a merge, and what happens to the other device's open span. This is a `CONTEXT.md` change.
- **C. Watch as capture node (F5-F8)**: apply the action's own timestamp, dedupe by `actionId`, dequeue only on acknowledgment.
- **D. Recovery (F9-F11)**: user-chosen destination, safe snapshot (`VACUUM INTO` plus hash), multiple generations, close-and-reopen on restore, and manual restore into an empty store. No automatic restore (D5).
- **E. Confidentiality (F13)**: split the plaintext interop export (`Time track`, BNPB contract) from the private encrypted snapshot (`drive.appdata`), pick the AEAD container, and settle key custody.

## Remediation plan (independent of the sync design)

These six changes do not depend on D1. They are ordered by risk and by what they touch.

### R1 — Apply the watch action's own timestamp (F5)

- `DayRecorder.label(activityId, {comment, tags, atEpochMs})` and `split({atEpochMs})` (`lib/core/state/day_recorder.dart:99-121`).
- In `_closeLapLocked`, compute `boundary = atEpochMs ?? now`, then clamp to `[current.startedAtEpochMs, now]` (`:550-611`). A watch clock ahead of the phone must never write a Record ending in the future; a label from before the last MidnightSplit must never rewrite the previous Day.
- `WearableSyncService._executeWatchAction` passes `action.timestampEpochMs` (`lib/wearable/wearable_sync_service.dart:202-225`).
- Tests: offline label lands at the tapped instant; a future instant clamps to now; a pre-midnight instant clamps to the Lap start and leaves the prior Day untouched; UTC duration arithmetic still holds.

### R2 — De-duplicate watch actions (F6)

- New schema v10 table `processed_actions(action_id TEXT PRIMARY KEY, source TEXT NOT NULL, applied_at_epoch_ms INTEGER NOT NULL)`.
- Insert the marker inside the same transaction that writes the Record, so a replay aborts before any write. `INSERT OR ABORT` plus a caught constraint violation is enough; the service treats the duplicate as success.
- Keep both the DataItem and the MessageClient fast path; the marker makes them idempotent. Dequeue from the watch only after the phone acknowledges.
- Tests: the same `actionId` twice writes one Record; one DataItem plus one message with the same id writes one Record.

### R3 — Stop stale Lap snapshots from rewinding the watch (F7)

- Echo the last applied watch `actionId` in the phone's `/tempo/lap` payload.
- The watch ignores an incoming Lap while it holds an unacknowledged action, unless the payload carries that action id (`WearLapRepository.updateFromPhone`, `WearLapRepository.kt:236-252`).
- Drop the meaningless revision comparison: the phone and watch counters are independent. Causality comes from the ack, not from a shared number.
- The phone checks the UndoGraceWindow before applying `UNDO`, instead of trusting the watch.
- Tests: an optimistic label survives a stale snapshot; the ack clears the pending state; `UNDO` outside the window is refused.

### R4 — Snapshot the database safely (F9)

- Add `TempoDatabase.snapshotTo(File)`: `VACUUM INTO '<tmp>'`, then SHA-256, then hand the file to the uploader, then delete the temp.
- Verify before upload: open read-only, run `PRAGMA integrity_check`, compare the Record count against the live store.
- Remove the `databaseFactory.getDatabasesPath()` file read in `_resolveLocalDbFile` from the upload path (`lib/core/sync/google_drive_sync_service.dart:290-294`).
- Tests: a snapshot taken with uncommitted WAL frames contains them and passes `integrity_check`.

### R5 — Restore without an open connection (F10)

- Validate the file first (hash from the manifest, schema version, integrity check), then close the database, replace atomically (`.tmp` → `rename`), then reopen.
- Reopening is an app-level concern: `DayRecorder`, `CsvExportEngine`, and the UI all hold the old instance. The smallest honest implementation is a restart after restore; a reload path that rebuilds the whole record graph is the alternative.
- Tests: restore into a running app shows the restored Records after reopen; a corrupt file is rejected while the old database is still intact.

### R6 — Auto-backup to a user-chosen location (D7, F11, F13)

- Settings: an auto-backup toggle, a destination folder picker, a generation count, and an encrypt toggle.
- Layout: `<destination>/tempo/backup-<deviceId>-<ISO8601>.db` plus `latest.json` holding hash, byte size, schema version, and creation time. Per-device filenames prevent the phone and the Mac from overwriting each other's snapshot, which is F2 in miniature.
- Cadence: on Record commit with a debounce, plus on app pause. A local folder makes this cheap; a cloud-synced folder makes every snapshot a full upload, so the debounce must be longer than the CSV's 1 s.
- Prune to the configured generation count after a verified write.
- Implementation risk: on Android the picker returns a SAF tree URI, not a path `dart:io` can write to. That needs a native channel or a plugin that supports persistable tree permissions. macOS needs a security-scoped bookmark to keep folder access across launches.
- Tests: write, verify, prune; permission lost on destination; corrupt backup refused.

## Decisions

- **D5 (decided 2026-11-04)**: no automatic restore. A reinstall may lose local data; recovery is an automatic backup plus a manual Restore action. Consequence: the automatic backup becomes the only copy, so F9 and F10 rise from "should fix" to "must fix", and the backup needs a bounded, stated loss window and at least one prior generation.
- **D6 (decided 2026-11-04)**: the backup must be confidential, so plaintext in a visible Drive folder is not acceptable for the database snapshot. **Amended by D6a**: confidentiality is delegated to the user-chosen destination rather than enforced by Tempo.
- **D6a (decided 2026-11-04)**: no app-level encryption. The snapshot is plaintext in the chosen folder; the destination is the security boundary. Consequence: if the user picks a cloud-synced folder, that provider and anyone with account access can read the full history. No recovery phrase exists, so a manual restore needs nothing but the file.
- **D7 (decided 2026-11-04)**: backup is user-configured — an auto-backup toggle plus a user-selected destination folder. Google Drive is then one possible destination, not the only one. The BNPB CSV stays at the fixed visible `Time track` location because BNPB reads it there; the private snapshot is separate.
- **D9 (decided 2026-11-04)**: device roles are fixed. macOS is a home companion used alongside the phone; Android is the mobile node; the watch reaches the world through the phone. Sync is LAN-only as a result, and no cloud account is required to sync.

## Sync patterns considered

The deciding question is not transport, it is **who orders concurrent facts**. Every option below is a different answer to that.

### A — Whole-database file, last writer wins

Each device uploads its `tempo.db` to a shared folder; the newest upload replaces the others. No merge, no identifiers, no log. This is what exists today as backup, minus the safety.

- Breaks when two devices are used on the same day: the loser loses every Record it wrote since the winner's last upload, which can be a full day.
- Effort: small. Verdict: not sync; a roving restore point.

### B — Per-device event log in a shared folder

Each device appends only to its own log (`changes-<deviceId>.ndjson` or a small SQLite log file) in a folder that all devices can see — Google Drive appdata, iCloud Drive, Dropbox, or a SAF tree. Every device replays every log into its local SQLite. No device ever writes another device's file, so no lock or CAS is needed.

- Ordering is deterministic: replay by event time, tiebreak by device id, and the merge rule from D1 applied at replay.
- Works offline for days. Latency is whatever the folder's sync gives, plus polling on app focus and on an interval.
- Needs: device id, event schema (label, split, edge move, relabel, delete), tombstones, a per-log cursor, and compaction so logs do not grow forever.
- The watch does not participate; it stays on the Data Layer through the phone.
- Effort: medium. This is the option that fits the constraints without inventing a server.

### C — Hub and spoke, Mac as authority

The Mac is the only writer of record. Phone and watch send intents to it, locally over LAN (Bonjour/mDNS plus HTTP) or through a store-and-forward folder when apart.

- Conflicts disappear because ordering is single-writer. The client-side code is simpler than B.
- Fails when the Mac is asleep or left at home, which is most of the day for a phone-first user. The Mac also becomes the single point of loss.
- Effort: medium, plus a server that runs inside a desktop app.

### D — SQLite Session extension changesets

SQLite's session extension records row-level changesets and applies them on another database with a conflict callback. It is the official version of "row deltas".

- Buys ordering-free transport and a conflict hook per row, without a custom log format.
- Risk: it is a compile-time option (`ENABLE_SESSION`). Android's system SQLite and the bundled `sqflite_common_ffi` build may or may not have it, and the two platforms must agree.
- Row deltas still cannot enforce interval invariants; two overlapping Records merge happily and stay overlapping.
- Effort: medium-high, gated on a build spike.

### E — Row-level CRDT (cr-sqlite, Automerge)

Automatic convergence on field-level edits.

- Does not solve the actual problem: this domain's conflicts are interval constraints, not concurrent field writes. A CRDT will converge to an overlapping day and then you still need D1 to fix it.
- Requires native builds per platform or a model rewrite. Effort: high, risk: high.

### F — Backend (excluded)

A Durable Object or Postgres would give push, ordering, and conflict handling for free, but it violates "no mandatory cloud account" and "no central infrastructure". Listed only to close it.

### Why B

B keeps every device a full local store, needs no server, survives days offline, and makes the merge rule the only hard decision left. Its weaknesses are latency and log growth, both bounded and fixable. C is simpler but bets the product on a Mac being awake. D and E move the hard part (interval invariants) without removing it.

## How the sync actually runs

Transport and merge are separable. Transport is how bytes move; merge is what the receiving device does with a fact it did not have. Every transport below needs *some* merge, even if the rule is one line, because two devices will eventually produce facts for the same minute.

### Transport 1 — A shared folder (cloud or local)

The folder is a dumb store; the devices are smart. Each device writes only its own append-only log.

```
phone labels 10:00  →  local Record committed in SQLite
                    →  one line appended to changes-phone.ndjson, fsync
                    →  the folder's own sync client uploads the file

Mac, on focus or on a timer:
  files.list(folder) → compare modifiedTime to the cursor
                     → download the tail of changes-phone.ndjson
                     → parse complete lines only, stop at a torn last line
                     → apply each unseen event to SQLite
                     → advance the cursor, refresh the UI
```

- **Latency**: the folder's propagation plus the poll. In practice one to five minutes, not instant. There is no push, because a webhook needs a public endpoint, which means a server.
- **Cursors**: one `(deviceId, lastAppliedSeq)` row per device. The cursor must be inside the backup snapshot, or a restore replays old events. Replay is idempotent if every event carries an id, so a stale cursor is wasteful, not corrupting.
- **Bootstrap**: a new or reinstalled device reads every log from the start, or from the newest snapshot plus the tail. Replaying a year of events takes seconds.
- **Growth**: one event is roughly 200 bytes. A heavy user produces a few hundred a day, so ten years is tens of megabytes. Compaction is optional, not required.
- **Partial file risk**: a cloud client can upload a half-written file. Readers must ignore a trailing incomplete line and must not advance the cursor past it.
- **Watch**: it never sees this folder. It talks to the phone over the Data Layer, and the phone's log carries anything the watch caused.

Two implementations of this transport exist by default: Google Drive's appdata namespace (hidden, per-account, survives reinstall) and a user-picked folder (iCloud Drive, Dropbox, local, external disk). Android writes to the former through the Drive API and to the latter through a SAF tree; macOS uses the filesystem and a security-scoped bookmark.

### Transport 2 — Direct LAN

When both devices are on the same network, one of them listens (Bonjour/mDNS for discovery, HTTP for transfer) and the other pushes and pulls its tail. Sub-second latency, no third party, no account.

- Fails entirely when the devices are apart, which is exactly the "I left the Mac at home" case.
- Requires a responder inside one app: a small server in the Mac app or an Android foreground service.
- Best treated as an accelerator on top of Transport 1, not a replacement.

### Transport 3 — Platform cloud kit

iCloud CloudKit on Apple platforms, Google Drive on Android, with each device syncing through its own vendor's store. There is no shared store between an Android phone and a Mac, so this cannot be the only transport. It works as a destination for Transport 1 on a per-platform basis, nothing more.

### The minimum merge any transport needs

Apply events in event-time order, tiebreak by device id. When an event claims a span that is already claimed, the rule from D1 decides. The office can be as small as "later event wins for the same instant" — one comparison, no conflict UI — but it has to exist, or two devices will write overlapping Records and the day stops being a day.

### Chosen shape: home-LAN peer sync (replaces the cloud transport for sync)

Usage model as stated: the Mac is used at home, alongside the phone. Outside, the phone is the only store. The watch works anywhere and always reaches the phone.

That model removes the reason for a cloud transport. The two stores are co-located whenever both are in use, so the folder transport and the Google account requirement both drop out of the sync path. Drive stays only as an optional backup destination (D7) and as the BNPB export location.

**Topology.** The Mac listens; the phone dials. The Mac only writes while at home, and when it is at home it is on the LAN, so a one-directional connection is enough. Both sides store everything; neither is a permanent authority.

**Discovery.** Both advertise and browse a Bonjour/mDNS service type. Android needs a `MulticastLock` or mDNS packets are dropped while the screen is off. macOS needs the `com.apple.security.network.server` sandbox entitlement to listen, and local-network permission on recent macOS versions, which prompts the user the first time.

**Pairing.** First connection shows a six-digit code on the Mac; the phone enters it. Both derive a long-lived shared secret, used as an HMAC over each request with a nonce and timestamp so a replay is refused. No certificate work. Traffic is plaintext HTTP on the LAN, which is acceptable on a home network and not acceptable on café Wi-Fi — but sync only runs at home, so the exposure is bounded. TLS with a self-signed certificate pinned at pairing is the upgrade path if that changes.

**Exchange.** One endpoint, symmetric deltas:

```
POST /sync
  { deviceId, cursors: { mac: 412, phone: 98 }, events: [ ...unseen by peer... ] }

200 OK
  { ackCursor: 98, events: [ ...unseen by caller... ] }
```

Each event has an id, a device id, a sequence, an event time, and a payload (label, split, edge move, relabel, delete). Idempotent by id, so a retried request is harmless.

**Triggers.** On app foreground; immediately after a local commit if a connection is open; on mDNS service resolution; on Wi-Fi join; and a heartbeat every 30 s while both are present. The steady-state latency at home is under a second, which is the point: the window in which the two devices can disagree shrinks from minutes to milliseconds, so the D1 rule becomes a rare edge case rather than a daily event.

**The open Lap needs no event.** It is the tail of the record set: after applying the other device's Records, the Lap start is the last Record's end. Only deliberate boundaries travel.

**Failure modes.**

- Mac asleep or app closed: connection refused, the phone keeps recording, retries on next foreground or discovery.
- Phone asleep: the Mac's events wait; the phone pulls on next open.
- Guest Wi-Fi with client isolation: no LAN path, no sync until the two are on a network that allows it. Nothing corrupts; the logs just grow.
- Both devices offline: both accumulate, converge on the next meeting.

**First pairing is a different problem.** Two stores that have been recording independently for weeks do not have a delta; they have overlapping histories. Merging them with D1 produces a day full of clipped Records. The practical options are: adopt one store as the seed and import only the days the seed lacks, or accept the merge. This has to be decided before the first sync ships.

### Transport comparison: home LAN vs shared cloud folder

| Dimension | LAN at home | Shared cloud folder (Drive appdata) |
| --- | --- | --- |
| Works when apart | No. Mac changes wait for reunion; phone changes wait too. | Yes, anywhere with internet. |
| Latency | Under a second. | One to five minutes: provider propagation plus poll. |
| Window for conflicting facts | Milliseconds. | Minutes, so the D1 rule runs routinely instead of rarely. |
| Account | None. | Google account and a Drive grant on both devices. |
| Where the data sits | Only on the two devices. | Google's cloud, under the provider's control. |
| Setup | Pairing code, mDNS, firewall and local-network permission. | OAuth consent, appdata bootstrap. |
| Platform risks | Android multicast lock, macOS sandbox entitlement and local-network prompt, guest-Wi-Fi isolation, flaky mDNS on some routers. | Drive quotas, token refresh, appdata versus `drive.file`, silent propagation failures. |
| Battery and data | Negligible; only at home. | Periodic radio wakeups for polling on the phone. |
| Failure visibility | Loud: no service, refused connection. | Silent: the file exists but has not propagated yet. |
| Backup | Separate concern (D7). | A synced folder is not a backup: deletion and corruption propagate. |
| Testability | Local socket in tests. | Mocked Drive client, which already exists. |
| Effort | mDNS, small HTTP server, HMAC pairing, one endpoint. | Drive list and poll, same endpoint logic. |
| Watch | Through the phone. | Through the phone. |

Identical in both: the event log, the merge rule, tombstones, device ids, cursors, and the watch path. Only the transport differs, so choosing one now does not foreclose the other — a second transport can be added over the same log.

LAN mitigations worth building: a manual connect by IP or QR code when mDNS is unreliable on a router, and launch-at-login on macOS so the listener exists.

## Decision register

Six decisions change the schema or the product contract and are yours to make. Each has a recommendation, and each states what it blocks.

| # | Decision | Recommendation | Blocks |
| --- | --- | --- | --- |
| D1 | What happens when two devices disagree about the same span: fixed rule, or a conflict the user resolves? | **Decided: earliest claim keeps its span.** The later claim is clipped to the remaining Untracked time; if nothing remains, the later label produces no Record. Deterministic by event time, not arrival order; matches the import precedence rule. No conflict UI. | Workstream A; event schema |
| D1a | Does accepted data loss cover only reinstall, or also device-to-device writes? | **Decided: reinstall only.** Devices must converge; whole-database last-write-wins is not acceptable. | Workstream A |
| D2 | Sync transport, given no backend | **Decided: LAN only.** The Mac listens, the phone dials over the home network; no cloud account is required to sync. The shared-folder route is dropped for sync but remains a backup destination. | Workstream A |
| D3 | Watch role | **Decided by the LAN architecture: durable capture node** with timestamped, deduplicated, acknowledged actions. Not a full store; porting the Day, MidnightSplit, and Boundary rules to Kotlin is out of scope. | Workstream C |
| D6a | Backup encryption: always, or trust the chosen destination? | **Decided: trust the destination.** No app-level encryption. Confidentiality is delegated to the folder the user picks (FileVault, an encrypted disk, or a provider they trust). The snapshot is plaintext wherever it lands. | Workstream E; R6 format |
| D8 | Plaintext export exposure: the CSV keeps comments with `w/` names in a visible folder | Accept and document, because BNPB requires the comment column. Offer an opt-in "redact comments in the export" toggle for users who do not need BNPB interop. | F13 scope |

## Defaults I will take unless you object

- Backup cadence: snapshot every 5 minutes while dirty, plus on app pause; maximum loss window 5 minutes.
- Retention: last 5 verified snapshots per device, pruned only after a verified write.
- Backup layout: `<destination>/tempo/backup-<deviceId>-<ISO8601>.db`, plus `latest.json` with hash, size, schema version, and timestamp.
- Device id: random UUID stored in a `meta` table, generated on first launch.
- Watch acknowledgement: the phone echoes the last applied `actionId` in the Lap payload; the watch holds its optimistic Lap until it sees that echo.
- `processed_actions` retention: 90 days, then pruned.

## Decisions after the transport choice

- **D1 (decided 2026-11-04)**: in an overlap, the earliest claim keeps its span; the later claim is clipped to the remaining Untracked time, and if none remains it produces no Record. Ordering is by event time with a device-id tiebreak, so the result does not depend on which device syncs first. The clipped event stays in the log for audit even when it yields no Record.
- **D1a (decided 2026-11-04)**: loss tolerance covers reinstall only. Devices converge; whole-database last-write-wins is rejected.
- **D2 (decided 2026-11-04)**: sync is LAN-only. The Mac listens, the phone dials over the home network, no cloud account is needed to sync, and the shared-folder transport is dropped from the sync path. Consequences: the departure-boundary gap is accepted; Drive remains only for the BNPB export and an optional backup destination; the event log, cursors, device ids, tombstones, and merge rule are still required.

- **D10 (decided 2026-11-04)**: stop naming the peer app in product copy. The CSV stays byte-compatible with the Simple Time Tracker 8-column schema and keeps the `Contact` tag behaviour, but the UI and product docs describe it as "Simple Time Tracker–compatible export" rather than naming the consumer. Current mentions to remove: `lib/ui/settings_view.dart:473, 477, 479`, `README.md:40-44`, `PRODUCT.md:15, 23, 48`, `CONTEXT.md:76`.
- **D11 (decided 2026-11-04)**: the phone is the seed for first pairing. The Mac starts empty and receives the full history from the phone; there is no merge of two existing histories. This also means the Mac's schema and log cursors must be built entirely from the incoming export.

## Open questions still unanswered

- D8 above, with the default recommendation: accept the plaintext CSV and document it, plus an opt-in redaction toggle.
- Whether the sync cadence can be lazy (on focus and on LAN join only) or must run on a background interval. With LAN this is a battery question, not a quota question.
- Whether launch-at-login is a requirement on macOS, since the listener only exists while the app runs.
