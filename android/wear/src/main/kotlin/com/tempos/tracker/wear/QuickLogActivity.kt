package com.tempos.tracker.wear

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.wear.ambient.AmbientLifecycleObserver
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * QuickLogActivity:
 * Labels the open Lap with one tap on an Activity and immediately finishes, so
 * the watch face returns and Wear OS keeps showing heads-up notifications.
 * The phone's 3-second UndoGraceWindow covers accidental labels.
 *
 * - Launched with [EXTRA_LABEL_ACTIVITY_ID] (tile slot): labels that Activity
 *   on launch and exits without drawing.
 * - Otherwise: shows the open Lap ("UNTRACKED · start") and its elapsed time,
 *   then "Still <Activity>" and "<Activity> again" for the last Activity,
 *   then the three most-used Activities as pills, then the rest.
 * - Inactivity timeout: 10s without a touch or scroll auto-exits.
 */
class QuickLogActivity : ComponentActivity() {

    companion object {
        const val EXTRA_LABEL_ACTIVITY_ID = "EXTRA_LABEL_ACTIVITY_ID"
    }

    private var isAmbientState = mutableStateOf(false)

    private val ambientCallback = object : AmbientLifecycleObserver.AmbientLifecycleCallback {
        override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
            isAmbientState.value = true
        }

        override fun onExitAmbient() {
            isAmbientState.value = false
        }

        override fun onUpdateAmbient() {
            // Low-power periodic refresh in ambient mode
        }
    }

    private val ambientObserver = AmbientLifecycleObserver(this, ambientCallback)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(ambientObserver)

        val repository = WearLapRepository.getInstance(this)

        // A tile slot names its Activity: label the Lap, confirm, and exit.
        val labelId = intent?.getStringExtra(EXTRA_LABEL_ACTIVITY_ID)
        if (!labelId.isNullOrEmpty()) {
            // The launch intent is re-delivered when the Activity is recreated
            // (a configuration change, or the watch waking from ambient). One
            // tap labels once: a second label would close a zero-length Record
            // on the phone.
            if (savedInstanceState != null) {
                finish()
                return
            }
            val activity = repository.activities.value.find { it.id == labelId }
                ?: WearActivity(id = labelId, name = labelId)
            val labeled = labeledSpan(repository.lap.value)
            intent?.removeExtra(EXTRA_LABEL_ACTIVITY_ID)
            repository.label(activity.id)
            window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            setContent {
                LabelConfirmationScreen(activity, labeled.range, labeled.overnight) { finish() }
            }
            return
        }

        // Wear OS 4+: the ongoing Lap notification needs POST_NOTIFICATIONS.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                if (granted) repository.notifySurfaces()
            }.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        setContent {
            val isAmbient by remember { isAmbientState }
            val lap by repository.lap.collectAsState()
            val activities by repository.activities.collectAsState()
            val lastActivity by repository.lastActivity.collectAsState()

            QuickLogScreen(
                isAmbient = isAmbient,
                lap = lap,
                activities = activities,
                slotActivities = repository.tileActivities(),
                lastActivity = lastActivity,
                onActivitySelected = { activity ->
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    repository.label(activity.id)
                },
                onStillSelected = {
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    repository.continueLast()
                },
                onAgainSelected = {
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    repository.labelLast()
                },
                onFinish = {
                    finish()
                }
            )
        }
    }
}

// Design D tokens (DESIGN.md).
private val Night = Color(0xFF0B0B0A)
private val Ink = Color(0xFF121210)
private val Lime = Color(0xFFC6F432)
private val Fog = Color(0xFFA8A8A8)

/** Space Grotesk (bundled variable font), pinned to each weight the watch uses. */
@OptIn(ExperimentalTextApi::class)
private val SpaceGrotesk = FontFamily(
    listOf(FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold).map { weight ->
        Font(
            R.font.space_grotesk,
            weight = weight,
            variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight))
        )
    }
)

/** Tabular figures so live times don't jitter. */
private const val TABULAR = "tnum"

/**
 * The brief lime flash shown before the Activity exits, so the user sees what
 * they labelled and the range it covers while the watch face returns.
 */
@Composable
fun LabelConfirmationScreen(
    activity: WearActivity,
    range: String,
    overnight: String? = null,
    verb: String? = null,
    onDone: () -> Unit
) {
    LaunchedEffect(Unit) {
        delay(CONFIRMATION_FLASH_MS)
        onDone()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Lime),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 20.dp)
        ) {
            Canvas(modifier = Modifier.size(28.dp)) {
                val path = Path().apply {
                    moveTo(size.width * 0.16f, size.height * 0.52f)
                    lineTo(size.width * 0.40f, size.height * 0.76f)
                    lineTo(size.width * 0.86f, size.height * 0.26f)
                }
                drawPath(
                    path = path,
                    color = Ink,
                    style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                )
            }
            Spacer(modifier = Modifier.height(6.dp))
            if (verb != null) {
                Text(
                    text = verb,
                    color = Ink.copy(alpha = 0.6f),
                    fontFamily = SpaceGrotesk,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.08.em
                )
            }
            Text(
                text = activity.name,
                color = Ink,
                fontFamily = SpaceGrotesk,
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.03).em,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (range.isNotEmpty()) {
                Text(
                    text = range,
                    color = Ink,
                    fontFamily = SpaceGrotesk,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    style = TextStyle(fontFeatureSettings = TABULAR)
                )
            }
            if (overnight != null) {
                Text(
                    text = overnight,
                    color = Ink,
                    fontFamily = SpaceGrotesk,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    style = TextStyle(fontFeatureSettings = TABULAR)
                )
            }
        }
    }
}

/** How long the label confirmation stays on screen before Action-and-Exit. */
private const val CONFIRMATION_FLASH_MS = 900L

/** How long the list waits with no touch or scroll before Action-and-Exit. */
private const val IDLE_TIMEOUT_MS = 10_000L

/** How often the idle check runs. */
private const val IDLE_POLL_MS = 500L

@Composable
fun QuickLogScreen(
    isAmbient: Boolean,
    lap: LapState,
    activities: List<WearActivity>,
    slotActivities: List<WearActivity>,
    lastActivity: WearActivity?,
    onActivitySelected: (WearActivity) -> Unit,
    onStillSelected: () -> Unit,
    onAgainSelected: () -> Unit,
    onFinish: () -> Unit
) {
    var elapsedMs by remember { mutableLongStateOf(lapElapsedMs(lap)) }
    var confirmed by remember { mutableStateOf<LabelConfirmation?>(null) }

    // Action-and-Exit still applies, but only after real inactivity: a touch, a
    // scroll or the rotating crown counts as use and restarts the countdown, so
    // the list never closes while it is being read. Ambient is not use — the
    // wrist is down — so the timeout keeps running there and the Activity never
    // lingers in the foreground.
    val lastInteractionMs = remember { AtomicLong(SystemClock.elapsedRealtime()) }
    LaunchedEffect(isAmbient) {
        if (!isAmbient) lastInteractionMs.set(SystemClock.elapsedRealtime())
    }
    LaunchedEffect(Unit) {
        while (isActive) {
            delay(IDLE_POLL_MS)
            if (SystemClock.elapsedRealtime() - lastInteractionMs.get() >= IDLE_TIMEOUT_MS) {
                onFinish()
                break
            }
        }
    }

    // Interactive 1-second ticker loop (local CPU only, no BLE wakeups)
    LaunchedEffect(isAmbient, lap.startedAtEpochMs) {
        if (!isAmbient && lap.isOpen) {
            while (isActive) {
                elapsedMs = lapElapsedMs(lap)
                delay(1000L)
            }
        } else {
            elapsedMs = lapElapsedMs(lap)
        }
    }

    val listState = rememberScalingLazyListState()
    LaunchedEffect(listState) {
        snapshotFlow { listState.centerItemIndex to listState.centerItemScrollOffset }
            .collect { lastInteractionMs.set(SystemClock.elapsedRealtime()) }
    }

    val select: (WearActivity) -> Unit = { activity ->
        val labeled = labeledSpan(lap)
        onActivitySelected(activity)
        confirmed = LabelConfirmation(activity, labeled)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Night)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        awaitPointerEvent(PointerEventPass.Initial)
                        lastInteractionMs.set(SystemClock.elapsedRealtime())
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        if (isAmbient) {
            LapHeader(lap = lap, elapsedMs = elapsedMs, elapsedColor = Fog)
        } else {
            val others = activities
                .filter { candidate -> slotActivities.none { it.id == candidate.id } }
                .sortedBy { it.name.lowercase(Locale.US) }

            ScalingLazyColumn(
                modifier = Modifier.fillMaxSize(),
                state = listState,
                contentPadding = PaddingValues(top = 26.dp, start = 14.dp, end = 14.dp, bottom = 26.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                item {
                    LapHeader(lap = lap, elapsedMs = elapsedMs, elapsedColor = Color.White)
                }

                // The phone's two repeat buttons, on top of the Activity pills:
                // "Still <Activity>" grows the last Record, "<Activity> again"
                // starts a new one.
                val last = lastActivity
                if (last != null) {
                    item {
                        RepeatActions(
                            last = last,
                            onStill = {
                                val labeled = labeledSpan(lap)
                                onStillSelected()
                                confirmed = LabelConfirmation(last, labeled, "STILL")
                            },
                            onAgain = {
                                val labeled = labeledSpan(lap)
                                onAgainSelected()
                                confirmed = LabelConfirmation(last, labeled, "AGAIN")
                            }
                        )
                    }
                }

                // The three most-used Activities, the same slots as the tile.
                items(slotActivities) { activity ->
                    ActivityPill(activity = activity, onClick = { select(activity) })
                }

                if (others.isNotEmpty()) {
                    item {
                        Text(
                            text = "All activities",
                            color = Fog,
                            fontFamily = SpaceGrotesk,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(top = 8.dp, bottom = 2.dp)
                        )
                    }

                    items(others) { activity ->
                        ActivityPill(activity = activity, onClick = { select(activity) })
                    }
                }
            }

            // Brief confirmation, then Action-and-Exit to the watch face.
            confirmed?.let { confirmation ->
                LabelConfirmationScreen(
                    confirmation.activity,
                    confirmation.labeled.range,
                    confirmation.labeled.overnight,
                    verb = confirmation.verb,
                    onDone = onFinish
                )
            }
        }
    }
}

/** "UNTRACKED · 10:06" overline (Lap start, its own zone) over the elapsed time. */
@Composable
private fun LapHeader(lap: LapState, elapsedMs: Long, elapsedColor: Color) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
    ) {
        Text(
            text = if (lap.isOpen) "UNTRACKED · ${clockTime(lap.startedAtEpochMs, lap.startedTimezoneId)}" else "UNTRACKED",
            color = Fog,
            fontFamily = SpaceGrotesk,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.08.em,
            style = TextStyle(fontFeatureSettings = TABULAR)
        )
        Text(
            text = if (lap.isOpen) formatElapsed(elapsedMs) else "--:--",
            color = elapsedColor,
            fontFamily = SpaceGrotesk,
            fontSize = 30.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = (-0.04).em,
            style = TextStyle(fontFeatureSettings = TABULAR)
        )
    }
}

/**
 * The phone's two repeat buttons: "Still <Activity>" grows the last Record,
 * "<Activity> again" starts a new one. Side by side to match the Today panel.
 */
@Composable
private fun RepeatActions(
    last: WearActivity,
    onStill: () -> Unit,
    onAgain: () -> Unit
) {
    val fill = remember(last.colorHex) {
        try {
            Color(android.graphics.Color.parseColor(last.colorHex))
        } catch (_: Exception) {
            Fog
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(
            modifier = Modifier
                .weight(1f)
                .height(40.dp)
                .clip(CircleShape)
                .background(fill)
                .clickable(onClick = onStill)
                .padding(horizontal = 10.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "Still ${last.name}",
                color = Ink,
                fontFamily = SpaceGrotesk,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .height(40.dp)
                .clip(CircleShape)
                .border(1.dp, Fog, CircleShape)
                .clickable(onClick = onAgain)
                .padding(horizontal = 10.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "${last.name} again",
                color = Color.White,
                fontFamily = SpaceGrotesk,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/** One Activity: a pill in its own colour with ink text. */
@Composable
fun ActivityPill(
    activity: WearActivity,
    onClick: () -> Unit
) {
    val fill = remember(activity.colorHex) {
        try {
            Color(android.graphics.Color.parseColor(activity.colorHex))
        } catch (_: Exception) {
            Fog
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .height(44.dp)
            .clip(CircleShape)
            .background(fill)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Text(
            text = activity.name,
            color = Ink,
            fontFamily = SpaceGrotesk,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

/** The confirmation's time lines: the range, plus an overnight sum when it crosses 00:00. */
private data class LabeledSpan(val range: String, val overnight: String? = null)

/** What the brief confirmation shows: the Activity, its span and the verb. */
private data class LabelConfirmation(
    val activity: WearActivity,
    val labeled: LabeledSpan,
    val verb: String? = null
)

/**
 * "10:06–10:43": the open Lap's start in its own zone to now in the current
 * zone. A Lap that crossed local midnight is written as two or more Records;
 * [LabeledSpan.overnight] then carries each slice and their sum, so the whole
 * label is readable in one glance.
 */
private fun labeledSpan(lap: LapState, now: Long = System.currentTimeMillis()): LabeledSpan {
    if (!lap.isOpen) return LabeledSpan("")
    val range = "${clockTime(lap.startedAtEpochMs, lap.startedTimezoneId)}–${clockTime(now, "")}"
    return LabeledSpan(range, overnightSum(lap.startedAtEpochMs, now, lap.startedTimezoneId))
}

private fun overnightSum(startedAt: Long, now: Long, timezoneId: String): String? {
    if (now <= startedAt) return null
    val zone = zoneOf(timezoneId)
    val parts = mutableListOf<Long>()
    var cursor = startedAt
    while (true) {
        val midnight = Instant.ofEpochMilli(cursor)
            .atZone(zone)
            .toLocalDate()
            .plusDays(1)
            .atStartOfDay(zone)
            .toInstant()
            .toEpochMilli()
        if (midnight >= now) break
        parts.add(midnight - cursor)
        cursor = midnight
    }
    if (parts.isEmpty()) return null
    parts.add(now - cursor)
    return parts.joinToString(" + ") { formatDuration(it) } +
        " = " + formatDuration(now - startedAt)
}

private fun zoneOf(zoneId: String): ZoneId {
    return try {
        if (zoneId.isEmpty()) ZoneId.systemDefault() else ZoneId.of(zoneId)
    } catch (_: Exception) {
        ZoneId.systemDefault()
    }
}

private fun clockTime(epochMs: Long, zoneId: String): String {
    return CLOCK.format(Instant.ofEpochMilli(epochMs).atZone(zoneOf(zoneId)))
}

private val CLOCK = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

private fun formatDuration(ms: Long): String {
    val totalMinutes = ms.coerceAtLeast(0L) / 60_000
    val hours = totalMinutes / 60
    val minutes = totalMinutes % 60
    return when {
        hours > 0 && minutes > 0 -> "${hours}h ${minutes}m"
        hours > 0 -> "${hours}h"
        totalMinutes > 0 -> "${minutes}m"
        else -> "${(ms / 1_000).coerceAtLeast(1L)}s"
    }
}

private fun lapElapsedMs(lap: LapState): Long {
    if (!lap.isOpen) return 0L
    val elapsed = System.currentTimeMillis() - lap.startedAtEpochMs
    return if (elapsed < 0L) 0L else elapsed
}

private fun formatElapsed(ms: Long): String {
    val totalMinutes = ms / 60_000
    return String.format(Locale.US, "%d:%02d", totalMinutes / 60, totalMinutes % 60)
}
