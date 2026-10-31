## Destination

A locked product and technical architecture specification (`PRODUCT.md`, `CONTEXT.md`, IPC/API contracts, and synced storage model) along with a sequenced, unblocked backlog of implementation tickets on the local markdown issue tracker, ready for autonomous build runs.

## Notes

- Domain: Offline-first multi-platform time tracking with Simple Time Tracker parity, frictionless 1-tap logging, Wear OS tiles/complications, peer app interoperability (`bnpb`, `ActivityWatchSync`, `workout-planner`), and private AI analytics via MCP.
- Platforms: Flutter (Android & macOS) + Native Jetpack Compose for Wear OS (Pixel Watch) + Local stdio MCP server (macOS).
- Standing preferences: 100% private and local-first, zero mandatory cloud accounts, live continuous CSV export for `bnpb`, deterministic PII sanitization for LLM queries.
- Skills to consult: `wayfinder`, `domain-modeling`, `grilling`, `research`.

## Decisions so far

- [01: Wearable Data Layer Sync Protocol](issues/01-research-wearable-data-layer-sync.md): Adopt `DataClient` (with `setUrgent()`) as the replicated state store and offline buffer; anchor timestamps (`startedAtEpochMs`) eliminate polling and preserve watch battery life across Compose, ProtoLayout Tiles, and Complications.
- [02: STT CSV & BNPB Compatibility](issues/02-research-stt-csv-and-bnpb-compatibility.md): Enforce strict 8-column Simple Time Tracker CSV parity (`activity name,time started,time ended,comment,categories,record tags,duration,duration minutes`), `yyyy-MM-dd HH:mm:ss` timestamps, `", "` multi-tag joins, `"Contact"` tag filtering, ADR-0005 name markers (`w/`, `with `), and continuous atomic Write-Flush-Rename exports to prevent partial read corruption.


## Not yet specified

- **Multi-timer concurrency**: Whether users can run multiple concurrent timers simultaneously or strictly enforce a single active timer.
- **Calendar timeline overlay**: Ingesting device calendar events alongside tracked records (similar to `auto-vol`).
- **Direct legacy STT SQLite migration**: Automated import tool for historical SQLite databases from existing Simple Time Tracker installations.
- **Sensor/Hardware automation triggers**: Bluetooth beacon, Wi-Fi SSID, or NFC tag triggers for automatic timer start/stop.

## Out of scope

- Multi-tenant cloud backends, subscription servers, or centralized user account infrastructure.
- Web browser client (strictly native Android, Pixel Watch OS, and macOS).
- Third-party remote tracking or telemetry servers.
