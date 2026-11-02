# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

People who want a plain, complete record of how each of their days went — sleep, meals, travel, chores, time with others, everything — and who use a constellation of personal apps across Android, Pixel Watch, and macOS. They need effortless, sub-second labeling without cognitive overhead, battery drain, or privacy exposure, and they do not want to be coached, scored, or nudged.

## Product Purpose

Tempo keeps a continuous record of the whole day, every day, midnight to midnight. An open Lap always runs; the user labels what it was after the fact, which closes it as a Record and starts the next Lap. Tempo describes how a day was spent and never judges it: no goals, streaks, scores, or focus/productivity framing. It bridges mobile, watch, and desktop into a cohesive offline-first system that operates without mandatory cloud accounts, provides continuous live interoperability with peer tools (such as BNPB and Workout Planner), and enables local AI analytics via Model Context Protocol (MCP) with strict PII protection.

## Positioning

Unlike cloud-locked, corporate subscription trackers (Toggl, Clockify, Harvest) that require proprietary accounts and monetize user telemetry, and unlike isolated single-device utilities (Simple Time Tracker) that lack multi-device sync and live automation:
- **100% Offline-First & Private**: Data lives in a local SQLite database owned exclusively by the user, with optional private Google Drive or peer-to-peer sync.
- **True Wear OS Companion**: Built with native Jetpack Compose for Wear OS, featuring sub-second startup, low-power ambient mode, Watch Face complications, and dynamic ProtoLayout tiles that never drain battery or suppress incoming notifications.
- **Desktop Keyboard Ergonomics**: Runs as an unobtrusive macOS menu bar status item with a global hotkey (`Option + Shift + T`) and number-key capture.
- **Ecosystem Interoperability**: Continuous live CSV export matching Simple Time Tracker schemas for seamless consumption by BNPB, paired with a universal deep-link bus (`tempo://start`) and Android broadcast intents.
- **Local AI Analysis via MCP**: Offline stdio MCP server for Claude Desktop, Gemini, or local models with automated, deterministic PII sanitization that redacts contact names before analysis.

## Operating Context

- **Pixel Watch (Wear OS)**: Ultra-fast micro-interactions on the wrist. The complication shows the open Lap's elapsed time; tapping it or a smart tile slot (the three most-used Activities) labels the Lap, triggers haptic confirmation, and immediately exits back to the watch face so incoming notifications, texts, and calls are never blocked.
- **Android Phone/Tablet**: Dashboard showing the open Lap, a midnight-to-midnight timeline of the day, and one-tap labeling; daily/weekly review of time per Activity, Activity configuration, and quick-settings tile labeling.
- **macOS Desktop**: Lightweight menu bar popover for instant keyboard-driven labeling of the open Lap, plus full window for browsing and correcting past Days.
- **Local MCP Client**: Local CLI process invoked over stdio by AI assistants to describe how time was spent: timelines, time per Activity, and comparisons across days and weeks.

## Capabilities and Constraints

- **Platform Architecture**:
  - Flutter multiplatform core powering the Android and macOS experiences.
  - Native Jetpack Compose for Wear OS companion module for Pixel Watch.
  - Google Play Services Wearable Data Layer (`DataClient` with `setUrgent()`) for instantaneous, battery-efficient watch-phone synchronization.
  - Local stdio MCP server CLI executable on macOS.
- **Storage & Relational Schema**:
  - Normalized SQLite database (`activities`, `tags`, `records`, `record_tags`, `lap`, and indexed `tombstones`).
  - Monotonic UTC epoch arithmetic (`nowUtc - lapStartedAt`) guaranteeing exact durations across device sleep, timezone crossings, and daylight saving shifts — a 6h flight is always 6h.
  - Each Record stores its start and end IANA time zone; past Records always display in the zones they happened in, never the device's current zone.
  - Continuous coverage: every moment of a Day belongs to exactly one Record or the open Lap, enforced by atomic SQLite transitions (label = close Lap as Record + open new Lap). Records crossing midnight are split at 00:00 local.
  - The open Lap's start is persisted, so battery death or a reboot simply extends the Lap; nothing is lost.
- **Data Portability & Ecosystem Interoperability**:
  - Continuous atomic Write-Flush-Rename CSV export matching Simple Time Tracker 8-column layout (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`). Times are written in each Record's start zone; durations come from UTC epoch arithmetic; Untracked Records are omitted until labeled.
  - Strict adherence to BNPB ingestion standards (`"Contact"` tags, `w/` and `with ` name markers, and SHA-256 deduplication fingerprints).
  - ActivityWatch bucket format compatibility for automated screen-time reconciliation.
- **Automations & Extensibility**:
  - Universal `tempo://start?activity=...` URL scheme across macOS and Android.
  - Android Broadcast Intents (`app.tempo.action.START_TIMER`) for Tasker, NFC tags, and Bluetooth triggers.
  - Native macOS Shortcuts and Raycast script commands.
- **Privacy & Security**:
  - Deterministic PII Sanitizer (`--sanitize-pii`) masking contact names after `w/` markers with session pseudonyms (`[Contact-1]`) and redacting emails/phones before payloads reach LLMs.
  - Guarded MCP write operations disabled by default unless `--allow-writes` is explicitly passed.

## Brand Commitments

- **Name**: Tempo (CLI binary: `tempo-mcp`, scheme: `tempo://`).
- **Design Language**: Clean, high-contrast utility design system with vibrant activity accent colors, dark mode defaults, legible monospace duration readouts, and minimal visual noise.
- **Tone & Voice**: Calm, plain, unobtrusive, and rigorously private. Descriptive, never evaluative. Zero nag screens, zero goals or streaks, zero subscription prompts, and zero uninvited telemetry.

## Product Principles

1. **Sub-Second Capture**: Labeling time must never feel like a chore. Wrist complications, menu bar hotkeys, and widget buttons must label the open Lap in $\le 1$ second.
2. **Never Miss a Notification**: Watch interactions must execute an Action-and-Exit pattern, immediately returning to the watch face so system alerts and communications remain unblocked.
3. **Data Sovereign & Local-First**: Time history is deeply personal. All data resides on physical hardware in open formats (SQLite, CSV, JSON); synchronization uses private user accounts (Google Drive) without middlemen.
4. **The Day Is Continuous**: Every moment belongs to a Record or the open Lap. Every label is 1 tap with a 3-second Undo window, and any past Boundary can be moved later — so an accidental tap costs nothing.
5. **Private AI Assistance**: AI analysis must be performed locally via MCP with deterministic sanitization so personal names, notes, and contacts are never leaked to cloud models.
6. **True to Where You Were**: Records show the local times they were lived in and their true durations, across any time zone or daylight saving change.
