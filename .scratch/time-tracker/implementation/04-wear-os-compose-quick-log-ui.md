# 04: Wear OS Compose Quick-Log UI

Status: ready
Phase: 2 - Wear OS Companion
Dependencies: none

## Scope
Implement the native Jetpack Compose for Wear OS interactive application (`QuickLogActivity` and `ActiveSessionActivity`) with anti-friction protections.

## Deliverables
- Pinned habit quick-log sheet with high-contrast, centered touch targets ($\ge 52\text{dp}$).
- 3-second floating **Undo Grace Window** snackbar upon timer start.
- GuardedStop button requiring a continuous 600ms hold with radial progress and haptic rumble to stop timers.
- **Action-and-Exit** lifecycle: immediate `Activity.finish()` on logging actions to return to watch face and prevent notification suppression.
- Ambient mode low-power rendering via `AmbientLifecycleObserver`.
