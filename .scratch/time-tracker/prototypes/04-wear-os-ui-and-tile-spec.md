# Wear OS UI, Tile, and Complication Prototype Specification

## 1. Executive Summary & Design Principles

This specification directly eliminates the three primary failure modes of wearable time trackers:
1. **Friction in finding activities**: Swiping through endless tiles and scrolling long lists is replaced by a **Watch Face Complication shortcut** and a **Fixed 3-Slot Smart Tile** (Favorites + Contextual Recents).
2. **Accidental touches & sleeve bumps**: Accidental starts provide an **Undo Grace Window (3-second snack-pill)**; stopping a running session requires a **Guarded Long-Press (600ms)** to prevent accidental loss of hours of tracked time.
3. **App staying open and blocking notifications**: Tapping any quick-log action executes an **Action-and-Exit** pattern: it updates state, triggers crisp haptic feedback, flashes an 800ms visual confirmation, and **immediately calls `activity.finish()`** to return to the watch face. The app never idles in the foreground, ensuring all incoming notifications peek and vibrate normally.

---

## 2. Glanceable Surfaces Architecture

```
                    ┌─────────────────────────┐
                    │   Watch Face Surface    │
                    │                         │
                    │  [ ⏱️ 01:24 ] <────────┼─── Complication (Instant Ticker)
                    │   (Direct Tap)          │    - When idle: opens Quick-Log Sheet
                    └───────────┬─────────────┘    - When active: opens Active Session
                                │
                  Swipe Left    │ Tap Complication
                                ▼
         ┌──────────────────────────────┐
         │     Wear OS Smart Tile       │
         │  (Jetpack ProtoLayout 1.4)   │
         │                              │
         │  [ 🟢 Coding • 01:24 ]       │ <── Active Status Banner
         │                              │
         │  [ 🏋️ Workout   ] [ 📖 Read ] │ <── 2 Large Smart Slots (Pinned/Recents)
         │  [ 🧹 Chores    ] [ ➕ More ] │
         └──────────────┬───────────────┘
                        │
                        │ Tap "More" or Activity
                        ▼
         ┌──────────────────────────────┐
         │ Jetpack Compose Wear OS App  │
         │                              │
         │ 1. Quick-Log Action Sheet    │ ───> Tap Activity ───> [Haptic + 800ms Flash] ───> finish()
         │ 2. Active Session Sheet      │ ───> Guarded Stop (600ms Hold) ───> finish()
         └──────────────────────────────┘
```

---

## 3. The 3 Anti-Friction Solutions

### Solution A: Finding Activities Instantly (Smart Pinned Slots + Complication)
- **Watch Face Complication**:
  - Direct 1-tap entry point on the primary watch face.
  - When **Idle**: Renders `[▶️ Track]`. Tapping immediately launches the in-app Quick-Log Sheet centered on your top 3 pinned activities.
  - When **Active**: Renders real-time elapsed time `[⏱️ 42m]` via system `TimeDifferenceComplicationText` (no app wakeups). Tapping opens the Active Session Sheet.
- **Smart 3-Slot Tile**:
  - The Tile does **not** feature a scrollable list.
  - Displays a clean, circular-adapted layout:
    - **Header**: Active Timer banner (if tracking) or "Quick Log" label.
    - **Slot 1 (Primary)**: Pinned Favorite #1 (largest button, 52dp height).
    - **Slot 2 & 3**: Contextual Recents (based on time of day: morning habits vs evening pursuits).
    - **Slot 4**: "All Activities..." pill linking into the full list.

### Solution B: Accidental Touch Protection (Undo + Guarded Stop)
- **Accidental Start Mitigation (Undo Grace Window)**:
  - When an activity is started from a Tile or Quick Sheet, an overlay chip appears for 3,000ms:
    ```
    ┌───────────────────────┐
    │   🟢 Started Coding   │
    │      [ ↩️ UNDO ]      │
    └───────────────────────┘
    ```
  - Tapping **UNDO** immediately cancels the active timer, drops the record, and restores prior idle state without recording noise.
- **Accidental Stop Mitigation (Guarded Hold-to-Stop)**:
  - Tapping "Stop" on an active timer requires a **600ms Continuous Hold** with a radial fill animation and progressive haptic rumble:
    ```
    Tap & Hold:  [ ⏹️ STOP ( 20% ) ]  ──>  [ ⏹️ STOP ( 100% ) ] ──> Vibrates & Finishes
    Brief Brush: Ignored (Radial fill snaps back to 0% if finger lifts early).
    ```
  - Accidental sleeve brushes or brief bump contacts cannot kill a running timer.

### Solution C: Action-and-Exit (Preserving Incoming Notifications)
- **The Problem**: Wear OS suppresses notification peeks/alerts if an app process remains foregrounded.
- **The Protocol**:
  1. User taps activity slot.
  2. Watch writes state to local room/DataClient (`PutDataRequest.setUrgent()`).
  3. Device triggers haptic pulse (`HapticFeedbackConstants.CONFIRM`).
  4. UI renders an 800ms confirmation tick animation: `✓ Coding Started`.
  5. **`Activity.finish()` is called automatically**.
  6. Display returns to the native Watch Face.
  7. Wear OS notification manager resumes normal state; all incoming phone calls, Slack messages, and alerts display with full vibration.
- **Inactivity Timeout**: If the user opens the full activity picker and leaves the watch untouched for 10 seconds, `finish()` is automatically invoked.

---

## 4. Screen Layout & Component Wireframes

### Screen 1: Wear OS Tile (Idle State vs Active State)
```
          [ IDLE TILE ]                            [ ACTIVE TILE ]
     ┌───────────────────────┐                ┌───────────────────────┐
     │      Quick Start      │                │  🟢 Coding    01:24:18│
     │                       │                │  (Dynamic ProtoLayout)│
     │  ┌─────────────────┐  │                │  ┌─────────────────┐  │
     │  │  💻 Coding      │  │                │  │  ⏹️ Hold to Stop│  │
     │  └─────────────────┘  │                │  └─────────────────┘  │
     │  ┌─────────┐┌────────┐│                │  ┌─────────┐┌────────┐│
     │  │🏋️Workout││📖 Read ││                │  │  Switch ││ ➕ Note ││
     │  └─────────┘└────────┘│                │  └─────────┘└────────┘│
     │      [ More... ]      │                │      [ Details ]      │
     └───────────────────────┘                └───────────────────────┘
```

### Screen 2: Quick-Log App Sheet (Compose for Wear OS)
```
     ┌───────────────────────┐
     │      Select Habit     │
     │ ┌───────────────────┐ │
     │ │ ★ Coding          │ │  <-- Top Pinned (52dp, accent border)
     │ └───────────────────┘ │
     │ ┌───────────────────┐ │
     │ │ ★ Workout         │ │
     │ └───────────────────┘ │
     │ ┌───────────────────┐ │
     │ │ ★ Reading         │ │
     │ └───────────────────┘ │
     │   ▼ All (12 more)     │
     └───────────────────────┘
```

### Screen 3: Active Session (Large Elapsed Timer & Guarded Stop)
```
     ┌───────────────────────┐
     │       CODING          │
     │     01 : 24 : 18      │  <-- 32sp Mono Font
     │      started 2:15 PM  │
     │                       │
     │   ┌───────────────┐   │
     │   │ ⭕ HOLD STOP  │   │  <-- 600ms Radial Fill Button
     │   └───────────────┘   │
     │    [ ⏸️ Pause ]       │
     └───────────────────────┘
```

---

## 5. Jetpack Compose Technical Implementation Blueprint

```kotlin
// GuardedStopButton.kt
@Composable
fun GuardedStopButton(
    onStopConfirmed: () -> Unit,
    modifier: Modifier = Modifier
) {
    var isHolding by remember { mutableStateOf(false) }
    val progress by animateFloatAsState(
        targetValue = if (isHolding) 1f else 0f,
        animationSpec = tween(durationMillis = 600, easing = LinearEasing),
        finishedListener = { if (it >= 1f) onStopConfirmed() }
    )

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(Color(0xFF2C2C2E))
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        isHolding = true
                        tryAwaitRelease()
                        isHolding = false
                    }
                )
            }
    ) {
        // Radial / Linear progress track
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(progress)
                .background(Color(0xFFE53935))
                .align(Alignment.CenterStart)
        )
        Text(
            text = if (isHolding) "Hold to Stop..." else "Hold to Stop",
            color = Color.White,
            fontWeight = FontWeight.Bold
        )
    }
}
```

```kotlin
// QuickLogActivity.kt - Action and Exit
fun onActivitySelected(activity: ActivityModel) {
    viewLifecycleOwner.lifecycleScope.launch {
        // 1. Dispatch state to DataClient
        timerRepository.startTimer(activity.id)
        
        // 2. Immediate Haptic
        view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        
        // 3. Brief visual snackbar with Undo
        showUndoToast(activity)
        
        // 4. Return to watch face so notifications are not suppressed
        delay(800)
        finish()
    }
}
```

---

## 6. Verification & Usability Criteria
1. **Tile Glancability**: Finding and starting any of the 3 top activities requires $\le 2$ seconds from wrist raise.
2. **Notification Delivery**: Incoming phone and messaging notifications trigger immediate heads-up peeks within 1 second of logging an activity (0 notifications blocked by stalled app processes).
3. **Zero Accidental Kills**: Running timers survive brushing against gym equipment, jackets, or brief touch screen contact due to the 600ms continuous hold requirement.
