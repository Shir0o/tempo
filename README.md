# Tempo

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An offline-first, private time tracker for Android, macOS, and Pixel Watch (Wear OS). Designed for frictionless 1-tap habit logging, native system glanceables without battery drain or notification blocking, live CSV export compatibility with BNPB, and private local AI analytics via Model Context Protocol (MCP).

## ✨ Key Features

- **Pixel Watch (Wear OS)**:
  - **Zero Tile Scrolling**: Direct Watch Face Complication (`[▶️ Track]` when idle, `[⏱️ 01:24]` when active) and a 3-Slot Smart Tile (Top Pinned Habit + 2 Contextual Recents).
  - **Action-and-Exit**: Tap activity $\to$ haptic pulse $\to$ immediate `activity.finish()`. Returns instantly to the watch face so incoming notifications and calls are never suppressed.
  - **Guarded Stop**: 600ms hold-to-stop with radial progress prevents accidental cancellation from clothing or gym bumps; 3-second floating Undo window on start.
  - **Zero-Poll Battery Optimization**: Anchor timestamp math (`startedAtEpochMs`) computes elapsed time locally; zero 1Hz Bluetooth polling between watch and phone.
- **Desktop (macOS)**:
  - Low-profile `NSStatusItem` menu bar status item (`[🟢 01:24 Coding]`).
  - Keyboard-first Quick Popover (`Option + Shift + T`, `1`-`9` number hotkeys).
  - Cross-platform `tempo://start?activity=...` deep link bus for Raycast and macOS Shortcuts.
- **Ecosystem & BNPB Interoperability**:
  - Continuous atomic Write-Flush-Rename CSV exports matching Simple Time Tracker schema (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`).
  - Preserves `"Contact"` tags and `w/` name markers for instant, automated staging in BNPB.
- **Private AI Analysis via MCP**:
  - Local stdio MCP server (`tempo-mcp`) connecting directly to SQLite on macOS with zero open ports and zero cloud relays.
  - Deterministic `PIISanitizer` (`--sanitize-pii`) redacting contact names before payloads reach LLMs.

## 🛠 Tech Stack

- **Mobile & Desktop**: Flutter (Dart) across Android and macOS.
- **Pixel Watch Companion**: Native Jetpack Compose for Wear OS, ProtoLayout Tiles 1.4, and Watch Face Complications.
- **Synchronization**: Google Play Services Wearable Data Layer (`DataClient` with `setUrgent()`) for phone $\leftrightarrow$ watch, and private Google Drive for desktop/mobile backups.
- **Database**: Local SQLite 3.35+ with monotonic UTC epoch arithmetic.

## 📖 Specifications & Wayfinder Map

- Product Specification: [`PRODUCT.md`](PRODUCT.md)
- Domain Glossary: [`CONTEXT.md`](CONTEXT.md)
- Wayfinder Map & Architectural Specs: [`.scratch/time-tracker/`](.scratch/time-tracker/map.md)
- Sequenced Implementation Backlog: [`.scratch/time-tracker/implementation/`](.scratch/time-tracker/implementation/)
