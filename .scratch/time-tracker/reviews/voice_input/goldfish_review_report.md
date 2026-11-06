# Goldfish Annotated Review Report

**Target:** `docs/designs/voice_assisted_activity_filtering.md` (full file, 1–618)
**Source findings:** `.scratch/time-tracker/reviews/voice_input/consolidated_review_report.md`
**Status:** resolved — 30 proposed fixes applied; 0 open

## Prioritized Findings & AI Suggestions

### B1. App pause clears the filter during the speech hand-off [`egm-design`, `egm-comprehension`, `egm-zoom-out`, `egm-implementation-readiness`] - Severity: High
* **Affected Scope:** State and lifecycle rules, Recognition in progress, CUJ 2
* **Discrepancy Description:** The design closes and clears the filter on app pause in three places, while the speech hand-off requires the field to survive a pause caused by the recognizer activity itself. CUJ 2 is unreachable as written.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** Verified against `dashboard_view.dart:149–158`, which treats any non-resumed state uniformly. The finding is correct and no recorded decision overrides it.
* ***Proposed Edit:***
  * Location: `### State and lifecycle rules`, first bullet.
  * Change: Replace "closed and cleared on … app pause" with: "Closed and cleared on successful label, tab change, back, and `paused`/`hidden` **only when no recognition is pending**. While `listen()` is outstanding, the field, query, and scroll state survive the pause; on resume the transcript is written and the screen returns to the result state. `inactive` (notification shade, dialogs) never closes the filter. If the activity is recreated, the pending call resolves null and the field is unchanged."
  * Location: `### Verification Plan`.
  * Change: Add "paused with a pending fake leaves the field intact; paused with no pending listen clears it; a result after activity recreation leaves the field unchanged."

### B2. Android result plumbing is three incompatible designs and can regress the backup picker [`egm-design`, `egm-implementation-readiness`, `egm-codebase-details`] - Severity: High
* **Affected Scope:** Speech hand-off contract, target files 7 and 8
* **Discrepancy Description:** The plan names an `ActivityResultLauncher`, an `onActivityResult` override, and a request code. The override form risks breaking `BackupDestinationChannel`, which receives results through `ActivityPluginBinding`.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** `BackupDestinationChannel.kt` is the shipped precedent: `FlutterPlugin, ActivityAware` plus `addActivityResultListener`, registered with `flutterEngine.plugins.add(...)`. `MainActivity` currently has no `onActivityResult` override, so adding one is new shared surface with a known regression path.
* ***Proposed Edit:***
  * Location: `### Speech hand-off contract`, mechanism paragraph.
  * Change: Replace "registers an `ActivityResultLauncher` and a method channel" with "is a `FlutterPlugin` that implements `ActivityAware`, owns a pending `MethodChannel.Result`, and receives its result through `ActivityPluginBinding.addActivityResultListener`, following `BackupDestinationChannel`. It is registered with `flutterEngine.plugins.add(...)`; `MainActivity` gains no `onActivityResult` override."
  * Location: target file 8.
  * Change: Delete the request code and `onActivityResult` forwarding. Keep only "register `SpeechRecognitionBridge` beside the existing plugin registrations; release it through `onDetachedFromEngine`."
  * Location: target file 7.
  * Change: Add constructor `SpeechRecognitionBridge(private val activity: Activity)`, a `companion object` with `CHANNEL_NAME = "tempo/speech"` and `REQUEST_RECOGNIZE = 0x5B0`, and main-thread result completion.

### B3. A pending recognition result is abandoned [`egm-implementation-readiness`, `egm-codebase-details`, `egm-zoom-out`] - Severity: High
* **Affected Scope:** Target file 7, pending-listen guard
* **Discrepancy Description:** "Clear pending state on activity destroy" drops the stored `MethodChannel.Result`, so the Dart future never completes and the microphone stays disabled for the session.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** `BackupDestinationChannel.detach()` resolves the in-flight result with `SAF_DETACHED` before clearing. The same rule applies here. A Dart future cannot be cancelled, so a dispose-time callback clear is not implementable.
* ***Proposed Edit:***
  * Location: target file 7.
  * Change: Replace "Clear pending state on activity destroy" with "On detach, destroy, or engine detach, complete the pending result with `error("SPEECH_DETACHED", …)` before clearing it. A second `listen` returns `error("SPEECH_BUSY", …)`. The Dart wrapper maps any `PlatformException` to null."
  * Location: target file 2 and dashboard plan.
  * Change: Add "The Dart side wraps `listen()` in a 60-second timeout and clears the pending guard in `finally`; a late result after dispose is ignored with `if (!mounted) return`."

### B4. The filter is built in the hardest container [`egm-zoom-out`] - Severity: High
**Resolution:** owner chose the modal sheet. Placement, lifecycle, component map,
alternatives, and the implementation plan were rewritten to the sheet; the
`ScrollController`, `PopScope`, tab-index, and saved-offset work was deleted.
* **Affected Scope:** Placement and screen states, lifecycle rules, target files 4 and 5
* **Discrepancy Description:** In-place expansion inside the dashboard's `CustomScrollView` manufactures four problems: scroll restoration, back-press ownership, tab-change clearing, and keyboard occlusion. `history_view.dart:171–240` already implements the same picker as a modal sheet.
* ***AI Suggestion:*** ESCALATE
* ***Justification:*** The structural facts are verified: no `ScrollController`, no `PopScope` in `lib/`, `DashboardView` is an `IndexedStack` child. Which container wins depends on one product requirement the reviewers could not read: whether the suggestion chips must remain visible while the user filters. That requirement was never stated in the brainstorm conversation or the document, and only the owner can settle it.
* ***Proposed Edit:*** No automatic change. Owner chooses:
  * **Inline (current):** add the `ScrollController`, `PopScope`, tab-clearing, and keyboard rules from M6.
  * **Modal sheet:** replace states 2–3 with a sheet opened from the heading, remove scroll restoration, back interception, tab notifier, and keyboard occlusion from the design, and rewrite target files 4–5 accordingly.

### M1. The premise and headline goals are unverifiable [`egm-zoom-out`, `egm-design`, `egm-comprehension`] - Severity: Medium
* **Affected Scope:** The Problem, Goals 1–2, Open Question 1, Verification Plan
* **Discrepancy Description:** Goal 1 uses 40 Activities where a filter is guaranteed to help, while the document says the realistic grid is two to seven rows. Goal 2 depends on a corpus that does not exist and uses undefined terms. The playtest has no seeding mechanism.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** Valid. The design already admits the missing evidence, so adding a decision gate is consistent with its own posture.
* ***Proposed Edit:***
  * Location: new `## Decision Gate` after The Problem.
  * Change: "Proceed only if one holds: the real catalog has 25+ unarchived Activities, or a one-week manual log shows at least one label in three requiring a scroll. Otherwise ship a recent-Activities row instead."
  * Location: Goal 2.
  * Change: Add "Corpus: `test/fixtures/activity_match_corpus.json`, 40 entries, authored from the seeded Activity names, each `{phrase, expectedActivityId, mustNotBeFirst}`; pass = intended Activity in top three for 90%, and zero `mustNotBeFirst` violations."
  * Location: Verification Plan.
  * Change: "Seed 40 Activities with the existing Settings → STT import using `catalogOnly`, not by hand."

### M2. Delivery is one batch, with the unmeasured half first [`egm-zoom-out`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Detailed Implementation Plan
* **Discrepancy Description:** Eleven files land together. The field alone enables keyboard dictation, and fuzzy tiers are speech features sitting in the typed slice.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** Valid. Phasing matches the sibling `decayed_markov_2_activity_suggestions.md` plan and keeps the CI-verifiable half independent of the device-verified half.
* ***Proposed Edit:***
  * Location: new `### Phases` before target files.
  * Change: "Phase 1: matcher exact/prefix/substring, result row, dashboard filter, widget tests. Phase 2: `SpeechInput`, ActivityAware bridge, `<queries>`, return matrix, device pass. Phase 3: token-in-query, edit distance, and `Closest`, only if the corpus requires them. Each phase leaves the app buildable; reverting 2–3 leaves typed filtering intact."

### M3. The matcher contract is underdetermined [`egm-comprehension`, `egm-design`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Matcher contract, target files 1 and 10
* **Discrepancy Description:** API named three ways, metric and counting unit unnamed, `limit` has no default, sort stability claimed without support, `tokenPrefix` unreachable, and archived exclusion untestable.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** All sub-points verified. `List.sort` is not stable; a non-nullable named parameter without a default does not compile; a token prefix is always a substring.
* ***Proposed Edit:***
  * Location: `### Matcher contract`.
  * Change: Replace the API sentence with "`ActivityIndex.fromActivities(List<Activity>)` filters archived Activities internally, precomputes normalized names, and exposes `List<ActivityMatch> search(String query, {int limit = 20})`. `ActivityMatch` carries `activity` and `stage` only."
  * Change: Add "Distance is Damerau-Levenshtein over runes, with unit insert/delete/substitute/transpose and early exit. The threshold comes from the name's rune length; skip when `|len(query) − len(name)| > threshold`."
  * Change: Delete the `tokenPrefix` tier and its enum value.
  * Change: Replace "stable sort" with "sort by tier, then `sortOrder`, then normalized name, then id; never rely on `List.sort` stability."
  * Location: target file 10.
  * Change: Replace "archived exclusion" with "the index filters archived items from a full catalog".

### M4. The matcher misses normal spoken phrases and can return confident wrong results [`egm-design`, `egm-zoom-out`] - Severity: Medium
* **Affected Scope:** Matcher tiers, Goal 2, Goal 6
* **Discrepancy Description:** Fillers ("um, cleaning the kitchen") match nothing because all tiers anchor to the whole name. Reverse prefix promotes "workout was hard" to Work and "homework" to Home as strong matches.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** Valid. Fillers are normal recognition output, and the reverse-prefix tier contradicts Goals 2 and 6.
* ***Proposed Edit:***
  * Location: `### Matcher contract`, tier list.
  * Change: Add tier "name token in query — any whitespace token of the name appears as a token in the query", ranked below substring. Remove "the query starts with the name" from the prefix tier.
  * Change: Add "No reverse-prefix tier. `clean` finds `Cleaning` because the name starts with the query."
  * Change: Add "Fuzzy tiers appear only under `Closest`; no fuzzy result may be the first row when no exact, prefix, substring, or token-in-query match exists."

### M5. Lifecycle rules contradict each other and omit two label paths [`egm-design`, `egm-style`, `egm-comprehension`] - Severity: Medium
* **Affected Scope:** State and lifecycle rules
* **Discrepancy Description:** "Closed and cleared on label" conflicts with "a label keeps the query". `Split`, `Same as last`, external deep-link labels, and the failed-label path are not covered.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid; the current text contains both rules.
* ***Proposed Edit:***
  * Location: `### State and lifecycle rules`, replace the two conflicting bullets with a table: "Result-row tap → close → clear → label → reload. Failed label → close → clear → error bar. Pull-to-refresh → keep query → rebuild index → recompute. `Split` → close → clear → reload; the Lap reopens. `Same as last` or external deep link → close → clear. Tab change / back / pause → close and clear (pause exception per B1)."

### M6. Scroll, back, and keyboard mechanics have no implementation [`egm-design`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Goal 5, target file 4
* **Discrepancy Description:** No `ScrollController`; back has no `PopScope`; the field retains focus across recognition so the IME returns and covers the result list.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid for the inline container. If B4 selects the modal sheet, the scroll and back items are deleted instead; the keyboard item still applies inside the sheet.
* ***Proposed Edit:***
  * Location: target file 4.
  * Change: Add "`ScrollController _gridScroll`, attached to the `CustomScrollView`; capture `offset` before opening; after closing, restore in a post-frame callback with `jumpTo(min(saved, maxScrollExtent))`; dispose it."
  * Change: Add "`PopScope(canPop: false, onPopInvokedWithResult:)`: first back dismisses the IME if visible, second closes the filter."
  * Change: Add "Call `FocusScope.of(context).unfocus()` before launching recognition and after writing the transcript; never request focus on return."
  * Location: target file 11.
  * Change: Add "assert `tester.testTextInput.isVisible == false` after the fake transcript."

### M7. Excess state: tab notifier, `ActivityIndex`, duplicated query, controller not extracted [`egm-design`, `egm-structural`] - Severity: Medium
* **Affected Scope:** Target files 4 and 5, matcher contract
* **Discrepancy Description:** `TempoApp` already rebuilds on tab change; a notifier adds work with no benefit and omits listeners and disposal. `ActivityIndex` is a premature cache with two invalidation keys. Query text is stored twice.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid. A plain `final int tabIndex` plus `didUpdateWidget` is simpler and matches the existing rebuild flow. The pure-function precedent is `suggestion_engine.dart`.
* ***Proposed Edit:***
  * Location: target file 5.
  * Change: Replace the notifier with "add `final int tabIndex` to `TempoApp` and `DashboardView`; the dashboard closes the filter in `didUpdateWidget` when the value leaves Today. No new notifier or disposal."
  * Location: matcher contract.
  * Change: "Delete `ActivityIndex`; use a pure `rankActivities(List<Activity>, String query, {int limit})` called from the query-change handler. Do not call it from the ticker."
  * Location: target file 4.
  * Change: "The `TextEditingController` is the single source of truth for the query. Extract `ActivityFilterController` (plain Dart) holding open flag, availability, pending guard, and matches, so it is unit-testable."

### M8. The filter silently ships to macOS, and CUJ 1 is false there [`egm-design`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Overview, Non-Goals, CUJ 1, target files 4 and 6
* **Discrepancy Description:** `DashboardView` is shared, and only `SpeechInput` is nulled. The typed filter appears on the Mac, where labeling queues an intent rather than writing a Record.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Verified. Non-Goals says macOS is untouched, so Android-only is the consistent choice for v1.
* ***Proposed Edit:***
  * Location: target file 4.
  * Change: Add `bool showActivityFilter = false`; render the magnifier and filter only when true.
  * Location: target file 6.
  * Change: "Pass `showActivityFilter: true` from the Android composition; the `_startReplica` construction omits it. Declare the nullable `SpeechInput?` local before the platform block so the single Android `runApp` can pass both."
  * Location: CUJ 1.
  * Change: Add "Phone only. On macOS the magnifier is absent in v1."

### M9. Privacy NFR omits the audio trust boundary and transcript logging [`egm-design`, `egm-zoom-out`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Non-Functional Requirements, target file 7
* **Discrepancy Description:** The recognizer app may be a network service, so the utterance leaves Tempo. The NFR never says so, never makes the Play data-safety check a release gate, and never forbids transcript logging.
* ***AI Suggestion:*** PROPOSE FIX
* ***Justification:*** Valid. `MainActivity` already logs user-derived values, so the logging gap is plausible.
* ***Proposed Edit:***
  * Location: Non-Functional Requirements → Security and privacy.
  * Change: Add "The utterance leaves Tempo: the recognizer activity owns the microphone and may process audio off-device under its own policy. Tempo stores no audio and receives only text. The Play data-safety declaration is a release gate. Copy must never describe recognition as on-device. The typed path is the private path."
  * Location: target file 7.
  * Change: Add "Never log the transcript, the query, or `EXTRA_RESULTS`; log only the method name and an error code."

### M10. Filter states are under-specified and the archived path is a dead end [`egm-design`, `egm-comprehension`, `egm-structural`] - Severity: Medium
* **Affected Scope:** Four states, Accessibility, target files 3 and 4
* **Discrepancy Description:** Clear means both empty and close; any single character replaces the grid; no row cap; context line duplicates the subtitle; magnifier and row lack contracts; archived names dead-end; accessibility labels describe states that never render.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid and mostly mechanical.
* ***Proposed Edit:**
  * Location: Four states.
  * Change: "A trailing × clears the query and stays open in state 2; back closes. Filtering starts at one character; fuzzy tiers at three. Results cap at 20 with a `showing N of M` line."
  * Location: Placement.
  * Change: "While the filter is open, replace the heading subtitle `Tap to log …` with `Label HH:MM → now · <elapsed>`, using `UiHelpers.formatDurationHuman`; restore it on close."
  * Location: Empty state.
  * Change: Add a text action `Manage Activities` opening `ActivityManagerView`, so an archived name is not a dead end.
  * Location: Accessibility.
  * Change: "Drop the `Listening` and `Voice unavailable` labels. The mic is either rendered enabled or absent. Add a `Filter Activities` field hint, move focus into the result list when it appears, return focus to the magnifier on close, and throttle the live-region count."
  * Location: target file 4.
  * Change: Magnifier: trailing `IconButton`, 48×48 logical pixels, key `activity-filter-button`, semantics `Filter Activities`. Target file 3: duration via `UiHelpers.formatDurationHuman`, `0m` for zero, long-press opens the manager.

### M11. Test and verification plan cannot prove the claims [`egm-*`] - Severity: Medium
* **Affected Scope:** Verification Plan, target file 11
* **Discrepancy Description:** Kotlin is not compiled, the channel wrapper is untested, pause/back/tab harnesses are unspecified, transcript non-persistence is unasserted, and the playtest has no seed, viewport, or disabling method.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid; each item is a missing executable step.
* ***Proposed Edit:***
  * Location: Verification Plan.
  * Change: Add `cd android && ./gradlew :app:compileDebugKotlin`; replace the manifest command with `cd android && flutter build apk --debug` then inspect `build/app/outputs/flutter-apk/app-debug.apk` with `aapt dump permissions`; state the expected absence of `RECORD_AUDIO`.
  * Change: Add a mocked-channel test for `MethodChannelSpeechInput` using `setMockMethodCallHandler`, covering success, cancellation, `PlatformException`, and `MissingPluginException`.
  * Change: Add "pause via `tester.binding.handleAppLifecycleStateChanged`; back via `handlePopRoute`; seed the playtest with the STT `catalogOnly` import; record the device and viewport; disable the recognizer through Android Settings → Apps → Default apps."

### M12. Missing Risks section, and design assets are not updated [`egm-design`, `egm-structural`] - Severity: Medium
* **Affected Scope:** Non-Functional Requirements, Files not changed
* **Discrepancy Description:** No `## Risks & Mitigations` table, though both sibling specs carry one. Heading chrome changes the committed dashboard screenshot, and `DESIGN.md` still describes the old screen.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid and consistent with repo convention.
* ***Proposed Edit:***
  * Location: new `## Risks & Mitigations` before Alternatives.
  * Change: Add a table with rows: audio egress, process death during recognition, stale catalog, false positives, keyboard occlusion, corpus never authored, macOS surface. Columns: risk, trigger, mitigation, residual risk.
  * Location: Files not changed.
  * Change: Add `screenshots/color_blocks_dashboard.png`, `screenshots/color_blocks_dashboard_undo.png`, and `DESIGN.md`, with the re-capture command `TEMPO_SCREENSHOT=1 flutter test test/ui/color_blocks_dashboard_screenshot_test.dart --update-goldens`.

### M13. Performance bound and input clip are missing [`egm-structural`, `egm-implementation-readiness`] - Severity: Medium
* **Affected Scope:** Matcher contract, Non-Functional Requirements
* **Discrepancy Description:** The contract accepts arbitrarily long input and the test feeds 10k characters, while edit distance is quadratic per candidate on the UI thread.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid. Totality and unbounded work were conflated.
* ***Proposed Edit:***
  * Location: Matcher contract.
  * Change: "Clip the normalized query to 64 runes. Skip the distance tier when the query is clipped or when `|len(query) − len(name)| > threshold`. Cost is bounded by (64 × name length × candidate count)."

### M14. Result rows duplicate two existing rows without saying so [`egm-design`, `egm-structural`] - Severity: Medium
* **Affected Scope:** Target file 3
* **Discrepancy Description:** `history_view.dart` `_pickActivity` and `quick_popover_view.dart` `_buildActivityRow` are already swatch/name/tap rows. The new row's reason is file size, not reuse, and it names no `DESIGN.md` tokens.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid. The row genuinely needs a total and a category line, so a fourth variant is defensible, but the reason must be stated and the visual contract fixed.
* ***Proposed Edit:***
  * Location: target file 3.
  * Change: "Align with `_buildActivityRow`'s swatch and name treatment; add the total and optional category line as documented extensions. Use `TempoRadii.row` and `TempoRadii.swatch`; add a row variant to `DESIGN.md`."

### N1. Contract and API drift [`egm-*`] - Severity: Low
* **Affected Scope:** Matcher contract, component map
* **Discrepancy Description:** Tie-break key appears in one section only; "scoring uses integers" describes ordering; the diagram routes through `RecordCommands.label`; the state list omits the query; the request code has no value; the recognizer action is written two ways.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Cheap, and resolves ambiguity in the same pass as M3/M7.
* ***Proposed Edit:*** Align all three descriptions with the M3 signature; route the diagram through `_labelActivity`; add the query to the state list; define `REQUEST_RECOGNIZE = 0x5B0`; note that `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` and `android.speech.action.RECOGNIZE_SPEECH` are the same string.

### N2. Normalization details [`egm-comprehension`] - Severity: Low
* **Affected Scope:** Matcher contract
* **Discrepancy Description:** "Strip boundary punctuation" has no character set; whether it applies per token is unstated; "one edit at 4–7" has an ambiguous antecedent.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Cheap and testable.
* ***Proposed Edit:*** "Strip Unicode punctuation (`\p{P}`) at the start and end of the whole string before whitespace collapse; do not strip per token. Thresholds apply to the normalized name's rune length."

### N3. Accessibility details [`egm-design`] - Severity: Low
* **Affected Scope:** Accessibility
* **Discrepancy Description:** Unreachable labels; no field hint; focus transfer undefined; live region unthrottled.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Covered by M10; no separate change needed.
* ***Proposed Edit:*** Fold into M10.

### N4. Availability handling [`egm-design`, `egm-structural`] - Severity: Low
* **Affected Scope:** Speech contract, target files 2 and 4
* **Discrepancy Description:** Session cache hides the mic after one transient error; async resolution causes pop-in; three layers are named as cache owner.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid; one owner is cheaper to reason about.
* ***Proposed Edit:*** "`MethodChannelSpeechInput` owns a private `bool?` availability cache, re-resolved on each filter open. The dashboard renders no mic until the first resolution; a resolution after dispose is ignored."

### N5. Context line duplication [`egm-comprehension`, `egm-implementation-readiness`] - Severity: Low
* **Affected Scope:** Four states
* **Discrepancy Description:** The new context line duplicates the existing heading subtitle, and "reusing the existing lap label" names a widget that does not exist.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Valid; M10 already specifies the replacement.
* ***Proposed Edit:*** Fold into M10: replace the subtitle rather than add a third line.

### N6. Vocabulary and first-use definitions [`egm-comprehension`, `egm-design`] - Severity: Low
* **Affected Scope:** Overview, Empty state
* **Discrepancy Description:** "No active Activity matches" uses a non-domain word; "Lap" and "Record" are unglossed; "every Activity" ignores archived exclusion.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Cheap clarity.
* ***Proposed Edit:*** "At first use: 'the always-running open Lap, which a label closes into a Record'. Empty state: 'No unarchived Activity matches'. Overview: 'every unarchived Activity'."

### N7. Editorial fluff and unmeasured claims [`egm-style`] - Severity: Low
* **Affected Scope:** The Problem, Placement, NFR, Alternatives
* **Discrepancy Description:** "rare action", "seeded catalog" for two sizes, "microseconds", "weakest part of the case", metaphors and intensifiers, repeated invariants.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Low risk, improves signal.
* ***Proposed Edit:*** "Replace 'rare action' with 'an action that may be infrequent'; distinguish 'shipped seed catalog (five)' from 'playtest catalog (forty)'; replace 'microseconds' with the M13 cost model; delete 'This is the weakest part of the case, and the design should say so'; replace 'load-bearing' with 'carries the feature'; delete 'zero risk' and 'genuinely'."

### N8. Document structure [`egm-structural`] - Severity: Low
* **Affected Scope:** Non-Functional Requirements, Additional Resources, Future Improvements
* **Discrepancy Description:** Two document-level sections are H3 under NFR and sit before the implementation plan; NFR formatting differs from the rest.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Mechanical.
* ***Proposed Edit:*** "Promote Additional Resources and Future Improvements to H2 and move them after the implementation plan. Convert NFR bold lead-ins to H3 subsections."

### N9. Non-goal rationale [`egm-structural`] - Severity: Low
* **Affected Scope:** Non-Goals
* **Discrepancy Description:** "A settings key would force a schema migration" is false; `settings` is a KV table already used by `TodayOrder`.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Verified in `tempo_database.dart:531–548`.
* ***Proposed Edit:*** "Replace the reason with: transient UI state should not survive a restart, and a stored query is a privacy and staleness liability."

### N10. Small wiring details [`egm-implementation-readiness`] - Severity: Low
* **Affected Scope:** Target files 2, 5, 11
* **Discrepancy Description:** In-memory test pattern omits `sqfliteFfiInit()`; item 5 omits `speechInput`; per-file rationale absent; "48dp" instead of logical pixels.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Mechanical.
* ***Proposed Edit:*** "Add the FFI setup to target file 11; name the parameter `speechInput`; add one `Rationale:` line per file; use logical pixels."

### N11. `EXTRA_MAX_RESULTS` 3 with one consumer [`egm-zoom-out`] - Severity: Low
* **Affected Scope:** Speech contract
* **Discrepancy Description:** Three results are requested but only the first is used.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Remove unused generality.
* ***Proposed Edit:*** "Request one result; add a `Did you mean` row only if the corpus shows alternatives matter."

### N12. Tie-break duplicates a shipped comparator [`egm-zoom-out`] - Severity: Low
* **Affected Scope:** Matcher contract
* **Discrepancy Description:** `activity_order.dart:29–34` already implements `sortOrder` then lowercase name.
* ***AI Suggestion:*** PROPOSE FIX
* **Justification:** Two definitions will drift.
* ***Proposed Edit:*** "Extract the existing comparator into a shared helper and reuse it, appending id as the final tie-break."
