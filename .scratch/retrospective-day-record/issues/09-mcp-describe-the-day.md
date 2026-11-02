# 09: MCP: describe the day

**What to build:** The local MCP server describes the day plainly: a Day's timeline, time per Activity over a range, count and length of Untracked Records, and comparisons between Days. With `--allow-writes`, write tools `label_lap`, `split_lap` and `move_boundary` go through `DayRecorder`. Productivity, focus and goal wording is removed from tool names, descriptions and output.

**Blocked by:** 03, 05

**Status:** ready-for-agent

- [ ] Read tools return times in each Record's lived zones; durations from UTC
- [ ] Write tools absent unless launched with `--allow-writes`; they keep the Day continuous
- [ ] PIISanitizer still masks `w/` / `with ` contacts with stable `[Contact-N]` pseudonyms
- [ ] No evaluative wording in any tool description or output
- [ ] Targeted tests for the new tools against an in-memory DB
