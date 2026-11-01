package com.tempos.tracker.wear

import android.os.Bundle
import android.text.format.DateFormat
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.ambient.AmbientLifecycleObserver
import androidx.wear.compose.material.CompactChip
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Date
import java.util.Locale

/**
 * ActiveSessionActivity:
 * - Monospace elapsed ticker with 1-second precision in interactive mode.
 * - GuardedStop button requiring a continuous 600ms hold with radial progress and haptic rumble.
 * - Action-and-Exit on stop: flashes 800ms confirmation, finishes immediately.
 * - Ambient mode low-power rendering via AmbientLifecycleObserver (ticks once a minute, HH:mm).
 */
class ActiveSessionActivity : ComponentActivity() {

    private var isAmbientState = mutableStateOf(false)

    private val ambientCallback = object : AmbientLifecycleObserver.AmbientLifecycleCallback {
        override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
            isAmbientState.value = true
        }

        override fun onExitAmbient() {
            isAmbientState.value = false
        }

        override fun onUpdateAmbient() {
            // Called roughly once every 60 seconds by Wear OS launcher
        }
    }

    private val ambientObserver = AmbientLifecycleObserver(this, ambientCallback)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(ambientObserver)

        val repository = WearTimerRepository.getInstance(this)

        setContent {
            val isAmbient by remember { isAmbientState }
            val activeTimer by repository.activeTimerState.collectAsState()

            ActiveSessionScreen(
                isAmbient = isAmbient,
                activeTimer = activeTimer,
                onStopConfirmed = {
                    repository.stopTimer()
                },
                onTogglePause = {
                    if (activeTimer.isPaused) {
                        repository.resumeTimer()
                    } else {
                        repository.pauseTimer()
                    }
                },
                onFinish = {
                    finish()
                }
            )
        }
    }
}

@Composable
fun ActiveSessionScreen(
    isAmbient: Boolean,
    activeTimer: ActiveTimerState,
    onStopConfirmed: () -> Unit,
    onTogglePause: () -> Unit,
    onFinish: () -> Unit
) {
    val view = LocalView.current
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var showStoppedConfirmation by remember { mutableStateOf(false) }
    var currentElapsedMs by remember {
        mutableLongStateOf(calculateElapsedMs(activeTimer))
    }

    // Interactive 1-second ticker loop (Local CPU only, zero BLE wakeups)
    LaunchedEffect(isAmbient, activeTimer.isRunning, activeTimer.isPaused, activeTimer.startedAtEpochMs) {
        if (!isAmbient && activeTimer.isRunning && !activeTimer.isPaused) {
            while (isActive) {
                currentElapsedMs = calculateElapsedMs(activeTimer)
                delay(1000L)
            }
        } else {
            currentElapsedMs = calculateElapsedMs(activeTimer)
        }
    }

    // Auto finish if no timer is running and not showing confirmation
    LaunchedEffect(activeTimer.isRunning, showStoppedConfirmation) {
        if (!activeTimer.isRunning && !showStoppedConfirmation) {
            onFinish()
        }
    }

    val accentColor = remember(activeTimer.activityColorHex) {
        try {
            Color(android.graphics.Color.parseColor(activeTimer.activityColorHex ?: "#4CAF50"))
        } catch (_: Exception) {
            Color(0xFF4CAF50)
        }
    }

    val startedTimeString = remember(activeTimer.startedAtEpochMs) {
        if (activeTimer.startedAtEpochMs > 0) {
            val format = DateFormat.getTimeFormat(context)
            format.format(Date(activeTimer.startedAtEpochMs))
        } else {
            ""
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        if (isAmbient) {
            // Ambient mode: strictly monochrome, low contrast, HH:mm elapsed time
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    text = activeTimer.activityName ?: "Active Session",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = formatAmbientDuration(currentElapsedMs),
                    color = Color.White,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold
                )
                if (activeTimer.isPaused) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "[PAUSED]",
                        color = Color.Gray,
                        fontSize = 11.sp
                    )
                }
            }
        } else {
            // Interactive mode
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 14.dp, vertical = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                // Header: Activity Name + Color Dot
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(accentColor)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = (activeTimer.activityName ?: "Activity").uppercase(Locale.getDefault()),
                        color = Color.White,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                // Center: Monospace duration ticker & started time
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = formatInteractiveDuration(currentElapsedMs),
                        color = if (activeTimer.isPaused) Color(0xFFFBBF24) else Color.White,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center
                    )

                    Spacer(modifier = Modifier.height(2.dp))

                    if (activeTimer.isPaused) {
                        Text(
                            text = "PAUSED",
                            color = Color(0xFFFBBF24),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 1.sp
                        )
                    } else if (startedTimeString.isNotEmpty()) {
                        Text(
                            text = "Started $startedTimeString",
                            color = Color(0xFF94A3B8),
                            fontSize = 11.sp
                        )
                    }
                }

                // Bottom: GuardedStopButton + Pause toggle
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    GuardedStopButton(
                        onStopConfirmed = {
                            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                            onStopConfirmed()
                            showStoppedConfirmation = true
                            coroutineScope.launch {
                                // 800ms Action-and-Exit confirmation flash
                                delay(800L)
                                onFinish()
                            }
                        }
                    )

                    Spacer(modifier = Modifier.height(4.dp))

                    CompactChip(
                        onClick = {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            onTogglePause()
                        },
                        label = {
                            Text(
                                text = if (activeTimer.isPaused) "Resume" else "Pause",
                                fontSize = 11.sp
                            )
                        }
                    )
                }
            }

            // 800ms Stopped Visual Confirmation Overlay
            AnimatedVisibility(
                visible = showStoppedConfirmation,
                enter = fadeIn(),
                exit = fadeOut()
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.92f)),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text(
                            text = "✓",
                            color = Color(0xFF22C55E),
                            fontSize = 36.sp,
                            fontWeight = FontWeight.ExtraBold
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "Timer Stopped",
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }
}

private fun calculateElapsedMs(state: ActiveTimerState): Long {
    if (!state.isRunning || state.startedAtEpochMs <= 0L) return 0L
    val now = System.currentTimeMillis()
    val elapsed = now - state.startedAtEpochMs - state.accumulatedPauseMs
    return if (elapsed < 0L) 0L else elapsed
}

private fun formatInteractiveDuration(ms: Long): String {
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

private fun formatAmbientDuration(ms: Long): String {
    val totalSeconds = ms / 1000
    val totalMinutes = totalSeconds / 60
    val minutes = totalMinutes % 60
    val hours = totalMinutes / 60

    return String.format(Locale.US, "%02d:%02dh", hours, minutes)
}
