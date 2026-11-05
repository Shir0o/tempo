# Stage 5 — Initial Zoom Out Report

Target: `docs/designs/multi-device-sync-and-recovery.md` (full file)
Standard: `zoom-out-standard.md`
Reviewer: `egm-zoom-out`

## Blockers

1. **Merge ordering stated twice, incompatibly.** Step 3 applies claims in `(event_at, device_id, seq)` order (lines 162–163), the paragraph below says ordering is by claimed span start (line 170), and CUJ 4 (lines 78–82) depends on span start while both claims start at 09:00. Fix: one key per event class; claims by `(started_at, event_at, device_id)`, entity ops by event time; rewrite CUJ 4.
2. **Derived midnight halves get random ids.** Today's split assigns a fresh UUID per slice (`DayRecorder._slicesOf`), so the two devices cannot produce identical Records and the property test cannot pass (line 164). Fix: derive slice ids from `(claim id, slice index)`.
3. **Undo moves the Lap backwards, which the Lap rule forbids.** `lap_moved` is emitted by undo (line 153) and rule 7 says the Lap may never move backwards (line 167), while `undoLast` provably restores the previous start. Fix: define undo's Lap fact, or make step 7 a recomputation.
4. **Unclaimed time never becomes an Untracked Record in the rebuild.** Steps 1–8 build Records from claims only (lines 161–168), but coverage requires every minute to have an owner and the verification plan asserts no gaps. Fix: materialise unclaimed spans with deterministic ids.
5. **One malformed event wedges the peer.** The port rolls back the whole exchange and leaves the cursor unchanged (lines 175–185) while promising per-event rejection (lines 201, 219). Fix: separate infrastructure abort from per-event rejection, with a retry policy.
6. **An exclusive store lock breaks the shipped MCP server whenever the app is open.** Item 20 takes a lifetime exclusive lock (lines 452–455); the MCP CLI is a separate process that opens the same file today; item 22 only expects failure during restore (lines 462–465). Fix: shared read lock, exclusive only for swaps.

## Major

7. One-authority-plus-queued-clients (phone as writer, Mac like the watch) is never weighed, though it would delete the event log, merge, rebuild, and convergence tests.
8. The bootstrap export duplicates the sync path; a backfill plus full replay already converges a new Mac.
9. The two-second goal cannot be met by a one-way listener with a 30-second heartbeat.
10. `store_id`, `device_id`, and `log_epoch` carry overlapping duties, and nothing in scope ever changes `log_epoch`.
11. `sync_suppressed` persists state the rebuild can derive.
12. Nonce replay protection duplicates `event_id` idempotence.
13. Two snapshot tiers exist with no stated failure separating them.
14. `BackupDestination` lacks atomic rename and read, which the layout and restore depend on; SAF has no atomic rename.
15. A watch action is guarded by four mechanisms with no statement of which is load-bearing.
16. Edits targeting a suppressed claim have no rule, though the property test asserts one.
17. `record_delete` does not say whether coverage is preserved (the codebase clears the Activity instead).
18. Disconnect clears the cursor but not the secret, so pairing has no revocation path.

## Nits

19. The plan branches on two of the document's own open questions (items 49–50).
20. Diagnostics expose internal cursors and seven counters to users.
21. Stage 0 bundles work unrelated to sync or recovery.
22. The CSV redaction switch has no goal and no named user.
23. "Kept cheap" contradicts a coverage walk on every snapshot.
24. The manual-IP fallback cannot deliver `store_id`.
25. `sync_cursors.last_seq` has no stated direction, and one column cannot show "both cursors".
26. The log has no stated compaction ceiling.
27. The new dependencies are unnamed.
28. The SAF channel does not say why the existing picker is insufficient.
29. The watch queue cap value and drop end are unstated.
