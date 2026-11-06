# Re-Review Delta — Voice-Assisted Activity Filtering v2

**Target:** `docs/designs/voice_assisted_activity_filtering.md` (825 → 910 lines)
**Reviewed:** 2026-11-06
**Mode:** Delta re-review after the modal-sheet rewrite
**Reviewers:** zoom-out, design, structural, style, implementation-readiness,
codebase-details, style (implementation range)

## Verdict

The four original blockers and most majors are fixed. The modal sheet removed the
scroll, back, tab, and keyboard machinery as intended, and the Android seam now
matches `BackupDestinationChannel`. The delta review found no blocker in the
feature shape, but it found eight inconsistencies introduced by the rewrite:
sheet data contract, close-versus-failure ordering, controller ownership, focus
transfer, a non-existent radius token and wrong zero-duration claim, `N of M`
without a total, phases that contradicted the file specs, and verification
commands that could not run.

All eight are now fixed. Residual nits (repetition, editorial register,
terminology drift, and a few unverified accessibility behaviours) are accepted.

## Fixed in this pass

* Sheet takes a `FilterSheetData` (lap label, durations, category names),
  `onPick`, and `onManageActivities`; matcher returns `ActivityRanking` with an
  untruncated `total` for "showing N of M".
* Close-then-label is the single sequence; the failed-label-keeps-sheet row is
  deleted, matching the existing `history_view` convention and `_labelActivity`'s
  SnackBar.
* One owner: the dashboard creates and disposes `ActivityFilterController` around
  the route; the sheet owns the text controller and focus node; `_loadData`
  pushes catalog changes; the sheet pops on pause; the dashboard pops on an
  external label.
* Focus stays in the field while typing; it moves only after a voice transcript
  or an explicit navigation action.
* Matcher comparator is defined in the matcher (the claimed extracted comparator
  did not exist); normalization order and the `RegExp(unicode: true)` flag are
  stated once; the clip no longer skips the distance tier.
* Row uses `TempoRadii.row` plus a radius-5 swatch and "—" for zero; the
  non-existent `TempoRadii.swatch` and the false "0m" claim are gone.
* Phase 1 implements four strong tiers; distance and "Closest" move to Phase 3;
  Phase 1 includes the `SpeechInput` interface with a null implementation so the
  sheet compiles before Android work.
* `TempoApp` parameters have defaults, so `widget_test.dart` compiles; `main`
  gates the capability on `!kIsWeb && Platform.isAndroid`.
* Corpus schema allows null `expectedActivityId` for negatives, excludes them from
  the denominator, and adds a 40-Activity catalog fixture plus an STT seed CSV.
* Verification uses root-level `flutter build apk --debug`, `aapt2` from
  `$ANDROID_HOME` for permissions and the `<queries>` xmltree, a seeded playtest,
  and an AOSP/no-recognizer device for the negative case.
* Screenshot test is now a target file and passes `showActivityFilter: true`, so
  the golden actually captures the magnifier.
* Recreation now says the sheet is gone and nothing is labeled, instead of
  claiming the field survives.
* Archived filtering consumes `_activitiesById.values`, so the matcher's filter
  runs in production.

## Accepted residual nits

* Repetition: the 49-Activity fact, the resting-screen invariant, and the
  privacy rule each appear more than once.
* Editorial register: a few slogans remain ("the filter carries the feature",
  "the typed path is the private path").
* Terminology: "stage" and "tier" name the same thing.
* Accessibility behaviours (focus return, throttled live region) are specified
  but only partly asserted in the widget tests.
* The Activity Manager return path is described in one sentence, not a test.

## Status

Design is `Proposed`. Decision Gate recorded: 49 unarchived Activities,
2026-11-06. Phase 1 issue drafted at
`.scratch/time-tracker/reviews/voice_input/phase1_issue.md`.
