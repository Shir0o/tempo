# Critic Review Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md`
**Stage:** 7, Critic Review
**Audit scope:** FeatureRange, lines 1-449
**Standard:** `feature-spec-standard.md`
**Reviewers:** `egm-design`, `egm-structural`, `egm-style`

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-design` | completed |
| `egm-structural` | completed |
| `egm-style` | completed |

## Prioritized Findings

### 1. The 60-day query cost is unbounded and mis-scoped

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-design`, `egm-zoom-out`
**Affected scope:** Open Question 1 (89-93); §6 (231-243); §8 (273-283);
Non-Functional Requirements (404-410); Future Improvements (431-433).

The 1.2 ms figure covers only the pure `rank` walk. The real per-event cost is
`getRecords`, which hydrates every row and issues a chunked `record_tags` query
per 500 rows. At 6,000 rows that is 12 extra queries and 6,000 deserializations
on every record commit, every `publish()` (including the 3-second Undo settle),
and every watch refresh. There is no `limit` and no row cap. A user splitting
every five minutes produces about 17,280 rows in 60 days, not 6,000.

**Recommendation:** project only `activity_id, started_at_epoch_ms,
timezone_id` for ranking, bound the query, and measure commit-to-notification
p95 on a mid-range device before shipping. Decide the cap in the design rather
than deferring it.

### 2. Risks, rollout, and quality evidence are not consolidated

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-structural`, `egm-design`
**Affected scope:** entire feature specification; Non-Functional Requirements
(399-415); Rollout (413-415); Future Improvements (431-446).

The feature-spec standard requires failure modes and their mitigations. There is
no `## Risks & Mitigations` section. Risk-shaped content is dispersed across The
Problem (44-48), Open Questions (87-101), and Non-Functional Requirements. The
document also claims "reverting the commit rolls it back," which is false for
users who already updated: store releases are not retroactive. There is no
feature flag, no shadow mode, no numeric rollback trigger, and no quality signal
beyond unit tests that pin the implementation's own constants and a synthetic
performance test.

**Recommendation:** add one consolidated risk-to-mitigation section, define a
local flag or device-local shadow comparison, record an on-device top-3 hit-rate
counter rebuilt from the next label (no network), and state a numeric rollback
trigger.

### 3. "habit" is used for an Activity, which the project bans

**Severity:** 🔴 Blocker
**Reviewer lens:** `egm-style`
**Affected scope:** lines 40-41, 99, 123, 129-130, 303-304, 375, 441.

`CONTEXT.md` lists "habit" under `Activity -> Avoid`. It imports streak and goal
framing that the product forbids. The word appears in the Problem, Goals, CUJ 3,
Alternative A, Alternative H, and Future Improvements.

**Recommendation:** replace with the domain term. "A pattern does not fade at
the edge" (40); "outrank a strong Markov-1 sequence" (99); "CUJ 3: A new sequence
replaces an old one" (123); "the older sequence" (129-130); "a daily `B -> C`
sequence" (303-304); "the pattern problem" (375); "displacing a strong Markov-1
sequence" (441).

### 4. Gap-bridging context contradicts gap-breaking training

**Severity:** 🟡 Major
**Reviewer lens:** `egm-design`, `egm-comprehension`
**Affected scope:** §3 (191-194); Alternative F (348-356); §9 (291-292).

`contextFromHistory` skips Untracked rows, so `A, untracked, B` returns `(B, A)`,
but the rank walk resets the chain at the gap. That pair can never match on the
tail. Evidence can only come from an older contiguous `A -> B`, so the gate can
activate on unrelated history while the true second-preceding run is unknown.
The document calls this "useful"; it is neither useful nor honest.

**Recommendation:** break the context at gaps too, or state the intended
semantics and add a test for the `A, untracked, B` case.

### 5. A known comparator defect ships undecided

**Severity:** 🟡 Major
**Reviewer lens:** `egm-design`
**Affected scope:** Open Question 3 (98-101); §4 (210-213); Alternative A
(299-306).

The gate protects the pair, not the outcome. Once a pair is established, any
candidate with a token trigram score (for example 51,000 from one 60-day-old
observation) outranks a strong Markov-1 sequence with zero trigram. Open
Question 3 asks whether to fix this; a question is not a mitigation.

**Recommendation:** normalize within the tier (trigram score divided by context
mass) or add the per-outcome floor now, and test it.

### 6. Core constants are asserted, not evaluated

**Severity:** 🟡 Major
**Reviewer lens:** `egm-design`, `egm-zoom-out`
**Affected scope:** Goals (52-58); §2 (163-177); §4 (196-208).

The 14-day half-life, 60-day window, two-observation minimum, and
1,000,000-micro mass floor have no alternatives and no sensitivity analysis. The
combined gate rejects a pair seen twice 20 days ago (0.37 + 0.37 < 1.0) while
accepting one seen once today and once 30 days ago. Two tuned constants guard
one property. The alternatives cover architecture, not the parameters that are
the feature.

**Recommendation:** add a parameter table with rejected values and the
acceptance envelope. Consider whether the mass floor alone is enough; if so,
remove the count threshold.

### 7. Non-goals contradict the proposed remedy

**Severity:** 🟡 Major
**Reviewer lens:** `egm-design`
**Affected scope:** Non-Goals (85); Open Question 1 (93); Future Improvements
(431-433).

Non-goals forbid "a cache or precomputed index," while Open Question 1 and Future
Improvements propose a query cache as the fallback.

**Recommendation:** either allow a bounded query or remove the cache as a
fallback and state the alternative (row cap, projection, smaller watch window).

### 8. `SuggestionContext` is half-wired

**Severity:** 🟡 Major
**Reviewer lens:** `egm-zoom-out`, `egm-design`
**Affected scope:** §7 (245-271); §1 (136-138).

`contextFromHistory` returns a value type, but `rank` takes its two fields
separately, so every caller unpacks it and the type owns no boundary. The
optional second id plus a debug-only assert encode an invalid state that the
type could make unrepresentable. The "single context source" guarantee exists
only by convention.

**Recommendation:** accept one context object in `rank`, or derive the context
inside `rank` from the history snapshot. Make the invalid state unrepresentable.

### 9. The caller pipeline is triplicated

**Severity:** 🟡 Major
**Reviewer lens:** `egm-zoom-out`
**Affected scope:** §8 (273-283); shipped `_chipActivities`,
`_tileActivityIds`, and the Dashboard load.

Query, order, `contextFromHistory`, `rank`, and the suggested-then-fill ranking
are about fifteen near-identical lines in the notification and wearable
services, plus a variant in the Dashboard. That duplication produced the
30-day/14-day split this design exists to remove.

**Recommendation:** add one shared entry point in `lib/core/state`: history in,
ranked ids out.

### 10. The replaced ranking helper is unaccounted for

**Severity:** 🟡 Major
**Reviewer lens:** `egm-zoom-out`
**Affected scope:** entire plan; `lib/core/state/activity_ranking.dart`.

`rankActivitiesByUse` has no references in `lib/` or `test/`. The design
supersedes the fallback fill but never states whether the helper is deleted,
repurposed, or left orphaned.

**Recommendation:** name the disposition in the plan.

### 11. The document is both a record and a forward plan

**Severity:** 🟡 Major
**Reviewer lens:** `egm-zoom-out`, `egm-structural`
**Affected scope:** Overview (24-25) versus Detailed Implementation Plan
(450-596); §Technical Plan title (132).

Status "In Review" and "the design is already implemented" sit above a plan of
"Proposed Changes / Create" items, including process artifacts and test-rename
choreography. The parenthetical "(Architecture)" signals an unresolved title and
collides with the later implementation plan. A reviewer cannot tell what is
being approved.

**Recommendation:** decide the document's purpose. Either rewrite the plan as a
short "what shipped" delta, or remove the "implemented" claim and review it as a
forward design.

### 12. Micro-unit regime and weight table are optimization-first

**Severity:** 🟡 Major
**Reviewer lens:** `egm-zoom-out`
**Affected scope:** §2 (163-177); Alternatives C and D (319-336).

The integer scale and 61-entry table avoid a cross-platform ulp tie that nothing
demonstrates, and remove `pow` from a loop that costs well under a millisecond.
The candidate-index tie-breaker already stabilizes equal scores.

**Recommendation:** keep determinism, but present the integer convention as a
design choice, not a measured need.

### 13. Trigger frequency is undefined

**Severity:** 🟡 Major
**Reviewer lens:** `egm-comprehension`
**Affected scope:** Open Question 1 (89).

"Every Lap change" is the stated trigger but is never defined. `CONTEXT.md`
defines Lap but not the events that change it: label, Split, Edge edit,
MidnightSplit, watch action, deep link. The cost argument depends on that
frequency.

**Recommendation:** enumerate the events and their expected frequency.

### 14. The fill-remaining rule is omitted

**Severity:** 🟡 Major
**Reviewer lens:** `egm-comprehension`
**Affected scope:** §6 (240-242); §8 (280); CUJ 1-2 (105-121); §9 (285-295).

The diagram says "top 6" and "top 3," but both callers fill unused slots with
remaining Activities in their own order. Nothing states this padding rule, so
the CUJs cannot be reasoned about and cold-start behavior per surface is
undefined.

**Recommendation:** state the fill-remaining rule and the cold-start behavior
for each surface.

### 15. "Trigram" and "bigram" are never mapped to the Markov tiers

**Severity:** 🟡 Major
**Reviewer lens:** `egm-comprehension`
**Affected scope:** §4 (200-226); Alternative A (303); test plan (519).

The terms are used as synonyms for Markov-2 and Markov-1, but the mapping is
never stated. A reader must reverse-engineer it from the code block or source.

**Recommendation:** define both terms once, next to the tier names.

### 16. Process artifacts are undefined

**Severity:** 🟡 Major
**Reviewer lens:** `egm-comprehension`
**Affected scope:** Overview (24, 44); Additional Resources (424, 562-564).

"The review," "the Goldfish review," and `/egm-draft` are team-process artifacts
with no inline definition or link. A fresh reader cannot tell what produced the
decisions or what `concepts_brief.md` is for.

**Recommendation:** define or link them once, or move the process history out of
the design document.

### 17. Structural layout issues

**Severity:** 🟡 Major
**Reviewer lens:** `egm-structural`
**Affected scope:** Additional Resources (419); Future Improvements (429); Open
Questions (87); Problem header (27).

`Additional Resources` and `Future Improvements` are H3s that function as
top-level back matter, so a generated table of contents nests them under
Non-Functional Requirements. Open Questions sits before the architecture and
CUJs even though its questions reference terms introduced later. The required
"Problem Statement" header is renamed "The Problem."

**Recommendation:** promote the appendices to H2 or move them after the
implementation plan, move Open Questions after the architecture or into the risk
section, and use the standard header name.

### 18. "Smooth decay" contradicts the whole-day bucket

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** Goals (52-54); §2 (165-166); Alternative C (321-322).

The goals promise smooth decay, while the design uses a whole-day table and
Alternative C calls the alternative "continuous rather than bucketed by day."

**Recommendation:** rename the goal to "daily-stepped decay" and state the
61-entry bucket explicitly.

### 19. `ageDays` is described as fractional but implemented as whole days

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** §2 (168-172).

The formula shows a division that reads as fractional, while the table is
whole-day. The truncation rule and the UTC basis are unstated, even though the
temporal slot uses local hours.

**Recommendation:** write `ageDays = floor((targetEpochMs -
startedAtEpochMs) / 86_400_000)`, state that it is UTC-based, and state that the
temporal slot uses the local hour.

### 20. Unmeasurable and false-agency phrasing

**Severity:** 🟡 Major
**Reviewer lens:** `egm-style`
**Affected scope:** lines 29, 33-34, 128-130, 44, 194, 206, 306, 101, 316, 446.

Examples: "make the current suggestions worse than the history they are built
from"; "a routine the user stopped"; "the training chain stays honest"; "whether
the pair is a real routine"; "This is the exact failure"; "This is standard
backoff behavior"; "too brittle." None are measurable, and several attribute
agency to arithmetic or to a review.

**Recommendation:** rewrite as measured comparisons or consequences of the
specified rule. For example, "This follows from the tier order in §5"; "if
replay shows top-3 hit rate falls below Markov-1 for the same history."

### 21. "query" is overloaded

**Severity:** 🟢 Nit
**Reviewer lens:** `egm-style`
**Affected scope:** line 154 versus 89, 279.

"Query" means the ranking input in one place and a SQL query in another.

**Recommendation:** call the ranking input the request context or the context
pair; reserve "query" for SQL.

### 22. The 64-bit headroom is unquantified

**Severity:** 🟢 Nit
**Reviewer lens:** `egm-style`
**Affected scope:** lines 176-177.

"Far below the 64-bit limit" is not a number. The largest single accumulator is
61 x 1,000,000 = 61,000,000.

### 23. Surface names drift

**Severity:** 🟢 Nit
**Reviewer lens:** `egm-style`
**Affected scope:** lines 13, 110, 118, 242.

"Today Dashboard", "chips", "Wear tile", and "watch tile" vary.

**Recommendation:** choose one name per surface.

### 24. Unreachable empty-history behavior

**Severity:** 🟢 Nit
**Reviewer lens:** `egm-design`
**Affected scope:** §9 (286-287); `dashboard_view.dart:211`.

Empty history "returns candidates in original order" never reaches Dashboard
users: the view short-circuits to an empty suggestion list.

**Recommendation:** state the surface behavior or add a test.

### 25. Minor formatting and terminology issues

**Severity:** 🟢 Nit
**Reviewer lens:** `egm-structural`, `egm-style`
**Affected scope:** front matter (3-5); thematic breaks (7, 397, 417, 448);
numbering schemes; Additional Resources (421-427); "cliff" (39-40, 363);
"phantom mass" (97); "accident" (305); "earn their complexity" (385); "churn"
(392); "runs" and "established" before definition (55, 62, 198); "desktop quick
popover" (84); `concepts_brief.md` without a path (424); repeated no-dependency
constraints (21-22, 69-70, 75-85, 368-376, 401-403).

**Recommendation:** normalize list markers and thematic breaks, use one numbering
convention, add relative links, replace "cliff" with "discontinuity," define
"runs" and "established" before first use, use `QuickPopover`, add the
`concepts_brief.md` path, and state the no-dependency constraint once.

## Traceability Matrix

| ID | Severity | Consolidated finding | Sources |
| --- | --- | --- | --- |
| 1 | Blocker | 60-day query unbounded and mis-scoped | `egm-design`, `egm-zoom-out` |
| 2 | Blocker | Risks, rollout, and quality evidence not consolidated | `egm-structural`, `egm-design` |
| 3 | Blocker | "habit" violates project vocabulary | `egm-style` |
| 4 | Major | Gap-bridging context contradicts gap-breaking training | `egm-design`, `egm-comprehension` |
| 5 | Major | Rare-outcome comparator defect ships undecided | `egm-design` |
| 6 | Major | Constants asserted; two thresholds for one property | `egm-design`, `egm-zoom-out` |
| 7 | Major | Non-goals contradict the cache fallback | `egm-design` |
| 8 | Major | `SuggestionContext` half-wired | `egm-zoom-out`, `egm-design` |
| 9 | Major | Caller pipeline triplicated | `egm-zoom-out` |
| 10 | Major | Dead `rankActivitiesByUse` unaccounted | `egm-zoom-out` |
| 11 | Major | Document is both record and forward plan | `egm-zoom-out`, `egm-structural` |
| 12 | Major | Micro-unit/table optimization-first | `egm-zoom-out` |
| 13 | Major | Trigger frequency undefined | `egm-comprehension` |
| 14 | Major | Fill-remaining rule omitted | `egm-comprehension` |
| 15 | Major | Trigram/bigram not mapped to tiers | `egm-comprehension` |
| 16 | Major | Process artifacts undefined | `egm-comprehension` |
| 17 | Major | Structural layout issues | `egm-structural` |
| 18 | Major | "Smooth decay" contradicts whole-day bucket | `egm-style` |
| 19 | Major | `ageDays` fractional vs whole-day | `egm-style` |
| 20 | Major | Unmeasurable and false-agency phrasing | `egm-style` |
| 21 | Nit | "query" overloaded | `egm-style` |
| 22 | Nit | 64-bit headroom unquantified | `egm-style` |
| 23 | Nit | Surface names drift | `egm-style` |
| 24 | Nit | Empty-history behavior unreachable | `egm-design` |
| 25 | Nit | Formatting and terminology issues | `egm-structural`, `egm-style` |
