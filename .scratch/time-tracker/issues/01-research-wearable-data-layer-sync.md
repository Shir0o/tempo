# Research Wearable Data Layer Sync Protocol

Type: research
Status: resolved
Blocked by: none

## Question

What is the optimal communication protocol and data schema for Google Play Services Wearable Data Layer (`DataClient` vs `MessageClient` vs `ChannelClient`) between the Flutter Android companion app and the Jetpack Compose Wear OS companion to synchronize active timer state, 1-tap start/stop actions, and the recent activity list with maximum battery efficiency and low latency?

## Answer

Comprehensive research has been concluded and documented in [`01-wearable-data-layer-sync.md`](../research/01-wearable-data-layer-sync.md).

### Summary of Decisions & Findings:
1. **Protocol Choice**:
   - **`DataClient` (Replicated State / `DataItem`)** is selected as the primary sync engine and offline buffer. It provides automatic offline persistence in Google Play Services SQLite, cross-reboot durability, and automatic sync over Bluetooth/Wi-Fi/Cloud relay when devices reconnect.
   - For state transitions (`START`, `STOP`, `PAUSE`), invoke `PutDataRequest.setUrgent()` to bypass Google Play Services' standard 30-minute batching window.
   - **`MessageClient` (RPC)** is used as an optional fast-path accelerator when connected for sub-30ms round-trip foreground start/stop interactions, but is never relied upon for state persistence.
   - **`ChannelClient`** is omitted for timer states due to stream setup overhead, remaining reserved for full historical SQLite database dumps.

2. **Ticking Timer Architecture & Zero-Poll Battery Optimization**:
   - **Zero network traffic during active tracking**: Never transmit 1-second ticks over Bluetooth. Instead, transmit a static anchor timestamp (`startedAtEpochMs`).
   - Both phone and watch compute elapsed time locally: $\text{elapsed} = \text{now} - \text{startedAtEpochMs} - \text{accumulatedPauseMs}$.
   - **Wear OS Surfaces**:
     - *Foreground Compose UI*: Driven by a local Compose `LaunchedEffect` 1-second ticker.
     - *Ambient Mode (AOD)*: Redraws once per minute from the anchor timestamp; 0 BLE radio wakeups.
     - *Wear OS Tiles*: Evaluated directly by the system launcher using Jetpack ProtoLayout dynamic expressions (`DynamicInstant` and `DynamicDuration`) without waking the app process.
     - *Watch Face Complications*: Rendered directly by the watch face system using `TimeDifferenceComplicationText` with `STYLE_STOPWATCH` (or `DynamicComplicationText`).

3. **Offline Buffering & Conflict Resolution**:
   - Fully standalone operation (e.g. running workout without phone) is supported. The watch creates records with local UUIDs and buffers them in local `DataClient` storage.
   - Upon reconnection, Google Play Services flushes changes automatically to the phone's native `WearableListenerService`.
   - Conflicts follow Last-Write-Wins (LWW) for the `ActiveTimer` pointer based on monotonic timestamps and revision numbers, while all completed `Record` events are append-only to ensure zero data loss.

See the full specification and citations in [`01-wearable-data-layer-sync.md`](../research/01-wearable-data-layer-sync.md).
