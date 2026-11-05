# Stage 6 — Comprehension Report

Target: `docs/designs/multi-device-sync-and-recovery.md`
FeatureRange: 1–346. DetailedRange: 347–622.

## Paraphrase — Feature Range (1–346)

The phone and the Mac stop being two separate databases. Each install keeps an append-only event log inside `tempo.db`, alongside per-peer cursors and a suppressed-claim table. On the home LAN the Mac's listener and the phone's client exchange events past each other's cursor, and each device rebuilds every affected Day from the union of both logs, so the same facts produce the same Records regardless of arrival order. The watch stops being a mirror: each tap is stamped, queued, given an id and sequence, delivered later, applied at the tapped instant, acknowledged by a watermark, and de-duplicated by action id. Backup becomes automatic — a local rolling snapshot while dirty, promoted hourly and on pause to a chosen folder, five generations, hashed and checked — and restore becomes a manual, validated, store-swapping action. The whole-file Drive backup is removed; the Drive CSV upload stays on the phone. Nine alternatives are recorded, with NFRs for LAN plaintext plus HMAC pairing, rollback, and accepted risks.

## Paraphrase — Detailed Range (347–622)

Fifty numbered work items in five stages, each naming a file with its type, scope, and intended change. Stage 0 edits product docs, the glossary, the README, and the `.backup` parser so tag rows become names. Stage 1 is schema v10, the event model and accessors, `DayRecorder` event emission with a watch timestamp, a pure overlap resolver, watch sequencing and acknowledgement, and tests. Stage 2 adds `StoreLifecycle`, `BackupService`, the platform destination abstraction and native channels, settings UI, macOS and Android configuration, and removes database backup from the Drive service. Stage 3 adds a versioned store export and bootstrap. Stage 4 adds discovery, pairing, the listener, the client, the merge engine, pairing UI, and dependencies. Stage 5 hardens CI and leaves launch-at-login and `minSdk` conditional. Verification covers analysis, tests, both builds, a convergence invariant, a manual two-device matrix, and failure checks.

## Findings

1. **BLOCKER — Merge ordering specified twice, incompatibly.** Lines 162–163 vs 170; CUJ 4 at 82 cannot distinguish two claims starting at 09:00 by span start. Fix: one canonical key; `seq` is local only.
2. **MAJOR — D1 and D2 are used as if defined.** Lines 56, 265; nothing links the decisions brief. Fix: expand on first use and link.
3. **MAJOR — "Retention window" is undefined and contradicts the no-compaction stance.** Line 193 sends "the full log for the retention window"; line 343 states no ceiling. Fix: state both numbers.
4. **MAJOR — `log_epoch` is defined only as "reset guard".** Lines 128, 137, 191–193. Fix: define what it identifies and what changes it.
5. **MAJOR — Bootstrap appears in the architecture but is never explained or journeyed.** Lines 137, 527–542; no CUJ. Fix: define it and add a CUJ, or remove the reference.
6. **MAJOR — "Reproduces the store exactly" contradicts the restore procedure.** Line 34 vs 88, 211 (new `device_id`, cleared cursors). Fix: restate the goal.
7. **MAJOR — The debounce window has no value.** Lines 34, 181. Fix: state 1,000 ms inline.
8. **MAJOR — "Rejected" has no defined meaning for peer events.** Lines 39, 185, 219; only watch rejections are defined. Fix: enumerate causes and say whether the cursor advances.
9. **MAJOR — `sync_suppressed` has no stated reader.** Lines 131–135, 163, 165; test at 584 asserts undefined behaviour. Fix: define edits targeting a suppressed claim, and why the row is persisted.
10. **MAJOR — "Both cursors" cannot be mapped onto the schema.** Line 39 vs 126–129 (one `last_seq` per peer). Fix: define inbound and outbound cursors.
11. **MAJOR — The decision log's storage is unstated and collides with the snapshot.** Lines 219, 304, 208. Fix: say where it lives and what is excluded.
12. **MAJOR — The coverage check compares a high-water mark to cursors.** Line 207. Fix: compare `MAX(seq)` to `MAX(seq)`, and check `log_epoch` per cursor.
13. **MAJOR — "One owner per process" contradicts the multi-process premise.** Line 111 vs Alternative G at 276 and items 20/22. Fix: one holder across all processes, enforced by a lock file.
14. **MAJOR — Restore assumes a permission that does not survive reinstall.** CUJ 5 at 86–88; SAF permission and bookmark are lost on uninstall. Fix: add the re-pick step.
15. **MAJOR — `Contact` and `w/` are referenced but not defined.** Lines 37, 305, 376. Fix: define both where the CSV is first mentioned.
16. **MAJOR — The eight-column schema is named but never listed or linked.** Lines 37, 215, 532. Fix: list the columns and expand STT.
17. **MAJOR — "The peer consumer" is unnamed and the removal has no reason.** Lines 356, 366. Fix: name it and the reason, or reference the brief.
18. **MAJOR — "The 90-day ledger" appears once and is never explained.** Line 418. Fix: define it or delete the clause.
19. **MAJOR — Cloud-folder detection is specified by path on a platform that returns handles.** Lines 210, 475, 515. Fix: detect per platform, inside the implementation.
20. **MAJOR — Stage 3 has no transport and no entry point.** Lines 527–542 vs the stage contract at 349 and Settings at 490. Fix: add a share-sheet path or move the stage after Stage 4.
21. **MAJOR — Four modules claim the same merge responsibility.** Lines 174–185, 403, 405–408, 566–569. Fix: state which module owns which numbered step.
22. **MAJOR — Schema downgrade is asserted without a mechanism.** Line 316. Fix: state what a v9 build does with a v10 file.
23. **NIT — "Store" is used as a synonym for the database without a definition.** Define it once including `-wal` and `-shm`.
24. **NIT — Local symbols are used before they are introduced.** Mark new components at first mention; define `_synchronized` and `adjustEdges`.
25. **NIT — Counter vocabulary drifts between three lists.** Define once in the Apply port.
26. **NIT — "The zone the claim was lived in" is ambiguous for a cross-zone claim.** Say the start zone decides the split.
27. **NIT — "Clipped" and "suppressed" are used before definition.** Add the two-line glossary.
28. **NIT — `.backup` never names its format.** Say "Simple Time Tracker `.backup` file".
29. **NIT — Old-phone compatibility is asserted as "its current behaviour".** State the outcome.
30. **NIT — The "Edge, not Boundary" rule has no stated reason.** Add one clause.
31. **NIT — Tag reuse has no identity rule.** State case-insensitive name match within the store.
32. **NIT — The CI signature check names no bundle.** Name the artifact path.
