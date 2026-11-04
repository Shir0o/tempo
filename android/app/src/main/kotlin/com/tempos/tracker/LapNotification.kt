package com.tempos.tracker

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * The ongoing notification that is always present while a Lap is open, so the
 * Lap can be labeled with one tap. Dart owns its content and posts it through
 * [post] whenever the Lap changes; times arrive already formatted in the zones
 * they were lived in.
 *
 * It is local-only: the watch builds its own notification.
 */
object LapNotification {
    const val CHANNEL_NAME = "com.tempos.tracker/notification"

    private const val TAG = "TempoLapNotification"
    private const val NOTIFICATION_CHANNEL_ID = "open_lap"
    private const val NOTIFICATION_ID = 1
    private const val CHIPS_PER_ROW = 3
    private const val REQUEST_OPEN_APP = 100
    private const val REQUEST_SPLIT = 101
    private const val REQUEST_UNDO = 102
    private const val FALLBACK_COLOR = "#4CAF50"

    /** The state Dart last posted, kept so it can be re-posted once notifications are allowed. */
    @Volatile
    private var lastState: Map<*, *>? = null

    /**
     * Posts the open Lap from [state]: `lapStartedAtEpochMs`, `since` (the Lap's
     * start, "HH:mm"), `activities` (ranked `{id, name, colorHex}`), and an
     * optional `lastLabel` (`activityName`, `colorHex`, `startedAt`, `endedAt`,
     * `duration`, `undoUntilEpochMs`) shown with Undo until it expires.
     */
    fun post(context: Context, state: Map<*, *>) {
        lastState = state
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val lapStartedAt = (state["lapStartedAtEpochMs"] as? Number)?.toLong() ?: return
        val activities = (state["activities"] as? List<*>)?.filterIsInstance<Map<*, *>>().orEmpty()
        val lastLabel = (state["lastLabel"] as? Map<*, *>)?.takeIf {
            System.currentTimeMillis() < ((it["undoUntilEpochMs"] as? Number)?.toLong() ?: 0L)
        }

        val manager = NotificationManagerCompat.from(context)
        manager.createNotificationChannel(
            NotificationChannelCompat.Builder(NOTIFICATION_CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                .setName("Open Lap")
                .setDescription("Label the open Lap with one tap")
                .setShowBadge(false)
                .build()
        )

        val builder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_timer)
            .setOngoing(true)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setWhen(lapStartedAt)
            .setContentIntent(openAppIntent(context))

        if (lastLabel != null) {
            builder
                .setContentTitle(
                    "${lastLabel["activityName"]} · ${lastLabel["startedAt"]} → " +
                        "${lastLabel["endedAt"]} · ${lastLabel["duration"]}"
                )
                .setContentText("New Lap running")
                .setColor(parseColor(lastLabel["colorHex"] as? String))
                .addAction(0, "Undo", actionIntent(context, LapNotificationReceiver.ACTION_UNDO, REQUEST_UNDO))
        } else {
            builder
                .setSubText("since ${state["since"]}")
                .setStyle(NotificationCompat.DecoratedCustomViewStyle())
                .setCustomContentView(collapsedView(context, activities))
                .setCustomBigContentView(expandedView(context, lapStartedAt, activities))
        }

        try {
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            Log.w(TAG, "Notifications are not allowed: ${e.message}")
        }
    }

    /** Re-posts the last state, e.g. right after notifications were allowed. */
    fun repost(context: Context) {
        lastState?.let { post(context, it) }
    }

    private fun collapsedView(context: Context, activities: List<Map<*, *>>) =
        RemoteViews(context.packageName, R.layout.notification_lap_collapsed).apply {
            addChipRow(context, this, R.id.lap_chips, activities, 0)
            setOnClickPendingIntent(R.id.lap_more, openAppIntent(context))
        }

    private fun expandedView(context: Context, lapStartedAt: Long, activities: List<Map<*, *>>) =
        RemoteViews(context.packageName, R.layout.notification_lap_expanded).apply {
            // Chronometer counts on the elapsed-realtime clock; the elapsed time
            // itself is UTC epoch arithmetic.
            val elapsedMs = System.currentTimeMillis() - lapStartedAt
            setChronometer(R.id.lap_elapsed, SystemClock.elapsedRealtime() - elapsedMs, null, true)
            addChipRow(context, this, R.id.lap_chips_top, activities, 0)
            if (activities.size > CHIPS_PER_ROW) {
                addChipRow(context, this, R.id.lap_chips_bottom, activities, CHIPS_PER_ROW)
            } else {
                setViewVisibility(R.id.lap_chips_bottom, View.GONE)
            }
            setOnClickPendingIntent(
                R.id.lap_split,
                actionIntent(context, LapNotificationReceiver.ACTION_SPLIT, REQUEST_SPLIT)
            )
            setOnClickPendingIntent(R.id.lap_other, openAppIntent(context))
        }

    /** Adds a row of chips from [start]; empty slots stay invisible so columns line up. */
    private fun addChipRow(
        context: Context,
        parent: RemoteViews,
        rowId: Int,
        activities: List<Map<*, *>>,
        start: Int,
    ) {
        for (slot in start until start + CHIPS_PER_ROW) {
            val chip = RemoteViews(context.packageName, R.layout.notification_lap_chip)
            val activity = activities.getOrNull(slot)
            if (activity == null) {
                chip.setViewVisibility(R.id.lap_chip, View.INVISIBLE)
            } else {
                chip.setTextViewText(R.id.lap_chip_name, activity["name"] as? String ?: "")
                chip.setInt(R.id.lap_chip_fill, "setColorFilter", parseColor(activity["colorHex"] as? String))
                chip.setOnClickPendingIntent(
                    R.id.lap_chip,
                    actionIntent(
                        context,
                        LapNotificationReceiver.ACTION_LABEL,
                        slot,
                        activity["id"] as? String
                    )
                )
            }
            parent.addView(rowId, chip)
        }
    }

    private fun actionIntent(
        context: Context,
        action: String,
        requestCode: Int,
        activityId: String? = null,
    ): PendingIntent {
        val intent = Intent(context, LapNotificationReceiver::class.java).setAction(action)
        if (activityId != null) {
            intent.putExtra(LapNotificationReceiver.EXTRA_ACTIVITY_ID, activityId)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQUEST_OPEN_APP,
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    /** Parses "#RRGGBB", "RRGGBB" or "#AARRGGBB", as Dart's UiHelpers.parseHexColor does. */
    private fun parseColor(hex: String?): Int =
        try {
            val value = hex?.trim().orEmpty()
            Color.parseColor(if (value.startsWith("#")) value else "#$value")
        } catch (e: IllegalArgumentException) {
            Color.parseColor(FALLBACK_COLOR)
        }
}
