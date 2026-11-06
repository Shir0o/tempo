# Goldfish Annotated Review Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md` (full file)
**Line range:** 1-600
**Source of findings:** `consolidated_review_report.md`
**Status:** resolved

## High Severity

### B1. The 60-day query cost is unbounded and mis-scoped

**Reviewer lens:** `egm-zoom-out`, `egm-design`, `egm-implementation-readiness`
**Affected scope:** Open Question 1; §6; §8; Non-Functional Requirements; Future
Improvements.
**Discrepancy:** The 1.2 ms figure covers only `rank`. `getRecords` hydrates full
Records, issues `record_tags` queries per 500 rows, and has no cap. It runs on
every Lap change.
**Rationale:** A battery- and latency-critical path is widened fourfold on faith.
**AI suggestion:** PROPOSE FIX.
**Justification:** The document should specify the lean read and the bound, not
defer them. The code follow-up will add `includeTags: false`, a
`startedBefore: now` filter, and a descending read with a row cap that is
reversed before ranking. Projection to only the three needed columns remains a
follow-up if device measurement shows hydration is still too expensive.
**Proposed edit:**
- Location: Open Question 1, §8, Non-Functional Requirements, Future
  Improvements.
- Change: replace the "unmeasured, maybe cache later" text with: "The loader
  reads at most 12,000 Records from the last 60 days, ordered newest-first,
  selects only ranking fields, skips tag hydration, and reverses the list before
  ranking. `publish()` and `_loadData()` must be measured on a mid-range device;
  if the bound is reached, the oldest decayed rows are discarded first." Remove
  the cache as the fallback.

### B2. Risks, rollout, and quality evidence are not consolidated

**Reviewer lens:** `egm-structural`, `egm-design`
**Affected scope:** entire feature specification; Non-Functional Requirements;
Rollout; Future Improvements.
**Discrepancy:** No `## Risks & Mitigations` section. The rollback claim is
false for users who already updated. No quality signal exists beyond unit tests.
**Rationale:** The feature-spec standard requires failure modes and mitigations.
**AI suggestion:** PROPOSE FIX.
**Justification:** Add one consolidated section. Keep the simpler rollout: no
runtime flag, no shadow mode. Correct the rollback claim. Use the offline replay
harness for quality evidence.
**Proposed edit:**
- Location: after Non-Functional Requirements.
- Change: add `## Risks & Mitigations` with rows for query cost, stale/interrupted
  learning, tombstoned context mass, rare-outcome inversion, clock skew, and
  surface drift, each with a mitigation and an owner. Replace "reverting the
  commit rolls it back" with "rollback means the next release; no persisted data
  changes." Remove the feature-flag and production hit-rate suggestions from
  Future Improvements.

### B3. "habit" is used for an Activity, which the project bans

**Reviewer lens:** `egm-style`
**Affected scope:** lines 40-41, 99, 123, 129-130, 303-304, 375, 441.
**Discrepancy:** `CONTEXT.md` lists "habit" under `Activity -> Avoid`.
**Rationale:** It imports streak and goal framing the product forbids.
**AI suggestion:** PROPOSE FIX.
**Justification:** Mechanical replacement with domain vocabulary.
**Proposed edit:**
- Location: listed lines.
- Change: "habit" -> "pattern" or "sequence"; "routine" -> "sequence" where it
  names an Activity pattern. Specific replacements: 40 "A pattern does not fade
  at the edge"; 99 "a strong Markov-1 sequence"; 123 "CUJ 3: A new sequence
  replaces an old one"; 129-130 "the older sequence"; 303-304 "a daily `B -> C`
  sequence"; 375 "the pattern problem"; 441 "displacing a strong Markov-1
  sequence."

### B4. Window-edge arithmetic and the caller cutoff disagree

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** §2; §9; all three callers' `startedAfter`.
**Discrepancy:** The document uses `/` and says "older than 60 days excluded."
The implementation truncates with `~/`, so 60.9 days still scores as day 60. The
SQL cutoff excludes everything older than exactly 60 days.
**Rationale:** The engine and the query disagree at the boundary; the test at
60.5 days expects inclusion.
**AI suggestion:** PROPOSE FIX.
**Justification:** Honor the accepted decision: exclude anything beyond 60 days.
Compute the raw age in milliseconds and compare it before the whole-day bucket.
**Proposed edit:**
- Location: §2 "Decay weights"; §9 "Boundary behavior."
- Change: "ageMs = targetEpochMs - startedAtEpochMs. If ageMs < 0 or ageMs >
  60 days, the Record is a gap and contributes nothing. Otherwise ageDays =
  ageMs ~/ 86_400_000, so the table is indexed 0..60. A Record at exactly 60 days
  uses bucket 60; a Record at 60 days plus one millisecond is excluded. The
  callers' `startedAfter` uses the same 60-day boundary."
- Code follow-up: add the `ageMs > historyWindow` check before `ageDays`; update
  the 60.5-day test to expect exclusion; add exactly-60-days inclusion.

### B5. Run resets contradict the feature sections

**Reviewer lens:** `egm-style`, `egm-implementation-readiness`
**Affected scope:** plan item 1 versus §3 and §9.
**Discrepancy:** Item 1 says "resets at Untracked and out-of-window Records."
§3 says only Untracked resets. §9 says over-window is excluded. The code also
resets at future Records.
**Rationale:** The implementer must guess which rule is real.
**AI suggestion:** PROPOSE FIX.
**Justification:** State the exact reset set. The code behavior is sensible.
**Proposed edit:**
- Location: §3 "Runs, not Records"; §9; plan item 1.
- Change: "An Untracked, future-started, or out-of-window Record clears all three
  chain fields: previousRunId, secondPreviousRunId, and currentRunId. A Record
  outside the window is never scored; it is not merely skipped, because skipping
  would bridge the gap."

### B6. The implementation plan has no phases or checkpoints

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** Detailed Implementation Plan.
**Discrepancy:** The file list is flat; the standard requires incremental,
buildable phases.
**Rationale:** A fresh implementer cannot stop and verify between engine and
callers.
**AI suggestion:** PROPOSE FIX.
**Justification:** Three phases with named checkpoints.
**Proposed edit:**
- Location: after "Target Files to Create/Modify."
- Change: add `### Phases`: Phase 1 engine + `contextFromHistory` + engine tests,
  checkpoint `flutter test test/core/suggestion_engine_test.dart`; Phase 2 the
  three callers, checkpoint the notification and wearable tests; Phase 3 docs and
  `concepts_brief.md`. Each phase leaves `flutter analyze` clean.

### B7. Temporal hour-wrap and zone basis are missing

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** §1 pipeline; §9.
**Discrepancy:** The code accepts the 23:00-00:00 wrap (`diff == 23`), but the
plan says only "within ±1 hour." The plan also omits that the run's hour uses
`record.timezoneId`, not the target zone.
**Rationale:** An implementer drops the wrap case; no test names it.
**AI suggestion:** PROPOSE FIX.
**Justification:** State both rules and add a boundary test.
**Proposed edit:**
- Location: §1 "Temporal" bullet; §9.
- Change: "A run matches when its local hour differs from the target hour by at
  most one, including the 23:00-00:00 wrap (`diff == 23`). The hour is resolved
  in the Record's own `timezoneId`; the target hour is resolved in the query
  zone. Add a test at 23:30 versus 00:30."

## Medium Severity

### M1a. Context helper and chain disagree on gaps and future Records

**Reviewer lens:** `egm-design`, `egm-zoom-out`, `egm-implementation-readiness`
**Affected scope:** §3; §7; plan item 1.
**Discrepancy:** `contextFromHistory` skips Untracked and future Records; `rank`
resets on them. The context can name a run the chain rejected.
**Rationale:** The pair gate can activate on a context that never existed in the
chain.
**AI suggestion:** PROPOSE FIX.
**Justification:** Keep the required two-parameter API but make the helper follow
the chain rule.
**Proposed edit:**
- Location: §3 "The query context uses a different rule"; §7 API; plan item 1.
- Change: `contextFromHistory(history, targetEpochMs)` walks forward and clears
  `preceding` and `second` on Untracked, future-started, and out-of-window
  Records, then collapses repeats. It returns the last two runs that the chain
  would also accept. Callers pass `now`.
- Code follow-up: add the `targetEpochMs` parameter, implement the reset rule,
  update callers and tests.

### M1b. Delete `SuggestionContext`, `contextFromHistory`, and the two parameters

**Reviewer lens:** `egm-zoom-out`
**Affected scope:** §7 API; §3.
**Discrepancy:** The intermediate zoom-out recommends deriving the pair inside
`rank` and deleting the helper and parameters.
**Rationale:** It removes a wrapper and the invalid state.
**AI suggestion:** CONTEST.
**Justification:** The locked requirement explicitly keeps
`precedingActivityId` and optional `secondPrecedingActivityId` in `rank`, and the
design's public API is built on them. Deleting them is a larger API change than
the review scope. The helper can be made consistent instead (M1a). The
`SuggestionContext` return type remains a convenience for the three callers; the
two fields are the required interface.
**Proposed edit:** none. Record the contest and keep the API.

### M2. A known comparator defect ships undecided

**Reviewer lens:** `egm-design`
**Affected scope:** Open Question 3; §4; Alternative A.
**Discrepancy:** Once a pair is established, a token trigram score outranks a
strong Markov-1 sequence.
**Rationale:** The gate protects the pair, not the outcome.
**AI suggestion:** PROPOSE FIX.
**Justification:** Define a candidate-level strength threshold using the existing
context mass, so no new accumulator is needed. A candidate enters the trigram
tier only when it carries at least 10 percent of the pair's context mass.
**Proposed edit:**
- Location: §4 "Markov-2 gate and backoff"; Open Question 3.
- Change: add "A candidate is a strong trigram match when its trigram score is
  at least 10 percent of the pair's context mass. Candidates below that share
  fall through to Markov-1." Close Open Question 3 with this rule.
- Code follow-up: compare `trigramScore * 10 >= contextMass` before using the
  trigram value; add a test for a 4.9 percent token score.

### M3. Core constants are asserted, not evaluated

**Reviewer lens:** `egm-design`, `egm-zoom-out`
**Affected scope:** Goals; §2; §4.
**Discrepancy:** The half-life, window, observation count, and mass floor have no
alternatives or sensitivity analysis. The combined gate has an unstated
acceptance envelope.
**Rationale:** The constants are the feature, but they are folklore.
**AI suggestion:** PROPOSE FIX.
**Justification:** Keep both gate constants. Present them as one predicate, not
two knobs. Add the envelope.
**Proposed edit:**
- Location: after §4.
- Change: add a parameter table: half-life 14 (rejected 7, 30), window 60
  (rejected 30, 90), min observations 2 (rejected 1 for stray events), min mass
  1,000,000 (rejected 500,000 for stale pairs). State the envelope: "accepted:
  seen at least twice and still worth one fresh observation; rejected: one fresh
  event, or repeats whose combined decay is below one fresh observation."

### M4. Non-goals contradict the proposed remedy

**Reviewer lens:** `egm-design`, `egm-zoom-out`
**Affected scope:** Non-Goals; Open Question 1; Future Improvements.
**Discrepancy:** Non-goals forbid a cache, but the fallback proposes one.
**Rationale:** The minimal fix is projection and a bound, not a cache.
**AI suggestion:** PROPOSE FIX.
**Justification:** Remove the contradiction.
**Proposed edit:**
- Location: Non-Goals; Open Question 1; Future Improvements.
- Change: replace "cache or precomputed index" with "a cache, precomputed index,
  or a second history store; the allowed remedy is a lean read and a row bound."
  Remove the cache fallback from Open Question 1.

### M5. The caller pipeline is triplicated

**Reviewer lens:** `egm-zoom-out`
**Affected scope:** §8; `_chipActivities`; `_tileActivityIds`; Dashboard load.
**Discrepancy:** The query, context derivation, rank, and fill block is copied
three times.
**Rationale:** That duplication produced the window split.
**AI suggestion:** PROPOSE FIX.
**Justification:** Add one function in `lib/core/state` that owns the window,
lean read, bound, context, rank, limit, fill-remaining, and empty behavior.
**Proposed edit:**
- Location: §8 Caller changes; plan target files.
- Change: add `lib/core/state/suggestion_loader.dart` with
  `Future<List<Activity>> loadSuggestions({database, candidates, nowEpochMs,
  timezoneId, limit})`. The three callers use it. It stays a function, not a
  service or cache.

### M6. The replaced ranking helper is unaccounted for

**Reviewer lens:** `egm-zoom-out`
**Affected scope:** `lib/core/state/activity_ranking.dart`.
**Discrepancy:** `rankActivitiesByUse` has no references.
**Rationale:** The plan replaces the fallback but never disposes of the old code.
**AI suggestion:** PROPOSE FIX.
**Justification:** Delete the dead helper if the code search confirms no
references.
**Proposed edit:**
- Location: plan target files.
- Change: add `lib/core/state/activity_ranking.dart` (Delete) with rationale
  "superseded by the engine; no references." Confirm with code search before
  deleting.

### M7. The document is both a record and a forward plan

**Reviewer lens:** `egm-zoom-out`, `egm-structural`,
`egm-codebase-details`
**Affected scope:** Overview; Detailed Implementation Plan; items 10-11.
**Discrepancy:** "Already implemented" sits above future-tense "Add/Replace"
steps and `(Create)` markers for existing files.
**Rationale:** A reviewer cannot tell what is being approved.
**AI suggestion:** PROPOSE FIX.
**Justification:** Make it one document: a design with a "Shipped" ledger and a
short "Remaining" list.
**Proposed edit:**
- Location: Overview; Detailed Implementation Plan.
- Change: add a status table at the top of the plan: `Shipped` for the engine,
  callers, tests, README, and old design doc; `Remaining` for the query bound,
  context helper fix, candidate floor, caller regression tests, and device
  measurement. Remove `(Create)` from existing files and replace `(Verify)` with
  `Modify` or `Verify (no change)`.

### M8. The test plan lists topics, not executable cases

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** item 5.
**Discrepancy:** No expected orders or failing assertions; fixtures unnamed.
**Rationale:** A fresh implementer cannot reproduce the cases.
**AI suggestion:** PROPOSE FIX.
**Justification:** Add concrete fixtures and expected first ids.
**Proposed edit:**
- Location: item 5.
- Change: add a table of cases with activities, day offsets, target, context,
  and expected first id for: half-life boundary (14/13 days -> first is the pair
  outcome), unseen pair (expect Markov-1), one observation (expect Markov-1),
  candidate share below 10 percent (expect Markov-1), gap (expect Markov-1), and
  tie (expect list order). Name `makeActivity`, `makeRecord`, `ordered`,
  `zoneUtc`, `zoneNY`.

### M9. The caller context change has no regression test

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** items 3, 4, 7.
**Discrepancy:** No test fails if the old last-two query stays.
**Rationale:** The central hazard is unguarded.
**AI suggestion:** PROPOSE FIX.
**Justification:** Add one test per caller.
**Proposed edit:**
- Location: items 3, 4, 7.
- Change: add "one test per caller: last Record Untracked or outside the window;
  context comes from history; exactly one history query is issued."

### M10. The Dashboard test claim is false

**Reviewer lens:** `egm-codebase-details`
**Affected scope:** Future Improvements; Verification Plan.
**Discrepancy:** `test/ui/color_blocks_dashboard_test.dart:64` already tests the
suggested row.
**Rationale:** The document claims a gap that does not exist.
**AI suggestion:** PROPOSE FIX.
**Justification:** Remove the false claim and list the existing test.
**Proposed edit:**
- Location: Future Improvements; Verification Plan; target files.
- Change: replace "the Dashboard row does not have a widget test" with "extend
  `test/ui/color_blocks_dashboard_test.dart` for the new ranking order." Add the
  file to the target list as Modify.

### M11. Trigger frequency is undefined

**Reviewer lens:** `egm-comprehension`
**Affected scope:** Open Question 1.
**Discrepancy:** "Every Lap change" is not defined.
**Rationale:** The cost argument depends on the event count.
**AI suggestion:** PROPOSE FIX.
**Justification:** Enumerate the events.
**Proposed edit:**
- Location: Open Question 1.
- Change: "Lap changes are: label, Split, Undo, Edge edit, MidnightSplit, watch
  label, deep-link label. The notification path recomputes on each; the watch
  path recomputes on each committed Record."

### M12. The fill-remaining and cold-start rules are omitted

**Reviewer lens:** `egm-comprehension`, `egm-implementation-readiness`
**Affected scope:** §6; §8; CUJs; §9.
**Discrepancy:** No padding rule or cold-start surface behavior.
**Rationale:** The CUJs cannot be reasoned about.
**AI suggestion:** PROPOSE FIX.
**Justification:** State the rule for each surface.
**Proposed edit:**
- Location: §8; CUJs.
- Change: "After the ranked suggestions, each surface appends remaining active
  Activities in its own list order: Dashboard stops at four, notification at
  six, watch tile at three. Empty history returns an empty suggestion strip; the
  surface shows its normal Activity list."

### M13. "Trigram" and "bigram" are never mapped to the Markov tiers

**Reviewer lens:** `egm-comprehension`
**Affected scope:** §4; Alternative A; test plan.
**Discrepancy:** The terms are used without definition.
**Rationale:** A fresh reader must reverse-engineer them.
**AI suggestion:** PROPOSE FIX.
**Justification:** Define both once.
**Proposed edit:**
- Location: §4 opening.
- Change: "Markov-2 observations are trigrams: a pair `(A, B)` plus the outcome
  `C`. Markov-1 observations are bigrams: `B` plus the outcome `C`."

### M14. Process artifacts are undefined

**Reviewer lens:** `egm-comprehension`
**Affected scope:** Overview; Additional Resources.
**Discrepancy:** "The review," "the Goldfish review," and `/egm-draft` are not
defined or linked.
**Rationale:** A fresh reader cannot tell what produced the decisions.
**AI suggestion:** PROPOSE FIX.
**Justification:** Define or link them once, or move process history out.
**Proposed edit:**
- Location: Overview; Additional Resources.
- Change: add "The design review was an EGM Goldfish review; `concepts_brief.md`
  is its brief." Link `concepts_brief.md`. Remove `/egm-draft` from the design
  rationale.

### M15. Structural layout issues

**Reviewer lens:** `egm-structural`
**Affected scope:** Additional Resources; Future Improvements; Open Questions;
Problem header.
**Discrepancy:** Orphan H3 appendices, out-of-order Open Questions, renamed
Problem header.
**Rationale:** The table of contents mis-nests and the reader hits undefined
terms.
**AI suggestion:** PROPOSE FIX.
**Justification:** Normalize the structure.
**Proposed edit:**
- Location: headings 27, 87, 419, 429.
- Change: rename "The Problem" to "Problem Statement"; move Open Questions after
  the Technical Plan; promote Additional Resources and Future Improvements to H2
  or move them after the Detailed Implementation Plan.

### M16. The decay description is internally inconsistent

**Reviewer lens:** `egm-style`
**Affected scope:** Goals; §2; Alternative C.
**Discrepancy:** "Smooth decay" versus a whole-day table; fractional formula
versus truncation.
**Rationale:** The document describes two different mechanisms.
**AI suggestion:** PROPOSE FIX.
**Justification:** Name the mechanism and state the truncation.
**Proposed edit:**
- Location: Goals; §2.
- Change: "Daily-stepped decay" instead of "smooth decay." State the 61-entry
  bucket and `ageDays = floor(ageMs / 86_400_000)`, UTC-based. The temporal slot
  uses the local hour.

### M17. Unmeasurable and false-agency phrasing

**Reviewer lens:** `egm-style`
**Affected scope:** lines 29, 33-34, 44, 101, 128-130, 194, 206, 306, 316, 446.
**Discrepancy:** Claims such as "worse than the history," "the training chain
stays honest," "a real routine," "standard backoff behavior," and "too brittle."
**Rationale:** None are measurable.
**AI suggestion:** PROPOSE FIX.
**Justification:** Rewrite as consequences of the specified rule.
**Proposed edit:**
- Location: listed lines.
- Change: "Three properties make the ranking diverge from the history"; "the
  transition chain stays artifact-free"; "whether the pair clears both
  thresholds"; "this follows from the tier order in §5"; "if replay shows top-3
  hit rate falls below Markov-1."

### M18. Documentation edits are open-ended

**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** item 9.
**Discrepancy:** "Update goal, scoring tiers, diagram..." leaves decisions to the
implementer.
**Rationale:** The plan must be executable.
**AI suggestion:** PROPOSE FIX.
**Justification:** This resolution pass supplies the replacement text; item 9
should point to it.
**Proposed edit:**
- Location: item 9.
- Change: replace the open-ended list with "Apply the replacements in
  `goldfish_review_report.md` sections B3, B4, B5, M3, M13, M16, and M19."

### M19. Naming and API sketch drift

**Reviewer lens:** `egm-style`, `egm-implementation-readiness`
**Affected scope:** §7; plan items.
**Discrepancy:** Four names for the window, unnamed constants, undefined "run,"
API sketch missing `static`/`required`.
**Rationale:** A caller written from the sketch would not compile.
**AI suggestion:** PROPOSE FIX.
**Justification:** Normalize names and the signature.
**Proposed edit:**
- Location: §7; plan item 1.
- Change: use `historyWindowDays`, `_pairMinObservations`,
  `_pairMinContextMass`, and "collapsed run." Publish the signature with
  `static`, `required`, and `Duration historyWindow = Duration(days:
  historyWindowDays)`.

### M20. Manual checks are not executable

**Reviewer lens:** `egm-style`
**Affected scope:** Verification Plan.
**Discrepancy:** No fixtures, target instant, or expected order.
**Rationale:** The checks cannot be reproduced.
**AI suggestion:** PROPOSE FIX.
**Justification:** Specify the scenario and expected top-1 per surface.
**Proposed edit:**
- Location: Verification Plan.
- Change: add a fixture: Gym 18:00, Shower 18:30, Dinner 19:00 on two days;
  Sleep 07:00, Shower 07:30, Commute 08:00 on two days; query 18:00 with
  `(Gym, Shower)` expects Dinner; query 08:00 with `(Sleep, Shower)` expects
  Commute. Surface limits are 4/6/3, so compare only the top-1.

### M21. Open Question 2 is already answered by shipped behavior

**Reviewer lens:** `egm-zoom-out`
**Affected scope:** Open Question 2; test "context mass counts outcomes that are
not candidates."
**Discrepancy:** The test pins the tombstoned-id mass the question calls open.
**Rationale:** The document contradicts its tests.
**AI suggestion:** PROPOSE FIX.
**Justification:** Close the question as accepted and state the rule.
**Proposed edit:**
- Location: Open Question 2.
- Change: "Accepted: context mass counts outcomes for tombstoned and archived
  Activities; this only affects whether a pair is established, not which
  candidates can be chosen. A future cleanup may make a tombstoned id break the
  chain." Remove Q2 from the open list.

## Low Severity

| ID | Finding | AI suggestion |
| --- | --- | --- |
| N1 | Test count "38" is stale. | DECLINE |
| N2 | `flutter analyze` versus `dart analyze`. | DECLINE |
| N3 | Release behavior for second-without-first. | DECLINE |
| N4 | `concepts_brief.md` path; `design_draft.md` undefined. | DECLINE |
| N5 | "Caching note" undefined. | DECLINE |
| N6 | "archived" versus "tombstoned." | DECLINE |
| N7 | "unit and integration tests" label. | DECLINE |
| N8 | Filler rationale "This is the feature." | DECLINE |
| N9 | "query" overloaded. | DECLINE |
| N10 | 64-bit headroom unquantified. | DECLINE |
| N11 | Surface names drift. | DECLINE |
| N12 | Empty-history contract unreachable. | DECLINE |
| N13 | Formatting and terminology drift. | DECLINE |
| N14 | Duplicate Dashboard tail query. | DECLINE |
| N15 | Micro-unit framing. | DECLINE |
| N16 | 5 ms CI guard versus 2 ms target. | DECLINE |

## Code Follow-Ups for Accepted Fixes

These are outside the document but required for the "both in one pass" choice.

1. **Window edge**: add `ageMs > historyWindow` exclusion before the whole-day
   bucket; update the 60.5-day test and add exactly-60-days inclusion.
2. **Context helper**: add `targetEpochMs`; clear both ids on Untracked,
   future-started, and out-of-window Records; update callers and tests.
3. **Candidate floor**: compare `trigramScore * 10 >= contextMass`; add the 4.9
   percent test.
4. **Lean read**: add `includeTags: false` to `getRecords`; add a
   `startedBefore: now` filter; add a 12,000-row cap with newest-first read and
   reverse.
5. **Shared loader**: add `lib/core/state/suggestion_loader.dart`; use it in the
   Dashboard, notification, and wearable services.
6. **Dead helper**: delete `lib/core/state/activity_ranking.dart` if the code
   search confirms no references.
7. **Regression tests**: one per caller for the context source and the single
   history query.
8. **Measurement**: profile `publish()` and `_loadData()` on device; record the
   p95. This cannot be completed in this environment.

**Applied:** items 1-7. **Remaining:** item 8, device measurement only.

## Resolution Summary

- PROPOSE FIX: 27
- CONTEST: 1 (M1b)
- ESCALATE: 0
- DECLINE: 16 nits
- Code follow-ups: 8
