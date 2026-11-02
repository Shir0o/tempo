# 04: Split at midnight

**What to build:** A Lap or Record never crosses local midnight. At 00:00 in the zone the user is in at that moment, the open Lap is closed and reopened, so each Day's totals are exact. When the app resumes after being closed across one or more midnights, the missed splits are applied.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] MidnightSplit happens at 00:00 in the current zone; a label later applies to the whole span but is stored as one Record per Day
- [ ] Resume after several days applies every missed midnight
- [ ] DST days (23h/25h) and travel days (21–27h) total their real length
- [ ] Tests at the `DayRecorder` seam with an injected clock and zone, including a DST transition and a zone change before midnight
