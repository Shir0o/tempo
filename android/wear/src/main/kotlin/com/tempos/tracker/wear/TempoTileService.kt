package com.tempos.tracker.wear

import android.content.Context
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.DimensionBuilders.wrap
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.TypeBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

class ImmediateFuture<V>(private val value: V) : ListenableFuture<V> {
    override fun get(): V = value
    override fun get(timeout: Long, unit: TimeUnit): V = value
    override fun isDone(): Boolean = true
    override fun isCancelled(): Boolean = false
    override fun cancel(mayInterruptIfRunning: Boolean): Boolean = false
    override fun addListener(listener: Runnable, executor: Executor) = executor.execute(listener)
}

/**
 * TempoTileService:
 * Non-scrolling circular tile built with ProtoLayout.
 * - Ledger Paper background (solid; ProtoLayout can't draw the Untracked hatching).
 * - Header: "Untracked" and the open Lap's elapsed time; tapping it opens the
 *   full Activity list.
 * - Three rounded-square slots: the most-used Activities over the last 14 days,
 *   most used first, each in its colour with ink initials. Tapping a slot labels
 *   the open Lap with that Activity and exits straight back to the watch face.
 */
class TempoTileService : TileService() {

    companion object {
        private const val RESOURCES_VERSION = "1"

        // Design D tokens (DESIGN.md).
        private const val LEDGER_PAPER = 0xFFE9E9E2.toInt()
        private const val INK = 0xFF121210.toInt()
        private const val FOG = 0xFFA8A8A8.toInt()

        fun requestUpdate(context: Context) {
            getUpdater(context).requestUpdate(TempoTileService::class.java)
        }
    }

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> {
        val repository = WearLapRepository.getInstance(this)
        val lap = repository.lap.value
        val slots = repository.tileActivities()

        val timeline = TimelineBuilders.Timeline.fromLayoutElement(buildTileLayout(lap, slots))

        val tile = TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setTileTimeline(timeline)
            // Re-render once a minute so the elapsed header stays current.
            .setFreshnessIntervalMillis(60_000)
            .build()

        return ImmediateFuture(tile)
    }

    override fun onTileResourcesRequest(requestParams: RequestBuilders.ResourcesRequest): ListenableFuture<ResourceBuilders.Resources> {
        return ImmediateFuture(
            ResourceBuilders.Resources.Builder()
                .setVersion(RESOURCES_VERSION)
                .build()
        )
    }

    private fun buildTileLayout(
        lap: LapState,
        slots: List<WearActivity>
    ): LayoutElementBuilders.LayoutElement {
        val slotRow = LayoutElementBuilders.Row.Builder()
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
        slots.forEachIndexed { index, activity ->
            if (index > 0) slotRow.addContent(buildGap(8))
            slotRow.addContent(buildSlotButton(activity))
        }

        val column = LayoutElementBuilders.Column.Builder()
            .setWidth(wrap())
            .setHeight(wrap())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(buildHeaderElement(lap))
            .addContent(buildSpacer(10))
            .addContent(slotRow.build())
            .build()

        // Ledger Paper: the open Lap is live, so the tile sits on paper.
        return LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(LEDGER_PAPER))
                            .build()
                    )
                    .build()
            )
            .addContent(column)
            .build()
    }

    /** "Untracked" over the Lap's elapsed time; tapping opens every Activity. */
    private fun buildHeaderElement(lap: LapState): LayoutElementBuilders.LayoutElement {
        val elapsed = if (lap.isOpen) formatElapsed(lap.startedAtEpochMs) else "--:--"

        val label = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder("Untracked").build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(12f))
                    .setWeight(LayoutElementBuilders.FONT_WEIGHT_BOLD)
                    .setColor(argb(INK))
                    .build()
            )
            .build()

        val value = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder(elapsed).build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(28f))
                    .setWeight(LayoutElementBuilders.FONT_WEIGHT_MEDIUM)
                    .setColor(argb(INK))
                    .build()
            )
            .build()

        return LayoutElementBuilders.Column.Builder()
            .setWidth(wrap())
            .setHeight(wrap())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId("open_quick_log")
                            .setOnClick(launchQuickLog())
                            .build()
                    )
                    .setPadding(
                        ModifiersBuilders.Padding.Builder()
                            .setStart(dp(10f))
                            .setEnd(dp(10f))
                            .build()
                    )
                    .build()
            )
            .addContent(label)
            .addContent(value)
            .build()
    }

    /** One Activity slot: a rounded square in its colour; a tap labels the open Lap and exits. */
    private fun buildSlotButton(activity: WearActivity): LayoutElementBuilders.LayoutElement {
        val text = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder(initials(activity.name)).build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(15f))
                    .setWeight(LayoutElementBuilders.FONT_WEIGHT_BOLD)
                    .setColor(argb(INK))
                    .build()
            )
            .build()

        return LayoutElementBuilders.Box.Builder()
            .setWidth(dp(48f))
            .setHeight(dp(48f)) // 48dp touch target
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId("label_${activity.id}")
                            .setOnClick(launchQuickLog(activity.id))
                            .build()
                    )
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(parseColor(activity.colorHex)))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(16f)).build())
                            .build()
                    )
                    .setSemantics(
                        ModifiersBuilders.Semantics.Builder()
                            .setContentDescription(activity.name)
                            .build()
                    )
                    .build()
            )
            .addContent(text)
            .build()
    }

    /**
     * Opens QuickLogActivity. With [activityId] the Activity labels the open
     * Lap and exits on launch; without it the list is shown.
     */
    private fun launchQuickLog(activityId: String? = null): ActionBuilders.LaunchAction {
        val androidActivity = ActionBuilders.AndroidActivity.Builder()
            .setPackageName(packageName)
            .setClassName(QuickLogActivity::class.java.name)

        if (activityId != null) {
            androidActivity.addKeyToExtraMapping(
                QuickLogActivity.EXTRA_LABEL_ACTIVITY_ID,
                ActionBuilders.stringExtra(activityId)
            )
        }

        return ActionBuilders.LaunchAction.Builder()
            .setAndroidActivity(androidActivity.build())
            .build()
    }

    private fun buildSpacer(heightDp: Int): LayoutElementBuilders.LayoutElement {
        return LayoutElementBuilders.Spacer.Builder()
            .setHeight(dp(heightDp.toFloat()))
            .setWidth(dp(1f))
            .build()
    }

    private fun buildGap(widthDp: Int): LayoutElementBuilders.LayoutElement {
        return LayoutElementBuilders.Spacer.Builder()
            .setWidth(dp(widthDp.toFloat()))
            .setHeight(dp(1f))
            .build()
    }

    /** "Errands" -> "Er": two letters, so three slots fit across a round face. */
    private fun initials(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return "?"
        return trimmed.take(2).lowercase(Locale.getDefault())
            .replaceFirstChar { it.titlecase(Locale.getDefault()) }
    }

    private fun parseColor(hex: String): Int {
        return try {
            android.graphics.Color.parseColor(hex)
        } catch (_: Exception) {
            FOG
        }
    }

    /** The minute-resolution elapsed time ("0:37"); the tile refreshes once a minute. */
    private fun formatElapsed(startedAt: Long): String {
        if (startedAt <= 0) return "--:--"
        val totalMinutes = ((System.currentTimeMillis() - startedAt) / 60_000).coerceAtLeast(0)
        return String.format(Locale.US, "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
