package com.tempos.tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Pairing secrets, kept out of `tempo.db` so no snapshot ever carries a
 * credential.
 *
 * `lib/core/sync/peer_pairing.dart` defines the contract this channel answers:
 * `read`, `write`, `delete`, and `deleteAll`, each keyed by the peer or invite
 * key the Dart side chooses.
 *
 * Each value is sealed with an AES-256-GCM key that never leaves the Android
 * Keystore; only the IV and the ciphertext are written to preferences.
 * `deleteAll` drops both, so "revoke all paired devices" also invalidates
 * anything that copied the preferences file.
 *
 * Registered from `MainActivity.configureFlutterEngine`.
 */
class PairingSecretChannel : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "tempo/pairing_secrets"

        private const val PREFERENCES_NAME = "tempo_pairing_secrets"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "tempo.pairing.secrets"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val IV_BYTES = 12
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private val preferences: android.content.SharedPreferences
        get() = (context ?: throw IllegalStateException("Tempo is not attached to an engine"))
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    // FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    // MethodChannel.MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> onIo(result) { read(requireKey(call)) }
            "write" -> onIo(result) {
                write(requireKey(call), requireValue(call))
                null
            }
            "delete" -> onIo(result) {
                delete(requireKey(call))
                null
            }
            "deleteAll" -> onIo(result) {
                deleteAll()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun read(key: String): String? {
        val stored = preferences.getString(key, null) ?: return null
        return try {
            val combined = Base64.decode(stored, Base64.NO_WRAP)
            if (combined.size <= IV_BYTES) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(GCM_TAG_BITS, combined, 0, IV_BYTES),
            )
            String(cipher.doFinal(combined, IV_BYTES, combined.size - IV_BYTES), Charsets.UTF_8)
        } catch (e: Exception) {
            // A cleared or rotated Keystore key makes old ciphertext useless;
            // the peer simply pairs again rather than crashing the app.
            preferences.edit().remove(key).commit()
            null
        }
    }

    private fun write(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(cipher.iv.size + sealed.size)
        cipher.iv.copyInto(combined)
        sealed.copyInto(combined, cipher.iv.size)
        preferences.edit()
            .putString(key, Base64.encodeToString(combined, Base64.NO_WRAP))
            .commit()
    }

    private fun delete(key: String) {
        preferences.edit().remove(key).commit()
    }

    private fun deleteAll() {
        preferences.edit().clear().commit()
        try {
            KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
                .deleteEntry(KEY_ALIAS)
        } catch (e: Exception) {
            // The key is already gone, or this device has no Keystore entry.
        }
    }

    /** The app's AES key, created on first use and never exported. */
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            KEYSTORE_PROVIDER,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /**
     * Runs a Keystore call off the platform thread and answers on it: the first
     * write generates a key, which can take longer than a frame.
     */
    private fun onIo(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("PAIRING_SECRET_ERROR", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun requireKey(call: MethodCall): String =
        call.argument<String>("key")?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("key is required")

    private fun requireValue(call: MethodCall): String =
        call.argument<String>("value")
            ?: throw IllegalArgumentException("value is required")
}
