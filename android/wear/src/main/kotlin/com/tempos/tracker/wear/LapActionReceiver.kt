package com.tempos.tracker.wear

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator

/**
 * Handles the Lap notification's actions in the background, so labeling from
 * the notification never brings an activity to the foreground.
 */
class LapActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_LABEL = "com.tempos.tracker.wear.action.LABEL_LAP"
        const val ACTION_UNDO = "com.tempos.tracker.wear.action.UNDO_LABEL"
        const val EXTRA_ACTIVITY_ID = "activityId"

        /** Bumped per label so an older confirmation's revert doesn't cut a newer one short. */
        private var confirmationToken = 0
    }

    override fun onReceive(context: Context, intent: Intent) {
        val repository = WearLapRepository.getInstance(context)
        when (intent.action) {
            ACTION_LABEL -> {
                val activityId = intent.getStringExtra(EXTRA_ACTIVITY_ID) ?: return
                val name = repository.activities.value.find { it.id == activityId }?.name ?: activityId
                val labeledMs = System.currentTimeMillis() - repository.lap.value.startedAtEpochMs
                repository.label(activityId)
                tick(context)
                LapNotification.showLabeled(context, repository, name, labeledMs)

                // Keep the receiver alive through the UndoGraceWindow, then revert.
                val token = ++confirmationToken
                val pending = goAsync()
                Handler(Looper.getMainLooper()).postDelayed({
                    if (token == confirmationToken) {
                        LapNotification.endConfirmation(context, repository)
                    }
                    pending.finish()
                }, LapNotification.UNDO_GRACE_WINDOW_MS)
            }

            ACTION_UNDO -> {
                confirmationToken++
                repository.undo()
                tick(context)
                LapNotification.endConfirmation(context, repository)
            }
        }
    }

    private fun tick(context: Context) {
        context.getSystemService(Vibrator::class.java)
            ?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
    }
}
