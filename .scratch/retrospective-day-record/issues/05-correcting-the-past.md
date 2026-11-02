# 05: Correcting the past

**What to build:** From history you can move the Boundary between two Records, split a Record in two, merge neighbours, change a Record's Activity, and delete a Record (it becomes Untracked). Every edit keeps the Day continuous: anything that would create a gap or overlap is refused with a plain message.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] `DayRecorder` adds `relabel`, `moveBoundary`, `splitRecord`, `merge`, `delete`
- [ ] Moving a Boundary resizes both neighbours; it cannot pass a neighbour's other edge or the Lap start
- [ ] Delete turns the Record Untracked rather than removing time
- [ ] Each edit writes a Tombstone where a Record disappears, and triggers a CSV rewrite
- [ ] History UI exposes each edit; refused edits explain why
- [ ] Tests at the `DayRecorder` seam for each edit and each refusal
