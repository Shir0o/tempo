# Desktop macOS Menu Bar and OS Automation Spec

Type: prototype
Status: resolved
Blocked by: none

## Question

How does the macOS menu bar status item, keyboard shortcuts, and deep link / URL scheme (`timetracker://start?...`) behave, and how does the automation engine integrate with macOS Shortcuts, Raycast, and Android Intents/Tasker?

## Answer

The complete macOS menu bar and cross-platform automation engine is specified in [`.scratch/time-tracker/prototypes/05-desktop-macos-menu-bar-and-automation-spec.md`](../prototypes/05-desktop-macos-menu-bar-and-automation-spec.md).

### Resolved Decisions:
1. **macOS Status Item & Quick Popover**: Low-profile `NSStatusItem` displaying `[🟢 HH:MM Activity]` when active; left-click or global hotkey (`Option + Shift + T`) opens a keyboard-navigable Quick Popover with number keys `1`-`9` for 1-tap habit switching.
2. **DeepLinkBus (`timetracker://`)**: Cross-platform URL scheme (`timetracker://start?activity=...&comment=...`, `timetracker://stop`, `timetracker://pause`, `timetracker://resume`) allowing peer apps like `bnpb` and `workout-planner` to command timers programmatically without stealing desktop focus.
3. **OS Automation Integrations**: Native Raycast script commands and macOS Shortcuts app actions on desktop; Android Quick Settings tile and broadcast intents (`app.timetracker.action.START_TIMER`) on mobile for Tasker, NFC tags, and Bluetooth triggers.
