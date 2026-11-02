package com.tempos.tracker

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

class TempoQuickSettingsTileService : TileService() {

    companion object {
        private const val TAG = "TempoQSTileService"
        const val PREFS_NAME = "tempo_tile_prefs"
        const val KEY_LAP_STARTED_AT = "lap_started_at_ms"

        fun updateTileState(context: Context, startedAtMs: Long) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putLong(KEY_LAP_STARTED_AT, startedAtMs)
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

        val intent = Intent(TempoBroadcastReceiver.ACTION_START_TEMPO).apply {
            setPackage(packageName)
            putExtra(TempoBroadcastReceiver.EXTRA_ACTIVITY, "General")
        }
        sendBroadcast(intent)
    }

    private fun updateTileUI() {
        val tile = qsTile ?: return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val startedAt = prefs.getLong(KEY_LAP_STARTED_AT, 0L)

        tile.state = if (startedAt > 0L) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Tempo"
        tile.subtitle = "Tap to label the Lap"
        tile.updateTile()
    }
}
