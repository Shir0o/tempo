# 06: Color Blocks dashboard (design D)

**What to build:** The phone dashboard becomes design D (Color Blocks): a hatched Lap panel ("Untracked since 10:06", large elapsed time), a 00–24 strip of today's Records with marks where the zone changed, Split and "Same as last: <Activity>" buttons, a 3-column grid of Activity blocks with today's totals ("What was it? · Tap to log 10:06 → now"), and an undo bar with a 3s countdown.

Reference: design canvas https://claude.ai/artifact/V98e1anWLHDg8oQbh44db9 (board D · Color Blocks).

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Layout and colors match board D; accent `#C6F432`; Space Grotesk bundled with the app (no remote font CDN)
- [ ] Strip is chronological from 00:00, scaled to the Day's real length
- [ ] Copy stays descriptive: no goals, streaks, scores or productivity wording
- [ ] Touch targets ≥ 48dp; strip and blocks have screen-reader labels
- [ ] One widget smoke test: tapping a block labels the Lap and shows the undo bar
- [ ] 1–2 screenshots of the final state
