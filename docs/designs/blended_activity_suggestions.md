# Blended Activity Suggestions

* **Author:** twang
* **Status:** In Review
* **Date:** 2026-11-14

--------------------------------------------------------------------------------

## Problem

The Today suggestions missed routines that are obvious from history:

- **Grooming** almost always follows Morning time or Bible reading, yet it was
  picked from the grid by hand.
- **Commute** happens most Thursdays between 08:00 and 08:30, usually after
  Grooming or Breakfast, yet it was picked from the grid by hand.

The engine in [decayed_markov_2_activity_suggestions.md](decayed_markov_2_activity_suggestions.md)
ranks in strict tiers: Markov-2, then Markov-1, then a ±1 hour slot on weekday
versus weekend, then frequency. Three things follow from that.

1. Any sequence evidence beats any time evidence, so an Activity strong on
   both cannot beat one that only follows more often.
2. Time knows weekday versus weekend, not the day of the week, so "Thursday at
   08:00" looks like every weekday at 08:00.
3. The target is the moment the app is opened, not the moment being labeled.
   Labeling after the fact scores the wrong hour.

The pinned Activity also took one of the four chips, so learned picks had
three.

## Design

### Ranking

Each candidate gets three shares, each its decayed score over the decayed mass
of everything the signal saw (0 to 1):

- **Sequence.** Markov-1 share, interpolated 7:3 with the Markov-2 share when
  the pair is established (same gates as before: two observations, one unit of
  mass, the candidate holding a tenth of the pair). When the target's day of
  the week has its own Markov-1 transitions (two observations, one unit of
  mass), the result is averaged with the share on that day alone, because a
  routine can differ by day: after Breakfast, Commute on Thursdays and Work
  otherwise.
- **Time.** Share of starts within 60 minutes of the target's local time on
  weekday versus weekend. When the target's day of the week has its own slot
  history (same two gates), it is averaged with the share on that day alone.
- **Frequency.** Overall share.

The score is `10 × sequence + 8 × time + 1 × frequency`, in integer
micro-units; ties keep the candidate order. Sequence weighs a little more, so
in a pure conflict it still wins, but an Activity strong on both wins over one
strong on either.

The preceding Activity scores zero. Runs collapse a repeated label, so the
next run is never that Activity, and Still / Again (Repeat on the
notification and watch) already offer it in one tap.

The 14-day half-life, 60-day window, run collapsing, Untracked chain breaks and
MidnightSplit handling are unchanged.

### Target moment

`loadSuggestions` and the new `loadRankedSuggestions` take a `targetEpochMs`.
The Dashboard, notification and Wear tile pass the open Lap's start, so the
time signal scores the hour being labeled. History is still read up to now.

### Reasons

`rankExplained` returns each Activity with the signal that carried most of its
score: `after` (the preceding Activity), `weekday` (day of the week and typical
start, rounded to five minutes), `dayGroup` (weekdays or weekends and typical
start) or `frequent`. The Dashboard shows it as one line under the chip:
"After Breakfast", "Thursdays ~08:05", "Weekdays ~07:30", "Often".

### Today layout

Chosen from the canvas mock-ups (option A):

- **SUGGESTED**: four learned chips, two per row, each with its reason.
  Pinned Activities are left out of the ranking here.
- **PINNED**: the user's pins in a row of their own, as outlined pills.

The notification chips and the Wear tile keep pinned Activities first, as
before.

## Not changed

- The History relabel picker still ranks by time of day only.
- Google Calendar is not read. The calendar held no routine events, so the
  logged history is the stronger signal.
