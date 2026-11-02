# 10: Remove the old timer model

**What to build:** With every caller on `DayRecorder`, delete what's left of the old model: pause/resume, stop, HeartbeatCheckpoint, the crash-recovery prompt, `ActiveTimer`, and the start→label / stop→split shims from 02. Rewrite the README to describe Tempo as a plain whole-day record.

**Blocked by:** 06, 07, 08, 09

**Status:** ready-for-agent

- [ ] No references to pause, stop, heartbeat or `ActiveTimer` remain outside migrations
- [ ] Migration code that reads the old `active_timer` table is kept so old installs still upgrade
- [ ] README matches PRODUCT.md and CONTEXT.md vocabulary
- [ ] `dart analyze` clean; Android and Wear compile
