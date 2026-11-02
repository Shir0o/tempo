# 02: An always-running Lap you label afterwards

**What to build:** There is always an open Lap. Tapping an Activity on the phone dashboard labels the Lap that just ended, closes it as a Record and opens a new Lap in one atomic step. "Same as last" labels it with the previous Record's Activity. Pause and stop disappear from the phone. Other callers (watch, macOS, deep links, MCP) keep working through thin mappings: start → label, stop → split, pause → removed, so CI stays green.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] A single-row `lap` table (started_at_epoch_ms, started_timezone_id, revision) replaces `active_timer`
- [ ] Upgrade migration closes a running timer as a Record and opens the Lap at its end
- [ ] `DayRecorder` exposes a lap stream, `label(activityId, {comment, tags})` and `sameAsLast()`; clock, ID and zone are injected
- [ ] Phone dashboard tap labels the Lap; pause/stop controls removed
- [ ] Old entry points delegate to `DayRecorder` via the mappings above
- [ ] Tests at the `DayRecorder` seam with an in-memory DB: label closes exactly `[lapStart, now)` and the new Lap starts at `now`
