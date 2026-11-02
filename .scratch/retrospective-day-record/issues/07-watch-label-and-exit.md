# 07: Watch: label and exit

**What to build:** On the Pixel Watch the complication shows the Lap's elapsed time. Tapping it, or a tile slot, labels the Lap, gives haptic and visual confirmation, and immediately finishes the Activity so the watch face returns (Action-and-Exit). The tile shows the three most-used Activities over the last 14 days. The 600ms hold-to-stop is removed. The Data Layer sync carries the Lap instead of the active timer.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Complication and tile anchor on the Lap start epoch; no polling
- [ ] Label from the watch → haptic, flash, `finish()`; the phone sees the new Record
- [ ] Tile slots = top 3 Activities by count over 14 days
- [ ] GuardedStop / hold-to-stop code removed from the wear module
- [ ] `./gradlew :wear:compileDebugKotlin` passes
