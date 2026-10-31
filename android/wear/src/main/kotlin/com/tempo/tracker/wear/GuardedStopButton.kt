package com.tempo.tracker.wear

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Text
import kotlinx.coroutines.delay

/**
 * GuardedStop: An intentional interaction requirement (600ms continuous hold)
 * preventing accidental termination of a running ActiveTimer by clothing or incidental screen contact.
 */
@Composable
fun GuardedStopButton(
    onStopConfirmed: () -> Unit,
    modifier: Modifier = Modifier,
    holdDurationMs: Int = 600
) {
    var isHolding by remember { mutableStateOf(false) }
    var holdCompleted by remember { mutableStateOf(false) }
    val view = LocalView.current
    val context = LocalContext.current
    val vibrator = remember {
        @Suppress("DEPRECATION")
        context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    // Haptic rumble loop during hold
    LaunchedEffect(isHolding) {
        if (isHolding && !holdCompleted) {
            val stepInterval = 100L
            var elapsed = 0L
            while (isHolding && elapsed < holdDurationMs) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createOneShot(30, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(30)
                }
                delay(stepInterval)
                elapsed += stepInterval
            }
        }
    }

    val progress by animateFloatAsState(
        targetValue = if (isHolding) 1f else 0f,
        animationSpec = tween(
            durationMillis = if (isHolding) holdDurationMs else 150,
            easing = LinearEasing
        ),
        finishedListener = { finalValue ->
            if (finalValue >= 0.99f && isHolding && !holdCompleted) {
                holdCompleted = true
                view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                onStopConfirmed()
            }
        },
        label = "GuardedStopProgress"
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
                        holdCompleted = false
                        val released = tryAwaitRelease()
                        isHolding = false
                        if (!released) {
                            // Touch cancelled or slipped
                        }
                    }
                )
            }
    ) {
        // Red radial/linear progress fill track
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(progress)
                .background(Color(0xFFE53935))
                .align(Alignment.CenterStart)
        )

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 16.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(12.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = if (isHolding) "Hold to Stop (${(progress * 100).toInt()}%)" else "Hold to Stop",
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}
