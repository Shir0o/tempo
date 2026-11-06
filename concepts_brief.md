# Decayed Markov-2 Activity Suggestions

* **Author:** twang
* **Date:** 2026-11-05

## Overview

Tempo currently ranks the next Activity with flat counts: Markov-1 transitions, a
±1 hour temporal slot on weekday versus weekend, and overall frequency. Three
problems follow. Every Record counts the same no matter how old it is, the
ranking only sees the single Activity that came immediately before, and the
30-day history cutoff drops patterns abruptly. Two of the three callers actually
use a 14-day window, so the cliff arrives even sooner on the watch tile and the
notification chips.

The locked concept replaces flat counts with a 14-day half-life decay, adds
Markov-2 with backoff to Markov-1, and widens history to 60 days. Execution stays
pure, deterministic, offline, and dependency-free, with a target under 2 ms.

The Goldfish review found the concept implementable but not yet safe to code.
Midnight-split Records fabricate a repeated Activity, the caller-supplied
context can disagree with the history chain, "skip untracked gaps" can invent
adjacency across unlabeled hours, and the 2 ms budget is not proven at the new
volume. This brief keeps the locked intent and records the revisions that close
those gaps.

## Implementation Status

Implemented on 2026-11-05:

- `ContextualSuggestionEngine` now uses decayed integer micro-weights, run-based
  adjacency, Markov-2 with a pair-level gate and a 10% candidate share,
  Markov-1 backoff, and decayed temporal and frequency tiers.
- The shared `loadSuggestions` path reads a three-column
  `SuggestionObservation` history, skips tag hydration, caps at 12,000 rows,
  excludes future-dated Records, and derives both preceding ids from the same
  snapshot.
- The separate last-two-Record query, the shared 14-day `tileActivityWindow`, and
  the dead `activity_ranking.dart` helper are removed.
- `flutter analyze` reports no issues, and 45 targeted tests pass.
- The engine measured about 1.6 ms for 6,000 observations with non-UTC zones in
  the test runtime, inside the 2 ms target. The CI regression bound is 5 ms.

Remaining risk: the 60-day history read runs on every Lap change on the
notification and watch paths. The engine budget is met and the read is bounded,
but its end-to-end p95 has not been measured on device.

## Analysis

> The blockers below are kept as the review record. Each was addressed by the
> implementation described above; the open decisions were resolved before coding.

### What survives review

- **Decay is the right fix for the cliff.** A half-life of 14 days with a
  60-day window gives today a weight of 1.0, the half-life 0.5, and the window
  edge about 0.05. The 60-day window is not arbitrary: a daily sequence accumulates
  about 19.7 weight over 60 days, and the remaining tail adds little.
- **Markov-2 is the right no-LLM tool for routine context.** The distinction
  between `Gym → Shower → Dinner` and `Sleep → Shower → Commute` is real, and a
  trigram is the smallest model that can represent it. An on-device model or a
  remote API would add cost, battery use, latency, and non-determinism for a
  problem that integer arithmetic already solves.
- **A context gate is necessary.** Per-candidate tiering lets one stray
  three-step event outrank a daily two-step pattern. Gating on the pair is the
  difference between a routine and a coincidence.
- **Integer scores are the right representation.** Quantizing each weight once
  removes cross-platform floating-point drift and makes the final index
  tie-breaker exact rather than "usually exact."
- **The existing hierarchy is preserved.** Archived filtering, the temporal
  slot, the frequency fallback, and the stable candidate-index tie-breaker all
  stay. This is an upgrade of the scoring inputs, not a new engine.

### Blockers

1. **Midnight splits fake a repeated Activity.** Tempo splits anything crossing
   midnight into two Records with the same `activityId` (`record.dart:27-30`,
   `suggestion_engine_test.dart:228-274`). A night of sleep therefore produces
   `Sleep → Sleep` and a `(Sleep, Sleep) → Breakfast` trigram. The pair
   `(Sleep, Sleep)` is an artifact users can never mean, yet a single real night
   can satisfy the `≥ 2 occurrences` gate once the split halves are counted
   separately. The chain must collapse consecutive equal Activity ids into one
   run before counting transitions. The query context must then come from the
   last two *runs*, not the last two Records. This also applies to a user who
   labels the same Activity twice in a row with no intervening Activity.

2. **The context has two sources of truth.** The locked design has callers fetch
   the last two tracked Records with `ended_at DESC`, while the engine builds
   its chain from a separate `started_at ASC` history query
   (`dashboard_view.dart:193-207`, `wearable_sync_service.dart:141-153`,
   `lap_notification_service.dart:155-163`). A commit between the two awaits, an
   edit that moves a Boundary, a zero-length Record, or a MidnightSplit can make
   the supplied pair disagree with the chain tail. The trigram tier then either
   fires on the wrong context or never fires, with no visible symptom. Both ids
   must be derived from the same history snapshot in one place.

3. **Untracked gaps are being treated as adjacency.** The locked assumption
   skips `activityId == null` rows, so `A, null, B` contributes `A → B`. That
   can fabricate a routine across a 20-hour unlabeled hole or a night. Tempo
   treats an Untracked Record as a first-class part of the Day in `CONTEXT.md`,
   so a gap is positive evidence that the sequence is unknown, not evidence that
   the two labeled Activities were adjacent. The domain-safe rule is: skip
   untracked rows when finding the query context, but break the training chain
   at a gap rather than bridging it.

4. **Context mass and candidate score were conflated.** The gate needs the
   pair's total decayed mass across *every* outcome, including archived and
   non-candidate Activities. The ranking may only score current candidates.
   Implemented inside the existing candidate-guarded loop
   (`suggestion_engine.dart:53-103`), the gate would be permanently
   under-counted and every Markov-2 test would fail for a non-obvious reason.
   The engine needs two named accumulators: `contextMass` for the pair, which is
   outcome-agnostic, and `trigramScore`/`bigramScore` per candidate, which are
   candidate-only. A pair can be established and still have zero candidate
   trigram evidence; in that case the comparator falls through to Markov-1
   normally. That fallthrough is intended and must be tested.

5. **Chain order is an unenforced invariant.** Markov-2 is order-dependent, but
   `rank` accepts an unordered `Iterable<Record>` (`suggestion_engine.dart:15`).
   All three callers happen to order by `started_at_epoch_ms ASC`, but none adds
   a `rowid` tie-breaker. Midnight splits and zero-length Records share
   timestamps, so SQLite may return them in either order. Determinism then
   depends on the database, not the engine. All history queries must use
   `started_at_epoch_ms ASC, rowid ASC`, and the contract must be documented on
   `rank`.

6. **The performance budget is unproven and internally inconsistent.** The
   existing test allows 3,000 µs for 2,000 Records
   (`suggestion_engine_test.dart:311-351`) while calling the result
   "sub-millisecond." The new target of 2 ms for 6,000 Records is 0.33 µs per
   Record, a 4.5× improvement while adding work. The dominant existing cost is
   `wallClockAt` (`timezone_id.dart:87-108`), which resolves an IANA location per
   candidate Record, not the decay arithmetic. A whole-day weight table removes
   `pow` from the loop and makes the decay cost trivial, but the 2 ms claim still
   has to be measured on device. The 60-day `getRecords` call is likely more
   expensive than the ranking itself and runs on every Lap change on the watch
   and notification paths.

### Major findings

- **The gate means "at least two completed trigram observations, recent
  enough."** The pair at the tail of history has no following Record, so its own
  occurrence is not counted. Two completed outcomes plus the current pair means
  the pair has appeared at least three times in total. `≥ 1,000,000` micros is
  exactly one fresh observation, so two occurrences at the 14-day half-life
  exactly meet it; two at 21 days score 0.71 and fail. This is coherent, but it
  must be stated in those terms, not as a precise-looking literal.
- **The window constant is misplaced.** `dashboard_view.dart:203` hardcodes 30
  days, `wearable_sync_service.dart:52` defines a 14-day
  `tileActivityWindow`, and `lap_notification_service.dart:153` imports the
  wearable constant for notification chips. The window is engine policy, not a
  wearable detail. Put one constant on the engine and have all three callers
  read it.
- **The 60-day query is a product cost, not a detail.** The watch tile and the
  notification chips recompute on every Lap change. A fourfold increase in rows
  runs before the heads-up notification is posted, against the Action-and-Exit
  rule. Measure `publish()` end to end; if it regresses, the fix belongs in the
  query or a cache, not in a smaller window hidden from the engine.
- **Existing call-site tests encode 14 days.**
  `wearable_sync_service_test.dart:146,184` asserts a 14-day tile window and
  exact chip order; `lap_notification_service_test.dart` has matching
  expectations. Those tests will either fail or silently stop guarding the
  window. They must be rewritten for 60 days and for decayed ordering, and the
  Dashboard, which has no suggestion test today, needs one.
- **Future-dated Records are not handled.** Clamping age at zero gives a
  corrupted or clock-skewed Record the maximum weight of 1.0. A Record that
  starts after `targetEpochMs` is not evidence about the past and should be
  excluded from the chain and the sums, not clamped into first place.
- **Temporal and frequency are fallbacks, not competitors.** With exact integer
  scores, temporal and frequency decide only when bigram and trigram scores tie,
  which is the intended hierarchy. The concern that decay makes them unreachable
  is overstated: they are reachable whenever the higher tiers have no evidence
  for a candidate, which is the case they exist for.
- **Documentation will drift.** `docs/designs/smart_activity_suggestion.md`
  still describes Markov-1 and a 30-day window; `README.md:25` promises
  "three most-used Activities of the last 14 days"; the class comment on
  `ContextualSuggestionEngine` still lists a three-tier Markov-1 model. Update
  all three, plus `CONTEXT.md` if the untracked-gap rule changes.

### Smaller findings

- Deleted Activities are tombstoned but their Record rows remain
  (`tempo_database.dart:303-339`), so they can contribute phantom context mass.
  The gate's outcome-agnostic counting makes this visible. Decide whether to
  exclude tombstoned Activity ids or accept the phantom mass.
- The desktop quick popover keeps its own recency list
  (`desktop/ui/quick_popover_view.dart:193-209`) and will not follow this
  engine. Out of scope, but the divergence should be stated.
- Rotating shifts and travel are not modeled by Markov-2 or by a weekday/weekend
  slot. The 60-day window makes a trip more likely to be in view. This is a
  known limitation of the approach, not a defect in this change.
- The gate could compare pair mass against the pair's base rate instead of a raw
  threshold. That is more statistically defensible and materially more complex.
  Deferred until real replay data shows the simple gate failing.
- A debug-only tier or reason would make "why did the order change"
  answerable without a debugger. Deferred unless the tests cannot pin the
  behavior.

## Goals vs. Non-Goals

### In scope

- Decayed weights with a 14-day half-life and a 60-day history window.
- Markov-2 trigram scoring with a context gate and backoff to Markov-1.
- Decayed temporal-slot and frequency fallbacks.
- Run-collapsed chains so MidnightSplits and repeated labels do not fabricate
  transitions.
- One history snapshot per caller, with both preceding ids derived from it.
- One engine-owned history-window constant consumed by the Dashboard, the
  notification service, and the wearable sync service.
- Exact integer scoring with the existing stable index tie-breaker.
- Unit coverage for decay, context disambiguation, backoff, run collapsing,
  untracked gaps, future Records, window edges, tie-breaking, and 6,000-Record
  performance.
- Updated call-site tests and documentation.

### Out of scope

- On-device or remote LLM inference, embeddings, or any API call.
- New dependencies.
- Database schema changes, migrations, or cached aggregates.
- Markov-3 or longer n-grams.
- Weekday/weekend-conditioned transitions beyond the existing temporal slot.
- Rotating-shift or travel-aware models.
- Changes to the Dashboard, notification, or watch UI beyond the window
  constant and the ordering that follows from the new scores.
- The desktop quick popover's separate recency list.

## Alternatives Weighed

- **Per-candidate trigram gate.** Rejected. A single stray `(A, B) → D` event
  would outrank a daily `B → C` pattern, which is the exact failure the gate
  exists to prevent.
- **Weighted blend instead of tiers (`score = trigram * k + bigram`).**
  Rejected for now. It needs a tuning constant with no evidence, abandons the
  requested tier order, and makes the reason for a suggestion harder to explain.
  It is the fallback if the gate proves too brittle in replay.
- **Raw floating-point weights with an epsilon comparison.** Rejected. Equal
  sums can still differ by an ulp depending on platform and accumulation order.
  A whole-day integer table is deterministic, cheaper, and easier to test.
- **Per-record weights with `pow` in the loop.** Rejected. A 61-entry table
  indexed by whole days removes the call, removes the platform-sensitive
  boundary, and keeps the promised half-life values exactly.
- **Keeping the last-two-Record query and trusting it to match history.**
  Rejected. It adds a second source of truth and a race for no benefit; the
  history snapshot already contains the tail.
- **Bridging untracked gaps.** Rejected. It invents adjacency across unknown
  time and contradicts the domain model. Skipping untracked rows when finding
  the context, while breaking the training chain, preserves the useful part
  without fabricating evidence.
- **Keeping the 30-day Dashboard window and the 14-day tile window.**
  Rejected. Both create the cliff the change exists to remove, and the split
  between them is arbitrary.
- **An on-device model or remote API.** Rejected. It cannot meet the offline,
  deterministic, zero-cost, zero-battery constraints, and the routine problem
  does not need it.
- **Shipping decay first and Markov-2 later.** Considered. The two changes touch
  the same loop and the same tests; splitting them would double the call-site
  churn. Keep them together, but stage engine, callers, and verification as
  separate commits.

## Key Decisions & Staging for Next Steps

### Revised engine behavior

1. **History contract.** `rank` requires history ascending by
   `started_at_epoch_ms`, then insertion order. Every caller query adds
   `rowid ASC`. The engine documents the contract and does not sort.
2. **Runs, not Records, define adjacency.** Walk the history once and collapse
   consecutive Records with the same non-null `activityId` into a run. Count
   transitions between runs. The last two runs supply the query context. A run's
   temporal slot uses the start of its first Record.
3. **Untracked rows.** Do not emit a transition into or out of a null Activity,
   and do not bridge across one. Skip nulls only when finding the last known
   runs for the query context.
4. **Weight table.** `ageDays = (targetEpochMs - startedAtEpochMs) ~/ 86400000`.
   Exclude Records with `startedAtEpochMs > targetEpochMs` or an age beyond 60
   days; both contribute weight 0. `wMicros = _weightMicrosByDay[ageDays]` for
   0..60, generated once from `pow(0.5, day / 14.0) * 1000000`. One lookup per
   record.
5. **Accumulators.** `frequencyScore`, `temporalScore`, `bigramScore`,
   `trigramScore`, and `contextMass`. The first four are candidate-only;
   `contextMass` counts every outcome of the query pair. A pair can activate the
   trigram tier with zero candidate trigram evidence; the comparator falls
   through.
6. **Gate.** The query pair must have at least two completed trigram
   observations and at least 1,000,000 micros of `contextMass`. Otherwise the
   whole list backs off to Markov-1.
7. **Comparator.** When the trigram tier is active: trigram, then bigram, then
   temporal, then frequency, then the candidate's original index. When inactive:
   bigram, temporal, frequency, index. Zero and absent scores are treated
   identically.
8. **Constants and docs.** Name the half-life, window, micros-per-unit,
   minimum-occurrence, and minimum-mass constants. Update the class comment and
   `docs/designs/smart_activity_suggestion.md`.

### Caller changes

- Add `ContextualSuggestionEngine.contextFromHistory(history)` or an equivalent
  shared helper that returns the last two run ids after the untracked and
  duplicate rules. All three callers use it on the history snapshot they already
  fetched; the separate last-two query is deleted.
- Move the 60-day window to the engine. `DashboardView` reads it instead of the
  hardcoded 30 days; `LapNotificationService` and `WearableSyncService` stop
  sharing `tileActivityWindow` for this purpose.
- Keep `precedingActivityId` and `secondPrecedingActivityId` as optional named
  parameters so tests and future callers can supply an explicit context. The
  production path derives them from history.
- Update `README.md:25`, the design doc, and the call-site tests. Add a Dashboard
  suggestion test.

### Verification

- Engine tests: 14-day half-life; recent pattern beats older-but-more-frequent
  pattern; `Gym → Shower → Dinner` versus `Sleep → Shower → Commute`; unseen-pair
  backoff; stale trigram loses to a strong bigram; gate inactive at one
  occurrence; gate active at two completed observations; pair active with zero
  candidate evidence falls through; MidnightSplit collapse; repeated-label
  collapse; untracked gap does not bridge; future Record excluded; window-edge
  Record; equal scores preserve candidate order; archived filtering; 6,000-Record
  performance with a generous CI bound.
- Call-site tests: 60-day window, decayed chip order, no extra last-two query,
  and the watch/notification paths still produce a full chip set.
- On-device measurement: `rank` on 6,000 Records in release, and `publish()` /
  `_loadData()` end to end. Record the numbers. Do not repeat the "under 2 ms"
  claim until they exist.

### Resolved decisions

1. **Untracked gaps:** break the training chain at a gap; skip untracked rows
   only when finding the query context.
2. **Context source:** derive both ids from the same history snapshot; delete
   the separate last-two-Record query.
3. **Midnight splits:** collapse consecutive equal Activity ids into runs before
   counting transitions and before deriving the query context.

These revisions remove the blockers without changing the product intent, the
public `rank` name, or any schema.
