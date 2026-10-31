# 07: Wearable Data Layer Sync Service

Status: completed
Phase: 2 - Wear OS Companion
Dependencies: 01, 04

## Scope
Implement bidirectional synchronization between the Android phone app (Flutter) and Wear OS companion (Compose) using Google Play Services `DataClient`.

## Deliverables
- Wear OS background `WearableListenerService` listening for `DataItem` changes on `/timetracker/active_timer` and `/timetracker/activities`.
- Urgent transport dispatch (`PutDataRequest.setUrgent()`) on `START`/`STOP`/`PAUSE` state changes.
- Standalone offline queueing on watch: completed records buffered locally and flushed automatically upon BLE/Wi-Fi reconnection.
- Android Flutter platform channel bridge forwarding Wearable Data Layer events into Dart.
