package com.tempos.tracker.wear

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
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
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * QuickLogActivity:
 * Labels the open Lap with one tap on an Activity and immediately finishes, so
 * the watch face returns and Wear OS keeps showing heads-up notifications.
 * The phone's 3-second UndoGraceWindow covers accidental labels.
 *
 * - Launched with [EXTRA_LABEL_ACTIVITY_ID] (tile slot): labels that Activity
 *   on launch and exits without drawing.
 * - Otherwise: shows the open Lap ("UNTRACKED · start") and its elapsed time,
 *   then the three most-used Activities as pills, then the rest.
 * - Inactivity timeout: 10s auto-exit.
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
            val activity = repository.activities.value.find { it.id == labelId }
                ?: WearActivity(id = labelId, name = labelId)
            val range = labeledRange(repository.lap.value)
            repository.label(activity.id)
            window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            setContent {
                LabelConfirmationScreen(activity, range) { finish() }
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

            QuickLogScreen(
                isAmbient = isAmbient,
                lap = lap,
                activities = activities,
                slotActivities = repository.tileActivities(),
                onActivitySelected = { activity ->
                    window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                    repository.label(activity.id)
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
fun LabelConfirmationScreen(activity: WearActivity, range: String, onDone: () -> Unit) {
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
        }
    }
}

/** How long the label confirmation stays on screen before Action-and-Exit. */
private const val CONFIRMATION_FLASH_MS = 300L

@Composable
fun QuickLogScreen(
    isAmbient: Boolean,
    lap: LapState,
    activities: List<WearActivity>,
    slotActivities: List<WearActivity>,
    onActivitySelected: (WearActivity) -> Unit,
    onFinish: () -> Unit
) {
    var elapsedMs by remember { mutableLongStateOf(lapElapsedMs(lap)) }
    var confirmed by remember { mutableStateOf<Pair<WearActivity, String>?>(null) }

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

    // Inactivity timeout: 10 seconds auto-exit if left untouched
    LaunchedEffect(Unit) {
        delay(10_000L)
        onFinish()
    }

    val select: (WearActivity) -> Unit = { activity ->
        val range = labeledRange(lap)
        onActivitySelected(activity)
        confirmed = activity to range
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Night),
        contentAlignment = Alignment.Center
    ) {
        if (isAmbient) {
            LapHeader(lap = lap, elapsedMs = elapsedMs, elapsedColor = Fog)
        } else {
            val others = activities.filter { candidate ->
                slotActivities.none { it.id == candidate.id }
            }

            ScalingLazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 26.dp, start = 14.dp, end = 14.dp, bottom = 26.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                item {
                    LapHeader(lap = lap, elapsedMs = elapsedMs, elapsedColor = Color.White)
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
            confirmed?.let { (activity, range) ->
                LabelConfirmationScreen(activity, range, onDone = onFinish)
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

/** "10:06–10:43": the open Lap's start in its own zone to now in the current zone. */
private fun labeledRange(lap: LapState): String {
    if (!lap.isOpen) return ""
    val now = System.currentTimeMillis()
    return "${clockTime(lap.startedAtEpochMs, lap.startedTimezoneId)}–${clockTime(now, "")}"
}

private fun clockTime(epochMs: Long, zoneId: String): String {
    val zone = try {
        if (zoneId.isEmpty()) ZoneId.systemDefault() else ZoneId.of(zoneId)
    } catch (_: Exception) {
        ZoneId.systemDefault()
    }
    return CLOCK.format(Instant.ofEpochMilli(epochMs).atZone(zone))
}

private val CLOCK = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

private fun lapElapsedMs(lap: LapState): Long {
    if (!lap.isOpen) return 0L
    val elapsed = System.currentTimeMillis() - lap.startedAtEpochMs
    return if (elapsed < 0L) 0L else elapsed
}

private fun formatElapsed(ms: Long): String {
    val totalMinutes = ms / 60_000
    return String.format(Locale.US, "%d:%02d", totalMinutes / 60, totalMinutes % 60)
}
