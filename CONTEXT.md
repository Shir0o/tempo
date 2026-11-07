# Tempo

An offline-first, private record of the whole day — every day, midnight to midnight — for Android, macOS, and Pixel Watch (Wear OS). Time is captured retrospectively: an open Lap always runs, and the user labels what it was after the fact. Tempo describes how a day was spent; it never sets goals, scores, or judges it.

## Language

### Core Tracking

**Day**:
The span from local midnight to the next local midnight in the zone the user is in. Every moment of a Day belongs to exactly one Record or the open Lap — no gaps, no overlaps. A Day that crosses time zones is shorter or longer than 24h (e.g., 21h or 27h) and shows the zone change.
_Avoid_: Workday, session, period

**Activity**:
A named, color-coded kind of thing that fills part of a day (e.g., "Sleep", "Meals", "Commute", "Reading"). No Activity is privileged over another. An Activity belongs optionally to exactly one Category (1:1 classification).
_Avoid_: Task, job, habit, project

**Category**:
A primary organizational grouping classifying one or more Activities into high-level routines (e.g., "Essentials", "Productivity", "Leisure", "Transportation"). Categories own the colour its Activities wear and group activities across reports and exports without imposing priority or goal mechanics.
_Avoid_: Bucket, goal, folder

**Record**:
A labeled, closed span of a Day for one Activity, containing a start timestamp, end timestamp, start time zone, end time zone, duration, optional comment, and tags. Duration is always UTC epoch arithmetic; start and end are displayed in their own zones (e.g., "13:05 LAX → 16:05 JFK · 6h 00m").
_Avoid_: TimeEntry, log, session, event

**Lap**:
The internal name for the open Untracked stretch: the single running span from the end of the last Record to now. It always runs; labeling it closes it as a Record and opens a new one. Never shown in the UI, which calls this time Untracked.
_Avoid_: Timer, stopwatch, running record, session

**Untracked Record**:
A closed span with no Activity yet, created by a Split, by leaving time unlabeled, or by trimming a Record's Edge. Shown hatched; can be labeled any time; excluded from the EcosystemExport until labeled.
_Avoid_: Gap, hole, idle time

**Split**:
Closing the open Lap at the current moment without labeling it, producing an Untracked Record and a new Lap.
_Avoid_: Stop, pause, break

**Still / Again**:
The two ways to give the open Lap the last labeled Activity. **Still** grows that Record over the Lap, keeping its note and tags, when the two meet; across an Untracked span or a midnight it labels the Lap as a new Record with the same Activity, note and tags. **Again** labels the Lap as a new Record with that Activity and no note.
_Avoid_: Repeat, same as last, merge

**Edge**:
The start or end instant of one Record. Correcting the past moves an Edge: only that Record changes, the time it gives up becomes an Untracked Record (joining an adjacent Untracked span or the open Untracked stretch when one is there), and it may grow only into time that is already Untracked. A Record that would cross local midnight is split there.
_Avoid_: Boundary, cut, handle

**MidnightSplit**:
The division of any Record or Lap that crosses midnight into two, at 00:00 in the zone the user is in when that midnight occurs. An edit that pushes a Record across midnight is split the same way.
_Avoid_: Rollover, day wrap

**Tag**:
A secondary label attached to an Activity or Record for orthogonal filtering and cross-app routing (e.g., "Contact", "Travel"). At most one Tag carries the Contact flag, set in Settings → Tags; that tag is attached automatically to a Record whose comment names a Person, and the flag survives renaming the tag.
_Avoid_: Label, badge, category, marker

**QuickLog**:
A rapid 1-tap capture on a watch complication, tile, or mobile widget that labels the open Lap with an Activity and immediately finishes back to the ambient home surface.
_Avoid_: Fast track, instant start, one-click

**UndoGraceWindow**:
The transient interval (default 3 seconds) following a label action allowing single-tap reversal of an accidental label.
_Avoid_: Cancel window, rollback buffer

**Tombstone**:
A dedicated record in an auxiliary deletion table capturing the entity ID and deletion timestamp to prevent resurrected items during peer sync.
_Avoid_: Soft delete, trash, ghost record

**QuickPopover**:
A lightweight, keyboard-navigable floating status panel spawned from the macOS menu bar or global hotkey for labeling the open Lap.
_Avoid_: Menu window, tray dialog, popup

**DeepLinkBus**:
The cross-platform `tempo://` URL scheme and Android Intent bridge enabling peer apps and system automations to label the open Lap and query Records.
_Avoid_: Custom scheme, IPC handler, command URL

**PIISanitizer**:
A deterministic redaction engine within the MCPBridge that pseudonymizes contact names and masks personal metadata before AI consumption.
_Avoid_: Anonymizer, filter, redactor

### Integrations & Interoperability

**NameMarker**:
A designated prefix within a Record's comment (default `w/` or `with `) identifying associated people for peer CRM apps such as BNPB.
_Avoid_: Mention, contact tag, name prefix

**Person**:
Someone named after a NameMarker in a Record's comment. People are not stored separately: they are drawn from past comments and offered back ranked by how recent and frequent they are. Choosing a Person writes their name after the NameMarker and attaches the Contact Tag to the Record.
_Avoid_: Contact (as an entity), friend, attendee

**AutoAdvance**:
Prefilling a new Record's comment from the last Record with the same Activity and Person, with its trailing number moved forward (e.g., "John 1 w/ Sam" → "John 2 w/ Sam"). It keeps the cadence seen in history: the same number of chapters per meeting. A Bible reference moves by chapter only, following the 66-book Protestant order, and runs past a book's last chapter into the next book ("John 19-20" → "John 21, Acts 1"); Revelation wraps to Genesis. Always an editable suggestion, never applied silently.
_Avoid_: Auto-increment, template, macro

**RecurringNote**:
A comment that keeps coming back for the same Activity on the same weekday at about the same hour (at least 2 of the last 4 such weekdays, within an hour). When one matches the moment being labeled, it is offered first: it supplies the People, and AutoAdvance moves any reading forward; a note without a number is offered as written. Always a suggestion, never applied silently.
_Avoid_: Routine, habit, schedule, template

**EcosystemExport**:
An automated, live-updating export file (Simple Time Tracker CSV parity, JSON, and ActivityWatch bucket formats) published to local storage and Google Drive for downstream consumption. CSV times are written in each Record's start zone (never the device's current zone), so rows never shift after travel and subtracting them yields the true duration.
_Avoid_: Dump, backup, sync feed

**MCPBridge**:
A local Model Context Protocol server exposing read-only descriptive tools (timelines, time per Activity, comparisons across days) and guarded write tools over the local SQLite store to external AI assistants. It describes how time was spent; it never scores or judges it.
_Avoid_: AI agent, plugin, cloud assistant

**Import Continuous Coverage Reconciliation**:
The non-destructive ingestion pipeline that bridges external tracking files (Simple Time Tracker `.backup` or `.csv`) into Tempo's zero-gap midnight-to-midnight model. Multi-day spans are partitioned at local 00:00 midnight boundaries, unrecorded historical spans between the first and last imported timestamps are synthesized into Untracked Records (`activity_id: null`), historical timestamps resolve using the device's local timezone DST rules on that historical date, and existing Tempo records strictly take precedence over imported records.
_Avoid_: Direct bulk insert, loose import, gap-tolerant ingest
