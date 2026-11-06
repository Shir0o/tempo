# Voice-Assisted Activity Filtering on the Android Phone

* **Author:** twang
* **Date:** 2026-11-05
* **Review lenses:** design/architecture, codebase details, YAGNI, UX, migration/rollout, long-term maintainability (six independent reviewers, BRAINSTORM mode)
* **Status:** concept, not approved for implementation

## Overview

The Android Today screen has no search. Labeling is a horizontally scrolling row of up to **four** contextually ranked suggestion chips (`lib/ui/dashboard_view.dart` around line 783; the dashboard passes `limit: 4` around lines 240–255, while 6 is only the engine default in `lib/core/state/suggestion_engine.dart` line 109) followed by every Activity as a colour block in a three-column grid (`_buildActivityBlock`, around line 960). When the Activity you want is neither a chip nor on the first grid screen, you scroll.

The proposal was to add a text filter to that screen with a microphone button inside it, using the phone's speech service — "the same one Gboard's voice button uses" — so that saying "cleaning" ranks Cleaning for a single press.

The reviewers converged on a narrower shape: **the filter is the feature; the microphone is delegated to the platform.** Android has no public API that lets an app press the keyboard's own mic, and calling `SpeechRecognizer` would mean Tempo records the audio itself. The version that keeps an in-app button without that cost is `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`: the button launches the phone's speech-recognition screen, the recognizer app records the audio, and Tempo receives only the resulting text. Tempo declares no microphone permission, owns no audio stream, and still never labels without a press.

The strongest counter-argument to the whole concept also held up: there is no evidence in the repo that findability is actually failing. The seeded catalog is five Activities (`lib/main.dart` around lines 335–409), the grid is two to seven rows at realistic catalog sizes, and the product already ships pinning and manual ordering (`TodayOrder.pinned`, `activity_order.dart`). The watch made the same call deliberately, replacing tile searching with a fixed three-slot tile (`.scratch/time-tracker/issues/04-wear-os-ui-and-tile-spec.md` line 16). A recent-Activities row or better ordering may dissolve the problem with less surface than a filter.

## Analysis

### 1. The button is cheap; the engine choice decides the privacy story

Android gives an app three ways to get spoken words, and only one avoids a microphone permission:

- **Keyboard dictation** records inside the IME process. There is no public API to trigger it from an app; the user must press the keyboard's own mic key. Free, but it cannot be an in-app button.
- **`SpeechRecognizer`** records inside Tempo. It needs `RECORD_AUDIO`, shows the system microphone indicator, and on API 24–30 has no on-device option (`createOnDeviceSpeechRecognizer` is API 31+; `minSdk` is 24 at `android/app/build.gradle.kts` line 39). `EXTRA_PREFER_OFFLINE` is a hint, not a guarantee.
- **`RecognizerIntent.ACTION_RECOGNIZE_SPEECH`** launches the phone's recognition activity. The recognizer app records and returns text; Tempo needs no microphone permission and never touches the audio stream. This is the chosen path.

What it costs:

- The OS owns the screen while listening, so the calm in-field interaction is interrupted by the phone's own speech UI. That is familiar and visible, but it is not Tempo's design.
- The result is final-only. The recognizer app may show its own interim words, but the caller receives a completed transcript; Tempo does not re-rank on partials.
- Availability depends on a resolvable recognizer activity. Under Android 11+ package visibility, resolving `android.speech.action.RECOGNIZE_SPEECH` requires a `<queries>` entry; without it the button appears broken even when the phone can recognize speech. The manifest currently declares only `PROCESS_TEXT` (lines 90–95).
- Audio is handled by the recognizer app, which may be a network service. Tempo's listing does not claim otherwise, but the Play data-safety wording must be checked before release, and the control must not be described as on-device.
- The returned transcript is personal data even though Tempo did not record it.

Conclusion: the button is a thin platform hand-off, not an audio pipeline. It should check resolvability before rendering, launch with the device locale, take the top transcript into the field, and return the user to the result list without reopening the keyboard.

### 2. Re-ranking while a thumb is travelling can write a wrong Record

The chosen path returns one final transcript, which removes most of this risk. The invariant still matters if an inline recognizer ever replaces it. If interim transcripts re-sort the results, a row that is a tap-to-commit action (`_labelActivity`, around lines 269–281) moves under a finger already on its way down. The user labels the wrong Activity, and the three-second undo window is competing with the keyboard and their attention.

Mitigations that should become invariants:

- Rank on the **final** transcript only. Interim text may be shown as plain, non-editable text; it may not reorder the list.
- Never mutate the list while a pointer is down.
- Never auto-label, and never auto-create an Activity, from a transcript. The press is the commit.

### 3. The screen's layout is not built for a second input mode

- **The keyboard hides what you are labeling.** The lap panel ("Untracked", since 10:06, elapsed) and the heading ("Tap to log 10:06 → now") are the only statement of which interval a tap will close. A focused field in a `CustomScrollView` pushes both off-screen on a normal phone. The filter needs a compact, always-visible context line such as "Label 10:06 → now · 25m" while it is open.
- **A filtered three-column square grid looks broken.** One match leaves two-thirds of a row empty; section headings over single-item sections waste vertical space. Filtered results should be full-width rows with a colour swatch, name, total today, and category when present — not squares.
- **The field must not be permanent.** A permanent field costs about 64dp on every visit to serve a rare action. The cheaper placement is a magnifier on the "What was it?" heading that expands the field in place, focuses it, and collapses on clear/back. A bottom sheet is the alternative if one-handed reach matters more than tap count.
- **Archived Activities create a false "no match."** The dashboard loads unarchived Activities for the grid but keeps an all-Activities map for names. Decide the candidate set explicitly and show an archived hit as a non-tappable row with a route to Activities, rather than silently hiding it.
- **Duplicate names are legal.** `activities.name` has no `UNIQUE` constraint, so two "Cleaning" rows are possible. Result rows need the category line, and ranking needs a total order.

State rules the reviewers flagged:

- Use `IndexedStack` awareness (`lib/ui/tempo_app.dart` line 155): a filter left active when the user returns from Totals shows a subset as if it were the whole catalog. Clear the query on tab change, app pause, and successful label.
- The dashboard rebuilds every second (`_startLiveTicker`, around lines 174–183). Do not re-run the matcher on every tick; cache against query plus `catalogRevision`, and skip the ticker rebuild while the filter is open.
- Keep the query, controller, and focus node in `_DashboardViewState`, dispose them with the existing `dispose()`, and never persist a filter to `settings` — a new key means a schema migration for transient UI state.

### 4. Matching is cheap; ranking and honesty are the work

The matcher itself is small and pure. The risks are policy risks:

- **A miss is normal.** Speech output and user-authored names will not line up. The matcher must make misses look like misses: a low score should render as "No Activity matches 'clening'" with the query echoed and a Clear action, not a confident wrong first row.
- **No fuzzy tier below four characters.** Edit distance on short names produces "Run" → "Fun" → "Sun". One edit at 4–7 characters, two at 8+, and label fuzzy results "Closest" so the user knows the app is guessing.
- **Tie-break deterministically.** Match tier, then `sortOrder`, then normalized name, then id. Integer weights, no locale-aware collation, no unstable sort.
- **Accent folding is optional.** Dart has no Unicode normalization. Either ship a small fold table with test vectors (`Café/cafe`, `naïve/naive`, `Straße/strasse`) or declare that v1 does not fold and let edit distance absorb one character. Do not hand-roll a half-correct table.
- **The flagship example only works for near-exact names.** "cleaning" finds "Cleaning" and "Clean house"; it does not find "Housework" or "Chores". That is acceptable if stated, and it is the reason the field must also accept typing.

### 5. Structure: one pure matcher, reused, never committing

- Put the matcher in `lib/core/state/` as a pure function over a candidate list, in the style of `suggestion_engine.dart`: no `BuildContext`, no database, no clock, no locale.
- Return ranked matches with a stage enum (`exact`, `prefix`, `substring`, `tokenPrefix`, `editDistance`) so a future alias or semantic layer is a new stage, not a signature change.
- Do not filter `_activities` in place. It also feeds `_activitiesById`, `_todayActivityDurations`, and history labels. Filter as a render-time projection from an explicitly passed query.
- The desktop popover's search is a raw `contains` over **pinned** Activities only (`lib/desktop/ui/quick_popover_view.dart` around lines 941–948) and its Enter key **creates** an Activity (around lines 460–497). Do not inherit either behaviour on the phone. If the desktop adopts the shared matcher later, that is its own change with its own tests.
- Name things `speech_` or `voice_`. In this repo `STT` already means Simple Time Tracker (`lib/core/import/stt_*`), so "speech-to-text" must not reuse that prefix.
- Inject platform capability rather than branching on `Platform.isAndroid` inside the shared `DashboardView`, which also runs on macOS and in host-side widget tests.

### 6. Privacy and trust details that must be stated, not assumed

- The transcript is personal data. Keep it in widget state only: never in a Record comment, never exported, never logged, cleared on collapse, tab change, app pause, and label.
- With the system recognition activity, the recognizer app records and the OS shows the microphone indicator; Tempo receives only text. That keeps `RECORD_AUDIO` out of the manifest and keeps Tempo out of the audio path.
- If `SpeechRecognizer` ever replaces the system activity: on-device only (`createOnDeviceSpeechRecognizer`, API 31+, hidden when unavailable), no network fallback, one recognizer per tap, `cancel()` and `destroy()` on every terminal path, and a hard stop on app background.
- The product has no telemetry. The button's only local state is whether a recognizer activity resolved; if that check fails, the button is hidden rather than shown broken. No counters, no upload.

## Goals vs. Non-Goals

**In scope**

- A filter on the Android Today screen that narrows the Activity catalog by typed text.
- An in-app microphone button that launches `ACTION_RECOGNIZE_SPEECH`, captures the top transcript into the field, and returns the user to the result list.
- A pure, deterministic matcher in `lib/core/state/` with unit tests and a golden corpus of real names.
- Full-width result rows with category disambiguation, an always-visible "Label <start> → now" context line, and no list mutation under a finger.
- Restoring the exact prior chips, grid, and scroll offset on clear, back, label, tab change, and app pause.

**Out of scope for v1**

- `RECORD_AUDIO`, `SpeechRecognizer`, any speech plugin, and any app-owned audio stream.
- Interim-transcript ranking inside Tempo.
- Auto-labeling, auto-creating Activities, and create-on-Enter.
- Searching categories, tags, or Record comments.
- Watch or macOS changes. The desktop keeps its current search until a separate change.
- Network or cloud speech chosen by Tempo, embeddings, alias lists, and any semantic model.
- New telemetry, and any persisted filter state or schema migration.

## Alternatives Weighed

- **Do nothing and measure first.** Rejected as a deliverable because it does not answer the request, but retained as the honest baseline: the seeded catalog is five Activities, and no data shows scroll frequency. If a recent-Activities row or better pinning solves it, the filter should not ship.
- **Better ranking instead of a new surface.** A "Recent today" row of 8–10 one-tap chips, or surfacing pinning on the dashboard, would solve "not in the top four" with no field, keyboard, or permission. Cheaper than both alternatives below. Rejected only because the user wants a deliberate search path for long catalogs; it should still be considered Stage 0.
- **In-app `SpeechRecognizer`.** Rejected. It adds `RECORD_AUDIO`, a runtime permission, a permanent store-listing entry, an on-device API 31 floor against `minSdk` 24, and an OS availability state machine — to keep the recognition UI inside Tempo. Not worth it for a one-tap difference.
- **System recognition activity (`ACTION_RECOGNIZE_SPEECH`).** Chosen. The recognizer app records, so Tempo needs no microphone permission and owns no audio. The cost is an OS-owned listening screen, a final-only transcript, and a `<queries>` entry so the activity can be resolved on Android 11+.
- **Android App Shortcuts / the existing broadcast and deep link.** `app.tempo.action.START_TIMER` with an `activity` extra and `tempo://start?activity=` already label the open Lap from Tasker, NFC, or an Assistant routine (`TempoBroadcastReceiver.kt`, `lib/desktop/deep_link_service.dart`). This is a zero-code voice path with the three-second undo as the guard, but it labels directly rather than showing a list to press, so it does not match the requested interaction.
- **A shared matcher for Android and macOS now.** Rejected as speculative. The desktop's search is pinned-only and has a create-on-Enter contract that the phone must not inherit. Extract on the second real caller, in a change that also widens the desktop filter and re-baselines its tests.
- **Putting search in the History edit sheet first.** The edit sheet renders every Activity as a wrapped chip with no filter (`lib/ui/history_view.dart` around lines 650–668), which is the surface with the genuinely long list and no alternative path. Rejected as the first target only because the user's request is about labeling the open Lap; the matcher should be built so this surface can adopt it later.

## Key Decisions & Staging for Next Steps

1. **Stage 1 ships the typed filter plus the system-recognition button.** No `RECORD_AUDIO`, no speech plugin, no audio code in Tempo. The only manifest addition is a `<queries>` entry for `android.speech.action.RECOGNIZE_SPEECH`.
2. **Invariants:** a press is the only commit; no auto-label; no auto-create; no interim re-ranking; no list mutation under a finger; the empty-query grid is identical to today.
3. **Matcher:** pure function in `lib/core/state/activity_matcher.dart`; tiered exact → prefix → substring → token-prefix → bounded edit distance; integer weights; documented tie-break; golden corpus including one deliberate miss.
4. **Placement:** magnifier on the "What was it?" heading that expands a focused field, with a persistent "Label <start> → now" line while open. Result rows, not grid squares. The mic button sits inside the field.
5. **State:** query lives in the dashboard state and is cleared on label, tab change, and app pause; never persisted and never added to `settings`.
6. **Voice hand-off:** check that a recognizer activity resolves before rendering the button; hide it when none does. Launch with the device locale, take the top transcript, and leave the keyboard closed so the results are visible. A cancelled or failed recognition returns to the field unchanged.
7. **Open before implementation:** confirm the real catalog size on the user's phone, and decide whether a recent-Activities row should ship before the filter. Both are cheap and could remove the need for Stage 1 as specified.
