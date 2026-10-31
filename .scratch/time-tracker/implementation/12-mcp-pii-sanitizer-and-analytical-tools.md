# 12: MCP PII Sanitizer and Analytical Tools

Status: completed
Phase: 4 - Local AI & MCP
Dependencies: 11

## Scope
Implement the analytical tool suite and deterministic PII sanitization engine within the MCP server.

## Deliverables
- `PIISanitizer` engine replacing names following `w/` and `with ` with session-consistent pseudonyms (`[Contact-1]`) and redacting emails/phones.
- Analytical Tools:
  - `get_active_timer`
  - `get_daily_summary(date)`
  - `query_records(start_date, end_date, activity_name, tag, limit)`
  - `analyze_trends(lookback_weeks)`
- Guarded write tools (`start_timer`, `stop_timer`, `add_manual_record`) active only with `--allow-writes`.
- Unit tests verifying sanitization rules and analytical calculations.
