package com.tempos.tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Receives taps on the ongoing Lap notification. Not exported: only this app's
 * immutable PendingIntents reach it. The tap runs in the app's own engine when
 * it is alive, otherwise in a [HeadlessLapEngine].
 */
class LapNotificationReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_LABEL = "com.tempos.tracker.notification.LABEL"
        const val ACTION_SPLIT = "com.tempos.tracker.notification.SPLIT"
        const val ACTION_UNDO = "com.tempos.tracker.notification.UNDO"
        const val EXTRA_ACTIVITY_ID = "activityId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val type = when (intent.action) {
            ACTION_LABEL -> "LABEL"
            ACTION_SPLIT -> "SPLIT"
            ACTION_UNDO -> "UNDO"
            else -> return
        }
        val action = mapOf(
            "action" to type,
            "activityId" to intent.getStringExtra(EXTRA_ACTIVITY_ID)
        )

        if (MainActivity.instance?.dispatchNotificationAction(action) == true) return
        HeadlessLapEngine.dispatch(context, action, goAsync())
    }
}

/**
 * Carries out notification taps while the app is not running: boots a
 * FlutterEngine on the Dart entrypoint `notificationActionMain`, which opens
 * the database and DayRecorder exactly as the app does, hands it the taps one
 * at a time, and destroys it once Dart reports the UndoGraceWindow has passed
 * and the CSV export is written. Every tap's broadcast is held open
 * ([BroadcastReceiver.goAsync]) until then, at most [MAX_HOLD_MS].
 *
 * All state is touched on the main thread only.
 */
internal object HeadlessLapEngine {
    private const val TAG = "TempoHeadlessLap"
    private const val ENTRYPOINT = "notificationActionMain"

    /** Under the 10s a receiver may stay open after goAsync(). */
    private const val MAX_HOLD_MS = 9_000L

    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var isReady = false
    private var isBusy = false
    private val queued = ArrayDeque<Map<String, Any?>>()
    private val held = mutableListOf<BroadcastReceiver.PendingResult>()

    private val releaseHeld = Runnable {
        finishHeld()
        // Dart never came up: drop this engine so the next tap starts clean.
        if (!isReady) destroy()
    }

    fun dispatch(context: Context, action: Map<String, Any?>, result: BroadcastReceiver.PendingResult) {
        if (held.isEmpty()) handler.postDelayed(releaseHeld, MAX_HOLD_MS)
        held += result
        queued.addLast(action)
        if (engine == null) start(context.applicationContext) else sendNext()
    }

    private fun start(context: Context) {
        Log.d(TAG, "Starting headless engine for a notification tap")
        val engine = FlutterEngine(context)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, LapNotification.CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateLapNotification" -> {
                    (call.arguments as? Map<*, *>)?.let { LapNotification.post(context, it) }
                    result.success(null)
                }
                "headlessReady" -> {
                    isReady = true
                    result.success(null)
                    sendNext()
                }
                "headlessSettled" -> {
                    result.success(null)
                    handler.post { if (!isBusy && queued.isEmpty()) destroy() }
                }
                else -> result.notImplemented()
            }
        }
        this.engine = engine
        this.channel = channel
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(FlutterInjector.instance().flutterLoader().findAppBundlePath(), ENTRYPOINT)
        )
    }

    /** Sends the next queued tap once Dart is ready and the previous one is done. */
    private fun sendNext() {
        val channel = channel ?: return
        if (!isReady || isBusy) return
        val action = queued.removeFirstOrNull() ?: return
        isBusy = true
        channel.invokeMethod("onNotificationAction", action, object : MethodChannel.Result {
            override fun success(result: Any?) = onSent()

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                Log.w(TAG, "Notification action failed: $errorCode $errorMessage")
                onSent()
            }

            override fun notImplemented() = onSent()
        })
    }

    private fun onSent() {
        isBusy = false
        sendNext()
    }

    private fun destroy() {
        Log.d(TAG, "Destroying headless engine")
        engine?.destroy()
        engine = null
        channel = null
        isReady = false
        isBusy = false
        queued.clear()
        finishHeld()
    }

    private fun finishHeld() {
        handler.removeCallbacks(releaseHeld)
        held.forEach { it.finish() }
        held.clear()
    }
}
