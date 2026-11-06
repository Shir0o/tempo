# Voice-Assisted Activity Filtering (Android)

* **Author:** twang
* **Status:** Draft
* **Date:** 2026-11-05

--------------------------------------------------------------------------------

## Overview

Tempo labels the open Lap after the fact. On the Android Today screen the user
picks from up to four contextually ranked suggestion chips and then from a
three-column grid of every Activity. There is no search on that screen.

This design adds a text filter to the Today screen and an in-app microphone
button that launches the phone's speech-recognition activity. The user says
"cleaning", the transcript lands in the filter, the matching Activity appears at
the top of a short result list, and the user presses it to label the Lap. The
microphone is a platform hand-off, not an audio pipeline: `RECORD_AUDIO` is not
declared, the recognizer app records the audio, and Tempo receives only text.

The filter is the load-bearing part. It gives a direct path to any Activity in a
long catalog, works without a microphone or permission, and carries the matching
logic that a future History or macOS surface can reuse. The microphone is a
convenience on top of it.

## The Problem

Tempo's capture surfaces are optimized for the common case: label the Lap with
one of the Activities you used recently. The Today screen shows up to four
suggestion chips, then the full catalog as a three-column grid grouped by
category. When the target Activity is neither a chip nor on the first visible
grid rows, the user scrolls and scans. That cost grows with the catalog.

The product promises labeling in under a second. A scroll does not break that
promise for a visible block, but it does for an Activity the user cannot see.
There is no way to jump directly to a named Activity, and no way to speak one.

This is the weakest part of the case, and the design should say so: no
instrumentation in the repo shows how often a label requires a scroll. The
seeded catalog is small. The screen may work well enough for most users, and
better ranking or a recent-Activities row may remove the need for a filter
entirely. The filter is justified only if the catalog is genuinely long enough
that scanning fails, which the Goals below make testable.

The speech path introduces its own constraint. Android has no public API that
lets an app press the keyboard's own microphone. Calling `SpeechRecognizer`
directly would require `RECORD_AUDIO`, a runtime permission, a permanent store
listing entry, and an API 31 floor for on-device recognition against a `minSdk`
of 24. Launching `ACTION_RECOGNIZE_SPEECH` avoids all of that: the recognizer
app records, Tempo receives the transcript, and the OS owns the listening
screen. The cost is that the listening UI is not Tempo's, the transcript arrives
only as a final result, and the target activity must be resolvable on Android
11 and later.

## Goals

1. **Reach any Activity without scanning.** With a catalog of 40 Activities, a
   user can find and label any named Activity from the Today screen without
   scrolling the block grid. Verified by manual playtest with a seeded
   40-Activity catalog.
2. **Rank the right Activity first.** For a checked-in corpus of real spoken
   phrases and Activity names, the intended Activity appears in the top three
   results for at least 90% of entries, and the matcher never returns a
   confident wrong first result when no plausible match exists.
3. **Speak a name and press it.** Tapping the microphone button opens the
   system recognition activity; the top transcript fills the filter; the
   matching Activity is visible; one press labels the Lap. No microphone
   permission is requested by Tempo at any point.
4. **Never commit without a press.** No transcript, keystroke, or exact match
   labels a Lap or creates an Activity on its own.
5. **Leave the resting screen unchanged.** With an empty query, the Today screen
   renders the same chips, grid, order, geometry, and tap targets as today, and
   the previous scroll offset is restored after the filter closes.
6. **Degrade honestly.** A miss shows the query and a clear action, never a
   best-effort row presented as a match. A microphone button appears only when a
   recognizer activity resolves; otherwise the typed field remains fully usable.

## Non-Goals

* Declaring `RECORD_AUDIO`, using `SpeechRecognizer`, shipping a speech plugin,
  or recording audio inside Tempo.
* Interim-transcript ranking, auto-labeling, auto-creating Activities, or
  create-on-Enter.
* Searching categories, tags, Record comments, or historical Records.
* An English-only or model-based semantic matcher. Matching is deterministic and
  local; "cleaning" does not find "Housework".
* New telemetry, counters, or any upload. Success is verified by tests and a
  manual playtest, not analytics.
* Changes to the watch, the macOS popover, the History edit sheet, the CSV
  export, the MCP server, the sync model, or the database schema.
* Persisting a filter query or adding a settings key. Any new key would force a
  schema migration for transient UI state.

## Critical User Journeys (CUJs)

### CUJ 1: Label an off-screen Activity by typing

* **Given** the Today screen shows an open Lap and a catalog of 40 Activities,
  and the target Activity is not among the four suggestion chips.
* **When** the user opens the filter, types three or more characters of the
  Activity name, and presses the matching row.
* **Then** exactly one Record is created for the open Lap, the filter closes, the
  chips and grid return at the previous scroll offset, and the undo bar reads
  "Logged <Activity> <start>–<end>".

### CUJ 2: Label by voice

* **Given** the filter is open and a recognizer activity resolves on the device.
* **When** the user taps the microphone button, says an Activity name in the
  system recognition screen, and returns to Tempo.
* **Then** the final transcript fills the filter, the matching Activity appears
  in the top three rows, no Lap is labeled yet, and one press labels it. No
  microphone permission prompt from Tempo appears at any point.

### CUJ 3: A miss does not become a wrong Record

* **Given** the user says or types a phrase that does not plausibly match any
  active Activity.
* **When** the result list renders.
* **Then** the list shows "No active Activity matches '<query>'" with a Clear
  action, no row is preselected, and nothing is labeled until the user presses a
  real Activity.

## Technical Plan

### Placement and screen states

The filter is not permanent. It opens from a magnifier button on the "What was
it?" heading and collapses back into it. This keeps the resting screen
unchanged and avoids paying roughly 64dp of chrome on every visit for a rare
action.

Four states, with no others:

1. **Closed (default).** Chips and grid exactly as today.
2. **Open, empty query.** The heading row expands into a focused text field with
   a microphone button. Chips and grid remain visible beneath it. A compact
   context line reads "Label 10:06 → now · 25m" so the interval being closed is
   never hidden by the keyboard.
3. **Open, non-empty query.** The suggestion chips and the grid are replaced by
   a full-width result list. The context line and the field stay visible above
   it. This avoids showing the same Activity simultaneously as chip, block, and
   result with three different ranks.
4. **Recognition in progress.** The OS speech activity covers Tempo. On return,
   the transcript is written into the field and the screen is state 3. There is
   no in-app listening UI and no interim ranking.

Closing the filter (clear, back, successful label, tab change, app pause)
restores the exact chips, grid, and scroll offset from before it opened.

### Component map

```text
Activity catalog (unarchived, grid order)
        │
        ├── normalized once per catalogRevision ──┐
        │                                         │
   query text (typed or transcript) ─────────────►│
                                                  ▼
                                  activity_matcher.rankActivities()
                                                  │
                                    List<ActivityMatch>
                                                  │
                                                  ▼
                            full-width result rows in DashboardView
                                                  │
                                              press row
                                                  │
                                                  ▼
                                    RecordCommands.label(activityId)
                                                  │
                                                  ▼
                              _loadData() → filter closes → grid returns
```

Components:

* **Matcher** (`lib/core/state/activity_matcher.dart`, new): pure functions,
  no Flutter imports, no database, no clock, no locale. Owns normalization,
  tier scoring, and the total order.
* **Speech hand-off** (`lib/speech/speech_input.dart`, new): an abstract
  `SpeechInput` with `Future<bool> isAvailable()` and
  `Future<String?> listen()`, plus a `MethodChannel` implementation. Android
  implements it; macOS and tests receive null.
* **Result row** (`lib/ui/activity_result_row.dart`, new): a full-width row with
  colour swatch, Activity name, total today, and optional category label. Kept
  out of the dashboard file because the dashboard is already large.
* **Dashboard** (`lib/ui/dashboard_view.dart`, modify): owns filter state,
  renders the four states, and calls the matcher and `RecordCommands`.
* **Injection** (`lib/main.dart`, `lib/ui/tempo_app.dart`, modify): pass the
  optional `SpeechInput` down to the dashboard. No `Platform.isAndroid` check
  inside the shared widget, because the dashboard also runs on macOS and in
  host-side widget tests.

### Matcher contract

Input: the unarchived Activity list in grid order, a query string, and an
optional limit. Output: an ordered list of matches carrying the Activity, a
stage, and a tie-break key.

Normalization: trim, lowercase, collapse internal whitespace, and strip
punctuation at the boundaries. No accent folding in v1 — Dart has no Unicode
normalization, the edit-distance tier absorbs a single accent difference, and a
hand-maintained fold table is long-term maintenance for a small gain. No
locale-aware comparison anywhere.

Tiers, in descending priority:

1. **Exact** — normalized names are equal.
2. **Prefix** — the name starts with the query, or the query starts with the
   name (so "clean" and "cleaning" find each other).
3. **Substring** — the query appears anywhere in the name.
4. **Token prefix** — any whitespace-separated token starts with the query.
5. **Edit distance** — only for queries of 3+ characters and names of 4+
   characters. One edit for names of 4–7 characters, two for 8+. This tier is
   labelled "Closest" in the result list.

Within a tier, order by existing grid order (`sortOrder`, then normalized name,
then Activity id). Scoring uses integers and a stable sort so the same inputs
always produce the same order, including when two Activities share a name.

The matcher must be total: any input string, including emoji, combining marks,
lone surrogates, and very long input, returns a list and never throws. Fuzzy
results are never presented as exact; the UI separates them under the "Closest"
heading.

Archived Activities are excluded from candidates. The empty state says "No
active Activity matches '<query>'" rather than "No match", so a user searching
for an archived Activity is told the truth without adding an archived row and a
second navigation path in v1.

### Speech hand-off contract

`SpeechInput.isAvailable()` asks the Android side whether
`android.speech.action.RECOGNIZE_SPEECH` resolves to an activity. The answer is
cached for the app session and checked when the filter opens. When it is false,
the microphone button is not rendered; the typed field is unaffected. This
avoids a button that exists only to fail.

`SpeechInput.listen()` starts the recognizer activity with:

* `EXTRA_LANGUAGE_MODEL` free-form,
* `EXTRA_LANGUAGE` set to the device locale language tag,
* `EXTRA_MAX_RESULTS` 3,
* no `EXTRA_PARTIAL_RESULTS`, because the caller receives only the final result.

The Kotlin side registers an `ActivityResultLauncher` and a method channel.
Tempo does not request `RECORD_AUDIO`; the recognizer activity owns the
microphone. A cancelled or failed recognition resolves the call with null and
leaves the field as it was. The top returned alternative is written into the
field as plain text. The app does not request focus or reopen the keyboard after
the hand-off.

Only one recognition may be in flight. The dashboard disables the microphone
button while a call is pending and clears its pending callback on dispose.

### State and lifecycle rules

* `TextEditingController`, `FocusNode`, query string, open flag, saved scroll
  offset, and cached matches live in `_DashboardViewState` and are disposed
  with the existing `dispose()`.
* Matches are recomputed only when the query changes or `catalogRevision`
  changes. The one-second live ticker continues to update the Lap display but
  does not re-run the matcher.
* The filter is not persisted. It is closed and cleared on successful label,
  tab change, app pause, and the first back press.
* A reload from pull-to-refresh or a label keeps the query if the filter was
  open, but recomputes matches against the refreshed catalog. The filter closes
  on the label path because the label is the end of that interaction.
* The `IndexedStack` in `lib/ui/tempo_app.dart` keeps the dashboard alive across
  tabs, so clearing on tab change is explicit, not implied by rebuild.

### Accessibility

* The field has a minimum height of 56dp and grows with text scale; no fixed
  height that clips.
* The microphone button has a 48×48dp target and a Semantics label that changes
  between "Start voice input", "Listening", and "Voice input unavailable".
* The result region is a live region announcing the count ("3 activities
  match") when it changes, so a screen-reader user learns that filtering
  happened.
* The typed path is complete and primary. The microphone is additive, never the
  only way to reach a result.

### Constraints this plan holds

* **Privacy:** no microphone permission, no audio in Tempo, no network call from
  Tempo, no transcript persisted or exported.
* **Correctness:** a press is the only commit; the matcher cannot write.
* **Performance:** matching a few dozen names is microseconds; normalization is
  computed once per catalog revision, not per frame.
* **Rollback:** the feature adds no schema, no settings key, no sync payload,
  and no export field. Removing the UI restores the old screen exactly.

## Alternatives Considered

### Alternative A: Do nothing and measure first

* **Pros**: Zero code, zero risk, and it tests the premise honestly. The seeded
  catalog is five Activities, and the existing grid is two to seven rows at
  realistic sizes.
* **Cons**: Does not answer the request, and the product has no analytics to
  measure scroll frequency with. Any "measurement" would be a manual playtest
  with a synthetic catalog.
* **Reason for Rejection**: Rejected as the deliverable, but retained inside the
  plan: Goal 1 is a manual playtest with 40 Activities, so the assumption is
  tested before the feature is called successful.

### Alternative B: Better ranking instead of a new surface

* **Pros**: A "Recent today" row of 8–10 one-tap chips, or surfacing pinning on
  the dashboard, solves "not in the top four" with no field, no keyboard, and no
  platform hand-off. It stays inside the one-tap capture promise.
* **Cons**: It only covers Activities used recently or pinned. An Activity used
  rarely but known by name still requires scanning.
* **Reason for Rejection**: Cheaper, but it does not provide a direct path to a
  named Activity in a long catalog. It should still be considered as a
  complementary change if the filter proves too heavy in review.

### Alternative C: In-app `SpeechRecognizer` with `RECORD_AUDIO`

* **Pros**: Recognition stays inside Tempo: inline field, no OS screen, no
  hand-off, and a transcript can stream as the user speaks.
* **Cons**: Tempo declares a permanent microphone permission shown to every Play
  user, adds a runtime permission state machine, updates the data-safety form,
  and needs an API 31 floor for on-device recognition against `minSdk` 24.
  Without that floor, audio may leave the device to a network recognizer.
* **Reason for Rejection**: The permission and store-listing cost is permanent;
  the saved tap is not. The platform activity achieves the same user outcome
  without Tempo owning audio.

### Alternative D: Keyboard dictation only, no in-app button

* **Pros**: Zero permissions, zero manifest changes, zero platform channel. Any
  focused text field already exposes the keyboard's voice key.
* **Cons**: Android has no public API to trigger the keyboard's microphone from
  the app, so there is no in-app button. The user must find the keyboard's mic
  key, which is a different affordance on every keyboard.
* **Reason for Rejection**: It satisfies voice input but not the requested
  interaction. It remains the fallback if the recognizer-activity hand-off fails
  review.

### Alternative E: Android App Shortcuts or the existing broadcast and deep link

* **Pros**: `app.tempo.action.START_TIMER` with an `activity` extra and
  `tempo://start?activity=` already label the open Lap from Tasker, NFC, or an
  Assistant routine. Zero new code, and the three-second undo is the guard.
* **Cons**: It labels directly instead of showing a list to press, so it does not
  match the requested "speak it, then press it" interaction, and it requires the
  user to configure an external automation.
* **Reason for Rejection**: A useful existing path to document, but not the
  in-app experience this design covers.

### Alternative F: Share the matcher with macOS in the same change

* **Pros**: One ranking implementation instead of two, and the desktop's search
  becomes more capable.
* **Cons**: The macOS popover filters only pinned Activities and its Enter key
  creates an Activity. Reusing the matcher means widening that filter and
  changing a mature surface's behavior, with its own tests and re-baselined
  screenshots.
* **Reason for Rejection**: Speculative reuse with one caller. Extract on the
  second real caller, and keep create-on-Enter out of the phone.

### Alternative G: Semantic matching, aliases, or an on-device model

* **Pros**: "cleaning" would find "Housework" or "Chores", which deterministic
  matching cannot do.
* **Cons**: Requires an alias list the user maintains or a model to ship,
  quantize, version, and test. It adds latency, package size, and a new failure
  mode where a plausible but wrong Activity ranks first.
* **Reason for Rejection**: Out of proportion to the problem, and it weakens the
  "a miss looks like a miss" property that protects the record.

### Alternative H: Put search in the History edit sheet first

* **Pros**: The edit sheet renders every Activity as a wrapped chip with no
  filter, so it has the genuinely long list and no alternative path.
* **Cons**: It does not help labeling the open Lap, which is the requested
  interaction and the more frequent one.
* **Reason for Rejection**: The matcher is built as a pure function so the
  History picker can adopt it in a later change without redesign.

## Detailed Implementation Plan

No production code is written in this step. The plan names every file, what
changes, and why. `pubspec.yaml` is unchanged: no new dependency, no speech
plugin, no model.

### Target Files to Create/Modify

#### 1. `lib/core/state/activity_matcher.dart` (Create)

* **Type / Scope**: Pure Dart matching module. No Flutter imports, no database,
  no clock, no locale.
* **Proposed Changes**: Define `ActivityMatchStage` as an ordered enum (exact,
  prefix, substring, tokenPrefix, editDistance) and `ActivityMatch` carrying the
  Activity and its stage. Provide an immutable `ActivityIndex` built once from
  the unarchived Activity list, which precomputes normalized names, and a
  `search(String query, {int limit})` method returning ranked matches.
  Normalization: trim, lowercase, collapse whitespace, strip boundary
  punctuation. Tier thresholds: prefix in either direction; token prefix on
  whitespace tokens; edit distance only for queries of 3+ characters and names
  of 4+ characters, with one edit at 4–7 characters and two at 8+. Order within
  a tier by `sortOrder`, then normalized name, then id. Return an empty list for
  an empty query. The function is total: arbitrary Unicode, emoji, combining
  marks, and very long strings return a list and never throw.

#### 2. `lib/speech/speech_input.dart` (Create)

* **Type / Scope**: Platform-agnostic abstraction plus the Android
  implementation.
* **Proposed Changes**: Define `abstract class SpeechInput` with
  `Future<bool> isAvailable()` and `Future<String?> listen()`. Add
  `MethodChannelSpeechInput` over a `tempo/speech` channel with `isAvailable`
  and `listen` methods. Catch `MissingPluginException` and `PlatformException`,
  returning false and null respectively. No permission calls, no audio API, no
  state beyond the channel.

#### 3. `lib/ui/activity_result_row.dart` (Create)

* **Type / Scope**: Stateless Flutter widget.
* **Proposed Changes**: A full-width row taking an Activity, today's duration,
  an optional category name, a flag for the "Closest" section, and an `onTap`.
  Renders a colour swatch, name, trailing tabular duration, and a small
  uppercase category line when present. Minimum height 48dp, semantics label
  includes activity name, duration, and "Tap to label untracked time". Key
  format `activity-result-<id>` so tests can target it.

#### 4. `lib/ui/dashboard_view.dart` (Modify)

* **Type / Scope**: The Today screen state and layout.
* **Proposed Changes**: Add an optional `SpeechInput? speechInput` constructor
  parameter and a `ValueListenable<int>? tabIndex` parameter. Add filter state
  to `_DashboardViewState`: controller, focus node, open flag, saved scroll
  offset, `ActivityIndex`, current matches, cached speech availability, and a
  pending-listen guard. Add a magnifier button to the "What was it?" heading
  that opens the field and focuses it. Render the four defined states:
  closed; open with empty query (field, mic, context line, chips, grid); open
  with non-empty query (field, context line, result rows replacing chips and
  grid); recognition in progress (OS screen, no in-app change). Add a compact
  context line reusing the existing lap label and elapsed time. Close and clear
  the filter on back, clear, successful label, tab change, and app pause,
  restoring the saved scroll offset. Rebuild `ActivityIndex` whenever
  `_activities` is replaced, and recompute matches only when the query changes.
  Do not re-run the matcher from the one-second ticker. Dispose the controller
  and focus node in the existing `dispose()`. On a result tap, close the filter
  before delegating to the existing `_labelActivity`, so the undo bar is not
  competing with the keyboard. Do not change `_labelActivity`'s write path.

#### 5. `lib/ui/tempo_app.dart` (Modify)

* **Type / Scope**: App shell and dependency injection.
* **Proposed Changes**: Accept an optional `SpeechInput?` and pass it to
  `DashboardView`. Replace the plain `_currentTabIndex` integer with a
  `ValueNotifier<int>` (still driving the existing `IndexedStack` and
  `NavigationBar`) and pass it to the dashboard so the filter can close when the
  user leaves Today. No other screen changes.

#### 6. `lib/main.dart` (Modify)

* **Type / Scope**: Platform composition root.
* **Proposed Changes**: Construct `MethodChannelSpeechInput()` only in the
  Android branch and pass it into `TempoApp`. The macOS branch passes null. This
  keeps platform branching at the composition root rather than inside the shared
  dashboard or its widget tests.

#### 7. `android/app/src/main/kotlin/com/tempos/tracker/SpeechRecognitionBridge.kt` (Create)

* **Type / Scope**: Kotlin method-channel handler and activity-result owner.
* **Proposed Changes**: Handle `isAvailable` by resolving
  `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` through `PackageManager`. Handle
  `listen` by storing the single pending `MethodChannel.Result` and launching
  the recognizer activity with free-form language model, device locale, and
  three results. Expose an `onActivityResult` that returns the first
  `EXTRA_RESULTS` entry on success and null on cancellation or failure, then
  clears the pending result. Reject a second `listen` while one is pending.
  Clear pending state on activity destroy. No `RECORD_AUDIO`, no
  `SpeechRecognizer`, no audio recording.

#### 8. `android/app/src/main/kotlin/com/tempos/tracker/MainActivity.kt` (Modify)

* **Type / Scope**: Activity wiring.
* **Proposed Changes**: Instantiate `SpeechRecognitionBridge` in
  `configureFlutterEngine` with the binary messenger, add a speech request code
  distinct from the notification permission code, forward `onActivityResult` to
  the bridge, and release it in `onDestroy`.

#### 9. `android/app/src/main/AndroidManifest.xml` (Modify)

* **Type / Scope**: Package visibility.
* **Proposed Changes**: Add an `<intent>` for
  `android.speech.action.RECOGNIZE_SPEECH` to the existing `<queries>` block.
  This is required for `resolveActivity` to see the recognizer on Android 11+.
  Do not add `RECORD_AUDIO` or any other permission. Leave the existing CAMERA
  removal comment and behavior untouched.

#### 10. `test/core/activity_matcher_test.dart` (Create)

* **Type / Scope**: Unit tests for the pure matcher.
* **Proposed Changes**: Cover normalization, each tier and its priority,
  both-direction prefix, token prefix, edit-distance thresholds at 3/4/7/8
  characters, duplicate-name tie-break by grid order and id, archived exclusion,
  empty query, the golden corpus from Goal 2, and a fuzz loop over arbitrary
  strings (emoji, combining marks, lone surrogates, 10k characters) asserting no
  throw and a stable order.

#### 11. `test/ui/activity_filter_test.dart` (Create)

* **Type / Scope**: Widget tests for the dashboard filter and the speech seam.
* **Proposed Changes**: Using the existing in-memory `TempoDatabase` pattern,
  verify: closed by default; magnifier opens and focuses; typing filters to the
  expected row; pressing a row creates exactly one Record, closes the filter,
  and restores the grid; clear and back restore the previous screen; a fake
  `SpeechInput` returning a transcript fills the field without labeling;
  `isAvailable` false hides the microphone; tab change and app pause close the
  filter; the no-match state shows the query and Clear. Three suggestion chips
  and the grid must be unchanged with an empty query.

### Files explicitly not changed

* `pubspec.yaml`: no new dependency.
* `lib/data/database/*`, `lib/core/export/*`, `lib/mcp/*`, `lib/wearable/*`:
  no schema, export, or sync changes.
* `lib/desktop/ui/quick_popover_view.dart`: the macOS search keeps its current
  behavior, including create-on-Enter.
* `test/ui/color_blocks_dashboard_test.dart`: the new constructor parameter is
  optional, so existing tests compile unchanged.

### Verification Plan

* **Static analysis**: `dart analyze`
* **Matcher tests**: `flutter test test/core/activity_matcher_test.dart`
* **Filter widget tests**: `flutter test test/ui/activity_filter_test.dart`
* **CI**: full suite runs in GitHub Actions, not locally, per the repo rules.
* **Permission audit**: build the debug manifest and confirm `RECORD_AUDIO` is
  absent from the merged result (`./gradlew :app:processDebugMainManifest` or
  `aapt dump permissions`).
* **Manual playtest on an Android device with a recognizer activity**: seed a
  40-Activity catalog, then run CUJ 1, CUJ 2, and CUJ 3. Confirm the keyboard
  does not hide the context line, the undo bar is reachable for its full three
  seconds, and no microphone permission prompt from Tempo appears.
* **Device caveat**: also verify on one device without a resolvable recognizer
  (or with the recognizer disabled) that the microphone button is hidden and
  typing still works.



