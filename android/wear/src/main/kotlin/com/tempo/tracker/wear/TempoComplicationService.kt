package com.tempo.tracker.wear

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationText
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.CountUpTimeReference
import androidx.wear.watchface.complications.data.MonochromaticImage
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.data.SmallImage
import androidx.wear.watchface.complications.data.SmallImageComplicationData
import androidx.wear.watchface.complications.data.SmallImageType
import androidx.wear.watchface.complications.data.TimeDifferenceComplicationText
import androidx.wear.watchface.complications.data.TimeDifferenceStyle
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import java.time.Instant

/**
 * TempoComplicationService:
 * Supports SHORT_TEXT, RANGED_VALUE, and SMALL_IMAGE complications.
 * - Idle State: Renders [▶️ Track]; direct tap launches QuickLogActivity.
 * - Active State: Renders live stopwatch elapsed time via system TimeDifferenceComplicationText
 *   with STYLE_STOPWATCH (zero watch battery drain); tap opens ActiveSessionActivity.
 */
class TempoComplicationService : SuspendingComplicationDataSourceService() {

    companion object {
        fun requestUpdate(context: Context) {
            val component = ComponentName(context, TempoComplicationService::class.java)
            ComplicationDataSourceUpdateRequester.create(context, component).requestUpdateAll()
        }
    }

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val repository = WearTimerRepository.getInstance(this)
        val activeTimer = repository.activeTimerState.value

        return when (request.complicationType) {
            ComplicationType.SHORT_TEXT -> createShortTextData(activeTimer)
            ComplicationType.RANGED_VALUE -> createRangedValueData(activeTimer)
            ComplicationType.SMALL_IMAGE -> createSmallImageData(activeTimer)
            else -> null
        }
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? {
        return when (type) {
            ComplicationType.SHORT_TEXT -> {
                ShortTextComplicationData.Builder(
                    text = PlainComplicationText.Builder("24m").build(),
                    contentDescription = PlainComplicationText.Builder("Tempo").build()
                )
                    .setTitle(PlainComplicationText.Builder("Coding").build())
                    .build()
            }
            ComplicationType.RANGED_VALUE -> {
                RangedValueComplicationData.Builder(
                    value = 24f,
                    min = 0f,
                    max = 60f,
                    contentDescription = PlainComplicationText.Builder("Tempo 24m").build()
                )
                    .setText(PlainComplicationText.Builder("24m").build())
                    .setTitle(PlainComplicationText.Builder("Coding").build())
                    .build()
            }
            ComplicationType.SMALL_IMAGE -> {
                val icon = Icon.createWithResource(this, android.R.drawable.ic_menu_recent_history)
                SmallImageComplicationData.Builder(
                    smallImage = SmallImage.Builder(icon, SmallImageType.ICON).build(),
                    contentDescription = PlainComplicationText.Builder("Tempo").build()
                ).build()
            }
            else -> null
        }
    }

    private fun createShortTextData(timer: ActiveTimerState): ComplicationData {
        return if (timer.isRunning && timer.startedAtEpochMs > 0) {
            val tapIntent = Intent(this, ActiveSessionActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 101, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val text: ComplicationText = try {
                val instant = Instant.ofEpochMilli(timer.startedAtEpochMs)
                TimeDifferenceComplicationText.Builder(
                    TimeDifferenceStyle.STOPWATCH,
                    CountUpTimeReference(instant)
                ).build()
            } catch (_: Throwable) {
                val elapsedMinutes = ((System.currentTimeMillis() - timer.startedAtEpochMs) / 60000).coerceAtLeast(0)
                PlainComplicationText.Builder("${elapsedMinutes}m").build()
            }

            val title = timer.activityName ?: "Active"

            ShortTextComplicationData.Builder(
                text = text,
                contentDescription = PlainComplicationText.Builder("Active Timer: $title").build()
            )
                .setTitle(PlainComplicationText.Builder(title).build())
                .setTapAction(pendingIntent)
                .build()
        } else {
            val tapIntent = Intent(this, QuickLogActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 102, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            ShortTextComplicationData.Builder(
                text = PlainComplicationText.Builder("Track").build(),
                contentDescription = PlainComplicationText.Builder("Tempo - Start Tracking").build()
            )
                .setTitle(PlainComplicationText.Builder("▶️").build())
                .setTapAction(pendingIntent)
                .build()
        }
    }

    private fun createRangedValueData(timer: ActiveTimerState): ComplicationData {
        val tapIntent = if (timer.isRunning) {
            Intent(this, ActiveSessionActivity::class.java)
        } else {
            Intent(this, QuickLogActivity::class.java)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 103, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return if (timer.isRunning && timer.startedAtEpochMs > 0) {
            val elapsedMinutes = ((System.currentTimeMillis() - timer.startedAtEpochMs) / 60000).toFloat()
            val targetMinutes = 60f

            val text: ComplicationText = try {
                val instant = Instant.ofEpochMilli(timer.startedAtEpochMs)
                TimeDifferenceComplicationText.Builder(
                    TimeDifferenceStyle.STOPWATCH,
                    CountUpTimeReference(instant)
                ).build()
            } catch (_: Throwable) {
                PlainComplicationText.Builder("${elapsedMinutes.toInt()}m").build()
            }

            RangedValueComplicationData.Builder(
                value = elapsedMinutes.coerceAtMost(targetMinutes),
                min = 0f,
                max = targetMinutes,
                contentDescription = PlainComplicationText.Builder("Tempo Active").build()
            )
                .setText(text)
                .setTitle(PlainComplicationText.Builder(timer.activityName ?: "Active").build())
                .setTapAction(pendingIntent)
                .build()
        } else {
            RangedValueComplicationData.Builder(
                value = 0f,
                min = 0f,
                max = 60f,
                contentDescription = PlainComplicationText.Builder("Tempo Idle").build()
            )
                .setText(PlainComplicationText.Builder("Track").build())
                .setTitle(PlainComplicationText.Builder("▶️").build())
                .setTapAction(pendingIntent)
                .build()
        }
    }

    private fun createSmallImageData(timer: ActiveTimerState): ComplicationData {
        val tapIntent = if (timer.isRunning) {
            Intent(this, ActiveSessionActivity::class.java)
        } else {
            Intent(this, QuickLogActivity::class.java)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 104, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val icon = Icon.createWithResource(this, android.R.drawable.ic_menu_recent_history)
        return SmallImageComplicationData.Builder(
            smallImage = SmallImage.Builder(icon, SmallImageType.ICON).build(),
            contentDescription = PlainComplicationText.Builder("Tempo").build()
        )
            .setTapAction(pendingIntent)
            .build()
    }
}
