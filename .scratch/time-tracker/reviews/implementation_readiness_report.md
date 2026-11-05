# Stage 9 — Implementation Readiness Report

Target: `docs/designs/multi-device-sync-and-recovery.md`, lines 347–622.
Reviewers: `egm-implementation-readiness`, `egm-codebase-details`, `egm-style`. Standard: `implementation-readiness-standard.md`.

## Blockers

1. **`record_delete` cannot express what delete does.** `DayRecorder.delete` rewrites the Record as Untracked in place (`day_recorder.dart:452–468`); the event carries only id and time, and applying it literally leaves a gap. Fix: emit `record_relabel(null)` + `record_annotate(empty)`, or define the event as "keeps span, clears label".
2. **Four write paths create or rewrite Records with no event.** `splitRecord` (`history_view.dart:369`), `merge` (`:673`), automatic midnight splits (`day_recorder.dart:646–708`), and the Untracked Records from `adjustEdges` (`:216–352`). A rebuild drops or regenerates them. Fix: add `record_split`, extend `record_edges`, define midnight splits as derived output with stable ids.
3. **Received events are never persisted.** The apply port updates the Lap and commits without inserting the peer's events (lines 174–183), though the union (line 161), the audit trail (line 200), and the seed (line 532) all assume they are stored. Fix: `INSERT OR IGNORE` on `event_id` inside the same transaction, preserving origin and event time, assigning a local `seq`.
4. **No rejection channel in the watch contract.** The Lap payload gains only `appliedActionSeq` (line 413), while refused actions are "acknowledged as rejected" (line 201); Android invokes the handler fire-and-forget (`MainActivity.kt:296`). Fix: add `rejectedActionIds`, define the watermark as monotonic past rejections, remove the dequeue-on-dispatch (`WearLapRepository.kt:268, 367`).
5. **Merge step 7 is not an algorithm.** Three constraints with no conflict rule (line 167); undo requires moving backwards. Fix: state the comparison, the tiebreak, and whose open span survives.
6. **`sync_events` has no Day key**, so "the cost is bounded by one Day" (line 310) requires a full-table JSON scan. Fix: add `day_start_epoch_ms` (or a join table) with an index.
7. **Entity upserts have no emitter.** `category_upsert`, `activity_upsert`, `tag_upsert` are specified (line 398) but only `day_recorder.dart` is named as an emitter (line 403), while Activities and Tags are written from six other files. Fix: name each write site or add one repository seam.
8. **The v10 backfill creates no `lap_moved`**, so the merge's Lap rule has no input after migration (line 388).
9. **Migration wording implies a `record_claim` table** that item 7 does not create (line 388). Fix: say "one `record_claim` event per Record".
10. **Dependency selection is left to the implementer** (line 579). Fix: name packages, versions, and licences.
11. **Two stages are conditional placeholders** (items 49–50). Fix: decide launch-at-login and `minSdk` or move both to Non-Goals/Future Improvements.
12. **New settings have no persistence map** (line 490 vs line 388).

## Majors

13. **`appliedActionSeq` has no source**: not in `WatchAction`, not in the Android payload, not returned by the Dart handler (`wearable_sync_service.dart:12–26, 177–182`; `MainActivity.kt:288–297`).
14. **Item 22 misdescribes the MCP entry point.** `TempoMCP` never opens a store; `bin/tempo_mcp.dart:51` does, and holds it for the session. Fix: acquire the lock in the CLI and define who refuses.
15. **The Gradle CI job cannot run on a fresh checkout**: `android/settings.gradle.kts` requires `local.properties`, which is gitignored. Fix: state setup-java, Flutter action, and how `flutter.sdk` is provided.
16. **The QR scan path has no owner, file, or camera permission** (macOS `NSCameraUsageDescription`/entitlement, Android `CAMERA`).
17. **The coverage predicate is undefined** (lines 470, 520). Fix: name the predicate and the SQLite version threshold.
18. **Transport limits are unquantified**: request size, timeouts, backoff schedule (lines 559, 564).
19. **The event-kind count contradicts the emitter list** (line 398 vs 403). Fix: one table mapping kind → payload → emitter → test.
