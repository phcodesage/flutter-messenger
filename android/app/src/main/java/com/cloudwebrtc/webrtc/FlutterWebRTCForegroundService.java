package com.cloudwebrtc.webrtc;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import androidx.core.app.NotificationCompat;

public class FlutterWebRTCForegroundService extends Service {

    private static final String CHANNEL_ID = "screen_share_channel";
    private static final int NOTIFICATION_ID = 9999;

    /**
     * Whether this service has actually entered the foreground with the
     * mediaProjection type.
     *
     * startForegroundService() only *schedules* onStartCommand — it returns
     * immediately, so a caller that treats it as "the service is up" races the
     * main thread. MediaProjectionManager.getMediaProjection() then throws
     * "Media projections require a foreground service of type
     * FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION" because the service has not
     * gotten there yet. Callers await {@link #awaitForeground} instead.
     */
    private static final Object FOREGROUND_LOCK = new Object();
    private static volatile boolean sInForeground = false;

    /** True once the service is genuinely foregrounded, false on timeout. */
    public static boolean awaitForeground(long timeoutMs) {
        final long deadline = System.currentTimeMillis() + timeoutMs;
        synchronized (FOREGROUND_LOCK) {
            while (!sInForeground) {
                final long remaining = deadline - System.currentTimeMillis();
                if (remaining <= 0) return false;
                try {
                    FOREGROUND_LOCK.wait(remaining);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return sInForeground;
                }
            }
            return true;
        }
    }

    private static void setInForeground(boolean value) {
        synchronized (FOREGROUND_LOCK) {
            sInForeground = value;
            FOREGROUND_LOCK.notifyAll();
        }
    }

    @Override
    public void onDestroy() {
        setInForeground(false);
        super.onDestroy();
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = "Screen Sharing";
        String text = "You are sharing your screen";

        if (intent != null) {
            if (intent.hasExtra("notificationTitle")) {
                title = intent.getStringExtra("notificationTitle");
            }
            if (intent.hasExtra("notificationText")) {
                text = intent.getStringExtra("notificationText");
            }
        }

        Notification notification = buildNotification(title, text);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
            } catch (Exception e) {
                // Android 14+ (enforced hard at targetSdk 34+) refuses a
                // mediaProjection foreground service until the user has granted
                // screen-capture consent — the `android:project_media` appop.
                // Starting it before the consent dialog throws here.
                android.util.Log.w("FlutterWebRTCFGS",
                        "startForeground(mediaProjection) failed, trying plain foreground: " + e);
                try {
                    // The plain call is rejected too: the service is DECLARED as
                    // foregroundServiceType=mediaProjection in the manifest, so
                    // the system applies the same precondition either way. This
                    // second throw used to escape onStartCommand and take the
                    // whole process down with it (FATAL EXCEPTION in
                    // ActivityThread.handleServiceArgs).
                    startForeground(NOTIFICATION_ID, notification);
                } catch (Exception e2) {
                    android.util.Log.e("FlutterWebRTCFGS",
                            "Could not enter foreground at all; stopping service: " + e2);
                    // Give up cleanly rather than leaving a started service that
                    // never reached the foreground — the system would kill the
                    // app for that too.
                    stopSelf();
                    return START_NOT_STICKY;
                }
            }
        } else {
            try {
                startForeground(NOTIFICATION_ID, notification);
            } catch (Exception e) {
                android.util.Log.e("FlutterWebRTCFGS", "startForeground failed: " + e);
                stopSelf();
                return START_NOT_STICKY;
            }
        }

        // Only now is it safe for the caller to start the projection.
        setInForeground(true);
        android.util.Log.d("FlutterWebRTCFGS", "Service is in the foreground");
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Screen Sharing",
                    NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Notification for screen sharing");
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification(String title, String text) {
        // NotificationCompat rather than the platform Notification.Builder: the
        // no-channel constructor `new Notification.Builder(Context)` is
        // deprecated as of API 26, and it was the only way to build one on the
        // API 24-25 devices this app still supports (minSdk 24) — so the
        // version check could not avoid the deprecated call, only hide it in a
        // branch. NotificationCompat takes the channel id on every API level and
        // ignores it below O, which collapses the branch entirely.
        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                // LOW matches the channel's importance; below O, where there are
                // no channels, this is what keeps the screen-share notice quiet.
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .build();
    }
}
