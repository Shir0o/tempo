# Consolidated Review Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md`
**Reviewed:** 2026-11-06
**Mode:** Consolidated full flow (Stages 5–9)
**Semantic split:** FeatureRange 1–450, DetailedRange 451–618
**Artifacts:** `zoom_out_report.md`, `comprehension_report.md`,
`critic_report.md`, `intermediate_zoom_out_report.md`,
`implementation_readiness_report.md` (same directory)

## Verdict

The design is honest about its weakest premise and unusually good on
alternatives, but it is larger than its evidence and currently carries three
contradictions that make its own voice journey unimplementable as written. The
core shape — a typed filter as the feature, voice as a platform hand-off — holds.
The current container choice and the Android result plumbing do not.

The most consequential finding is architectural: building the filter inside the
dashboard's scroll view manufactures scroll restoration, back-press ownership,
tab-change clearing, and keyboard occlusion as four separate problems, when the
repo already has a modal picker pattern that solves all four.

## Reviewer Status

| Stage | Reviewer | Status |
| --- | --- | --- |
| 5 | `egm-zoom-out` | completed |
| 6 | `egm-comprehension` | completed |
| 7 | `egm-design` | completed |
| 7 | `egm-structural` | completed |
| 7 | `egm-style` | completed |
| 8 | `egm-zoom-out` | completed |
| 9 | `egm-implementation-readiness` | completed |
| 9 | `egm-codebase-details` | completed |
| 9 | `egm-style` | completed |

## Priority Summary

| Priority | Count |
| --- | --- |
| Blocker | 4 |
| Major | 14 |
| Nit | 12 groups |

--------------------------------------------------------------------------------

## Blockers

### B1. "Close on app pause" destroys the speech hand-off
**Sources:** Stage 5 #1, Stage 6 #1, Stage 7 B1, Stage 8 #6, Stage 9 B1.
**Scope:** 162–167, 272–273, 284, 296, 509–511; repo
`dashboard_view.dart:149–158`.

Launching `ACTION_RECOGNIZE_SPEECH` drives Tempo through `inactive` → `hidden` →
`paused`. The rule "closed and cleared on app pause" therefore clears the field
before `listen()` returns, so CUJ 2 cannot complete and the transcript has
nowhere to land. The pending-listen guard only disables the button.

Fix: close on `paused`/`hidden` only when no recognition is pending; define which
lifecycle states count (`inactive` also fires for the notification shade); add a
paused-with-pending test and a paused-without-pending test. Define the return
matrix for tab switch, activity recreation, cancellation, and a result arriving
after an unrelated label.

### B2. Android result plumbing is three incompatible designs and can regress the backup picker
**Sources:** Stage 7 M1, Stage 8 #8, Stage 9 B2, Stage 6 #9, Stage 5 #16.
**Scope:** 265, 538–554.

The plan names an `ActivityResultLauncher` (unavailable on `FlutterActivity`
without switching to `FlutterFragmentActivity`), an `onActivityResult` override,
and a request code. `BackupDestinationChannel` is the repo precedent:
`FlutterPlugin, ActivityAware` plus `ActivityPluginBinding.addActivityResultListener`,
registered with `flutterEngine.plugins.add(...)`. An override that misses
`super.onActivityResult` breaks the shipped folder picker. "Distinct from the
notification permission code" is misguided: permission results arrive at
`onRequestPermissionsResult`.

Fix: use the ActivityAware plugin seam; `MainActivity` gains one registration
line, not an override.

### B3. A pending recognition result is abandoned, permanently disabling the microphone
**Sources:** Stage 9 B3, Stage 7 M1, Stage 5 #16, Stage 8 #6.
**Scope:** 504, 540–545, 273.

"Clear pending state on activity destroy" drops the stored `MethodChannel.Result`,
so the Dart future never completes and the pending guard keeps the mic disabled
for the session. `BackupDestinationChannel.detach()` resolves the in-flight
result with an error before clearing. Do the same, give a second `listen` a named
error, and note that a Dart future cannot be cancelled, so "clears its pending
callback on dispose" must be `if (!mounted) return`. Add a timeout or justify its
absence.

### B4. The filter is built in the hardest container
**Source:** Stage 8 #1.
**Scope:** 146–167, 275–289, 497–525.

In-place expansion inside the `CustomScrollView` forces a saved scroll offset (no
`ScrollController` exists), a back interceptor (`DashboardView` is not a route), a
tab listener plus notifier plumbing, and a keyboard-versus-context-line argument.
A modal sheet supplies all four for free, and `history_view.dart:171–240`
already opens a `showModalBottomSheet` titled "What was it?" with a swatch/name
row per Activity and returns the selection.

Fix: replace the inline field with that modal pattern, or state the "chips stay
visible while filtering" requirement that forces inline and justify it against
the four problems it imports.

--------------------------------------------------------------------------------

## Majors

### M1. The premise and the headline goal are unverifiable
**Sources:** Stage 5 #2, Stage 6 #7, Stage 7 M4, Stage 8 #4/#5, Stage 9 M9/M10.

Goal 1 uses 40 Activities, at which a filter is guaranteed to help, while
Alternative A says the realistic grid is two to seven rows and the seed is five.
Nothing decides between them. Goal 2 depends on a corpus that does not exist, has
no path, size, schema, or owner, and uses undefined terms ("confident",
"plausible"). The 40-Activity playtest has no seeding mechanism, though the STT
`catalogOnly` import can create one.

Fix: add a pre-registered catalog size or observed scroll frequency and a written
"do not ship" outcome; add `test/fixtures/activity_match_corpus.json` with a
fixed schema and size; name the playtest seeding method.

### M2. Delivery is one batch, with the unmeasured half ahead of the measurable half
**Sources:** Stage 8 #2/#3, Stage 9 M1, Stage 7 M1 (zoom).

Eleven files land together with no phases. The field alone already enables voice
through keyboard dictation, and `tempo://start?activity=` already labels from an
Assistant routine. Fuzzy tiers (reverse prefix, edit distance, "Closest") exist
for recognition error, not typed search, yet they ship in the first slice and
keep the wrong-Record hazard alive.

Fix: phase the work. (1) matcher exact/prefix/substring plus the picker, fully
testable in CI; (2) voice and speech-specific tiers; (3) "Closest" only if the
corpus shows the need. State that reverting phases 2–3 leaves the filter intact.

### M3. The matcher contract is underdetermined
**Sources:** Stage 6 #2/#4, Stage 7 M12, Stage 9 M5/M6/M7/M8, Stage 5 #19.

Unresolved: public API (`rankActivities` vs `ActivityIndex.search`), metric
(Levenshtein vs Damerau), unit (characters vs UTF-16 code units or runes), `limit`
default and ordering, and sort stability (Dart's `List.sort` is not stable).
`tokenPrefix` is a strict subset of `substring` and therefore unreachable. The
archived-exclusion test cannot see archived items if the index is built from the
unarchived list. The edit-distance bands do not say which length governs when the
query and name fall in different bands.

Fix: one signature, one metric, one unit, a stated default and cap, delete or
redefine `tokenPrefix`, choose whether the index filters archived items, and
define `(queryLength, nameLength)` boundary pairs.

### M4. The matcher cannot match normal spoken phrases and can produce confident wrong results
**Sources:** Stage 7 M2/M3, Stage 8 #3.

All tiers anchor to the name. "um, cleaning the kitchen" matches nothing because
the name is not the whole query or a prefix. Conversely, reverse prefix promotes
"workout was hard" to **Work** and "homework" to **Home** as a strong match,
contradicting Goal 2 and Goal 6. Fillers need a token-in-query tier or a
documented filler strip; reverse prefix needs a token boundary and a remainder
constraint, or should be demoted or dropped.

### M5. Lifecycle rules contradict each other and omit two label paths
**Sources:** Stage 5 #10, Stage 6 #3, Stage 7 M9, Stage 8 #9, Stage 9 M4/M24.

"Closed and cleared on label" conflicts with "a label keeps the query". `Split`,
`Same as last`, and external deep-link/broadcast labels are not covered, so a live
query can sit over a newly opened Lap. The failed-label path is unspecified, and
pull-to-refresh retention is dropped from the implementation plan.

Fix: write one sequence per path. Result tap → close → label → reload; refresh →
keep query → rebuild → recompute; `Split` → keep query → re-read Lap; any
successful label closes and clears; a failed label keeps the query and shows the
error.

### M6. Scroll, back, and keyboard mechanics have no implementation
**Sources:** Stage 5 #4/#5, Stage 6 #8, Stage 7 M8/M11, Stage 9 M2/M12, Stage 8 #7.

There is no `ScrollController`; "restore exact offset" is unachievable as
written. There is no `PopScope`; with the IME up the first back dismisses the
keyboard anyway. The field retains focus across the speech hand-off, so Android
re-shows the keyboard and covers the result list the design says stays visible.

Fix if inline is kept: name the `ScrollController`, capture and clamp-restore in a
post-frame callback, name the back mechanism and the two-press rule, and unfocus
before and after recognition with a test assertion.

### M7. Tab notifier and `ActivityIndex` add state without earning it
**Sources:** Stage 5 #6/#7/#9, Stage 8 #12, Stage 9 M3/M17.

`TempoApp` already rebuilds the shell on tab change, so a plain `tabIndex` plus
`didUpdateWidget` would do; a `ValueNotifier<int>` adds a listener, disposal, and
three call-site rewrites with no rebuild benefit, and the plan omits them.
`ActivityIndex` is a premature cache with two invalidation keys
(`catalogRevision` vs `_activities`). Query text is stored twice (controller and
string). The plan also loads the 1,100-line `_DashboardViewState` with the whole
state machine rather than extracting a testable controller.

Fix: pass a plain tab value; delete the index and call a pure rank function on
query change; keep one query source of truth; extract an
`ActivityFilterController`.

### M8. The filter silently ships to macOS, and CUJ 1 is false there
**Sources:** Stage 7 M7, Stage 9 M11, Stage 5 #17.

`DashboardView` is shared, and only `SpeechInput` is nulled. The typed filter
appears on the Mac, where `_labelActivity` goes through `RemoteRecordCommands`,
returns null, and shows "waiting for the phone". The plan's "macOS branch passes
null" also misdescribes `main.dart`, where macOS returns early through
`_startReplica`.

Fix: state the platform scope explicitly and adjust CUJ 1, or render the
magnifier only when a speech/filter capability is injected. Correct the
composition-root description.

### M9. Privacy NFR omits the audio trust boundary and transcript logging
**Sources:** Stage 5 #3, Stage 7 M6, Stage 8 #10, Stage 9 M13.

The recognizer app may be a network service; audio leaves Tempo's trust boundary.
The NFR never says so, never names the Play data-safety check as a release gate,
and never forbids describing the control as on-device. `MainActivity` already logs
user-derived values, so an accidental transcript log is plausible.

Fix: state the boundary, make the data-safety check a merge gate, forbid
on-device copy, and require "never log the transcript, query, or `EXTRA_RESULTS`".

### M10. Filter states are under-specified and the archived path is a dead end
**Sources:** Stage 5 #12/#14, Stage 6 #6/#19, Stage 7 M10/M14/N1/N4, Stage 9 M16/M18.

Clear is used as both "empty the query" and "close", and no clear control exists
in state 2. Any single character replaces the grid, with no minimum length and no
result cap. The context line duplicates the existing heading subtitle. The
magnifier has no size, key, or semantics. The result row has no `DESIGN.md`
contract, no formatter, and its "Closest" flag does nothing. Archived Activities
produce "No active Activity matches" with only Clear, no route to Activities.
Accessibility names "Listening" and "Voice unavailable" states that never render,
and focus transfer is unspecified.

Fix: define clear versus close, a minimum query length and row cap, the exact
context-line replacement, the magnifier and row contracts, and either a "Manage
Activities" action in the empty state or an explicit accepted limitation.

### M11. Test and verification plan cannot prove the claims
**Sources:** Stage 5 #18, Stage 6 #7/#16, Stage 7 M4, Stage 8 #10/#13, Stage 9 M14/M15.

`dart analyze` excludes Kotlin, and no listed command compiles the bridge.
`processDebugMainManifest` names no artifact to inspect; `gradlew` is generated.
The channel wrapper's error mapping is untested. Pause, back, and tab simulations
have no harness details. No test asserts the transcript is not written to a
comment, or that the mic is disabled while pending. The corpus does not exist.
The manual playtest has no catalog seed, viewport, or disabling method.

Fix: add `cd android && ./gradlew :app:compileDebugKotlin`, name the merged
manifest, add a mocked-channel test, specify the lifecycle and back harness,
assert transcript non-persistence, and name the fixture and seed.

### M12. Missing Risks section, and the design system and screenshots are not updated
**Sources:** Stage 7 M5/M8, Stage 9 M14/M18.

Both sibling specs carry a `## Risks & Mitigations` table. This one has none.
Adding heading chrome changes `screenshots/color_blocks_dashboard*.png`, which CI
skips, so the goldens silently go stale, and `DESIGN.md` still describes the old
screen.

Fix: add the risk table (audio egress, process death, stale catalog, false
positives, keyboard occlusion, corpus never authored, macOS surface) and list the
screenshot re-baseline and `DESIGN.md` update.

### M13. Performance bound and input clip are missing
**Sources:** Stage 7 (structural) #10, Stage 9 M8/M12.

The contract accepts "very long input" and the test feeds 10k characters, while
edit distance is quadratic per candidate on the UI thread. Clip the normalized
query (for example 64 characters), add the `|len(a) - len(b)| > threshold`
prefilter and early exit, then state the cost model.

### M14. Result rows duplicate two existing rows without saying so
**Sources:** Stage 5 #8, Stage 7 N3, Stage 9 M18.

`history_view.dart` `_pickActivity` and `quick_popover_view.dart`
`_buildActivityRow` are already swatch/name/tap rows. A third variant is
defensible because the filter row needs a total and a category line, but the
reason given is file size, not reuse, and no `DESIGN.md` tokens are named.

Fix: align the row with the existing ones or extract a shared row with optional
slots, and add the `DESIGN.md` entry.

--------------------------------------------------------------------------------

## Nits

**N1. Contract and API details.** `search(String, {int limit})` does not compile
without a default; "tie-break key" appears in one section and not another;
"scoring uses integers" describes ordering that is really tier plus comparator;
the component map routes through `RecordCommands.label` rather than
`_labelActivity`; the state list omits the query string; request code has no
value; the recognizer action is written two ways. (Stages 5, 6, 9)

**N2. Normalization details.** "Strip boundary punctuation" has no character set;
whether it applies to the whole string or each token is unstated; "one edit at
4–7" has an ambiguous antecedent. (Stage 6 #15, Stage 9 nits)

**N3. Accessibility details.** Labels describe states that never render; the field
semantics and hint are unspecified; focus transfer into and out of the result list
is undefined; the live-region announcement needs throttling. (Stage 7 N1)

**N4. Availability handling.** Session caching hides the mic after one transient
error; asynchronous resolution causes a layout pop-in; three different layers are
named as the cache owner. (Stages 7, 9)

**N5. Context line.** It duplicates the existing heading subtitle, "reuses" a
widget that does not exist, and "compact" has no value. (Stages 6, 7, 9)

**N6. Vocabulary and copy.** "No active Activity matches" uses a non-domain word;
"Lap" and "Record" are not glossed at first use; "every Activity" ignores archived
exclusion. (Stages 6, 7)

**N7. Editorial.** "rare action" asserts an unknown frequency; "seeded catalog"
means both five and forty; "microseconds" is unmeasured; "weakest part of the
case" is review commentary; metaphors and intensifiers ("load-bearing", "degrade
honestly", "genuinely long", "mature surface"); the resting-screen invariant is
repeated four times. (Stage 7 style)

**N8. Document structure.** Additional Resources and Future Improvements are H3
under NFR and sit before the plan; NFR formatting differs from the rest. (Stage 7)

**N9. Non-goal rationale.** A settings key does not force a migration; `settings`
is a KV table already used by `TodayOrder`. Give the real reason. (Stage 7)

**N10. Small wiring.** In-memory test pattern omits `sqfliteFfiInit()` and
`databaseFactoryFfiNoIsolate`; item 5 omits the `speechInput` parameter name;
per-file rationale is claimed but absent; "48dp" should be logical pixels.
(Stage 9)

**N11. EXTRA_MAX_RESULTS 3 with only the top used.** Surface alternatives or
request one. (Stage 8 #11)

**N12. Tie-break duplicates a shipped comparator.** `activity_order.dart:29–34`
already implements `sortOrder` then lowercase name; extract rather than restate.
(Stage 8 #12)

--------------------------------------------------------------------------------

## Traceability Matrix

| Consolidated | Raw sources |
| --- | --- |
| B1 app-pause hand-off | S5 #1, S6 #1, S7 B1, S8 #6, S9 B1 |
| B2 Android plumbing | S7 M1, S8 #8, S9 B2, S6 #9, S5 #16 |
| B3 pending result abandoned | S9 B3, S7 M1, S5 #16, S8 #6 |
| B4 container choice | S8 #1 |
| M1 unverifiable premise/goals | S5 #2, S6 #7, S7 M4, S8 #4/#5, S9 M9/M10 |
| M2 delivery sequencing | S8 #2/#3, S9 M1 |
| M3 matcher contract | S6 #2/#4, S7 M12, S9 M5/M6/M7/M8, S5 #19 |
| M4 matcher realism | S7 M2/M3, S8 #3 |
| M5 lifecycle contradictions | S5 #10, S6 #3, S7 M9, S8 #9, S9 M4/M24 |
| M6 scroll/back/keyboard | S5 #4/#5, S6 #8, S7 M8/M11, S9 M2/M12, S8 #7 |
| M7 excess state | S5 #6/#7/#9, S8 #12, S9 M3/M17 |
| M8 macOS scope | S7 M7, S9 M11, S5 #17 |
| M9 privacy boundary | S5 #3, S7 M6, S8 #10, S9 M13 |
| M10 UI states/archived/a11y | S5 #12/#14, S6 #6/#19, S7 M10/M14/N1/N4, S9 M16/M18 |
| M11 test/verification gaps | S5 #18, S6 #7/#16, S7 M4, S8 #10/#13, S9 M14/M15 |
| M12 risks/design assets | S7 M5/M8, S9 M14/M18 |
| M13 performance bound | S7 (structural) #10, S9 M8/M12 |
| M14 row duplication | S5 #8, S7 N3, S9 M18 |
| N1–N12 | Stage-specific nits as listed |

## Recommended remediation order

1. Decide the container (B4). If the modal picker wins, B1, M6, and M7 partly
   disappear.
2. Decide the platform scope and the voice slice (M2, M8), and record the
   pre-build premise test (M1).
3. Fix the Android seam and pending-result lifecycle (B2, B3).
4. Tighten the matcher contract and remove unreachable tiers (M3, M4, M13).
5. Rewrite the lifecycle rules as one sequence per path (M5).
6. Add risks, assets, and verification detail (M11, M12).
7. Resolve the remaining UI, privacy, and editorial findings.

## What would make this pass

* A filter container that does not require scroll, back, tab, or IME workarounds.
* Typed find shipped and verified before voice.
* A matcher contract with one signature, one metric, one unit, and no dead tiers.
* A lifecycle table covering recognition return, label variants, split, refresh,
  failure, and tab change.
* A privacy statement that says where the utterance goes and that it is never
  logged or persisted.
* A verification plan that compiles Kotlin, seeds its own catalog, and asserts
  the transcript never reaches a Record.
