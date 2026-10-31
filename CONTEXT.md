# Tempo

An offline-first, private time tracker for Android, macOS, and Pixel Watch (Wear OS) designed for frictionless 1-tap logging, native system integrations, peer app interoperability, and local AI analytics via MCP.

## Language

### Core Tracking

**Activity**:
A named, color-coded task or pursuit that can be timed (e.g., "Coding", "Workout", "Reading").
_Avoid_: Task, category, job, habit

**Record**:
A completed time interval logged for an Activity, containing a start timestamp, end timestamp, duration, optional comment, and tags.
_Avoid_: TimeEntry, log, session, event

**ActiveTimer**:
The single in-progress clock tracking an ongoing Activity in real time across watch, phone, and desktop.
_Avoid_: Stopwatch, running record, tracker

**Tag**:
A secondary label attached to an Activity or Record for orthogonal filtering and cross-app routing (e.g., "Contact", "DeepWork").
_Avoid_: Label, badge, category, marker

**QuickLog**:
A rapid 1-tap capture action on a watch complication, tile, or mobile widget that initiates an ActiveTimer and automatically finishes back to the ambient home surface.
_Avoid_: Fast track, instant start, one-click

**UndoGraceWindow**:
The transient interval (default 3 seconds) following a QuickLog action allowing single-tap reversal of an accidental timer start.
_Avoid_: Cancel window, rollback buffer

**GuardedStop**:
An intentional interaction requirement (a 600ms continuous hold) preventing accidental termination of a running ActiveTimer by clothing or incidental screen contact.
_Avoid_: Confirmation dialog, lock switch

**HeartbeatCheckpoint**:
A lightweight periodic timestamp (saved every 60 seconds) used to detect abrupt power loss or abnormal device shutdown during an active tracking session.
_Avoid_: Auto-save, ping, keep-alive

**Tombstone**:
A dedicated record in an auxiliary deletion table capturing the entity ID and deletion timestamp to prevent resurrected items during peer sync.
_Avoid_: Soft delete, trash, ghost record

**QuickPopover**:
A lightweight, keyboard-navigable floating status panel spawned from the macOS menu bar or global hotkey for rapid habit switching.
_Avoid_: Menu window, tray dialog, popup

**DeepLinkBus**:
The cross-platform `tempo://` URL scheme and Android Intent bridge enabling peer apps and system automations to start, stop, and query timers.
_Avoid_: Custom scheme, IPC handler, command URL

**PIISanitizer**:
A deterministic redaction engine within the MCPBridge that pseudonymizes contact names and masks personal metadata before AI consumption.
_Avoid_: Anonymizer, filter, redactor

### Integrations & Interoperability

**NameMarker**:
A designated prefix within a Record's comment (default `w/` or `with `) identifying associated people for peer CRM apps such as BNPB.
_Avoid_: Mention, contact tag, name prefix

**EcosystemExport**:
An automated, live-updating export file (Simple Time Tracker CSV parity, JSON, and ActivityWatch bucket formats) published to local storage and Google Drive for downstream consumption.
_Avoid_: Dump, backup, sync feed

**MCPBridge**:
A local Model Context Protocol server exposing read-only analytical tools and guarded write tools over the local SQLite store to external AI assistants.
_Avoid_: AI agent, plugin, cloud assistant
