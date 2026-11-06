# Implementation Readiness Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md`
**Stage:** 9, Implementation Readiness Test
**Audit scope:** DetailedRange, lines 450-600
**Standard:** `implementation-readiness-standard.md`
**Reviewers:** `egm-implementation-readiness`, `egm-codebase-details`,
`egm-style`

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-implementation-readiness` | completed |
| `egm-codebase-details` | completed |
| `egm-style` | completed |

## Verdict

Not ready. The plan names the right files but omits decisive algorithm details,
phases, and executable test fixtures. A fresh implementer would produce a
different engine. One factual claim about existing test coverage is also false.

## Blockers

### 1. No phases or checkpoints

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** lines 450-597.

The file list is flat. The standard requires incremental phases that each leave
the codebase buildable and testable.

**Recommendation:** add Phase 1 (engine, `SuggestionContext`, engine tests;
checkpoint `flutter test test/core/suggestion_engine_test.dart`), Phase 2 (the
three callers; checkpoint the notification and wearable tests), and Phase 3
(docs and `concepts_brief.md`). Each phase must leave `flutter analyze` clean.

### 2. Temporal hour-wrap and zone basis are missing

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** §1 pipeline (line 152); §9 (285-295).

The implementation accepts `diff <= 1 || diff == 23` (the 23:00 to 00:00 wrap).
The plan says only "within ±1 hour," so an implementer drops the wrap case, and
no test names it. The plan also omits that the run's hour uses
`record.timezoneId`, not the target zone.

**Recommendation:** state both rules and add a wrap-boundary test.

### 3. Window-edge arithmetic and the caller cutoff disagree

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-implementation-readiness`, `egm-codebase-details`
**Affected scope:** §2 (168-177); §9 (291-292); callers' `startedAfter`.

The formula uses `/`, never states truncation, and claims "older than 60 days
excluded." The implementation truncates with `~/`, so a Record at 60.9 days still
scores as day 60. The callers' `startedAfter` excludes everything older than
exactly 60 days, so the engine and the query disagree at the edge. A test at
60.5 days expects inclusion.

**Recommendation:** specify `ageDays = delta ~/ 86_400_000`, `ageDays < 0 -> 0`,
`ageDays > 60 -> 0`, and reconcile the SQL cutoff with bucket 60. State whether
60.x days is inside or outside.

### 4. Run resets contradict the feature sections

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-style`, `egm-implementation-readiness`
**Affected scope:** item 1 (466-469) versus §3 (185-189) and §9 (291-292).

Item 1 says the walk "resets at Untracked and out-of-window Records." Section 3
says only an Untracked Record resets the chain. Section 9 says an over-window
Record is "excluded as a gap." The code also resets `previousRunId`,
`secondPreviousRunId`, and `currentRunId` at future Records. An implementer must
guess which rule is real.

**Recommendation:** state the exact reset set: Untracked, future-started, and
out-of-window Records clear all three chain fields. Distinguish "excluded from
scores" from "resets the chain."

## Major Findings

### 5. The trigram gate is under-specified

**Severity:** 🟡 Major
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** §4 (196-213).

"Two completed trigram observations" is undefined. The implementation counts
every in-window chain outcome of the pair, candidate or not, and both counters
are inclusive `>=`. No worked numbers are given: two observations at 15 days
produce about 950,000 micros and fail the mass floor.

**Recommendation:** define "completed," state the inclusivity, and add worked
fixtures near the boundary.

### 6. The test plan lists topics, not cases

**Severity:** 🟡 Major
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** item 5 (509-523).

Bullets such as "add decay ranking" and "tie-breaking" give no expected order and
no assertion that fails when a gate or comparator line is removed.

**Recommendation:** provide per-case fixtures (Activities, day offsets, target,
expected first id) for the half-life boundary, unseen-pair backoff, and
zero-candidate fallthrough.

### 7. The caller context change has no regression test

**Severity:** 🟡 Major
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** items 3, 4, 7 (486-540).

The design's central hazard is the separate last-two query. "Notification tests
pass unchanged" means nothing fails if the old query stays.

**Recommendation:** add one test per caller: last Record Untracked or outside the
window, context derived from history, and a single history query.

### 8. The Dashboard test claim is false

**Severity:** 🟡 Major
**Reviewer lens:** `egm-codebase-details`
**Affected scope:** lines 444-445, 592-594; `test/ui/color_blocks_dashboard_test.dart:64`.

The plan says "the Dashboard row does not have a widget test" and lists adding
one as a remaining coverage gap. The repository already has
`testWidgets('suggested activities row renders when suggestions exist and labels
on tap')`, which seeds history, asserts the `suggested-chip-act-2` chip, and taps
it to label the Lap.

**Recommendation:** delete the false gap or change it to "extend the existing
test in `test/ui/color_blocks_dashboard_test.dart`." Add that file to the target
list.

### 9. Tense and file markers contradict "already implemented"

**Severity:** 🟡 Major
**Reviewer lens:** `egm-codebase-details`, `egm-style`
**Affected scope:** line 24; items 10-11 (559-572); item 7 (534).

Line 24 says the design "is already implemented," yet every step is prospective
("Add," "Replace," "Delete"). All eight modifications are present uncommitted.
Items 10 and 11 are marked `(Create)` for files that already exist. Item 7 is
marked `(Verify)`, outside the Create/Modify/Delete vocabulary.

**Recommendation:** convert the section to a completed-change ledger, or restate
it as the original plan with each item marked Done. Give full paths.

### 10. Future-dated Records break the "one context source" guarantee

**Severity:** 🟡 Major
**Reviewer lens:** `egm-codebase-details`
**Affected scope:** lines 65-66, 191-194, 463-464; `suggestion_engine.dart:70-84` versus `:152-157`; all three callers.

`contextFromHistory` skips only null ids and repeats. `rank` additionally resets
on future-started and out-of-window Records. None of the history queries passes
`startedBefore`, and `getRecords` filters only on `started_at >= since`, so a
clock-skewed or future-dated row is returned. The context tail then names a run
the chain never accepted, silently suppressing the bigram and trigram.

**Recommendation:** add `startedBefore: now` to all three queries, or apply the
same filter inside `contextFromHistory`, and document the precondition.

### 11. The Dashboard empty-history contract conflicts

**Severity:** 🟡 Major
**Reviewer lens:** `egm-implementation-readiness`, `egm-design`
**Affected scope:** §9 (287) versus `dashboard_view.dart:213`.

The engine contract returns candidates in original order for empty history; the
Dashboard returns an empty suggestion list.

**Recommendation:** document the caller guard explicitly, or change the surface
behavior.

### 12. Documentation edits are open-ended

**Severity:** 🟡 Major
**Reviewer lens:** `egm-implementation-readiness`
**Affected scope:** item 9 (549-557).

"Update the goal, scoring tiers, diagram, API, caching note, performance target,
and test plan" leaves the writing and decisions to the implementer.

**Recommendation:** provide the replacement outline or target text per section.

### 13. Window and constant names drift

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** lines 459, 479, 490, 503, 546; 459-460.

The window has four names: "engine-owned 60-day window," "the engine's history
window," "the engine's 60-day window," and "the history window." The gate
constants are unnamed.

**Recommendation:** use `historyWindowDays` and quote 60 once. Name the constants
with values: `_pairMinObservations = 2`, `_pairMinContextMass = 1_000_000`.

### 14. "run" is undefined in the plan

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** lines 458, 466, 515.

`CONTEXT.md` has no `Run`. The plan says "run ids" and "both preceding ids" for
the same values.

**Recommendation:** define "collapsed run" in one line at first use and use it
consistently.

### 15. Test labels are inaccurate or untestable

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** lines 513, 518, 521.

"Midnight Split" breaks the glossary term `MidnightSplit`. "The half-life gate
boundary" conflates the 14-day decay with the pair gate. "A 6,000-Record
performance guard" carries no threshold.

**Recommendation:** use `MidnightSplit`, call the gate the pair gate, and state
"assert `rank` for 6,000 non-UTC Records completes under 5 ms."

### 16. Manual checks are not executable

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** lines 584-591.

"Label a routine that shares an immediate predecessor" specifies no fixture, no
target instant, and no expected order. "Confirm the three surfaces agree" omits
that they request 4, 6, and 3 candidates, so only the top item can match.

**Recommendation:** give the Records to create and the expected top-1 per
surface.

### 17. The test count is stale

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** line 580.

"Current count: 38 tests" is unverifiable from the document and wrong after item
5 adds tests.

**Recommendation:** drop the absolute count or state the expected delta.

## Nits

- **API sketch omits `static`** (lines 248-266). `historyWindowDays`,
  `historyWindow`, and `contextFromHistory` are static in code.
- **Boundary list omits two return paths:** `limit <= 0` and all-archived
  candidates both return `const []`.
- **Verification command conflict:** the plan says `flutter analyze`; the
  repository's stated command is `dart analyze`.
- **Release behavior for second-without-first is undocumented.** The assert is
  stripped in release.
- **Shared fixtures are not named.** Item 5 should name `makeActivity`,
  `makeRecord`, `ordered`, `zoneUtc`, `zoneNY`.
- **`concepts_brief.md` has no path; `design_draft.md` is undefined.**
- **"Caching note" is undefined**; no such section exists in the document.
- **"archived" versus "tombstoned"**: confirm they are the same lifecycle state
  or distinguish them.
- **Filler rationale** at lines 472-473: "This is the feature" adds nothing.
- **"unit and integration tests"** mislabels the call-site tests that the same
  document calls "Call-site tests."

## Traceability Matrix

| ID | Severity | Consolidated finding | Sources |
| --- | --- | --- | --- |
| 1 | Blocker | No phases or checkpoints | `egm-implementation-readiness` |
| 2 | Blocker | Hour-wrap and zone basis missing | `egm-implementation-readiness` |
| 3 | Blocker | Window-edge arithmetic and cutoff disagree | `egm-implementation-readiness`, `egm-codebase-details` |
| 4 | Blocker | Run resets contradict §3 and §9 | `egm-style`, `egm-implementation-readiness` |
| 5 | Major | Trigram gate under-specified | `egm-implementation-readiness` |
| 6 | Major | Test plan topics, not cases | `egm-implementation-readiness` |
| 7 | Major | No caller context regression test | `egm-implementation-readiness` |
| 8 | Major | Dashboard test claim is false | `egm-codebase-details` |
| 9 | Major | Tense and file markers contradict status | `egm-codebase-details`, `egm-style` |
| 10 | Major | Future-dated Records break one context source | `egm-codebase-details` |
| 11 | Major | Dashboard empty-history conflict | `egm-implementation-readiness`, `egm-design` |
| 12 | Major | Docs edits open-ended | `egm-implementation-readiness` |
| 13 | Major | Window and constant names drift | `egm-style` |
| 14 | Major | "run" undefined in plan | `egm-style` |
| 15 | Major | Test labels inaccurate | `egm-style` |
| 16 | Major | Manual checks not executable | `egm-style` |
| 17 | Major | Test count stale | `egm-style` |
