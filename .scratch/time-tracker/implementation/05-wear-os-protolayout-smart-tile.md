# 05: Wear OS ProtoLayout Smart Tile

Status: ready
Phase: 2 - Wear OS Companion
Dependencies: 04

## Scope
Implement the Wear OS smart tile using `androidx.wear.tiles` and ProtoLayout 1.4.

## Deliverables
- Fixed 3-slot non-scrolling round layout:
  - Top: Active timer status or "Quick Start" label.
  - Slot 1: Primary pinned habit button.
  - Slot 2 & 3: Contextual recent activities.
  - Slot 4: "More..." action pill launching `QuickLogActivity`.
- Dynamic ProtoLayout expressions (`DynamicInstant` / `DynamicDuration`) rendering live elapsed time in system compositor with 0 app wakeups.
