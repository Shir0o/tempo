# 08: Retrospective Day Record & Color Blocks Dashboard

Status: ready-for-agent
Labels: ready-for-agent
Dependencies: CSV export timezone fix (branch `claude/fix-csv-export-timezone-34e2a3`, in progress)
Design: Tempo Dashboard Variations canvas, artboard **D · Color Blocks** — https://claude.ai/artifact/V98e1anWLHDg8oQbh44db9

## Problem Statement

Tempo was built as a start/pause/stop timer, which forces me to decide what I'm doing *before* I do it and to remember to start and stop. When I forget, the day has holes; when I start the wrong thing, I have to fix it. That is the productivity-timer mindset, and it isn't what I want: I want a plain, complete record of how every day went — sleep, meals, transit, errands, everything — without being coached, scored, or framed around focus or work.

Travel makes it worse. In Simple Time Tracker (the app I'm migrating from), crossing time zones corrupted my history: a 6-hour flight showed as 4 hours, and past records shifted to the wrong clock times after I landed. Tempo's current CSV export has the same class of bug.

## Solution

Tempo keeps a continuous record of each Day, midnight to midnight. An open **Lap** is always running. When something ends, I tap what it was: the Lap closes as a **Record** for that Activity and a new Lap opens immediately. There is no pause and no stop. If I can't label something yet, I **Split** it, leaving an **Untracked Record** I can label later. Every moment of the day belongs to exactly one Record or the open Lap, so corrections are made by moving a **Boundary** between neighbors.

Each Record remembers the time zones it started and ended in. Durations are always true elapsed time, and past Records always show the local clock times I actually lived — a flight reads "08:00 LAX → 16:00 JFK · 5h 00m", and a travel day is shown as 21h or 27h with the zone change marked.

The phone's home screen becomes the **Color Blocks** dashboard: a hatched grey panel showing the open Lap ("Untracked since 10:06", big elapsed time, a midnight-to-midnight strip of the day), Split and "Same as last" buttons, a 3-column grid of color blocks to label the Lap, and an undo bar after each label.

## User Stories

### Recording the day
1. As a user, I want a Lap to always be running from the end of my last Record, so that no part of my day is ever unaccounted for.
2. As a user, I want to tap an Activity to say what the time since the last label was, so that I record what happened instead of predicting it.
3. As a user, I want labeling to close the Lap and open a new one in the same instant, so that there is never a gap or overlap between Records.
4. As a user, I want a "Same as last" action, so that I can label a Lap as the previous Activity with one tap.
5. As a user, I want to Split the Lap without labeling it, so that I can mark a boundary now and decide what it was later.
6. As a user, I want unlabeled time to stay visible as Untracked Records, so that I can see which parts of the day still need a label.
7. As a user, I want to label an Untracked Record at any time, so that I can catch up on my day later.
8. As a user, I want to see how many untracked blocks today has, so that I know whether my day is complete.
9. As a user, I want a 3-second undo after every label, so that an accidental tap costs nothing.
10. As a user, I want undo to restore the Lap exactly as it was (same start), so that undoing doesn't create a gap.
11. As a user, I want to add a comment and tags when I label, so that I keep the same detail I had in Simple Time Tracker (e.g. `w/` contact markers for BNPB).
12. As a user, I want no pause or stop controls anywhere, so that the app never implies my day can be switched off.
13. As a user, I want no goals, streaks, scores, or focus/productivity language anywhere, so that Tempo describes my day without judging it.

### The day boundary
14. As a user, I want each Day to run from local midnight to local midnight, so that my days match how I think about them.
15. As a user, I want anything crossing midnight (sleep, an open Lap) to be split at 00:00 automatically, so that each Day's totals are exact.
16. As a user, I want the midnight split to use the zone I'm in when midnight happens, so that a flight across midnight is split where I actually was.
17. As a user, I want both halves of a midnight-split Record to keep the same Activity, comment, and tags, so that splitting never loses information.

### Correcting the past
18. As a user, I want to drag the Boundary between two Records, so that I can fix when something actually ended — and the neighbor adjusts with it.
19. As a user, I want to split a past Record at a chosen time, so that I can break "Errands" into "Errands" and "Meals" after the fact.
20. As a user, I want to merge two neighboring Records, so that I can undo an unnecessary split.
21. As a user, I want to change the Activity of any past Record, so that I can fix a mislabel.
22. As a user, I want the app to refuse any edit that would create a gap or overlap, so that the record stays continuous.
23. As a user, I want deleting a Record to turn it into an Untracked Record rather than a hole, so that coverage is preserved.

### Time zones and travel
24. As a user, I want every Record to store the zone it started in and the zone it ended in, so that travel doesn't corrupt my history.
25. As a user, I want past Records displayed in the zones they happened in, so that waking at 07:00 in Tokyo still reads 07:00 after I fly home.
26. As a user, I want durations computed from absolute time, so that a 6-hour flight is always 6h 00m regardless of zone changes.
27. As a user, I want a Record that crosses zones to show both ends with their zones (e.g. "08:00 LAX → 16:00 JFK"), so that I can read it at a glance.
28. As a user, I want a travel day shown as its true length (21h / 27h) with the zone change marked, so that the timeline stays truthful.
29. As a user, I want daylight-saving changes handled the same way, so that the 23h and 25h days are correct too.
30. As a user, I want time zones stored as real zone IDs (e.g. `America/Los_Angeles`), not abbreviations like "PST", so that conversions are never ambiguous.

### Color Blocks dashboard (phone)
31. As a user, I want the top panel to show the open Lap as hatched grey with "Untracked since HH:MM", so that I instantly see it's waiting for a label.
32. As a user, I want a large elapsed time for the open Lap, so that I can see how long it's been at a glance.
33. As a user, I want today's logged total in the panel header, so that I see how much of the day is labeled.
34. As a user, I want a midnight-to-midnight strip in the panel with each Record at its real time and the open Lap shown in black, so that I can see the shape of my day.
35. As a user, I want the strip to mark zone changes on travel days, so that a shorter or longer day makes sense.
36. As a user, I want Split and "Same as last: <Activity>" buttons under the timer, so that the two most common non-grid actions are one tap.
37. As a user, I want a 3-column grid of color blocks, one per Activity, each showing today's total, so that labeling is one tap and I can see where the day went.
38. As a user, I want the grid heading to say "What was it?" and the time span being labeled ("Tap to log 10:06 → now"), so that I know exactly what a tap will record.
39. As a user, I want an undo bar after labeling ("Logged Errands 08:42–10:06 · Undo · 3"), so that I can reverse a mistake within 3 seconds.
40. As a user, I want to tap the day strip to open that Day's records for editing, so that corrections are one step away.
41. As a user, I want the dashboard to update the elapsed time every second without draining battery, so that it feels live.
42. As a user, I want all touch targets to be at least 44px and text to meet contrast guidelines, so that the screen is usable one-handed and outdoors.
43. As a user, I want the accent color to be adjustable, so that the screen matches my taste.

### Other surfaces
44. As a Pixel Watch user, I want the complication to show the open Lap's elapsed time, so that I see it on my watch face.
45. As a Pixel Watch user, I want tapping the complication or a tile slot to label the Lap, buzz, and immediately return to the watch face, so that I never miss a notification.
46. As a Pixel Watch user, I want the tile's three slots to be my three most-used Activities, so that common labels need no scrolling.
47. As a Pixel Watch user, I want no hold-to-stop gesture, so that the watch interaction is a single tap.
48. As a macOS user, I want the menu bar item to show the open Lap's elapsed time, so that I see it without opening anything.
49. As a macOS user, I want number keys in the Quick Popover to label the Lap, so that labeling is keyboard-fast.
50. As an automation user, I want existing `tempo://start?activity=X` links and the Android start intent to keep working, now meaning "label the open Lap as X", so that my Tasker/Raycast setups don't break.
51. As a BNPB user, I want the CSV export to keep the exact 8-column schema, so that BNPB keeps importing without changes.
52. As a BNPB user, I want CSV times written in each Record's start zone and durations from absolute time, so that rows never shift after travel and never duplicate.
53. As a BNPB user, I want Untracked Records left out of the CSV until labeled, so that BNPB never sees rows without an activity name.
54. As an MCP user, I want tools that describe timelines, time per Activity, and comparisons across days, so that an assistant can tell me how my time was spent without judging it.
55. As an MCP user, I want write tools (label Lap, Split, move Boundary) available only with `--allow-writes`, so that assistants can't change my record by default.

### Migration
56. As an existing user, I want a running timer at upgrade time to be closed as a Record ending at upgrade time, with a new Lap opening, so that nothing in progress is lost.
57. As an existing user, I want gaps between my existing Records filled with Untracked Records, so that my history becomes continuous and I can label old gaps if I want.
58. As an existing user, I want my existing Records' durations and times unchanged by the upgrade, so that history stays trustworthy.

## Implementation Decisions

### Domain and state
- Vocabulary follows `CONTEXT.md`: Day, Activity, Record, Lap, Untracked Record, Split, Boundary, MidnightSplit, QuickLog, UndoGraceWindow. `ActiveTimer`, `GuardedStop`, and `HeartbeatCheckpoint` are retired.
- The timer state machine module is replaced by a **day recorder** module (working name `DayRecorder`). It owns all writes to Records and the Lap, serialized through the existing lock, and keeps the existing injection points (clock, ID generator, zone provider) so it is testable without a device.
- Day recorder interface (behavioral contract):
  - `lap` — the open Lap (start instant, start zone) and a listenable/stream for UI.
  - `label(activityId, {comment, tags})` — atomically closes the Lap as a Record ending now and opens a new Lap at the same instant; returns the Record and arms the UndoGraceWindow.
  - `sameAsLast()` — `label` with the most recent labeled Record's Activity.
  - `split()` — atomically closes the Lap as an Untracked Record and opens a new Lap.
  - `undoLast()` — within 3 seconds of a label/split, deletes that Record and restores the Lap to its previous start; no effect after the window.
  - `relabel(recordId, activityId | null)`, `moveBoundary(leftRecordId, newInstant)`, `splitRecord(recordId, instant)`, `merge(leftRecordId, rightRecordId)`, `delete(recordId)` (becomes Untracked).
  - Every operation rejects edits that would create a gap or overlap, or move a Boundary past a neighbor's other end.
- There is no pause, resume, stop, start-with-activity, switch, heartbeat, or crash-recovery prompt. After a reboot or battery death the Lap simply continues from its persisted start.
- MidnightSplit is applied whenever a Record or the Lap is written and spans local midnight (zone in effect at that midnight); it also runs when the app resumes after crossing midnight. Both halves copy Activity, comment, and tags.
- UndoGraceWindow default stays 3 seconds.

### Schema (one migration)
- `records`: `activity_id` becomes nullable (null = Untracked Record); add `end_timezone_id`; `timezone_id` is the start zone. Both store IANA zone IDs.
- `active_timer` is replaced by a single-row `lap` table: `started_at_epoch_ms`, `started_timezone_id`, `revision`. Pause, comment, initial tags, and heartbeat columns are dropped.
- Migration steps: (1) close any running timer as a Record ending at migration time with its Activity, comment, and tags (pause time already excluded); (2) open the Lap at that instant; (3) fill every gap between existing Records (from the earliest Record onward) with Untracked Records; (4) leave any pre-existing overlaps untouched (no data loss) — the continuity invariant is enforced for all writes from then on; (5) backfill `end_timezone_id` with `timezone_id`; (6) convert stored zone abbreviations to IANA IDs on a best-effort basis, keeping the original value when it can't be resolved.
- Tombstones apply to Records deleted via merge/undo, so peer sync doesn't resurrect them.

### Time zones
- The zone provider returns the device's IANA zone ID (not `timeZoneName` abbreviations). Durations always use UTC epoch milliseconds; display converts each end with its own stored zone.
- A Day's length is computed from local midnight to local midnight in the zones in effect, so travel and DST days can be 21–27h.

### CSV export (EcosystemExport)
- Builds on the in-progress timezone fix: 8-column Simple Time Tracker schema unchanged; `time started` and `time ended` both written in the Record's start zone; `duration` / `duration minutes` from UTC epoch arithmetic; Untracked Records omitted; atomic Write-Flush-Rename with 1,000ms debounce unchanged.

### Phone dashboard — Color Blocks (design D)
- Replaces the current dashboard view. Layout top to bottom:
  - **Lap panel** (rounded bottom corners): hatched light grey while the Lap is open; header row with date and "Xh Ym logged"; title "Untracked / since HH:MM"; very large tabular elapsed time; the day strip (00–24 labels, Records at their real positions in their Activity colors, the Lap in black, zone-change marks on travel days); a row with **Split** (outlined) and **Same as last: <Activity>** (filled, with the Activity's color dot).
  - **Grid section** on black: heading "What was it?" with "Tap to log HH:MM → now"; 3-column grid of square color blocks (Activity color, dark text) showing today's total and the Activity name.
  - **Undo bar** pinned at the bottom after a label: "Logged <Activity> HH:MM–HH:MM" and "Undo · N" countdown.
- Typography: Space Grotesk (bundled locally, not loaded from Google Fonts), tabular numerals for times. Default accent `#C6F432`, exposed in settings.
- Tapping the day strip opens the Day's records (existing history view, extended with Boundary editing). Long-pressing a block opens Activity edit.
- The elapsed display ticks once per second only while the screen is visible.

### Other surfaces
- **Wear OS**: complication shows Lap elapsed; tapping it or a tile slot opens the Activity list / labels directly, then haptic + visual confirmation + `Activity.finish()` (Action-and-Exit unchanged). Tile slots = three most-used Activities over the last 14 days. Hold-to-stop UI removed. Data Layer payload carries the Lap (start + zone) instead of the active timer.
- **macOS**: menu bar shows Lap elapsed; Quick Popover number keys call `label`; Split available from the popover.
- **DeepLinkBus**: `tempo://start?activity=X` and the existing Android start intent map to `label(X)`; add `tempo://split`. Names unchanged for backward compatibility.
- **MCP**: read tools describe Days (timeline with zones, time per Activity, untracked count, day/week comparisons); remove productivity/habit/goal wording from tool names and descriptions. Write tools (`label_lap`, `split_lap`, `move_boundary`) require `--allow-writes`. PII sanitization unchanged.
- **Stats**: time per Activity per Day/week; no goals, streaks, or scores.

## Testing Decisions

- Good tests exercise external behavior through public interfaces only: given a clock, a zone, and a sequence of operations, assert the resulting Records and Lap. No assertions on internal fields, SQL, or private helpers.
- **Primary seam — the day recorder**, driven against a real in-memory database with injected clock, ID generator, and zone provider. Covers: label/close-and-open atomicity, `sameAsLast`, Split and Untracked Records, undo inside and outside the 3s window, Boundary moves/split/merge/delete, rejection of gap/overlap edits, MidnightSplit (including across a zone change and after app resume), start/end zone capture, exact durations across DST and a 6h zone-crossing flight, Lap survival across restart, and the schema migration (running timer closed, gaps filled, overlaps preserved, abbreviations mapped). Prior art: the existing timer state machine test suite — its UTC/DST invariance and crash-recovery groups are adapted; its pause/stop/heartbeat groups are removed.
- **Secondary seam — the CSV export engine** (existing): start-zone formatting, cross-zone records, UTC durations, Untracked omission, stable output when the device zone changes. Prior art: the existing CSV export engine tests and the timezone fix's regression test.
- **Dashboard**: one smoke widget test that the Color Blocks dashboard builds with a Lap and a few Records. Visual and interaction quality is checked by a manual playtest, not automated tests. Prior art: the existing widget test.
- Per repo rules, run only the targeted test files locally; the full suite runs in CI.

## Out of Scope

- Labeling the *upcoming* Lap ahead of time (pre-labeling) — the model is retrospective only.
- Renaming the `tempo://start` scheme or Android intent action.
- Calendar overlays and direct import of Simple Time Tracker's SQLite database (still "Not yet specified" in the map).
- A 24h dial or other dashboard variants (A and B on the canvas) — only D is built.
- Weekly/monthly visualization redesigns beyond removing goal/productivity framing.
- Any cloud backend or account system.

## Further Notes

- **Open decision affecting this spec:** the CSV timezone session is waiting on how to handle legacy zone abbreviations. This spec assumes option A (store IANA IDs on new Records via a platform zone lookup; best-effort abbreviation → zone mapping for old rows). Ambiguous abbreviations ("CST", "IST") cannot be recovered exactly; the mapping must document its choice for each.
- `README.md` still describes habit logging and `[▶️ Track]`/hold-to-stop; update it when this ships.
- Sample/seed data and copy must use neutral everyday Activities (Sleep, Routine, Meals, Transit, Errands, Exercise, Reading) — never Work, Commute, focus, or productivity framing.
