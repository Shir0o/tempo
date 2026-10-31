# Time Tracker

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
