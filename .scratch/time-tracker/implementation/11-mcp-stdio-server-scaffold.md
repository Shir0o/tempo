# 11: MCP Stdio Server Scaffold

Status: ready
Phase: 4 - Local AI & MCP
Dependencies: 01

## Scope
Scaffold the offline Model Context Protocol server binary (`time-tracker-mcp`) operating over `stdio`.

## Deliverables
- JSON-RPC 2.0 stdio transport adhering to the official MCP specification.
- Direct read-only connection to local SQLite database file.
- CLI argument parsing (`--db-path`, `--sanitize-pii`, `--allow-writes`).
- Server capability registration: tools discovery, ping, and error handling.
