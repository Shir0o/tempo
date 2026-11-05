# Goldfish Annotated Review Report

**Target:** `docs/designs/multi-device-sync-and-recovery.md` (full file)
**Source:** `.scratch/time-tracker/reviews/consolidated_review_report.md`
**Status:** resolved (44 proposed fixes applied; 1 escalated — now decided: phone is the sole writer; 2 nits declined)

## Escalated (needs your knowledge, not just approval)

### C30 — Merge vs one-authority queues [`egm-zoom-out`] — Severity: High

- **Affected Scope:** lines 157–170, 60–88, 15 (`Technical Plan`, `Critical User Journeys`, `Overview`)
- **Discrepancy Description:** Five of six CUJs are single-writer, so the merge apparatus exists for one conflict case the usage model calls rare. One-authority-plus-queued-clients was never weighed, though the watch already implements it.
- **Rationale:** If the Mac is only ever used at home while the phone is present, the phone could be the single writer and the Mac a queued client, deleting the event log, merge, resolver, suppression, determinism, and convergence test.
- **AI Suggestion:** ESCALATE
- **Justification:** The counter-cost is real: the Mac could not accept a label while the phone is asleep or off the network, and the phone would need to be reachable. That is a product trade-off, not a textual fix.
- **Proposed Edit:** none until you decide. If you keep the merge, no change; if you cut it, the affected sections are the Technical Plan merge/apply, the event model, alternatives, and about 12 file entries.

## Blockers

### C1 — Merge ordering stated twice [`egm-design`, `egm-structural`, `egm-style`, `egm-zoom-out`, `egm-comprehension`] — Severity: High

- **Affected Scope:** lines 162–170 (`Merge`), line 82 (`CUJ 4`)
- **Discrepancy Description:** Claims are ordered by `(event_at, device_id, seq)` in step 3 and by span start in the paragraph below; CUJ 4's two claims both start at 09:00.
- **Rationale:** `seq` is a local insertion counter and cannot be compared across devices.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** The reviewer is right; the text is internally contradictory.
- **Proposed Edit:** Replace step 3 and the closing paragraph with one rule: claims by `(started_at_epoch_ms, event_at_epoch_ms, device_id, event_id)`; entity ops by `(event_at_epoch_ms, device_id, event_id)`; `seq` is local only. Rewrite CUJ 4's "Then" to state the winner by that key.

### C2 — A Day has no identity [`egm-zoom-out`] — Severity: High

- **Affected Scope:** lines 117–139 (`Data model`), 157–170 (`Merge`), 207 (`Backup`)
- **Discrepancy Description:** The rebuild unit is "each Day touched", but `day_key` does not exist and a Day is defined by the computing device's zone.
- **Rationale:** A phone that crosses zones makes different Days than the Mac, so CUJ 2 fails the convergence goal.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct, and it is the root of C3, C4, and C7.
- **Proposed Edit:** Add `day_start_epoch_ms` (first local midnight in the claim's zone) plus `day_timezone_id` to `record_claim`, `record_edges`, and `lap_moved`; add `day_key` to Records; rewrite merge steps 1, 4, and 6 and the coverage check to group by `day_key`.

### C3 — Derived midnight halves get random ids [`egm-zoom-out`, `egm-codebase-details`] — Severity: High

- **Affected Scope:** line 164 (`Merge` step 4)
- **Discrepancy Description:** Today's split assigns a fresh UUID per slice, so two devices cannot produce identical Records.
- **Rationale:** The property test at line 584 cannot pass.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** State that slice ids are `(claim record id, slice index)` and that synthesised Untracked spans use `(day_key, gap index)`.

### C4 — Unclaimed time never becomes Untracked [`egm-zoom-out`, `egm-implementation-readiness`] — Severity: High

- **Affected Scope:** lines 161–168 (`Merge`)
- **Discrepancy Description:** The rebuild builds Records from claims only; gaps have no owner.
- **Rationale:** Coverage is a product invariant and the verification plan asserts it.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Add merge step 6a: every unclaimed span in the Day becomes an Untracked Record with a deterministic id and the Day's zones.

### C5 — `record_delete` does not match delete [`egm-zoom-out`, `egm-implementation-readiness`, `egm-codebase-details`] — Severity: High

- **Affected Scope:** lines 152, 165 (`Event kinds`, `Merge`)
- **Discrepancy Description:** `DayRecorder.delete` clears the Activity in place and keeps the span; the event carries only id and time.
- **Rationale:** Applying it literally leaves a gap.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Remove `record_delete`; specify that delete and undo emit `record_relabel(null)` + `record_annotate(empty)` in one transaction, and that undo additionally emits the compensating claim/delete pair with its own `reason` — name the pair explicitly so the resolver can remove the claim.

### C6 — The Lap rule forbids undo [`egm-zoom-out`, `egm-design`, `egm-implementation-readiness`, `egm-style`] — Severity: High

- **Affected Scope:** lines 153, 167 (`Event kinds`, `Merge` step 7)
- **Discrepancy Description:** `lap_moved` is emitted by undo, and undo restores an earlier start, while step 7 says the Lap may never move backwards.
- **Rationale:** The two rules cannot both hold.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Replace step 7 with: the Lap start is `max(latest applicable lap_moved start, last Record end)`, computed after the Day's claims are resolved; `lap_moved` events sort by `(at, device_id)`; an undo event carries `reason: undo` and may move the start back to the surviving Record end. State which open span survives when two devices hold different starts: the later one wins, and the earlier device's span becomes Untracked if it is unclaimed.

### C7 — Edits to suppressed claims are undefined [`egm-zoom-out`, `egm-comprehension`] — Severity: High

- **Affected Scope:** lines 131–135, 155, 165 (`Data model`, `Merge`)
- **Discrepancy Description:** A relabel/annotate/edge/delete aimed at a claim clipped to nothing has no rule; `sync_suppressed` is written and never read.
- **Rationale:** The property test asserts behaviour that is not specified.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Add a rule: edits to a suppressed claim are retained and re-applied if that claim later wins time; otherwise they are recorded in `sync_suppressed` with reason `edit-of-suppressed`. Name the reader: the Day view's diagnostics and the counter.

### C8 — The log is not the only writer [`egm-zoom-out`, `egm-implementation-readiness`, `egm-codebase-details`] — Severity: High

- **Affected Scope:** line 148 (`Event kinds`), item 10, item 7, items 4–6
- **Discrepancy Description:** Import, seeding, `splitRecord`, `merge`, midnight splits, edge gaps, and entity writes outside `DayRecorder` emit nothing.
- **Rationale:** A rebuild deletes those Records or breaks coverage.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct and the largest cluster.
- **Proposed Edit:** Add an invariant: every Record and entity write emits its event in the same transaction, with no exceptions. Extend item 10 to name every write site by file; add `record_split`; state that midnight splits and edge gaps are derived output of `rebuildDay` and never logged; state that import and seeding emit `activity_upsert`/`tag_upsert`/`record_claim`; add a test that an import followed by a rebuild reproduces the imported store.

### C9 — Received events are never persisted [`egm-implementation-readiness`, `egm-design`] — Severity: High

- **Affected Scope:** lines 174–185 (`Apply port`)
- **Discrepancy Description:** The port commits without inserting the peer's events; the union, audit trail, suppressed rows, and seed all assume they are stored.
- **Rationale:** Without persistence, the union cannot be rebuilt later.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Add to the apply port: `INSERT OR IGNORE` each received event on `event_id`, preserving origin `device_id` and `event_at_epoch_ms`, assigning a fresh local `seq`, before the rebuild; define "duplicate" as an ignored insert.

### C12 — Full replay in one request livelocks [`egm-zoom-out`, `egm-comprehension`, `egm-structural`] — Severity: High

- **Affected Scope:** lines 185, 193, 559 (`Apply port`, `Transport`, item 40)
- **Discrepancy Description:** A restored device sends its whole log in one size-bounded request, and the cursor advances only on a completed apply.
- **Rationale:** The retry can never send less.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Add cursor pagination: request `{sinceSeq, limit}`, apply and commit one batch per request, advance the cursor per batch, loop to the tail. State that every full replay uses the same path and that `limit` is a fixed event count.

### C20 — Watch ack has no rejection channel or source [`egm-implementation-readiness`, `egm-codebase-details`] — Severity: High

- **Affected Scope:** lines 196–202 (`Watch protocol`), items 12–14
- **Discrepancy Description:** Only `appliedActionSeq` is added; refused actions are "acknowledged as rejected"; `WatchAction` has no sequence; the watch dequeues on dispatch.
- **Rationale:** Android invokes the handler fire-and-forget, so a return value cannot reach the watch.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Add `actionSeq` to `WatchAction` and to the Android payload; add `appliedActionSeq` and `rejectedActionIds` to the Lap payload; state the chain (watch → Android → Dart → label result → service → syncLap); remove dequeue-on-dispatch and dequeue by watermark.

### C34 — Exclusive store lock breaks MCP [`egm-zoom-out`, `egm-comprehension`, `egm-implementation-readiness`, `egm-codebase-details`] — Severity: High

- **Affected Scope:** items 20 and 22, line 111 (`Component map`)
- **Discrepancy Description:** A lifetime exclusive lock conflicts with the MCP CLI, which holds the store for its session.
- **Rationale:** `TempoMCP` never opens a store; `bin/tempo_mcp.dart` does.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Make the lock advisory and scoped to restore and fallback snapshots, recording `{pid, purpose, acquired_at}` with a staleness timeout; normal opens rely on SQLite's own locking; remove `tempo_mcp_server.dart` from item 22 and scope it to `bin/tempo_mcp.dart`.

### C35 — Dependencies and camera path unspecified [`egm-zoom-out`, `egm-implementation-readiness`, `egm-style`] — Severity: High

- **Affected Scope:** item 44, items 29–31
- **Discrepancy Description:** The plan names package categories, not packages; no camera permission or entitlement is added.
- **Rationale:** The standard forbids leaving dependency selection to the implementer.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** Correct.
- **Proposed Edit:** Name `bonsoir` (mDNS), `qr_flutter` (render), and `mobile_scanner` (scan); require the resolved versions to be pinned in `pubspec.lock`; add `android.permission.CAMERA`, `NSCameraUsageDescription`, and `com.apple.security.device.camera`; state that the Mac displays and the phone scans, with the payload format `tempo://pair?h=&p=&s=&id=`.

### C36 — Conditional placeholders [`egm-zoom-out`, `egm-implementation-readiness`] — Severity: High

- **Affected Scope:** items 49–50, `Open Questions`
- **Discrepancy Description:** Two items depend on undecided scope.
- **Rationale:** An implementer cannot execute a conditional.
- **AI Suggestion:** PROPOSE FIX
- **Justification:** The prior decision deferred launch-at-login; the fallback is already the chosen path.
- **Proposed Edit:** Delete item 49 and add "launch at login" to Non-Goals for this release; delete item 50 and state in item 23 that the fallback is the plan; remove both questions from Open Questions.

## Majors

### C10 — Migration wording and missing Lap backfill [`egm-implementation-readiness`, `egm-style`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Item 7: say "one `record_claim` **event** per existing Record" and add one `lap_moved` with the current start and zone and `reason: migration`.

### C11 — Three write paths open their own transactions [`egm-codebase-details`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Item 10: name `relabel`, `annotate`, and `delete` as needing `_db.db.transaction` with `_updateRecordInTxn` so the event lands in the same transaction.

### C13 — Two-second goal unachievable one-way [`egm-zoom-out`, `egm-design`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Restate the goal: "visible on the other device on the next exchange, which is under two seconds while a connection is open"; add "reconnect on commit" to the triggers.

### C14 — Coverage check compares wrong values [`egm-comprehension`, `egm-design`, `egm-style`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Replace with: the snapshot's `MAX(sync_events.seq)` equals the live store's, every cursor's `log_epoch` matches, and the Record-level gap/overlap check passes.

### C15 — `log_epoch` undefined [`egm-zoom-out`, `egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Define it as a UUID renewed by restore, bootstrap adoption, or any future log truncation; a peer seeing an unfamiliar value discards that cursor and replays the full log.

### C16 — One cursor column cannot show both directions [`egm-zoom-out`, `egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Rename to `peer_ack_seq` (newest of ours the peer holds) and add `received_seq` (newest of theirs we hold); diagnostics reads both.

### C17 — Pairing cannot be revoked; fallback lacks store id [`egm-zoom-out`, `egm-style`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Disconnect deletes the stored secret on both sides; include `storeId` in the typed fallback payload.

### C18 — Nonce protection duplicates idempotence [`egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Drop the nonce; keep the five-minute timestamp window and `event_id` dedupe.

### C19 — No Android execution model [`egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State foreground-only: sync and backup run while the app is open; delete the heartbeat and network-change triggers; add the accepted risk "the phone syncs only while Tempo is open"; rewrite CUJ 2's trigger.

### C21 — Watch and peer claims get different policies [`egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Route watch actions through the same resolver; reject only undecodable payloads and unknown Activities.

### C22 — Four duplicate guards [`egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** `event_id` is the only correctness guard; the watermark trims the queue; drop DataItem deletion and its ledger justification.

### C23 — "Exactly once" overclaims [`egm-style`, `egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Restate as "applied at the tap timestamp, exactly once, when it is delivered"; name the queue-cap and rejection loss paths and their user-visible signal.

### C24 — Backup keyed by reissued device id [`egm-design`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Key by `store_id`; record the writing `device_id` in the manifest; prune across device ids.

### C25 — Recovery window is the promotion interval [`egm-zoom-out`, `egm-structural`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Restate the goal as "restore loses at most one promotion interval"; promote before any destructive action and on app detach.

### C26 — Destination abstraction lacks primitives [`egm-zoom-out`, `egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add `renameAtomically` and `openRead`; state SAF's weaker copy-then-delete guarantee; move cloud detection into each implementation (mount point on macOS, provider authority on Android).

### C27 — Restore assumes a lost permission [`egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** CUJ 5 and the Backup section: the destination must be re-picked after a reinstall.

### C28 — Decision-log storage unstated [`egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Place it in `tempo.db` as `sync_log`, excluded from every snapshot and pruned at seven days; correct the privacy sentence.

### C29 — Two snapshot tiers with no stated failure [`egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Name the failures: the local tier covers a corrupted live store; the destination tier covers an erased install. Keep both.

### C31 — Bootstrap duplicates sync and cannot be exercised [`egm-zoom-out`, `egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Keep the file export, give it a Settings entry and the OS share sheet as transport (Stage 3), and state that the LAN path can also seed through paginated replay.

### C32 — Phone is a CSV single point of failure [`egm-design`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State that Mac-made Records reach the CSV on the restored phone's first exchange, and name the resulting delay.

### C33 — Clipped time is invisible on the Day [`egm-design`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Mark clipped and suppressed spans on the Day view; add a per-Day digest to the exchange and a mismatch counter.

### C37 — Settings persistence undefined [`egm-implementation-readiness`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Enumerate `backup_enabled`, `backup_destination`, `backup_generations`, `export_redact_comments`, `sync_enabled`, and a `sync_peers` table in items 7–8.

### C38 — Gradle CI job cannot run [`egm-codebase-details`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Item 48: checkout, Temurin 17, Flutter action, `flutter pub get`, write `android/local.properties` with `flutter.sdk`, then the Gradle command; macOS job builds the Debug bundle and signs-verifies `build/macos/Build/Products/Debug/tempo.app`.

### C39 — Downgrade mechanism unstated [`egm-comprehension`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** State the downgrade path: a v9 build refuses to open v10 and the user must restore; add it to failure checks.

### C40 — No Risks & Mitigations section [`egm-structural`, `egm-style`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Add the section as a table covering divergence, log growth, watch queue drop, pending-set retention, epoch reset, lost destination permission, interrupted restore, and clock skew.

### C41 — Heading hierarchy [`egm-structural`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Promote `Additional Resources` and `Future Improvements` to H2; convert the five bold NFR labels to H3.

### C42 — Open Questions already answered [`egm-structural`, `egm-style`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Remove the section; move each decision to Non-Goals, the body, or Future Improvements.

### C43 — Constraints stated three times [`egm-structural`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Keep the normative statements in Transport and NFR; reduce the accepted-risks block to one-line references.

### C44 — Undefined terms [`egm-comprehension`, `egm-zoom-out`] — Severity: Medium

- **AI Suggestion:** PROPOSE FIX
- **Proposed Edit:** Define store, clipped, suppressed, D1/D2, `Contact`, `w/`, the eight columns, the consumer and why its name is removed, and the 90-day ledger — each at first use.

## Nits

### C45 — Minor items [`egm-zoom-out`, `egm-comprehension`, `egm-structural`, `egm-style`] — Severity: Low

- **AI Suggestion:** DECLINE, except two worth fixing.
- **Proposed Edit (accepted subset):** state the 1,000 ms debounce inline; define the counter list once in the Apply port and reference it from the goal and Settings. Decline the rest: section naming, Non-Goals duplication, Stage 0 bundling, unmeasured assertions.
