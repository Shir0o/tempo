# Suggestion Feedback

* **Status:** In Review
* **Date:** 2026-11-20

--------------------------------------------------------------------------------

## Problem

The Today suggestions learn only from what was logged. There is no way to say
"that was a good pick" or "not that, not now", so a wrong pick keeps coming
back at the same moment until history outweighs it.

## What the user does

- **Tap a suggestion:** labels the Lap with the Tags that suggestion usually
  carries. Tempo remembers what it suggested, so later edits to that Record
  count as feedback (below).
- **"Good suggestion?" bar:** after logging from a suggestion (SUGGESTED or
  WITH NOTE), a bar with 👍 and 👎 shows above the undo bar for 8 seconds. No
  answer is no feedback.
- **Long-press a suggestion:** on a SUGGESTED or a WITH NOTE chip, a sheet
  offers *Add a note first* (*Edit the note first* on a note, which opens
  with its note), *Good suggestion* and *Not useful here*. A vote on a note
  is kept with its People, like every other vote on it. Not useful hides the
  chip until the Lap changes. Logging from the note sheet here counts as
  logging from the suggestion: the rating bar shows, and what was changed
  in the note counts as an edit.
- **Rate it later:** a Record logged from a suggestion shows *Suggested by
  Tempo* with *Good suggestion* and *Not useful* in its History edit sheet.
  A tap counts at once (not on Save) and tapping it again takes it back. It
  is the same rating the "Good suggestion?" bar gives, so a later one
  replaces it.
- **Pass it over:** suggestions shown on Today when a Lap is labeled some
  other way count as passed over, and one passed over many times ranks
  slowly lower (below).
- **Settings → Suggestion feedback:** shows how many votes are kept and resets
  them, with the passed-over counts.

## Edits as quiet feedback

A label made from a suggestion is stored as a `logged` entry with its Record
id and the note and Tags it was given. Each time suggestions are ranked, the
entry is read against what that Record holds now:

| What the Record shows now | Vote |
| --- | --- |
| Undone or deleted | nothing |
| Another Activity | not useful for the Activity (and its note) |
| Same Activity | light vote (¼) for the Activity |
| Note: same reading and People | good for the note |
| Note: same reading, other People | light vote for the note |
| Note: reading rewritten | not useful for the note |

A rating the user gives on purpose (the bar, or the History edit sheet) is
kept with the Record id and stands in for what the edits say; Tag edits still
count.

A note suggestion is keyed by its Activity and People. Its votes do not touch
the Activity's own ranking; on Today they reorder the WITH NOTE row and leave
out a note with about one fresh rejection at a similar moment.

## Learned Tags

A suggestion fills in the Tags on at least half of the Activity's last four
Records (for a note, those naming the same first Person). The Contact Tag
follows the note's People as before. Tag edits after logging are Tag feedback
for that Activity: a suggested Tag removed counts −1, one added +1, one kept
+¼, fading on the same half-life. At a net of half a fresh vote, feedback
drops a Tag history would fill in (the Contact Tag included) or adds one it
would not.

Every other label fills in the same Tags the same way: an Activity block, a
pin or the filter on Today (stored as a `tagged` entry, so its Tag edits
count too but it is no vote on the Activity), *Add a note first* (the note
sheet opens with them), and a chip on the notification or the watch.

## Passed over

When a Lap is labeled on Today, each suggestion on screen (SUGGESTED and WITH
NOTE) that was not the one tapped counts as passed over once. The one tapped
starts again from zero; if its Activity was logged another way, its count is
halved. Counts fade on the 14-day half-life and live under
`suggestion_ignored` in `settings`, one per suggestion.

The first three times change nothing. After that each time divides the score
by 15% more, at most three times lower, so a pick shown all day and never
taken sinks, falls off the screen, and can come back once the count fades. A
WITH NOTE suggestion sinks among the notes by a quarter vote per time, never
enough on its own to leave it out.

## How a vote is kept

Each vote is stored with the moment it was about: the Activity, the vote, when
it was given, the open Lap's start and its zone, and the Activity before it.
Votes live in the `settings` table as one JSON list under
`suggestion_feedback`, like `today_activity_order`. No schema change. They stay
on the device: not synced and not exported.
Votes older than the 60-day history window are dropped on the next write, and
at most 800 are kept.

## How a vote changes the ranking

`ContextualSuggestionEngine.rankExplained` takes the votes alongside history.
For each candidate it sums its votes:

```
vote      = +1 good, -1 not useful, +1/4 light
weight    = vote × decay(age) × similarity²
similarity = ½ [same preceding Activity]
           + ½ closeness of the time of day (within ±60 min, full at the
               same minute, half at the edge) × day factor
day factor = 1 same day of the week, ½ same kind (weekday or weekend),
             ¼ otherwise
```

Decay is the history's 14-day half-life. Squaring the similarity keeps a vote
local: full weight in the same situation, a quarter where half of it matches.

The net then scales the blended score:

- **Net good:** `score × (1 + net / 2)`, at most double, so liked picks rise
  but cannot overturn a strong routine.
- **Net not useful:** `score / (1 + 20 × net)`, so one fresh vote in the same
  situation drops even a routine's usual next step.

Equal scores (often zero) are ordered by net feedback, so a disliked Activity
with no history sinks below ones nobody voted on.

The preceding Activity is never suggested next, so votes on it are ignored.
Reasons under the chips are unchanged.

Every surface ranks through `loadRankedSuggestions`, so the notification chips
and the watch tile follow the same votes as Today. Votes are given on Today
only.
