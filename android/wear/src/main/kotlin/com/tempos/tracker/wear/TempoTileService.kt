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
 * - Header: the open Lap's elapsed time; tapping it opens the full Activity list.
 * - Three slots: the most-used Activities over the last 14 days, most used
 *   first. Tapping a slot labels the open Lap with that Activity and exits
 *   straight back to the watch face.
 */
class TempoTileService : TileService() {

    companion object {
        private const val RESOURCES_VERSION = "1"

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
        val columnBuilder = LayoutElementBuilders.Column.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)

        columnBuilder.addContent(buildHeaderElement(lap))
        columnBuilder.addContent(buildSpacer(6))

        slots.forEachIndexed { index, activity ->
            columnBuilder.addContent(buildSlotButton(activity, isPrimary = index == 0))
            columnBuilder.addContent(buildSpacer(4))
        }

        return LayoutElementBuilders.Box.Builder()
            .setWidth(expand())
            .setHeight(expand())
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(0xFF000000.toInt()))
                            .build()
                    )
                    .build()
            )
            .addContent(columnBuilder.build())
            .build()
    }

    /** Lap elapsed, tapping opens the list of every Activity. */
    private fun buildHeaderElement(lap: LapState): LayoutElementBuilders.LayoutElement {
        val elapsed = if (lap.isOpen) formatElapsed(lap.startedAtEpochMs) else "--:--"

        val label = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder("LAP ").build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(11f))
                    .setWeight(LayoutElementBuilders.FONT_WEIGHT_MEDIUM)
                    .setColor(argb(0xFF94A3B8.toInt()))
                    .build()
            )
            .build()

        val value = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder(elapsed).build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(13f))
                    .setWeight(LayoutElementBuilders.FONT_WEIGHT_BOLD)
                    .setColor(argb(0xFF4ADE80.toInt()))
                    .build()
            )
            .build()

        val row = LayoutElementBuilders.Row.Builder()
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .addContent(label)
            .addContent(value)
            .build()

        return LayoutElementBuilders.Box.Builder()
            .setWidth(wrap())
            .setHeight(dp(24f))
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setClickable(
                        ModifiersBuilders.Clickable.Builder()
                            .setId("open_quick_log")
                            .setOnClick(launchQuickLog())
                            .build()
                    )
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(0xFF1E293B.toInt()))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(12f)).build())
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
            .addContent(row)
            .build()
    }

    /** One Activity slot: a single tap labels the open Lap and exits. */
    private fun buildSlotButton(activity: WearActivity, isPrimary: Boolean): LayoutElementBuilders.LayoutElement {
        val heightDp = if (isPrimary) 52f else 36f

        val text = LayoutElementBuilders.Text.Builder()
            .setText(TypeBuilders.StringProp.Builder(activity.name).build())
            .setFontStyle(
                LayoutElementBuilders.FontStyle.Builder()
                    .setSize(sp(if (isPrimary) 15f else 12f))
                    .setWeight(
                        if (isPrimary) {
                            LayoutElementBuilders.FONT_WEIGHT_BOLD
                        } else {
                            LayoutElementBuilders.FONT_WEIGHT_MEDIUM
                        }
                    )
                    .setColor(argb(0xFFFFFFFF.toInt()))
                    .build()
            )
            .build()

        return LayoutElementBuilders.Box.Builder()
            .setWidth(dp(156f))
            .setHeight(dp(heightDp)) // >= 36dp, primary >= 52dp touch target
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
                            .setColor(argb(0xFF1E3A8A.toInt()))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(heightDp / 2f)).build())
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

    private fun formatElapsed(startedAt: Long): String {
        if (startedAt <= 0) return "--:--"
        val totalSec = ((System.currentTimeMillis() - startedAt) / 1000).coerceAtLeast(0)
        val seconds = totalSec % 60
        val totalMinutes = totalSec / 60
        val minutes = totalMinutes % 60
        val hours = totalMinutes / 60
        return if (hours > 0) {
            String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format(Locale.US, "%02d:%02d", minutes, seconds)
        }
    }
}
