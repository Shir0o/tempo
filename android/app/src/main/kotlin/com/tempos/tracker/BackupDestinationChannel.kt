package com.tempos.tracker

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/**
 * The Storage Access Framework half of the backup destination.
 *
 * `lib/core/backup/backup_destination.dart` defines the contract this channel
 * answers: method names, argument keys, and the shapes it returns. Paths are
 * always relative to the picked tree and use `/` separators, because Android
 * has no atomic rename; the Dart side promotes a generation by copying it and
 * reading it back.
 *
 * Handles are stable: the persisted tree URI is the only thing that survives a
 * restart, and every call re-resolves documents from it.
 *
 * Registered from `MainActivity.configureFlutterEngine`. As an [ActivityAware]
 * plugin it receives the activity result for the folder picker without adding
 * an `onActivityResult` override to the activity itself.
 */
class BackupDestinationChannel : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "tempo/backup_destination"
        private const val REQUEST_PICK_TREE = 0x5AF
    }

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var pendingPick: MethodChannel.Result? = null

    private val resolver: ContentResolver
        get() = activity?.contentResolver
            ?: throw IllegalStateException("Tempo is not attached to a window")

    private val activityResultListener =
        object : PluginRegistry.ActivityResultListener {
            override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
                if (requestCode != REQUEST_PICK_TREE) return false
                handlePickedTree(resultCode, data)
                return true
            }
        }

    // FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(activityResultListener)
    }

    private fun detach() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
        activity = null
        pendingPick?.error("SAF_DETACHED", "the picker was closed with the app", null)
        pendingPick = null
    }

    // MethodChannel.MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTree" -> pickTree(result)
            "reopen" -> onIo(result) { reopen(requireArg(call, "treeUri")) }
            "displayName" -> onIo(result) { Tree(requireArg(call, "treeUri")).readablePath() }
            "createDirectory" -> onIo(result) {
                Tree(requireArg(call, "treeUri"))
                    .ensureDirectory(requireArg(call, "relativeDirectory"))
                true
            }
            "writeFile" -> onIo(result) {
                Tree(requireArg(call, "treeUri"))
                    .writeFile(requireArg(call, "relativePath"), bytesArg(call))
                true
            }
            "readFile" -> onIo(result) {
                Tree(requireArg(call, "treeUri")).readFile(requireArg(call, "relativePath"))
            }
            "list" -> onIo(result) {
                Tree(requireArg(call, "treeUri"))
                    .list(requireString(call, "relativeDirectory"))
            }
            "delete" -> onIo(result) {
                Tree(requireArg(call, "treeUri")).delete(requireArg(call, "relativePath"))
                true
            }
            "release" -> onIo(result) {
                release(requireArg(call, "treeUri"))
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun pickTree(result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("SAF_NO_ACTIVITY", "Tempo is not showing a window", null)
            return
        }
        if (pendingPick != null) {
            result.error("SAF_BUSY", "the folder picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        host.startActivityForResult(intent, REQUEST_PICK_TREE)
    }

    private fun handlePickedTree(resultCode: Int, data: Intent?) {
        val pending = pendingPick ?: return
        pendingPick = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            pending.success(null)
            return
        }
        try {
            resolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            pending.success(
                mapOf(
                    "treeUri" to uri.toString(),
                    "providerAuthority" to (uri.authority ?: ""),
                ),
            )
        } catch (e: SecurityException) {
            pending.error("SAF_PERMISSION", e.message ?: "the folder grant was refused", null)
        }
    }

    /** True only while the persisted grant still covers the tree and it opens. */
    private fun reopen(treeUri: String): Boolean {
        val uri = Uri.parse(treeUri)
        val granted = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (!granted) return false
        return try {
            Tree(treeUri).rootName() != null
        } catch (e: Exception) {
            false
        }
    }

    private fun release(treeUri: String) {
        try {
            resolver.releasePersistableUriPermission(
                Uri.parse(treeUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            // Never granted, or already released: nothing left to drop.
        }
    }

    /**
     * Runs a SAF call off the platform thread and answers on it. Cloud
     * providers can take hundreds of milliseconds per document; a blocked main
     * thread would stall the settings screen that shows the backup state.
     */
    private fun onIo(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: FileNotFoundException) {
                mainHandler.post {
                    result.error("SAF_MISSING", e.message ?: "the document is missing", null)
                }
            } catch (e: SecurityException) {
                mainHandler.post {
                    result.error("SAF_PERMISSION", e.message ?: "the folder grant was revoked", null)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("SAF_ERROR", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun requireArg(call: MethodCall, key: String): String =
        call.argument<String>(key)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("$key is required")

    /** The relative directory may legitimately be the tree root, so empty is fine. */
    private fun requireString(call: MethodCall, key: String): String =
        call.argument<String>(key) ?: throw IllegalArgumentException("$key is required")

    private fun bytesArg(call: MethodCall): ByteArray =
        call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes is required")

    /** One resolved tree: a relative-path walk with no cached documents. */
    private inner class Tree(treeUri: String) {
        private val uri: Uri = Uri.parse(treeUri)

        fun rootName(): String? =
            displayName(DocumentsContract.getTreeDocumentId(uri))

        /**
         * A path a person can read, such as `Downloads/Tempo` or
         * `Drive/Backups`. Tree document ids are provider-private (Drive's is
         * an encoded blob), so the names come from the provider itself: the
         * document path from its root when the provider can report one,
         * otherwise the root's title and the folder's own name.
         */
        fun readablePath(): String? {
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            val folder = displayName(treeId) ?: return null
            val names = documentPathNames(treeId)
            val rootTitle = rootTitle(names?.first)
            val parts = mutableListOf<String>()
            if (rootTitle != null) parts.add(rootTitle)
            val trail = names?.second.orEmpty()
            if (trail.isNotEmpty()) {
                // The first document on the path is the root's own folder,
                // which the root title already names.
                val skipFirst = rootTitle != null && trail.size > 1
                parts.addAll(if (skipFirst) trail.drop(1) else trail)
            }
            if (parts.isEmpty() || parts.last() != folder) parts.add(folder)
            return parts.distinct().joinToString("/")
        }

        /** The root id and the display names from the root down to the tree. */
        private fun documentPathNames(treeId: String): Pair<String?, List<String>>? {
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return null
            return try {
                val path = DocumentsContract.findDocumentPath(resolver, documentUri(treeId))
                    ?: return null
                path.rootId to path.path.mapNotNull { displayName(it) }
            } catch (e: Exception) {
                // Many providers, Drive among them, do not implement it.
                null
            }
        }

        /**
         * The provider root's title, such as `Downloads` or `Drive`. With no
         * root id, it is used only when the provider has exactly one root, so
         * a guess never names the wrong account or volume.
         */
        private fun rootTitle(rootId: String?): String? {
            val authority = uri.authority ?: return null
            val projection = arrayOf(
                DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_TITLE,
            )
            val roots = mutableListOf<Pair<String?, String?>>()
            try {
                resolver.query(
                    DocumentsContract.buildRootsUri(authority),
                    projection,
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        roots.add(cursor.getString(0) to cursor.getString(1))
                    }
                }
            } catch (e: Exception) {
                return null
            }
            val match = if (rootId != null) {
                roots.firstOrNull { it.first == rootId }
            } else {
                roots.singleOrNull()
            }
            return match?.second?.takeIf { it.isNotBlank() }
        }

        fun ensureDirectory(relativeDirectory: String): String {
            var parentId = DocumentsContract.getTreeDocumentId(uri)
            for (segment in segments(relativeDirectory)) {
                parentId = findChild(parentId, segment, directory = true)?.first
                    ?: createDocument(parentId, segment, DocumentsContract.Document.MIME_TYPE_DIR)
            }
            return parentId
        }

        fun writeFile(relativePath: String, bytes: ByteArray) {
            val parts = segments(relativePath)
            require(parts.isNotEmpty()) { "relativePath is required" }
            val name = parts.last()
            val parentId = ensureDirectory(parts.dropLast(1).joinToString("/"))
            // createDocument renames on a name clash ("backup.db (1)"), which
            // would break the caller's read-back check, so an old copy goes first.
            findChild(parentId, name, directory = false)?.let { deleteDocument(it.first) }
            val documentId = createDocument(parentId, name, "application/octet-stream")
            val output = resolver.openOutputStream(documentUri(documentId), "wt")
                ?: throw FileNotFoundException("cannot write $relativePath")
            output.use { it.write(bytes) }
        }

        fun readFile(relativePath: String): ByteArray {
            val parts = segments(relativePath)
            require(parts.isNotEmpty()) { "relativePath is required" }
            val directoryId = findDirectory(parts.dropLast(1).joinToString("/"))
                ?: throw FileNotFoundException("missing directory for $relativePath")
            val documentId = findChild(directoryId, parts.last(), directory = false)?.first
                ?: throw FileNotFoundException("SAF file is missing: $relativePath")
            val input = resolver.openInputStream(documentUri(documentId))
                ?: throw FileNotFoundException("SAF file is missing: $relativePath")
            return input.use {
                val buffer = ByteArrayOutputStream()
                it.copyTo(buffer)
                buffer.toByteArray()
            }
        }

        fun list(relativeDirectory: String): List<Map<String, Any?>> {
            val directoryId = findDirectory(relativeDirectory) ?: return emptyList()
            val rows = mutableListOf<Map<String, Any?>>()
            for (row in children(directoryId)) {
                if (row.isDirectory) continue
                val relative = if (relativeDirectory.isEmpty()) {
                    row.name
                } else {
                    "$relativeDirectory/${row.name}"
                }
                rows.add(
                    mapOf(
                        "path" to relative,
                        "bytes" to row.bytes,
                        "modifiedAtEpochMs" to row.modifiedAtEpochMs,
                    ),
                )
            }
            rows.sortBy { it["path"] as String }
            return rows
        }

        fun delete(relativePath: String) {
            val parts = segments(relativePath)
            if (parts.isEmpty()) return
            val directoryId = findDirectory(parts.dropLast(1).joinToString("/")) ?: return
            val documentId = findChild(directoryId, parts.last(), directory = false)?.first ?: return
            deleteDocument(documentId)
        }

        private fun findDirectory(relativeDirectory: String): String? {
            var parentId = DocumentsContract.getTreeDocumentId(uri)
            for (segment in segments(relativeDirectory)) {
                parentId = findChild(parentId, segment, directory = true)?.first ?: return null
            }
            return parentId
        }

        private fun findChild(
            parentId: String,
            name: String,
            directory: Boolean,
        ): Pair<String, Row>? =
            children(parentId)
                .firstOrNull { it.name == name && it.isDirectory == directory }
                ?.let { it.documentId to it }

        private fun createDocument(parentId: String, name: String, mimeType: String): String =
            DocumentsContract.createDocument(
                resolver,
                documentUri(parentId),
                mimeType,
                name,
            )?.let { DocumentsContract.getDocumentId(it) }
                ?: throw FileNotFoundException("cannot create $name")

        private fun deleteDocument(documentId: String) {
            DocumentsContract.deleteDocument(resolver, documentUri(documentId))
        }

        private fun displayName(documentId: String): String? {
            val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            resolver.query(documentUri(documentId), projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) return cursor.getString(0)
            }
            return null
        }

        private fun children(parentId: String): List<Row> {
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parentId)
            val rows = mutableListOf<Row>()
            resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    rows.add(
                        Row(
                            documentId = cursor.getString(0) ?: continue,
                            name = cursor.getString(1) ?: continue,
                            mimeType = cursor.getString(2) ?: "",
                            bytes = if (cursor.isNull(3)) 0L else cursor.getLong(3),
                            modifiedAtEpochMs = if (cursor.isNull(4)) 0L else cursor.getLong(4),
                        ),
                    )
                }
            }
            return rows
        }

        private fun documentUri(documentId: String): Uri =
            DocumentsContract.buildDocumentUriUsingTree(uri, documentId)
    }

    private data class Row(
        val documentId: String,
        val name: String,
        val mimeType: String,
        val bytes: Long,
        val modifiedAtEpochMs: Long,
    ) {
        val isDirectory: Boolean
            get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }
}

/** Splits a `/`-separated relative path, refusing traversal. */
private fun segments(relativePath: String): List<String> =
    relativePath.split('/')
        .filter { it.isNotEmpty() && it != "." }
        .onEach {
            require(it != "..") { "relative paths may not leave the chosen folder" }
        }
