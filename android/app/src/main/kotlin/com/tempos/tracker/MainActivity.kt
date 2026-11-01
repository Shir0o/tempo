package com.tempos.tracker

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity(), DataClient.OnDataChangedListener, MessageClient.OnMessageReceivedListener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var methodChannel: MethodChannel? = null
    private var deepLinkChannel: MethodChannel? = null
    private var initialDeepLink: String? = null

    companion object {
        private const val TAG = "TempoMainActivity"
        const val CHANNEL_NAME = "com.tempos.tracker/wearable"
        const val DEEPLINK_CHANNEL_NAME = "com.tempos.tracker/deeplink"
        const val PATH_ACTIVE_TIMER = "/tempo/active_timer"
        const val PATH_ACTIVITIES = "/tempo/activities"
        const val PATH_ACTIONS_PREFIX = "/tempo/actions/"
        const val PATH_ACTION_RPC = "/tempo/action"

        @Volatile
        var instance: MainActivity? = null
    }

    fun isFlutterEngineRunning(): Boolean {
        return deepLinkChannel != null || methodChannel != null
    }

    fun dispatchDeepLink(url: String) {
        runOnUiThread {
            Log.d(TAG, "Dispatching deep link to Flutter: $url")
            deepLinkChannel?.invokeMethod("onDeepLinkReceived", mapOf("url" to url))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "syncActiveTimer" -> handleSyncActiveTimer(call, result)
                "syncActivities" -> handleSyncActivities(call, result)
                else -> result.notImplemented()
            }
        }

        deepLinkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEEPLINK_CHANNEL_NAME)
        deepLinkChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialDeepLink" -> {
                    result.success(initialDeepLink)
                    initialDeepLink = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this

        val dataString = intent?.dataString
        if (!dataString.isNullOrEmpty()) {
            initialDeepLink = dataString
            Log.d(TAG, "Captured initial deep link: $initialDeepLink")
        }

        try {
            Wearable.getDataClient(this).addListener(this)
            Wearable.getMessageClient(this).addListener(this)
        } catch (e: Exception) {
            Log.w(TAG, "Wearable API init warning: ${e.message}")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val dataString = intent.dataString
        if (!dataString.isNullOrEmpty()) {
            Log.d(TAG, "Captured onNewIntent deep link: $dataString")
            dispatchDeepLink(dataString)
        }
    }

    override fun onDestroy() {
        if (instance == this) {
            instance = null
        }
        try {
            Wearable.getDataClient(this).removeListener(this)
            Wearable.getMessageClient(this).removeListener(this)
        } catch (e: Exception) {
            Log.w(TAG, "Wearable API cleanup warning: ${e.message}")
        }
        super.onDestroy()
    }

    private fun handleSyncActiveTimer(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("INVALID_ARGS", "Expected Map arguments", null)
            return
        }

        val isRunning = args["isRunning"] as? Boolean ?: false
        val activityId = args["activityId"] as? String
        val activityName = args["activityName"] as? String
        val colorHex = args["activityColorHex"] as? String ?: "#4CAF50"
        val startedAt = (args["startedAtEpochMs"] as? Number)?.toLong() ?: 0L
        val isPaused = args["isPaused"] as? Boolean ?: false
        val accPause = (args["accumulatedPauseMs"] as? Number)?.toLong() ?: 0L
        val revision = (args["revision"] as? Number)?.toLong() ?: 0L
        val updatedAt = (args["updatedAtEpochMs"] as? Number)?.toLong() ?: System.currentTimeMillis()

        // Update Quick Settings Tile
        try {
            TempoQuickSettingsTileService.updateTileState(
                this,
                isRunning && !isPaused,
                activityName,
                startedAt
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update Quick Settings Tile: ${e.message}")
        }

        scope.launch {
            try {
                val putRequest = PutDataMapRequest.create(PATH_ACTIVE_TIMER).apply {
                    dataMap.putBoolean("isRunning", isRunning)
                    dataMap.putString("activityId", activityId ?: "")
                    dataMap.putString("activityName", activityName ?: "")
                    dataMap.putString("activityColorHex", colorHex)
                    dataMap.putLong("startedAtEpochMs", startedAt)
                    dataMap.putBoolean("isPaused", isPaused)
                    dataMap.putLong("accumulatedPauseMs", accPause)
                    dataMap.putLong("revision", revision)
                    dataMap.putLong("updatedAtEpochMs", updatedAt)
                }.asPutDataRequest().setUrgent()

                Wearable.getDataClient(this@MainActivity).putDataItem(putRequest).await()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to sync active timer to DataClient", e)
                runOnUiThread { result.error("DATA_CLIENT_ERROR", e.message, null) }
            }
        }
    }

    private fun handleSyncActivities(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val activitiesList = (args?.get("activities") as? List<*>) ?: run {
            result.error("INVALID_ARGS", "Expected 'activities' list", null)
            return
        }

        val jsonArray = JSONArray()
        for (item in activitiesList) {
            if (item is Map<*, *>) {
                val obj = JSONObject().apply {
                    put("id", item["id"] as? String ?: "")
                    put("name", item["name"] as? String ?: "")
                    put("colorHex", item["colorHex"] as? String ?: "#4CAF50")
                    put("iconName", item["iconName"] as? String ?: "schedule")
                    put("isPinned", item["isPinned"] as? Boolean ?: false)
                }
                jsonArray.put(obj)
            }
        }

        scope.launch {
            try {
                val putRequest = PutDataMapRequest.create(PATH_ACTIVITIES).apply {
                    dataMap.putString("activities_json", jsonArray.toString())
                    dataMap.putLong("updatedAtEpochMs", System.currentTimeMillis())
                }.asPutDataRequest()

                Wearable.getDataClient(this@MainActivity).putDataItem(putRequest).await()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to sync activities to DataClient", e)
                runOnUiThread { result.error("DATA_CLIENT_ERROR", e.message, null) }
            }
        }
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type == DataEvent.TYPE_CHANGED) {
                val path = event.dataItem.uri.path ?: continue
                if (path.startsWith(PATH_ACTIONS_PREFIX)) {
                    val dataMap = DataMapItem.fromDataItem(event.dataItem).dataMap
                    val action = dataMap.getString("action") ?: continue
                    val activityId: String? = if (dataMap.containsKey("activityId")) dataMap.getString("activityId") else null
                    val timestamp = dataMap.getLong("timestampEpochMs", System.currentTimeMillis())
                    val actionId: String? = if (dataMap.containsKey("actionId")) dataMap.getString("actionId") else null
                    val comment: String? = if (dataMap.containsKey("comment")) dataMap.getString("comment") else null

                    forwardActionToFlutter(action, activityId, timestamp, actionId, comment)
                }
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path == PATH_ACTION_RPC) {
            try {
                val json = JSONObject(String(messageEvent.data, Charsets.UTF_8))
                val action = json.getString("action")
                val activityId = json.optString("activityId").ifEmpty { null }
                val timestamp = json.optLong("timestampEpochMs", System.currentTimeMillis())
                val actionId = json.optString("actionId").ifEmpty { null }
                val comment = json.optString("comment").ifEmpty { null }

                forwardActionToFlutter(action, activityId, timestamp, actionId, comment)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse RPC message action", e)
            }
        }
    }

    private fun forwardActionToFlutter(
        action: String,
        activityId: String?,
        timestamp: Long,
        actionId: String?,
        comment: String?
    ) {
        runOnUiThread {
            val payload = mapOf(
                "action" to action,
                "activityId" to activityId,
                "timestampEpochMs" to timestamp,
                "actionId" to actionId,
                "comment" to comment
            )
            Log.d(TAG, "Forwarding watch action to Flutter: $action")
            methodChannel?.invokeMethod("onWatchActionReceived", payload)
        }
    }
}
