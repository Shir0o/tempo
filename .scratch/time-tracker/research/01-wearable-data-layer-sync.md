# Research: Wearable Data Layer Sync Protocol for Time Tracker

- **Topic**: Google Play Services Wearable Data Layer Sync Protocol & Architecture
- **Context**: Offline-first time tracker with Android Companion (Flutter) and Wear OS Watch (Jetpack Compose)
- **Author**: Antigravity Research Agent
- **Date**: 2026-10-31
- **Status**: Complete

---

## 1. Executive Summary & Core Architectural Decisions

Synchronizing an active time tracker between a mobile device (Android Flutter app) and a smartwatch (Wear OS Jetpack Compose app) introduces distinct constraints: battery conservation on the watch, instant UI feedback on 1-tap start/stop interactions, full offline operability (e.g., workouts or runs without a phone), and synchronization across watch faces, tiles, and the main UI.

### Key Architectural Recommendations:
1. **Primary Protocol**: Use **`DataClient` (DataItems)** as the foundational state replication store and offline buffer. Do not rely on `MessageClient` as the primary state sync mechanism, because `MessageClient` fails when devices are disconnected.
2. **Dual-Path Action Signaling**: Use **`DataClient` with `.setUrgent()`** for state synchronization (guaranteeing offline queuing and delivery). For instantaneous foreground start/stop clicks when a Bluetooth connection is active, optionally send an accompanying **`MessageClient` RPC** for sub-30ms round-trip execution.
3. **Zero-Poll Battery Optimization**: **Never stream 1-second timer ticks across the Bluetooth radio**. Transmit a single static anchor snapshot: `startedAtEpochMs`, `activityId`, and `status`. Both devices compute elapsed time locally using the formula $\text{now} - \text{startedAtEpochMs}$.
4. **Native Wear OS Surface Rendering**:
   - **Interactive Watch App**: Jetpack Compose `produceState` or Coroutine ticker running locally.
   - **Ambient Mode (Always-On Display)**: Redraw once per minute from the anchor timestamp; 0 BLE radio wakeups.
   - **Wear OS Tiles**: Jetpack ProtoLayout dynamic expressions (`DynamicInstant` and `DynamicDuration`), allowing the Wear OS launcher to render ticking seconds without waking the app process.
   - **Watch Face Complications**: `TimeDifferenceComplicationText` with `STYLE_STOPWATCH` (or `DynamicComplicationText`), natively updated by the watch face system service.
5. **Master / Replica Hierarchy**: The Android phone (Flutter + SQLite) acts as the system of record. The Wear OS watch functions as a high-speed peripheral and offline logging node, storing an offline action log that auto-reconciles with SQLite upon reconnect.

---

## 2. Google Play Services Wearable Data Layer API Evaluation

The Wearable Data Layer API provides three primary communication clients: `DataClient`, `MessageClient`, and `ChannelClient`, supplemented by `CapabilityClient` for node discovery.

### 2.1 Comparative Analysis

| Feature / Client | `DataClient` | `MessageClient` | `ChannelClient` | `CapabilityClient` |
| :--- | :--- | :--- | :--- | :--- |
| **Paradigm** | Distributed Replicated Key-Value (`DataItem`) | Remote Procedure Call (RPC) / Fire-and-forget | Bidirectional Stream (Byte pipe / File) | Topology & Service Discovery |
| **Persistence** | Persistent (stored in local Play Services SQLite) | Ephemeral (in-memory buffer only) | Ephemeral (open socket/pipe) | Ephemeral / Cached |
| **Offline Buffering** | **Yes** (automatic queuing & sync upon reconnection) | **No** (throws `TARGET_NODE_NOT_CONNECTED`) | **No** (stream closes on disconnect) | N/A |
| **Latency** | Medium (batching) to Low (<50ms with `setUrgent()`) | Very Low (<20ms over BLE) | Low to Medium | N/A |
| **Payload Size Limit** | 100 KB per `DataItem` | 100 KB per message | Unlimited (streamed via disk/memory) | Small capability strings |
| **Power Consumption** | Low (batched opportunistic sync; configurable) | Low per call, high if polled | High during active stream transfer | Negligible |
| **Recommended Role in Time Tracker** | **Primary state replication, active timer, recent activities list, offline action queue** | **Instant 1-tap start/stop signals when online, haptic triggers** | Not needed for active timers (reserved for full historical SQLite export/import) | **Pairing and discovery of active phone/watch node IDs** |

---

### 2.2 Deep Dive: `DataClient` (Replicated State)

- **Mechanisms**: Data is represented as a `DataItem` consisting of a URI path (e.g., `/time_tracker/active_timer`) and a binary payload, typically populated using `PutDataMapRequest`.
- **Synchronization Engine**: Managed by the Google Play Services background daemon (`com.google.android.gms`). Data is written locally first, then automatically synchronized across paired devices over Bluetooth Low Energy (BLE), local Wi-Fi, or Google Cloud Sync relay.
- **Offline Resilience**: If the user leaves their phone behind and starts/stops a timer on the watch, `DataClient.putDataItem()` writes immediately to the watch's local Play Services store. When the watch re-pairs with the phone, Play Services automatically flushes the changes without requiring custom networking logic.
- **Urgent Delivery (`.setUrgent()`)**:
  - *Standard behavior*: By default, `DataItem` sync can be delayed up to 30 minutes to batch radio packets and save battery.
  - *Urgent behavior*: Calling `.setUrgent()` on `PutDataRequest` instructs Play Services to initiate transport immediately.
  - *Rule*: Always invoke `.setUrgent()` for active timer transitions (`START`, `STOP`, `PAUSE`). For non-urgent metadata (e.g., updating the list of 20 available activities or color schemes), omit `setUrgent()` so the system batches it opportunistically.

```kotlin
// Example: Urgent DataItem Dispatch
val request = PutDataMapRequest.create("/time_tracker/active_timer").apply {
    dataMap.putString("timerId", timerId)
    dataMap.putString("activityId", activityId)
    dataMap.putString("activityName", activityName)
    dataMap.putLong("startedAtEpochMs", startedAtEpochMs)
    dataMap.putBoolean("isRunning", true)
    dataMap.putLong("lastModifiedEpochMs", System.currentTimeMillis())
}.asPutDataRequest().setUrgent()

Wearable.getDataClient(context).putDataItem(request)
```

---

### 2.3 Deep Dive: `MessageClient` (Low-Latency RPC)

- **Mechanisms**: Sends a byte array payload to a target node path using `sendMessage(nodeId, path, byteArray)` or `sendRequest(...)`.
- **Pros**: Minimal overhead, immediate transmission, direct response via Tasks/Coroutines.
- **Limitations**:
  - Requires target node connection. If the watch is standalone, calls fail.
  - Messages are not stored. If the receiving app process is dead and no `WearableListenerService` is registered, the message is dropped.
- **Usage in Time Tracker**:
  - Best used as a *latency accelerator*. When the watch user taps "Stop", the watch can dispatch a `MessageClient` message `/actions/stop` to the phone for instant UI reaction if connected, while simultaneously writing to `DataClient` for durable persistence.

---

### 2.4 Deep Dive: `ChannelClient` (Streaming)

- **Mechanisms**: Opens a direct `InputStream` / `OutputStream` channel or transfers files with `sendFile()`.
- **Verdict for Time Tracker**: Time tracker records and timer state payloads are minuscule (<1 KB). `DataItem` easily handles these payloads up to 100 KB. `ChannelClient` is unnecessary for normal operation, but can be utilized in the future for direct SQLite database backup file transfers.

---

### 2.5 Deep Dive: `CapabilityClient` (Service Discovery)

- In `res/values/wear.xml`, declare:
  ```xml
  <resources>
      <string-array name="android_wear_capabilities">
          <item name="time_tracker_companion" />
      </string-array>
  </resources>
  ```
- Before sending `MessageClient` commands, query `Wearable.getCapabilityClient(context).getCapability("time_tracker_companion", CapabilityClient.FILTER_REACHABLE)` to obtain reachable node IDs.

---

## 3. Recommended Architecture: Flutter (Android) <-> Jetpack Compose (Wear OS)

```
┌────────────────────────────────────────────────────────┐
│                   Android Phone                        │
│                                                        │
│  ┌─────────────────────────┐                           │
│  │    Flutter UI (Dart)    │                           │
│  │   ActiveTimer / SQLite  │                           │
│  └────────────▲────────────┘                           │
│               │ MethodChannel / EventChannel           │
│  ┌────────────▼────────────┐                           │
│  │ Native Android Host (Kt)│                           │
│  │ WearableListenerService │                           │
│  └────────────▲────────────┘                           │
│               │ Google Play Services DataLayer         │
└───────────────┼────────────────────────────────────────┘
                │ Bluetooth LE / Wi-Fi / Cloud Sync
┌───────────────┼────────────────────────────────────────┐
│               │ Google Play Services DataLayer         │
│  ┌────────────▼────────────┐                           │
│  │ Native Wear OS (Kotlin) │                           │
│  │ WearableListenerService │                           │
│  └────────────▲────────────┘                           │
│               │ Coroutine StateFlow                    │
│  ┌────────────┼───────────────────────────┐            │
│  │            │                           │            │
│  ▼            ▼                           ▼            │
│┌───────────┐ ┌─────────────────────────┐ ┌───────────┐ │
││Compose App│ │Wear OS Tile(ProtoLayout)│ │Complication││
│└───────────┘ └─────────────────────────┘ └───────────┘ │
│                  Wear OS Smartwatch                    │
└────────────────────────────────────────────────────────┘
```

### 3.1 Responsibilities & Authority

1. **Phone (Authority / Master)**:
   - Houses the definitive SQLite database storing all Activities, Tags, and Records.
   - Publishes the current `ActiveTimer` state to `DataClient` at `/time_tracker/active_timer`.
   - Publishes recent Activities (id, name, colorHex) to `DataClient` at `/time_tracker/activities_summary`.
   - Ingests completed Record actions synced from the watch.
2. **Watch (Edge Companion & Offline Logger)**:
   - Maintains a lightweight local cache (Room or Proto DataStore) of recent Activities and ActiveTimer state.
   - Displays real-time elapsed time on 3 native surfaces:
     - Foreground Jetpack Compose app.
     - Glanceable Wear OS Tile (ProtoLayout).
     - Watch Face Complication (`TimeDifferenceComplicationText`).
   - Allows 1-tap start/stop, continuing to function seamlessly offline.

---

### 3.2 Canonical Data Schema

#### A. Active Timer State (`/time_tracker/active_timer`)
Synced via `DataClient` with `.setUrgent()`.

```json
{
  "timerId": "8f1a23c0-4567-4890-a123-bcdef0123456",
  "activityId": "act_coding",
  "activityName": "Coding",
  "activityColorHex": "#2563EB",
  "startedAtEpochMs": 1730361600000,
  "state": "RUNNING", // "IDLE" | "RUNNING" | "PAUSED"
  "accumulatedPauseMs": 0,
  "revision": 104,
  "updatedAtEpochMs": 1730361600120,
  "sourceDeviceId": "phone_pixel8"
}
```

#### B. Recent Activities Summary (`/time_tracker/activities_summary`)
Synced via `DataClient` (opportunistic / non-urgent).

```json
{
  "updatedAtEpochMs": 1730361000000,
  "activities": [
    { "id": "act_coding", "name": "Coding", "colorHex": "#2563EB" },
    { "id": "act_workout", "name": "Workout", "colorHex": "#10B981" },
    { "id": "act_reading", "name": "Reading", "colorHex": "#F59E0B" },
    { "id": "act_meeting", "name": "Meeting", "colorHex": "#8B5CF6" }
  ]
}
```

#### C. Watch Action Queue (`/time_tracker/actions/{actionId}`)
Used when the watch generates an action offline.

```json
{
  "actionId": "act_evt_99812",
  "type": "STOP_TIMER", // "START_TIMER" | "STOP_TIMER" | "SWITCH_ACTIVITY"
  "timerId": "8f1a23c0-4567-4890-a123-bcdef0123456",
  "activityId": "act_workout",
  "timestampEpochMs": 1730365200000,
  "sourceDeviceId": "watch_pixelwatch2"
}
```

---

## 4. Battery Optimization & Zero-Polling Active Timer Execution

### 4.1 The Cost of Polling vs. Anchor Timestamp

- **The Polling Anti-Pattern**: If the phone or watch pushes Bluetooth packets once per second to "tick" the timer:
  - BLE radio enters high-power transmission state 3,600 times per hour.
  - Device CPU wakes up and prevents deep sleep / low-power Doze states.
  - Result: The watch battery depletes in **under 4 to 5 hours**.
- **The Anchor Timestamp Solution**:
  - The phone transmits **one single packet** when the timer starts (`startedAtEpochMs`).
  - While the timer runs, **zero network packets are transmitted**.
  - Elapsed duration is calculated deterministically on the client device:
    $$\text{Elapsed}(t) = t_{\text{current}} - \text{startedAtEpochMs} - \text{accumulatedPauseMs}$$

---

### 4.2 Rendering Across 4 Wear OS Surfaces Without Polling

#### 1. Interactive Watch App (Foreground Compose)
When the user opens the watch app, we run a local Compose timer. No Bluetooth transmission occurs:

```kotlin
@Composable
fun ActiveTimerScreen(startedAtEpochMs: Long, isRunning: Boolean) {
    var elapsedMs by remember { mutableLongStateOf(System.currentTimeMillis() - startedAtEpochMs) }

    LaunchedEffect(isRunning, startedAtEpochMs) {
        if (!isRunning) return@LaunchedEffect
        while (isActive) {
            elapsedMs = System.currentTimeMillis() - startedAtEpochMs
            delay(1000L) // Local 1-second UI tick on device CPU
        }
    }

    Text(
        text = formatDuration(elapsedMs),
        style = MaterialTheme.typography.displayMedium
    )
}
```

#### 2. Ambient Mode (Always-On Display)
In ambient mode (watch wrist lowered, display dimmed):
- Redraw frequency is capped by the system to **once every 60 seconds**.
- The ambient observer (`AmbientLifecycleObserver`) triggers a redraw once per minute.
- Seconds are omitted, displaying `HH:mm`.
- Computation is purely local against system time; Bluetooth radio remains in deep sleep.

#### 3. Wear OS Tiles (Jetpack ProtoLayout Dynamic Expressions)
Wear OS Tiles are hosted by the system system UI launcher. ProtoLayout provides **dynamic time expressions** (`DynamicInstant` and `DynamicDuration`):

```kotlin
// In ProtoLayout Tile Builder:
val startedInstant = Instant.ofEpochMilli(startedAtEpochMs)
val dynamicTimeDiff = DynamicInstant.platformTimeWithSecondsPrecision()
    .durationUntil(DynamicInstant.withSecondsPrecision(startedInstant))

Text.Builder(context, "")
    .setContentDescription("Running timer duration")
    .setStringContent(
        DynamicBuilders.DynamicString.onCondition(dynamicTimeDiff)
            // Evaluated directly in hardware/display pipeline
            .formatDuration()
    )
    .build()
```
*Result*: The timer digits increment smoothly on the Tile without waking up your app's background process or triggering CPU execution.

#### 4. Watch Face Complications
Wear OS complications provide built-in stopwatch countdown/countup rendering:

```kotlin
val timeDifferenceText = TimeDifferenceComplicationText.Builder(
    /* referencePeriodStartMillis = */ startedAtEpochMs,
    /* referencePeriodEndMillis = */ Long.MAX_VALUE
)
    .setStyle(TimeDifferenceComplicationText.STYLE_STOPWATCH)
    .setShowNowText(true)
    .build()

ShortTextComplicationData.Builder(
    text = timeDifferenceText,
    contentDescription = PlainComplicationText.Builder("Timer").build()
)
    .setMonochromaticImage(stopwatchIcon)
    .setTapAction(openAppPendingIntent)
    .build()
```
*Result*: The watch face framework updates the complication text in real time with hardware-accelerated time formatting and zero battery penalty.

---

## 5. Offline Buffering, Network Disconnects & Conflict Resolution

### 5.1 Disconnected Scenarios

#### Scenario A: Standalone Workout (Phone left behind)
1. User starts "Workout" on watch.
2. Watch checks network/nodes via `CapabilityClient`. Phone is unreachable.
3. Watch immediately updates its local state:
   - Sets local `ActiveTimer` = `{ activity: "Workout", startedAt: now, isRunning: true }`.
   - Tile and Complication start ticking immediately (optimistic UI update).
4. Watch calls `DataClient.putDataItem(request.setUrgent())`.
5. Google Play Services saves the `DataItem` in its local persistent store on the watch.
6. When workout is finished, user taps "Stop". Watch creates a Record event `{ id: UUID, activity: "Workout", start: T1, end: T2 }`.
7. Watch reconnects to phone via Bluetooth hours later:
   - Google Play Services automatically detects the connection and syncs all buffered `DataItems`.
   - Phone's `WearableListenerService` receives `onDataChanged`.
   - Phone inserts the completed Record into SQLite.

#### Scenario B: Simultaneous Start / Split-Brain
What happens if the phone starts "Coding" at 10:00:00, while the offline watch starts "Reading" at 10:00:05?

**Conflict Resolution Rules:**
1. **Monotonic Revisions & Timestamps**: Every state change contains `updatedAtEpochMs` and a monotonic `revision` counter.
2. **Last-Write-Wins (LWW) for ActiveTimer**: When synchronization occurs, the higher `updatedAtEpochMs` becomes the current `ActiveTimer`.
3. **Zero Data Loss for Records**:
   - Any timer stopped offline is saved as a durable `Record` entity with its unique UUID.
   - When conflicting records overlap in time (e.g. Phone logged 10:00–10:30 Coding; Watch logged 10:05–10:25 Reading), both records are retained in the SQLite database.
   - An `isReconciled: false` or overlap tag can be attached, allowing the user to review or keep both entries. No tracked time is ever silently discarded.

---

## 6. Integration Bridge: Flutter Android Host to Wear OS

### 6.1 Android Phone: Native Plugin Bridge
Because Flutter Dart cannot directly register a persistent Android background service that Google Play Services can invoke when the Flutter engine is dead, a clean native Android module is required:

1. **`TimeTrackerWearService : WearableListenerService()`**:
   - Registered in `AndroidManifest.xml` with `<action android:name="com.google.android.gms.wearable.DATA_CHANGED" />`.
   - When `onDataChanged` triggers from watch actions:
     - If Flutter Engine is alive: Send payload via `EventChannel` or `MethodChannel.invokeMethod("onWearActionReceived", data)`.
     - If Flutter Engine is dead: Update native SharedPreferences / lightweight SQLite queue and optionally launch a background WorkManager or headless Flutter background task.

2. **Flutter Dart Platform Channel Contract**:
   ```dart
   // Dart Interface
   abstract class WearDataLayerBridge {
     Future<void> syncActiveTimer(ActiveTimer? timer);
     Future<void> syncActivities(List<Activity> activities);
     Stream<WearAction> get incomingActions;
   }
   ```

### 6.2 Wear OS: Modern Kotlin Stack with Horologist
On the Wear OS companion app, use Google's **Horologist DataLayer** (`com.google.android.horologist:horologist-datalayer-watch`):
- Wraps `DataClient` in Kotlin `Flow<DataItem>` and Coroutines.
- Integrates with Proto DataStore for typesafe state handling.
- Simplifies node reachability queries.

---

## 7. Primary Source Citations & References

1. **Android Developers - Wearable Data Layer API**:
   - *Overview & Best Practices*: [developer.android.com/training/wearables/data-layer](https://developer.android.com/training/wearables/data-layer)
   - *Accessing Data Items (`DataClient`)*: [developer.android.com/training/wearables/data-layer/data-items](https://developer.android.com/training/wearables/data-layer/data-items)
   - *Sending and Receiving Messages (`MessageClient`)*: [developer.android.com/training/wearables/data-layer/messages](https://developer.android.com/training/wearables/data-layer/messages)
   - *Transferring Assets & Streams (`ChannelClient`)*: [developer.android.com/training/wearables/data-layer/assets](https://developer.android.com/training/wearables/data-layer/assets)
2. **Urgent Delivery (`PutDataRequest.setUrgent()`)**:
   - *Android API Reference*: [developer.android.com/reference/com/google/android/gms/wearable/PutDataRequest#setUrgent()](https://developer.android.com/reference/com/google/android/gms/wearable/PutDataRequest#setUrgent())
3. **Jetpack ProtoLayout Dynamic Expressions (Tiles)**:
   - *Dynamic Expressions in Wear OS*: [developer.android.com/training/wearables/protolayout/dynamic-expressions](https://developer.android.com/training/wearables/protolayout/dynamic-expressions)
   - *ProtoLayout DynamicBuilders & DynamicInstant*: [developer.android.com/reference/androidx/wear/protolayout/expression/DynamicBuilders](https://developer.android.com/reference/androidx/wear/protolayout/expression/DynamicBuilders)
4. **Wear OS Watch Face Complications**:
   - *TimeDifferenceComplicationText*: [developer.android.com/reference/androidx/wear/watchface/complications/data/TimeDifferenceComplicationText](https://developer.android.com/reference/androidx/wear/watchface/complications/data/TimeDifferenceComplicationText)
   - *Complication Styles & Formatting*: [developer.android.com/training/wearables/watch-faces/complications](https://developer.android.com/training/wearables/watch-faces/complications)
5. **Google Horologist Project**:
   - *Horologist DataLayer Library*: [google.github.io/horologist/datalayer](https://google.github.io/horologist/datalayer)
   - *GitHub Repository*: [github.com/google/horologist](https://github.com/google/horologist)
