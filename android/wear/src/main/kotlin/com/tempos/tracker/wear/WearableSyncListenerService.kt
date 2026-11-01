package com.tempos.tracker.wear

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONArray
import org.json.JSONObject

/**
 * WearableSyncListenerService:
 * - Listens for DataItem changes from the phone on /tempo/active_timer and /tempo/activities.
 * - Flushes buffered offline actions upon peer connection (onPeerConnected).
 * - Dispatches updates to Complication and Tile providers.
 */
class WearableSyncListenerService : WearableListenerService() {

    companion object {
        private const val TAG = "WearableSyncListener"
        private const val PATH_ACTIVE_TIMER = "/tempo/active_timer"
        private const val PATH_ACTIVITIES = "/tempo/activities"
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        val repository = WearTimerRepository.getInstance(this)

        for (event in dataEvents) {
            if (event.type == DataEvent.TYPE_CHANGED) {
                val uri = event.dataItem.uri
                val path = uri.path ?: continue

                when (path) {
                    PATH_ACTIVE_TIMER -> {
                        val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                        Log.d(TAG, "Received active timer update from phone: isRunning=${dataMap.getBoolean("isRunning")}")
                        repository.updateFromPhone(dataMap)
                    }
                    PATH_ACTIVITIES -> {
                        val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                        val json = dataMap.getString("activities_json")
                        if (!json.isNullOrEmpty()) {
                            try {
                                val array = JSONArray(json)
                                val list = mutableListOf<WearActivity>()
                                for (i in 0 until array.length()) {
                                    val obj = array.getJSONObject(i)
                                    list.add(
                                        WearActivity(
                                            id = obj.getString("id"),
                                            name = obj.getString("name"),
                                            colorHex = obj.optString("colorHex", "#4CAF50"),
                                            iconName = obj.optString("iconName", "schedule"),
                                            isPinned = obj.optBoolean("isPinned", false)
                                        )
                                    )
                                }
                                Log.d(TAG, "Received ${list.size} activities from phone")
                                repository.saveActivities(list)
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to parse activities json", e)
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        Log.d(TAG, "Received message on path: ${messageEvent.path}")
        if (messageEvent.path == "/tempo/ping") {
            WearTimerRepository.getInstance(this).flushOfflineQueue()
        }
    }

    override fun onPeerConnected(peer: Node) {
        Log.d(TAG, "Phone node connected: ${peer.displayName} (${peer.id}), flushing offline queue")
        WearTimerRepository.getInstance(this).flushOfflineQueue()
    }
}
