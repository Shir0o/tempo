# Voice-Assisted Activity Filtering (Android)

* **Author:** twang
* **Status:** Proposed
* **Date:** 2026-11-06

--------------------------------------------------------------------------------

## Overview

Tempo labels the always-running open Lap after the fact; a label closes that span
into a Record and starts the next Lap. On the Android Today screen the user picks
from up to four contextually ranked suggestion chips and then from a three-column
grid of every unarchived Activity. There is no search on that screen.

This design adds a text filter to the Today screen and an in-app microphone
button that launches the phone's speech-recognition activity. The user says
"cleaning", the transcript lands in the filter, the matching Activity appears at
the top of a short result list, and the user presses it to label the Lap. The
microphone is a platform hand-off, not an audio pipeline: `RECORD_AUDIO` is not
declared, the recognizer app records the audio, and Tempo receives only text.

The filter carries the feature. It gives a direct path to any unarchived Activity
in a long catalog, works without a microphone or permission, and holds the
matching logic that a future History surface can reuse. The microphone is a
convenience on top of it.

## The Problem

Tempo's capture surfaces are optimized for the common case: label the Lap with
one of the Activities you used recently. The Today screen shows up to four
suggestion chips, then the full catalog as a three-column grid grouped by
category. When the target Activity is neither a chip nor on the first visible
grid rows, the user scrolls and scans. That cost grows with the catalog.

The product targets labeling in under a second. A scroll does not break that
target for a visible block, but it does for an Activity the user cannot see.
There is no way to jump directly to a named Activity from the Today screen, and no
way to speak one there.

No instrumentation in the repo shows how often a label requires a scroll. The
shipped seed catalog holds five Activities; the playtest catalog holds forty.
Those are different things, and the second is not evidence for the first. The
screen may work well enough for most users, and better ranking or a
recent-Activities row may remove the need for a filter entirely.

The speech path introduces its own constraint. Android has no public API that
lets an app press the keyboard's own microphone. Calling `SpeechRecognizer`
directly would require `RECORD_AUDIO`, a runtime permission, a permanent store
listing entry, and an API 31 floor for on-device recognition against a `minSdk`
of 24. Launching `ACTION_RECOGNIZE_SPEECH` avoids all of that: the recognizer
app records, Tempo receives the transcript, and the OS owns the listening
screen. The cost is that the listening UI is not Tempo's, the transcript arrives
only as a final result, and the target activity must be resolvable on Android
11 and later.

## Decision Gate

Proceed only if one of these holds:

* the real Activity catalog has 25 or more unarchived Activities, or
* a one-week manual log shows at least one label in three requiring a scroll.

If neither holds, ship a recent-Activities row or stronger pinning instead and
leave this design unbuilt. Record the answer and the date here before any
implementation. The gate is answered before the code, not inferred from it.

**Recorded 2026-11-06:** the maintainer's catalog holds **49 unarchived
Activities**. The first condition holds, so the filter proceeds. A
scroll-frequency observation is not required.

## Goals

1. **Reach any unarchived Activity without scanning.** With a 40-Activity
   playtest catalog, a user can find and label any named unarchived Activity from
   the Today screen without scrolling the block grid. Verified by the manual
   playtest described in the Verification Plan.
2. **Rank the right Activity first.** For
   `test/fixtures/activity_match_corpus.json` (40 entries, a conservative set
   below the recorded 49-Activity catalog; each has a phrase, an expected
   Activity id, and an optional `mustNotBeFirst` id), the intended Activity
   appears in the top three for at least 90% of positive entries, and no
   `mustNotBeFirst` entry ranks its named Activity first.
3. **Speak a name and press it.** Tapping the microphone button opens the
   system recognition activity; the top transcript fills the filter; the
   matching Activity is visible; one press labels the Lap. No microphone
   permission is requested by Tempo at any point.
4. **Never commit without a press.** No transcript, keystroke, or exact match
   labels a Lap or creates an Activity on its own.
5. **Leave the resting screen unchanged except for one control.** The Today
   screen renders the same chips, grid, order, and tap targets as today; the only
   addition is a 48×48 logical-pixel magnifier in the heading. The filter is a
   modal sheet, so the screen underneath is not rebuilt by filter state and its
   scroll position never changes; the Lap ticker still updates.
6. **Show misses as misses.** A miss shows the query and a clear action, never a
   best-effort row presented as a match. A microphone button appears only when a
   recognizer activity resolves; otherwise the typed field remains fully usable.

## Non-Goals

* Declaring `RECORD_AUDIO`, using `SpeechRecognizer`, shipping a third-party
  speech plugin package, or recording audio inside Tempo.
* Interim-transcript ranking, auto-labeling, auto-creating Activities, or
  create-on-Enter.
* Searching categories, tags, Record comments, or historical Records.
* An English-only or model-based semantic matcher. Matching is deterministic and
  local; "cleaning" does not find "Housework".
* New telemetry, counters, or any upload. Success is verified by tests and a
  manual playtest, not analytics.
* Shipping the typed filter on macOS in v1. The macOS Today screen is unchanged;
  the magnifier renders only when the phone-only filter capability is injected.
* Changes to the watch, the macOS popover, the History edit sheet, the CSV
  export, the MCP server, the sync model, or the database schema.
* Persisting a filter query or adding a settings key. Transient UI state should
  not survive a restart, and a stored query is a privacy and staleness liability.

## Open Questions

* **Question 1**: How large is the maintainer's real Activity catalog, and how
  often does labeling currently require a scroll? Answered 2026-11-06: 49
  unarchived Activities, so the Decision Gate passes. The scroll-frequency part
  is not required for v1.
* **Question 2**: Should a "Recent today" row or stronger pinning ship before
  the filter, or alongside it? Either could reduce how often the filter is
  needed, or remove the need entirely.
* **Question 3**: Which recognizer activity resolves on the maintainer's test
  devices, and does delegating audio to it require a Play data-safety declaration
  update? The declaration is a release gate, not optional paperwork.
* **Question 4**: Does any Activity name in real use contain characters that
  make the no-accent-folding decision visibly wrong? The corpus should prove it.

## Critical User Journeys (CUJs)

### CUJ 1: Label an off-screen Activity by typing (phone only)

* **Given** the Today screen shows an open Lap and a playtest catalog of 40
  Activities, and the target Activity is not among the four suggestion chips.
* **When** the user opens the filter, types one or more characters of the
  Activity name, and presses the matching row.
* **Then** exactly one Record is created for the open Lap, the sheet closes onto
  the unchanged Today screen, and the undo bar reads
  "Logged <Activity> <start>–<end>". On macOS the magnifier is absent in v1.

### CUJ 2: Label by voice

* **Given** the filter is open and a recognizer activity resolves on the device.
* **When** the user taps the microphone button, says an Activity name in the
  system recognition screen, and returns to Tempo.
* **Then** the final transcript fills the filter, the matching Activity appears
  in the top three rows, no Lap is labeled yet, and one press labels it. No
  microphone permission prompt from Tempo appears at any point.

### CUJ 3: A miss does not become a wrong Record

* **Given** the user says or types a phrase that does not plausibly match any
  unarchived Activity.
* **When** the result list renders.
* **Then** the list shows "No unarchived Activity matches '<query>'" with Clear
  and Manage Activities actions, no row is preselected, and nothing is labeled
  until the user presses a real Activity.

## Technical Plan (Architecture)

### Placement and screen states

The filter lives in a modal bottom sheet, opened from a magnifier in the "What
was it?" heading. The magnifier is a trailing 48×48 logical-pixel icon button,
key `activity-filter-button`, semantics label "Filter Activities". It renders
only when the injected `showActivityFilter` capability is true, which is the
Android phone only in v1.

The sheet uses `showModalBottomSheet` with `isScrollControlled: true`, the Ledger
Paper surface from `DESIGN.md`, a height of roughly 70% of the viewport, and
bottom padding from `MediaQuery.viewInsets` so the keyboard never covers the
field. It follows the sheet pattern used by the edit sheet in `history_view.dart`
and the activity editor in `activity_manager_view.dart`.

Three states, with no others:

1. **Closed (default).** Chips and grid exactly as today, plus the magnifier.
2. **Sheet open.** The field is focused on open. It carries a microphone button
   and a trailing × control. Above it, a context line reads
   "Label 10:06 → now · 25m" (`UiHelpers.formatDurationHuman`), because the lap
   panel is behind the barrier and the interval being closed must stay visible.
   With an empty query the sheet shows only the field, the mic, and the context
   line. With a non-empty query it shows a full-width result list capped at 20
   rows, with a "showing N of M" line when truncated. The × clears the query and
   returns to the empty-query view; it does not close the sheet.
3. **Recognition in progress.** The OS speech activity covers Tempo; the sheet
   route stays mounted behind it. On return, the transcript is written into the
   field and the sheet shows results. There is no in-app listening UI and no
   interim ranking.

The sheet closes on drag-down, back, a barrier tap, or a successful label. When
it closes, the Today screen underneath is untouched: same chips, same grid, same
scroll position. There is no offset to save or restore.

### Component map

```text
magnifier in "What was it?" heading
        │
        ▼
   ActivityFilterSheet (modal route)
        │  field text (typed or transcript)
        ▼
   rankActivities(catalog, query)  ← full catalog; archived filtered inside
        │
        ▼
   List<ActivityMatch> → full-width rows
        │
     press row
        │
        ▼
   dashboard._labelActivity(activity) → RecordCommands.label(id)
        │
        ▼
   sheet closes; Today screen is not rebuilt by filter state
```

Components:

* **Matcher** (`lib/core/state/activity_matcher.dart`, new): pure functions,
  no Flutter imports, no database, no clock, no locale. Filters archived
  Activities, owns normalization, tier scoring, and the total order.
* **Filter controller** (`lib/core/state/activity_filter_controller.dart`, new):
  a `ChangeNotifier` holding matches, availability, and the pending guard, so the
  state machine is testable without a widget tree. The dashboard creates and
  disposes it around the sheet route; the sheet listens to it.
* **Sheet** (`lib/ui/activity_filter_sheet.dart`, new): the modal route holding
  the field, mic, ×, context line, and result rows. Takes the controller, the
  archived-inclusive catalog, the speech seam, a `FilterSheetData` object
  (`lapLabel`, `durations`, `categoryNames`), and `onPick`/`onManageActivities`
  callbacks. It returns the picked Activity through `onPick` and never writes a
  Record.
* **Speech hand-off** (`lib/core/speech/speech_input.dart`, new): an abstract
  `SpeechInput` with `Future<bool> isAvailable()` and
  `Future<String?> listen()`, plus a `MethodChannel` implementation. Android
  implements it; macOS and tests receive null.
* **Result row** (`lib/ui/activity_result_row.dart`, new): a full-width row with
  colour swatch, Activity name, total today, and optional category label. Aligns
  with the existing `_buildActivityRow` treatment and adds the total and category
  line as documented extensions.
* **Dashboard** (`lib/ui/dashboard_view.dart`, modify): adds the magnifier,
  opens the sheet, and receives the picked Activity through `onPick` before
  delegating to `_labelActivity`.
* **Injection** (`lib/main.dart`, `lib/ui/tempo_app.dart`, modify): pass
  `speechInput` and `showActivityFilter` down to the dashboard. No
  `Platform.isAndroid` check inside the shared widget, because the dashboard also
  runs on macOS and in host-side widget tests.

### Matcher contract

Input: the archived-inclusive Activity catalog, a query string, and an optional
limit. Output: an `ActivityRanking` carrying `matches` and `total`, where `total`
is the match count before the limit is applied. `ActivityMatch` carries the
Activity and its stage.

Normalization, in this order: trim, lowercase, strip Unicode punctuation
(`\p{P}`, via `RegExp(unicode: true)`) at the start and end of the whole string,
collapse internal whitespace, trim again. Do not strip per token. No accent
folding in v1 — Dart has no Unicode normalization, the edit-distance tier absorbs
a single accent difference, and a hand-maintained fold table is long-term
maintenance for a small gain. No locale-aware comparison anywhere.

Length is counted in runes. Emoji do not shift the thresholds. Combining marks
still count as separate runes, so a decomposed `café` is one rune longer than its
precomposed form; the corpus includes one such name so the behaviour is recorded
rather than assumed.

Tiers, in descending priority:

1. **Exact** — normalized names are equal.
2. **Prefix** — the name starts with the query. This covers "clean" → "Cleaning".
3. **Substring** — the query appears anywhere in the name.
4. **Name token in query** — any whitespace token of the name appears as a token
   in the query. This is what lets "um, cleaning the kitchen" find Cleaning.
5. **Edit distance** — only for queries of 3+ runes and names of 4+ runes.
   Damerau-Levenshtein over runes, with unit insert, delete, substitute, and
   transpose. The threshold comes from the normalized name's rune length: one
   edit at 4–7 runes, two at 8+. Skip the tier when
   `|len(query) − len(name)| > threshold`. This tier ships in Phase 3, not
   Phase 1.

There is no reverse-prefix tier: it promoted "workout was hard" to Work and
"homework" to Home as strong matches. No `tokenPrefix` tier either: a token prefix
is always a substring, so it could never be reached.

Normalize, then clip the query to 64 runes. Longer input is treated as its first
64 runes, and the distance tier runs on that clipped query. This bounds the tier
to about 64 × name length per candidate.

Within a tier, order by `sortOrder`, then normalized name, then Activity id.
Define this comparator inside the matcher; do not import
`lib/ui/helpers/activity_order.dart`, which depends on Flutter and does not carry
the id tie-break. Never rely on `List.sort` stability.

The matcher is total: any input string, including emoji, combining marks, and lone
surrogates, returns a ranking and never throws.

Archived Activities are filtered inside the matcher, and the sheet passes
`_activitiesById.values` (the archived-inclusive catalog), not `_activities`.
Fuzzy results appear only under a "Closest" heading. When no exact, prefix,
substring, or token match exists, no fuzzy row is presented as a normal match and
nothing is preselected. The empty state says "No unarchived Activity
matches '<query>'" and offers Clear and Manage Activities, so an archived name is
not a dead end.

### Speech hand-off contract

`SpeechInput.isAvailable()` asks the Android side whether
`RecognizerIntent.ACTION_RECOGNIZE_SPEECH` resolves to an activity with
`PackageManager.MATCH_DEFAULT_ONLY`. `MethodChannelSpeechInput` owns the
availability cache and re-resolves it when the sheet opens. The sheet requests
availability through the controller and renders no microphone until the first
resolution; a resolution after dispose is ignored. When no activity resolves, the
microphone is absent and the typed field is unaffected.

`SpeechInput.listen()` starts the recognizer activity with:

* `EXTRA_LANGUAGE_MODEL` free-form,
* `EXTRA_LANGUAGE` set to `Locale.getDefault().toLanguageTag()`,
* `EXTRA_MAX_RESULTS` 1,
* no `EXTRA_PARTIAL_RESULTS`, because the caller receives only the final result.

The Kotlin side is a `FlutterPlugin` that implements `ActivityAware`, owns a
single pending `MethodChannel.Result`, and receives its result through
`ActivityPluginBinding.addActivityResultListener`, following
`BackupDestinationChannel`. It is registered with `flutterEngine.plugins.add(...)`
and uses `REQUEST_RECOGNIZE = 0x5B0` in its companion object. `MainActivity` gains
no `onActivityResult` override, so the existing backup folder picker keeps
receiving results.

`android.speech.action.RECOGNIZE_SPEECH` and
`RecognizerIntent.ACTION_RECOGNIZE_SPEECH` are the same string.

Tempo does not request `RECORD_AUDIO`; the recognizer activity owns the
microphone. The result is `getStringArrayListExtra(EXTRA_RESULTS)?.firstOrNull()`
— null when the list is absent or empty. A cancelled or failed recognition
resolves the call with null and leaves the field as it was. On detach, destroy,
or engine detach, the bridge completes a pending call with
`error("SPEECH_DETACHED", …)` before clearing it. A second `listen` while one is
pending returns `error("SPEECH_BUSY", …)`. The Dart side maps any
`PlatformException` to null, times out after 60 seconds, and clears the pending
guard in `finally`; a late result after dispose is ignored with
`if (!mounted) return`.

The top returned alternative is written into the field as literal text, not
parsed. The app calls `FocusScope.of(context).unfocus()` before launching and
after writing the transcript, and never requests focus or reopens the keyboard on
return. The
bridge never logs the transcript, the query, or `EXTRA_RESULTS`; it logs only the
method name and an error code.

Only one recognition may be in flight. The sheet disables the microphone button
while the controller reports a pending call.

### State and lifecycle rules

The `TextEditingController` and `FocusNode` live in the sheet's `State` and are
disposed when the route closes. The dashboard creates the
`ActivityFilterController`, passes it in, and disposes it after the
`showModalBottomSheet` future completes; the sheet listens to it and never
disposes it. The text controller is the query source; the filter controller holds
matches, availability, and the pending flag. The sheet is a
`WidgetsBindingObserver` for the pause rule; the dashboard calls
`refreshMatches` from `_loadData` and pops the sheet when an external label
lands.

| Event | Query | Sheet | Notes |
| --- | --- | --- | --- |
| Result-row tap | clear | close | then `_labelActivity` → reload; a failure shows the existing SnackBar on Today and the user reopens |
| × control | clear | open | returns to the empty-query view |
| Drag-down, back, or barrier tap | clear | close | native route dismissal |
| Deep-link or broadcast label | clear | close | dashboard pops the sheet |
| Catalog changes while open | keep | open | `_loadData` calls `refreshMatches` with the new catalog |
| `paused` with no recognition pending | clear | close | privacy rule; the sheet pops itself |
| `paused` while `listen()` is pending | keep | open | transcript lands on resume |
| `hidden` | same as `paused` | same | the platform sends it between `inactive` and `paused` |
| `inactive` | keep | open | notification shade or dialog; never closes |

While a recognition is pending, the sheet route stays mounted across the pause.
`AppLifecycleState.inactive` alone never closes the sheet. If the activity is
recreated, the sheet is gone and nothing is labeled; the user reopens it. The
query is not persisted, by design.

Matches are recomputed when the query changes or the catalog changes. The
one-second live ticker continues to update the Lap display behind the barrier and
does not re-run the matcher.

The filter is not persisted. Because the sheet is a route, the dashboard's
`IndexedStack` state and scroll position are untouched; there is no tab-change
listener and no offset to restore.

### Accessibility

* The field has a minimum height of 56 logical pixels and grows with text scale;
  no fixed height that clips.
* The microphone button has a 48×48 logical-pixel target and a semantics label
  that is "Start voice input" when enabled. It is absent when no recognizer
  resolves, and disabled with the hint "Starting voice input" while a call is
  pending. There is no "Listening" state to announce, because the OS screen is
  on top.
* The field hint is "Filter Activities".
* The field keeps input focus while the query is being edited; the result list
  appearing must not move focus or close the keyboard. After a voice transcript,
  or when the user explicitly navigates to the results, move focus to the first
  row.
* On close, return input focus to the magnifier through an explicit `FocusNode`.
* The result region is a live region announcing the count ("3 activities match")
  when it changes, throttled so it does not announce on every keystroke.
* The typed path is complete and primary. The microphone is additive, never the
  only way to reach a result.

## Risks & Mitigations

| Risk | Trigger | Mitigation | Residual risk |
| --- | --- | --- | --- |
| Audio leaves Tempo's trust boundary | User taps the microphone | OS recognizer owns audio; Tempo stores and logs no audio or transcript; Play data-safety check is a release gate | The recognizer service's policy still applies |
| Process death during recognition | Low memory or task killer | Pending result resolves null on detach; 60-second Dart timeout; field unchanged | User retries by tapping the mic again |
| Stale catalog behind an open filter | Activity renamed or archived elsewhere | Recompute matches whenever `_activities` is replaced; matcher filters archived | A mid-gesture reorder is possible |
| False-positive fuzzy match | Short names and edit distance | Fuzzy rows only under "Closest"; no preselect; `mustNotBeFirst` corpus entries | A user can still press the wrong row deliberately |
| Keyboard hides the result | Sheet opens with the field focused | `isScrollControlled` sheet padded by `viewInsets`; unfocus before and after recognition; 56-pixel field | Small screens with 2× text scale still need the manual check |
| Corpus never authored | Work starts without fixtures | Corpus is a named target file and a Goal 2 prerequisite | Goal 2 remains unverifiable until it exists |
| macOS surface change | Shared `DashboardView` | `showActivityFilter` defaults false; phone composition passes true | A future macOS change must opt in explicitly |

## Alternatives Considered

### Alternative A: Do nothing and measure first

* **Pros**: Zero code, zero manifest changes, and it tests the premise honestly.
  The shipped seed catalog is five Activities; the maintainer's catalog is 49,
  which is a long catalog by any measure.
* **Cons**: Does not answer the request, and the product has no analytics to
  measure scroll frequency with. Any "measurement" would be a manual playtest
  with a synthetic catalog.
* **Reason for Rejection**: Rejected as the deliverable, but retained as the
  Decision Gate. The gate is answered (49 unarchived Activities, recorded
  2026-11-06), so the filter proceeds; the scroll-frequency observation is
  optional for v1.

### Alternative B: Better ranking instead of a new surface

* **Pros**: A "Recent today" row of 8–10 one-tap chips, or surfacing pinning on
  the dashboard, solves "not in the top four" with no field, no keyboard, and no
  platform hand-off. It stays inside the one-tap capture promise.
* **Cons**: It only covers Activities used recently or pinned. An Activity used
  rarely but known by name still requires scanning.
* **Reason for Rejection**: Cheaper, but it does not provide a direct path to a
  named Activity in a long catalog. It remains the fallback if the Decision Gate
  fails or the filter proves too heavy in review.

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
  interaction. It remains the fallback if the recognizer hand-off fails review.

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
  changing an existing surface's behavior, with its own tests and re-baselined
  screenshots.
* **Reason for Rejection**: Speculative reuse with one caller. Extract on the
  second real caller, and keep create-on-Enter out of the phone.

### Alternative G: Semantic matching, aliases, or an on-device model

* **Pros**: "cleaning" would find "Housework" or "Chores", which deterministic
  matching cannot do.
* **Cons**: Requires an alias list the user maintains or a model to ship,
  quantize, version, and test. It adds latency, package size, and a new failure
  mode where a plausible but wrong Activity ranks first.
* **Reason for Rejection**: Too large for the problem, and it weakens the "a miss
  looks like a miss" property that protects the record.

### Alternative H: Put search in the History edit sheet first

* **Pros**: The edit sheet renders every Activity as a wrapped chip with no
  filter, so it has the long list and no alternative path.
* **Cons**: It does not help labeling the open Lap, which is the requested
  interaction and the more frequent one.
* **Reason for Rejection**: The matcher is a pure function so the History picker
  can adopt it in a later change without redesign.

### Alternative I: Inline expanding field on the Today screen

* **Pros**: The chips and grid stay visible while the field is open, and there is
  no route to push.
* **Cons**: Requires a `ScrollController` with clamped post-frame restore, a
  `PopScope` back rule, tab-change clearing, and explicit keyboard-occlusion
  handling. Four mechanisms, each with its own failure mode.
* **Reason for Rejection**: A modal sheet gets dismissal, scroll isolation, tab
  isolation, and keyboard padding from the framework. The only benefit given up,
  visible chips, applies only to the empty-query state, which is a transient stop
  on the way to a query.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### Security and privacy

Tempo declares no microphone permission and records no audio. The recognizer
activity owns the microphone and returns text. The utterance leaves Tempo: the
recognizer app may process audio off-device under its own policy. Tempo stores no
audio and receives only text. The Play data-safety declaration is a release gate,
not optional paperwork, and copy must never describe recognition as on-device.
The typed path is the private path.

The transcript lives in widget state only: it is never written to a Record
comment, never exported, never logged, and is cleared when the filter closes, the
tab changes, the app pauses without a pending recognition, or the Lap is labeled.
The bridge logs only method names and error codes, never the transcript, the
query, or `EXTRA_RESULTS`. The matcher and filter make no network calls. No
telemetry or counters are added.

### Performance and latency

Normalization runs per search call, not per frame. Cost is bounded by the clipped
query (64 runes) × the longest Activity name × the number of candidates; the
distance tier is skipped when the length difference exceeds its threshold. The
one-second Lap ticker does not re-run the matcher. The speech path's latency is
owned by the OS recognizer; the design adds no work while it is open.

### Compatibility and rollout

The feature adds no schema, no settings key, no sync payload, no CSV field, and
no MCP tool. The typed filter is Android-only in v1 via `showActivityFilter`;
macOS and existing widget tests default to false. Removing the UI restores the
previous screen exactly, so rollback is a code revert with no data migration.
The capability is a compile-time switch (`showActivityFilter`), not a remote
feature flag. The only manifest change is a `<queries>` entry for
`android.speech.action.RECOGNIZE_SPEECH`; `RECORD_AUDIO` must be absent from the
merged manifest and is checked in verification.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

This document specifies the change; it is written before any code.
`pubspec.yaml` is unchanged: no new dependency, no speech plugin, no model.

### Phases

1. **Typed find.** Matcher (exact, prefix, substring, name-token-in-query), the
   `SpeechInput` interface with a null implementation, result row,
   `ActivityFilterController`, filter sheet, magnifier, unit and widget tests. No
   Android code. Checkpoint: `dart analyze` and the matcher, controller, and
   filter tests.
2. **Voice.** `MethodChannelSpeechInput`, ActivityAware bridge, `<queries>`,
   pending guard, availability, device pass. Checkpoint: the APK builds and the
   typed path is unchanged.
3. **Fuzzy.** Damerau-Levenshtein and the "Closest" heading, only if the Phase 1
   corpus top-three rate is below 90%. Checkpoint: the same corpus re-run.

Each phase leaves the app buildable. Reverting phases 2–3 leaves typed filtering
intact.

### Target Files to Create/Modify

#### 1. `lib/core/state/activity_matcher.dart` (Create)

* **Type / Scope**: Pure Dart matching module. No Flutter imports, no database,
  no clock, no locale.
* **Rationale**: The ranking logic must be testable without a widget tree and
  reusable by the History picker later.
* **Proposed Changes**: Define `ActivityMatchStage` as an ordered enum (exact,
  prefix, substring, nameTokenInQuery, editDistance) and `ActivityMatch` carrying
  the Activity and its stage. Provide
  `ActivityRanking rankActivities(List<Activity> catalog, String query,
  {int limit = 20})`, where `ActivityRanking` carries `matches` and the untruncated
  `total`; the function filters `isArchived` internally, precomputes normalized
  names, and returns ranked matches. Normalization order: trim, lowercase, strip
  boundary `\p{P}` with `RegExp(unicode: true)`, collapse whitespace, trim.
  Sort by tier, `sortOrder`, normalized name, id; do not rely on sort stability.
  Return an empty ranking for an empty query. The function is total and never
  throws. Phase 1 implements the first four stages; `editDistance` and its
  threshold are added in Phase 3.

#### 2. `lib/core/state/activity_filter_controller.dart` (Create)

* **Type / Scope**: `ChangeNotifier` from `flutter/foundation`, no widgets or
  `BuildContext`.
* **Rationale**: Keeps the sheet's state machine and the pending guard out of the
  1,100-line dashboard and unit-testable.
* **Proposed Changes**: Hold the catalog, query, matches, availability, and the
  pending-listen flag. `setQuery` normalizes and recomputes matches from the held
  catalog, so query and matches cannot diverge. Expose `clear()`,
  `setCatalog(List<Activity>)`, `setQuery(String)`, `setAvailability(bool)`,
  `markListening()`, and `finishListening()`. Own no platform types beyond the
  injected `SpeechInput` interface.

#### 3. `lib/ui/activity_filter_sheet.dart` (Create)

* **Type / Scope**: Stateful Flutter widget presented as a modal bottom sheet.
* **Rationale**: The sheet is the filter's container, so the dashboard only opens
  it and receives a picked Activity. The route supplies dismissal, scroll
  isolation, and tab isolation without additional code.
* **Proposed Changes**: `showActivityFilterSheet(context, controller, catalog,
  speechInput, data, onPick, onManageActivities)` calls `showModalBottomSheet`
  with `isScrollControlled: true`, `FractionallySizedBox(heightFactor: 0.7)`, and
  bottom padding from `MediaQuery.viewInsets`. `data` is a small
  `FilterSheetData` carrying `lapLabel`, `durations`, and `categoryNames`. The
  widget renders the focused field, mic, ×, context line, result rows, and the
  "showing N of M" line from `ActivityRanking.total`. It owns the
  `TextEditingController` and `FocusNode`, listens to the controller for matches,
  and calls `onPick` or `onManageActivities`. `onManageActivities` pops the sheet,
  pushes `ActivityManagerView`, and the dashboard reloads on return. It never
  writes a Record.

#### 4. `lib/core/speech/speech_input.dart` (Create)

* **Type / Scope**: Platform-agnostic abstraction plus the Android channel
  implementation.
* **Rationale**: Keeps the Android lifecycle outside the shared dashboard, groups
  the seam with the other `core` platform adapters, and lets tests inject a fake.
* **Proposed Changes**: Define `abstract class SpeechInput` with
  `Future<bool> isAvailable()` and `Future<String?> listen()`. Add
  `MethodChannelSpeechInput` over a `tempo/speech` channel with those methods,
  an availability cache owned here and re-resolved when the sheet opens, a
  60-second timeout on `listen`, and mapping: `isAvailable` returns false on
  `MissingPluginException` or `PlatformException`; `listen` returns null on
  either, on timeout, or on an activity-launch failure. No permission calls, no audio API.

#### 5. `lib/ui/activity_result_row.dart` (Create)

* **Type / Scope**: Stateless Flutter widget.
* **Rationale**: The dashboard file is already large, and the row has a visual
  contract shared with the block and popover rows.
* **Proposed Changes**: A full-width row taking an Activity, today's duration in
  milliseconds, an optional category name, and `onTap`. Renders a colour swatch,
  name, trailing duration via `UiHelpers.formatDurationHuman` (zero renders
  "—", matching the existing popover row), and a small uppercase category line
  when present. Minimum height 48 logical pixels, `TempoRadii.row` for the row
  and radius 5 for the swatch, matching `history_view.dart`. Key format
  `activity-result-<id>`; semantics label includes name, duration, and "Tap to
  label untracked time". No long-press action in v1.

#### 6. `lib/ui/dashboard_view.dart` (Modify)

* **Type / Scope**: The Today screen state and layout.
* **Rationale**: This is the only screen that opens the filter; the rest of the
  app should not know about it.
* **Proposed Changes**: Add `SpeechInput? speechInput` and
  `bool showActivityFilter = false` constructor parameters, plus a `FocusNode`
  for the magnifier. Add the trailing 48×48 magnifier, key
  `activity-filter-button`, semantics "Filter Activities", visible only when
  `showActivityFilter` is true. On tap, create the `ActivityFilterController`
  with `_activitiesById.values` (archived-inclusive), open
  `showActivityFilterSheet` with `lapLabel`, `_todayActivityDurations`,
  category names, `onPick`, and `onManageActivities`, and dispose the controller
  when the route future completes. `_loadData` calls `controller.setCatalog` so an
  open sheet sees catalog changes. On an external label, pop the sheet. On pick,
  close the sheet and delegate to the existing `_labelActivity`; a failure shows
  the existing SnackBar on Today. Do not add a `ScrollController`, `PopScope`,
  tab-index listener, or saved offset. Do not change `_labelActivity`'s write
  path.

#### 7. `lib/ui/tempo_app.dart` (Modify)

* **Type / Scope**: App shell and dependency injection.
* **Rationale**: Supplies the capabilities without platform checks inside the
  dashboard.
* **Proposed Changes**: Accept `SpeechInput? speechInput` and
  `bool showActivityFilter = false`, both with defaults, and pass them to
  `DashboardView`. Existing `TempoApp` callers, including
  `test/widget_test.dart`, compile unchanged. No tab index, no notifier, no new
  disposal. No other screen changes.

#### 8. `lib/main.dart` (Modify)

* **Type / Scope**: Platform composition root.
* **Rationale**: The phone is the only platform that enables the filter in v1.
* **Proposed Changes**: Declare `final isAndroid = !kIsWeb && Platform.isAndroid`
  and a nullable `SpeechInput? speechInput` before the platform block; assign
  `MethodChannelSpeechInput()` when `isAndroid`; pass `speechInput` and
  `showActivityFilter: isAndroid` to the single `runApp(TempoApp(...))`.
  `_startReplica` omits both, so macOS defaults to null and false.

#### 9. `android/app/src/main/kotlin/com/tempos/tracker/SpeechRecognitionBridge.kt` (Create)

* **Type / Scope**: Kotlin `FlutterPlugin, ActivityAware` channel handler.
* **Rationale**: Follows `BackupDestinationChannel`, which exists precisely to
  avoid an `onActivityResult` override in `MainActivity`.
* **Proposed Changes**: `companion object` with `CHANNEL_NAME = "tempo/speech"`
  and `REQUEST_RECOGNIZE = 0x5B0`. Handle `isAvailable` with
  `resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null`. Handle
  `listen` by storing one pending `MethodChannel.Result` and launching the
  recognizer with free-form model, `Locale.getDefault().toLanguageTag()`, one
  result, and no partials. Receive the result through
  `ActivityPluginBinding.addActivityResultListener`; return
  `getStringArrayListExtra(EXTRA_RESULTS)?.firstOrNull()`, null on cancel or
  empty. Reject a second listen with `SPEECH_BUSY`. On detach or engine detach,
  complete a pending call with `SPEECH_DETACHED` before clearing. Never log the
  transcript, query, or results.

#### 10. `android/app/src/main/kotlin/com/tempos/tracker/MainActivity.kt` (Modify)

* **Type / Scope**: Plugin registration only.
* **Rationale**: One registration line, no new result choke point.
* **Proposed Changes**: Register `SpeechRecognitionBridge` with
  `flutterEngine.plugins.add(...)` beside the existing registrations. Do not add
  an `onActivityResult` override or a request code.

#### 11. `android/app/src/main/AndroidManifest.xml` (Modify)

* **Type / Scope**: Package visibility.
* **Rationale**: Android 11+ hides the recognizer without this entry.
* **Proposed Changes**: Add an `<intent>` for
  `android.speech.action.RECOGNIZE_SPEECH` to the existing `<queries>` block. Do
  not add `RECORD_AUDIO` or any other permission. Leave the CAMERA removal
  untouched.

#### 12. `test/core/activity_matcher_test.dart` (Create)

* **Type / Scope**: Unit tests for the pure matcher.
* **Rationale**: The matcher is the only CI-verifiable part of the ranking.
* **Proposed Changes**: Phase 1 covers normalization (including
  `RegExp(unicode: true)` for `\p{P}`), the four strong tiers and their priority,
  duplicate-name tie-break by `sortOrder`, then normalized name, then id,
  archived filtering from an archived-inclusive catalog, empty and
  punctuation-only queries (which normalize to empty and return
  `matches: []`), the `total` before the limit, the 40-entry corpus, and a fuzz
  loop with `Random(0)` and a fixed input list (emoji, combining marks, lone
  surrogates, 10k characters) asserting no throw and identical output across two
  runs. Phase 3 adds `(queryLength, nameLength)` pairs at 3/4/5/6/7/8 and the
  64-rune clip behaviour.

#### 13. `test/fixtures/activity_match_corpus.json` (Create)

* **Type / Scope**: Test fixture.
* **Rationale**: Goal 2 needs a concrete, checked-in input.
* **Proposed Changes**: 40 entries, each `{phrase, expectedActivityId,
  mustNotBeFirst}`, where both id fields are nullable. Positive entries use
  `expectedActivityId`; the two negative entries set it to null and are excluded
  from the 90% denominator, but must still respect `mustNotBeFirst`. Includes four
  filler phrases, one duplicate name, and one diacritic name. The test asserts
  top-three ≥ 90% over positives and zero `mustNotBeFirst` violations.

#### 14. `test/fixtures/activity_catalog_40.json` (Create)

* **Type / Scope**: Test fixture.
* **Rationale**: The corpus ids must resolve to a fixed catalog with names,
  categories, and archived flags.
* **Proposed Changes**: 40 Activities, each `{id, name, categoryId, isArchived}`.
  Two names are duplicates with different ids, one is archived, and one uses a
  diacritic. Both the matcher corpus test and the widget tests load this file, so
  the playtest catalog is reproducible.

#### 15. `test/ui/activity_filter_test.dart` (Create)

* **Type / Scope**: Widget tests for the filter sheet and the speech seam.
* **Rationale**: Verifies the three states and the no-write invariants.
* **Proposed Changes**: Using `sqfliteFfiInit()` +
  `TempoDatabase.openInMemory(factory: databaseFactoryFfiNoIsolate)`, verify:
  the magnifier is absent when `showActivityFilter` is false and present when
  true; tapping it opens the sheet with the field focused; typing filters to the
  expected row; pressing a row creates exactly one Record and closes the sheet;
  the × clears and keeps the sheet open; drag-down and back dismiss it; a fake
  `SpeechInput` fills the field without labeling; availability false hides the
  mic; a pending listen disables it; pause with a pending fake keeps the sheet
  and pause without one closes it; the no-match state shows the query, Clear, and
  Manage Activities; the 20-row cap and "showing N of M" line; input focus stays
  in the field after a query produces rows; the transcript is not written to any
  Record comment; `tester.testTextInput.isVisible == false` after the fake
  transcript.

#### 16. `test/core/activity_filter_controller_test.dart` (Create)

* **Type / Scope**: Unit tests for the state machine.
* **Rationale**: The controller was extracted to be testable without a widget
  tree; its pending and availability transitions are the risky part.
* **Proposed Changes**: Cover query-to-match recomputation, `setCatalog`
  replacing matches, availability transitions, double-listen rejection, clear
  during pending, and disposal safety.

#### 17. `test/speech/speech_input_test.dart` (Create)

* **Type / Scope**: Channel wrapper test with a mocked messenger.
* **Rationale**: The wrapper's error mapping is otherwise untested.
* **Proposed Changes**: Use
  `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`
  to cover success, cancellation, `PlatformException`, `MissingPluginException`,
  and timeout; tear down with a null handler.

#### 18. `DESIGN.md`, `test/ui/color_blocks_dashboard_screenshot_test.dart`, and `screenshots/color_blocks_dashboard*.png` (Modify)

* **Type / Scope**: Design system, screenshot harness, and visual baselines.
* **Rationale**: The heading gains one control, and the new row is a component.
* **Proposed Changes**: Document the result-row variant, the magnifier, and the
  sheet surface. Update the screenshot test to pass
  `showActivityFilter: true` and a null `SpeechInput`, then re-capture with
  `TEMPO_SCREENSHOT=1 flutter test test/ui/color_blocks_dashboard_screenshot_test.dart --update-goldens`.

#### 19. `test/fixtures/seed_40_activities.csv` (Create)

* **Type / Scope**: Import fixture for the manual playtest.
* **Rationale**: Goal 1's playtest needs a repeatable 40-Activity catalog, not 35
  hand-typed entries.
* **Proposed Changes**: A Simple Time Tracker CSV that the existing Settings →
  "Import from Simple Time Tracker" flow ingests with `catalogOnly`, creating the
  same names as `activity_catalog_40.json`.

### Files explicitly not changed

* `pubspec.yaml`: no new dependency.
* `lib/data/database/*`, `lib/core/export/*`, `lib/mcp/*`, `lib/wearable/*`:
  no schema, export, or sync changes.
* `lib/desktop/ui/quick_popover_view.dart`: the macOS search keeps its current
  behavior, including create-on-Enter.
* `test/ui/color_blocks_dashboard_test.dart` and `test/widget_test.dart`: the new
  constructor parameters have defaults, so both compile unchanged.

### Verification Plan

* **Static analysis**: `dart analyze`
* **Matcher tests**: `flutter test test/core/activity_matcher_test.dart`
* **Controller tests**: `flutter test test/core/activity_filter_controller_test.dart`
* **Filter widget tests**: `flutter test test/ui/activity_filter_test.dart`
* **Channel wrapper tests**: `flutter test test/speech/speech_input_test.dart`
* **Android build**: `flutter build apk --debug` from the repo root. This compiles
  the Kotlin bridge; the Gradle wrapper is generated by Flutter and is not
  checked in.
* **CI**: full suite runs in GitHub Actions, not locally, per the repo rules.
* **Permission audit**: after the debug build, run the SDK's `aapt2` from the repo
  root:
  `$ANDROID_HOME/build-tools/<version>/aapt2 dump permissions build/app/outputs/flutter-apk/app-debug.apk`
  and confirm `RECORD_AUDIO` is absent. Then
  `$ANDROID_HOME/build-tools/<version>/aapt2 dump xmltree --file AndroidManifest.xml build/app/outputs/flutter-apk/app-debug.apk`
  and confirm the `android.speech.action.RECOGNIZE_SPEECH` query is present.
* **Manual playtest on an Android phone with a recognizer activity**: import
  `test/fixtures/seed_40_activities.csv` through Settings → "Import from Simple
  Time Tracker" with `catalogOnly`. Use a 390×844 portrait viewport at 1.0 text
  scale. Run CUJ 1, CUJ 2, and CUJ 3. Fail if the keyboard covers the context
  line or the first three result rows, if the undo bar is not tappable for three
  seconds, or if Tempo shows a microphone permission prompt.
* **Device caveat**: on an AOSP emulator image with no recognition service, or
  after disabling the resolved recognizer package with `adb shell pm
  disable-user --user 0 <package>`, confirm the microphone is hidden and typing
  still works. The Kotlin bridge is build- and playtest-verified, not unit-tested.

--------------------------------------------------------------------------------

## Additional Resources

* `.scratch/time-tracker/concepts_brief_voice_input.md` — the brainstorm brief
  and the multi-lens review that shaped this design.
* `PRODUCT.md` — sub-second capture, local-first privacy, and the no-telemetry
  posture.
* `CONTEXT.md` — Activity, Record, Lap, Untracked Record, and Boundary
  vocabulary.
* `lib/ui/dashboard_view.dart` — the Today screen, suggestion row, grid, label
  path, ticker, and undo bar.
* `lib/core/state/suggestion_engine.dart` — the pure ranking precedent.
* `lib/desktop/ui/quick_popover_view.dart` — the existing macOS search, its
  pinned-only scope, and its create-on-Enter behavior.
* `android/app/src/main/kotlin/com/tempos/tracker/BackupDestinationChannel.kt` —
  the ActivityAware result pattern the speech bridge follows.
* `android/app/src/main/AndroidManifest.xml` — current permissions, the CAMERA
  removal decision, and the existing `<queries>` block.
* `.scratch/time-tracker/issues/04-wear-os-ui-and-tile-spec.md` — the watch's
  decision to use fixed slots instead of search.

## Future Improvements

* **A "Recent today" row.** 8–10 one-tap chips built from the last Records could
  remove most uses of the filter while staying at one tap.
* **Share the matcher with the History edit sheet.** The edit sheet renders every
  Activity with no filter; the pure matcher makes that a small, separate change.
* **Adopt the matcher on macOS.** Widen the desktop filter to the full catalog
  and remove create-on-Enter in its own change, with its own tests.
* **Alias support.** A per-Activity alias list, or a deterministic plural and
  suffix rule, would bridge "cleaning" to "Housework" without a model.
* **Accent folding.** If the corpus shows real names with diacritics, add a
  tested fold table rather than a guess.

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
