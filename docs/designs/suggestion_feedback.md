# Suggestion Feedback

* **Status:** In Review
* **Date:** 2026-11-20

--------------------------------------------------------------------------------

## Problem

The Today suggestions learn only from what was logged. There is no way to say
"that was a good pick" or "not that, not now", so a wrong pick keeps coming
back at the same moment until history outweighs it.

## What the user does

- **Tap a suggestion:** labels the Lap as before, and counts as a light vote
  for it at that moment.
- **Long-press a suggestion:** a sheet offers *Add a note first*, *Good
  suggestion* and *Not useful here*. Not useful hides the chip until the Lap
  changes.
- **Settings → Suggestion feedback:** shows how many votes are kept and resets
  them.

## How a vote is kept

Each vote is stored with the moment it was about: the Activity, the vote, when
it was given, the open Lap's start and its zone, and the Activity before it.
Votes live in the `settings` table as one JSON list under
`suggestion_feedback`, like `today_activity_order`. No schema change. They stay
on the device: not synced and not exported.
Votes older than the 60-day history window are dropped on the next write, and
at most 500 are kept.

## How a vote changes the ranking

`ContextualSuggestionEngine.rankExplained` takes the votes alongside history.
For each candidate it sums its votes:

```
vote      = +1 good, -1 not useful, +1/4 tap
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
