# Local Model Context Protocol (MCP) Server Specification

## 1. Architecture & Security Model

The Time Tracker MCP server (`time-tracker-mcp`) is an offline-first, local CLI service operating over standard input/output (`stdio`) on macOS. It connects directly to the local SQLite database to provide external AI assistants (Claude Desktop, Gemini, Cursor) with rich analytical intelligence regarding personal habits, focus distributions, and time allocation.

```
┌─────────────────────────┐                   ┌──────────────────────────────┐
│ External AI Assistant   │                   │ Local macOS Environment      │
│ (Claude / Gemini CLI)   │ <=== (stdio) ===> │ time-tracker-mcp             │
│                         │   JSON-RPC 2.0    │ ┌──────────────────────────┐ │
│ Prompt: "How did I      │                   │ │ PII Sanitizer Engine     │ │
│ spend my time this week?│                   │ │ (Redacts 'w/ <Name>')    │ │
└─────────────────────────┘                   │ └────────────┬─────────────┘ │
                                              │              │               │
                                              │              ▼               │
                                              │ ┌──────────────────────────┐ │
                                              │ │ SQLite Local Database    │ │
                                              │ └──────────────────────────┘ │
                                              └──────────────────────────────┘
```

### Security & Privacy Tenets:
1. **Zero Open Ports & Zero Telemetry**: Operates strictly over `stdio`. No HTTP ports are opened on loopback; no cloud relay is required.
2. **Read-Only by Default**: The MCP server runs in read-only mode by default. Mutation tools (`start_timer`, `stop_timer`, `add_manual_record`) are completely disabled unless the binary is explicitly launched with the `--allow-writes` flag.
3. **Deterministic PII Sanitization (`--sanitize-pii`)**: Enabled by default. Automatically redacts personal contact names and sensitive identifiers before payloads are returned to the LLM.

---

## 2. Deterministic PII Sanitization Engine

Downstream apps like BNPB attach personal contact names into record comments using standardized name markers (`w/`, `with `). To prevent leaking real-world identities to external cloud model providers during conversational analysis, the sanitizer applies three deterministic passes:

1. **Contact Marker Masking**:
   - Matches regex: `(?i)(?:\b(?:w\/|with)\s+)([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)`
   - Maps each unique real name encountered to a consistent session pseudonym: `Alice Smith` $\to$ `[Contact-1]`, `Bob Jones` $\to$ `[Contact-2]`.
   - The AI understands relational context (e.g. *"You met with [Contact-1] twice this week for 3 hours total"*) without ever seeing the person's true name.
2. **Contact Tags Preservation**:
   - The tag `"Contact"` remains intact so analytical models can quantify relational investment versus solo deep work.
3. **Pattern Redaction**:
   - Email addresses $\to$ `[EMAIL]`
   - Phone numbers $\to$ `[PHONE]`
   - URLs $\to$ `[URL]`

---

## 3. Tool Catalog & Schemas

### 3.1 `get_active_timer`
Returns the status of the currently ticking timer, if any.
- **Input Parameters**: None
- **Output Schema**:
  ```json
  {
    "is_tracking": true,
    "activity_name": "Coding",
    "color_hex": "#4CAF50",
    "started_at": "2026-10-30T14:15:00Z",
    "elapsed_seconds": 5055,
    "is_paused": false,
    "comment": "Refactoring MCP server",
    "tags": ["DeepWork", "Project-A"]
  }
  ```

### 3.2 `get_daily_summary`
Aggregates total tracked time, break intervals, and category breakdown for a single day.
- **Input Parameters**:
  - `date` *(string, optional, format: `YYYY-MM-DD`)*: Target date. Defaults to current day.
- **Output Schema**:
  ```json
  {
    "date": "2026-10-30",
    "total_duration_hours": 7.42,
    "total_records_count": 5,
    "breakdown": [
      { "activity": "Coding", "hours": 4.5, "percentage": 60.6 },
      { "activity": "Workout", "hours": 1.25, "percentage": 16.8 },
      { "activity": "Reading", "hours": 1.0, "percentage": 13.5 },
      { "activity": "Meeting", "hours": 0.67, "percentage": 9.1 }
    ]
  }
  ```

### 3.3 `query_records`
Searches historical time records with flexible date range and tag filters.
- **Input Parameters**:
  - `start_date` *(string, format `YYYY-MM-DD`)*: Inclusive start date.
  - `end_date` *(string, format `YYYY-MM-DD`)*: Inclusive end date.
  - `activity_name` *(string, optional)*: Filter by activity.
  - `tag` *(string, optional)*: Filter by tag (e.g. `"Contact"`).
  - `limit` *(integer, optional, default: 50, max: 200)*
- **Output**: Array of record objects with sanitized comments.

### 3.4 `analyze_trends`
Calculates multi-week habit consistency, peak hours of day, and week-over-week trends.
- **Input Parameters**:
  - `lookback_weeks` *(integer, optional, default: 4)*: Number of historical weeks to analyze.
- **Output Schema**:
  - `weekly_averages`: Hours per activity per week.
  - `time_of_day_distribution`: Hourly histogram (00:00–23:00) showing when deep work occurs.
  - `habit_streaks`: Current and max daily streaks per pinned habit.

### 3.5 Guarded Write Tools (Active only with `--allow-writes`)
- `start_timer(activity_name, comment, tags)`: Starts active timer via local SQLite singleton.
- `stop_timer(comment)`: Commits active timer and triggers live CSV export.
- `add_manual_record(activity_name, start_time, end_time, comment, tags)`: Logs past session.

---

## 4. Claude Desktop / Gemini MCP Client Configuration

To register the time tracker MCP server in `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "time-tracker": {
      "command": "/Users/twang/.gemini/antigravity/scratch/time-tracker/bin/time-tracker-mcp",
      "args": [
        "--db-path", "/Users/twang/Library/Application Support/time-tracker/timetracker.db",
        "--sanitize-pii"
      ]
    }
  }
}
```

---

## 5. Verification & Acceptance Criteria
1. **Sanitization Rigor**: 100% of names following `w/` or `with ` are replaced with anonymous tokens in returned record payloads; zero real contact names are output in LLM responses.
2. **Query Latency**: Analytical queries (`analyze_trends` over 10,000 records) execute via indexed SQLite queries in $<25$ms.
3. **Execution Safety**: Mutation tools return a clean error if `--allow-writes` is absent, preventing rogue model invocations from altering user records.
