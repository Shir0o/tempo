# Intermediate Zoom Out Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md` (lines 1-600)
**Stage:** 8, Intermediate Zoom Out
**Reviewer:** `egm-zoom-out`
**Standard:** `zoom-out-standard.md`
**Prior reports:** `zoom_out_report.md`, `comprehension_report.md`,
`critic_report.md`

## Verdict

The earlier reports hold up: the query blocker, caller triplication, the
half-wired context type, dead `rankActivitiesByUse`, and the record-versus-plan
ambiguity are real. Two proposed mitigations are wrong or oversized. No new
blocker appeared.

## Findings

### 1. The context type, helper, and optional parameter are removable

**Severity:** 🟡 Major

**Affected scope:** §3, §7, §8, Alternative F; `suggestion_engine.dart`.

`rank` already receives the history it would need. `SuggestionContext` is a pure
function of that argument, and nothing consumes it except the three call sites
that immediately unpack it. Deriving the pair inside `rank`, using the chain rule
rather than the skip-null rule, deletes the value type, `contextFromHistory`, the
optional `secondPrecedingActivityId`, the debug assert, and three unpacks. It
also dissolves critic finding 4: `A, untracked, B` currently returns `(B, A)`
for the query while the walk resets at the same gap, so the pair can never match
the tail. That contradiction is untested; the "gap breaks the chain" test hands
`rank` a pair its own history cannot produce.

This makes critic finding 8's "accept one context object" the weaker fix: a
wrapper where deletion is available.

### 2. Keep both gate constants

**Severity:** 🟡 Major

**Affected scope:** §4; Alternatives A and B.

Mass-only admits one fresh observation (mass = 1,000,000), which is the stray
`(A, B) -> D` failure the gate exists to stop. The count rejects a single fresh
one-off; the mass rejects repeats too stale to trust. They guard two properties,
not one. Present them as a single predicate with one stated intent ("seen at
least twice, and still worth one fresh observation"), not as two tunable knobs,
but do not remove either.

### 3. The shared entry point is the right fix only if it stays a function

**Severity:** 🟡 Major

**Affected scope:** §8; `_chipActivities`, `_tileActivityIds`, Dashboard load.

The notification and wearable query-context-rank blocks are identical apart from
`limit` and return type. A ten-line function in `lib/core/state` that owns
`limit`, fill-remaining, and empty behavior removes about 45 lines and closes
comprehension findings 5 and 14. It must not become a service or a cache, which
would violate non-goal line 85 and reinstate the drift it removes.

### 4. The rollout mitigation is disproportionate

**Severity:** 🟡 Major

**Affected scope:** NFR Rollout; Future Improvements.

A feature flag, a shadow comparison, and a production hit-rate counter are three
new mechanisms for a change that reorders a list and persists nothing. Simpler
and honest: ship without a flag, delete the false "reverting the commit rolls it
back" claim (store releases are not retroactive), and state that rollback means
the next release. If quality evidence is required, get it from the offline replay
harness over historical or synthetic histories.

### 5. The query-cost fix is projection, not a cache

**Severity:** 🟡 Major

**Affected scope:** Open Question 1; §8; NFR Performance.

`getRecords` hydrates full `Record`s and issues one `record_tags` query per 500
rows. At 6,000 rows that is 12 queries whose results no ranking path reads.
Skipping tags (`includeTags: false`, or a lean read) is the minimal mitigation
and needs no cache, index, or model. A plain `LIMIT` is not enough: with the
required ascending order it returns the oldest rows and discards the newest
evidence. Any cap needs a descending read and reverse, or a run-count band.

### 6. Open Question 2 is already answered by shipped behavior

**Severity:** 🟡 Major

**Affected scope:** Open Question 2; `test/core/suggestion_engine_test.dart:560`.

The test "context mass counts outcomes that are not candidates" pins exactly the
tombstoned-id mass that Q2 calls open. The document asks a question its own test
suite has already decided. Close Q2 as accepted, or add the rule (a tombstoned id
breaks the chain like an Untracked Record) and change the test. Deferring leaves
the design contradicting its tests.

### 7. The Dashboard keeps the duplicate tail query the design rejects elsewhere

**Severity:** 🟢 Nit

**Affected scope:** §8 Dashboard; Alternative E.

Alternative E removes the separate last-two query because the snapshot already
holds the tail. The Dashboard nonetheless keeps a second `limit: 1` query for
`_lastActivity`. Reuse the snapshot tail, or state why the 60-day edge case
justifies the extra query.

### 8. Micro-unit regime: keep it, drop the justification

**Severity:** 🟢 Nit

**Affected scope:** §2; Alternatives C and D.

It is implemented, cheap, and harmless. Only the claim that it answers a
demonstrated ulp problem is unsupported. Present it as a convention.

## Residual Architectural Risks

1. End-to-end 60-day query cost per Lap change is still unmeasured on device.
2. No product-quality evidence exists for the tier order; every constant rests on
   reasoning.
3. Four-step routines remain outside the model by design.
4. Surface drift will recur unless the duplicated pipeline becomes one function.
5. Tombstoned Activities may keep contributing gate mass until Open Question 2 is
   closed.
