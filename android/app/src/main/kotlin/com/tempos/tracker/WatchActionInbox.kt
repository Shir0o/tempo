package com.tempos.tracker

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.DataMap
import org.json.JSONArray
import org.json.JSONObject

/**
 * Normalizes the two channels a watch action can arrive on and keeps a durable
 * inbox for actions that reach the phone while the Flutter engine is not
 * running. The watch's own offline queue is the source of truth; this inbox
 * only has to survive until Dart can apply the action and acknowledge it.
 */
object WatchActionInbox {
    private const val TAG = "WatchActionInbox"
    private const val PREFS = "tempo_watch_actions"
    private const val KEY_PENDING = "pending_actions"

    /** Bounded like the watch queue, so the inbox cannot grow without limit. */
    private const val MAX_PENDING = 100

    /** The watch's urgent DataItem payload on `/tempo/actions/<actionId>`. */
    fun fromDataMap(dataMap: DataMap): Map<String, Any?> = mapOf(
        "action" to dataMap.getString("action"),
        "activityId" to dataMap.getString("activityId"),
        "timestampEpochMs" to dataMap.getLong("timestampEpochMs", System.currentTimeMillis()),
        "zoneId" to dataMap.getString("zoneId"),
        "actionId" to dataMap.getString("actionId"),
        "actionSeq" to dataMap.getLong("actionSeq", 0L),
        "deviceId" to dataMap.getString("deviceId"),
        "undoesActionId" to dataMap.getString("undoesActionId"),
        "comment" to dataMap.getString("comment")
    )

    /** The low-latency `/tempo/action` message payload. */
    fun fromMessage(json: JSONObject): Map<String, Any?> = mapOf(
        "action" to json.optionalString("action"),
        "activityId" to json.optionalString("activityId"),
        "timestampEpochMs" to json.optLong("timestampEpochMs", System.currentTimeMillis()),
        "zoneId" to json.optionalString("zoneId"),
        "actionId" to json.optionalString("actionId"),
        "actionSeq" to json.optLong("actionSeq", 0L),
        "deviceId" to json.optionalString("deviceId"),
        "undoesActionId" to json.optionalString("undoesActionId"),
        "comment" to json.optionalString("comment")
    )

    private fun JSONObject.optionalString(key: String): String? =
        if (has(key)) getString(key).ifEmpty { null } else null

    /** Stores [payload], replacing an earlier copy of the same action id. */
    fun append(context: Context, payload: Map<String, Any?>) {
        val actionId = payload["actionId"] as? String
        synchronized(this) {
            val queue = read(context).toMutableList()
            if (actionId != null) queue.removeAll { it["actionId"] == actionId }
            queue.add(payload)
            while (queue.size > MAX_PENDING) queue.removeAt(0)
            write(context, queue)
        }
    }

    /** Drops an action the phone applied, so the next start does not replay it. */
    fun remove(context: Context, actionId: String?) {
        if (actionId.isNullOrEmpty()) return
        synchronized(this) {
            val queue = read(context)
            val kept = queue.filterNot { it["actionId"] == actionId }
            if (kept.size != queue.size) write(context, kept)
        }
    }

    /** Hands every pending action to Dart once, clearing the inbox. */
    fun drain(context: Context): List<Map<String, Any?>> = synchronized(this) {
        val queue = read(context)
        if (queue.isNotEmpty()) write(context, emptyList())
        queue
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun read(context: Context): List<Map<String, Any?>> {
        val raw = prefs(context).getString(KEY_PENDING, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).map { decode(array.getJSONObject(it)) }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read pending watch actions", e)
            emptyList()
        }
    }

    private fun write(context: Context, queue: List<Map<String, Any?>>) {
        val editor = prefs(context).edit()
        if (queue.isEmpty()) {
            editor.remove(KEY_PENDING)
        } else {
            val array = JSONArray()
            for (payload in queue) array.put(encode(payload))
            editor.putString(KEY_PENDING, array.toString())
        }
        editor.apply()
    }

    private fun encode(payload: Map<String, Any?>): JSONObject = JSONObject().apply {
        for ((key, value) in payload) {
            if (value != null) put(key, value)
        }
    }

    private fun decode(json: JSONObject): Map<String, Any?> {
        val payload = LinkedHashMap<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            payload[key] = json.get(key)
        }
        return payload
    }
}
