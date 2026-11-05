package com.tempos.tracker.wear

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
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
    /** Per-watch monotonic counter; the phone acknowledges the highest applied. */
    val actionSeq: Long = 0L,
    val type: String, // "LABEL", "SPLIT" or "UNDO"
    val activityId: String? = null,
    val timestampEpochMs: Long = System.currentTimeMillis(),
    val timezoneId: String = ZoneId.systemDefault().id,
    /** For an UNDO, the label it reverses. */
    val undoesActionId: String? = null,
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

    /** The Lap as it was before the last [label], restored by [undo]. */
    @Volatile
    private var lapBeforeLabel: LapState? = null

    /** The action id of the last [label], carried by the [undo] that reverses it. */
    @Volatile
    private var lastLabelActionId: String? = null

    /** Guards the visible notice so one burst of failures shows one notice. */
    @Volatile
    private var lastNoticeEpochMs = 0L

    companion object {
        private const val TAG = "WearLapRepository"
        private const val PREF_LAP_STARTED_AT = "lap_started_at"
        private const val PREF_LAP_STARTED_TZ = "lap_started_timezone"
        private const val PREF_LAP_REVISION = "lap_revision"
        private const val PREF_LAP_UPDATED_AT = "lap_updated_at"
        private const val PREF_ACTIVITIES_JSON = "activities_json"
        private const val PREF_TILE_ACTIVITY_IDS_JSON = "tile_activity_ids_json"
        private const val PREF_OFFLINE_QUEUE_JSON = "offline_queue_json"
        private const val PREF_ACTION_SEQ = "action_seq"
        private const val PREF_DEVICE_ID = "device_id"
        private const val TILE_SLOT_COUNT = 3

        /** The queue holds 50 actions; beyond that the oldest is dropped. */
        private const val MAX_PENDING_ACTIONS = 50
        private const val NOTICE_DEDUPE_MS = 2_000L

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
        lapBeforeLabel = _lap.value
        openLapFrom(now)
        val action = WatchAction(
            actionSeq = nextActionSeq(),
            type = "LABEL",
            activityId = activityId,
            timestampEpochMs = now,
            timezoneId = ZoneId.systemDefault().id
        )
        lastLabelActionId = action.actionId
        dispatchAction(action)
        notifySurfaces()
    }

    /** Closes the open Lap as an Untracked Record; the phone marks the boundary. */
    fun split() {
        val now = System.currentTimeMillis()
        lapBeforeLabel = null
        lastLabelActionId = null
        openLapFrom(now)
        dispatchAction(
            WatchAction(
                actionSeq = nextActionSeq(),
                type = "SPLIT",
                timestampEpochMs = now,
                timezoneId = ZoneId.systemDefault().id
            )
        )
        notifySurfaces()
    }

    /**
     * Reverses the last [label] inside the UndoGraceWindow: the Lap goes back
     * to its previous start here, and the phone deletes the Record it wrote.
     * The undo carries the id of the label it reverses.
     */
    fun undo() {
        val previous = lapBeforeLabel ?: return
        val undoesActionId = lastLabelActionId
        lapBeforeLabel = null
        lastLabelActionId = null
        val now = System.currentTimeMillis()
        val restored = previous.copy(revision = _lap.value.revision + 1, updatedAtEpochMs = now)
        _lap.value = restored
        saveLap(restored)
        dispatchAction(
            WatchAction(
                actionSeq = nextActionSeq(),
                type = "UNDO",
                timestampEpochMs = now,
                timezoneId = ZoneId.systemDefault().id,
                undoesActionId = undoesActionId
            )
        )
        notifySurfaces()
    }

    /** The watch's own identity, so the phone keys its watermark by device. */
    private val deviceId: String by lazy {
        prefs.getString(PREF_DEVICE_ID, null)
            ?: UUID.randomUUID().toString().also {
                prefs.edit().putString(PREF_DEVICE_ID, it).apply()
            }
    }

    /** Allocates the next sequence before any network call, so a retry keeps it. */
    private fun nextActionSeq(): Long = synchronized(this) {
        val next = prefs.getLong(PREF_ACTION_SEQ, 0L) + 1L
        prefs.edit().putLong(PREF_ACTION_SEQ, next).apply()
        next
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

    /**
     * Applies the phone's acknowledgement: pending actions at or below
     * [appliedActionSeq] are done and leave the queue, and [rejectedActionIds]
     * are dropped instead of retried. A rejection also rolls the optimistic
     * Lap back, because the phone's Lap is the one that actually happened.
     */
    fun applyAcknowledgement(appliedActionSeq: Long, rejectedActionIds: List<String>) {
        pruneAcknowledged(appliedActionSeq)
        discardRejected(rejectedActionIds)

        if (rejectedActionIds.isEmpty()) return
        lapBeforeLabel = null
        lastLabelActionId = null
        postNotice("A label couldn't be applied")
    }

    private fun dispatchAction(action: WatchAction) {
        enqueueOfflineAction(action)
        scope.launch {
            try {
                // Put DataItem with setUrgent() for durable replication. It stays
                // pending until the phone acknowledges its sequence: a DataItem
                // outlives this process and is re-read after a queue restore.
                Wearable.getDataClient(context).putDataItem(
                    putActionRequest(action).asPutDataRequest().setUrgent()
                ).await()
                Log.d(TAG, "Dispatched urgent action ${action.actionId} (seq ${action.actionSeq})")

                // Also attempt low-latency MessageClient RPC to connected nodes
                sendActionMessage(action)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to immediately dispatch action (still pending): ${e.message}")
            }
        }
    }

    private fun putActionRequest(action: WatchAction): PutDataMapRequest {
        return PutDataMapRequest.create("/tempo/actions/${action.actionId}").apply {
            dataMap.putString("actionId", action.actionId)
            dataMap.putLong("actionSeq", action.actionSeq)
            dataMap.putString("deviceId", deviceId)
            dataMap.putString("action", action.type)
            action.activityId?.let { dataMap.putString("activityId", it) }
            dataMap.putLong("timestampEpochMs", action.timestampEpochMs)
            dataMap.putString("zoneId", action.timezoneId)
            action.undoesActionId?.let { dataMap.putString("undoesActionId", it) }
            action.comment?.let { dataMap.putString("comment", it) }
        }
    }

    private suspend fun sendActionMessage(action: WatchAction) {
        try {
            val nodes = Wearable.getNodeClient(context).connectedNodes.await()
            val payload = JSONObject().apply {
                put("actionId", action.actionId)
                put("actionSeq", action.actionSeq)
                put("deviceId", deviceId)
                put("action", action.type)
                action.activityId?.let { put("activityId", it) }
                put("timestampEpochMs", action.timestampEpochMs)
                put("zoneId", action.timezoneId)
                action.undoesActionId?.let { put("undoesActionId", it) }
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
        val dropped = synchronized(this) {
            val queue = getOfflineQueue().toMutableList()
            queue.add(action)
            var oldest: WatchAction? = null
            while (queue.size > MAX_PENDING_ACTIONS) {
                oldest = queue.removeAt(0)
            }
            saveOfflineQueue(queue)
            oldest
        }
        if (dropped != null) {
            Log.w(TAG, "Pending queue full; dropped action ${dropped.actionId}")
            postNotice("Watch queue full: a label was lost")
        }
    }

    private fun pruneAcknowledged(appliedActionSeq: Long) {
        if (appliedActionSeq <= 0L) return
        synchronized(this) {
            val queue = getOfflineQueue()
            // Anything at or below the watermark is done. An action queued
            // before sequences existed carries 0 and can never be acknowledged,
            // so it goes here too rather than being re-sent and applied twice.
            val kept = queue.filter { it.actionSeq > appliedActionSeq }
            if (kept.size == queue.size) return
            saveOfflineQueue(kept)
            Log.d(TAG, "Acknowledged ${queue.size - kept.size} actions up to $appliedActionSeq")
        }
    }

    private fun discardRejected(rejectedActionIds: List<String>) {
        if (rejectedActionIds.isEmpty()) return
        synchronized(this) {
            val rejected = rejectedActionIds.toSet()
            val queue = getOfflineQueue()
            val kept = queue.filter { it.actionId !in rejected }
            if (kept.size != queue.size) {
                saveOfflineQueue(kept)
                Log.w(TAG, "Phone rejected ${queue.size - kept.size} actions")
            }
        }
    }

    private fun postNotice(message: String) {
        val now = System.currentTimeMillis()
        if (now - lastNoticeEpochMs < NOTICE_DEDUPE_MS) return
        lastNoticeEpochMs = now
        Handler(Looper.getMainLooper()).post {
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
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
                        actionSeq = obj.optLong("actionSeq", 0L),
                        type = obj.getString("action"),
                        activityId = obj.optString("activityId").ifEmpty { null },
                        timestampEpochMs = obj.getLong("timestampEpochMs"),
                        timezoneId = obj.optString("timezoneId", ""),
                        undoesActionId = obj.optString("undoesActionId").ifEmpty { null },
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
                put("actionSeq", a.actionSeq)
                put("action", a.type)
                a.activityId?.let { put("activityId", it) }
                put("timestampEpochMs", a.timestampEpochMs)
                put("timezoneId", a.timezoneId)
                a.undoesActionId?.let { put("undoesActionId", it) }
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
            Log.d(TAG, "Flushing ${pending.size} unacknowledged actions")
            for (action in pending) {
                try {
                    Wearable.getDataClient(context).putDataItem(
                        putActionRequest(action).asPutDataRequest().setUrgent()
                    ).await()
                    sendActionMessage(action)
                    Log.d(TAG, "Re-sent action: ${action.actionId} (seq ${action.actionSeq})")
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
        try {
            LapNotification.update(context, this)
        } catch (e: Exception) {
            Log.w(TAG, "Lap notification update error: ${e.message}")
        }
    }
}
