# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Individual developers, researchers, students, and professionals who manage their own time, build deep habits, and interact with a constellation of personal apps across Android, Pixel Watch, and macOS. They need effortless, sub-second time capture without cognitive overhead, battery drain, or privacy exposure.

## Product Purpose

Tempo delivers instant, frictionless time tracking and habit awareness across everyday devices. It bridges mobile, watch, and desktop into a cohesive offline-first system that operates without mandatory cloud accounts, provides continuous live interoperability with peer tools (such as BNPB and Workout Planner), and enables local AI analytics via Model Context Protocol (MCP) with strict PII protection.

## Positioning

Unlike cloud-locked, corporate subscription trackers (Toggl, Clockify, Harvest) that require proprietary accounts and monetize user telemetry, and unlike isolated single-device utilities (Simple Time Tracker) that lack multi-device sync and live automation:
- **100% Offline-First & Private**: Data lives in a local SQLite database owned exclusively by the user, with optional private Google Drive or peer-to-peer sync.
- **True Wear OS Companion**: Built with native Jetpack Compose for Wear OS, featuring sub-second startup, low-power ambient mode, Watch Face complications, and dynamic ProtoLayout tiles that never drain battery or suppress incoming notifications.
- **Desktop Keyboard Ergonomics**: Runs as an unobtrusive macOS menu bar status item with a global hotkey (`Option + Shift + T`) and number-key capture.
- **Ecosystem Interoperability**: Continuous live CSV export matching Simple Time Tracker schemas for seamless consumption by BNPB, paired with a universal deep-link bus (`tempo://start`) and Android broadcast intents.
- **Local AI Analysis via MCP**: Offline stdio MCP server for Claude Desktop, Gemini, or local models with automated, deterministic PII sanitization that redacts contact names before analysis.

## Operating Context

- **Pixel Watch (Wear OS)**: Ultra-fast micro-interactions on the wrist. Tapping a watch complication or smart tile slot starts tracking, triggers haptic confirmation, and immediately exits back to the watch face so incoming notifications, texts, and calls are never blocked.
- **Android Phone/Tablet**: Comprehensive mobile dashboard for daily/weekly review, habit statistics, category configuration, and quick-settings tile logging.
- **macOS Desktop**: Lightweight menu bar popover for instant keyboard-driven habit switching during deep focus work, plus full window for historical analysis and reporting.
- **Local MCP Client**: Local CLI process invoked over stdio by AI assistants to query productivity trends, calculate time distributions, and inspect habit consistency.

## Capabilities and Constraints

- **Platform Architecture**:
  - Flutter multiplatform core powering the Android and macOS experiences.
  - Native Jetpack Compose for Wear OS companion module for Pixel Watch.
  - Google Play Services Wearable Data Layer (`DataClient` with `setUrgent()`) for instantaneous, battery-efficient watch-phone synchronization.
  - Local stdio MCP server CLI executable on macOS.
- **Storage & Relational Schema**:
  - Normalized SQLite database (`activities`, `tags`, `records`, `record_tags`, `active_timer`, and indexed `tombstones`).
  - Monotonic UTC epoch arithmetic (`nowUtc - startedAt - accumulatedPause`) guaranteeing 100% mathematical accuracy across device sleep, timezone crossings, and daylight saving shifts.
  - 60-second heartbeat checkpointing in `active_timer` to recover gracefully from unexpected battery death.
  - Strict single-active-timer semantics via atomic SQLite `SWITCH` transitions.
- **Data Portability & Ecosystem Interoperability**:
  - Continuous atomic Write-Flush-Rename CSV export matching Simple Time Tracker 8-column layout (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`).
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
- **Design Language**: Clean, high-contrast utility design system with vibrant activity accent colors, dark mode defaults, legible monospace duration timers, and minimal visual noise.
- **Tone & Voice**: Focused, calm, unobtrusive, and rigorously private. Zero nag screens, zero subscription prompts, and zero uninvited telemetry.

## Product Principles

1. **Sub-Second Capture**: Logging time must never feel like work. Wrist complications, menu bar hotkeys, and widget buttons must initiate tracking in $\le 1$ second.
2. **Never Miss a Notification**: Watch interactions must execute an Action-and-Exit pattern, immediately returning to the watch face so system alerts and communications remain unblocked.
3. **Data Sovereign & Local-First**: Time history is deeply personal. All data resides on physical hardware in open formats (SQLite, CSV, JSON); synchronization uses private user accounts (Google Drive) without middlemen.
4. **Guarded Intentionality**: Starting is 1-tap fast with a 3-second Undo window; stopping an active timer requires a deliberate 600ms hold to eliminate accidental stoppage from sleeve brushes or bumps.
5. **Private AI Assistance**: AI analysis must be performed locally via MCP with deterministic sanitization so personal names, notes, and contacts are never leaked to cloud models.
