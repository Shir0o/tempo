# Wear OS UI, Tile, and Complication Spec

Type: prototype
Status: resolved
Blocked by: none

## Question

What are the exact layout specifications, interaction states, and glanceable visual representations for the Wear OS Tile (quick-start buttons), Watch Face Complication (active elapsed time / toggle icon), and the minimal 2-screen watch UI?

## Answer

The Wear OS UI, Tile, and Complication architecture is specified in [`.scratch/time-tracker/prototypes/04-wear-os-ui-and-tile-spec.md`](../prototypes/04-wear-os-ui-and-tile-spec.md).

### Resolved Decisions & Mitigations:
1. **Activity Discovery Friction**: Replaced horizontal tile searching with a direct **Watch Face Complication shortcut** (`[▶️ Track]` when idle, `[⏱️ 01:24]` when tracking) and a non-scrolling **3-Slot Smart Tile** (Top Pinned Habit + 2 Contextual Recents based on time of day).
2. **Accidental Touch Protection**: 
   - Starting an activity displays a 3-second floating **Undo Grace Window** (`Started Coding • [UNDO]`) to roll back accidental starts without cluttering records.
   - Stopping a session enforces a **GuardedStop (600ms hold-to-stop)** with radial progress and haptic rumble, rendering sleeve brushes and gym bumps harmless.
3. **Notification Suppression Elimination**: Quick-log actions execute an **Action-and-Exit** pattern: writing state, firing haptic confirmation, flashing an 800ms visual check, and immediately calling `Activity.finish()` to return to the watch face. The app never remains foregrounded, ensuring all incoming notifications peek and vibrate normally.
