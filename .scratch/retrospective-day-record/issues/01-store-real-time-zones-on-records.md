# 01: Store real time zones on Records

**What to build:** Every Record knows the IANA zones it started and ended in, and history shows each Record in the zones it was lived in. A flight reads "08:00 LAX → 16:00 JFK · 5h 00m": durations come from UTC, never from wall-clock subtraction. Old rows that stored abbreviations ("PST") are mapped to IANA best-effort.

**Blocked by:** Shir0o/tempo#11 (CSV export time zone fix, which already writes IANA zones for new Records).

**Status:** ready-for-agent

- [ ] Records gain an end zone; every writer (state machine, MCP write tools) stores IANA start and end zones through the injected zone provider
- [ ] Existing rows: abbreviations mapped to IANA where unambiguous; end zone backfilled from start zone
- [ ] History renders start and end times in their own zones and shows both when they differ
- [ ] Duration shown equals end epoch minus start epoch (test: a 6h flight across −3h reads 6h)
- [ ] `dart analyze` clean; targeted tests for the migration and a zone-crossing Record
