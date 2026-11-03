package com.tempos.tracker.wear

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
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
import java.time.ZoneId
import java.util.UUID

/**
 * The open, always-running Lap as the watch knows it: a start instant and the
 * zone it started in.
 */
data class LapState(
    val startedAtEpochMs: Long = 0L,
    val startedTimezoneId: String = "",
    val revision: Long = 0L,
    val updatedAtEpochMs: Long = 0L
) {
    val isOpen: Boolean get() = startedAtEpochMs > 0L
}

data class WearActivity(
    val id: String,
    val name: String,
    val colorHex: String = "#4CAF50",
    val iconName: String = "schedule",
    val isPinned: Boolean = false
)

data class WatchAction(
    val actionId: String = UUID.randomUUID().toString(),
    val type: String, // "LABEL" or "SPLIT"
    val activityId: String? = null,
    val timestampEpochMs: Long = System.currentTimeMillis(),
    val comment: String? = null
)

/**
 * Single source of truth for the watch: the open Lap, the Activity list and the
 * tile's ranked slots, all mirrored from the phone over the Data Layer.
 */
class WearLapRepository private constructor(private val context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefs: SharedPreferences =
        context.getSharedPreferences("tempo_wear_prefs", Context.MODE_PRIVATE)

    private val _lap = MutableStateFlow(loadLap())
    val lap: StateFlow<LapState> = _lap.asStateFlow()

    private val _activities = MutableStateFlow(loadActivities())
    val activities: StateFlow<List<WearActivity>> = _activities.asStateFlow()

    companion object {
        private const val TAG = "WearLapRepository"
        private const val PREF_LAP_STARTED_AT = "lap_started_at"
        private const val PREF_LAP_STARTED_TZ = "lap_started_timezone"
        private const val PREF_LAP_REVISION = "lap_revision"
        private const val PREF_LAP_UPDATED_AT = "lap_updated_at"
        private const val PREF_ACTIVITIES_JSON = "activities_json"
        private const val PREF_TILE_ACTIVITY_IDS_JSON = "tile_activity_ids_json"
        private const val PREF_OFFLINE_QUEUE_JSON = "offline_queue_json"
        private const val TILE_SLOT_COUNT = 3

        @Volatile
        private var instance: WearLapRepository? = null

        fun getInstance(context: Context): WearLapRepository {
            return instance ?: synchronized(this) {
                instance ?: WearLapRepository(context.applicationContext).also { instance = it }
            }
        }
    }

    private fun loadLap(): LapState {
        return LapState(
            startedAtEpochMs = prefs.getLong(PREF_LAP_STARTED_AT, 0L),
            startedTimezoneId = prefs.getString(PREF_LAP_STARTED_TZ, "") ?: "",
            revision = prefs.getLong(PREF_LAP_REVISION, 0L),
            updatedAtEpochMs = prefs.getLong(PREF_LAP_UPDATED_AT, 0L)
        )
    }

    private fun saveLap(state: LapState) {
        prefs.edit()
            .putLong(PREF_LAP_STARTED_AT, state.startedAtEpochMs)
            .putString(PREF_LAP_STARTED_TZ, state.startedTimezoneId)
            .putLong(PREF_LAP_REVISION, state.revision)
            .putLong(PREF_LAP_UPDATED_AT, state.updatedAtEpochMs)
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
        WearActivity(id = "act_sleep", name = "Sleep", colorHex = "#9AA5C8", isPinned = true),
        WearActivity(id = "act_meals", name = "Meals", colorHex = "#FFC94A", isPinned = true),
        WearActivity(id = "act_errands", name = "Errands", colorHex = "#C6F432", isPinned = true)
    )

    /**
     * Stores the Activity list and the tile's ranked slots. [tileActivityIds]
     * is ordered most-used first; an empty list falls back to the Activity
     * order so a fresh install still has three tappable slots.
     */
    fun saveActivities(activities: List<WearActivity>, tileActivityIds: List<String> = emptyList()) {
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

        val tileArray = JSONArray()
        for (id in tileActivityIds) {
            tileArray.put(id)
        }

        prefs.edit()
            .putString(PREF_ACTIVITIES_JSON, array.toString())
            .putString(PREF_TILE_ACTIVITY_IDS_JSON, tileArray.toString())
            .apply()
        _activities.value = activities
        notifySurfaces()
    }

    /** The tile's three slots: most-used first, padded from the Activity order. */
    fun tileActivities(): List<WearActivity> {
        val byId = _activities.value.associateBy { it.id }
        val ranked = loadTileActivityIds().mapNotNull { byId[it] }
        return (ranked + _activities.value).distinctBy { it.id }.take(TILE_SLOT_COUNT)
    }

    private fun loadTileActivityIds(): List<String> {
        val json = prefs.getString(PREF_TILE_ACTIVITY_IDS_JSON, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { array.getString(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Labels the open Lap as [activityId]; the phone writes the Record. */
    fun label(activityId: String) {
        val now = System.currentTimeMillis()
        openLapFrom(now)
        dispatchAction(WatchAction(type = "LABEL", activityId = activityId, timestampEpochMs = now))
        notifySurfaces()
    }

    /** Closes the open Lap as an Untracked Record; the phone marks the boundary. */
    fun split() {
        val now = System.currentTimeMillis()
        openLapFrom(now)
        dispatchAction(WatchAction(type = "SPLIT", timestampEpochMs = now))
        notifySurfaces()
    }

    /**
     * Moves the Lap start to [nowUtcMs] immediately so the complication resets
     * on the watch face. The phone's authoritative Lap arrives over the Data
     * Layer and replaces it.
     */
    private fun openLapFrom(nowUtcMs: Long) {
        val next = LapState(
            startedAtEpochMs = nowUtcMs,
            startedTimezoneId = ZoneId.systemDefault().id,
            revision = _lap.value.revision + 1,
            updatedAtEpochMs = nowUtcMs
        )
        _lap.value = next
        saveLap(next)
    }

    /** Applies the Lap the phone pushed. */
    fun updateFromPhone(dataMap: DataMap) {
        val lapStartedAt = dataMap.getLong("lapStartedAtEpochMs", 0L).takeIf { it > 0L } ?: 0L

        val state = LapState(
            startedAtEpochMs = lapStartedAt,
            startedTimezoneId = dataMap.getString("lapStartedTimezoneId") ?: "",
            revision = dataMap.getLong("revision", 0L),
            updatedAtEpochMs = dataMap.getLong("updatedAtEpochMs", System.currentTimeMillis())
        )
        _lap.value = state
        saveLap(state)
        notifySurfaces()
    }

    private fun dispatchAction(action: WatchAction) {
        enqueueOfflineAction(action)
        scope.launch {
            try {
                // 1. Put DataItem with setUrgent() for durable replication
                Wearable.getDataClient(context).putDataItem(
                    putActionRequest(action).asPutDataRequest().setUrgent()
                ).await()
                Log.d(TAG, "Successfully dispatched urgent action: ${action.type}")

                // Also attempt low-latency MessageClient RPC to connected nodes
                sendActionMessage(action)

                dequeueOfflineAction(action.actionId)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to immediately dispatch action (buffered in offline queue): ${e.message}")
            }
        }
    }

    private fun putActionRequest(action: WatchAction): PutDataMapRequest {
        return PutDataMapRequest.create("/tempo/actions/${action.actionId}").apply {
            dataMap.putString("actionId", action.actionId)
            dataMap.putString("action", action.type)
            action.activityId?.let { dataMap.putString("activityId", it) }
            dataMap.putLong("timestampEpochMs", action.timestampEpochMs)
            action.comment?.let { dataMap.putString("comment", it) }
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
                    Wearable.getDataClient(context).putDataItem(
                        putActionRequest(action).asPutDataRequest().setUrgent()
                    ).await()
                    dequeueOfflineAction(action.actionId)
                    Log.d(TAG, "Flushed action: ${action.actionId}")
                } catch (e: Exception) {
                    Log.w(TAG, "Offline flush retry deferred: ${e.message}")
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
