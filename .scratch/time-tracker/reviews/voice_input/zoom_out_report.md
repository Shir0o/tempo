# Zoom Out Report — Voice-Assisted Activity Filtering

**Target:** `docs/designs/voice_assisted_activity_filtering.md` (lines 1–618)
**Stage:** 5 (Initial Zoom Out)
**Reviewer:** `egm-zoom-out`

## Verdict

The document passes the context-sufficiency gate. A fresh reader can tell what is
being built, why, and what is out of scope. The problem statement is honest, the
alternatives are real, and the pure matcher boundary follows the existing
`suggestion_engine.dart` precedent.

It does not pass cleanly on simplicity. One internal contradiction breaks the
voice journey, one goal promises a mechanism the plan never adds, two pieces of
state are justified by an unmeasured cost, and the privacy section omits where
the utterance goes.

## Blockers

### 1. "Clear on app pause" destroys the speech hand-off it depends on
Affected: state 4 (162–167), lifecycle rules (284), privacy NFR (397–401),
speech contract (265–273).

Launching `ACTION_RECOGNIZE_SPEECH` puts Tempo into `inactive` → `hidden` →
`paused`, which is exactly what `didChangeAppLifecycleState` observes. Implemented
literally, tapping the mic closes and clears the filter, so the transcript has
nowhere to land. CUJ 2 fails. The pending-listen guard only disables the button,
it does not suppress the pause rule.

Fix: state that app pause does not close the filter while a recognition is
pending, and define which lifecycle states count.

## Majors

### 2. The premise is testable today, for free, and the design does not test it first
A 40-Activity seed plus ten named labels in the Activities screen answers Open
Question 1 with no code. Alternative A should be "run this experiment" rather
than "rejected because it does not answer the request".

### 3. The privacy section omits that the utterance leaves Tempo
`ACTION_RECOGNIZE_SPEECH` hands the spoken Activity name to a third-party app
that may be a network service. The brief required this to be stated and required
that the control never be described as on-device. The design drops both.

### 4. Goal 5 promises scroll restoration, but nothing can restore it
`dashboard_view.dart` has no `ScrollController` (confirmed around line 380).
Replacing the grid with a shorter list clamps the position. Either add the
controller and describe the capture/reapply sequence, or drop "exact" from the
goal.

### 5. "First back press closes the filter" has no home
`DashboardView` is a child of an `IndexedStack`, not a route. There is no
`PopScope` or `BackButtonListener` anywhere in `lib/`. The interception needs an
owner, and with the IME up the first back dismisses the keyboard anyway.

### 6. `ValueNotifier<int>` for the tab index is heavier than the problem
`TempoApp` already rebuilds the shell on tab change, so a plain `final int
tabIndex` plus `didUpdateWidget` closes the filter. A notifier adds a listener,
a dispose, and a rewrite of the navigation callbacks for no rebuild benefit.

### 7. `ActivityIndex` is a premature cache with a second source of truth
A pure `rankActivities(List<Activity>, String)` called on query change is
microseconds at 40 names. The index adds a rebuild lifecycle, a "do not recompute
on the ticker" invariant, and drift over whether invalidation follows
`catalogRevision` or `_activities`.

### 8. A third Activity row is created while two near-identical rows exist
`history_view.dart` `_pickActivity` and `quick_popover_view.dart`
`_buildActivityRow` are both full-width swatch/name/tap rows. The stated reason
for a new widget is file size, not reuse. Either align it with those rows or
extract a shared row with optional slots.

## Nits

9. Query text is stored twice (controller and separate string).
10. "A label keeps the query" contradicts "the filter closes on the label path".
11. "Listening" and "Voice input unavailable" semantics labels are unreachable.
12. "Same geometry as today" contradicts the new heading button.
13. The context line duplicates the existing heading subtitle.
14. A single character replaces the whole grid; no minimum query length.
15. "Grid order" tie-break does not match `TodayOrder` (alphabetical, pinned,
    categories, manual).
16. `ActivityResultLauncher` and `onActivityResult` are two mechanisms, not a pair.
17. "The macOS branch passes null" is wrong: macOS returns early through
    `_startReplica` and constructs its own `TempoApp`; the phone's `main()` has no
    macOS branch.
18. The "not changed" list names one dashboard test; two others also construct
    `DashboardView`.
19. Contract drift: "tie-break key" vs "Activity and its stage"; "scoring uses
    integers" when ordering is tier plus comparator; component map routes through
    `RecordCommands.label` instead of `_labelActivity`.

## What would make it pass

1. Resolve the pause-versus-hand-off contradiction.
2. Run and record the zero-code premise experiment, and split delivery into
   filter first, speech second.
3. Add the audio trust boundary to the privacy NFR.
4. Fix or drop scroll restoration, and place back-press interception correctly.
5. Delete `ActivityIndex`, keep one query source of truth, pass the tab index as
   a plain value.
