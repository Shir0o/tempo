package com.tempos.tracker.wear

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The ongoing Lap notification, wrapped in an Ongoing Activity so the Tempo
 * icon sits on the watch face and in recents. Its actions label the open Lap
 * through [LapActionReceiver]; nothing is launched except "More".
 */
object LapNotification {

    private const val CHANNEL_ID = "tempo_lap"
    private const val NOTIFICATION_ID = 1001
    private const val ICON = android.R.drawable.ic_menu_recent_history
    private const val REQUEST_MORE = 100
    private const val REQUEST_UNDO = 101

    /** While a label confirmation shows, Lap updates leave the notification alone. */
    @Volatile
    private var confirmingUntilEpochMs = 0L

    /** Posts or refreshes the normal Lap notification. */
    fun update(context: Context, repository: WearLapRepository) {
        if (System.currentTimeMillis() < confirmingUntilEpochMs) return
        val lap = repository.lap.value
        if (!lap.isOpen) {
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
            return
        }

        val builder = baseBuilder(context, lap)
            .setContentTitle("Lap · since ${clockTime(lap.startedAtEpochMs, lap.startedTimezoneId)}")
            .setContentText("What was it?")

        repository.tileActivities().forEachIndexed { index, activity ->
            builder.addAction(
                NotificationCompat.Action.Builder(
                    colorDot(activity.colorHex),
                    activity.name,
                    receiverIntent(context, LapActionReceiver.ACTION_LABEL, index, activity.id)
                ).build()
            )
        }
        builder.addAction(
            NotificationCompat.Action.Builder(
                IconCompat.createWithResource(context, ICON),
                "More",
                quickLogIntent(context, REQUEST_MORE)
            ).build()
        )
        // The first Activity is tappable straight from the notification list.
        builder.extend(NotificationCompat.WearableExtender().setContentAction(0))

        post(context, builder, lap)
    }

    /**
     * Shows "<Activity> · 1h 24m · New Lap running" with Undo for the
     * UndoGraceWindow. The caller reverts with [endConfirmation].
     */
    fun showLabeled(context: Context, repository: WearLapRepository, activityName: String, labeledMs: Long) {
        confirmingUntilEpochMs = System.currentTimeMillis() + UNDO_GRACE_WINDOW_MS
        val lap = repository.lap.value
        val builder = baseBuilder(context, lap)
            .setContentTitle("$activityName · ${formatDuration(labeledMs)}")
            .setContentText("New Lap running")
            .addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithResource(context, ICON),
                    "Undo",
                    receiverIntent(context, LapActionReceiver.ACTION_UNDO, REQUEST_UNDO, null)
                ).build()
            )
        post(context, builder, lap)
    }

    /** Reverts to the normal Lap notification. */
    fun endConfirmation(context: Context, repository: WearLapRepository) {
        confirmingUntilEpochMs = 0L
        update(context, repository)
    }

    private fun baseBuilder(context: Context, lap: LapState): NotificationCompat.Builder {
        ensureChannel(context)
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(ICON)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setUsesChronometer(true)
            .setWhen(lap.startedAtEpochMs)
            .setShowWhen(true)
            .setContentIntent(quickLogIntent(context, REQUEST_MORE))
    }

    private fun post(context: Context, builder: NotificationCompat.Builder, lap: LapState) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        // Stopwatch parts count from SystemClock.elapsedRealtime(), not the wall clock.
        val elapsedMs = (System.currentTimeMillis() - lap.startedAtEpochMs).coerceAtLeast(0L)
        val status = Status.Builder()
            .addTemplate("Lap · #lap#")
            .addPart("lap", Status.StopwatchPart(SystemClock.elapsedRealtime() - elapsedMs))
            .build()
        OngoingActivity.Builder(context, NOTIFICATION_ID, builder)
            .setStaticIcon(ICON)
            .setTouchIntent(quickLogIntent(context, REQUEST_MORE))
            .setStatus(status)
            .build()
            .apply(context)

        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, builder.build())
    }

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Open Lap", NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun quickLogIntent(context: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode,
            Intent(context, QuickLogActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    private fun receiverIntent(context: Context, action: String, requestCode: Int, activityId: String?): PendingIntent {
        val intent = Intent(context, LapActionReceiver::class.java).setAction(action)
        activityId?.let { intent.putExtra(LapActionReceiver.EXTRA_ACTIVITY_ID, it) }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    /** A small filled circle in the Activity's color. */
    private fun colorDot(colorHex: String): IconCompat {
        val color = try {
            android.graphics.Color.parseColor(colorHex)
        } catch (_: IllegalArgumentException) {
            android.graphics.Color.WHITE
        }
        val size = 48
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        Canvas(bitmap).drawCircle(size / 2f, size / 2f, size / 2f, paint)
        return IconCompat.createWithBitmap(bitmap)
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

    private fun formatDuration(ms: Long): String {
        val totalMinutes = ms.coerceAtLeast(0L) / 60_000
        val hours = totalMinutes / 60
        val minutes = totalMinutes % 60
        return if (hours > 0) "${hours}h ${minutes}m" else "${minutes}m"
    }

    /** Matches the phone's UndoGraceWindow (DayRecorder.defaultUndoGraceWindow). */
    const val UNDO_GRACE_WINDOW_MS = 3_000L
}
