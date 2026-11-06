# Zoom Out Review Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md` (lines 1-600)
**Stage:** 5, Initial Zoom Out
**Reviewer:** `egm-zoom-out`
**Standard:** `zoom-out-standard.md`

## Findings

### Unbounded query growth on the highest-cost path

**Severity:** 🔴 Blocker

**Affected scope:** Open Questions Q1; §8 Caller changes; Non-Functional
Requirements (Performance and Battery); Future Improvements.

The design widens the notification and watch history from 14 to 60 days and runs
it on every Lap change, then records the cost as unmeasured and defers the remedy
to "profile later, then maybe cache or cap." That upgrades a battery- and
latency-critical surface on faith. The simplest guard is available now, in the
same query: cap the row count to the newest N thousand. The engine already drops
rows past 60 days and decays the rest, so a cap is behaviorally near-identical.
Deciding that in the design costs one line; deferring it leaves the watch paying
roughly four times the rows per Lap change with no bound.

### `SuggestionContext` is only half-wired

**Severity:** 🟡 Major

**Affected scope:** §7 Public API; §3 Runs, not Records (lines 245-271).

`contextFromHistory` returns a value type, but `rank` takes its two fields
separately, so every caller unpacks it, and the type appears nowhere outside the
engine. The optional second id plus a debug-only assert also encode an invalid
state (`second` without `first`) that the type could make unrepresentable. The
simplest form is `rank(context: SuggestionContext)`. As written the type adds a
hop without owning a boundary.

### The pipeline is triplicated the same way the windows were

**Severity:** 🟡 Major

**Affected scope:** §8, and the shipped `_chipActivities`, `_tileActivityIds`,
and Dashboard load.

The goal "one context source" stops at the context. Query, order,
`contextFromHistory`, `rank`, and the suggested-then-fill ranking are about
fifteen near-identical lines in the notification and wearable services, plus a
variant in the Dashboard. That duplication produced the 30-day/14-day split this
design exists to remove; the design reproduces the shape and declares success. A
single shared entry point (history in, ranked ids out, in `lib/core/state`) would
prevent the next drift.

### An existing ranking helper is now dead and unaccounted for

**Severity:** 🟡 Major

**Affected scope:** entire plan; `lib/core/state/activity_ranking.dart`.

`rankActivitiesByUse` has no references in `lib/` or `test/`. The design
supersedes the fallback fill but never states whether this helper is deleted,
repurposed, or left orphaned. A design that claims to consolidate ranking should
name the disposition of the ranking code it replaces.

### Two gate thresholds where one is justified

**Severity:** 🟡 Major

**Affected scope:** §4 Markov-2 gate; Goals.

The goals never ask for "two observations"; the gate appears first in §4. The
1,000,000 mass threshold is defined as one fresh observation, which already
handles staleness, and the count threshold only rejects a single fresh
observation. Two tuned constants guard one property, and the document concedes
the constants rest on reasoning, not a corpus. One rule would be simpler and
easier to explain.

### The document is both a record and a forward plan

**Severity:** 🟡 Major

**Affected scope:** Overview line 24 versus Detailed Implementation Plan
(450-596).

Status "In Review" and "the design is already implemented" sit above a plan of
"Proposed Changes / Create" items, including process artifacts
(`concepts_brief.md`, this document) and test-rename choreography. A reviewer
cannot tell what is being approved. Either drop the plan to a short "what
shipped" delta, or drop the "implemented" claim.

### Micro-unit regime and weight table are optimization-first

**Severity:** 🟡 Major

**Affected scope:** §2 Decay weights; Alternatives C and D.

The integer scale and 61-entry table exist to avoid a cross-platform ulp tie
that nothing demonstrates, and to remove `pow` from a 6,000-iteration loop that
costs well under a millisecond. The candidate-index tie-breaker already
stabilizes equal scores. Keep determinism, but present it as a convention, not
as a measured need.

### Vocabulary drift

**Severity:** 🟢 Nit

**Affected scope:** The Problem; Goals; CUJs.

"habit" and "routine" run throughout; `CONTEXT.md` avoids "habit" for Activity,
and `PRODUCT.md` bans evaluative framing. This document becomes source material
for future copy and test names.

### Asymmetric adjacency reads as one rule

**Severity:** 🟢 Nit

**Affected scope:** §3.

The context skips Untracked; the training chain breaks at it. The section
presents both under "Runs, not Records," inviting a future implementer to unify
them.

## Merit

The problem statement is concrete, the alternatives are honestly costed, the
non-goals are genuinely restrictive, and the tie-breaking story is coherent. The
context is sufficient to review; the issues above are design and scope, not
comprehension.
