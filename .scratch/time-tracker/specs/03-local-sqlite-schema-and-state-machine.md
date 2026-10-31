# Local SQLite Schema & Timer State Machine Specification

## 1. Relational Database Schema (SQLite 3.35+)

### 1.1 Table DDL

```sql
-- Activities: Top-level tracked pursuits (e.g. Coding, Workout, Reading)
CREATE TABLE IF NOT EXISTS activities (
    id TEXT PRIMARY KEY NOT NULL, -- UUIDv4
    name TEXT NOT NULL,
    color_hex TEXT NOT NULL DEFAULT '#4CAF50', -- 7-char hex '#RRGGBB'
    icon_name TEXT NOT NULL DEFAULT 'schedule', -- Material/Symbol icon identifier
    is_pinned INTEGER NOT NULL DEFAULT 0, -- 1 = Top slot on Watch Tile & Quick Log
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_archived INTEGER NOT NULL DEFAULT 0, -- Soft hiding from UI pickers
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);

-- Tags: Orthogonal labels (e.g. "Contact", "DeepWork", "Project-A")
CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY NOT NULL, -- UUIDv4
    name TEXT NOT NULL UNIQUE,
    color_hex TEXT NOT NULL DEFAULT '#9E9E9E',
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);

-- Records: Completed time tracking sessions
CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY NOT NULL, -- UUIDv4
    activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    started_at_epoch_ms INTEGER NOT NULL, -- UTC Epoch timestamp
    ended_at_epoch_ms INTEGER NOT NULL,   -- UTC Epoch timestamp
    duration_ms INTEGER NOT NULL,         -- Explicit duration accounting for pauses
    comment TEXT NOT NULL DEFAULT '',     -- Optional user comment (supports name markers like 'w/ Alice')
    timezone_id TEXT NOT NULL,            -- e.g. 'America/Los_Angeles' for wall-clock date parity
    created_at_epoch_ms INTEGER NOT NULL,
    updated_at_epoch_ms INTEGER NOT NULL
);

-- Record Tags: Many-to-Many junction table
CREATE TABLE IF NOT EXISTS record_tags (
    record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (record_id, tag_id)
);

-- Active Timer: Singleton table (id = 1) tracking in-progress clock across devices
CREATE TABLE IF NOT EXISTS active_timer (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    activity_id TEXT NOT NULL REFERENCES activities(id),
    started_at_epoch_ms INTEGER NOT NULL,      -- UTC Epoch timestamp when session began
    is_paused INTEGER NOT NULL DEFAULT 0,       -- 1 = Paused, 0 = Actively ticking
    paused_at_epoch_ms INTEGER DEFAULT NULL,    -- UTC Epoch timestamp when paused
    accumulated_pause_ms INTEGER NOT NULL DEFAULT 0, -- Sum of previous pause durations
    current_comment TEXT NOT NULL DEFAULT '',   -- In-progress comment notes
    initial_tags_json TEXT NOT NULL DEFAULT '[]', -- JSON array of tag IDs
    last_heartbeat_epoch_ms INTEGER NOT NULL,  -- Updated every 60s for crash detection
    revision INTEGER NOT NULL DEFAULT 1         -- Monotonic sequence counter for LWW sync
);

-- Tombstones: Dedicated deletion tracking for sync engines without polluting records
CREATE TABLE IF NOT EXISTS tombstones (
    entity_id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL, -- 'record', 'activity', 'tag'
    deleted_at_epoch_ms INTEGER NOT NULL
);

-- Indexes for rapid analytical aggregation, date filtering, and MCP queries
CREATE INDEX IF NOT EXISTS idx_records_started ON records(started_at_epoch_ms);
CREATE INDEX IF NOT EXISTS idx_records_activity ON records(activity_id);
CREATE INDEX IF NOT EXISTS idx_records_updated ON records(updated_at_epoch_ms);
CREATE INDEX IF NOT EXISTS idx_tombstones_deleted ON tombstones(deleted_at_epoch_ms);
```

---

## 2. Timer State Machine

### 2.1 State Diagram
```
              ┌────────────────────────┐
              │          IDLE          │
              │  (active_timer is null)│
              └───────────┬────────────┘
                          │
                          │ START(activity_id)
                          ▼
              ┌────────────────────────┐
   ┌─────────>│        TRACKING        │<─────────┐
   │          │   (is_paused = 0)      │          │
   │          └─────┬────────────┬─────┘          │
   │                │            │                │
   │ RESUME         │ PAUSE      │ SWITCH(new_id) │
   │                ▼            │                │
   │          ┌──────────┐       │                │
   └──────────┤  PAUSED  │       │                │
              │(paused=1)│       │                │
              └─────┬────┘       │                │
                    │            │                │
                    │ STOP       │ (Auto-stop &   │
                    ▼            │  start new)    │
              ┌──────────────────┴─────┐          │
              │     COMMIT RECORD      │──────────┘
              │ 1. Insert into records │
              │ 2. Atomic CSV Export   │
              │ 3. Clear active_timer  │
              └────────────────────────┘
```

### 2.2 Transition Logic

1. **`START(activity_id, initial_comment = '', initial_tags = [])`**:
   - If `active_timer` is not empty $\to$ invoke `SWITCH(activity_id)`.
   - Otherwise, insert singleton into `active_timer`:
     ```sql
     INSERT INTO active_timer (
       id, activity_id, started_at_epoch_ms, is_paused, 
       accumulated_pause_ms, current_comment, initial_tags_json, 
       last_heartbeat_epoch_ms, revision
     ) VALUES (1, :activityId, :nowUtc, 0, 0, :comment, :tagsJson, :nowUtc, :nextRevision);
     ```
   - Notify Wearable Data Layer (`PutDataRequest.setUrgent()`).

2. **`PAUSE`**:
   - Condition: `is_paused == 0`.
   - Update: `is_paused = 1`, `paused_at_epoch_ms = :nowUtc`, `last_heartbeat_epoch_ms = :nowUtc`, `revision = revision + 1`.

3. **`RESUME`**:
   - Condition: `is_paused == 1`.
   - Calculate additional pause: `addedPause = :nowUtc - paused_at_epoch_ms`.
   - Update: `accumulated_pause_ms = accumulated_pause_ms + addedPause`, `is_paused = 0`, `paused_at_epoch_ms = NULL`, `last_heartbeat_epoch_ms = :nowUtc`, `revision = revision + 1`.

4. **`STOP`**:
   - Condition: `active_timer` exists.
   - Calculate final duration:
     $$\text{durationMs} = (\text{is\_paused} ? \text{paused\_at} : \text{nowUtc}) - \text{started\_at} - \text{accumulated\_pause}$$
   - In a single SQLite transaction:
     1. Insert new row into `records` with `duration_ms`, timestamps, and comment.
     2. Insert associated tags into `record_tags`.
     3. `DELETE FROM active_timer WHERE id = 1;`
   - Trigger async debounced **Atomic CSV Export** (for `bnpb` and Google Drive).
   - Clear Wearable Data Layer active timer path.

5. **`SWITCH(new_activity_id)`**:
   - Atomically executes `STOP` for current activity and `START` for `new_activity_id` within a single database transaction. Prevents multiple concurrent timers without requiring manual double-actions from the user.

---

## 3. Clock Resiliency & Power-Loss Recovery

### 3.1 Mathematical Duration Invariant
All duration evaluations use absolute UTC epoch arithmetic:
$$\text{elapsedElapsedMs}(t) = \begin{cases} 
t_{\text{paused}} - t_{\text{started}} - \Delta t_{\text{pause}}, & \text{if } \text{is\_paused} = 1 \\
t_{\text{nowUtc}} - t_{\text{started}} - \Delta t_{\text{pause}}, & \text{if } \text{is\_paused} = 0 
\end{cases}$$

- **Daylight Savings & Time Zone Changes**: Because calculations depend entirely on monotonic UTC milliseconds, crossing time zones or jumping hours back/forward during DST transitions produces zero calculation error.
- **Deep Doze & CPU Sleep**: The device does not execute a background loop. When the app resumes from deep sleep, `elapsedElapsedMs` is evaluated once against system clock epoch.

### 3.2 Heartbeat Checkpointing & Crash Recovery
- Every 60 seconds while tracking, a background worker updates `last_heartbeat_epoch_ms = nowUtc`.
- Upon application boot:
  - If `active_timer` exists:
    - Check delta: `gap = nowUtc - last_heartbeat_epoch_ms`.
    - If `gap > 6 hours` (e.g. device died overnight or was powered off for an extended period):
      - App presents a recovery prompt:
        - *"Timer was running when device shut down. Keep tracking (elapsed: X hrs), or truncate to last heartbeat (Y hrs), or discard?"*
    - If `gap <= 6 hours`:
      - Normal continuation; timer continues ticking smoothly.

---

## 4. Tombstone Deletion & Synchronization Protocol

- When an entity (`record`, `activity`, `tag`) is deleted:
  ```sql
  BEGIN TRANSACTION;
  DELETE FROM records WHERE id = :id;
  INSERT OR REPLACE INTO tombstones (entity_id, entity_type, deleted_at_epoch_ms) 
  VALUES (:id, 'record', :nowUtc);
  COMMIT;
  ```
- **Sync Reconciliation**:
  - Peer synchronization queries `SELECT entity_id FROM tombstones WHERE deleted_at_epoch_ms > :lastSyncEpoch;`
  - Deletions are propagated to remote devices without resurrections.
- **Vacuum Cadence**:
  - `DELETE FROM tombstones WHERE deleted_at_epoch_ms < (:nowUtc - 30 * 86400000);` (purges tombstones older than 30 days during weekly maintenance).
