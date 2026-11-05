# Goldfish Annotated Review Report (Fresh Pass)

**Target:** `docs/designs/multi-device-sync-and-recovery.md` (full file)
**Source:** `.scratch/time-tracker/reviews/consolidated_review_report_2.md`
**Status:** resolved (38 proposed fixes applied; 1 contested — C22; some sub-items declined within C39)

## Blockers

### C1 — Pairing direction contradicts platform wiring [`egm-zoom-out`, `egm-comprehension`, `egm-style`] — High

- **Scope:** lines 193, 501, 506, 580, 585 (Transport, items 29–31, 44–45)
- **Discrepancy:** Prose says phone shows the QR, Mac scans. The plan adds `CAMERA` to Android, a QR renderer to the macOS host, and no camera permission or entitlement to the Mac.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** The direction in the prose is right; the platform items were carried over from the previous design.
- **Proposed Edit:** Add `qr_flutter` to the phone, `mobile_scanner` to the Mac, `NSCameraUsageDescription`, `com.apple.security.device.camera`; remove Android `CAMERA`; keep Android multicast (the phone advertises). Add a permission-per-side table in Transport.

### C2 — Two-second goal unreachable with a 30-second poll [`egm-zoom-out`, `egm-design`] — High

- **Scope:** lines 31, 115, 197
- **Discrepancy:** The Mac is the only dialer; nothing wakes it on a phone write.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** A long-poll is a small change to the listener and keeps the stated goal.
- **Proposed Edit:** The Mac holds `GET /changes?since=` open for up to 25 s; the phone completes it on the next change. Keep the 30 s poll as a fallback when long-polling fails.

### C9 — `INSERT OR REPLACE` breaks foreign keys, rowids, and entity order [`egm-zoom-out`, `egm-style`] — High

- **Scope:** lines 171, 565 (Change kinds, Replication)
- **Discrepancy:** REPLACE deletes and re-inserts, nulling `activities.category_id` and cascading `record_tags`; it also reassigns rowid, which adjacency ties use.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** The repo already handles this in `upsertCategory` (`tempo_database.dart:355–362`).
- **Proposed Edit:** Apply as update-then-insert keyed by the text id; tags in the same transaction; state the entity order (categories, activities, tags, records, lap) and correct "removes the need for ordering" to "makes retries idempotent; `seq` order is still required".

### C19 — A delayed intent is silently reinterpreted [`egm-zoom-out`, `egm-implementation-readiness`, `egm-design`] — High

- **Scope:** lines 32, 176, 181, 404
- **Discrepancy:** The design promises the tapped time, then says a label clamps to the Lap; a Mac label tapped at 10:00 arriving after a 10:05 phone label would label the wrong span.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** This is the difference between a client and a second writer.
- **Proposed Edit:** Every intent carries `expected_lap_start_epoch_ms` and `tapped_at_zone`. The phone applies at the tapped time only if the Lap still starts there; otherwise it returns `rejected` with a specific reason and the Mac offers "place at now". Define `IntentResult {status, reason, entityId, appliedAtEpochMs}`.

### C10 — No delete kinds for Activity, Category, Tag; `record_remove` has no producer [`egm-zoom-out`, `egm-comprehension`, `egm-implementation-readiness`] — High

- **Scope:** lines 162–170 (Change kinds)
- **Discrepancy:** All three entity deletes exist and write tombstones; `DayRecorder.delete` relabels, so `record_remove` comes only from `merge` and `undoLast`.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add `activity_remove`, `category_remove`, `tag_remove`; route every delete through one helper writing the tombstone and change in the same transaction; state the `record_remove` producers.

### C11 — Three Record paths and the importer emit nothing [`egm-implementation-readiness`, `egm-codebase-details`, `egm-design`] — High

- **Scope:** line 404 (item 10), Stage 0
- **Discrepancy:** `splitRecord`, `merge`, `sameAsLast`, and the STT importer alter Records; none is in the plan.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Name all three in item 10 with their change kinds (`record_upsert` twice for split, `record_upsert` + `record_remove` for merge, `label` for sameAsLast); add `lib/core/import/stt_import_service.dart` to the plan with its append site.

### C12 — A fresh install never creates the new tables [`egm-implementation-readiness`] — High

- **Scope:** items 7–8
- **Discrepancy:** Only `migrateV9ToV10` creates `changes`, `processed_intents`, `sync_peers`; `createSchema` is what runs for a new database and every in-memory test.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add the DDL and seeds to `createSchema` and state that both paths produce the same schema.

### C13 — Seeded and backfilled values are unspecified [`egm-style`, `egm-implementation-readiness`] — High

- **Scope:** item 7
- **Discrepancy:** "Seed the eight settings rows" and "one `record_upsert` per Record" leave fields to the implementer.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State: `store_id = uuid`, `device_id = uuid`, `log_epoch = uuid`, `backup_enabled = false`, `backup_destination = ''`, `backup_generations = 5`, `export_redact_comments = false`, `replicate_enabled = false`; backfilled `change_id = uuid`, `at_epoch_ms = record.updated_at`, `entity_id = record.id`.

### C14 — Intent kinds counted, never enumerated, count wrong [`egm-implementation-readiness`, `egm-style`, `egm-codebase-details`] — High

- **Scope:** lines 185, 399, 575
- **Discrepancy:** Says eight, lists seven, omits `merge`, `splitRecord`, `sameAsLast`.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** One canonical list: `label`, `split`, `relabel`, `annotate`, `adjust_edges`, `clear`, `undo`, `merge`, `split_record`. `sameAsLast` is `label` with the last Activity. State which are exposed on the Mac.

### C15 — Mac `intents` table has no creation step [`egm-implementation-readiness`] — High

- **Scope:** item 7, item 42
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add a numbered item creating `intents` on macOS with DDL, indexes (`status`, `tapped_at`), and accessors (enqueue, pending in order, mark applied/rejected, read by id). Branch in `createSchema` by platform.

### C16 — The Mac runs the phone's startup path [`egm-implementation-readiness`] — High

- **Scope:** item 20
- **Discrepancy:** `main.dart` builds `DayRecorder`, seeds Activities, and can write a Lap and midnight Records.
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** A macOS startup that opens the replica with `ReplicaApplier` and `IntentQueue` only, plus a test that a Mac launch leaves `records`, `lap`, `activities`, and `changes` untouched.

### C17 — Watch watermark has no durable home [`egm-implementation-readiness`] — High

- **Scope:** item 11, data model
- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add `watch_watermarks(device_id TEXT PRIMARY KEY, action_seq INTEGER NOT NULL)`; read it on every `syncLap`; pass the watch's device id from the Data Layer call.

## Majors

### C3 — Unknown change kinds have no safe policy [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Abort the pull, do not advance `applied_seq`, and surface "the phone is running a newer version".

### C4 — `ackSeq` undefined [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Delete `ackSeq`; `intentResults` acknowledges intents individually and `applied_seq` acknowledges changes.

### C5 — `log_epoch` undefined [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Define it as a UUID renewed by restore, bootstrap, or log truncation; a differing value clears the cursor and replays from zero.

### C6 — Mac clock and zone trusted while the watch's are policed [`egm-comprehension`, `egm-zoom-out`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Carry `tapped_at_zone_id` in every intent and an end zone in `lap_set`; apply the same ten-minute skew rule to `tapped_at`, with a visible rejection.

### C7 — Pairing material in snapshots; no home on the Mac [`egm-comprehension`, `egm-design`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Keep secrets in platform secure storage (Android Keystore-backed preferences, macOS Keychain), not `tempo.db`; `sync_peers` keeps only peer id, store id, and host. Add "revoke all paired devices"; rotate on restore.

### C8 — Three id namespaces used as one [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** One `intent_id` used by Mac intents and watch actions; drop the `eventId` parameter and rename the column.

### C18 — `changes` grows without a bound [`egm-comprehension`, `egm-style`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State the estimate (about 200 bytes per change, a few hundred a day, roughly 20 MB a year), a 500 MB warning threshold, and the behaviour at it (warn, offer export, stop appending only with the user's consent). Add a risk row.

### C20 — Undo cannot be an intent [`egm-zoom-out`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Undo becomes a compensating intent: `record_remove` with the record id plus `lap_set` with the prior start. The watch's undo carries its `actionId`; the phone maps it to the Record it created.

### C21 — The MCP CLI is a second writer [`egm-zoom-out`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** While a peer is paired, `--allow-writes` is refused; the app reloads the Lap on external change. State this in the MCP section, not only in the lock item.

### C22 — Mac labelling carries most of the cost for a case the premise rules out [`egm-zoom-out`] — Medium

- **Discrepancy:** The reviewer proposes shipping a read-only replica first.
- **AI Suggestion:** CONTEST
- **Justification:** Mac labelling is a stated product goal in the reviewed document (line 32, CUJ 2) and in the user's requirement to switch devices mid-day. Proposing its removal is a scope argument, not a defect in the design.
- **Proposed Edit:** none. Recorded as a dissent; the design keeps My labelling.

### C23 — The only complete copy can be lost while a current copy sits on the desk [`egm-zoom-out`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add a phone-lost journey; allow the Mac replica to seed a replacement under the same hash and coverage validation as a backup; do not clear the replica on epoch change until a replacement reports a cursor; forbid an on-device destination, or state that a backup on the phone does not survive device loss.

### C24 — Staging ships write-path surgery before the safety net [`egm-zoom-out`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Reorder: Stage 1 backup, restore, store lifecycle; Stage 2 watch correctness; Stage 3 change feed; Stage 4 replication; Stage 5 hardening. The change-row backfill moves with Stage 3.

### C25 — Restore does not reconcile intents or `processed_intents` [`egm-design`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Key `processed_intents` by `(log_epoch, intent_id)`; on an epoch mismatch the Mac resends only pending intents and marks applied ones abandoned with a visible reason.

### C26 — Stage 3 export duplicates the backup and the Mac cannot produce it [`egm-zoom-out`, `egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Drop `changes` and the cursor from the export; the consumer backfills changes on import. Both sides can then produce it.

### C27 — SAF promotion is not atomic [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Verify the promoted file's hash against the manifest at the destination before marking the generation valid; state that SAF promotion is copy-then-delete, not atomic.

### C28 — Downgrade remedy names a nonexistent artifact [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State that downgrade is unsupported; a v9 build refuses v10 and the user must reinstall and accept losing post-upgrade data.

### C29 — `sync_log`, checksum, warning lack work items [`egm-zoom-out`, `egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Drop `sync_log`; counters come from `processed_intents` and `applied_seq`. Drop the drift checksum in favour of replay-from-zero. Remove the pre-departure warning from the risk table.

### C30 — Snapshot seq check races the live store [`egm-design`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Capture the expected seq in the same read transaction that starts the snapshot, compare to that, and record it in the manifest.

### C31 — macOS CI job has no preconditions [`egm-style`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add `runs-on: macos-latest`, checkout, the Flutter action, and `flutter pub get` before the build and codesign.

### C32 — Mac UI files unnamed [`egm-implementation-readiness`, `egm-style`, `egm-codebase-details`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Name `lib/ui/dashboard_view.dart`, `lib/ui/history_view.dart`, `lib/desktop/ui/quick_popover_view.dart`, `lib/desktop/menu_bar_service.dart`, and a new `lib/desktop/pairing_view.dart`; drop `settings_view.dart` from the mutation bullet.

### C33 — Sync settings specified in two stages [`egm-style`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Item 26 keeps backup and redaction only; item 44 owns the Sync section.

### C34 — Stage 0's test depends on Stage 1 [`egm-comprehension`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Move the change-row assertion to the change-feed stage.

## Structure

### C35 — `Additional Resources` and `Future Improvements` are H3 under Risks [`egm-structural`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Promote both to H2.

### C36 — Risk content has two homes [`egm-structural`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Move accepted risks into the risk section as an H3 and delete duplicated rows.

### C37 — One H2 swallows Backup, Seeding, Export, Diagnostics [`egm-structural`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Promote `Backup and Restore`, `Seeding and Export`, and `Diagnostics` to H2.

### C38 — The import goal has no section [`egm-structural`] — Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add `### Import` under the technical plan and state the tag behaviour there.

### C39 — Naming and format drift [`egm-structural`, `egm-style`, `egm-comprehension`] — Low

- **AI Suggestion:** PROPOSE FIX for four items, DECLINE the rest.
- **Proposed Edit (accepted):** rename `The Problem` to `Problem Statement` and `Technical Plan (Architecture)` to `Proposed Architecture`; say "row-for-row" instead of "byte-for-byte"; define the manifest as one ordered generation list; add the DataItem rationale.
- **Declined:** horizontal-rule regularisation, snake/camel casing sweep, removing comparative claims, the "ticket-level detail" objection (the drafting standard requires the section).
