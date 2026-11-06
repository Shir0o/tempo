# Comprehension Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md`
**Scopes:** FeatureRange 1–450, DetailedRange 451–618
**Reviewer:** `egm-comprehension`

## What this proposes

Adds a transient text filter, and on Android a button that hands off to the
phone's system speech-recognition activity, to Tempo's Today screen so the user
can jump to any Activity and label the open Lap with one press. The filter is
the feature: a pure, deterministic, local matcher with five ranked tiers,
archived exclusion, and an empty state. Voice is a convenience that never
touches audio or `RECORD_AUDIO`. The screen gains four states: closed, open with
an empty query, open with results replacing the chips and grid, and the OS
recognition screen. No persistence, schema, settings, export, sync, or telemetry
changes. Eleven files are named in the implementation plan.

## How the existing system works, per this document

Tempo keeps an always-running open Lap that the user labels after the fact;
labeling closes it into a Record and starts the next Lap. The Android Today
screen shows up to four contextually ranked suggestion chips and then a
three-column grid of the unarchived catalog grouped by category, with no search.
Writes go through `RecordCommands.label`, the dashboard reloads, and a
three-second undo bar offers reversal. The macOS popover filters pinned
Activities only and its Enter key creates an Activity. The Android manifest
declares no `RECORD_AUDIO`.

## Findings

**1. Blocker — app pause clears the filter during the speech hand-off.**
Lifecycle rules (284–287), state 4 (162–167), CUJ 2 (124–131), privacy NFR
(397–401). Launching the recognizer activity is itself an app pause, so the rule
clears the field before the transcript returns. The document never carves out an
exception.

**2. Major — `tokenPrefix` is a strict subset of `substring`.**
Matcher tiers (225–234), plan (466–474), tests (568–573). If a token starts with
the query, the query is already a substring of the name. With first-match-wins,
no candidate can ever receive the `tokenPrefix` stage. The enum value is dead and
the "five tiers" are four.

**3. Major — lifecycle bullets contradict each other on the label path.**
Bullet 2 says the filter is closed and cleared on label; bullet 3 says a label
keeps the query if the filter was open. An implementer reading the list alone has
two opposite rules for one event.

**4. Major — the edit-distance tier never says what is compared.**
Tier 5 (232–234), plan (470–472). Whole name vs query, or query vs each token?
Which metric: Levenshtein or transposition-aware? Code points, UTF-16 code units,
or graphemes? Goal 2's corpus cannot be authored against this.

**5. Major — "grid order" is not a single order.**
Component map (172), contract (215–237), plan (465–472, 510–512). The visible
order comes from `TodayOrder` (categories, manual, alphabetical, pinned), and
`getAllActivities` returns `sort_order, name`. There is no flat grid order to
pass in, and the stated tie-break matches only manual order.

**6. Major — "Closest" rows vs "no match" are undefined against each other.**
Goal 6 (74–77), CUJ 3 (133–140), tier 5 (232–243). Goal 6 says never show a
best-effort row as a match; tier 5 shows rows within one or two edits. The
document never defines the boundary between a plausible Closest row and a miss.

**7. Major — Goal 2's corpus has no authoring procedure.**
Goal 2 (62–65), test plan (570–573). No path, size, format, ground-truth schema,
or owner. "Real spoken phrases" conflicts with the no-telemetry posture unless
they are authored, not collected. The test plan refers to a corpus the document
never defines.

**8. Major — scroll restoration has no mechanism.**
Goal 5 (74), CUJs, plan (501–512). No `ScrollController` or `PageStorageKey`
exists on the dashboard, and the shrink-then-restore sequence is undescribed.

**9. Major — `ActivityResultLauncher` vs `onActivityResult`.**
Speech contract (265) describes a launcher; the plan (541–554) forwards
`onActivityResult`. These are alternative wiring strategies.

**10. Nit — matcher API named three ways.**
`rankActivities` returning `List<ActivityMatch>` (178–180), `ActivityIndex.search`
(463–467), and a match carrying "a stage and a tie-break key" (217) vs "the
Activity and its stage" (464).

**11. Nit — "confident wrong first result" is undefined.**
Goal 2 (64–65) introduces "confident" with no threshold, mechanism, or test
mapping.

**12. Nit — repo identifiers used without a gloss.**
`catalogRevision`, `sortOrder`, `RecordCommands.label`, `_loadData`,
`TodayOrder`, `IndexedStack`. `catalogRevision` is load-bearing and never
defined.

**13. Nit — the magnifier entry control is under-specified.**
No size, semantics label, or test key, unlike the field, mic, and rows. It also
tension with Goal 5's "resting screen unchanged".

**14. Nit — four states "with no others" vs a fifth pending condition.**
The mic is disabled while a call is pending, and the accessibility section
specifies a "Listening" label that cannot be observed because the OS screen
covers the app.

**15. Nit — normalization boundaries are undefined.**
Which characters count as punctuation, whether stripping happens before or after
whitespace collapse, and whether "boundary" means the whole string or each token.

**16. Nit — verification commands are not reproducible as written.**
`./gradlew :app/processDebugMainManifest` needs `cd android`; `aapt dump
permissions` needs an APK path.

**17. Nit — draft commentary remains in the document.**
"This is the weakest part of the case, and the design should say so" reads as a
review note, and "which the Goals below make testable" overstates Goal 1 because
a synthetic playtest cannot establish the size of the real catalog.

**18. Nit — result-list bounds are unstated.**
Optional matcher `limit`, no UI display cap, no scroll behaviour. Goal 3 says
"visible" while Goals 1–2 say "top three" and "without scrolling".

**19. Nit — domain nouns appear before definition.**
"Lap" and "Record" carry the flow and are only pointed at `CONTEXT.md` at the
end. One gloss at first use would make the document stand alone.

## Self-containment check

All linked paths resolve. Verified claims: four suggestion chips, three-column
grid grouped by category, no search on Today, the label → reload → undo path, the
macOS popover's pinned-only scope and create-on-Enter, no `RECORD_AUDIO`, and an
existing `<queries>` block. The gaps are internal coherence and undefined
mechanics, not broken links.
