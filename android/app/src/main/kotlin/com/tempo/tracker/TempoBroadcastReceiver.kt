package com.tempo.tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log

class TempoBroadcastReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TempoBroadcastReceiver"

        const val ACTION_START_TEMPO = "app.tempo.action.START_TIMER"
        const val ACTION_STOP_TEMPO = "app.tempo.action.STOP_TIMER"
        const val ACTION_TOGGLE_TEMPO = "app.tempo.action.TOGGLE_TIMER"

        const val ACTION_START_LEGACY = "app.timetracker.action.START_TIMER"
        const val ACTION_STOP_LEGACY = "app.timetracker.action.STOP_TIMER"
        const val ACTION_TOGGLE_LEGACY = "app.timetracker.action.TOGGLE_TIMER"

        const val EXTRA_ACTIVITY = "activity"
        const val EXTRA_COMMENT = "comment"
        const val EXTRA_TAGS = "tags"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.d(TAG, "Received broadcast intent: $action")

        val activity = intent.getStringExtra(EXTRA_ACTIVITY)
            ?: intent.getStringExtra("activityName")
            ?: intent.getStringExtra("activityId")
            ?: ""

        val comment = intent.getStringExtra(EXTRA_COMMENT) ?: ""
        val tagsExtra = intent.getCharSequenceArrayListExtra(EXTRA_TAGS)?.joinToString(",")
            ?: intent.getStringExtra(EXTRA_TAGS)
            ?: ""

        val uriBuilder = Uri.Builder().scheme("tempo")

        when (action) {
            ACTION_START_TEMPO, ACTION_START_LEGACY -> {
                uriBuilder.authority("start")
                if (activity.isNotEmpty()) {
                    uriBuilder.appendQueryParameter("activity", activity)
                }
                if (comment.isNotEmpty()) {
                    uriBuilder.appendQueryParameter("comment", comment)
                }
                if (tagsExtra.isNotEmpty()) {
                    uriBuilder.appendQueryParameter("tags", tagsExtra)
                }
            }
            ACTION_STOP_TEMPO, ACTION_STOP_LEGACY -> {
                uriBuilder.authority("stop")
                if (comment.isNotEmpty()) {
                    uriBuilder.appendQueryParameter("comment", comment)
                }
            }
            ACTION_TOGGLE_TEMPO, ACTION_TOGGLE_LEGACY -> {
                uriBuilder.authority("toggle")
                if (activity.isNotEmpty()) {
                    uriBuilder.appendQueryParameter("activity", activity)
                }
            }
            else -> {
                Log.w(TAG, "Unhandled broadcast action: $action")
                return
            }
        }

        val deepLinkUrl = uriBuilder.build().toString()
        Log.d(TAG, "Constructed deep link: $deepLinkUrl")

        val mainActivity = MainActivity.instance
        if (mainActivity != null && mainActivity.isFlutterEngineRunning()) {
            mainActivity.dispatchDeepLink(deepLinkUrl)
        } else {
            // Launch MainActivity with the deep link intent
            val launchIntent = Intent(Intent.ACTION_VIEW, Uri.parse(deepLinkUrl)).apply {
                setClass(context, MainActivity::class.java)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("source", "broadcast")
            }
            context.startActivity(launchIntent)
        }
    }
}
