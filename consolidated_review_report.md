# Consolidated Review Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md`
**FeatureRange:** lines 1-449
**DetailedRange:** lines 450-600
**Stages:** 5-9, uninterrupted full flow
**Date:** 2026-11-05

## Verdict

The design is technically coherent and the core trade-offs are documented, but
it is not approval-ready. Seven blockers remain. Three are cross-stage: the
60-day query cost is unbounded, risks and rollout are not consolidated, and the
document uses "habit," which the project bans. Four are implementation-plan
defects: missing phases, missing hour-wrap and zone rules, a window-edge
arithmetic contradiction, and a run-reset rule that contradicts the feature
sections. The plan also makes one false claim about existing Dashboard test
coverage.

## Reviewer Status

| Stage | Reviewer | Status | Report |
| --- | --- | --- | --- |
| 5 | `egm-zoom-out` | completed | `zoom_out_report.md` |
| 6 | `egm-comprehension` | completed | `comprehension_report.md` |
| 7 | `egm-design` | completed | `critic_report.md` |
| 7 | `egm-structural` | completed | `critic_report.md` |
| 7 | `egm-style` | completed | `critic_report.md` |
| 8 | `egm-zoom-out` | completed | `intermediate_zoom_out_report.md` |
| 9 | `egm-implementation-readiness` | completed | `implementation_readiness_report.md` |
| 9 | `egm-codebase-details` | completed | `implementation_readiness_report.md` |
| 9 | `egm-style` | completed | `implementation_readiness_report.md` |

## Blockers

### B1. The 60-day query cost is unbounded and mis-scoped

**Sources:** `zoom_out_report.md`; `critic_report.md` finding 1;
`implementation_readiness_report.md` finding 3; `intermediate_zoom_out_report.md`
finding 5.

**Affected scope:** Open Question 1 (89-93); §6 (231-243); §8 (273-283);
Non-Functional Requirements (404-410); Future Improvements (431-433).

The 1.2 ms figure covers only the pure `rank` walk. `getRecords` hydrates full
`Record` objects and issues one `record_tags` query per 500 rows. At 6,000 rows
that is 12 extra queries and 6,000 deserializations on every record commit,
every `publish()` including the 3-second Undo settle, and every watch refresh.
There is no `limit` and no row cap. A user splitting every five minutes produces
about 17,280 rows in 60 days.

**Required revision:** project only `activity_id, started_at_epoch_ms,
timezone_id` for ranking, skip tag hydration, bound the query, and measure
commit-to-notification p95 on a mid-range device. A plain `LIMIT` on the
required ascending order returns the oldest rows; any cap needs a descending
read and reverse, or a run-count band.

### B2. Risks, rollout, and quality evidence are not consolidated

**Sources:** `critic_report.md` finding 2; `intermediate_zoom_out_report.md`
finding 4; `egm-structural`.

**Affected scope:** entire feature specification; Non-Functional Requirements
(399-415); Rollout (413-415); Future Improvements (431-446).

The feature-spec standard requires failure modes and their mitigations. There is
no `## Risks & Mitigations` section. Risk-shaped content is dispersed across The
Problem, Open Questions, and Non-Functional Requirements. The document says
"reverting the commit rolls it back," which is false for users who already
updated: store releases are not retroactive.

**Required revision:** add one consolidated risk-to-mitigation section and
correct the rollback claim. The critic proposed a feature flag, shadow mode, and
a production hit-rate counter; the intermediate zoom-out calls that
disproportionate for a change that reorders a list and persists nothing. The
smaller resolution is to ship without a runtime flag, state that rollback means
the next release, and get quality evidence from the offline replay harness.

### B3. "habit" is used for an Activity, which the project bans

**Source:** `critic_report.md` finding 3.

**Affected scope:** lines 40-41, 99, 123, 129-130, 303-304, 375, 441.

`CONTEXT.md` lists "habit" under `Activity -> Avoid`. It imports streak and goal
framing that the product forbids.

**Required revision:** replace with "pattern," "sequence," or "Activity." For
example: "A pattern does not fade at the edge"; "outrank a strong Markov-1
sequence"; "CUJ 3: A new sequence replaces an old one"; "a daily `B -> C`
sequence."

### B4. Window-edge arithmetic and the caller cutoff disagree

**Sources:** `implementation_readiness_report.md` finding 3;
`critic_report.md` finding 19.

**Affected scope:** §2 (168-177); §9 (291-292); all three callers'
`startedAfter`.

The document uses `/` and never states truncation. The implementation uses
`~/`, so a Record at 60.9 days still scores as day 60. The callers'
`startedAfter` excludes everything older than exactly 60 days, so the engine and
the SQL cutoff disagree at the edge. A test at 60.5 days expects inclusion.

**Required revision:** specify `ageDays = delta ~/ 86_400_000`,
`ageDays < 0 -> 0`, `ageDays > 60 -> 0`, and reconcile the SQL cutoff with
bucket 60. State whether 60.x days is inside or outside.

### B5. Run resets contradict the feature sections

**Sources:** `implementation_readiness_report.md` finding 4;
`critic_report.md` finding 17; `implementation_readiness_report.md` finding 10.

**Affected scope:** item 1 (466-469) versus §3 (185-189) and §9 (291-292).

Item 1 says the walk "resets at Untracked and out-of-window Records." Section 3
says only an Untracked Record resets the training chain. Section 9 says an
over-window Record is "excluded as a gap." The code also resets
`previousRunId`, `secondPreviousRunId`, and `currentRunId` at future Records. An
implementer must guess which rule is real.

**Required revision:** state the exact reset set: Untracked, future-started, and
out-of-window Records clear all three chain fields. Distinguish "excluded from
scores" from "resets the chain."

### B6. The implementation plan has no phases or checkpoints

**Source:** `implementation_readiness_report.md` finding 1.

**Affected scope:** lines 450-597.

The file list is flat. The implementation-readiness standard requires
incremental phases that each leave the codebase buildable and testable.

**Required revision:** add Phase 1 (engine and engine tests; checkpoint
`flutter test test/core/suggestion_engine_test.dart`), Phase 2 (three callers;
checkpoint the notification and wearable tests), Phase 3 (docs and
`concepts_brief.md`). Each phase must leave `flutter analyze` clean.

### B7. Temporal hour-wrap and zone basis are missing

**Source:** `implementation_readiness_report.md` finding 2.

**Affected scope:** §1 pipeline (line 152); §9 (285-295).

The implementation accepts `diff <= 1 || diff == 23` for the 23:00 to 00:00
wrap. The plan says only "within ±1 hour," so an implementer drops the wrap
case. The plan also omits that the run's hour uses `record.timezoneId`, not the
target zone.

**Required revision:** state both rules and add a wrap-boundary test.

## Major Findings

### M1. Context derivation is inconsistent, half-wired, and contradicted by gaps

**Sources:** `critic_report.md` findings 4 and 8; `comprehension_report.md`
finding 6; `intermediate_zoom_out_report.md` finding 1;
`implementation_readiness_report.md` finding 10.

`contextFromHistory` skips Untracked rows, so `A, untracked, B` returns `(B, A)`,
but `rank` resets the chain at the same gap. That pair can never match the tail.
The same mismatch exists for future-dated Records: the context helper skips only
nulls and repeats, while `rank` resets on future and out-of-window Records, and
none of the history queries passes `startedBefore`. `SuggestionContext` is
returned by the helper but unpacked at every call site, so it owns no boundary.

**Recommended resolution:** derive both preceding runs inside `rank` from the
history snapshot, using the chain rule rather than the skip-null rule. Delete
`SuggestionContext`, `contextFromHistory`, the optional
`secondPrecedingActivityId`, the debug assert, and the three unpacks. If the
context stays separate, break it at gaps and future Records and accept one
context object rather than two loose fields.

### M2. A known comparator defect ships undecided

**Source:** `critic_report.md` finding 5.

**Affected scope:** Open Question 3 (98-101); §4 (210-213); Alternative A
(299-306).

The gate protects the pair, not the outcome. Once a pair is established, any
candidate with a token trigram score (51,000 from one 60-day-old observation)
outranks a strong Markov-1 sequence with zero trigram.

**Recommended resolution:** normalize within the tier (trigram score divided by
context mass) or add the per-outcome floor now, and test it. Do not leave it as
an open question.

### M3. Core constants are asserted, not evaluated

**Sources:** `critic_report.md` finding 6; `intermediate_zoom_out_report.md`
finding 2.

The 14-day half-life, 60-day window, two-observation minimum, and 1,000,000-micro
mass floor have no alternatives and no sensitivity analysis. The combined gate
rejects a pair seen twice 20 days ago (0.37 + 0.37 < 1.0) while accepting one
seen once today and once 30 days ago.

**Recommended resolution:** add a parameter table with rejected values and the
acceptance envelope. Keep both gate constants: mass-only admits one fresh
observation, reintroducing the stray-event failure; count-only admits stale
repeats. Present them as one predicate ("seen at least twice, and still worth
one fresh observation"), not two tunable knobs.

### M4. Non-goals contradict the proposed remedy

**Source:** `critic_report.md` finding 7; `intermediate_zoom_out_report.md`
finding 5.

Non-goals forbid "a cache or precomputed index," while Open Question 1 and
Future Improvements propose a query cache. The intermediate zoom-out shows the
minimal fix is projection, not a cache.

**Recommended resolution:** replace the cache language with lean projection and
a bounded query. Remove the contradiction.

### M5. The caller pipeline is triplicated

**Source:** `critic_report.md` finding 9; `intermediate_zoom_out_report.md`
finding 3.

Query, order, context derivation, `rank`, and the suggested-then-fill ranking are
about fifteen near-identical lines in the notification and wearable services,
plus a variant in the Dashboard. That duplication produced the 30-day/14-day
split this design exists to remove.

**Recommended resolution:** add one ten-line function in `lib/core/state` that
owns the window, projection, limit, fill-remaining, and empty behavior. It must
stay a function, not a service or cache.

### M6. The replaced ranking helper is unaccounted for

**Source:** `critic_report.md` finding 10.

`lib/core/state/activity_ranking.dart` still defines `rankActivitiesByUse`, which
has no references in `lib/` or `test/`. The plan never says whether it is
deleted, repurposed, or left orphaned.

**Recommended resolution:** name the disposition.

### M7. The document is both a record and a forward plan

**Sources:** `critic_report.md` finding 11; `implementation_readiness_report.md`
finding 9; `comprehension_report.md` finding 2; `egm-structural`.

Status "In Review" and "the design is already implemented" sit above a plan of
"Proposed Changes / Create" items, including process artifacts and test-rename
choreography. Items 10 and 11 are marked `(Create)` for files that already
exist; item 7 uses `(Verify)`, outside the Create/Modify/Delete vocabulary.
`design_draft.md` has no defined path.

**Recommended resolution:** convert the section to a completed-change ledger with
one status per item, or rewrite it as the original plan and remove the
"implemented" claim. Give full paths.

### M8. The test plan lists topics, not executable cases

**Source:** `implementation_readiness_report.md` finding 6.

Bullets such as "add decay ranking" and "tie-breaking" give no expected order and
no assertion that fails when a gate or comparator line is removed. Shared
fixtures (`makeActivity`, `makeRecord`, `ordered`, `zoneUtc`, `zoneNY`) are not
named.

**Recommended resolution:** provide per-case fixtures (Activities, day offsets,
target, expected first id) for the half-life boundary, unseen-pair backoff, and
zero-candidate fallthrough. Name the fixtures to reuse.

### M9. The caller context change has no regression test

**Source:** `implementation_readiness_report.md` finding 7.

"Notification tests pass unchanged" means nothing fails if the old last-two
query stays. The design's central hazard is unguarded.

**Recommended resolution:** add one test per caller: last Record Untracked or
outside the window, context derived from history, and a single history query.

### M10. The Dashboard test claim is false

**Source:** `implementation_readiness_report.md` finding 8.

The plan says the Dashboard row has no widget test. The repository already has
`testWidgets('suggested activities row renders when suggestions exist and labels
on tap')` in `test/ui/color_blocks_dashboard_test.dart:64`. It seeds history,
asserts the `suggested-chip-act-2` chip, and taps it to label the Lap.

**Recommended resolution:** delete the false gap or change it to "extend the
existing test." Add that file to the target list.

### M11. Trigger frequency is undefined

**Source:** `comprehension_report.md` finding 4.

"Every Lap change" is the stated trigger but is never defined. `CONTEXT.md`
defines Lap but not the events that change it: label, Split, Edge edit,
MidnightSplit, watch action, deep link. The cost argument depends on that
frequency.

**Recommended resolution:** enumerate the events and their expected frequency.

### M12. The fill-remaining and cold-start rules are omitted

**Source:** `comprehension_report.md` finding 5;
`implementation_readiness_report.md` finding 11.

The diagram says "top 6" and "top 3," but both callers fill unused slots with
remaining Activities in their own order. Nothing states this padding rule. The
engine returns candidates in original order for empty history, while the
Dashboard returns an empty suggestion list.

**Recommended resolution:** state the fill-remaining rule and the cold-start
behavior for each surface, or document the Dashboard guard.

### M13. "Trigram" and "bigram" are never mapped to the Markov tiers

**Source:** `comprehension_report.md` finding 1.

The terms are used as synonyms for Markov-2 and Markov-1, but the mapping is
never stated.

**Recommended resolution:** define both terms once, next to the tier names.

### M14. Process artifacts are undefined

**Source:** `comprehension_report.md` finding 2.

"The review," "the Goldfish review," and `/egm-draft` have no inline definition or
link. `concepts_brief.md` has no path.

**Recommended resolution:** define or link them once, or move the process history
out of the design document.

### M15. Structural layout issues

**Source:** `critic_report.md` finding 17.

`Additional Resources` and `Future Improvements` are H3s that function as
top-level back matter, so a generated table of contents nests them under
Non-Functional Requirements. Open Questions sits before the architecture and
CUJs even though its questions reference terms introduced later. The required
"Problem Statement" header is renamed "The Problem."

**Recommended resolution:** promote the appendices to H2 or move them after the
implementation plan, move Open Questions after the architecture or into the risk
section, and use the standard header name.

### M16. The decay description is internally inconsistent

**Sources:** `critic_report.md` findings 18 and 19.

The goals promise "smooth decay," while the design uses a whole-day table and
Alternative C calls the alternative "continuous rather than bucketed by day."
The formula reads fractional, but the table is whole-day.

**Recommended resolution:** call it "daily-stepped decay," state the 61-entry
bucket, write `ageDays = floor(...)`, state that it is UTC-based, and state that
the temporal slot uses the local hour.

### M17. Unmeasurable and false-agency phrasing

**Source:** `critic_report.md` finding 20.

Examples: "make the current suggestions worse than the history they are built
from"; "a routine the user stopped"; "the training chain stays honest"; "whether
the pair is a real routine"; "This is the exact failure"; "This is standard
backoff behavior"; "too brittle."

**Recommended resolution:** rewrite as measured comparisons or consequences of
the specified rule. For example, "This follows from the tier order in §5"; "if
replay shows top-3 hit rate falls below Markov-1 for the same history."

### M18. Documentation edits are open-ended

**Source:** `implementation_readiness_report.md` finding 12.

"Update the goal, scoring tiers, diagram, API, caching note, performance target,
and test plan" leaves the writing and decisions to the implementer.

**Recommended resolution:** provide the replacement outline or target text per
section.

### M19. Naming and API sketch drift

**Sources:** `implementation_readiness_report.md` findings 13-15;
`implementation_readiness_report.md` nits; `implementation_readiness_report.md`
finding 5.

The window has four names. The gate constants are unnamed. `CONTEXT.md` has no
`Run`, but the plan uses "run ids" and "both preceding ids" interchangeably. The
API sketch omits `static`, `required`, and the type of `historyWindow`. Boundary
returns for `limit <= 0` and all-archived are not listed.

**Recommended resolution:** use `historyWindowDays`, quote 60 once, name
`_pairMinObservations` and `_pairMinContextMass` with values, define "collapsed
run," and publish the actual static named-parameter shape.

### M20. Manual checks are not executable

**Source:** `implementation_readiness_report.md` finding 16.

"Label a routine that shares an immediate predecessor" specifies no fixture, no
target instant, and no expected order. "Confirm the three surfaces agree" omits
that they request 4, 6, and 3 candidates, so only the top item can match.

**Recommended resolution:** give the Records to create and the expected top-1
per surface.

### M21. Open Question 2 is already answered by shipped behavior

**Source:** `intermediate_zoom_out_report.md` finding 6.

The test "context mass counts outcomes that are not candidates" pins exactly the
tombstoned-id mass that Q2 calls open. The document asks a question its own test
suite has already decided.

**Recommended resolution:** close Q2 as accepted, or add the rule (a tombstoned
id breaks the chain like an Untracked Record) and change the test.

## Nits

| ID | Finding | Source |
| --- | --- | --- |
| N1 | The test count "38" is unverifiable and stale after new tests. | `implementation_readiness_report.md` finding 17 |
| N2 | The verification command says `flutter analyze`; the repository says `dart analyze`. | `implementation_readiness_report.md` nit |
| N3 | Release behavior for a second id without a first is undocumented; the assert is stripped. | `implementation_readiness_report.md` nit |
| N4 | `concepts_brief.md` has no path; `design_draft.md` is undefined. | `implementation_readiness_report.md` nit |
| N5 | "Caching note" is undefined; no such section exists. | `implementation_readiness_report.md` nit |
| N6 | "archived" versus "tombstoned" may be the same lifecycle state. | `implementation_readiness_report.md` nit |
| N7 | "unit and integration tests" mislabels the call-site tests. | `implementation_readiness_report.md` nit |
| N8 | Filler rationale "This is the feature" adds nothing. | `implementation_readiness_report.md` nit |
| N9 | "query" means the ranking input and a SQL query. | `critic_report.md` finding 21 |
| N10 | The 64-bit headroom is unquantified; the maximum accumulator is 61,000,000. | `critic_report.md` finding 22 |
| N11 | Surface names drift: "Today Dashboard," "chips," "Wear tile," "watch tile." | `critic_report.md` finding 23 |
| N12 | The empty-history engine contract never reaches Dashboard users. | `critic_report.md` finding 24 |
| N13 | Formatting drift: list markers, thematic breaks, numbering, plain paths, "cliff," "phantom mass," "accident," "churn," "desktop quick popover," repeated constraints. | `critic_report.md` finding 25 |
| N14 | The Dashboard keeps a duplicate `limit: 1` tail query. | `intermediate_zoom_out_report.md` finding 7 |
| N15 | "Smooth decay" and micro-unit framing present conventions as measured needs. | `intermediate_zoom_out_report.md` finding 8 |
| N16 | The 5 ms CI guard does not enforce the 2 ms product target. | `critic_report.md` finding 24 |

## Cross-Stage Disagreements

The reviewers did not agree on every remedy. These are the material forks.

1. **Rollout safety.** The design critic wants a feature flag, shadow mode, and
   production hit-rate counter. The intermediate zoom-out calls that
   disproportionate. Resolution: add the missing risk section and correct the
   rollback claim, but use the offline replay harness for quality evidence. Do
   not add runtime state.
2. **Context type.** The design critic wants `rank` to accept one
   `SuggestionContext`. The intermediate zoom-out wants to delete the type and
   derive the context inside `rank`. Resolution: derive inside `rank`; it removes
   the invalid state and the gap contradiction.
3. **Gate constants.** The design critic suggests one rule. The intermediate
   zoom-out shows mass-only reintroduces the stray-event failure. Resolution:
   keep both constants, but present them as one predicate with one intent.
4. **Query remedy.** The zoom-out says cap the rows. The intermediate shows a
   plain cap on ascending history keeps the oldest rows. Resolution: lean
   projection first, then a descending read and reverse if a cap is still
   needed.
5. **Micro-unit regime.** The zoom-out calls it optimization-first; the
   intermediate says keep it and drop the justification. Resolution: keep the
   integer convention, present it as a determinism choice, not a measured need.

## Traceability Matrix

| Consolidated ID | Sources |
| --- | --- |
| B1 | Z; Cr 1; IR 3; I 5 |
| B2 | Cr 2; I 4 |
| B3 | Cr 3 |
| B4 | IR 3; Cr 19 |
| B5 | IR 4 and 10; Cr 17 |
| B6 | IR 1 |
| B7 | IR 2 |
| M1 | Cr 4 and 8; C 6; I 1; IR 10 |
| M2 | Cr 5 |
| M3 | Cr 6; I 2 |
| M4 | Cr 7; I 5 |
| M5 | Cr 9; I 3 |
| M6 | Cr 10 |
| M7 | Cr 11; IR 9; C 2 |
| M8 | IR 6 |
| M9 | IR 7 |
| M10 | IR 8 |
| M11 | C 4 |
| M12 | C 5; IR 11 |
| M13 | C 1 |
| M14 | C 2 |
| M15 | Cr 17 |
| M16 | Cr 18 and 19 |
| M17 | Cr 20 |
| M18 | IR 12 |
| M19 | IR 13-15 |
| M20 | IR 16 |
| M21 | I 6 |

Key: Z = `zoom_out_report.md`; C = `comprehension_report.md`;
Cr = `critic_report.md`; I = `intermediate_zoom_out_report.md`;
IR = `implementation_readiness_report.md`.

## Residual Risks

1. End-to-end 60-day query cost per Lap change is unmeasured on device.
2. No product-quality evidence exists for the tier order; every constant rests on
   reasoning.
3. Tombstoned Activities may keep contributing gate mass until Open Question 2 is
   closed.
4. Four-step routines remain outside the model by design.
5. Surface drift will recur unless the duplicated pipeline becomes one function.
