# Tempo

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A private, offline-first record of the whole day — every day, from local midnight to local midnight — for Android, macOS, and Pixel Watch (Wear OS). An open **Lap** always runs, and you label what it was after the fact. Labeling closes the Lap as a **Record** and opens the next one in the same instant, so every moment of the day belongs to exactly one Record or the open Lap.

Tempo describes how a day was spent, without judging it.

## 📖 The Recording Model

- **An open Lap always runs.** It starts where the last Record ended and continues from its persisted start across reboots and battery changes.
- **Label after the fact.** Tapping an Activity closes the Lap as a Record and opens a new Lap atomically — no gaps, no overlaps.
- **Split when you are not sure.** A Split marks a boundary now and leaves an Untracked Record you can label later.
- **Undo costs nothing.** Every label or Split has a 3-second UndoGraceWindow that restores the Lap exactly as it was.
- **Correct the past by moving Boundaries.** Drag the edge between two Records, split or merge neighbours, or relabel any Record. Edits that would create a gap or overlap are refused.
- **Midnight stays honest.** Anything crossing local midnight is split at 00:00 in the zone you were in, including sleep and the open Lap.
- **Travel stays truthful.** Every Record stores the IANA zone it started and ended in. Durations use UTC epoch arithmetic, and past Records display the clock times they were lived in — a 6-hour flight is always 6h.

## ✨ Features

### Pixel Watch (Wear OS)

- **Lap complication**: shows the open Lap's elapsed time, anchored on its start instant with no polling.
- **Label and exit**: tapping the complication or a tile slot labels the Lap, gives haptic and visual confirmation, and immediately returns to the watch face so notifications are never suppressed.
- **Three useful slots**: the tile offers the three most-used Activities over the last 14 days.
- **Timestamp math**: elapsed time is computed locally from the Lap start, so the watch and phone do not maintain a 1 Hz link.

### Android

- **Color Blocks dashboard**: a hatched panel for the open Lap, its elapsed time, a midnight-to-midnight strip of the day, Split and "Same as last" actions, a 3-column grid of Activity blocks, and an undo bar after each label.
- **History editing**: open any Day to relabel Records, move Boundaries, split, merge, or turn a Record back into an Untracked Record.
- **Quick Settings tile**: shows the Lap is running and labels it from the shade.

### macOS

- **Menu bar readout**: the status item shows the open Lap's elapsed time.
- **Quick Popover**: number keys `1`–`9` label the open Lap, with Split and a 3-second undo bar.
- **Deep links**: `tempo://start?activity=...` labels the open Lap and `tempo://split` marks a boundary, for Raycast, Shortcuts, and other automations.

### Ecosystem and BNPB

- **Continuous CSV export** in the Simple Time Tracker 8-column schema (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`), written with an atomic Write-Flush-Rename sequence and a 1,000 ms debounce.
- **Times in the Record's own zone**: rows never shift after travel, and subtracting the two times yields the true duration. Untracked Records stay out of the export until labeled.
- **`w/` and `with ` name markers** plus `"Contact"` tags are preserved for BNPB ingestion.
- **Android automation**: `app.tempo.action.START_TIMER` and `app.tempo.action.SPLIT` broadcast intents mirror `tempo://start` and `tempo://split` for Tasker, NFC tags, and Bluetooth triggers.

### Private AI Analysis via MCP

- **Local stdio MCP server** (`tempo-mcp`) reads the local SQLite store directly, with no open ports and no cloud relay.
- **Descriptive tools** cover day timelines, time per Activity, untracked time, and comparisons across days and weeks.
- **Guarded writes**: tools that label the open untracked stretch, Split it, or adjust a Record's start or end require `--allow-writes`.
- **Deterministic PII redaction**: `--sanitize-pii` replaces contact names after `w/` and `with ` markers with stable session pseudonyms and masks emails, phone numbers, and URLs before payloads reach an assistant.

## 🛠 Tech Stack

- **Mobile and desktop**: Flutter (Dart) across Android and macOS.
- **Pixel Watch companion**: native Jetpack Compose for Wear OS, ProtoLayout Tiles, and Watch Face Complications.
- **Synchronization**: Google Play Services Wearable Data Layer (`DataClient` with `setUrgent()`) between phone and watch, plus private local and Google Drive export.
- **Storage**: local SQLite with monotonic UTC epoch arithmetic and IANA time zones on every Record.

## 📖 Specifications and Wayfinder Map

- Product Specification: [`PRODUCT.md`](PRODUCT.md)
- Domain Glossary: [`CONTEXT.md`](CONTEXT.md)
- Wayfinder Map and Architectural Specs: [`.scratch/time-tracker/`](.scratch/time-tracker/map.md)
- Sequenced Implementation Backlog: [`.scratch/time-tracker/implementation/`](.scratch/time-tracker/implementation/)
