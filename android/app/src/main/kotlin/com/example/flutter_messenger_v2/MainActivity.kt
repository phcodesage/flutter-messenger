package com.example.flutter_messenger_v2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.ComponentName
import android.content.ContentValues
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.util.Rational
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val TAG = "PiP"
    private val CLIPBOARD_TAG = "ClipboardPaste"
    private val CHANNEL = "com.example.flutter_messenger_v2/pip"
    private val AUDIO_CHANNEL = "com.example.flutter_messenger_v2/audio_recorder"
    private val QUICK_REPLY_CHANNEL = "com.example.flutter_messenger_v2/quick_reply"
    private val FILE_OPS_CHANNEL = "com.example.flutter_messenger_v2/file_ops"
    private val SHARE_CHANNEL = "com.example.flutter_messenger_v2/share_target"
    private val SHORTCUT_CHANNEL = "com.example.flutter_messenger_v2/shortcuts"
    private val NOTIFICATION_PAYLOAD_CHANNEL = "com.example.flutter_messenger_v2/notification_payload"
    private val DIRECT_SHARE_CATEGORY = "com.example.flutter_messenger_v2.directshare"
    private var methodChannel: MethodChannel? = null
    private var shareMethodChannel: MethodChannel? = null
    private var shortcutMethodChannel: MethodChannel? = null
    private var notificationPayloadChannel: MethodChannel? = null
    private var fileOpsMethodChannel: MethodChannel? = null
    private var clipboardManager: ClipboardManager? = null
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var pendingSharedItems: List<Map<String, String>> = emptyList()
    private var pendingSharedTargetUserId: String? = null
    private var pendingShortcutTargetUserId: String? = null
    private var pendingNotificationPayload: String? = null
    private var isInCall = false
    private var isMuted = false

    // Native audio recorder for accurate amplitude readings
    @Suppress("DEPRECATION")
    private var audioRecorder: MediaRecorder? = null
    private var currentRecordingPath: String? = null

    companion object {
        private const val ACTION_TOGGLE_MIC = "com.example.flutter_messenger_v2.PIP_TOGGLE_MIC"
        private const val ACTION_END_CALL = "com.example.flutter_messenger_v2.PIP_END_CALL"
        private const val REQUEST_TOGGLE_MIC = 1001
        private const val REQUEST_END_CALL = 1002
        private const val REQUEST_QUICK_REPLY = 2001
        private const val CHAT_NOTIFICATION_HISTORY_PREFS = "chat_notification_history"
        private const val CHAT_NOTIFICATION_HISTORY_LIMIT = 12
    }

    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_TOGGLE_MIC -> {
                    Log.d(TAG, "PiP action: toggle mic (was muted=$isMuted)")
                    isMuted = !isMuted
                    methodChannel?.invokeMethod("onPipAction", "toggleMic")
                    // Update PiP actions to reflect new mute state
                    updatePipActions()
                }
                ACTION_END_CALL -> {
                    Log.d(TAG, "PiP action: end call")
                    isInCall = false
                    // Exit PiP by bringing activity back to full screen
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode) {
                        moveTaskToBack(true)
                    }
                    methodChannel?.invokeMethod("onPipAction", "endCall")
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        logIntent(intent, "onCreate")
        pendingSharedItems = extractSharedItemsFromIntent(intent)
        pendingSharedTargetUserId = extractSharedTargetUserId(intent)
        pendingShortcutTargetUserId = extractShortcutTargetUserId(intent)
        pendingNotificationPayload = intent?.getStringExtra("notification_payload")
        Log.d("ShareDebug", "onCreate result: items=${pendingSharedItems.size}, sharedTarget=$pendingSharedTargetUserId, shortcutTarget=$pendingShortcutTargetUserId")

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            Log.e(TAG, "Uncaught exception in thread ${thread.name}: ${throwable.message}", throwable)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        shareMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL,
        )
        shareMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialSharedItems" -> {
                    val currentItems = pendingSharedItems
                    pendingSharedItems = emptyList()
                    result.success(currentItems)
                }
                "consumeInitialSharedTargetUserId" -> {
                    val currentTarget = pendingSharedTargetUserId
                    pendingSharedTargetUserId = null
                    result.success(currentTarget)
                }
                else -> result.notImplemented()
            }
        }

        // ── Direct Share shortcuts channel ─────────────────────────────────
        shortcutMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHORTCUT_CHANNEL,
        )
        shortcutMethodChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pushShareTargets" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            val users = call.arguments as? List<Map<String, Any>> ?: emptyList()
                            pushShareShortcuts(users)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "pushShareTargets error: ${e.message}", e)
                            result.error("SHORTCUT_ERROR", e.message, null)
                        }
                    }
                    "reportShareUsed" -> {
                        try {
                            val userId = call.argument<String>("userId")
                            if (userId.isNullOrBlank()) {
                                result.error("BAD_ARGS", "userId is required", null)
                            } else {
                                reportShareShortcutUsed(userId)
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "reportShareUsed error: ${e.message}", e)
                            result.error("SHORTCUT_ERROR", e.message, null)
                        }
                    }
                    "consumeInitialShortcutTarget" -> {
                        val currentTarget = pendingShortcutTargetUserId
                        pendingShortcutTargetUserId = null
                        result.success(currentTarget)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Audio recorder channel ─────────────────────────────────────────
        // Uses MediaRecorder.getMaxAmplitude() for accurate real-time amplitude.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        try {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error(
                                    "NO_PATH", "Recording path is required", null
                                )
                            // Release any existing recorder
                            audioRecorder?.apply { try { stop() } catch (_: Exception) {}; release() }
                            @Suppress("DEPRECATION")
                            audioRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                MediaRecorder(this)
                            } else {
                                @Suppress("DEPRECATION")
                                MediaRecorder()
                            }
                            audioRecorder!!.apply {
                                setAudioSource(MediaRecorder.AudioSource.MIC)
                                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                                setAudioEncodingBitRate(128000)
                                setAudioSamplingRate(44100)
                                setOutputFile(path)
                                prepare()
                                start()
                            }
                            currentRecordingPath = path
                            Log.d(TAG, "Audio recording started: $path")
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "startRecording error: ${e.message}", e)
                            result.error("RECORD_ERROR", e.message, null)
                        }
                    }
                    "getAmplitude" -> {
                        // getMaxAmplitude() resets after each call — perfect for scrolling waveform
                        val amplitude = audioRecorder?.maxAmplitude ?: 0
                        result.success(amplitude)
                    }
                    "pauseRecording" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                audioRecorder?.pause()
                                result.success(true)
                            } else {
                                result.error("API_LEVEL", "Pause requires API 24+", null)
                            }
                        } catch (e: Exception) {
                            result.error("PAUSE_ERROR", e.message, null)
                        }
                    }
                    "resumeRecording" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                audioRecorder?.resume()
                                result.success(true)
                            } else {
                                result.error("API_LEVEL", "Resume requires API 24+", null)
                            }
                        } catch (e: Exception) {
                            result.error("RESUME_ERROR", e.message, null)
                        }
                    }
                    "stopRecording" -> {
                        try {
                            audioRecorder?.apply {
                                stop()
                                release()
                            }
                            audioRecorder = null
                            val path = currentRecordingPath
                            currentRecordingPath = null
                            Log.d(TAG, "Audio recording stopped: $path")
                            result.success(path)
                        } catch (e: Exception) {
                            audioRecorder = null
                            Log.e(TAG, "stopRecording error: ${e.message}", e)
                            result.error("STOP_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Screen share foreground service channel ────────────────────────
        val screenShareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.flutter_messenger_v2/screen_share")
        screenShareChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    try {
                        val title = call.argument<String>("notificationTitle") ?: "Screen Sharing"
                        val text = call.argument<String>("notificationText") ?: "You are sharing your screen"
                        val serviceIntent = Intent(this, com.cloudwebrtc.webrtc.FlutterWebRTCForegroundService::class.java).apply {
                            putExtra("notificationTitle", title)
                            putExtra("notificationText", text)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        Log.d(TAG, "Screen share foreground service started")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error starting foreground service: ${e.message}", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "stopForegroundService" -> {
                    try {
                        val serviceIntent = Intent(this, com.cloudwebrtc.webrtc.FlutterWebRTCForegroundService::class.java)
                        stopService(serviceIntent)
                        Log.d(TAG, "Screen share foreground service stopped")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error stopping foreground service: ${e.message}", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── App-update download foreground service channel ─────────────────
        // Keeps the process alive so an OTA APK download survives backgrounding.
        val updateDownloadChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.flutter_messenger_v2/update_download",
        )
        updateDownloadChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        val title = call.argument<String>("title") ?: "Downloading update"
                        val text = call.argument<String>("text") ?: ""
                        val progress = call.argument<Int>("progress") ?: -1
                        val serviceIntent = Intent(this, UpdateDownloadService::class.java).apply {
                            action = UpdateDownloadService.ACTION_START
                            putExtra("title", title)
                            putExtra("text", text)
                            putExtra("progress", progress)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error starting update download service: ${e.message}", e)
                        result.error("UPDATE_FGS_ERROR", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        stopService(Intent(this, UpdateDownloadService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error stopping update download service: ${e.message}", e)
                        result.error("UPDATE_FGS_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── Native quick-reply notification bridge ───────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, QUICK_REPLY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showChatQuickReplyNotification" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (args == null) {
                                result.error("BAD_ARGS", "Expected Map arguments", null)
                                return@setMethodCallHandler
                            }

                            showChatQuickReplyNotification(args)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to show native quick-reply notification", e)
                            result.error("NATIVE_NOTIFICATION_ERROR", e.message, null)
                        }
                    }
                    "clearConversationNotificationState" -> {
                        try {
                            val args = call.arguments as? Map<*, *>
                            if (args == null) {
                                result.error("BAD_ARGS", "Expected Map arguments", null)
                                return@setMethodCallHandler
                            }

                            clearConversationNotificationState(args)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to clear conversation notification state", e)
                            result.error("NATIVE_NOTIFICATION_CLEAR_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Native file save bridge (Downloads via MediaStore) ───────────
        fileOpsMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_OPS_CHANNEL,
        )
        fileOpsMethodChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        try {
                            val fileName = call.argument<String>("fileName")
                            val mimeType = call.argument<String>("mimeType")
                                ?: "application/octet-stream"
                            val bytes = call.argument<ByteArray>("bytes")

                            if (fileName.isNullOrBlank() || bytes == null) {
                                result.error(
                                    "BAD_ARGS",
                                    "fileName and bytes are required",
                                    null,
                                )
                                return@setMethodCallHandler
                            }

                            val savedUri = saveBytesToDownloads(fileName, mimeType, bytes)
                            if (savedUri == null) {
                                result.error("SAVE_FAILED", "Failed to save file", null)
                            } else {
                                result.success(savedUri.toString())
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "saveToDownloads error: ${e.message}", e)
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    "getClipboardImagePngBytes" -> {
                        try {
                            val bytes = getClipboardImagePngBytes()
                            result.success(bytes)
                        } catch (e: Exception) {
                            Log.e(TAG, "getClipboardImagePngBytes error: ${e.message}", e)
                            result.error("CLIPBOARD_READ_FAILED", e.message, null)
                        }
                    }
                    "getClipboardMediaFile" -> {
                        try {
                            val media = getClipboardMediaFile()
                            result.success(media)
                        } catch (e: Exception) {
                            Log.e(TAG, "getClipboardMediaFile error: ${e.message}", e)
                            result.error("CLIPBOARD_READ_FAILED", e.message, null)
                        }
                    }
                    "openDownloadedFile" -> {
                        try {
                            val target = call.argument<String>("target")
                            val mimeType = call.argument<String>("mimeType") ?: "*/*"
                            if (target.isNullOrBlank()) {
                                result.error("BAD_ARGS", "target is required", null)
                                return@setMethodCallHandler
                            }

                            val opened = openDownloadedFile(target, mimeType)
                            if (opened) {
                                result.success(true)
                            } else {
                                result.error(
                                    "OPEN_FAILED",
                                    "No app found to open this file",
                                    null,
                                )
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "openDownloadedFile error: ${e.message}", e)
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        registerClipboardListenerIfNeeded()

        // ── Native notification payload bridge ────────────────────────────
        notificationPayloadChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_PAYLOAD_CHANNEL,
        )
        notificationPayloadChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialNotificationPayload" -> {
                    val payload = pendingNotificationPayload
                    pendingNotificationPayload = null
                    result.success(payload)
                }
                else -> result.notImplemented()
            }
        }

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipAvailable" -> {
                    val available = isPipAvailable()
                    Log.d(TAG, "isPipAvailable: $available")
                    result.success(available)
                }
                "enterPipMode" -> {
                    Log.d(TAG, "enterPipMode called from Flutter")
                    result.success(enterPipMode())
                }
                "setInCall" -> {
                    isInCall = call.argument<Boolean>("inCall") ?: false
                    Log.d(TAG, "setInCall: $isInCall")
                    result.success(true)
                }
                "updateMuteState" -> {
                    isMuted = call.argument<Boolean>("isMuted") ?: false
                    Log.d(TAG, "updateMuteState: $isMuted")
                    updatePipActions()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Register broadcast receiver for PiP actions
        val filter = IntentFilter().apply {
            addAction(ACTION_TOGGLE_MIC)
            addAction(ACTION_END_CALL)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pipActionReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(pipActionReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Receiver already unregistered")
        }
        shareMethodChannel = null
        shortcutMethodChannel = null
        notificationPayloadChannel = null
        fileOpsMethodChannel = null
        removeClipboardListenerIfNeeded()
        super.onDestroy()
    }

    private fun registerClipboardListenerIfNeeded() {
        if (clipboardListener != null) {
            Log.d(CLIPBOARD_TAG, "listener already registered")
            return
        }

        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: run {
                Log.w(CLIPBOARD_TAG, "clipboard manager unavailable")
                return
            }

        clipboardManager = manager
        Log.d(CLIPBOARD_TAG, "registering clipboard listener")
        clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
            try {
                Log.d(CLIPBOARD_TAG, "primary clip changed")
                val hasImage = hasClipboardImage()
                fileOpsMethodChannel?.invokeMethod(
                    "onClipboardChanged",
                    mapOf("hasImage" to hasImage),
                )
                if (hasImage) {
                    Log.d(CLIPBOARD_TAG, "clipboard image detected; notifying flutter")
                    fileOpsMethodChannel?.invokeMethod("onClipboardImageAvailable", null)
                } else {
                    Log.d(CLIPBOARD_TAG, "clipboard changed but no image detected")
                }
            } catch (e: Exception) {
                Log.w(CLIPBOARD_TAG, "clipboard listener error: ${e.message}")
            }
        }
        manager.addPrimaryClipChangedListener(clipboardListener)
    }

    private fun removeClipboardListenerIfNeeded() {
        val manager = clipboardManager
        val listener = clipboardListener
        if (manager != null && listener != null) {
            Log.d(CLIPBOARD_TAG, "removing clipboard listener")
            manager.removePrimaryClipChangedListener(listener)
        }
        clipboardManager = null
        clipboardListener = null
    }

    private fun hasClipboardImage(): Boolean {
        val clipboard = clipboardManager ?: return false
        if (!clipboard.hasPrimaryClip()) {
            Log.d(CLIPBOARD_TAG, "hasClipboardImage: no primary clip")
            return false
        }

        val clip = clipboard.primaryClip ?: return false
        Log.d(CLIPBOARD_TAG, "hasClipboardImage: itemCount=${clip.itemCount}")
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            Log.d(CLIPBOARD_TAG, "hasClipboardImage: checking item index=$index")
            if (isLikelyImageClipItem(clip, index, item)) {
                Log.d(CLIPBOARD_TAG, "hasClipboardImage: image-like item found at index=$index")
                return true
            }
        }

        return false
    }

    private fun saveBytesToDownloads(
        fileName: String,
        mimeType: String,
        bytes: ByteArray,
    ): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val itemUri = contentResolver.insert(collection, values) ?: return null

            try {
                contentResolver.openOutputStream(itemUri)?.use { output ->
                    output.write(bytes)
                    output.flush()
                } ?: throw IllegalStateException("Unable to open output stream")

                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(itemUri, values, null, null)
                itemUri
            } catch (e: Exception) {
                contentResolver.delete(itemUri, null, null)
                throw e
            }
        } else {
            val downloadDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (!downloadDir.exists()) {
                downloadDir.mkdirs()
            }
            val outputFile = File(downloadDir, fileName)
            FileOutputStream(outputFile).use { output ->
                output.write(bytes)
                output.flush()
            }
            Uri.fromFile(outputFile)
        }
    }

    private fun openDownloadedFile(target: String, mimeType: String): Boolean {
        val uri = when {
            target.startsWith("content://") || target.startsWith("file://") -> Uri.parse(target)
            else -> Uri.fromFile(File(target))
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        val resolved = intent.resolveActivity(packageManager) ?: return false
        startActivity(intent)
        return resolved != null
    }

    private fun getClipboardImagePngBytes(): ByteArray? {
        Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes called")
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        if (!clipboard.hasPrimaryClip()) {
            Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: no primary clip")
            return null
        }

        val clip = clipboard.primaryClip ?: return null
        Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: itemCount=${clip.itemCount}")
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val uriCandidates = mutableListOf<Uri>()
            item.uri?.let { uriCandidates.add(it) }
            item.intent?.data?.let { uriCandidates.add(it) }

            val textUri = item.text?.toString()?.trim()
            if (!textUri.isNullOrEmpty() &&
                (textUri.startsWith("content://") || textUri.startsWith("file://"))) {
                try {
                    uriCandidates.add(Uri.parse(textUri))
                } catch (_: Exception) {
                    // Ignore malformed URIs from clipboard providers.
                }
            }

            Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: index=$index candidateCount=${uriCandidates.size}")

            for (uri in uriCandidates) {
                Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: trying uri=$uri")
                val maybeBytes = readImageBytesFromUri(uri)
                if (maybeBytes != null && maybeBytes.isNotEmpty()) {
                    Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: extracted bytes=${maybeBytes.size} from uri=$uri")
                    return maybeBytes
                }
            }
        }

        Log.d(CLIPBOARD_TAG, "getClipboardImagePngBytes: no image bytes extracted")
        return null
    }

    /**
     * Returns the first image OR video file referenced by the clipboard, copied
     * into the app cache with its original format/extension preserved. The map
     * has keys "path", "mimeType" and "fileName", or null when the clipboard
     * holds no pasteable image/video item. Used by the composer Paste button so
     * copied media (incl. video) can be attached, not just decoded bitmaps.
     */
    private fun getClipboardMediaFile(): Map<String, Any>? {
        Log.d(CLIPBOARD_TAG, "getClipboardMediaFile called")
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        if (!clipboard.hasPrimaryClip()) {
            Log.d(CLIPBOARD_TAG, "getClipboardMediaFile: no primary clip")
            return null
        }

        val clip = clipboard.primaryClip ?: return null
        Log.d(CLIPBOARD_TAG, "getClipboardMediaFile: itemCount=${clip.itemCount}")
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val uriCandidates = mutableListOf<Uri>()
            item.uri?.let { uriCandidates.add(it) }
            item.intent?.data?.let { uriCandidates.add(it) }

            val textUri = item.text?.toString()?.trim()
            if (!textUri.isNullOrEmpty() &&
                (textUri.startsWith("content://") || textUri.startsWith("file://"))) {
                try {
                    uriCandidates.add(Uri.parse(textUri))
                } catch (_: Exception) {
                    // Ignore malformed URIs from clipboard providers.
                }
            }

            for (uri in uriCandidates) {
                val mime = resolveMediaMimeType(uri) ?: continue
                if (!(mime.startsWith("image/") || mime.startsWith("video/"))) {
                    Log.d(CLIPBOARD_TAG, "getClipboardMediaFile: skipping non-media mime=$mime uri=$uri")
                    continue
                }
                val copied = copyUriToCacheFile(uri, mime) ?: continue
                Log.d(CLIPBOARD_TAG, "getClipboardMediaFile: copied uri=$uri -> ${copied.absolutePath} ($mime)")
                return mapOf(
                    "path" to copied.absolutePath,
                    "mimeType" to mime,
                    "fileName" to copied.name,
                )
            }
        }

        Log.d(CLIPBOARD_TAG, "getClipboardMediaFile: no media file found")
        return null
    }

    private fun resolveMediaMimeType(uri: Uri): String? {
        contentResolver.getType(uri)?.let { return it }
        val ext = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
        if (!ext.isNullOrEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())?.let { return it }
        }
        return null
    }

    private fun copyUriToCacheFile(uri: Uri, mimeType: String): File? {
        return try {
            val displayName = queryClipboardDisplayName(uri)
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
                ?: displayName?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() }
                ?: uri.lastPathSegment?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() }
                ?: "bin"
            val rawBase = displayName?.substringBeforeLast('.', displayName) ?: "pasted_media"
            val safeBase = rawBase.replace(Regex("[^A-Za-z0-9._-]"), "_").take(64)
            val fileName = "${safeBase}_${System.currentTimeMillis()}.$ext"

            val dir = File(cacheDir, "pasted_media").apply { mkdirs() }
            val outFile = File(dir, fileName)

            val copied = contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
                true
            } ?: false

            if (!copied || outFile.length() == 0L) {
                outFile.delete()
                Log.d(CLIPBOARD_TAG, "copyUriToCacheFile: empty/failed copy for uri=$uri")
                null
            } else {
                outFile
            }
        } catch (e: Exception) {
            Log.d(CLIPBOARD_TAG, "copyUriToCacheFile failed for uri=$uri: ${e.message}")
            null
        }
    }

    private fun queryClipboardDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isLikelyImageClipItem(clip: ClipData, index: Int, item: ClipData.Item): Boolean {
        val description = clip.description
        if (description != null && index < description.mimeTypeCount) {
            val mime = description.getMimeType(index)
            if (!mime.isNullOrBlank() && mime.startsWith("image/")) {
                return true
            }
        }

        val uri = item.uri ?: item.intent?.data
        if (uri != null && uriLooksLikeImage(uri)) {
            return true
        }

        val text = item.text?.toString()?.trim().orEmpty()
        if (text.startsWith("content://") || text.startsWith("file://")) {
            return try {
                uriLooksLikeImage(Uri.parse(text))
            } catch (_: Exception) {
                false
            }
        }

        return false
    }

    private fun uriLooksLikeImage(uri: Uri): Boolean {
        val mimeType = contentResolver.getType(uri)
        if (mimeType?.startsWith("image/") == true) {
            Log.d(CLIPBOARD_TAG, "uriLooksLikeImage: mime image for uri=$uri")
            return true
        }

        val uriString = uri.toString().lowercase()
        if (uriString.contains("image") || uriString.endsWith(".png") ||
            uriString.endsWith(".jpg") || uriString.endsWith(".jpeg") ||
            uriString.endsWith(".webp") || uriString.endsWith(".gif")) {
            Log.d(CLIPBOARD_TAG, "uriLooksLikeImage: uri hint matched for uri=$uri")
            return true
        }

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val options = BitmapFactory.Options().apply {
                    inJustDecodeBounds = true
                }
                BitmapFactory.decodeStream(input, null, options)
                val looksImage = options.outWidth > 0 && options.outHeight > 0
                Log.d(CLIPBOARD_TAG, "uriLooksLikeImage: decode bounds for uri=$uri -> $looksImage (${options.outWidth}x${options.outHeight})")
                looksImage
            } ?: false
        } catch (_: Exception) {
            Log.d(CLIPBOARD_TAG, "uriLooksLikeImage: decode bounds failed for uri=$uri")
            false
        }
    }

    private fun readImageBytesFromUri(uri: Uri): ByteArray? {
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                val bitmap = BitmapFactory.decodeStream(input)
                if (bitmap != null) {
                    Log.d(CLIPBOARD_TAG, "readImageBytesFromUri: bitmap decoded for uri=$uri")
                    return bitmap.toPngBytes()
                }
            }
        } catch (_: Exception) {
            Log.d(CLIPBOARD_TAG, "readImageBytesFromUri: bitmap decode failed for uri=$uri")
            // Fallback below.
        }

        if (!uriLooksLikeImage(uri)) {
            Log.d(CLIPBOARD_TAG, "readImageBytesFromUri: uri not image-like: $uri")
            return null
        }

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                Log.d(CLIPBOARD_TAG, "readImageBytesFromUri: using raw bytes fallback for uri=$uri")
                input.readBytes()
            }
        } catch (_: Exception) {
            Log.d(CLIPBOARD_TAG, "readImageBytesFromUri: raw bytes fallback failed for uri=$uri")
            null
        }
    }

    private fun Bitmap.toPngBytes(): ByteArray {
        val output = ByteArrayOutputStream()
        compress(Bitmap.CompressFormat.PNG, 100, output)
        return output.toByteArray()
    }

    /**
     * Forward activity results to the FragmentManager so that
     * ScreenRequestPermissionsFragment (used by flutter_webrtc's getDisplayMedia)
     * receives the screen-capture permission result.
     *
     * FlutterActivity.onActivityResult() does NOT call super (Activity.onActivityResult),
     * so android.app.Fragments added via getFragmentManager() never receive their results.
     * We find the fragment by tag and dispatch directly.
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        Log.d(TAG, "onActivityResult: requestCode=0x${requestCode.toString(16)} resultCode=$resultCode")
        // Screen capture permission result from ScreenRequestPermissionsFragment.
        // The fragment is added with tag = its fully-qualified class name.
        val screenFragTag =
            "com.cloudwebrtc.webrtc.GetUserMediaImpl\$ScreenRequestPermissionsFragment"
        val screenFrag = fragmentManager.findFragmentByTag(screenFragTag)
        if (screenFrag != null) {
            Log.d(TAG, "Dispatching activity result to ScreenRequestPermissionsFragment")
            // Strip the high-16-bit fragment-index encoding added by startActivityFromFragment()
            screenFrag.onActivityResult(requestCode and 0xffff, resultCode, data)
        }
        // Always let FlutterActivity / the engine handle it too.
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        logIntent(intent, "onNewIntent")

        val sharedItems = extractSharedItemsFromIntent(intent)
        pendingSharedTargetUserId = extractSharedTargetUserId(intent)
        Log.d("ShareDebug", "onNewIntent result: items=${sharedItems.size}, sharedTarget=$pendingSharedTargetUserId")
        if (sharedItems.isNotEmpty()) {
            pendingSharedItems = sharedItems
            Log.d("ShareDebug", "onNewIntent: invoking onSharedItems, first item directShareUserId=${sharedItems.firstOrNull()?.get("directShareUserId")}")
            shareMethodChannel?.invokeMethod("onSharedItems", sharedItems)
        }

        val shortcutTargetUserId = extractShortcutTargetUserId(intent)
        if (!shortcutTargetUserId.isNullOrBlank() && sharedItems.isEmpty()) {
            pendingShortcutTargetUserId = shortcutTargetUserId
            shortcutMethodChannel?.invokeMethod("onShortcutTarget", shortcutTargetUserId)
        }

        val notificationPayload = intent.getStringExtra("notification_payload")
        if (!notificationPayload.isNullOrBlank()) {
            pendingNotificationPayload = notificationPayload
            notificationPayloadChannel?.invokeMethod("onNotificationTap", notificationPayload)
        }
    }

    private fun extractShortcutTargetUserId(intent: Intent?): String? {
        if (intent == null) {
            return null
        }

        val shortcutUserId = intent.getStringExtra("direct_share_user_id")
        if (shortcutUserId.isNullOrBlank()) {
            return null
        }

        // Reuse the same shortcut for two cases:
        // 1) launcher recent-chat tap -> ACTION_SEND but with no shared payload -> open chat
        // 2) sharesheet direct-share tap -> ACTION_SEND with EXTRA_STREAM/clipData/text -> auto-send shared content
        if (intentHasSharedPayload(intent)) {
            return null
        }

        return shortcutUserId
    }

    private fun logIntent(intent: Intent?, source: String) {
        if (intent == null) {
            Log.d("ShareDebug", "[$source] intent is null")
            return
        }
        Log.d("ShareDebug", "[$source] action=${intent.action}, type=${intent.type}")
        Log.d("ShareDebug", "[$source] direct_share_user_id=${intent.getStringExtra("direct_share_user_id")}")
        val stream = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        Log.d("ShareDebug", "[$source] EXTRA_STREAM=$stream")
        Log.d("ShareDebug", "[$source] clipData=${intent.clipData}, clipData.itemCount=${intent.clipData?.itemCount ?: 0}")
        Log.d("ShareDebug", "[$source] EXTRA_TEXT=${intent.getStringExtra(Intent.EXTRA_TEXT)?.take(80)}")
        val extras = intent.extras
        if (extras != null) {
            val keys = extras.keySet().joinToString(", ")
            Log.d("ShareDebug", "[$source] all extras keys: $keys")
        }
    }

    private fun intentHasSharedPayload(intent: Intent): Boolean {
        if (intent.clipData != null && intent.clipData!!.itemCount > 0) {
            return true
        }

        if (!intent.getStringExtra(Intent.EXTRA_TEXT).isNullOrBlank()) {
            return true
        }

        val action = intent.action ?: return false
        return when (action) {
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) != null
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) != null
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    !list.isNullOrEmpty()
                } else {
                    @Suppress("DEPRECATION")
                    val list = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    !list.isNullOrEmpty()
                }
            }
            else -> false
        }
    }

    private fun extractSharedTargetUserId(intent: Intent?): String? {
        if (intent == null) {
            return null
        }

        val action = intent.action ?: return null
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return null
        }

        val id = intent.getStringExtra("direct_share_user_id")
            ?: userIdFromShortcutIdExtra(intent)
        Log.d("ShareDebug", "extractSharedTargetUserId: action=$action, direct_share_user_id=${intent.getStringExtra("direct_share_user_id")}, shortcut_fallback=${userIdFromShortcutIdExtra(intent)}, resolved=$id")
        return id
    }

    private fun userIdFromShortcutIdExtra(intent: Intent): String? {
        val sid = intent.getStringExtra("shortcut_id")
            ?: intent.getStringExtra("android.intent.extra.shortcut.ID")
            ?: intent.extras?.getString("android.intent.extra.shortcut.ID")
            ?: intent.extras?.getString("android.intent.extra.shortcut_id")
            ?: return null
        val prefix = "share_target_user_"
        return if (sid.startsWith(prefix)) sid.removePrefix(prefix) else null
    }

    private fun extractSharedItemsFromIntent(intent: Intent?): List<Map<String, String>> {
        if (intent == null) {
            return emptyList()
        }

        val action = intent.action ?: return emptyList()
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            val singleUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (singleUri != null) {
                uris.add(singleUri)
            }
        } else if (action == Intent.ACTION_SEND_MULTIPLE) {
            val multipleUris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (multipleUris != null) {
                uris.addAll(multipleUris)
            }
        }

        // Process clipData - check for text items (URL) first before image URIs
        var clipTextPayload: String? = null
        if (intent.clipData != null) {
            val clipData = intent.clipData!!
            for (index in 0 until clipData.itemCount) {
                val item = clipData.getItemAt(index)
                // Check for text content in clip item
                if (item.text != null) {
                    clipTextPayload = item.text.toString()
                    Log.d("ShareDebug", "Clip item $index text: ${clipTextPayload?.take(100)}")
                }
                // Collect URIs from clip item (only if no text found yet)
                if (item.uri != null && clipTextPayload == null) {
                    uris.add(item.uri)
                }
            }
        }

        // Check for text content first (Chrome often sends URL as text along with preview image)
        // Combine EXTRA_TEXT and clipData text
        val extraTextPayload = intent.getStringExtra(Intent.EXTRA_TEXT)
        val textPayload = extraTextPayload ?: clipTextPayload
        val subjectPayload = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val mimeType = intent.type?.lowercase() ?: ""
        Log.d("ShareDebug", "Share check: mimeType=$mimeType, extraText=${extraTextPayload?.take(100)}, clipText=${clipTextPayload?.take(100)}, subject=${subjectPayload?.take(100)}, uris=${uris.size}")
        
        // If there's a URL in the text, prioritize sending it as text message
        // Chrome may send "Page Title - URL" format or just the URL
        val urlRegex = Regex("(https?://[^\\s]+)")
        
        // Check EXTRA_TEXT for URL
        if (!textPayload.isNullOrBlank()) {
            val urlMatch = urlRegex.find(textPayload)
            if (urlMatch != null) {
                val extractedUrl = urlMatch.groupValues[1].ifEmpty { textPayload }
                Log.d("ShareDebug", "URL detected in EXTRA_TEXT: $extractedUrl, sending as text message")
                val textItem = copySharedTextToCache(
                    text = extractedUrl,
                    mimeType = "text/plain",
                    extension = "txt",
                    index = 0,
                )
                return if (textItem != null) listOf(textItem) else emptyList()
            }
        }
        
        // Sometimes Chrome puts URL in EXTRA_SUBJECT
        if (!subjectPayload.isNullOrBlank()) {
            val urlMatch = urlRegex.find(subjectPayload)
            if (urlMatch != null) {
                val extractedUrl = urlMatch.groupValues[1].ifEmpty { subjectPayload }
                Log.d("ShareDebug", "URL detected in EXTRA_SUBJECT: $extractedUrl, sending as text message")
                val textItem = copySharedTextToCache(
                    text = extractedUrl,
                    mimeType = "text/plain",
                    extension = "txt",
                    index = 0,
                )
                return if (textItem != null) listOf(textItem) else emptyList()
            }
        }

        if (uris.isEmpty()) {
            // Handle non-URL text shares (vCards, etc.)
            if (!textPayload.isNullOrBlank()) {
                // Handle vCard shares
                if (mimeType.contains("vcard")) {
                    val textItem = copySharedTextToCache(
                        text = textPayload,
                        mimeType = if (mimeType.isBlank()) "text/x-vcard" else mimeType,
                        extension = "vcf",
                        index = 0,
                    )
                    return if (textItem != null) listOf(textItem) else emptyList()
                }
                // Handle URL/text shares from Chrome and other browsers (text/plain, text/html, etc.)
                // Save as text file so Flutter side can process it as a text message
                val textItem = copySharedTextToCache(
                    text = textPayload,
                    mimeType = "text/plain",
                    extension = "txt",
                    index = 0,
                )
                return if (textItem != null) listOf(textItem) else emptyList()
            }
            return emptyList()
        }

        val extractedItems = mutableListOf<Map<String, String>>()
        Log.d("ShareDebug", "Processing ${uris.size} URIs from share intent")
        uris.forEachIndexed { index, uri ->
            try {
                val mimeType = contentResolver.getType(uri) ?: "unknown"
                Log.d("ShareDebug", "URI $index: $uri, mimeType=$mimeType")
                val sharedItem = copySharedUriToCache(uri, index)
                if (sharedItem != null) {
                    extractedItems.add(sharedItem)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse shared URI: $uri", e)
            }
        }

        // If arrived via a Direct Share shortcut the shortcut intent merges its extras
        // into the ACTION_SEND intent — pick up the user id and annotate each item.
        val directShareUserId = intent.getStringExtra("direct_share_user_id")
            ?: userIdFromShortcutIdExtra(intent)
        Log.d("ShareDebug", "extractSharedItemsFromIntent: directShareUserId=$directShareUserId (raw=${intent.getStringExtra("direct_share_user_id")}, shortcutFallback=${userIdFromShortcutIdExtra(intent)})")
        if (!directShareUserId.isNullOrBlank() && extractedItems.isNotEmpty()) {
            return extractedItems.map { it + ("directShareUserId" to directShareUserId) }
        }

        return extractedItems
    }

    // ── Sharing Shortcuts (Direct Share row) ───────────────────────────────

    private fun pushShareShortcuts(users: List<Map<String, Any>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return // shortcuts require API 25+

        val shortcuts = users.take(6).mapIndexedNotNull { rank, user ->
            val userId = user["id"]?.toString() ?: return@mapIndexedNotNull null
            val name = (user["name"] as? String)?.ifBlank { "User $userId" } ?: "User $userId"
            val colorIndex = (user["avatarColorIndex"] as? Int) ?: 0
            val shortcutId = "share_target_user_$userId"
            val person = Person.Builder().setName(name).build()

            // The shortcut's own intent — Android will merge its extras with the
            // incoming ACTION_SEND intent when the user picks this shortcut.
            val directShareIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                putExtra("direct_share_user_id", userId)
                // Secondary identifier: allows us to recover userId from shortcut ID
                // even if the primary extra is dropped during intent merging.
                putExtra("shortcut_id", shortcutId)
            }

            ShortcutInfoCompat.Builder(this, shortcutId)
                .setShortLabel(name)
                .setLongLabel(name)
                .setIcon(IconCompat.createWithBitmap(makeInitialsIcon(name, colorIndex)))
                .setActivity(ComponentName(this, MainActivity::class.java))
                .setIntent(directShareIntent)
                .setPersons(arrayOf(person))
                .setLongLived(true)
                .setCategories(setOf(DIRECT_SHARE_CATEGORY))
                .setRank(rank)
                .build()
        }

        if (shortcuts.isNotEmpty()) {
            ShortcutManagerCompat.removeAllDynamicShortcuts(this)
            ShortcutManagerCompat.addDynamicShortcuts(this, shortcuts)
        }
    }

    private fun reportShareShortcutUsed(userId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        ShortcutManagerCompat.reportShortcutUsed(this, "share_target_user_$userId")
    }

    /** Render a coloured circle with up to two initials — used as shortcut icon. */
    private fun makeInitialsIcon(name: String, colorIndex: Int): Bitmap {
        val avatarColors = intArrayOf(
            0xFFE91E63.toInt(), 0xFF9C27B0.toInt(), 0xFF673AB7.toInt(),
            0xFF3F51B5.toInt(), 0xFF2196F3.toInt(), 0xFF00BCD4.toInt(),
            0xFF009688.toInt(), 0xFF4CAF50.toInt(), 0xFFFF9800.toInt(), 0xFFFF5722.toInt(),
        )
        val bg = avatarColors[colorIndex % avatarColors.size]
        val size = 192
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = bg }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)

        val initials = name.trim().split(' ')
            .filter { it.isNotEmpty() }
            .take(2)
            .map { it.first().uppercaseChar() }
            .joinToString("")
            .ifEmpty { "?" }

        paint.apply {
            color = android.graphics.Color.WHITE
            textSize = size * 0.38f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val textBounds = Rect()
        paint.getTextBounds(initials, 0, initials.length, textBounds)
        canvas.drawText(initials, size / 2f, size / 2f + textBounds.height() / 2f, paint)
        return bmp
    }

    private fun copySharedTextToCache(
        text: String,
        mimeType: String,
        extension: String,
        index: Int,
    ): Map<String, String>? {
        val sharedDir = File(cacheDir, "shared_imports")
        if (!sharedDir.exists()) {
            sharedDir.mkdirs()
        }

        val targetFile = File(
            sharedDir,
            "${System.currentTimeMillis()}_$index-shared_contact.$extension",
        )

        return try {
            targetFile.writeText(text)
            mapOf(
                "path" to targetFile.absolutePath,
                "fileName" to targetFile.name,
                "mimeType" to mimeType,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to persist shared text payload", e)
            null
        }
    }

    private fun copySharedUriToCache(uri: Uri, index: Int): Map<String, String>? {
        val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
        val defaultExtension = extensionFromMimeType(mimeType)
        val displayName = resolveDisplayName(uri)
            ?: "shared_${System.currentTimeMillis()}_$index.$defaultExtension"
        val safeName = sanitizeFileName(displayName)

        val sharedDir = File(cacheDir, "shared_imports")
        if (!sharedDir.exists()) {
            sharedDir.mkdirs()
        }

        val targetFile = File(
            sharedDir,
            "${System.currentTimeMillis()}_$index-$safeName",
        )

        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(targetFile).use { output ->
                input.copyTo(output)
            }
        } ?: return null

        return mapOf(
            "path" to targetFile.absolutePath,
            "fileName" to safeName,
            "mimeType" to mimeType,
        )
    }

    private fun resolveDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return File(uri.path ?: return null).name
        }

        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val columnIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (columnIndex != -1) {
                    return cursor.getString(columnIndex)
                }
            }
        }

        return null
    }

    private fun sanitizeFileName(fileName: String): String {
        return fileName.replace(Regex("[^A-Za-z0-9._-]"), "_")
    }

    private fun extensionFromMimeType(mimeType: String): String {
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
        return if (ext.isNullOrBlank()) "bin" else ext
    }

    private fun isPipAvailable(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
    }

    private fun buildPipActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()

        val actions = mutableListOf<RemoteAction>()

        // Mute/Unmute action
        val micIcon = if (isMuted) {
            Icon.createWithResource(this, android.R.drawable.stat_notify_call_mute)
        } else {
            Icon.createWithResource(this, android.R.drawable.ic_btn_speak_now)
        }
        val micTitle = if (isMuted) "Unmute" else "Mute"
        val micIntent = PendingIntent.getBroadcast(
            this,
            REQUEST_TOGGLE_MIC,
            Intent(ACTION_TOGGLE_MIC),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        actions.add(RemoteAction(micIcon, micTitle, micTitle, micIntent))

        // End Call action
        val endCallIcon = Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel)
        val endCallIntent = PendingIntent.getBroadcast(
            this,
            REQUEST_END_CALL,
            Intent(ACTION_END_CALL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        actions.add(RemoteAction(endCallIcon, "End Call", "End Call", endCallIntent))

        return actions
    }

    private fun updatePipActions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode) {
            try {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(9, 16))
                    .setActions(buildPipActions())
                    .build()
                setPictureInPictureParams(params)
                Log.d(TAG, "PiP actions updated (muted=$isMuted)")
            } catch (e: Exception) {
                Log.e(TAG, "Error updating PiP actions: ${e.message}", e)
            }
        }
    }

    private fun showChatQuickReplyNotification(args: Map<*, *>) {
        val notificationId = (args["notificationId"] as? Number)?.toInt() ?: return
        val channelId = (args["channelId"] as? String)?.ifBlank { "chat_messages" } ?: "chat_messages"
        val channelName = (args["channelName"] as? String)?.ifBlank { "Chat Messages" } ?: "Chat Messages"
        val title = (args["title"] as? String)?.ifBlank { "New message" } ?: "New message"
        val body = (args["body"] as? String)?.ifBlank { "" } ?: ""
        val senderName = (args["senderName"] as? String)?.ifBlank { "Someone" } ?: "Someone"
        val groupName = (args["groupName"] as? String).orEmpty()
        val isGroup = args["isGroup"] as? Boolean ?: false
        val replyEndpoint = (args["replyEndpoint"] as? String).orEmpty()
        val replyRecipientId = (args["replyRecipientId"] as? String).orEmpty()
        val conversationType = (args["conversationType"] as? String)?.ifBlank { "direct" } ?: "direct"
        val enableQuickReply = args["enableQuickReply"] as? Boolean ?: true
        val groupId = (args["groupId"] as? String).orEmpty()
        val senderId = (args["senderId"] as? String).orEmpty()
        val baseUrl = (args["baseUrl"] as? String).orEmpty()
        val payloadJson = (args["payloadJson"] as? String).orEmpty()
        val conversationKey = (args["conversationKey"] as? String)?.ifBlank { null }
            ?: buildConversationKey(conversationType, groupId, replyRecipientId, notificationId, senderId)
        val history = appendChatHistory(conversationKey, senderName, body)

        ensureNotificationChannel(channelId, channelName)

        val replyIntent = Intent(this, ReplyReceiver::class.java).apply {
            putExtra("notification_id", notificationId)
            putExtra("reply_endpoint", replyEndpoint)
            putExtra("reply_recipient_id", replyRecipientId)
            putExtra("conversation_type", conversationType)
            putExtra("group_id", groupId)
            putExtra("base_url", baseUrl)
            putExtra("channel_id", channelId)
            putExtra("payload_json", payloadJson)
        }

        val replyPendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }

        val replyPendingIntent = PendingIntent.getBroadcast(
            this,
            notificationId + REQUEST_QUICK_REPLY,
            replyIntent,
            replyPendingIntentFlags,
        )

        val remoteInput = RemoteInput.Builder(ReplyReceiver.KEY_TEXT_REPLY)
            .setLabel("Write a reply...")
            .build()

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPendingIntent,
        )
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(true)
            .build()

        val mePerson = Person.Builder().setName("You").build()

        val style = NotificationCompat.MessagingStyle(mePerson)

        for (i in 0 until history.length()) {
            val entry = history.optJSONObject(i) ?: continue
            val lineSender = entry.optString("sender").ifBlank { senderName }
            val lineText = entry.optString("text").ifBlank { body }
            val lineTimestamp = entry.optLong("ts", System.currentTimeMillis())
            val senderPerson = Person.Builder().setName(lineSender).build()
            style.addMessage(lineText, lineTimestamp, senderPerson)
        }

        if (isGroup && groupName.isNotBlank()) {
            style.setConversationTitle(groupName)
            style.setGroupConversation(true)
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (payloadJson.isNotBlank()) {
                putExtra("notification_payload", payloadJson)
            }
        }

        val contentPendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                notificationId,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.sym_action_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setStyle(style)
            .setNumber(history.length())
            .setOnlyAlertOnce(false)
            .setAllowSystemGeneratedContextualActions(true)

        if (enableQuickReply) {
            builder.addAction(replyAction)
        }

        if (contentPendingIntent != null) {
            builder.setContentIntent(contentPendingIntent)
        }

        NotificationManagerCompat.from(this).notify(notificationId, builder.build())
    }

    private fun clearConversationNotificationState(args: Map<*, *>) {
        val notificationId = (args["notificationId"] as? Number)?.toInt()
        val conversationKey = (args["conversationKey"] as? String).orEmpty()

        if (notificationId != null) {
            NotificationManagerCompat.from(this).cancel(notificationId)
        }

        if (conversationKey.isNotBlank()) {
            // Cancel all per-message notifications belonging to this conversation's group.
            val groupKey = "chat:$conversationKey"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val nm = getSystemService(NotificationManager::class.java)
                nm?.activeNotifications?.forEach { sbn ->
                    if (sbn.notification?.group == groupKey) {
                        nm.cancel(sbn.tag, sbn.id)
                    }
                }
            }

            val prefs = getSharedPreferences(CHAT_NOTIFICATION_HISTORY_PREFS, Context.MODE_PRIVATE)
            prefs.edit().remove("history_$conversationKey").apply()
        }
    }

    private fun buildConversationKey(
        conversationType: String,
        groupId: String,
        replyRecipientId: String,
        notificationId: Int,
        senderId: String = "",
    ): String {
        if (conversationType == "group" && groupId.isNotBlank()) {
            return "group:$groupId"
        }

        if (senderId.isNotBlank()) {
            return "direct:$senderId"
        }

        if (replyRecipientId.isNotBlank()) {
            return "direct:$replyRecipientId"
        }

        return "id:$notificationId"
    }

    private fun appendChatHistory(
        conversationKey: String,
        senderName: String,
        body: String,
    ): JSONArray {
        val prefs = getSharedPreferences(CHAT_NOTIFICATION_HISTORY_PREFS, Context.MODE_PRIVATE)
        val prefKey = "history_$conversationKey"
        val existingRaw = prefs.getString(prefKey, null)
        val updated = JSONArray()

        if (!existingRaw.isNullOrBlank()) {
            try {
                val existing = JSONArray(existingRaw)
                val start = maxOf(0, existing.length() - (CHAT_NOTIFICATION_HISTORY_LIMIT - 1))
                for (i in start until existing.length()) {
                    updated.put(existing.optJSONObject(i) ?: JSONObject())
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to parse notification history for $conversationKey", e)
            }
        }

        updated.put(
            JSONObject().apply {
                put("sender", senderName)
                put("text", body)
                put("ts", System.currentTimeMillis())
            },
        )

        prefs.edit().putString(prefKey, updated.toString()).apply()
        return updated
    }

    private fun ensureNotificationChannel(channelId: String, channelName: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    private fun enterPipMode(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(9, 16))
                    .setActions(buildPipActions())
                    .build()
                Log.d(TAG, "Entering PiP mode with actions...")
                val success = enterPictureInPictureMode(params)
                Log.d(TAG, "enterPictureInPictureMode result: $success")
                return success
            } catch (e: Exception) {
                Log.e(TAG, "Error entering PiP mode: ${e.message}", e)
                return false
            }
        }
        Log.d(TAG, "PiP not available (SDK < O)")
        return false
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        Log.d(TAG, "onUserLeaveHint: isInCall=$isInCall, pipAvailable=${isPipAvailable()}")
        // Auto-enter PiP when user presses home button during a call
        if (isInCall && isPipAvailable()) {
            enterPipMode()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        Log.d(TAG, "onPictureInPictureModeChanged: $isInPictureInPictureMode")
        // Notify Flutter about PiP mode change
        methodChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }
}
