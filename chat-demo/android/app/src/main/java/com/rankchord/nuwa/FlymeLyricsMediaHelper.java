package com.rankchord.nuwa;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import androidx.core.content.ContextCompat;

import java.lang.reflect.Field;

/**
 * Coordinates Meizu Flyme status-bar lyrics (ticker protocol) and standard Android
 * MediaSession + MediaStyle notifications while Nuwa reads AI responses aloud.
 */
final class FlymeLyricsMediaHelper {
    private static final String CHANNEL_ID = "nuwa_read_aloud";
    private static final String CHANNEL_NAME = "AI 朗读字幕与媒体控制";
    private static final int NOTIFICATION_ID = 4102;
    private static final int REQUEST_CODE_NOTIFICATIONS = 4102;
    private static final String ACTION_STOP_READ_ALOUD = "com.rankchord.nuwa.ACTION_STOP_READ_ALOUD";
    private static final String PREFS_NAME = "nuwa_media_prefs";
    private static final String KEY_NOTIF_PROMPTED = "notif_perm_prompted_once";
    private static final long MIN_UPDATE_INTERVAL_MS = 380L;
    private static final int MAX_LINE_CHARS = 80;

    private static final int FLYME_FLAG_ALWAYS_SHOW_TICKER =
        resolveFlymeNotificationFlag("FLAG_ALWAYS_SHOW_TICKER", 0x01000000);
    private static final int FLYME_FLAG_ONLY_UPDATE_TICKER =
        resolveFlymeNotificationFlag("FLAG_ONLY_UPDATE_TICKER", 0x02000000);

    private final Context appContext;
    private final Handler mainHandler;
    private final Runnable onUserStop;
    private final NotificationManager notificationManager;

    private MediaSession mediaSession;
    private boolean receiverRegistered = false;
    private boolean sessionActive = false;
    private boolean firstPostedInSession = false;
    private String currentLine = null;
    private String pendingLine = null;
    private long lastNotifyElapsedMs = 0L;
    private boolean stopQueued = false;

    private final Runnable pendingUpdateRunnable = new Runnable() {
        @Override
        public void run() {
            String line = pendingLine;
            pendingLine = null;
            if (!sessionActive || line == null || line.isEmpty()) {
                return;
            }
            postNotificationInternal(line);
        }
    };

    private final BroadcastReceiver stopReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (intent != null && ACTION_STOP_READ_ALOUD.equals(intent.getAction())) {
                handleSystemStop();
            }
        }
    };

    FlymeLyricsMediaHelper(Context context, Handler mainHandler, Runnable onUserStop) {
        this.appContext = context.getApplicationContext();
        this.mainHandler = mainHandler;
        this.onUserStop = onUserStop;
        this.notificationManager = (NotificationManager) appContext.getSystemService(Context.NOTIFICATION_SERVICE);
        ensureNotificationChannel();
    }

    void startOrUpdate(Activity activity, String rawLine) {
        String line = normalizeLine(rawLine);
        if (line.isEmpty()) {
            return;
        }

        boolean startingNew = !sessionActive;
        sessionActive = true;

        if (startingNew) {
            maybeRequestNotificationPermissionOnce(activity);
        }

        ensureReceiverRegistered();
        ensureMediaSession();
        updateMediaSessionMetadataAndState(line);

        if (!startingNew && line.equals(currentLine)) {
            return;
        }
        currentLine = line;

        long now = SystemClock.elapsedRealtime();
        long elapsed = now - lastNotifyElapsedMs;
        if (startingNew || !firstPostedInSession || elapsed >= MIN_UPDATE_INTERVAL_MS) {
            mainHandler.removeCallbacks(pendingUpdateRunnable);
            pendingLine = null;
            postNotificationInternal(line);
        } else {
            pendingLine = line;
            mainHandler.removeCallbacks(pendingUpdateRunnable);
            mainHandler.postDelayed(pendingUpdateRunnable, Math.max(40L, MIN_UPDATE_INTERVAL_MS - elapsed));
        }
    }

    void stop() {
        mainHandler.removeCallbacks(pendingUpdateRunnable);
        pendingLine = null;
        currentLine = null;
        sessionActive = false;
        firstPostedInSession = false;

        if (mediaSession != null) {
            try {
                PlaybackState stopped = new PlaybackState.Builder()
                    .setState(PlaybackState.STATE_STOPPED, 0L, 0f, SystemClock.elapsedRealtime())
                    .setActions(0L)
                    .build();
                mediaSession.setPlaybackState(stopped);
                mediaSession.setActive(false);
            } catch (Throwable ignored) {
            }
        }

        if (notificationManager != null) {
            try {
                notificationManager.cancel(NOTIFICATION_ID);
            } catch (Throwable ignored) {
            }
        }
    }

    void destroy() {
        stop();
        if (receiverRegistered) {
            try {
                appContext.unregisterReceiver(stopReceiver);
            } catch (Throwable ignored) {
            }
            receiverRegistered = false;
        }
        if (mediaSession != null) {
            try {
                mediaSession.setCallback(null);
                mediaSession.release();
            } catch (Throwable ignored) {
            }
            mediaSession = null;
        }
    }

    private void handleSystemStop() {
        if (!sessionActive || stopQueued) {
            return;
        }
        stopQueued = true;
        mainHandler.post(() -> {
            stopQueued = false;
            if (!sessionActive) {
                return;
            }
            stop();
            if (onUserStop != null) {
                onUserStop.run();
            }
        });
    }

    private void ensureNotificationChannel() {
        if (notificationManager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        try {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("显示 AI 朗读状态栏字幕与锁屏控制");
            channel.setSound(null, null);
            channel.enableVibration(false);
            channel.enableLights(false);
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            notificationManager.createNotificationChannel(channel);
        } catch (Throwable ignored) {
        }
    }

    private void maybeRequestNotificationPermissionOnce(Activity activity) {
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return;
        }
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED) {
            return;
        }
        try {
            SharedPreferences prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            if (prefs.getBoolean(KEY_NOTIF_PROMPTED, false)) {
                return;
            }
            prefs.edit().putBoolean(KEY_NOTIF_PROMPTED, true).apply();
            activity.requestPermissions(
                new String[] { Manifest.permission.POST_NOTIFICATIONS },
                REQUEST_CODE_NOTIFICATIONS
            );
        } catch (Throwable ignored) {
        }
    }

    private void ensureReceiverRegistered() {
        if (receiverRegistered) {
            return;
        }
        try {
            IntentFilter filter = new IntentFilter(ACTION_STOP_READ_ALOUD);
            ContextCompat.registerReceiver(appContext, stopReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);
            receiverRegistered = true;
        } catch (Throwable ignored) {
        }
    }

    private void ensureMediaSession() {
        if (mediaSession != null) {
            try {
                if (!mediaSession.isActive()) {
                    mediaSession.setActive(true);
                }
            } catch (Throwable ignored) {
            }
            return;
        }
        try {
            MediaSession session = new MediaSession(appContext, "NuwaReadAloud");
            session.setCallback(new MediaSession.Callback() {
                @Override
                public void onPause() {
                    handleSystemStop();
                }

                @Override
                public void onStop() {
                    handleSystemStop();
                }
            }, mainHandler);
            session.setActive(true);
            mediaSession = session;
        } catch (Throwable ignored) {
        }
    }

    private void updateMediaSessionMetadataAndState(String line) {
        if (mediaSession == null) {
            return;
        }
        try {
            PlaybackState playing = new PlaybackState.Builder()
                .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f, SystemClock.elapsedRealtime())
                .setActions(
                    PlaybackState.ACTION_PAUSE
                        | PlaybackState.ACTION_STOP
                        | PlaybackState.ACTION_PLAY_PAUSE
                )
                .build();
            mediaSession.setPlaybackState(playing);

            MediaMetadata metadata = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, line)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Nuwa AI 朗读")
                .build();
            mediaSession.setMetadata(metadata);
        } catch (Throwable ignored) {
        }
    }

    @SuppressWarnings("deprecation")
    private void postNotificationInternal(String line) {
        if (!sessionActive || notificationManager == null) {
            return;
        }
        try {
            if (!notificationManager.areNotificationsEnabled()) {
                return;
            }
        } catch (Throwable ignored) {
        }

        boolean isUpdate = firstPostedInSession;
        firstPostedInSession = true;
        lastNotifyElapsedMs = SystemClock.elapsedRealtime();

        try {
            Intent launchIntent = new Intent(appContext, MainActivity.class);
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            PendingIntent contentPendingIntent = PendingIntent.getActivity(
                appContext,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            Intent stopIntent = new Intent(ACTION_STOP_READ_ALOUD);
            stopIntent.setPackage(appContext.getPackageName());
            PendingIntent stopPendingIntent = PendingIntent.getBroadcast(
                appContext,
                1,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(appContext, CHANNEL_ID)
                : new Notification.Builder(appContext).setPriority(Notification.PRIORITY_LOW);

            Notification.Action stopAction = new Notification.Action.Builder(
                Icon.createWithResource(appContext, android.R.drawable.ic_media_pause),
                "停止",
                stopPendingIntent
            ).build();

            builder
                .setSmallIcon(R.drawable.ic_stat_nuwa)
                .setContentTitle("Nuwa AI 朗读")
                .setContentText(line)
                .setTicker(line)
                .setContentIntent(contentPendingIntent)
                .setDeleteIntent(stopPendingIntent)
                .addAction(stopAction)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setCategory(Notification.CATEGORY_TRANSPORT);

            if (mediaSession != null) {
                Notification.MediaStyle style = new Notification.MediaStyle()
                    .setMediaSession(mediaSession.getSessionToken())
                    .setShowActionsInCompactView(0);
                builder.setStyle(style);
            }

            boolean flymeDevice = OemSpeechHelper.isFlyme()
                || OemSpeechHelper.detectBrand() == OemSpeechHelper.Brand.MEIZU;
            if (flymeDevice) {
                Bundle flymeExtras = new Bundle();
                flymeExtras.putInt("ticker_icon", R.drawable.ic_stat_nuwa);
                flymeExtras.putBoolean("ticker_icon_switch", false);
                flymeExtras.putInt("flyme.notification.lyric_type", 1);
                builder.addExtras(flymeExtras);
            }

            Notification notification = builder.build();
            if (flymeDevice) {
                notification.tickerText = line;
                notification.flags |= FLYME_FLAG_ALWAYS_SHOW_TICKER | Notification.FLAG_ONGOING_EVENT;
                if (isUpdate) {
                    notification.flags |= FLYME_FLAG_ONLY_UPDATE_TICKER;
                }
            }

            notificationManager.notify(NOTIFICATION_ID, notification);
        } catch (Throwable ignored) {
        }
    }

    private static String normalizeLine(String rawLine) {
        if (rawLine == null) {
            return "";
        }
        String collapsed = rawLine.replaceAll("\\s+", " ").trim();
        if (collapsed.length() <= MAX_LINE_CHARS) {
            return collapsed;
        }
        return collapsed.substring(0, MAX_LINE_CHARS - 1).trim() + "…";
    }

    @SuppressLint("PrivateApi")
    private static int resolveFlymeNotificationFlag(String fieldName, int fallback) {
        try {
            Field field = Notification.class.getDeclaredField(fieldName);
            field.setAccessible(true);
            return field.getInt(null);
        } catch (Throwable ignored) {
            return fallback;
        }
    }
}
