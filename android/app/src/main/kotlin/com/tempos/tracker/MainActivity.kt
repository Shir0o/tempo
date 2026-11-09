package com.tempos.tracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
    private var notificationChannel: MethodChannel? = null
    private var initialDeepLink: String? = null

    companion object {
        private const val TAG = "TempoMainActivity"
        const val CHANNEL_NAME = "com.tempos.tracker/wearable"
        const val DEEPLINK_CHANNEL_NAME = "com.tempos.tracker/deeplink"
        const val PATH_LAP = "/tempo/lap"
        const val PATH_ACTIVITIES = "/tempo/activities"
        const val PATH_ACTIONS_PREFIX = "/tempo/actions/"
        const val PATH_ACTION_RPC = "/tempo/action"
        const val PATH_PING = "/tempo/ping"
        private const val REQUEST_POST_NOTIFICATIONS = 1

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

    /**
     * Hands a tap on the Lap notification to this engine's Dart side. Returns
     * false when the engine is not up, so the tap runs headless instead.
     */
    fun dispatchNotificationAction(action: Map<String, Any?>): Boolean {
        val channel = notificationChannel ?: return false
        runOnUiThread { channel.invokeMethod("onNotificationAction", action) }
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "syncLap" -> handleSyncLap(call, result)
                "syncActivities" -> handleSyncActivities(call, result)
                // Actions buffered while the Flutter engine was not running.
                "drainPendingWatchActions" ->
                    result.success(WatchActionInbox.drain(applicationContext))
                // Ask every connected watch to re-send anything it still has
                // queued, so labels taken with the phone closed land now.
                "pingWatch" -> {
                    pingWatch()
                    result.success(true)
                }
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

        notificationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LapNotification.CHANNEL_NAME)
        notificationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateLapNotification" -> {
                    (call.arguments as? Map<*, *>)?.let { LapNotification.post(applicationContext, it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        flutterEngine.plugins.add(BackupDestinationChannel())
        flutterEngine.plugins.add(PairingSecretChannel())
        flutterEngine.plugins.add(SpeechRecognitionBridge())
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

        // The ongoing Lap notification needs this from Android 13 on.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST_NOTIFICATIONS)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_POST_NOTIFICATIONS &&
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        ) {
            LapNotification.repost(applicationContext)
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

    private fun handleSyncLap(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("INVALID_ARGS", "Expected Map arguments", null)
            return
        }

        val startedAt = (args["lapStartedAtEpochMs"] as? Number)?.toLong() ?: 0L
        val timezoneId = args["lapStartedTimezoneId"] as? String ?: ""
        val revision = (args["revision"] as? Number)?.toLong() ?: 0L
        val updatedAt = (args["updatedAtEpochMs"] as? Number)?.toLong() ?: System.currentTimeMillis()
        // The highest watch action the phone applied, and the ones it refused.
        val appliedActionSeq = (args["appliedActionSeq"] as? Number)?.toLong() ?: 0L
        val rejectedActionIds = (args["rejectedActionIds"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        // The Activity on the latest Record, so the watch can offer repeat
        // buttons next to its Activity pills.
        val lastActivityId = args["lastActivityId"] as? String ?: ""
        val lastActivityName = args["lastActivityName"] as? String ?: ""
        val lastActivityColorHex = args["lastActivityColorHex"] as? String ?: ""

        // Update Quick Settings Tile
        try {
            TempoQuickSettingsTileService.updateTileState(this, startedAt)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update Quick Settings Tile: ${e.message}")
        }

        scope.launch {
            try {
                val putRequest = PutDataMapRequest.create(PATH_LAP).apply {
                    dataMap.putLong("lapStartedAtEpochMs", startedAt)
                    dataMap.putString("lapStartedTimezoneId", timezoneId)
                    dataMap.putLong("revision", revision)
                    dataMap.putLong("updatedAtEpochMs", updatedAt)
                    dataMap.putLong("appliedActionSeq", appliedActionSeq)
                    dataMap.putStringArrayList("rejectedActionIds", ArrayList(rejectedActionIds))
                    dataMap.putString("lastActivityId", lastActivityId)
                    dataMap.putString("lastActivityName", lastActivityName)
                    dataMap.putString("lastActivityColorHex", lastActivityColorHex)
                }.asPutDataRequest().setUrgent()

                Wearable.getDataClient(this@MainActivity).putDataItem(putRequest).await()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to sync the Lap to DataClient", e)
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
        val tileActivityIds = (args.get("tileActivityIds") as? List<*>)
            ?.filterIsInstance<String>()
            ?: emptyList()

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

        val tileIdsArray = JSONArray().apply {
            for (id in tileActivityIds) put(id)
        }

        scope.launch {
            try {
                val putRequest = PutDataMapRequest.create(PATH_ACTIVITIES).apply {
                    dataMap.putString("activities_json", jsonArray.toString())
                    dataMap.putString("tileActivityIds_json", tileIdsArray.toString())
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
                    dispatchWatchAction(
                        WatchActionInbox.fromDataMap(
                            DataMapItem.fromDataItem(event.dataItem).dataMap
                        )
                    )
                }
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path == PATH_ACTION_RPC) {
            try {
                val json = JSONObject(String(messageEvent.data, Charsets.UTF_8))
                dispatchWatchAction(WatchActionInbox.fromMessage(json))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse RPC message action", e)
            }
        }
    }

    /**
     * Hands [payload] to the Dart side, keeping a durable copy until Dart
     * confirms it applied the action. Returns false when this Activity has no
     * engine yet, so the caller can leave the action in the inbox.
     */
    fun dispatchWatchAction(payload: Map<String, Any?>): Boolean {
        if (payload["action"] == null) return false
        val actionId = payload["actionId"] as? String
        // Durable before anything else: an action the engine cannot take yet
        // must still survive until Dart can drain it.
        WatchActionInbox.append(applicationContext, payload)
        val channel = methodChannel ?: return false
        runOnUiThread {
            channel.invokeMethod(
                "onWatchActionReceived",
                payload,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        WatchActionInbox.remove(applicationContext, actionId)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?
                    ) {
                        Log.w(
                            TAG,
                            "Watch action $actionId not applied: $errorCode $errorMessage"
                        )
                    }

                    override fun notImplemented() {
                        // The Dart handler is not registered yet; it will drain
                        // the inbox once it is.
                    }
                }
            )
        }
        return true
    }

    /** Asks every connected node to flush its pending watch actions. */
    private fun pingWatch() {
        scope.launch {
            try {
                val nodes = Wearable.getNodeClient(this@MainActivity)
                    .connectedNodes
                    .await()
                for (node in nodes) {
                    Wearable.getMessageClient(this@MainActivity)
                        .sendMessage(node.id, PATH_PING, ByteArray(0))
                        .await()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Watch ping skipped: ${e.message}")
            }
        }
    }
}
