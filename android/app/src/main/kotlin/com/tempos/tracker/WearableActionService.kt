package com.tempos.tracker

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/**
 * Receives the watch's labels even when no Flutter Activity is alive. Google
 * Play Services starts this service for a manifest-declared listener, which is
 * the only way a DataItem sent while the phone app was closed can reach the
 * app later. Anything that cannot be handed to a running engine is buffered in
 * [WatchActionInbox] for the next start.
 */
class WearableActionService : WearableListenerService() {

    companion object {
        private const val TAG = "WearableActionService"
        private const val PATH_ACTIONS_PREFIX = "/tempo/actions/"
        private const val PATH_ACTION_RPC = "/tempo/action"
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val path = event.dataItem.uri.path ?: continue
            if (!path.startsWith(PATH_ACTIONS_PREFIX)) continue
            val payload = WatchActionInbox.fromDataMap(
                DataMapItem.fromDataItem(event.dataItem).dataMap
            )
            deliver(payload)
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path != PATH_ACTION_RPC) return
        val payload = try {
            WatchActionInbox.fromMessage(
                JSONObject(String(messageEvent.data, Charsets.UTF_8))
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse watch action message", e)
            return
        }
        deliver(payload)
    }

    private fun deliver(payload: Map<String, Any?>) {
        if (payload["action"] == null) return
        val actionId = payload["actionId"] as? String

        // Persist first: the engine may die between here and Dart applying it.
        WatchActionInbox.append(applicationContext, payload)

        val activity = MainActivity.instance
        if (activity?.dispatchWatchAction(payload) == true) {
            Log.d(TAG, "Forwarded watch action $actionId to the running app")
        } else {
            Log.d(TAG, "Buffered watch action $actionId until the app starts")
        }
    }
}
