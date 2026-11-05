# Consolidated Review Report

- **Target**: `docs/designs/multi-device-sync-and-recovery.md`
- **Mode**: Consolidated report, all five stages
- **Date**: 2026-11-04
- **FeatureRange**: 1–346 · **DetailedRange**: 347–622
- **Reviewers**: zoom-out (×2), comprehension, design critic, structural, style (×3), implementation readiness, codebase details
- **Stage reports**: `zoom_out_report.md`, `comprehension_report.md`, `critic_report.md`, `intermediate_zoom_out_report.md`, `implementation_readiness_report.md`

## Verdict

Not ready for implementation. Twelve blockers, seventeen majors, eight nits.

The blockers are not scattered defects; they cluster around one claim the document makes and does not yet earn: **that the event log is the source of truth for a Day**. Three of the four write paths that create Records today emit nothing, received events are never stored, derived midnight halves get random ids, the Day itself has no identity, and the merge's ordering rule is stated twice with different answers. Any one of those makes convergence false; together they make the architecture unbuildable as written.

The review also found a product-level question the draft never asks: five of six user journeys are single-writer, so the entire merge apparatus exists for one conflict case that the stated usage pattern says is rare. That is worth settling before fixing the details, because the cheapest fix may be to delete the merge rather than repair it.

## Consolidated Findings

### A. Merge determinism and identity

**C1 — BLOCKER — Merge ordering is stated twice, incompatibly.**
Step 3 applies claims in `(event_at_epoch_ms, device_id, seq)` order (lines 162–163); the following paragraph orders by the claimed span's start (line 170); CUJ 4 (line 82) needs span start, but both claims start at 09:00, so a device-id tiebreak decides. `seq` is a local insertion counter and cannot be compared across devices (line 119).
*Fix*: one canonical key, stated once — claims by `(started_at_epoch_ms, event_at_epoch_ms, device_id, event_id)`, entity ops by `(event_at_epoch_ms, device_id, event_id)`. Delete the second rule and rewrite CUJ 4 to name the winning key.
*Sources*: S5-1, S6-1, S7-design-1, S7-structural-1, S7-style-1.

**C2 — BLOCKER — A Day has no identity.**
The rebuild unit is "each Day touched" (line 161) and coverage is "Records within each Day" (line 207), but there is no `day_key`. A Day is defined by the computing device's zone (`CONTEXT.md:9–10`), so a phone that crossed zones produces different Days than the Mac. CUJ 2 then fails the convergence goal.
*Fix*: add `day_key` — the UTC instant of the Day's first local midnight plus the zone that produced it — to every claim and Record, computed once by the originating device. Group, rebuild, and check coverage by it.
*Sources*: S8-2. Dissolves C3, C4, C7.

**C3 — BLOCKER — Derived midnight halves get random ids.**
Line 164 promises identical halves, but today's split assigns a fresh UUID per slice (`day_recorder.dart:772–793`), so the two devices cannot produce identical Records and the property test at line 584 cannot pass.
*Fix*: derive ids from `(claim id, slice index)`; state the rule in merge steps 4 and 6, and apply it to synthesised Untracked spans.
*Sources*: S5-2, S9-codebase-2, S8-2.

**C4 — BLOCKER — Unclaimed time never becomes an Untracked Record in the rebuild.**
Steps 1–8 build Records from claims only; a gap between two claims has no owner, yet the product invariant and the verification plan both require one.
*Fix*: add an explicit step that materialises every unclaimed span as an Untracked Record with a deterministic id.
*Sources*: S5-4, S9-readiness-1.

**C5 — BLOCKER — `record_delete` does not match what delete does.**
`DayRecorder.delete` rewrites the Record as Untracked in place, keeping id, span, and zones (`day_recorder.dart:452–468`). The event carries only id and time; applying it literally leaves a gap.
*Fix*: emit `record_relabel(null)` + `record_annotate(empty)` in one transaction and delete the kind, or define `record_delete` as "keeps span, clears label, preserves coverage".
*Sources*: S5-17, S9-readiness-1, S9-codebase-4.

**C6 — BLOCKER — The Lap rule forbids the undo it requires.**
`lap_moved` is emitted by undo (line 153) and undo restores an earlier start (`day_recorder.dart:484–511`), while step 7 says the Lap may never move backwards (line 167). No rule resolves the conflict.
*Fix*: make step 7 a recomputation, not a monotonic guard: state the comparison, the tiebreak between two `lap_moved` events, and which open span survives when the peer's start is earlier.
*Sources*: S5-3, S7-design-2, S9-readiness-5, S7-style-17.

**C7 — MAJOR — Edits targeting a suppressed claim are undefined, and `sync_suppressed` has no reader.**
The pending set covers only events arriving before their claim (line 155); a relabel, annotate, edge, or delete aimed at a claim clipped to nothing has no stated outcome, though the property test asserts one (line 584). The table is written but never read.
*Fix*: define the rule (retain and re-apply if the claim later wins time, or drop with a recorded reason), name the reader, or make suppression derived and delete the table.
*Sources*: S5-16, S5-11, S6-9.

### B. The log as the only writer

**C8 — BLOCKER — The log is not the only writer, so a rebuild destroys data it cannot see.**
`record_claim` is emitted only by label and the one-time backfill (line 148). Direct writes with no event: the STT importer (`stt_import_service.dart:458, 200, 229`), first-run seeding (`main.dart:180`), `splitRecord` (`history_view.dart:369`), `merge` (`:673`), automatic midnight splits (`day_recorder.dart:646–708`), the Untracked Records from `adjustEdges` (`:216–352`), and every Activity, Tag, and Category write outside `DayRecorder` (`activity_manager_view.dart:291, 305`, `quick_popover_view.dart:427`, `deep_link_service.dart:205`, `tempo_mcp_server.dart:1081`).
*Fix*: make the log the single write path before Stage 1 — every insert emits its event in the same transaction — or add an explicit "adopt unclaimed Record" step. Name each write site and whether import, deep links, and seeding emit.
*Sources*: S8-1, S9-readiness-2, S9-codebase-1, S9-codebase-2.

**C9 — BLOCKER — Received events are never persisted.**
The apply port commits after updating the Lap (lines 174–183) without inserting the peer's events, though the union (line 161), the audit trail (line 200), the suppressed rows (line 131), and the seed (line 532) all assume they are stored.
*Fix*: state that `applyRemoteEvents` inserts each received event with `INSERT OR IGNORE` on `event_id` before the rebuild, preserving origin device and event time and assigning a fresh local `seq`. Define "duplicate" as an ignored insert.
*Sources*: S9-readiness-3, S7-design-3.

**C10 — MAJOR — The migration wording implies a table it does not create, and backfills no Lap.**
Line 388 says "backfill one `record_claim` per existing Record", which reads as a table; item 7 creates only three tables. The Lap is a separate row (`migrations.dart:10–17`) and gets no `lap_moved`, so the merge's Lap rule has no input after upgrade.
*Fix*: say "one `record_claim` event per Record", and add one `lap_moved` with the current start and zone.
*Sources*: S9-readiness-9, S9-readiness-8, S7-style-1.

**C11 — MAJOR — Three write paths open their own transactions, so "inside the existing transaction" is false.**
`relabel` (`day_recorder.dart:139`), `annotate` (`:159`), and `delete` (`:464`) call `TempoDatabase.updateRecord`, which opens its own transaction (`tempo_database.dart:527–547`).
*Fix*: name the seam — rewrite these to open `_db.db.transaction` and use the existing `_updateRecordInTxn`, inserting the event in the same transaction.
*Sources*: S9-codebase-5.

### C. Protocol and recovery

**C12 — BLOCKER — Full replay in one request livelocks.**
A restored device clears cursors and sends its full log (line 193) in one `POST /sync` that must be size-bounded (line 559) while the log reaches tens of MB (line 343); the cursor advances only on a completed apply (line 185), so every retry sends the same oversized body.
*Fix*: cursor-paginated batches — `{sinceSeq, limit}`, one batch applied and committed per request, cursor advanced per batch, loop to the tail. State that every full replay uses the same path.
*Sources*: S8-4, S6-3, S7-structural-13, S5-3 (retention).

**C13 — MAJOR — The two-second goal cannot be met by a one-way listener.**
Only the Mac listens; a commit on a closed connection waits for the 30-second heartbeat (lines 31, 194).
*Fix*: keep a connection open and reconnect on commit, or restate the goal as "on the next exchange" and stop letting it drive the transport.
*Sources*: S5-9, S7-design-4.

**C14 — MAJOR — The coverage check compares the wrong values.**
Line 207 compares a log high-water mark to per-peer cursors; a truncated log passes.
*Fix*: compare the snapshot's `MAX(sync_events.seq)` to the live store's, and check each cursor's `log_epoch`; keep cursors out of the coverage predicate.
*Sources*: S6-12, S7-design-5.

**C15 — MAJOR — `log_epoch` is "reset guard" and never changes.**
It forces a full replay (line 193) but no operation in scope increments it; compaction is deferred; restore reissues `device_id`.
*Fix*: define what it identifies and the exact operation that changes it, or drop it from v10 and add it with compaction.
*Sources*: S5-10, S6-4.

**C16 — MAJOR — One cursor column cannot represent "both cursors".**
`sync_cursors.last_seq` is a per-peer send watermark, while Settings promises both directions (lines 39, 219).
*Fix*: name two columns (`peer_ack_seq`, `received_seq`) or state that one is derived from the last response, and say which diagnostics reads.
*Sources*: S5-25, S6-10.

**C17 — MAJOR — Pairing cannot be revoked, and the manual fallback cannot supply `store_id`.**
Disconnect clears the cursor but leaves the 256-bit secret valid on both sides (item 27). The typed fallback supplies IP and secret only, while requests validate `storeId` (lines 190–192).
*Fix*: disconnect deletes the secret on both sides; include the store id in the typed payload.
*Sources*: S5-18, S5-24, S7-style-5.

**C18 — MAJOR — Nonce replay protection duplicates event idempotence.**
A replayed request cannot alter the store because `event_id` is unique; the nonce cache adds unbounded server state.
*Fix*: drop the nonce, keep the timestamp window and the dedupe, or state the harm a replay causes.
*Sources*: S5-12.

**C19 — MAJOR — No execution model for sync or backup on Android.**
The triggers and the five-minute snapshot assume a running isolate (lines 194, 209); no foreground service, `WorkManager`, or boot receiver is planned, and no accepted risk covers it.
*Fix*: scope to foreground-only and rewrite the goal and CUJ 2, deleting the heartbeat and network-change triggers, or add a service and its battery cost.
*Sources*: S8-5.

### D. Watch

**C20 — BLOCKER — The watch acknowledgement has no rejection channel and no source.**
The Lap payload gains only `appliedActionSeq` (line 413); refused actions are "acknowledged as rejected" (line 201); Android invokes the handler fire-and-forget (`MainActivity.kt:296`); `WatchAction` has no sequence (`wearable_sync_service.dart:12–26`); the watch dequeues on dispatch (`WearLapRepository.kt:268, 367`).
*Fix*: add `rejectedActionIds` and `actionSeq` to the payload and `WatchAction`, return the applied seq from the label or split, keep the highest in the service, place both in `syncLap`, and remove dequeue-on-dispatch in favour of the watermark.
*Sources*: S9-readiness-4, S9-readiness-13, S9-codebase-6.

**C21 — MAJOR — A watch label and the same fact from the Mac get different policies.**
Peer claims clip and suppress; watch actions are rejected when earlier than the phone's Lap start (line 201), which is the normal case after hours offline.
*Fix*: route watch actions through the same resolver; reserve rejection for undecodable payloads and unknown Activities.
*Sources*: S8-3.

**C22 — MAJOR — Four duplicate guards with no load-bearing statement.**
Action id over two channels, `event_id` uniqueness, `appliedActionSeq`, and DataItem deletion. Deletion is justified by a ledger that ages out, while the log is never pruned.
*Fix*: `event_id` is the only correctness guard; the watermark trims the queue; drop DataItem deletion or state what it protects.
*Sources*: S5-15.

**C23 — MAJOR — "Exactly once" overclaims.**
Line 33 promises exactly once; line 202 drops the oldest action at the cap; line 201 rejects actions.
*Fix*: restate as delivery at the tap timestamp with idempotent application, and name both loss paths and their user-visible signal.
*Sources*: S7-style-15, S5-29.

### E. Backup and restore

**C24 — MAJOR — Backup directories are keyed by `device_id`, which restore reissues.**
Line 208 keys by device id and line 209 prunes per device; line 88 issues a new id after restore, so the old generations become unreachable and grow forever.
*Fix*: key by `store_id`, record the writing device in the manifest, and prune across device ids under one store.
*Sources*: S7-design-7.

**C25 — MAJOR — The recoverable copy is as fresh as the last promotion, not five minutes.**
The five-minute tier is local and dies with the uninstall (line 35 vs 209); promotion is hourly and on pause, and uninstall is neither.
*Fix*: state the real window ("restore loses at most one promotion interval"), and promote before destructive actions.
*Sources*: S8-6, S7-structural-13.

**C26 — MAJOR — The destination abstraction lacks the primitives the layout uses.**
`pick/write/list/delete/reopen` cannot express temp-then-rename, restore-time read, or atomic rename on SAF (line 208); cloud detection is specified by path while Android returns handles (line 210 vs 515).
*Fix*: add `renameAtomically` and `openRead` with per-platform guarantees, and move cloud detection into each implementation (mount point on macOS; provider authority on Android).
*Sources*: S5-14, S6-19.

**C27 — MAJOR — Restore assumes a permission that does not survive uninstall.**
CUJ 5 tells the user to pick Restore after reinstalling, but Android's SAF permission and the macOS bookmark are both gone.
*Fix*: add the re-pick step to CUJ 5 and the Backup section.
*Sources*: S6-14.

**C28 — MAJOR — The decision log's storage is unstated and collides with the snapshot.**
It "never leaves the device" (line 304) but is not placed in or out of `tempo.db`, which every snapshot copies.
*Fix*: state whether it is a table or a file; if a table, prune or exclude it before a snapshot and correct line 304.
*Sources*: S6-11.

**C29 — MAJOR — Two snapshot tiers with no stated failure separating them.**
The local five-minute copy is "never uploaded on its own"; promotion is hourly; no failure is named for each.
*Fix*: name the failure each covers (live-store corruption vs erased install) or collapse to one tier.
*Sources*: S5-13.

### F. Product and architecture

**C30 — MAJOR — One-authority-plus-queues is never weighed, and the merge serves one journey.**
Five of six CUJs are single-writer; CUJ 4 requires a partition between two devices described as sitting together (line 15). The watch already implements the queue model.
*Fix*: instrument real overlaps before building the merge, or cut to the queue model (phone as writer, Mac and watch as queued clients) and delete the merge, resolver, log determinism, and convergence test.
*Sources*: S5-7, S8-7.

**C31 — MAJOR — Bootstrap duplicates the sync path and cannot be exercised at its stage.**
Item 7 backfills claims and line 193 forces a full replay, so a new Mac converges through the ordinary path; Stage 3 has no transport (LAN is Stage 4) and no Settings entry point.
*Fix*: delete Stage 3, or give it a file path and an entry point and state the measured cost it avoids.
*Sources*: S5-8, S6-20, S6-5.

**C32 — MAJOR — The phone is a single point of failure for the CSV.**
Line 215 makes it the only uploader; if it is lost, Mac Records never reach the export.
*Fix*: state the delay until the restored phone syncs, or add a second exporter with a duplicate-write policy.
*Sources*: S7-design-8.

**C33 — MAJOR — Clipped and suppressed time is invisible on the Day.**
Line 82 silently rebuilds Commute; line 219 exposes it only as a counter, reproducing the "silence" the problem statement names (line 25). No per-Day digest detects divergence.
*Fix*: mark clipped and suppressed spans on the affected Day, and exchange a per-Day digest so a mismatch is reported rather than assumed away.
*Sources*: S7-design-6.

### G. Platform, build, and scope

**C34 — BLOCKER — The exclusive store lock breaks the shipped MCP workflow.**
Item 20 takes a lifetime exclusive lock; `bin/tempo_mcp.dart:51` holds the store for its whole session; item 22 only expects failure during restore.
*Fix*: make the lock advisory and scoped to restore and fallback snapshots, with pid, purpose, and staleness; define who refuses; drop `tempo_mcp_server.dart` from item 22 because it never opens a store.
*Sources*: S5-6, S6-13, S9-readiness-14, S9-codebase-7.

**C35 — BLOCKER — Dependencies and the camera path are left to the implementer.**
Line 579 names categories, not packages; no camera permission or entitlement is added; the QR side that scans is unstated.
*Fix*: name the mDNS, QR render, and QR scan packages with pinned versions and licences; add `CAMERA` and `NSCameraUsageDescription`; state the payload format and which side scans.
*Sources*: S5-27, S9-readiness-10, S9-readiness-16, S7-style-16.

**C36 — BLOCKER — Two stages end in conditional placeholders.**
Items 49–50 depend on undecided questions (launch-at-login, `minSdk`).
*Fix*: decide both, or move them to Non-Goals and Future Improvements and delete the items.
*Sources*: S5-19, S9-readiness-11.

**C37 — MAJOR — The new settings have no persistence map.**
Line 388 seeds three settings rows; line 490 adds five controls and a peer list.
*Fix*: enumerate every key and peer row in the v10 seed or DDL.
*Sources*: S9-readiness-12.

**C38 — MAJOR — The Gradle CI job cannot run on a fresh checkout.**
`android/settings.gradle.kts:1–8` requires `local.properties`, which is gitignored; the only existing Gradle job runs after `flutter build appbundle`.
*Fix*: state the job steps — Java 17, Flutter action, pub get, and how `flutter.sdk` is provided — before the Gradle command.
*Sources*: S9-codebase-8.

**C39 — MAJOR — Schema downgrade is asserted without a mechanism.**
Line 316 claims a downgrade loses the log but not the Records; nothing says how a v9 build handles `databaseVersion` 10.
*Fix*: state the downgrade path and add it to the failure checks.
*Sources*: S6-22.

### H. Document quality

**C40 — MAJOR — No Risks & Mitigations section, which the standard requires.**
The accepted-risks block records decisions, not failure modes. Missing: divergence detection, `sync_events` growth, watch queue drop, pending-set retention, epoch reset storm, lost destination permission, interrupted restore.
*Fix*: add the section as a table of failure mode → trigger → blast radius → mitigation → test.
*Sources*: S7-structural-1, S7-style-16, S5-23.

**C41 — MAJOR — Heading hierarchy is inconsistent.**
`Additional Resources` and `Future Improvements` are H3 under NFR; NFR uses bold pseudo-headings while the rest uses H3.
*Fix*: promote both to H2 and convert the five bold labels to H3.
*Sources*: S7-structural-2, S7-structural-3.

**C42 — MAJOR — Open Questions are already answered in the body.**
Launch-at-login (line 54) is answered at 325 and planned at 341; the second transport (line 56) is answered at 237 and 340; the fallback (line 55) is already specified at 206.
*Fix*: reduce to genuinely open items, or close the section and move each decision into the body.
*Sources*: S7-structural-4, S7-style-3.

**C43 — MAJOR — Normative constraints are stated three times with drifting wording.**
Transport rules (189–193), security NFRs (301–302), accepted risks (323–325).
*Fix*: keep the normative statement once and reduce the others to references.
*Sources*: S7-structural-6.

**C44 — MAJOR — Several terms are used before definition or never defined.**
`D1`/`D2` (line 56), "store", "retention window" (C12), "clipped"/"suppressed", `Contact` and `w/`, the eight CSV columns, "the peer consumer" (items 1–3), "the 90-day ledger" (item 13).
*Fix*: define each at first use; name the consumer and the reason for removing it; expand STT.
*Sources*: S6-2, S6-15, S6-16, S6-17, S6-18, S6-23, S6-27, S5-26.

**C45 — NIT — Smaller items.**
Counter vocabulary drifts across three lists (define once in the Apply port). The debounce value is unstated (1,000 ms). The manual-IP fallback was covered in C17. Stage 0 bundles unrelated work. The redaction switch has no goal. "Kept cheap" contradicts a coverage walk. The log has no ceiling. Two assertions are unmeasured ("a button nobody presses"; the usage pattern). Non-Goals duplicate alternatives.
*Sources*: S5-20–23, S5-26, S5-29, S7-style-6, S7-style-7, S7-style-8, S7-style-12, S7-structural-7, S7-structural-8, S6-25.

## Traceability Matrix

| Source | Findings → consolidated |
| --- | --- |
| Stage 5 (zoom out) | 1→C1 · 2→C3 · 3→C6 · 4→C4 · 5→C9 · 6→C34 · 7→C30 · 8→C31 · 9→C13 · 10→C15 · 11→C7 · 12→C18 · 13→C29 · 14→C26 · 15→C22 · 16→C7 · 17→C5 · 18→C17 · 19→C36 · 20→C45 · 21→C45 · 22→C45 · 23→C40 · 24→C17 · 25→C16 · 26→C45 · 27→C35 · 28→C35 · 29→C23 |
| Stage 6 (comprehension) | 1→C1 · 2→C44 · 3→C12 · 4→C15 · 5→C31 · 6→C25 · 7→C45 · 8→C20 · 9→C7 · 10→C16 · 11→C28 · 12→C14 · 13→C34 · 14→C27 · 15→C44 · 16→C44 · 17→C44 · 18→C44 · 19→C26 · 20→C31 · 21→C8 · 22→C39 · 23→C44 · 24→C44 · 25→C45 · 26→C3 · 27→C7 · 28→C44 · 29→C23 · 30→C44 · 31→C8 · 32→C38 |
| Stage 7 (critic) | design 1→C1 · design 2→C6 · design 3→C9 · design 4→C13 · design 5→C14 · design 6→C33 · design 7→C24 · design 8→C32 · structural 1→C40 · structural 2→C41 · structural 3→C41 · structural 4→C42 · structural 5→C12 · structural 6→C43 · structural 7→C45 · structural 8→C45 · style 1→C1 · style 2→C12 · style 3→C42 · style 4→C23 · style 5→C17 · style 6→C40 · style 7→C45 · style 8→C45 |
| Stage 8 (zoom out) | 1→C8 · 2→C2 · 3→C21 · 4→C12 · 5→C19 · 6→C25 · 7→C30 · 8→C8 (staging) |
| Stage 9 (readiness) | readiness 1→C5 · readiness 2→C8 · readiness 3→C9 · readiness 4→C20 · readiness 5→C6 · readiness 6→C2 · readiness 7→C8 · readiness 8→C10 · readiness 9→C10 · readiness 10→C35 · readiness 11→C36 · readiness 12→C37 · readiness 13→C20 · readiness 14→C34 · codebase 1→C8 · codebase 2→C8 · codebase 3→C9 · codebase 4→C5 · codebase 5→C11 · codebase 6→C20 · codebase 7→C34 · codebase 8→C38 · style 1→C10 · style 2→C35 · style 3→C36 · style 4→C37 · style 5→C45 · style 6→C35 · style 7→C14 · style 8→C45 |

## Recommended Order

1. **Settle C30 first.** If the merge is cut in favour of a queue model, C1–C8, C21, C33, and the convergence test disappear with it. Fixing them first may be wasted work.
2. **C8, C9, C2, C3, C4, C5** — make the log the only writer, store what arrives, give the Day an identity, and make derived rows deterministic. These are one design change, not six patches.
3. **C6, C12, C14, C20** — the Lap rule, pagination, snapshot verification, and the watch channel. Each is a protocol contract that tests will encode.
4. **C34, C35, C36, C37, C38** — platform decisions that block a build or a pairing flow.
5. **C40–C44** — the document structure, once the content has stopped moving.
