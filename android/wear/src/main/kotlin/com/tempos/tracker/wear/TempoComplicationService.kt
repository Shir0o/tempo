package com.tempos.tracker.wear

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationText
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.CountUpTimeReference
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
 * - Open Lap: renders the Lap's elapsed time from its start epoch with the
 *   system TimeDifferenceComplicationText (zero watch battery drain,
 *   no polling loop). Tapping opens the QuickLog list to label it.
 * - Before the first sync from the phone: renders "Track"; the same tap opens
 *   the list.
 */
class TempoComplicationService : SuspendingComplicationDataSourceService() {

    companion object {
        fun requestUpdate(context: Context) {
            val component = ComponentName(context, TempoComplicationService::class.java)
            ComplicationDataSourceUpdateRequester.create(context, component).requestUpdateAll()
        }
    }

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val lap = WearLapRepository.getInstance(this).lap.value

        return when (request.complicationType) {
            ComplicationType.SHORT_TEXT -> createShortTextData(lap)
            ComplicationType.RANGED_VALUE -> createRangedValueData(lap)
            ComplicationType.SMALL_IMAGE -> createSmallImageData()
            else -> null
        }
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? {
        return when (type) {
            ComplicationType.SHORT_TEXT -> {
                ShortTextComplicationData.Builder(
                    text = PlainComplicationText.Builder("24m").build(),
                    contentDescription = PlainComplicationText.Builder("Tempo Lap").build()
                )
                    .setTitle(PlainComplicationText.Builder("Lap").build())
                    .build()
            }
            ComplicationType.RANGED_VALUE -> {
                RangedValueComplicationData.Builder(
                    value = 24f,
                    min = 0f,
                    max = 60f,
                    contentDescription = PlainComplicationText.Builder("Tempo Lap 24m").build()
                )
                    .setText(PlainComplicationText.Builder("24m").build())
                    .setTitle(PlainComplicationText.Builder("Lap").build())
                    .build()
            }
            ComplicationType.SMALL_IMAGE -> {
                val icon = Icon.createWithResource(this, android.R.drawable.ic_menu_recent_history)
                SmallImageComplicationData.Builder(
                    smallImage = SmallImage.Builder(icon, SmallImageType.ICON).build(),
                    contentDescription = PlainComplicationText.Builder("Tempo Lap").build()
                ).build()
            }
            else -> null
        }
    }

    private fun openQuickLogIntent(): PendingIntent {
        val intent = Intent(this, QuickLogActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            this, 101, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** The elapsed time of an open Lap, rendered by the system stopwatch. */
    private fun elapsedText(lap: LapState, fallback: String): ComplicationText {
        return try {
            val instant = Instant.ofEpochMilli(lap.startedAtEpochMs)
            TimeDifferenceComplicationText.Builder(
                TimeDifferenceStyle.STOPWATCH,
                CountUpTimeReference(instant)
            ).build()
        } catch (_: Throwable) {
            PlainComplicationText.Builder(fallback).build()
        }
    }

    private fun createShortTextData(lap: LapState): ComplicationData {
        val pendingIntent = openQuickLogIntent()

        return if (lap.isOpen) {
            ShortTextComplicationData.Builder(
                text = elapsedText(lap, elapsedMinutes(lap)),
                contentDescription = PlainComplicationText.Builder("Open Lap: label it").build()
            )
                .setTitle(PlainComplicationText.Builder("Lap").build())
                .setTapAction(pendingIntent)
                .build()
        } else {
            ShortTextComplicationData.Builder(
                text = PlainComplicationText.Builder("Track").build(),
                contentDescription = PlainComplicationText.Builder("Tempo - label the open Lap").build()
            )
                .setTitle(PlainComplicationText.Builder("▶️").build())
                .setTapAction(pendingIntent)
                .build()
        }
    }

    private fun createRangedValueData(lap: LapState): ComplicationData {
        val pendingIntent = openQuickLogIntent()
        val elapsed = elapsedMinutesValue(lap)
        val targetMinutes = 60f

        return RangedValueComplicationData.Builder(
            value = if (lap.isOpen) elapsed.coerceAtMost(targetMinutes) else 0f,
            min = 0f,
            max = targetMinutes,
            contentDescription = PlainComplicationText.Builder(
                if (lap.isOpen) "Tempo Lap" else "Tempo"
            ).build()
        )
            .setText(
                if (lap.isOpen) {
                    elapsedText(lap, elapsedMinutes(lap))
                } else {
                    PlainComplicationText.Builder("Track").build()
                }
            )
            .setTitle(
                PlainComplicationText.Builder(if (lap.isOpen) "Lap" else "▶️").build()
            )
            .setTapAction(pendingIntent)
            .build()
    }

    private fun createSmallImageData(): ComplicationData {
        val icon = Icon.createWithResource(this, android.R.drawable.ic_menu_recent_history)
        return SmallImageComplicationData.Builder(
            smallImage = SmallImage.Builder(icon, SmallImageType.ICON).build(),
            contentDescription = PlainComplicationText.Builder("Tempo").build()
        )
            .setTapAction(openQuickLogIntent())
            .build()
    }

    private fun elapsedMinutesValue(lap: LapState): Float {
        if (!lap.isOpen) return 0f
        val elapsed = System.currentTimeMillis() - lap.startedAtEpochMs
        return (elapsed / 60000).coerceAtLeast(0).toFloat()
    }

    private fun elapsedMinutes(lap: LapState): String {
        return "${elapsedMinutesValue(lap).toInt()}m"
    }
}
