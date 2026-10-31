package com.tempo.tracker

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

class TempoQuickSettingsTileService : TileService() {

    companion object {
        private const val TAG = "TempoQSTileService"
        const val PREFS_NAME = "tempo_tile_prefs"
        const val KEY_IS_RUNNING = "is_running"
        const val KEY_ACTIVITY_NAME = "activity_name"
        const val KEY_STARTED_AT = "started_at_ms"

        fun updateTileState(
            context: Context,
            isRunning: Boolean,
            activityName: String?,
            startedAtMs: Long
        ) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putBoolean(KEY_IS_RUNNING, isRunning)
                putString(KEY_ACTIVITY_NAME, activityName ?: "")
                putLong(KEY_STARTED_AT, startedAtMs)
                apply()
            }

            try {
                requestListeningState(
                    context,
                    ComponentName(context, TempoQuickSettingsTileService::class.java)
                )
            } catch (e: Exception) {
                Log.w(TAG, "Failed to request tile listening state: ${e.message}")
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileUI()
    }

    override fun onClick() {
        super.onClick()
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val isRunning = prefs.getBoolean(KEY_IS_RUNNING, false)

        val tile = qsTile ?: return

        if (isRunning) {
            // Stop timer
            tile.state = Tile.STATE_INACTIVE
            tile.subtitle = "Stopped"
            tile.updateTile()

            val intent = Intent(TempoBroadcastReceiver.ACTION_STOP_TEMPO).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        } else {
            // Start or toggle timer
            tile.state = Tile.STATE_ACTIVE
            tile.subtitle = "Starting..."
            tile.updateTile()

            val intent = Intent(TempoBroadcastReceiver.ACTION_START_TEMPO).apply {
                setPackage(packageName)
                putExtra(TempoBroadcastReceiver.EXTRA_ACTIVITY, "General")
            }
            sendBroadcast(intent)
        }
    }

    private fun updateTileUI() {
        val tile = qsTile ?: return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val isRunning = prefs.getBoolean(KEY_IS_RUNNING, false)
        val activityName = prefs.getString(KEY_ACTIVITY_NAME, "") ?: ""

        if (isRunning) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = if (activityName.isNotEmpty()) activityName else "Tempo"
            tile.subtitle = "Tracking..."
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "Tempo"
            tile.subtitle = "Tap to start"
        }

        tile.updateTile()
    }
}
