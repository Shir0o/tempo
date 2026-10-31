# 14: Android Broadcast Intents and Quick Settings Tile

Status: completed
Phase: 5 - Mobile & Sync
Dependencies: 02, 13

## Scope
Implement system-level automation hooks on Android.

## Deliverables
- `BroadcastReceiver` listening for `app.timetracker.action.START_TIMER`, `STOP_TIMER`, and `TOGGLE_TIMER` with extras for activity, comment, and tags.
- Android `TileService` for the Quick Settings notification pull-down shade showing current timer and 1-tap start.
- Deep link intent filter for `timetracker://` matching desktop behavior.
