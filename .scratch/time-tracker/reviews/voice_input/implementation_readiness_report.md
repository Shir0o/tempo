# Implementation Readiness Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md`, DetailedRange 451–618
**Stage:** 9 (Implementation Readiness Test)
**Reviewers:** `egm-implementation-readiness`, `egm-codebase-details`, `egm-style`
**Standard:** `implementation-readiness-standard.md`

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `egm-implementation-readiness` | completed |
| `egm-codebase-details` | completed |
| `egm-style` | completed |

## Blockers

### B1. Closing on "app pause" destroys the state the speech hand-off depends on
`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`.
Item 4 (509–511) plus context 162–167, 284; repo `dashboard_view.dart:149–158`.

Launching the recognizer activity pauses Tempo, so the rule clears the field
before `listen()` returns. CUJ 2 is unreachable, and item 11 would encode the bug
in a test. Specify: close on `paused`/`hidden` only when no listen is pending;
name the states that count (`inactive` also fires for the notification shade);
add a paused-with-pending test and a paused-without-pending test.

### B2. The Android result plumbing is three incompatible designs
`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`.
Context 265; items 7 and 8 (538–554).

Three mechanisms appear: an `ActivityResultLauncher` (which `FlutterActivity`
cannot use without `FlutterFragmentActivity`), an `onActivityResult` override,
and a request code. `BackupDestinationChannel` is the repo precedent:
`FlutterPlugin, ActivityAware` plus `ActivityPluginBinding.addActivityResultListener`,
registered with `flutterEngine.plugins.add(...)`. Following item 8 risks breaking
the backup folder picker if `super.onActivityResult` is missed. Also delete
"distinct from the notification permission code": permission results arrive at
`onRequestPermissionsResult`.

### B3. A pending `MethodChannel.Result` is abandoned
`egm-implementation-readiness`, `egm-codebase-details`, `egm-style`.
Item 7 (540–545), item 4 (504), line 273.

"Clear pending state on activity destroy" drops the stored result, so the Dart
future never completes and the pending guard disables the mic for the session.
`BackupDestinationChannel.detach()` resolves the in-flight result with an error
before clearing; do the same (`SPEECH_DETACHED` or null). A second `listen` needs
a named error code. The Dart side cannot cancel a future, so "clears its pending
callback on dispose" is not implementable; use `if (!mounted) return`. Add a
Dart-side timeout or justify its absence.

## Majors

### M1. No phases or checkpoints
The plan is one flat batch of eleven files. The standard requires buildable,
testable phases. Add: (1) matcher plus tests; (2) result row and `SpeechInput`
seam; (3) dashboard filter plus widget tests; (4) Android bridge and manifest;
(5) verification. State that phase 4 is the only one touching `android/`, and
that reverting phases 3–4 leaves the typed filter intact.

### M2. Scroll restoration has no controller
`DashboardView` has no `ScrollController`. Item 4's "controller" is the
`TextEditingController`. Name `_gridScroll`, capture `offset` on open, re-apply
after the closed-state frame with clamping, and dispose it. Add a round-trip
assertion.

### M3. The tab notifier omits rebuild, listeners, and disposal
`_currentTabIndex` is assigned inside `setState` in three places and read by
`IndexedStack` and `NavigationBar`. A notifier does not rebuild them by itself.
Say whether `setState` remains or a `ValueListenableBuilder` replaces it; create
and dispose the notifier; add and remove the dashboard listener in `initState`
and `dispose`, as `catalogRevision` and `todayOrder` already do.

### M4. Recompute rule contradicts catalog reloads and produces stale rows
Item 4 says rebuild the index when `_activities` is replaced but recompute matches
only when the query changes. `_loadData()` replaces `_activities` after every
label, undo, refresh, and catalog bump, so an open query can show renamed,
archived, or deleted Activities. State one rule: recompute when the query changes
or the index is rebuilt. Say the ticker triggers neither.

### M5. Matcher contract is underdetermined
Four unresolved choices: public API (`rankActivities` vs `ActivityIndex.search`),
metric (Levenshtein vs Damerau), unit (`characters` vs UTF-16 code units or
runes), and `limit` (no default; non-nullable optional parameter does not
compile). Pick one signature, name the metric and unit, and state the default and
ordering semantics.

### M6. `tokenPrefix` is unreachable
A token prefix is always a substring, so first-match-wins never assigns the
stage. The enum value and its test are dead. Delete it, or redefine substring and
token-prefix as disjoint with a concrete input that reaches each.

### M7. Archived exclusion cannot be tested as specified
The index is "built from the unarchived list", so it never sees archived items,
yet item 10 requires an archived-exclusion test. Either accept the full catalog
and filter internally (the `suggestion_engine.dart` precedent) or document
"caller supplies active Activities" and remove the test.

### M8. Edit-distance bands and fuzz test are ambiguous
"When the query and name fall in different bands, which length governs?" is
unanswered, as is the metric. Item 10 conflates query and name thresholds into
"3/4/7/8". The fuzz loop has no seed, iteration count, generator, or definition
of "stable order". Specify `(queryLength, nameLength)` boundary pairs,
`Random(0)` with N iterations, and the exact stability property.

### M9. The golden corpus does not exist and has no schema
No fixture path, record shape, size, provenance, or assertion. Goal 2's 90% and
"no confident wrong result" cannot be evaluated. Add
`test/fixtures/activity_match_corpus.json` with `{phrase, expectedActivityId,
mustNotBeFirst}`, a stated size, and the seeded names it assumes.

### M10. The 40-Activity playtest has no seeding mechanism
The app seeds five Activities and there is no debug seeder. Name one: a
`--dart-define` branch in `_seedDefaultActivitiesIfEmpty`, a documented SQL
insert set, or the existing STT import with `catalogOnly`. Make it repeatable and
state whether the catalog includes categories, duplicates, and a diacritic name.

### M11. Platform scope is never decided
`DashboardView` is shared with macOS, and only `SpeechInput` is nulled. The typed
filter therefore ships to the Mac, where `_labelActivity` goes through
`RemoteRecordCommands`, returns null, and shows "waiting for the phone",
contradicting CUJ 1. State one sentence: the filter ships on both and CUJ 1 is
phone-only, or render the magnifier only when `speechInput != null`. Add the
replica test case.

### M12. Keyboard behaviour on speech return is unspecified
The field is focused when the mic is tapped; Android restores the IME on resume,
covering the result list and the context line the plan asks the playtest to
check. Unfocus before launching and after writing the transcript, then assert
`tester.testTextInput.isVisible == false`.

### M13. Kotlin step omits extras, empty-result handling, and transcript logging
Name `EXTRA_LANGUAGE_MODEL`, `EXTRA_LANGUAGE`, `EXTRA_MAX_RESULTS`, and the
absence of `EXTRA_PARTIAL_RESULTS`. Require
`getStringArrayListExtra(...)?.firstOrNull()` and `MATCH_DEFAULT_ONLY`. Add:
never log the transcript, the query, or `EXTRA_RESULTS`; log only the method and
an error code. `MainActivity` already logs user-derived values, so the risk is
real.

### M14. Verification cannot be run as written
`dart analyze` excludes `android/**`. Add
`cd android && ./gradlew :app:compileDebugKotlin` (or `flutter build apk
--debug`). `processDebugMainManifest` needs the merged-manifest path to inspect;
`aapt dump permissions` needs a built APK. `gradlew` is gitignored and generated
by Flutter. Name one command, one working directory, one artifact.

### M15. Test plan cannot express several claimed behaviours
Simulating pause needs `tester.binding.handleAppLifecycleStateChanged`. Back needs
a `PopScope` mechanism and `handlePopRoute`. The magnifier has no key. No test
asserts the transcript is not written to a comment, the mic is disabled while
pending, or the channel wrapper's error mapping. State which behaviours are
manual-only; the Kotlin bridge has no unit tests at all.

### M16. The clear control is undefined
State 2 lists no clear affordance, yet item 4 closes on "clear" and item 11 tests
it. CUJ 3 places Clear only in the no-match state. Define position, icon,
semantics, key, and whether clear empties the query and stays open or closes.

### M17. Availability has three owners and an undefined first frame
Item 2 says the wrapper has no state; the contract says session cache; item 4
puts the cache in the widget. `isAvailable()` is async, so the first frame is
undefined. Put the cache in one place, state what renders while it resolves, and
ignore a result after dispose.

### M18. Result row and magnifier are under-specified
Magnifier: no placement, size, key, semantics label, or visibility per state. Row:
"a flag for Closest" does nothing; duration has no formatter (two exist); no
long-press; zero duration undefined. Name the design tokens and update
`DESIGN.md`.

## Nits

* `search(String query, {int limit})` does not compile; give a default.
* `main.dart` "macOS branch" is wrong: macOS returns early via `_startReplica`;
  declare a nullable local before the platform block and pass it to the single
  Android `runApp`.
* `./gradlew` does not exist on a fresh clone; use Flutter's build command.
* "compact context line" duplicates the heading subtitle; say whether it replaces
  it.
* "reusing the existing lap label" names no widget; it is new text with a reused
  elapsed value.
* "strip boundary punctuation" has no character set.
* 48dp is Android idiom; the codebase uses logical pixels.
* State list omits the query string that the architecture lists.
* Request code has no value; recognizer action is written two ways.
* `resolveActivity` needs `MATCH_DEFAULT_ONLY` and a false path.
* In-memory test pattern omits `sqfliteFfiInit()` and
  `databaseFactoryFfiNoIsolate`.
* Item 5 omits the parameter name `speechInput`.
* Two meta-sentences carry no instruction; per-file "why" is claimed but absent.
* "so the undo bar is not competing with the keyboard" should state the literal
  claim: the keyboard would cover it.

## Verified against the repo (no finding)

Named paths exist; `lib/speech/` correctly marked Create. `TempoApp` and
`DashboardView` seams are as described: `_currentTabIndex`,
`_labelActivity`, `_activities`, ticker, `dispose`, `didChangeAppLifecycleState`,
four-chip row, three-column grid. The manifest has an existing `<queries>` block
and no `RECORD_AUDIO`. `pubspec.yaml` needs no change. `BackupDestinationChannel`
is the ActivityAware precedent. The in-memory database and channel-mock test
idioms exist. No telemetry is added, apart from the missing transcript-logging
rule.
