# Consolidated Review Report (Fresh Pass)

- **Target**: `docs/designs/multi-device-sync-and-recovery.md`
- **Mode**: Consolidated report, all five stages
- **Date**: 2026-11-04
- **FeatureRange**: 1–347 · **DetailedRange**: 348–613
- **Reviewers**: zoom-out (×2), comprehension, design critic, structural, style (×3), implementation readiness, codebase details
- **Supersedes**: `consolidated_review_report.md` (written against the two-writer design)

## Verdict

Not ready for implementation. Ten blockers and eighteen majors.

The architecture is sound for the stated usage: one writer removes the class of bugs the previous design carried, and a fresh reader described the mechanism correctly without help. What blocks it now is ordinary inconsistency — the plan and the prose disagree about pairing direction, the apply rule breaks foreign keys, several delete paths have no change kind, and the intent model silently reinterprets a delayed label instead of refusing it.

The one structural risk worth naming: the design's premise is "the phone is always present", but every mechanism depends on the phone **app**, not the phone **device**. That gap is recorded as an accepted risk and the Mac shows "waiting", but it is the difference between the premise being true and being convenient.

## Consolidated Findings

### A. Pairing and protocol

**C1 — BLOCKER — The pairing direction contradicts its own platform wiring.**
The prose says the phone shows the QR and the Mac scans (lines 193, 580). The plan adds `CAMERA` to the Android manifest for scanning (line 506), adds a QR-render channel to the macOS host (line 501), adds no `NSCameraUsageDescription` or camera entitlement to the Mac, and adds no QR encoder for the phone.
*Fix*: phone renders (add `qr_flutter`), Mac scans (add `NSCameraUsageDescription` and `com.apple.security.device.camera`), drop Android `CAMERA`, keep Android multicast for advertising. State the permission per side in one table.
*Sources*: S5-1, S6-15, S9-style-3.

**C2 — BLOCKER — The two-second goal is unreachable with a 30-second poll.**
The Mac is the only dialer; its triggers are open, resume, after an intent, and a 30-second poll (lines 115, 197). Nothing wakes it when the phone writes.
*Fix*: hold a long-poll open (up to 25 s) and return as soon as a change exists, or push over the same connection. State the worst case for each path.
*Sources*: S5-3, S7-design-1.

**C3 — MAJOR — Unknown change kinds have no safe handling policy.**
Item 9 says unknown kinds are "rejected", but skipping one and advancing `applied_seq` silently drops data.
*Fix*: abort the pull, do not advance, and surface "the phone is running a newer version".
*Sources*: S6-11.

**C4 — MAJOR — `ackSeq` is introduced once and never defined.**
It appears in the response contract (line 195) and nowhere else; the pull loop uses `applied_seq`.
*Fix*: delete it, or define it as the highest intent result the phone has emitted.
*Sources*: S6-5.

**C5 — MAJOR — `log_epoch` is load-bearing and undefined.**
It decides replay-from-zero (lines 179, 195, 215) but the document never says what it counts or who increments it.
*Fix*: define it as a UUID or counter renewed by restore, bootstrap, or log truncation, and state that a differing value clears the cursor and replays.
*Sources*: S6-4.

**C6 — MAJOR — Mac clock and zone are trusted while the watch's are policed.**
Intents carry a bare `tapped_at_epoch_ms` with no zone, and only watch actions get a skew rule (line 205). A Mac clock minutes off writes a Record at the wrong instant.
*Fix*: carry `tappedAtZoneId` in every intent and an end zone in `lap_set`; apply the same ten-minute rule to `tapped_at`, with a visible rejection.
*Sources*: S6-12, S8-5.

**C7 — MAJOR — Pairing material has no home on the Mac and travels inside snapshots on the phone.**
The Mac's model has only `intents` and two settings keys (lines 144–158), so the secret has nowhere to live. On the phone the secret sits in `sync_peers`, which every snapshot copies to a folder the design allows to be cloud-synced (lines 139–140, 211–214). Disconnect is the only revocation, and a lost Mac cannot be revoked.
*Fix*: store the Mac's peer record explicitly; keep `sync_peers` out of snapshots (or keep secrets outside `tempo.db`); rotate on restore; add "revoke all paired devices".
*Sources*: S6-1, S7-design-5.

**C8 — MAJOR — Three id namespaces are used as one.**
`actionId`, `intent_id`, and the `eventId` passed to `DayRecorder` all land in `processed_intents` with no statement that they share a namespace.
*Fix*: one id type, one column, one name; delete `eventId`.
*Sources*: S6-7.

### B. Apply, schema and write coverage

**C9 — BLOCKER — `INSERT OR REPLACE` breaks foreign keys, rowids and entity order.**
The design makes it the universal apply rule (lines 171, 565). The codebase already documents the counter-case: `upsertCategory` updates before inserting because REPLACE nulls `activities.category_id` (`tempo_database.dart:355–362`). `record_tags` cascades, and REPLACE reassigns `rowid`, which adjacency ties use.
*Fix*: update-then-insert keyed by text id; tags in the same transaction; state the required entity order for a replay; correct the claim that ordering is unnecessary.
*Sources*: S5-2, S7-style-3.

**C10 — BLOCKER — No delete kinds for Activity, Category or Tag, and `record_remove` has no producer.**
The kind table has only `record_remove`, while all three entity deletes exist and already write tombstones (`tempo_database.dart:303, 407, 490`). `DayRecorder.delete` relabels; real removals happen in `merge` and `undoLast`.
*Fix*: add `activity_remove`, `category_remove`, `tag_remove`; route every delete through one path that writes the tombstone and the change together; define the `record_remove` producers.
*Sources*: S5-4, S6-6, S9-readiness-1.

**C11 — BLOCKER — Three Record-mutating paths and the importer are missing from the plan.**
`splitRecord` (`day_recorder.dart:363`), `merge` (`:404`), and `sameAsLast` (`:515`) are reachable from the UI and alter Records. The STT importer writes Records, Activities, and Tags with raw inserts and is not in Stage 0's file list, though item 6 asserts imported Records produce changes.
*Fix*: name all three in item 10 and add `lib/core/import/stt_import_service.dart` to the plan with its append site.
*Sources*: S9-readiness-1, S9-codebase-1, S9-codebase-2, S7-design-3.

**C12 — BLOCKER — A fresh install creates v10 without the new tables.**
Item 7 seeds everything in `migrateV9ToV10`; `createSchema` (`tempo_database.dart:109`) is what runs for a new database and for every in-memory test, and it creates none of `changes`, `processed_intents`, `sync_peers`, or the settings rows.
*Fix*: add the same DDL and seeds to `createSchema`, and state each seeded value.
*Sources*: S9-readiness-3.

**C13 — BLOCKER — Seeded and backfilled values are unspecified.**
"Seed the eight settings rows" and "one `record_upsert` per existing Record" leave the implementer to invent `store_id`, `device_id`, `log_epoch`, `change_id`, `at_epoch_ms`, and `entity_id`.
*Fix*: state each value and derivation, and assert them in item 18.
*Sources*: S9-style-4, S9-readiness-3.

**C14 — BLOCKER — The intent kinds are counted, never enumerated, and the count is wrong.**
Item 9 says eight; the lists at lines 185 and 575 have seven. `merge`, `splitRecord`, and `sameAsLast` appear in neither.
*Fix*: publish one canonical list with payloads, and state which are `RecordCommands` members and which are phone-only.
*Sources*: S9-readiness-2, S9-style-5.

**C15 — BLOCKER — The Mac's `intents` table has no creation step.**
Item 7 creates phone tables only; item 42 requires durable intents.
*Fix*: add a Mac migration or a platform branch in `createSchema`, with DDL and accessor signatures.
*Sources*: S9-readiness-5.

**C16 — BLOCKER — The Mac would run the phone's startup path.**
`main.dart` always constructs `DayRecorder`, calls `initialize()`, seeds five Activities, and attaches the CSV exporter. That writes a Lap row, can write midnight Records, and violates "never write a Record from any other path".
*Fix*: a macOS startup path that opens the replica with `ReplicaApplier` and `IntentQueue`, plus a test that a Mac launch leaves `records`, `lap`, `activities`, and `changes` untouched.
*Sources*: S9-readiness-4.

**C17 — BLOCKER — The watch watermark has no durable home.**
Item 11 keeps the highest applied seq in memory; the phone schema has no column for it, and `WatchAction` carries no device id.
*Fix*: add `watch_watermarks(device_id, action_seq)` and read it on every `syncLap`.
*Sources*: S9-readiness-4.

**C18 — MAJOR — `changes` and `processed_intents` grow without a stated bound.**
Compaction is deferred to Future Improvements against a 100 MB trigger, and the risk table has no growth row.
*Fix*: state the expected growth and the failure behaviour at the cap, or add retention now.
*Sources*: S6-19, S7-style-2.

### C. Intents and authority

**C19 — BLOCKER — A delayed intent is silently reinterpreted instead of refused.**
The design promises application at the tapped time, then says a label "clamps to the Lap" (lines 32, 176, 181). A Mac label tapped at 10:00 that arrives after the phone labelled at 10:05 would label the 10:05–now span with the Mac's Activity.
*Fix*: give every intent a precondition (the expected open-Lap start), apply at the tapped time only if it still holds, otherwise reject with a specific reason and offer to re-place at now. State the `IntentResult` fields.
*Sources*: S8-3, S9-readiness-3, S7-design-2.

**C20 — BLOCKER — Undo cannot be an intent.**
Undo reverses `_lastOperation`, an in-memory snapshot bounded by three seconds; a LAN intent arriving later has nothing to reverse, and the watch's `UNDO` already reverses whatever the phone last did.
*Fix*: express undo as a compensating command with explicit targets (record id to remove, prior Lap start), or remove undo from the Mac and watch sets for this release.
*Sources*: S5-5.

**C21 — MAJOR — The MCP CLI is a second writer.**
`bin/tempo_mcp.dart` opens the store in its own process and its write tools label, split, and move edges through a separate `DayRecorder`. The document treats MCP only as a locking concern.
*Fix*: refuse MCP write mode while replication is enabled, or route writes through the app; reload the Lap when the store changes underneath.
*Sources*: S5-6.

**C22 — MAJOR — Mac labelling carries most of the cost for the case the premise says does not happen.**
The Mac's writes require the queue, the pending/rejected overlay, the `RecordCommands` rewiring of five view files, and a third writer into the domain — to save picking up a phone that is always within reach (lines 32, 67, 238, 575, 580).
*Fix*: consider shipping Stage 4 as a read-only replica first, and add Mac labelling separately; if it stays, start with actions that carry no time of their own (annotate, relabel).
*Sources*: S8-6.

### D. Recovery and staging

**C23 — BLOCKER — The only complete copy can be lost while a current copy sits on the desk.**
The phone is the sole authority; the Mac's replica is declared disposable (lines 209, 315). Losing the phone loses the record until a restore, and the destination tier covers an erased install, not a lost device. The SAF picker will also accept a folder on the phone itself.
*Fix*: add a phone-lost journey; let the replica seed a replacement under the same hash and coverage validation as a backup; do not clear the replica on epoch change until a replacement reports a cursor; forbid an on-device destination or say the backup does not survive device loss.
*Sources*: S8-1.

**C24 — BLOCKER — The staging ships write-path surgery before the safety net.**
Stage 1 rewrites eleven mutation paths before Stage 2 adds verified backup (lines 384, 404, 446).
*Fix*: swap them — backup and restore first, change emission with the replication stage, backfilled at enable time.
*Sources*: S8-2.

**C25 — MAJOR — Restore does not reconcile intents or `processed_intents`.**
`processed_intents` travels inside the restored snapshot (line 131) and the epoch renewal does not touch intents, so a label can be applied twice or never.
*Fix*: key `processed_intents` by `(log_epoch, intent_id)`; on mismatch, resend pending only and mark applied ones as abandoned with a reason.
*Sources*: S7-design-4.

**C26 — MAJOR — Stage 3's export duplicates the backup and the Mac cannot produce it.**
The export is defined to carry `changes` and the cursor, but the Mac replica has no `changes` table. Its unique value over a backup generation is the Mac's post-promotion records.
*Fix*: drop `changes` and the cursor from the export and have the consumer backfill changes on import, so either side can produce it; or delete Stage 3 and seed from the newest verified backup.
*Sources*: S5-7, S6-2.

**C27 — MAJOR — SAF promotion is not atomic and nothing detects a half-written generation.**
The layout says "renamed into place" and the risk table relies on temp-fsync-rename, while item 23 admits copy-then-delete on SAF.
*Fix*: verify the promoted file's hash against the manifest at the destination before marking the generation valid, and state that SAF promotion is not atomic.
*Sources*: S6-14.

**C28 — MAJOR — The downgrade remedy names an artifact that does not exist.**
Line 305 says a v9 build refuses v10 and the user must restore, but every backup and export is a v10 container.
*Fix*: state that downgrade loses post-upgrade data and name the v9-readable artifact, or declare downgrade unsupported.
*Sources*: S6-13.

**C29 — MAJOR — `sync_log`, the drift checksum, and the pre-departure warning are mechanisms without work items.**
`sync_log` is required by diagnostics and the security NFR but created by no stage and cannot be excluded from a `VACUUM INTO` snapshot. The checksum and warning appear only in the risk table.
*Fix*: drop `sync_log` (counters come from `processed_intents` and `applied_seq`), drop the checksum in favour of replay-from-zero, and mark the warning out of scope or add items.
*Sources*: S6-9, S5-8, S6-10.

**C30 — MAJOR — The snapshot's seq check races the live store.**
Comparing the snapshot's highest `changes.seq` to the live store's fails whenever a write lands during the vacuum.
*Fix*: capture the expected seq in the same read transaction that starts the snapshot, compare against that, and record it in the manifest.
*Sources*: S7-design-6.

### E. Platform and build

**C31 — MAJOR — The macOS CI job has no preconditions.**
It lists only `flutter build` and `codesign`, with no runner label, checkout, Flutter setup, or `pub get`, while the Android job lists all of them.
*Fix*: add `runs-on: macos-latest` and the same setup steps.
*Sources*: S9-style-2.

**C32 — MAJOR — The Mac UI file list is "the Mac views".**
Item 44 names `settings_view.dart`, which performs no Record mutation, and leaves the five files that do mutate unnamed.
*Fix*: list `dashboard_view.dart`, `history_view.dart`, `quick_popover_view.dart`, `menu_bar_service.dart`, and any new pairing view explicitly.
*Sources*: S9-readiness-5, S9-style-1, S9-codebase-5.

**C33 — MAJOR — The Sync settings section is specified in two stages.**
Item 26 (Stage 2) and item 44 (Stage 4) both add pairing, client list, cursors, and counters, so Stage 2 cannot ship alone.
*Fix*: keep backup and redaction in item 26; make item 44 the sole owner of the Sync section.
*Sources*: S9-style-6.

**C34 — MAJOR — Stage 0's test depends on Stage 1.**
Item 6 asserts imported Records produced `record_upsert` changes, but `changes` arrives in Stage 1.
*Fix*: move the assertion to Stage 1, or fold Stage 0's import work into the replication stage.
*Sources*: S6-8.

### F. Document structure

**C35 — MAJOR — `Additional Resources` and `Future Improvements` are H3 under Risks.**
They read as risk subsections, and no H2 closes the document after line 317.
*Fix*: promote both to H2.
*Sources*: S7-structural-1.

**C36 — MAJOR — Risk content has two competing homes.**
`Accepted risks` sits under NFR while `Risks & Mitigations` is its own H2; three entries are stated twice.
*Fix*: move accepted risks into the risk section as an H3 and delete duplicates.
*Sources*: S7-structural-2.

**C37 — MAJOR — One H2 swallows every subsystem.**
Backup, restore, seeding, export, and diagnostics are H3s under `Technical Plan (Architecture)`.
*Fix*: promote `Backup and Restore`, `Seeding and Export`, and `Diagnostics` to H2.
*Sources*: S7-structural-3.

**C38 — MAJOR — The import goal has no section.**
`Importing a Simple Time Tracker .backup preserves its tags` (line 39) maps to no heading.
*Fix*: add `### Import` and state the tag behaviour there.
*Sources*: S7-structural-4.

**C39 — NIT — Naming and format drift.**
`The Problem` vs the standard's Problem Statement; `Technical Plan (Architecture)` vs Proposed Architecture; inconsistent horizontal rules; "byte-for-byte" overstating value equality; snake_case and camelCase mixed for the same fields; manifest shape ambiguous; "do not delete DataItems" has no reason; three unmeasured comparative claims.
*Fix*: rename two headings, remove or regularise rules, say "row-for-row", pick one casing per name, define the manifest as one ordered list, add the DataItem rationale, and delete or measure the comparative claims.
*Sources*: S7-structural-5, S7-structural-6, S7-style-5, S7-style-6, S7-style-7, S6-16, S6-17, S6-18, S7-style-4.

## Traceability Matrix

| Source | Findings → consolidated |
| --- | --- |
| Stage 5 (zoom out) | 1→C1 · 2→C9 · 3→C2 · 4→C10 · 5→C20 · 6→C21 · 7→C26 · 8→C29 · 9→C39 · 10→C39 |
| Stage 6 (comprehension) | 1→C7 · 2→C26 · 3→C9/C27 · 4→C5 · 5→C4 · 6→C10/C14 · 7→C8 · 8→C34 · 9→C29 · 10→C29 · 11→C3 · 12→C6 · 13→C28 · 14→C27 · 15→C1 · 16→C39 · 17→C39 · 18→C39 · 19→C18 |
| Stage 7 (critic) | design 1→C2 · design 2→C19 · design 3→C10 · design 4→C25 · design 5→C7 · design 6→C30 · structural 1→C35 · structural 2→C36 · structural 3→C37 · structural 4→C38 · structural 5→C39 · structural 6→C39 · style 1→C39 · style 2→C18 · style 3→C9 · style 4→C39 · style 5→C39 · style 6→C39 |
| Stage 8 (zoom out) | 1→C23 · 2→C24 · 3→C19 · 4→C6 · 5→C6 · 6→C22 |
| Stage 9 (readiness) | readiness 1→C11 · readiness 2→C14 · readiness 3→C19 · readiness 4→C16 · readiness 5→C15/C32 · readiness 6→C7/C9 · codebase 1→C11 · codebase 2→C11 · codebase 3→C12 · codebase 4→C17 · codebase 5→C32 · codebase 6→C21 · style 1→C32 · style 2→C31 · style 3→C1 · style 4→C13 · style 5→C14 · style 6→C33 |

## Recommended Order

1. **C1, C2, C9, C19** — the four that make the feature wrong rather than incomplete: pairing direction, wake-up, apply semantics, and delayed-intent placement.
2. **C10, C11, C12, C13, C14, C15, C16, C17** — schema and write coverage. These are one pass over the migration and the write paths.
3. **C23, C24** — loss model and stage order. Both change the plan's shape, so settle them before editing items.
4. **C3, C4, C5, C6, C7, C8, C20, C21** — protocol and authority details.
5. **C18, C22, C25–C34** — bounds, alternative scope, recovery edges, platform wiring.
6. **C35–C39** — structure and wording, last.
