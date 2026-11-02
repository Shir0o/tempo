package com.tempos.tracker.wear

import android.util.Log
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMap
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONArray

/**
 * WearableSyncListenerService:
 * - Listens for DataItem changes from the phone on /tempo/active_timer, which
 *   now carries the open Lap (start instant and zone), and /tempo/activities.
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
        val repository = WearLapRepository.getInstance(this)

        for (event in dataEvents) {
            if (event.type == DataEvent.TYPE_CHANGED) {
                val uri = event.dataItem.uri
                val path = uri.path ?: continue

                when (path) {
                    PATH_ACTIVE_TIMER -> {
                        val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                        Log.d(TAG, "Received Lap update from phone: start=${dataMap.getLong("lapStartedAtEpochMs", 0L)}")
                        repository.updateFromPhone(dataMap)
                    }
                    PATH_ACTIVITIES -> {
                        val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                        val json = dataMap.getString("activities_json")
                        if (!json.isNullOrEmpty()) {
                            try {
                                val list = parseActivities(json)
                                val tileIds = parseTileActivityIds(dataMap)
                                Log.d(TAG, "Received ${list.size} activities from phone")
                                repository.saveActivities(list, tileIds)
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to parse activities json", e)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun parseActivities(json: String): List<WearActivity> {
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
        return list
    }

    /**
     * The tile's ranked slots. Payloads from phone builds before the ranking
     * existed simply have no ids, so the tile falls back to Activity order.
     */
    private fun parseTileActivityIds(dataMap: DataMap): List<String> {
        val json = dataMap.getString("tileActivityIds_json")
        if (json.isNullOrEmpty()) return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { array.getString(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse tile activity ids: ${e.message}")
            emptyList()
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        Log.d(TAG, "Received message on path: ${messageEvent.path}")
        if (messageEvent.path == "/tempo/ping") {
            WearLapRepository.getInstance(this).flushOfflineQueue()
        }
    }

    override fun onPeerConnected(peer: Node) {
        Log.d(TAG, "Phone node connected: ${peer.displayName} (${peer.id}), flushing offline queue")
        WearLapRepository.getInstance(this).flushOfflineQueue()
    }
}
