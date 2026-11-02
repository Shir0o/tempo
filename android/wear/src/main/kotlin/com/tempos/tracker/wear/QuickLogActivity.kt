package com.tempos.tracker.wear

import android.os.Bundle
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.ambient.AmbientLifecycleObserver
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.util.Locale

/**
 * QuickLogActivity:
 * Labels the open Lap with one tap on an Activity and immediately finishes, so
 * the watch face returns and Wear OS keeps showing heads-up notifications.
 * The phone's 3-second UndoGraceWindow covers accidental labels.
 *
 * - Launched with [EXTRA_LABEL_ACTIVITY_ID] (tile slot): labels that Activity
 *   on launch and exits without drawing.
 * - Otherwise: shows the three most-used Activities first, then the rest.
 * - Inactivity timeout: 10s auto-exit.
 */
class QuickLogActivity : ComponentActivity() {

    companion object {
        const val EXTRA_LABEL_ACTIVITY_ID = "EXTRA_LABEL_ACTIVITY_ID"

        /** Retired tile builds sent the same id under this name. */
        private const val LEGACY_EXTRA_START_ACTIVITY_ID = "EXTRA_START_ACTIVITY_ID"
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
            ?: intent?.getStringExtra(LEGACY_EXTRA_START_ACTIVITY_ID)
        if (!labelId.isNullOrEmpty()) {
            val activity = repository.activities.value.find { it.id == labelId }
                ?: WearActivity(id = labelId, name = labelId)
            repository.label(activity.id)
            window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            setContent {
                LabelConfirmationScreen(activity) { finish() }
            }
            return
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

/**
 * The brief visual confirmation shown before the Activity exits, so the user
 * sees what they labelled while the watch face returns.
 */
@Composable
fun LabelConfirmationScreen(activity: WearActivity, onDone: () -> Unit) {
    LaunchedEffect(Unit) {
        delay(CONFIRMATION_FLASH_MS)
        onDone()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "✓",
                color = Color(0xFF22C55E),
                fontSize = 34.sp,
                fontWeight = FontWeight.ExtraBold
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = activity.name,
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
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
    var confirmed by remember { mutableStateOf<WearActivity?>(null) }

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

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        if (isAmbient) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    text = "TEMPO",
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = if (lap.isOpen) formatElapsed(elapsedMs) else "No Lap",
                    color = Color.Gray,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace
                )
            }
        } else {
            val others = activities.filter { candidate ->
                slotActivities.none { it.id == candidate.id }
            }

            ScalingLazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 26.dp, start = 12.dp, end = 12.dp, bottom = 26.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                item {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 6.dp)
                    ) {
                        Text(
                            text = "LAP ${formatElapsed(elapsedMs)}",
                            color = Color(0xFF4ADE80),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace
                        )
                        Text(
                            text = "What was it?",
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            textAlign = TextAlign.Center
                        )
                    }
                }

                // The three most-used Activities, the same slots as the tile.
                items(slotActivities) { activity ->
                    ActivityChip(
                        activity = activity,
                        isPrimary = true,
                        onClick = {
                            onActivitySelected(activity)
                            confirmed = activity
                        }
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                }

                if (others.isNotEmpty()) {
                    item {
                        Text(
                            text = "All Activities",
                            color = Color(0xFFAAAAAA),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)
                        )
                    }

                    items(others) { activity ->
                        ActivityChip(
                            activity = activity,
                            isPrimary = false,
                            onClick = {
                                onActivitySelected(activity)
                                confirmed = activity
                            }
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                    }
                }
            }

            // Brief confirmation, then Action-and-Exit to the watch face.
            confirmed?.let { activity ->
                LabelConfirmationScreen(activity, onDone = onFinish)
            }
        }
    }
}

@Composable
fun ActivityChip(
    activity: WearActivity,
    isPrimary: Boolean,
    onClick: () -> Unit
) {
    val accentColor = remember(activity.colorHex) {
        try {
            Color(android.graphics.Color.parseColor(activity.colorHex))
        } catch (_: Exception) {
            Color(0xFF3B82F6)
        }
    }

    Chip(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp), // >= 52dp touch target
        colors = ChipDefaults.chipColors(
            backgroundColor = if (isPrimary) Color(0xFF1F2430) else Color(0xFF18181B),
            contentColor = Color.White
        ),
        label = {
            Text(
                text = activity.name,
                fontSize = 14.sp,
                fontWeight = if (isPrimary) FontWeight.Bold else FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        },
        icon = {
            Box(
                modifier = Modifier
                    .size(14.dp)
                    .clip(CircleShape)
                    .background(accentColor)
            )
        }
    )
}

private fun lapElapsedMs(lap: LapState): Long {
    if (!lap.isOpen) return 0L
    val elapsed = System.currentTimeMillis() - lap.startedAtEpochMs
    return if (elapsed < 0L) 0L else elapsed
}

private fun formatElapsed(ms: Long): String {
    val totalSeconds = ms / 1000
    val seconds = totalSeconds % 60
    val totalMinutes = totalSeconds / 60
    val minutes = totalMinutes % 60
    val hours = totalMinutes / 60

    return if (hours > 0) {
        String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.US, "%02d:%02d", minutes, seconds)
    }
}
