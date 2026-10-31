package com.tempo.tracker.wear

import android.os.Bundle
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
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
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * QuickLogActivity:
 * - Top pinned habits with touch targets >= 52dp.
 * - 3-second floating Undo Grace Window snackbar upon starting timer.
 * - Action-and-Exit pattern: immediate finish() on action to return to watch face
 *   and prevent notification suppression.
 * - Inactivity timeout: 10s auto-exit.
 * - Ambient mode low-power rendering via AmbientLifecycleObserver.
 */
class QuickLogActivity : ComponentActivity() {

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

        val repository = WearTimerRepository.getInstance(this)

        // Check if an activity ID was passed via Intent (e.g. from Tile slot tap)
        val startId = intent?.getStringExtra("EXTRA_START_ACTIVITY_ID")
        if (!startId.isNullOrEmpty()) {
            val activities = repository.activities.value
            val target = activities.find { it.id == startId }
                ?: WearActivity(id = startId, name = startId)
            repository.startTimer(target)
            window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            finish()
            return
        }

        setContent {
            val isAmbient by remember { isAmbientState }
            val activities by repository.activities.collectAsState()
            val activeTimer by repository.activeTimerState.collectAsState()

            QuickLogScreen(
                isAmbient = isAmbient,
                activities = activities,
                activeTimer = activeTimer,
                onActivitySelected = { activity ->
                    repository.startTimer(activity)
                },
                onUndoClicked = {
                    repository.undoTimer()
                },
                onFinish = {
                    finish()
                }
            )
        }
    }
}

@Composable
fun QuickLogScreen(
    isAmbient: Boolean,
    activities: List<WearActivity>,
    activeTimer: ActiveTimerState,
    onActivitySelected: (WearActivity) -> Unit,
    onUndoClicked: () -> Unit,
    onFinish: () -> Unit
) {
    val view = LocalView.current
    val coroutineScope = rememberCoroutineScope()

    var startedActivity by remember { mutableStateOf<WearActivity?>(null) }
    var showUndoWindow by remember { mutableStateOf(false) }
    var isUndone by remember { mutableStateOf(false) }

    // Inactivity timeout: 10 seconds auto-exit if left untouched
    LaunchedEffect(Unit) {
        delay(10_000L)
        if (!showUndoWindow) {
            onFinish()
        }
    }

    // 3-second Undo Grace Window timer
    LaunchedEffect(showUndoWindow) {
        if (showUndoWindow) {
            // Action-and-Exit: After 3 seconds without undo (or 800ms confirmation if undo not desired),
            // auto-exit back to watch face
            delay(3000L)
            if (!isUndone) {
                onFinish()
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        if (isAmbient) {
            // Low-power ambient display
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
                    text = if (activeTimer.isRunning) "Running: ${activeTimer.activityName ?: "Active"}" else "Idle",
                    color = Color.Gray,
                    fontSize = 12.sp
                )
            }
        } else {
            // Interactive mode
            ScalingLazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 28.dp, start = 12.dp, end = 12.dp, bottom = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                item {
                    Text(
                        text = if (activeTimer.isRunning) "Switch Habit" else "Select Habit",
                        color = Color.White,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 8.dp)
                    )
                }

                // Top pinned habits (>= 52dp touch target)
                val pinned = activities.filter { it.isPinned }
                val others = activities.filter { !it.isPinned }

                items(pinned) { activity ->
                    HabitChip(
                        activity = activity,
                        isPrimary = true,
                        onClick = {
                            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                            startedActivity = activity
                            onActivitySelected(activity)
                            showUndoWindow = true
                        }
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                }

                if (others.isNotEmpty()) {
                    item {
                        Text(
                            text = "Other Habits",
                            color = Color(0xFFAAAAAA),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(top = 8.dp, bottom = 4.dp)
                        )
                    }

                    items(others) { activity ->
                        HabitChip(
                            activity = activity,
                            isPrimary = false,
                            onClick = {
                                view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                                startedActivity = activity
                                onActivitySelected(activity)
                                showUndoWindow = true
                            }
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                    }
                }
            }

            // Floating 3-second Undo Grace Window snackbar
            AnimatedVisibility(
                visible = showUndoWindow,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.align(Alignment.BottomCenter)
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 8.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(Color(0xFF1E293B))
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "✓ ${startedActivity?.name ?: "Started"}",
                            color = Color(0xFF4ADE80),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color(0xFFDC2626))
                                .clickable {
                                    view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                                    isUndone = true
                                    showUndoWindow = false
                                    onUndoClicked()
                                    coroutineScope.launch {
                                        delay(400)
                                        onFinish()
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        ) {
                            Text(
                                text = "UNDO",
                                color = Color.White,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.ExtraBold
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun HabitChip(
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
