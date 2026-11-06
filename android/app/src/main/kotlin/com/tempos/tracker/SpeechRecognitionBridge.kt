package com.tempos.tracker

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognizerIntent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.util.Locale
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The Android half of the speech seam.
 *
 * It launches the system recognition activity with `ACTION_RECOGNIZE_SPEECH`;
 * the recognizer app owns the microphone, so Tempo declares no RECORD_AUDIO.
 * The result is returned through an ActivityAware binding, following
 * BackupDestinationChannel, so MainActivity needs no onActivityResult override.
 *
 * The transcript is never logged.
 */
class SpeechRecognitionBridge : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "tempo/speech"
        private const val REQUEST_RECOGNIZE = 0x5B0
    }

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null

    private val activityResultListener =
        object : PluginRegistry.ActivityResultListener {
            override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
                if (requestCode != REQUEST_RECOGNIZE) return false
                val text = if (resultCode == Activity.RESULT_OK) {
                    data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
                } else {
                    null
                }
                pending?.success(text)
                pending = null
                return true
            }
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(activityResultListener)
    }

    private fun detach() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
        activity = null
        pending?.error("SPEECH_DETACHED", "the recognizer was closed with the app", null)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isRecognizerAvailable())
            "listen" -> listen(result)
            else -> result.notImplemented()
        }
    }

    private fun isRecognizerAvailable(): Boolean {
        val activity = activity ?: return false
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        return activity.packageManager
            .resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null
    }

    private fun listen(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("SPEECH_BUSY", "a recognition is already in flight", null)
            return
        }
        val activity = activity
        if (activity == null) {
            result.error("SPEECH_UNAVAILABLE", "Tempo is not attached to a window", null)
            return
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        }

        pending = result
        try {
            activity.startActivityForResult(intent, REQUEST_RECOGNIZE)
        } catch (e: Exception) {
            pending = null
            result.error("SPEECH_LAUNCH_FAILED", e.message, null)
        }
    }
}
