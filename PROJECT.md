# Project-Specific Rules

<!-- Repo-specific agent instructions. The rollout script never touches this file. -->

## Context

- **Tempo**: A private, offline-first multi-platform time tracker for Android, macOS, and Pixel Watch (Wear OS).
- **Core Integrations**: Live continuous atomic CSV export for BNPB (`Time track` folder), local stdio Model Context Protocol (MCP) server for Claude/Gemini, and Google Play Services Wearable Data Layer (`DataClient`).
- **Domain Models & Glossary**: [CONTEXT.md](CONTEXT.md). Use exact domain vocabulary (`Activity`, `Record`, `ActiveTimer`, `Tag`, `QuickLog`, `UndoGraceWindow`, `GuardedStop`, `HeartbeatCheckpoint`, `Tombstone`, `PIISanitizer`).
- **Product Specification**: [PRODUCT.md](PRODUCT.md).
- **Backlog & Architecture**: Wayfinder map and implementation specs under `.scratch/time-tracker/`.

## Hard rules

- **Time Arithmetic Invariance**: All elapsed durations must be calculated using monotonic UTC epoch milliseconds (`nowUtc - startedAtEpochMs - accumulatedPauseMs`). Never use wall-clock local timezone subtraction for active timers.
- **Wear OS Notification Priority (Action-and-Exit)**: Logging an activity from the watch MUST trigger haptic feedback, flash visual confirmation, and immediately invoke `Activity.finish()`. The watch app must never linger in the foreground, as Wear OS suppresses heads-up notifications (HUN) while an app is active.
- **GuardedStop Requirement**: Stopping an active timer on Wear OS requires a continuous 600ms hold-to-stop with radial progress to prevent accidental touches from clothing or gym bumps.
- **Atomic CSV Pipeline**: Continuous exports for BNPB must strictly follow the 8-column Simple Time Tracker schema (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`) and use the atomic Write-Flush-Rename sequence (`.tmp.<uuid>` $\to$ `fsync()` $\to$ `rename()`) with a 1,000ms debounce.
- **Deterministic PII Sanitization**: When querying records via MCP, the `PIISanitizer` must mask real contact names following `w/` and `with ` markers with consistent session pseudonyms (`[Contact-1]`), and mask emails/phones/URLs unless explicitly authorized. Write tools must remain disabled unless launched with `--allow-writes`.

## Verification Commands

- Static Analysis: `dart analyze`
- Targeted Tests: `flutter test test/<path_to_test>`
- Local MCP Server: `dart run bin/tempo_mcp.dart --sanitize-pii`
- Android / Wear OS Builds:
  - Android App: `cd android && ./gradlew :app:compileDebugKotlin`
  - Wear OS Companion: `cd android && ./gradlew :wear:compileDebugKotlin`

## Tier

Tier 1: The `Analyze & Test` CI check (`.github/workflows/ci.yml`) is required on `main`.
