# Stage 7 — Critic Review Report

Target: `docs/designs/multi-device-sync-and-recovery.md`, lines 1–346.
Reviewers: `egm-design`, `egm-structural`, `egm-style`. Standard: `feature-spec-standard.md`.

## Blockers

1. **Merge order stated twice, incompatibly.** Lines 162–163 order claims by `(event_at, device_id, seq)`; line 170 orders by span start; CUJ 4 (line 82) needs span start but both claims start at 09:00, so the tiebreak, not the rule, decides. Fix: one key, stated once; `seq` is local only.
2. **The Lap rule forbids the undo it requires.** `lap_moved` is emitted by undo (line 153) while step 7 forbids moving backwards (line 167). Fix: make step 7 a recomputation, not a monotonic guard.
3. **Records without events are destroyed by the next rebuild.** Line 159 makes a Day a pure function of events; line 316 allows a downgrade to write Records with no event; line 185 never says received events are stored. Fix: enforce "every Record has a claim", persist received events, and define the repair path.

## Majors

4. **Two-second goal unachievable** with a one-way listener and a 30-second heartbeat (lines 31, 194).
5. **Coverage check compares the wrong values.** Line 207 compares a log high-water mark to per-peer cursors; use `MAX(seq)` against `MAX(seq)` (design) and per-cursor `log_epoch` (structural).
6. **Clipped and suppressed time is invisible to the user** except as a Settings counter (lines 82, 219), reproducing the "silence" the problem statement names (line 25). Fix: mark the affected Day and exchange a per-Day digest.
7. **Backup keyed by `device_id`, which restore reissues**, so old generations become unreachable and never pruned (lines 88, 208–209).
8. **Phone is an undocumented single point of failure for the CSV** (line 215); if it is lost, Mac Records never reach the export (design). Fix: state the delay until the restored phone syncs, or add a second exporter.
9. **No Risks & Mitigations section**, required by the standard (structural).
10. **`Additional Resources` and `Future Improvements` are H3 under NFR**, not H2 (structural).
11. **NFR uses bold pseudo-headings** while the rest uses H3 (structural).
12. **Open Questions are already answered in the body** (lines 54–56 vs 325, 206, 340) (structural, style).
13. **Retention window undefined** and load-bearing (line 193) (structural, style).
14. **Normative constraints stated three times** with drifting wording (lines 189–193, 301–302, 323–325) (structural).
15. **Watch guarantee stronger than the specified behaviour.** Line 33 promises "exactly once"; line 202 drops the oldest at the cap; line 201 rejects actions (style). Fix: restate as idempotent application plus two stated loss paths.
16. **No risk mitigations or detection** for divergence, watch clock skew, or secret revocation (style).
17. **`lap_moved` "latest start" conflicts with a late-arriving earlier claim** (style, below the cut).
18. **CSV freshness in Goals conflicts with phone-only export ownership** (style, below the cut).

## Nits

19. Two assertions are unmeasured ("a button nobody presses", line 21) and the usage pattern is asserted as fact (line 15).
20. The encryption decision is stated three times (lines 285, 324, 339).
21. Terms used before definition; counter sets disagree (lines 34, 39, 219).
22. Section names diverge from the standard (Problem Statement, Proposed Architecture).
23. Non-Goals duplicate alternatives instead of referencing them (lines 43, 45, 47).
