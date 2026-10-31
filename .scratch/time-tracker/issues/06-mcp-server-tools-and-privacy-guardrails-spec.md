# MCP Server Tools and Privacy Guardrails Spec

Type: grilling
Status: resolved
Blocked by: none

## Question

What is the exact Model Context Protocol (MCP) tool contract (tool names, JSON schema parameters, return payloads) for local AI analysis on macOS, and what deterministic PII sanitization rules (`--sanitize-pii`) protect contact names and sensitive notes from external LLMs?

## Answer

The complete MCP server tool contract and privacy guardrails specification is documented in [`.scratch/time-tracker/specs/06-mcp-server-tools-and-privacy-guardrails-spec.md`](../specs/06-mcp-server-tools-and-privacy-guardrails-spec.md).

### Resolved Decisions:
1. **Local Offline stdio Transport**: Built as an offline CLI binary (`time-tracker-mcp`) connecting directly to the local macOS SQLite database with zero open network ports and zero third-party telemetry.
2. **Deterministic PII Sanitization (`PIISanitizer`)**: Enabled by default via `--sanitize-pii`. Automatically matches and replaces contact names following `w/` and `with ` with session-scoped pseudonyms (`[Contact-1]`), while preserving relational context and the `"Contact"` tag so LLMs can analyze habits safely.
3. **Analytical Tool Catalog**: Exposes `get_active_timer`, `get_daily_summary`, `query_records`, and `analyze_trends` (rolling weekly averages, hourly heatmaps, habit streaks).
4. **Guarded Mutation Safety**: Write tools (`start_timer`, `stop_timer`, `add_manual_record`) are completely disabled unless the server is explicitly launched with the `--allow-writes` flag.
