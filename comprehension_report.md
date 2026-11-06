# Comprehension Report

**Target:** `docs/designs/decayed_markov_2_activity_suggestions.md`
**FeatureRange:** lines 1-449
**DetailedRange:** lines 450-600
**Stage:** 6, Comprehension Test
**Reviewer:** `egm-comprehension`

## What this proposes

Replace Tempo's flat-count activity ranking with decayed evidence: every
observation is weighted by a 14-day half-life inside a 60-day window, and
Markov-2 (two preceding runs -> next Activity) becomes the top ranking tier, but
only when that pair clears an evidence gate; otherwise the comparator falls back
to Markov-1, then temporal slot, then decayed frequency, then candidate index.
Consecutive Records with the same Activity collapse into one run so MidnightSplits
do not fabricate `Sleep -> Sleep` transitions, and Untracked Records break the
training chain while still being skipped when the query's last two runs are
derived. All three surfaces (Dashboard, notification chips, watch tile) query the
same 60-day snapshot and derive context from it, removing separate last-two
queries. The design is already implemented; it records what shipped and leaves
the end-to-end query cost as the open measurement.

## How the existing system works, per this document

Suggestions were ranked by flat counts: Markov-1 transitions, a ±1 hour temporal
slot split by weekday versus weekend, and overall frequency. History was clipped
at 30 days on the Dashboard and a shared 14-day window on the notification and
watch paths, producing a visible cliff and different rankings per surface.
Callers supplied the preceding Activity from separate last-two-Record or
last-closed queries, which could disagree with the ranked chain.

## Findings

### 1. "Trigram" and "bigram" are never mapped to Markov-2 and Markov-1

**Severity:** 🟡 Major

**Affected scope:** §4, Alternative A, test plan (lines 95, 200-226, 303, 519).

The document uses "trigram" and "bigram" as synonyms for Markov-2 and Markov-1,
but the mapping is never stated. Line 303 puts both in one sentence ("one stray
`(A, B) → D` outranks a daily `B → C` habit"). A reader must reverse-engineer
that trigram = pair plus outcome = Markov-2 tier, and bigram = Markov-1 tier,
from the code block or the source.

### 2. Process terms and artifacts are undefined

**Severity:** 🟡 Major

**Affected scope:** Overview and Additional Resources (lines 24, 44, 424,
562-564).

"The review", "the Goldfish review", and `/egm-draft` are team-process
artifacts with no inline definition or link. The document says the review "added
three implementation hazards" and that an undefined command "consumes"
`concepts_brief.md`, so a fresh reader cannot tell what produced these decisions
or what `concepts_brief.md` is for.

### 3. The open performance risk names untraceable methods

**Severity:** 🟡 Major

**Affected scope:** Open Question 1, NFRs, Future Improvements (lines 89-93,
408-410, 431, 595).

`publish()` and `_loadData()` are named as the unmeasured cost centres with no
file, class, or owner. Two services expose a `publish()`-style path, and neither
method is described, so the one open risk in the design is untraceable.

### 4. "Every Lap change" is undefined

**Severity:** 🟡 Major

**Affected scope:** Open Question 1 (line 89).

"Every Lap change" is the stated trigger but is never defined. `CONTEXT.md`
defines Lap but not the events that change it (label, Split, Edge edit,
MidnightSplit, watch or deep-link action). The cost argument depends entirely on
that frequency.

### 5. The surface contract omits the fill-remaining rule

**Severity:** 🟡 Major

**Affected scope:** §6 diagram, §8, CUJ 1-2, §9 (lines 110-121, 240-242, 280,
285-295).

The diagram says "top 6" and "top 3", but both callers fill unused slots with
remaining Activities in their own order (notification `_chipActivities`,
wearable `_tileActivityIds`). Nothing states this padding rule, so "Dinner leads
the six chips" and "Commute leads the three tile slots" cannot be reasoned
about, and the cold-start behavior of each surface is undefined.

### 6. "Gap" carries two meanings and conflicts with the glossary

**Severity:** 🟡 Major

**Affected scope:** §2, §3, §9, Alternative F (lines 174-177, 186-194, 291-292,
352-356).

"Gap" is used for "record that contributes nothing" while §3 also claims
Untracked "resets the training chain". §2 never says future or out-of-window
records also reset the chain (the engine does), which is the observable
difference between skipping and resetting. `CONTEXT.md` explicitly lists "gap"
as a word to avoid for Untracked Record, so the same noun now means two
different things.

### 7. Context mass overstates its coverage

**Severity:** 🟢 Nit

**Affected scope:** §4 (line 204).

"Context mass counts every outcome of the pair" overstates it: an Untracked
outcome resets the chain and never counts. Open Question 2's phantom-mass
argument rests on this detail.

### 8. "Completed trigram observations" is undefined

**Severity:** 🟢 Nit

**Affected scope:** §4 (line 200).

"Completed trigram observations" is undefined. All Records are closed, so
"completed" reads as excluding the most recent run, which is not what the
engine does.

### 9. The API block is not a usable signature

**Severity:** 🟢 Nit

**Affected scope:** §1, §7, §2 (lines 156-166, 245-267, 170).

The API block mixes a class with an untyped member list, shows
`historyWindowDays` and `historyWindow` as apparent duplicates, and omits
`required` so the real named-parameter signature looks positional.
"Micro-weight" and "micro-unit" alternate, and the 1,000,000-per-observation
base is only inferable from the decay formula.

### 10. The static-analysis command contradicts the repository

**Severity:** 🟢 Nit

**Affected scope:** Verification Plan (line 576).

`flutter analyze` contradicts the repository's stated static-analysis command
(`dart analyze`).
