# 03: Split, Untracked Records and undo

**What to build:** Split closes the Lap as an Untracked Record (no Activity) and opens a new Lap. A label or split can be undone within the 3s UndoGraceWindow, restoring the previous Lap exactly. History shows Untracked Records hatched and lets you label them. The CSV export leaves Untracked Records out until they are labeled.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] `records.activity_id` becomes nullable; `DayRecorder.split()` and `undoLast()` added
- [ ] Undo after 3s is refused; undo within 3s restores the Lap start and removes the Record
- [ ] Upgrade migration fills gaps between existing Records with Untracked Records; existing overlaps are kept as-is
- [ ] History renders Untracked Records hatched; tapping one lets you pick an Activity (`relabel`)
- [ ] CSV export omits Untracked Records; labeling one makes it appear on the next debounced write
- [ ] Tests at the `DayRecorder` seam (split, undo window, gap fill) and the CSV engine seam
