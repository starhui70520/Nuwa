package com.rankchord.nuwa;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import androidx.core.content.ContextCompat;

/**
 * 在 AI 流式回复或上下文整理进行期间维持前台服务与短时 CPU 唤醒锁，
 * 防止切到后台或锁屏后系统冻结 WebView 进程与网络连接导致断流重试。
 */
public class StreamKeepAliveService extends Service {
    private static final String CHANNEL_ID = "nuwa_stream_keepalive";
    private static final String CHANNEL_NAME = "AI 后台生成保活";
    private static final int NOTIFICATION_ID = 4103;
    private static final long MAX_WAKELOCK_MS = 10L * 60L * 1000L;

    private static volatile boolean desiredActive = false;
    private static volatile StreamKeepAliveService activeInstance = null;

    private final Object wakeLockGuard = new Object();
    private PowerManager.WakeLock wakeLock;
    private volatile boolean stopping = false;

    public static void start(Context context) {
        if (context == null) {
            return;
        }
        desiredActive = true;
        StreamKeepAliveService instance = activeInstance;
        if (instance != null && !instance.stopping) {
            instance.acquireWakeLock();
            return;
        }
        Context app = context.getApplicationContext();
        Intent intent = new Intent(app, StreamKeepAliveService.class);
        try {
            ContextCompat.startForegroundService(app, intent);
        } catch (Throwable ignored) {
            // Android 12+ 若在后台状态下被调用可能抛出 ForegroundServiceStartNotAllowedException，静默降级。
        }
    }

    public static void stop(Context context) {
        desiredActive = false;
        StreamKeepAliveService instance = activeInstance;
        if (instance != null) {
            instance.stopSelfSafely();
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        activeInstance = this;
        stopping = false;
        ensureNotificationChannel();
        promoteToForeground();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        activeInstance = this;
        stopping = false;
        promoteToForeground();
        if (!desiredActive) {
            stopSelfSafely();
            return START_NOT_STICKY;
        }
        acquireWakeLock();
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onTimeout(int startId) {
        desiredActive = false;
        stopSelfSafely();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        desiredActive = false;
        stopSelfSafely();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        desiredActive = false;
        stopSelfSafely();
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        releaseWakeLock();
        if (activeInstance == this) {
            activeInstance = null;
        }
        super.onDestroy();
    }

    private void stopSelfSafely() {
        stopping = true;
        releaseWakeLock();
        try {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } catch (Throwable ignored) {
        }
        try {
            stopSelf();
        } catch (Throwable ignored) {
        }
    }

    private void ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        try {
            NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager == null) {
                return;
            }
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("切到后台时保持 AI 流式回复连接不断开");
            channel.setSound(null, null);
            channel.enableVibration(false);
            channel.enableLights(false);
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        } catch (Throwable ignored) {
        }
    }

    @SuppressWarnings("deprecation")
    private void promoteToForeground() {
        try {
            Intent launchIntent = new Intent(this, MainActivity.class);
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            PendingIntent contentIntent = PendingIntent.getActivity(
                this,
                NOTIFICATION_ID,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this).setPriority(Notification.PRIORITY_LOW);

            Notification notification = builder
                .setSmallIcon(R.drawable.ic_stat_nuwa)
                .setContentTitle("Nuwa 正在生成回复")
                .setContentText("切到后台期间保持连接不断开")
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                );
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Throwable ignored) {
        }
    }

    private void acquireWakeLock() {
        synchronized (wakeLockGuard) {
            try {
                if (wakeLock == null) {
                    PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                    if (pm == null) {
                        return;
                    }
                    wakeLock = pm.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "com.rankchord.nuwa:StreamKeepAlive"
                    );
                    wakeLock.setReferenceCounted(false);
                }
                wakeLock.acquire(MAX_WAKELOCK_MS);
            } catch (Throwable ignored) {
            }
        }
    }

    private void releaseWakeLock() {
        synchronized (wakeLockGuard) {
            if (wakeLock != null) {
                try {
                    if (wakeLock.isHeld()) {
                        wakeLock.release();
                    }
                } catch (Throwable ignored) {
                }
                wakeLock = null;
            }
        }
    }
}
