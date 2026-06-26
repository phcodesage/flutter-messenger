package com.example.flutter_messenger_v2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service that keeps the app process alive while an OTA app-update
 * APK is downloading. Without it, Android freezes/kills the backgrounded process
 * and the in-flight Dio download stalls. Driven from Flutter via the
 * `com.example.flutter_messenger_v2/update_download` MethodChannel.
 *
 * Actions (Intent.action):
 *  - "START" with extras title/text/progress(-1 = indeterminate): (re)posts the
 *     ongoing notification and promotes the service to foreground. Re-sending
 *     with a new progress updates the same notification.
 *  - "STOP": drops the foreground notification and stops the service.
 */
class UpdateDownloadService : Service() {

    companion object {
        private const val TAG = "UpdateDownloadFGS"
        private const val CHANNEL_ID = "app_update_download"
        private const val NOTIFICATION_ID = 9100
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra("title") ?: "Downloading update"
        val text = intent?.getStringExtra("text") ?: ""
        val progress = intent?.getIntExtra("progress", -1) ?: -1

        val notification = buildNotification(title, text, progress)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // On Android 14+ startForeground may throw if preconditions aren't met;
            // fall back to a plain foreground so the process isn't crashed.
            Log.w(TAG, "startForeground(dataSync) failed, using plain foreground: $e")
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "startForeground failed entirely: $e2")
            }
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "App Update Download",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows download progress for app updates"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, text: String, progress: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }

        return builder.build()
    }
}
