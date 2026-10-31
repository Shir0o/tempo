# Desktop macOS Menu Bar & OS Automation Prototype Specification

## 1. Executive Summary & Design Goals

This specification details the desktop macOS menu bar status item, keyboard-driven quick capture, custom URL scheme (`timetracker://`), and cross-platform automation hooks (Raycast, macOS Shortcuts, Android Intents/Tasker).

### Key Architectural Tenets:
1. **Low-Profile Desktop Footprint**: Runs persistently as an `NSStatusItem` in the macOS menu bar; tracking never requires keeping a heavy window open.
2. **Keyboard-First Frictionless Capture**: Global hotkey (`Option + Shift + T`) brings up a keyboard-navigable Quick Popover; number keys `1`-`9` start pinned activities in $<1$ second.
3. **Universal Deep Link Bus**: A unified `timetracker://` scheme that works identically on macOS and Android, enabling peer apps (`bnpb`, `workout-planner`) and automation engines (Raycast, Shortcuts, Tasker) to command timers programmatically.

---

## 2. macOS Menu Bar Interface

### 2.1 Menu Bar Status Item (`NSStatusItem`)
- **Idle State**: Minimal monochrome template icon `[⏱️]`.
- **Active Tracking State**: 
  - Dynamic format: `[🟢 01:24 Coding]`
  - Configurable display preferences in Settings:
    - *Full*: `[Color Dot] [HH:MM] [Activity Name]` (Default)
    - *Compact*: `[Color Dot] [HH:MM]`
    - *Minimal*: `[Color Dot]` (Icon only with pulsing green indicator)
- **Menu Bar Click**:
  - **Left-Click**: Spawns the **Quick Popover** directly beneath the status item.
  - **Right-Click / Long-Press**: Displays context menu (`Pause`, `Stop`, `Preferences...`, `Quit`).

### 2.2 Quick Popover Wireframe & Keymap
```
┌──────────────────────────────────────────────────┐
│  🟢 CODING (01:24:15)                 [⏸️ Pause] │  <-- Active Timer Banner
│  Notes: w/ Alice - PR Review                      │  <-- Inline editable comment
│  [ ⏹️ Stop (Cmd+Enter) ]                          │
├──────────────────────────────────────────────────┤
│  🔍 Search or create activity... (/)             │  <-- Auto-focused search input
├──────────────────────────────────────────────────┤
│  PINNED HABITS                                   │
│  [1] 💻 Coding                     [ 12h 40m/wk ]│  <-- Number hotkey starts habit
│  [2] 🏋️ Workout                    [  4h 15m/wk ]│
│  [3] 📖 Reading                    [  6h 00m/wk ]│
│  [4] 🧹 Chores                     [  2h 30m/wk ]│
├──────────────────────────────────────────────────┤
│  RECENT ACTIVITIES                               │
│  • Bible Read                                    │
│  • Meeting                                       │
├──────────────────────────────────────────────────┤
│  [⌘O] Open Full Window      [⌘,] Settings   [⌘Q] │
└──────────────────────────────────────────────────┘
```

### 2.3 Keyboard Navigation Hierarchy
- `Option + Shift + T` (Global): Toggles the Quick Popover from any application.
- `1` through `9`: Instantly switches/starts Pinned Activity $N$ and dismisses popover.
- `Space`: Toggles Pause/Resume on currently active timer.
- `Cmd + Enter`: Stops active timer, commits record, and dismisses popover.
- `/`: Focuses the search input to filter long activity lists.
- `Escape`: Closes popover without affecting tracking.

---

## 3. Universal Deep Link & Automation Engine (`timetracker://`)

### 3.1 URL Scheme Specification
Both macOS and Android register the `timetracker://` protocol.

| Endpoint | Parameters | Action | Example |
| :--- | :--- | :--- | :--- |
| `timetracker://start` | `activity` (name or UUID)<br>`comment` (optional)<br>`tags` (comma-separated)<br>`foreground` (bool, default false) | Starts or atomically switches to activity. Creates activity if not existing. | `timetracker://start?activity=Workout&comment=Chest%20Day&tags=Fitness` |
| `timetracker://stop` | `comment` (optional, appends/updates comment before closing) | Stops currently active timer, commits record to SQLite, and triggers live CSV export. | `timetracker://stop?comment=Finished%20sets` |
| `timetracker://pause` | None | Pauses the running timer if active. | `timetracker://pause` |
| `timetracker://resume`| None | Resumes paused timer. | `timetracker://resume` |
| `timetracker://toggle`| `activity` (optional) | If idle, starts activity; if active with same activity, stops it. | `timetracker://toggle?activity=Coding` |

### 3.2 BNPB & Peer App Trigger Patterns
- **Direct Start from BNPB**: When opening a contact interaction in `bnpb`, BNPB can trigger:
  ```
  timetracker://start?activity=Meeting&comment=w/%20John%20Doe&tags=Contact
  ```
- **Direct Start from Workout Planner**: When starting Workout Block A:
  ```
  timetracker://start?activity=Workout&comment=Upper%20Body%20Hypertrophy&tags=Gym
  ```

---

## 4. Platform Automation Integrations

### 4.1 macOS Shortcuts & Raycast Script Command
```bash
#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Start Time Tracker
# @raycast.mode silent
# @raycast.argument1 { "type": "text", "placeholder": "Activity Name" }
# @raycast.argument2 { "type": "text", "placeholder": "Comment (optional)", "optional": true }

ACTIVITY=$(echo "$1" | sed 's/ /%20/g')
COMMENT=$(echo "$2" | sed 's/ /%20/g')

open "timetracker://start?activity=$ACTIVITY&comment=$COMMENT"
```

### 4.2 Android Intents & Tasker / Quick Settings Tile
- **Intent Filter Actions**:
  - `app.timetracker.action.START_TIMER`
    - Extras: `EXTRA_ACTIVITY_NAME` (String), `EXTRA_COMMENT` (String), `EXTRA_TAGS` (StringArray)
  - `app.timetracker.action.STOP_TIMER`
  - `app.timetracker.action.TOGGLE_TIMER`
- **Quick Settings Tile (`TileService`)**:
  - Shows current active activity name and elapsed time in the Android quick settings shade.
  - 1-tap toggles timer; long-press opens app.
- **Hardware & Environment Triggers**:
  - Tasker connects to car Bluetooth $\to$ sends `app.timetracker.action.START_TIMER` with `activity="Driving"`.
  - Disconnects $\to$ sends `STOP_TIMER`.

---

## 5. Verification & Acceptance Criteria
1. **Menu Bar Responsiveness**: Clicking the status item renders the Quick Popover in $<100$ms with zero UI jank.
2. **Deep Link Latency**: Invocations of `timetracker://start` execute and update the SQLite `active_timer` row within $<50$ms without forcing a full window to steal user focus when `foreground=false`.
3. **Live CSV Synchronization**: Stopping via deep link or hotkey immediately triggers the debounced atomic CSV write, making the record available to `bnpb` within 1 second.
