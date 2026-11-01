package com.tempos.tracker.wear

import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataMap
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class ActiveTimerState(
    val isRunning: Boolean = false,
    val activityId: String? = null,
    val activityName: String? = null,
    val activityColorHex: String? = null,
    val startedAtEpochMs: Long = 0L,
    val isPaused: Boolean = false,
    val accumulatedPauseMs: Long = 0L,
    val revision: Long = 0L,
    val updatedAtEpochMs: Long = 0L
)

data class WearActivity(
    val id: String,
    val name: String,
    val colorHex: String = "#4CAF50",
    val iconName: String = "schedule",
    val isPinned: Boolean = false
)

data class WatchAction(
    val actionId: String = UUID.randomUUID().toString(),
    val type: String, // "START", "STOP", "PAUSE", "RESUME", "UNDO"
    val activityId: String? = null,
    val timestampEpochMs: Long = System.currentTimeMillis(),
    val comment: String? = null
)

class WearTimerRepository private constructor(private val context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefs: SharedPreferences =
        context.getSharedPreferences("tempo_wear_prefs", Context.MODE_PRIVATE)

    private val _activeTimerState = MutableStateFlow(loadActiveTimer())
    val activeTimerState: StateFlow<ActiveTimerState> = _activeTimerState.asStateFlow()

    private val _activities = MutableStateFlow(loadActivities())
    val activities: StateFlow<List<WearActivity>> = _activities.asStateFlow()

    companion object {
        private const val TAG = "WearTimerRepository"
        private const val PREF_IS_RUNNING = "is_running"
        private const val PREF_ACTIVITY_ID = "activity_id"
        private const val PREF_ACTIVITY_NAME = "activity_name"
        private const val PREF_ACTIVITY_COLOR = "activity_color"
        private const val PREF_STARTED_AT = "started_at"
        private const val PREF_IS_PAUSED = "is_paused"
        private const val PREF_ACC_PAUSE = "acc_pause"
        private const val PREF_REVISION = "revision"
        private const val PREF_UPDATED_AT = "updated_at"
        private const val PREF_ACTIVITIES_JSON = "activities_json"
        private const val PREF_OFFLINE_QUEUE_JSON = "offline_queue_json"

        @Volatile
        private var instance: WearTimerRepository? = null

        fun getInstance(context: Context): WearTimerRepository {
            return instance ?: synchronized(this) {
                instance ?: WearTimerRepository(context.applicationContext).also { instance = it }
            }
        }
    }

    private fun loadActiveTimer(): ActiveTimerState {
        val isRunning = prefs.getBoolean(PREF_IS_RUNNING, false)
        val activityId = prefs.getString(PREF_ACTIVITY_ID, null)
        val activityName = prefs.getString(PREF_ACTIVITY_NAME, null)
        val colorHex = prefs.getString(PREF_ACTIVITY_COLOR, "#4CAF50")
        val startedAt = prefs.getLong(PREF_STARTED_AT, 0L)
        val isPaused = prefs.getBoolean(PREF_IS_PAUSED, false)
        val accPause = prefs.getLong(PREF_ACC_PAUSE, 0L)
        val revision = prefs.getLong(PREF_REVISION, 0L)
        val updatedAt = prefs.getLong(PREF_UPDATED_AT, 0L)

        return ActiveTimerState(
            isRunning = isRunning,
            activityId = activityId,
            activityName = activityName,
            activityColorHex = colorHex,
            startedAtEpochMs = startedAt,
            isPaused = isPaused,
            accumulatedPauseMs = accPause,
            revision = revision,
            updatedAtEpochMs = updatedAt
        )
    }

    private fun saveActiveTimer(state: ActiveTimerState) {
        prefs.edit()
            .putBoolean(PREF_IS_RUNNING, state.isRunning)
            .putString(PREF_ACTIVITY_ID, state.activityId)
            .putString(PREF_ACTIVITY_NAME, state.activityName)
            .putString(PREF_ACTIVITY_COLOR, state.activityColorHex)
            .putLong(PREF_STARTED_AT, state.startedAtEpochMs)
            .putBoolean(PREF_IS_PAUSED, state.isPaused)
            .putLong(PREF_ACC_PAUSE, state.accumulatedPauseMs)
            .putLong(PREF_REVISION, state.revision)
            .putLong(PREF_UPDATED_AT, state.updatedAtEpochMs)
            .apply()
    }

    private fun loadActivities(): List<WearActivity> {
        val json = prefs.getString(PREF_ACTIVITIES_JSON, null)
        if (json.isNullOrEmpty()) {
            return defaultActivities()
        }
        return try {
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
            if (list.isEmpty()) defaultActivities() else list
        } catch (e: Exception) {
            Log.e(TAG, "Error loading activities from prefs", e)
            defaultActivities()
        }
    }

    private fun defaultActivities(): List<WearActivity> = listOf(
        WearActivity(id = "act_coding", name = "Coding", colorHex = "#2563EB", isPinned = true),
        WearActivity(id = "act_workout", name = "Workout", colorHex = "#10B981", isPinned = true),
        WearActivity(id = "act_reading", name = "Reading", colorHex = "#F59E0B", isPinned = true),
        WearActivity(id = "act_meeting", name = "Meeting", colorHex = "#8B5CF6", isPinned = false)
    )

    fun saveActivities(activities: List<WearActivity>) {
        val array = JSONArray()
        for (a in activities) {
            val obj = JSONObject().apply {
                put("id", a.id)
                put("name", a.name)
                put("colorHex", a.colorHex)
                put("iconName", a.iconName)
                put("isPinned", a.isPinned)
            }
            array.put(obj)
        }
        prefs.edit().putString(PREF_ACTIVITIES_JSON, array.toString()).apply()
        _activities.value = activities
        notifySurfaces()
    }

    fun startTimer(activity: WearActivity) {
        val now = System.currentTimeMillis()
        val newState = ActiveTimerState(
            isRunning = true,
            activityId = activity.id,
            activityName = activity.name,
            activityColorHex = activity.colorHex,
            startedAtEpochMs = now,
            isPaused = false,
            accumulatedPauseMs = 0L,
            revision = _activeTimerState.value.revision + 1,
            updatedAtEpochMs = now
        )
        _activeTimerState.value = newState
        saveActiveTimer(newState)

        val action = WatchAction(
            type = "START",
            activityId = activity.id,
            timestampEpochMs = now
        )
        dispatchAction(action)
        notifySurfaces()
    }

    fun stopTimer() {
        val now = System.currentTimeMillis()
        val newState = ActiveTimerState(
            isRunning = false,
            activityId = null,
            activityName = null,
            activityColorHex = null,
            startedAtEpochMs = 0L,
            isPaused = false,
            accumulatedPauseMs = 0L,
            revision = _activeTimerState.value.revision + 1,
            updatedAtEpochMs = now
        )
        _activeTimerState.value = newState
        saveActiveTimer(newState)

        val action = WatchAction(
            type = "STOP",
            activityId = null,
            timestampEpochMs = now
        )
        dispatchAction(action)
        notifySurfaces()
    }

    fun pauseTimer() {
        val current = _activeTimerState.value
        if (!current.isRunning || current.isPaused) return
        val now = System.currentTimeMillis()
        val newState = current.copy(
            isPaused = true,
            revision = current.revision + 1,
            updatedAtEpochMs = now
        )
        _activeTimerState.value = newState
        saveActiveTimer(newState)

        val action = WatchAction(type = "PAUSE", timestampEpochMs = now)
        dispatchAction(action)
        notifySurfaces()
    }

    fun resumeTimer() {
        val current = _activeTimerState.value
        if (!current.isRunning || !current.isPaused) return
        val now = System.currentTimeMillis()
        val newState = current.copy(
            isPaused = false,
            revision = current.revision + 1,
            updatedAtEpochMs = now
        )
        _activeTimerState.value = newState
        saveActiveTimer(newState)

        val action = WatchAction(type = "RESUME", timestampEpochMs = now)
        dispatchAction(action)
        notifySurfaces()
    }

    fun undoTimer() {
        val now = System.currentTimeMillis()
        val newState = ActiveTimerState(
            isRunning = false,
            activityId = null,
            activityName = null,
            activityColorHex = null,
            startedAtEpochMs = 0L,
            isPaused = false,
            accumulatedPauseMs = 0L,
            revision = _activeTimerState.value.revision + 1,
            updatedAtEpochMs = now
        )
        _activeTimerState.value = newState
        saveActiveTimer(newState)

        val action = WatchAction(type = "UNDO", timestampEpochMs = now)
        dispatchAction(action)
        notifySurfaces()
    }

    fun updateFromPhone(dataMap: DataMap) {
        val isRunning = dataMap.getBoolean("isRunning", false)
        val activityId = dataMap.getString("activityId")
        val activityName = dataMap.getString("activityName")
        val colorHex = dataMap.getString("activityColorHex", "#4CAF50")
        val startedAt = dataMap.getLong("startedAtEpochMs", 0L)
        val isPaused = dataMap.getBoolean("isPaused", false)
        val accPause = dataMap.getLong("accumulatedPauseMs", 0L)
        val revision = dataMap.getLong("revision", 0L)
        val updatedAt = dataMap.getLong("updatedAtEpochMs", System.currentTimeMillis())

        val state = ActiveTimerState(
            isRunning = isRunning,
            activityId = activityId,
            activityName = activityName,
            activityColorHex = colorHex,
            startedAtEpochMs = startedAt,
            isPaused = isPaused,
            accumulatedPauseMs = accPause,
            revision = revision,
            updatedAtEpochMs = updatedAt
        )
        _activeTimerState.value = state
        saveActiveTimer(state)
        notifySurfaces()
    }

    private fun dispatchAction(action: WatchAction) {
        enqueueOfflineAction(action)
        scope.launch {
            try {
                // 1. Put DataItem with setUrgent() for durable replication
                val request = PutDataMapRequest.create("/tempo/actions/${action.actionId}").apply {
                    dataMap.putString("actionId", action.actionId)
                    dataMap.putString("action", action.type)
                    action.activityId?.let { dataMap.putString("activityId", it) }
                    dataMap.putLong("timestampEpochMs", action.timestampEpochMs)
                    action.comment?.let { dataMap.putString("comment", it) }
                }.asPutDataRequest().setUrgent()

                Wearable.getDataClient(context).putDataItem(request).await()
                Log.d(TAG, "Successfully dispatched urgent action: ${action.type}")

                // Also attempt low-latency MessageClient RPC to connected nodes
                sendActionMessage(action)

                dequeueOfflineAction(action.actionId)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to immediately dispatch action (buffered in offline queue): ${e.message}")
            }
        }
    }

    private suspend fun sendActionMessage(action: WatchAction) {
        try {
            val nodes = Wearable.getNodeClient(context).connectedNodes.await()
            val payload = JSONObject().apply {
                put("actionId", action.actionId)
                put("action", action.type)
                action.activityId?.let { put("activityId", it) }
                put("timestampEpochMs", action.timestampEpochMs)
                action.comment?.let { put("comment", it) }
            }.toString().toByteArray(Charsets.UTF_8)

            for (node in nodes) {
                Wearable.getMessageClient(context).sendMessage(node.id, "/tempo/action", payload).await()
            }
        } catch (e: Exception) {
            Log.w(TAG, "MessageClient send skipped/failed: ${e.message}")
        }
    }

    private fun enqueueOfflineAction(action: WatchAction) {
        synchronized(this) {
            val queue = getOfflineQueue().toMutableList()
            queue.add(action)
            saveOfflineQueue(queue)
        }
    }

    private fun dequeueOfflineAction(actionId: String) {
        synchronized(this) {
            val queue = getOfflineQueue().filter { it.actionId != actionId }
            saveOfflineQueue(queue)
        }
    }

    fun getOfflineQueue(): List<WatchAction> {
        val json = prefs.getString(PREF_OFFLINE_QUEUE_JSON, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            val list = mutableListOf<WatchAction>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                list.add(
                    WatchAction(
                        actionId = obj.getString("actionId"),
                        type = obj.getString("action"),
                        activityId = obj.optString("activityId").ifEmpty { null },
                        timestampEpochMs = obj.getLong("timestampEpochMs"),
                        comment = obj.optString("comment").ifEmpty { null }
                    )
                )
            }
            list
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun saveOfflineQueue(queue: List<WatchAction>) {
        val array = JSONArray()
        for (a in queue) {
            val obj = JSONObject().apply {
                put("actionId", a.actionId)
                put("action", a.type)
                a.activityId?.let { put("activityId", it) }
                put("timestampEpochMs", a.timestampEpochMs)
                a.comment?.let { put("comment", it) }
            }
            array.put(obj)
        }
        prefs.edit().putString(PREF_OFFLINE_QUEUE_JSON, array.toString()).apply()
    }

    fun flushOfflineQueue() {
        scope.launch {
            val pending = getOfflineQueue()
            if (pending.isEmpty()) return@launch
            Log.d(TAG, "Flushing ${pending.size} offline buffered actions")
            for (action in pending) {
                try {
                    val request = PutDataMapRequest.create("/tempo/actions/${action.actionId}").apply {
                        dataMap.putString("actionId", action.actionId)
                        dataMap.putString("action", action.type)
                        action.activityId?.let { dataMap.putString("activityId", it) }
                        dataMap.putLong("timestampEpochMs", action.timestampEpochMs)
                        action.comment?.let { dataMap.putString("comment", it) }
                    }.asPutDataRequest().setUrgent()

                    Wearable.getDataClient(context).putDataItem(request).await()
                    dequeueOfflineAction(action.actionId)
                    Log.d(TAG, "Flushed action: ${action.actionId}")
                } catch (e: Exception) {
                    Log.w(TAG, "Offline flush retry paused: ${e.message}")
                    break
                }
            }
        }
    }

    fun notifySurfaces() {
        try {
            TempoComplicationService.requestUpdate(context)
        } catch (e: Exception) {
            Log.w(TAG, "Complication update notify error: ${e.message}")
        }
        try {
            TempoTileService.requestUpdate(context)
        } catch (e: Exception) {
            Log.w(TAG, "Tile update notify error: ${e.message}")
        }
    }
}
