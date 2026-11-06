# Phase 1 — Activity filter sheet (typed find)

## Summary

Add a modal Activity filter to the Android Today screen so a user with a long
catalog can jump to any unarchived Activity without scrolling the grid, then label
the open Lap with one press. This phase is typed-only: no microphone, no Android
code, no manifest change.

Design: `docs/designs/voice_assisted_activity_filtering.md` (Status: Proposed).
Decision Gate: 49 unarchived Activities recorded 2026-11-06, so the feature
proceeds.

## Scope

* Pure matcher with exact, prefix, substring, and name-token-in-query stages.
* `ActivityFilterController` (matches, availability, pending guard).
* `ActivityFilterSheet` modal route with focused field, ×, context line, result
  rows, 20-row cap, no-match state, and Manage Activities action.
* `ActivityResultRow` widget.
* Magnifier in the "What was it?" heading, gated by `showActivityFilter`.
* `SpeechInput` interface with a null implementation, so Phase 2 can drop in the
  channel without changing the sheet.
* Unit tests, widget tests, corpus fixture, 40-Activity catalog, STT seed CSV.

## Files

Create:
* `lib/core/state/activity_matcher.dart`
* `lib/core/state/activity_filter_controller.dart`
* `lib/core/speech/speech_input.dart` (interface + null implementation)
* `lib/ui/activity_filter_sheet.dart`
* `lib/ui/activity_result_row.dart`
* `test/core/activity_matcher_test.dart`
* `test/core/activity_filter_controller_test.dart`
* `test/fixtures/activity_match_corpus.json`
* `test/fixtures/activity_catalog_40.json`
* `test/fixtures/seed_40_activities.csv`
* `test/ui/activity_filter_test.dart`

Modify:
* `lib/ui/dashboard_view.dart`
* `lib/ui/tempo_app.dart`
* `lib/main.dart`
* `DESIGN.md`
* `test/ui/color_blocks_dashboard_screenshot_test.dart`
* `screenshots/color_blocks_dashboard*.png`

## Acceptance criteria

* With `showActivityFilter: false`, the Today screen renders exactly as today.
* The magnifier opens a sheet with the field focused and the context line
  "Label HH:MM → now · duration" visible.
* Typing filters to the expected row; focus stays in the field while typing.
* Pressing a row creates exactly one Record, closes the sheet, and restores the
  same Today screen and scroll position.
* The × clears the query and keeps the sheet open; back and drag-down dismiss it.
* No result is preselected and no Activity is created by typing or submitting.
* An empty or punctuation-only query returns `matches: []` without an error.
* Archived Activities never appear as rows; the empty state offers Clear and
  Manage Activities.
* The 40-entry corpus reaches top-three ≥ 90% over positive entries with zero
  `mustNotBeFirst` violations.
* The 20-row cap shows "showing N of M" using the untruncated total.
* A 10k-character query and arbitrary Unicode never throw.

## Verification

* `dart analyze`
* `flutter test test/core/activity_matcher_test.dart`
* `flutter test test/core/activity_filter_controller_test.dart`
* `flutter test test/ui/activity_filter_test.dart`
* `TEMPO_SCREENSHOT=1 flutter test test/ui/color_blocks_dashboard_screenshot_test.dart --update-goldens`

Full suite runs in GitHub Actions, not locally.

## Out of scope

* `ACTION_RECOGNIZE_SPEECH`, `RECORD_AUDIO`, the Kotlin bridge, and the manifest
  `<queries>` entry (Phase 2).
* Damerau-Levenshtein, "Closest", and reverse matching (Phase 3).
* macOS, the watch, History search, CSV, MCP, and sync.
* Any schema or settings change.

## Risks

* The sheet hides the lap panel. The mandatory context line is the mitigation; a
  playtest failing that line blocks the phase.
* Matcher false positives. No row is preselected; fuzzy matching is not in this
  phase.
* The fixture catalog and the real 49-Activity catalog differ. The corpus is a
  conservative stand-in; the playtest uses the seed CSV.
