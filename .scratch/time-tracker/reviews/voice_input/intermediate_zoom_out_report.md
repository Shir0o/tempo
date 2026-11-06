# Intermediate Zoom Out Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md` (lines 1–618)
**Stage:** 8 (Intermediate Zoom Out)
**Reviewer:** `egm-zoom-out`
**Context read:** Stage 5 `zoom_out_report.md`, Stage 6 `comprehension_report.md`,
Stage 7 `critic_report.md`.

## Verdict

The document still passes context sufficiency, and the alternatives remain real.
At whole-system level the design is **architecturally over-built for its
evidence**, and the over-build is concentrated in one unargued decision:
rendering the filter inside the dashboard's scroll view. The voice half is also
sequenced ahead of the evidence, and its expensive matcher tiers are speech
features sitting in the typed slice.

Findings below do not repeat Stages 5–7. Where they touch a recorded finding,
the new part is named.

## What earlier stages missed

* The container decision. Scroll restoration, back-press ownership, tab-change
  clearing, and keyboard occlusion were treated as four gaps; they share one
  root cause: in-place expansion inside a `CustomScrollView`.
* The existing modal Activity chooser (`history_view.dart:171–240`) already does
  "heading + list of every Activity + tap to pick", titled "What was it?".
* The dashboard has three label paths, not one: result rows, `Same as last`, and
  external deep-link/broadcast labels. `Split` is a fourth state change.
* The 40-Activity verification catalog has no artifact, though the repo has a
  bulk import path.
* Two zero-additional-code voice paths exist once the field ships: keyboard
  dictation and the Assistant → broadcast → deep-link path. Neither is measured
  against the in-app button.
* The matcher's expensive tiers are speech features, not typed-search features.

## Blockers

### 1. The filter is built in the hardest container
Affected: 146–167, 275–289, 497–525.

In-place expansion forces a saved scroll offset (no `ScrollController` exists at
`dashboard_view.dart:380`), a back-press interceptor (`DashboardView` is an
`IndexedStack` child, not a route), a tab listener plus `ValueNotifier<int>`
plumbing, and a keyboard-versus-context-line argument. A modal sheet supplies
all four for free: back dismisses it, the nav bar is behind the barrier, the
dashboard offset is untouched, and the route survives the recognizer hand-off.

`history_view.dart:171–240` already opens a `showModalBottomSheet` titled "What
was it?" with a swatch/name row per Activity and returns the chosen Activity.
`activity_manager_view.dart:71`, `category_manager_view.dart:86`, and
`settings_view.dart:611,810` use the same pattern. The only genuine argument for
inline is "chips stay visible while filtering"; the document never states that as
a requirement or tests whether it matters. If it is load-bearing, say so; it is
the sole justification for the whole state machine.

## Majors

### 2. The field, not the button, enables voice
A focused text field exposes the keyboard's dictation key, and
`TempoBroadcastReceiver` + `deep_link_service.dart:139–160` already label from an
Assistant routine. Both are dismissed for not matching the requested interaction
shape, without weighing that against a Kotlin bridge, a manifest entry, a Play
data-safety check, injection through three files, and the only component with no
automated coverage. Justify the in-app button by measured keyboard-mic friction,
not by interaction shape alone.

### 3. Delivery seam is wrong: fuzzy matching is a voice feature in the typed slice
Goal 1 (typed find) needs exact, name-prefix, and substring. Reverse prefix
exists for truncated speech; edit distance and "Closest" exist for recognition
error; Goal 2's corpus is spoken. Shipping them together makes the unmeasured
half gate the measurable half and keeps the wrong-Record hazard in v1.

Proposed slices: (1) typed find with exact/prefix/substring and the picker; (2)
voice plus reverse prefix, edit distance, and the corpus; (3) "Closest" only if
the corpus shows the need.

### 4. Goal 1 cannot fail
At 40 Activities the grid is about 14 rows, so the need for a filter is
guaranteed by construction. Passing only proves the matcher works on 40 names.
Alternative A says the realistic grid is two to seven rows, and the seed is five.
The two numbers support opposite conclusions and nothing chooses between them.
Add a pre-registered catalog size or observed scroll frequency that justifies the
feature, plus a written "do not ship" outcome.

### 5. The verification catalog has no creation mechanism
Widget tests use an in-memory database with a handful of Activities; no fixture
file appears among the eleven. The manual playtest says "seed a 40-Activity
catalog" with no procedure, which in the UI means creating about 35 Activities by
hand. The repo already has a bulk path: Settings imports a Simple Time Tracker
file with `SttImportScope.catalogOnly` (`stt_import_service.dart:14,177–243`;
`settings_view.dart:886`). Use it, and add a checked-in 40-Activity fixture.

### 6. The pause fix is necessary but not sufficient
Hand-off is pause → OS recognizer → possible activity recreation → resume →
result. "Do not clear while pending" only covers the happy path. Undefined:
transcript after a tab switch from the OS screen; after a dashboard rebuild by a
deep-link label or catalog reload; after activity recreation; user cancels then
reopens; result arrives after an unrelated label's undo window. One owner for the
pending result and an explicit return matrix are the minimum.

### 7. "Does not reopen the keyboard" is asserted, not engineered
The field retains focus across the pause; Android normally re-shows the IME for a
focused field on resume, covering the result list. Unfocus before launching or on
resume before writing the transcript, and re-focus only on an explicit tap.

### 8. Kotlin plan diverges from the repo's plugin seam
`BackupDestinationChannel` is already a `FlutterPlugin, ActivityAware` with a
pending result, a request code, and `ActivityPluginBinding`, registered through
`flutterEngine.plugins.add`. The plan instead builds a bare class from the binary
messenger, adds a request code "distinct from the notification permission code"
(ignoring `0x5AF`), overrides `onActivityResult`, and releases in `onDestroy`.
An override that misses `super` breaks the shipped backup picker.

### 9. Three label paths exist; lifecycle rules wire one
States 2 and 3 keep the lap panel, which carries `Split` and `Same as last`, and
a deep link or broadcast can label while the dashboard lives. "Closed and cleared
on successful label" is implemented only for the result-row tap. Decide once: any
successful label closes and clears; `Split` keeps the query and re-reads the Lap.

### 10. Device-dependent path with no failure signal
Availability is cached for the session; errors collapse to null, indistinguishable
from cancellation. A wrong `<queries>` entry, disabled OEM recognizer, or bridge
regression simply hides the button or does nothing, and there is no telemetry.
Re-resolve availability on each open (a `PackageManager` query, no I/O), and add
a debug-only error log (never the transcript) plus a release smoke step.

## Nits

11. `EXTRA_MAX_RESULTS` 3 with only the top used. Surface alternatives or request 1.
12. Tie-break order duplicates `activity_order.dart:29–34`; extract or reuse.
13. Robustness budget is inverted: fuzz tests cover surrogates while fillers and
    verb-first phrases, the realistic failures, have no fixture.
14. The document is materially unchanged across three review rounds; require a
    revision marking each prior finding applied or rejected.

## Smallest coherent delivery

1. Decision note: real catalog size and one week of "did I scroll?" observation.
2. Slice 1: matcher (exact/prefix/substring) plus a modal picker in the existing
   `_pickActivity` pattern, opened from the Today heading. Keyboard dictation
   already supplies voice.
3. Slice 2, only if dictation friction is observed: `SpeechInput`, ActivityAware
   bridge, `<queries>`, return matrix, device pass.
4. Slice 3, only if the corpus shows the need: reverse prefix, edit distance,
   "Closest".
