# 09: macOS Keyboard-Navigable Quick Popover

Status: ready
Phase: 3 - Desktop macOS
Dependencies: 08

## Scope
Implement the floating desktop Quick Popover window triggered from the menu bar or global hotkey.

## Deliverables
- Global system hotkey registration (`Option + Shift + T`) via macOS Carbon/Cocoa APIs.
- Keyboard hierarchy:
  - `1`-`9`: Quick start pinned habit $N$.
  - `Space`: Pause/resume active timer.
  - `Cmd + Enter`: Stop active timer.
  - `/`: Focus search input.
  - `Escape`: Dismiss popover.
- Running session card with live elapsed ticker and inline comment editing.
