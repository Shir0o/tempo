# Critic Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md` (FeatureRange 1–450)
**Reviewers:** `egm-design`, `egm-structural`, `egm-style`
**Standard:** `feature-spec-standard.md` (design, structural)

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-design` | completed |
| `egm-structural` | completed |
| `egm-style` | completed |

## Blockers

### B1. App-pause teardown deletes the transcript during the speech hand-off
`egm-design`, `egm-structural`. Scope 162–167, 272–273, 284, 296; repo
`dashboard_view.dart:149–160`.

Launching `ACTION_RECOGNIZE_SPEECH` drives Tempo through `inactive` → `hidden` →
`paused`. The rule "closed and cleared on app pause" therefore fires during the
hand-off, clearing the field before `listen()` returns. CUJ 2 is unreachable,
and the planned widget test would enshrine the bug. Fix: suppress the pause rule
while a recognition is pending, define which lifecycle states count, and test a
paused state with a pending fake.

## Majors

### M1. Pending recognition can never resolve, and the plan names incompatible mechanisms
`egm-design`. Scope 265, 272–273, 538–554. The bridge stores one
`MethodChannel.Result` and clears state on destroy without resolving it, so the
Dart future never completes and the mic stays disabled for the session. The plan
names `ActivityResultLauncher`, `onActivityResult`, and a request code; these are
alternative wirings. Choose one (`ActivityPluginBinding` matches the repo's
`BackupDestinationChannel` precedent), call `super`, resolve null on destroy, and
add a Dart-side timeout.

### M2. The matcher cannot find a name inside a normal spoken phrase
`egm-design`. Scope 225–234, 62–65, 261. All tiers anchor to the name. "um,
cleaning the kitchen" or "let's log some cleaning" matches nothing because the
name is not the whole query or a prefix. Fillers are normal in recognition
output. Also `EXTRA_LANGUAGE` is pinned to the device locale while the catalog
language is unstated.

### M3. Reverse-prefix produces confident wrong first results
`egm-design`. Scope 228–229 vs 62–65, 75–77. "the query starts with the name" is
a strong prefix-tier match, so "workout was hard" ranks **Work** first and
"homework" ranks **Home**. No token boundary or remainder constraint. This is
the exact failure Goal 2 and Goal 6 forbid.

### M4. Goal 2 is unverifiable
`egm-design`, `egm-structural`, `egm-style`. Scope 62–65, 97–99, 571. No corpus
path, size, authoring procedure, provenance, ground-truth schema, or owner.
"Confident" and "plausible" are undefined. As written the headline gate cannot
pass or fail.

### M5. No Risks & Mitigations section
`egm-structural`, `egm-design`. Standard requires it; sibling specs
`decayed_markov_2_activity_suggestions.md:469–482` and
`multi-device-sync-and-recovery.md:349` carry one. Missing risks: third-party
audio egress, process death during recognition (no timeout), stale index behind
a swallowed `_loadData` catch (`dashboard_view.dart:264–266`), matcher false
positives, keyboard occlusion, corpus never authored, macOS surface change.

### M6. Privacy NFR understates the audio trust boundary
`egm-design`, `egm-structural`. Scope 396–401 vs 43–54, 103–106, 332–338. It
never says the recognizer app may be a network service, that audio may leave the
device under that app's policy, that the Play data-safety declaration is a
release gate, or that copy must not imply on-device recognition. Alternative C is
charged with the same property the chosen path has, which biases the comparison.

### M7. The filter ships to macOS while the spec says Android-only
`egm-design`, `egm-structural`. Scope 11–25, 90–91, 199–211; repo
`tempo_app.dart:123–132`, `main.dart:189–200`. `DashboardView` is shared, and the
spec forbids a `Platform.isAndroid` check inside it, so the typed filter appears
on the Mac. On the replica `_labelActivity` can return null ("waiting for the
phone"), so CUJ 1's "exactly one Record" is false there. State the platform
scope, or inject the filter capability.

### M8. "Resting screen unchanged" is contradicted, and screenshot/DESIGN.md work is missing
`egm-design`, `egm-structural`. Scope 72–74 vs 146–160, 584–595. The magnifier is
new heading chrome that changes geometry. `screenshots/color_blocks_dashboard*.png`
produced by `color_blocks_dashboard_screenshot_test.dart` will go stale, and
`DESIGN.md:150–230` describes this screen but is not in the change list.

### M9. Lifecycle rules contradict each other on the label path
`egm-design`, `egm-style`. Scope 283–288. Bullet 2 closes and clears on label;
bullet 3 keeps the query on label; bullet 3 also contradicts itself. Specify the
sequence: label → close → clear → reload; treat pull-to-refresh separately.

### M10. Any single character destroys the grid, and the list is uncapped
`egm-design`. Scope 158–161, 214–217, 403–406. Typing "a" replaces chips and grid
with most of the catalog. The matcher's `limit` is optional and the UI never sets
it. Define a minimum query length and a hard result cap with a "showing N of M"
line.

### M11. Scroll restoration and "field stays visible" have no mechanism
`egm-design`, `egm-structural`. The dashboard is one `CustomScrollView` with no
`ScrollController`; a focused field inside it scrolls away. State 3's claim that
field and context line stay visible is false unless a pinned header is added,
which changes the resting geometry. Choose in-scroll vs pinned, add the
controller, and define behaviour when the keyboard resizes the viewport.

### M12. Matcher determinism claims are wrong or underspecified
`egm-design`. Scope 232–238. Dart's `List.sort` is not guaranteed stable, so
"stable sort" invites losing determinism. The metric (Levenshtein vs
Damerau) is unnamed, so transpositions such as "cleaing" cost two edits and never
match. "Characters" is used where Dart exposes UTF-16 code units, shifting the
4/7/8 thresholds on emoji and combining marks.

### M13. The "never mutate the list under a finger" invariant was dropped
`egm-design`. Scope 280–287; brief 42–46. Matches recompute on catalog change, so
rows can reorder while a thumb descends. Freeze rendered order while a pointer is
down, and re-rank after the gesture ends. Test it.

### M14. Archived Activities are a dead end
`egm-design`. Scope 58–61, 75–77, 245–248; brief 53. Goal 1 says "any Activity";
archived ones are excluded, and the empty state offers only Clear. Either scope
the goal to unarchived, or offer "Manage Activities" in the empty state, which
reuses the existing manager.

### M15. Filter state is absorbed by an already-1,100-line `State`
`egm-structural`. Scope 196–211, 275–289. The visual row is extracted for file
size, but query, open flag, availability, pending, matches, invalidation, and
four-state rendering all land in `_DashboardViewState`, with no unit tests of
their own. Extract an `ActivityFilterController` (plain Dart) with an injected
`SpeechInput`, matching the pure-engine precedent.

### M16. Unbounded query input vs the microsecond claim
`egm-structural`. Scope 240–243 vs 403–406. The contract accepts "very long
input" and the test feeds 10k characters, while edit distance is quadratic per
candidate on the UI thread. Clip the normalized query to a fixed length and state
the cost model.

### M17. Public matcher API described three ways
`egm-structural`, `egm-comprehension`. `rankActivities` returning matches (178),
`ActivityIndex.search` (463), and a match with a "tie-break key" (217) vs without
(464). Align the contract with the plan and drop the leaked sort key.

### M18. "Grid order" is not a single order
`egm-comprehension`, `egm-structural`. `TodayOrder` supports categories, manual,
alphabetical, and pinned. The stated tie-break (`sortOrder`, normalized name, id)
matches only manual order, and `_activities` is DB order, not display order.
Either pass display order into the matcher or state that results have their own
order.

### M19. `tokenPrefix` is unreachable
`egm-comprehension`. A token prefix is always a substring, so with first-match-wins
no candidate receives that stage. The tier list is really four tiers, and the
test requirement for it has no input.

## Nits

* **N1.** Accessibility labels "Listening" and "Voice input unavailable" describe
  states that never render. Field hint and focus transfer are unspecified. The
  live-region announcement needs throttling. (`egm-design`, `egm-structural`)
* **N2.** Availability is cached for the session, so one transient error hides the
  mic until restart; and a resolvable intent does not guarantee recognition.
  Re-check on open and soften the claim. (`egm-design`)
* **N3.** Availability resolves asynchronously, so the mic pops in after the row
  renders. Pre-resolve or reserve the slot. (`egm-structural`)
* **N4.** The context line duplicates the existing "Tap to log …" subtitle.
  (`egm-comprehension`)
* **N5.** Minimum query length is inconsistent between CUJ 1 (three characters)
  and state 3 (any non-empty query). (`egm-comprehension`, `egm-structural`)
* **N6.** Normalization boundaries are undefined for punctuation and whitespace.
  (`egm-comprehension`)
* **N7.** Verification commands need `cd android` and an APK path.
  (`egm-comprehension`)
* **N8.** The new result row has no contract against `DESIGN.md` tokens; the
  uppercase category line has no scale. (`egm-design`)
* **N9.** "No active Activity matches" uses a non-domain word; the glossary uses
  archived/unarchived. (`egm-design`)
* **N10.** The macOS description in the plan is wrong: macOS returns early
  through `_startReplica` and constructs its own `TempoApp`. (`egm-design`)
* **N11.** "Files not changed" omits two dashboard tests that construct the
  widget. (`egm-design`)
* **N12.** Component map routes through `RecordCommands.label` instead of
  `_labelActivity`, hiding the replica's null path. (`egm-design`)
* **N13.** `ActivityIndex` invalidation key drifts between `catalogRevision` and
  `_activities`. (`egm-design`)
* **N14.** Empty query still needs a decided result cap and display limit.
  (`egm-comprehension`)
* **N15.** "Lap" and "Record" are not glossed at first use.
  (`egm-comprehension`)
* **N16.** Additional Resources and Future Improvements are H3 under NFR and sit
  before the implementation plan. (`egm-structural`)
* **N17.** Non-Goals says a settings key forces a migration; `settings` is a KV
  table already used by `TodayOrder` without migration. Give the real reason.
  (`egm-structural`)
* **N18.** NFR formatting is inconsistent with the rest of the document's H3
  subsection style. (`egm-structural`)
* **N19.** "rare action" asserts a frequency the document says is unknown.
  (`egm-style`)
* **N20.** "seeded catalog" is used for both five and forty Activities.
  (`egm-style`)
* **N21.** "Matching a few dozen names is microseconds" is unmeasured.
  (`egm-style`)
* **N22.** "This is the weakest part of the case" is review commentary left in the
  document. (`egm-style`)
* **N23.** "every Activity" overstates the candidate set, which excludes archived.
  (`egm-style`)
* **N24.** Metaphors and intensifiers: "load-bearing", "degrade honestly", "told
  the truth", "genuinely long", "mature surface", "out of proportion".
  (`egm-style`)
* **N25.** "Zero risk" is hyperbole in Alternative A. (`egm-style`)
* **N26.** "The product promises sub-second labeling" uses marketing register;
  PRODUCT.md states a target. (`egm-style`)
* **N27.** The resting-screen invariant is repeated four times, and "no microphone
  permission" six times. (`egm-style`)
* **N28.** "six-lens review" is internal jargon with no gloss. (`egm-style`)

## Verified claims (no finding)

Four chips, three-column category grid, no Today search, label/reload/undo path,
macOS pinned-only search with create-on-Enter, no `RECORD_AUDIO`, `CAMERA`
removal, existing `<queries>` block, `minSdk` 24, five seeded Activities,
`IndexedStack`, one-second ticker, `catalogRevision`, and the three-second undo
window all check out against the repo.
