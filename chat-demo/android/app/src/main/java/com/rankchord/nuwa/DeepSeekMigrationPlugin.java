package com.rankchord.nuwa;

import android.Manifest;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.speech.RecognitionListener;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

@CapacitorPlugin(
    name = "DeepSeekMigration",
    permissions = {
        @Permission(alias = "microphone", strings = { Manifest.permission.RECORD_AUDIO })
    }
)
public class DeepSeekMigrationPlugin extends Plugin {
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private SpeechRecognizer speechRecognizer;
    private final StringBuilder speechCommitted = new StringBuilder();
    private String speechPartial = "";
    private String speechLocale = "zh-CN";
    private boolean speechActive = false;
    private PluginCall pendingStopCall;
    private Runnable stopTimeoutRunnable;
    private long lastRmsEmitMs = 0L;
    private final Set<String> blacklistedAsrKeys = new HashSet<>();
    private ComponentName activeAsrComponent = null;
    private String lastWorkingAsrPkg = null;
    private boolean speechSessionReady = false;
    private int consecutiveAsrErrors = 0;
    private TextToSpeech textToSpeech;
    private boolean ttsReady = false;
    private boolean ttsInitializing = false;
    private String activeTtsEnginePkg = null;
    private String activeUtteranceId;
    private final List<Runnable> pendingTtsActions = new ArrayList<>();
    private final List<Runnable> pendingTtsErrors = new ArrayList<>();
    private final Map<String, String> utteranceChunkTexts = new HashMap<>();
    private FlymeLyricsMediaHelper lyricsMediaHelper;
    private AudioManager audioManager;
    private AudioFocusRequest audioFocusRequest;
    private final AudioManager.OnAudioFocusChangeListener audioFocusListener = focusChange -> {
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
            mainHandler.post(this::handleMediaStopControl);
        }
    };
    private volatile boolean updateDownloading = false;
    @PluginMethod
    public void openExportBrowser(PluginCall call) {
        boolean clearSession = Boolean.TRUE.equals(call.getBoolean("clearSession", false));
        Intent intent = new Intent(getContext(), MigrationWebViewActivity.class);
        intent.putExtra(MigrationWebViewActivity.EXTRA_CLEAR_SESSION, clearSession);
        getActivity().startActivity(intent);
        call.resolve();
    }

    @PluginMethod
    public void consumePendingExport(PluginCall call) {
        SharedPreferences prefs = getContext().getSharedPreferences(
            MigrationWebViewActivity.PREFS_NAME,
            Context.MODE_PRIVATE
        );
        String path = prefs.getString(MigrationWebViewActivity.KEY_PENDING_PATH, null);
        String name = prefs.getString(MigrationWebViewActivity.KEY_PENDING_NAME, "deepseek_data.zip");

        JSObject ret = new JSObject();
        if (path == null) {
            ret.put("hasPending", false);
            call.resolve(ret);
            return;
        }

        File file = new File(path);
        if (!file.exists()) {
            prefs.edit().clear().apply();
            ret.put("hasPending", false);
            call.resolve(ret);
            return;
        }

        android.util.Log.d("DSAPP_MIGRATION", "consumePendingExport: " + file.getAbsolutePath() + " size=" + file.length());
        ret.put("hasPending", true);
        ret.put("filePath", file.getAbsolutePath());
        ret.put("fileName", name);
        call.resolve(ret);
    }

    @PluginMethod
    public void clearPendingExport(PluginCall call) {
        SharedPreferences prefs = getContext().getSharedPreferences(
            MigrationWebViewActivity.PREFS_NAME,
            Context.MODE_PRIVATE
        );
        String path = prefs.getString(MigrationWebViewActivity.KEY_PENDING_PATH, null);
        if (path != null) {
            //noinspection ResultOfMethodCallIgnored
            new File(path).delete();
        }
        prefs.edit().clear().apply();
        call.resolve();
    }

    @PluginMethod
    public void startPlatformAuth(PluginCall call) {
        Intent intent = new Intent(getContext(), PlatformAuthActivity.class);
        getActivity().startActivity(intent);
        call.resolve();
    }

    @PluginMethod
    public void consumePendingPlatformAuth(PluginCall call) {
        SharedPreferences prefs = getContext().getSharedPreferences(
            PlatformAuthActivity.AUTH_PREFS,
            Context.MODE_PRIVATE
        );
        String token = prefs.getString(PlatformAuthActivity.KEY_PENDING_TOKEN, null);
        String label = prefs.getString(PlatformAuthActivity.KEY_PENDING_LABEL, null);

        JSObject ret = new JSObject();
        if (token == null || token.isEmpty()) {
            ret.put("hasPending", false);
            call.resolve(ret);
            return;
        }

        prefs.edit()
            .remove(PlatformAuthActivity.KEY_PENDING_TOKEN)
            .remove(PlatformAuthActivity.KEY_PENDING_LABEL)
            .apply();

        ret.put("hasPending", true);
        ret.put("token", token);
        ret.put("accountLabel", label != null ? label : "DeepSeek API 账号");
        call.resolve(ret);
    }

    @PluginMethod
    public void logoutPlatformAuth(PluginCall call) {
        final String token = call.getString("token", "");
        if (token != null && !token.isEmpty()) {
            new Thread(() -> {
                HttpURLConnection conn = null;
                try {
                    URL url = new URL("https://platform.deepseek.com/auth-api/v0/users/logout");
                    conn = (HttpURLConnection) url.openConnection();
                    conn.setRequestMethod("POST");
                    conn.setInstanceFollowRedirects(false);
                    conn.setConnectTimeout(10000);
                    conn.setReadTimeout(10000);
                    PlatformAuthActivity.applyPlatformClientHeaders(conn);
                    conn.setRequestProperty("x-dsh-auth-token", token);
                    conn.getResponseCode();
                } catch (Exception ignored) {
                } finally {
                    if (conn != null) {
                        conn.disconnect();
                    }
                }
            }).start();
        }
        call.resolve();
    }

    @PluginMethod
    public void ensureMicrophonePermission(PluginCall call) {
        boolean granted = ContextCompat.checkSelfPermission(
            getContext(),
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED;
        if (granted) {
            JSObject ret = new JSObject();
            ret.put("granted", true);
            call.resolve(ret);
            return;
        }
        requestPermissionForAlias("microphone", call, "onMicrophonePermissionResult");
    }

    @PermissionCallback
    private void onMicrophonePermissionResult(PluginCall call) {
        if (call == null) {
            return;
        }
        boolean granted = ContextCompat.checkSelfPermission(
            getContext(),
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED;
        JSObject ret = new JSObject();
        ret.put("granted", granted);
        call.resolve(ret);
    }

    @PluginMethod
    public void startSpeechRecognition(PluginCall call) {
        final String locale = call.getString("locale", "zh-CN");
        mainHandler.post(() -> {
            if (ContextCompat.checkSelfPermission(getContext(), Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
                call.reject("PERMISSION_DENIED");
                return;
            }
            destroySpeechRecognizerInternal();
            speechCommitted.setLength(0);
            speechPartial = "";
            speechLocale = locale != null && !locale.isEmpty() ? locale : "zh-CN";
            speechActive = true;
            speechSessionReady = false;
            consecutiveAsrErrors = 0;
            pendingStopCall = null;

            List<ComponentName> candidates = OemSpeechHelper.getRankedAsrCandidates(
                getContext(),
                speechLocale,
                blacklistedAsrKeys
            );
            if (candidates.isEmpty() && !blacklistedAsrKeys.isEmpty()) {
                blacklistedAsrKeys.clear();
                candidates = OemSpeechHelper.getRankedAsrCandidates(
                    getContext(),
                    speechLocale,
                    blacklistedAsrKeys
                );
            }
            if (candidates.isEmpty()) {
                speechActive = false;
                call.reject("UNAVAILABLE");
                return;
            }
            startRecognizerWithCandidate(candidates.get(0), call);
        });
    }

    private void startRecognizerWithCandidate(final ComponentName candidate, final PluginCall initialCall) {
        if (!speechActive) {
            if (initialCall != null) {
                initialCall.resolve();
            }
            return;
        }
        destroySpeechRecognizerInternal();
        activeAsrComponent = candidate;
        speechSessionReady = false;
        final String candidateKey = candidate != null ? candidate.flattenToString() : "__default__";

        try {
            speechRecognizer = candidate != null
                ? SpeechRecognizer.createSpeechRecognizer(getContext(), candidate)
                : SpeechRecognizer.createSpeechRecognizer(getContext());
        } catch (Exception e) {
            blacklistedAsrKeys.add(candidateKey);
            tryNextAsrCandidate(initialCall, e);
            return;
        }

        if (speechRecognizer == null) {
            blacklistedAsrKeys.add(candidateKey);
            tryNextAsrCandidate(initialCall, null);
            return;
        }

        final OemSpeechHelper.Brand brand = OemSpeechHelper.detectBrand();
        speechRecognizer.setRecognitionListener(new RecognitionListener() {
            @Override
            public void onReadyForSpeech(Bundle params) {
                speechSessionReady = true;
                consecutiveAsrErrors = 0;
                if (candidate != null) {
                    lastWorkingAsrPkg = candidate.getPackageName();
                }
            }

            @Override
            public void onBeginningOfSpeech() {
                speechSessionReady = true;
                consecutiveAsrErrors = 0;
            }

            @Override
            public void onRmsChanged(float rmsdB) {
                long now = System.currentTimeMillis();
                if (now - lastRmsEmitMs < 40L) {
                    return;
                }
                lastRmsEmitMs = now;
                float level = Math.max(0f, Math.min(1f, (rmsdB + 2f) / 12f));
                emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-rms',{detail:" + level + "}))");
            }

            @Override
            public void onBufferReceived(byte[] buffer) {
            }

            @Override
            public void onEndOfSpeech() {
            }

            @Override
            public void onError(int error) {
                if (pendingStopCall != null) {
                    finishPendingStop();
                    return;
                }
                if (!speechActive) {
                    return;
                }
                boolean hasMicPerm = ContextCompat.checkSelfPermission(
                    getContext(),
                    Manifest.permission.RECORD_AUDIO
                ) == PackageManager.PERMISSION_GRANTED;
                if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS && !hasMicPerm) {
                    speechActive = false;
                    destroySpeechRecognizerInternal();
                    emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'PERMISSION_DENIED'}))");
                    return;
                }
                // OEM private-permission or unready client error: failover to next ranked engine.
                if (!speechSessionReady
                    && (error == SpeechRecognizer.ERROR_CLIENT
                        || error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS
                        || error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED
                        || error == 11 /* ERROR_SERVER_DISCONNECTED */)) {
                    blacklistedAsrKeys.add(candidateKey);
                    tryNextAsrCandidate(null, null);
                    return;
                }
                if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    scheduleAsrRestart(120L, brand);
                    return;
                }
                consecutiveAsrErrors++;
                if (consecutiveAsrErrors >= 4 && getCombinedSpeechText().isEmpty()) {
                    speechActive = false;
                    destroySpeechRecognizerInternal();
                    emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'UNAVAILABLE'}))");
                    return;
                }
                if (error == SpeechRecognizer.ERROR_CLIENT && getCombinedSpeechText().isEmpty()) {
                    blacklistedAsrKeys.add(candidateKey);
                    tryNextAsrCandidate(null, null);
                    return;
                }
                scheduleAsrRestart(160L, brand);
            }

            @Override
            public void onResults(Bundle results) {
                speechSessionReady = true;
                consecutiveAsrErrors = 0;
                if (candidate != null) {
                    lastWorkingAsrPkg = candidate.getPackageName();
                }
                ArrayList<String> matches = results != null
                    ? results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    : null;
                if (matches != null && !matches.isEmpty()) {
                    String text = matches.get(0);
                    if (text != null && !text.isEmpty()) {
                        speechCommitted.append(text);
                    }
                }
                speechPartial = "";
                if (pendingStopCall != null) {
                    finishPendingStop();
                } else if (speechActive) {
                    scheduleAsrRestart(60L, brand);
                }
            }

            @Override
            public void onPartialResults(Bundle partialResults) {
                speechSessionReady = true;
                ArrayList<String> matches = partialResults != null
                    ? partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    : null;
                if (matches != null && !matches.isEmpty()) {
                    String text = matches.get(0);
                    if (text != null && !text.isEmpty()) {
                        speechPartial = text;
                    }
                }
            }

            @Override
            public void onEvent(int eventType, Bundle params) {
            }
        });

        try {
            speechRecognizer.startListening(OemSpeechHelper.buildRecognizerIntent(getContext(), speechLocale, brand));
            if (initialCall != null) {
                initialCall.resolve();
            }
        } catch (Exception e) {
            blacklistedAsrKeys.add(candidateKey);
            tryNextAsrCandidate(initialCall, e);
        }
    }

    private void tryNextAsrCandidate(final PluginCall initialCall, final Exception lastError) {
        destroySpeechRecognizerInternal();
        if (!speechActive) {
            if (initialCall != null) {
                initialCall.resolve();
            }
            return;
        }
        List<ComponentName> next = OemSpeechHelper.getRankedAsrCandidates(
            getContext(),
            speechLocale,
            blacklistedAsrKeys
        );
        if (!next.isEmpty()) {
            startRecognizerWithCandidate(next.get(0), initialCall);
            return;
        }
        speechActive = false;
        if (initialCall != null) {
            if (lastError != null) {
                initialCall.reject("UNAVAILABLE", lastError);
            } else {
                initialCall.reject("UNAVAILABLE");
            }
        } else {
            emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'UNAVAILABLE'}))");
        }
    }

    private void scheduleAsrRestart(long delayMs, final OemSpeechHelper.Brand brand) {
        mainHandler.postDelayed(() -> {
            if (speechActive && speechRecognizer != null) {
                try {
                    speechRecognizer.startListening(
                        OemSpeechHelper.buildRecognizerIntent(getContext(), speechLocale, brand)
                    );
                } catch (Exception ignored) {
                }
            }
        }, delayMs);
    }

    @PluginMethod
    public void stopSpeechRecognition(PluginCall call) {
        mainHandler.post(() -> {
            speechActive = false;
            if (speechRecognizer == null) {
                JSObject ret = new JSObject();
                ret.put("text", getCombinedSpeechText());
                speechCommitted.setLength(0);
                speechPartial = "";
                call.resolve(ret);
                return;
            }
            if (pendingStopCall != null) {
                JSObject prev = new JSObject();
                prev.put("text", "");
                pendingStopCall.resolve(prev);
            }
            pendingStopCall = call;
            try {
                speechRecognizer.stopListening();
            } catch (Exception ignored) {
                finishPendingStop();
                return;
            }
            stopTimeoutRunnable = this::finishPendingStop;
            mainHandler.postDelayed(stopTimeoutRunnable, 900L);
        });
    }

    @PluginMethod
    public void cancelSpeechRecognition(PluginCall call) {
        mainHandler.post(() -> {
            speechActive = false;
            if (stopTimeoutRunnable != null) {
                mainHandler.removeCallbacks(stopTimeoutRunnable);
                stopTimeoutRunnable = null;
            }
            if (pendingStopCall != null) {
                JSObject empty = new JSObject();
                empty.put("text", "");
                pendingStopCall.resolve(empty);
                pendingStopCall = null;
            }
            speechCommitted.setLength(0);
            speechPartial = "";
            destroySpeechRecognizerInternal();
            call.resolve();
        });
    }

    @Override
    protected void handleOnDestroy() {
        mainHandler.post(() -> {
            speechActive = false;
            pendingStopCall = null;
            destroySpeechRecognizerInternal();
            activeUtteranceId = null;
            utteranceChunkTexts.clear();
            pendingTtsActions.clear();
            pendingTtsErrors.clear();
            abandonTtsAudioFocus();
            if (lyricsMediaHelper != null) {
                lyricsMediaHelper.destroy();
                lyricsMediaHelper = null;
            }
            if (textToSpeech != null) {
                try {
                    textToSpeech.stop();
                    textToSpeech.shutdown();
                } catch (Exception ignored) {
                }
                textToSpeech = null;
            }
            activeTtsEnginePkg = null;
            ttsReady = false;
            ttsInitializing = false;
        });
        super.handleOnDestroy();
    }

    private String getCombinedSpeechText() {
        String partial = speechPartial != null ? speechPartial : "";
        return (speechCommitted.toString() + partial).trim();
    }

    private void finishPendingStop() {
        if (stopTimeoutRunnable != null) {
            mainHandler.removeCallbacks(stopTimeoutRunnable);
            stopTimeoutRunnable = null;
        }
        PluginCall stopCall = pendingStopCall;
        pendingStopCall = null;
        String text = getCombinedSpeechText();
        speechCommitted.setLength(0);
        speechPartial = "";
        speechActive = false;
        destroySpeechRecognizerInternal();
        if (stopCall != null) {
            JSObject ret = new JSObject();
            ret.put("text", text);
            stopCall.resolve(ret);
        }
    }

    private void destroySpeechRecognizerInternal() {
        if (stopTimeoutRunnable != null) {
            mainHandler.removeCallbacks(stopTimeoutRunnable);
            stopTimeoutRunnable = null;
        }
        if (speechRecognizer != null) {
            try {
                speechRecognizer.destroy();
            } catch (Exception ignored) {
            }
            speechRecognizer = null;
        }
    }

    @PluginMethod
    public void getAppVersion(PluginCall call) {
        try {
            PackageInfo info = getContext().getPackageManager().getPackageInfo(
                getContext().getPackageName(),
                0
            );
            long versionCode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? info.getLongVersionCode()
                : info.versionCode;
            JSObject ret = new JSObject();
            ret.put("versionName", info.versionName != null ? info.versionName : "0.1.1");
            ret.put("versionCode", versionCode);
            call.resolve(ret);
        } catch (Exception e) {
            call.reject("Failed to read app version", e);
        }
    }

    @PluginMethod
    public void downloadAndInstallApk(PluginCall call) {
        String downloadUrl = call.getString("url");
        if (downloadUrl == null || (!downloadUrl.startsWith("https://") && !downloadUrl.startsWith("http://"))) {
            call.reject("Invalid APK URL");
            return;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            && !getContext().getPackageManager().canRequestPackageInstalls()) {
            Intent permIntent = new Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + getContext().getPackageName())
            );
            permIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(permIntent);
            JSObject ret = new JSObject();
            ret.put("started", false);
            ret.put("needsInstallPermission", true);
            call.resolve(ret);
            return;
        }

        if (updateDownloading) {
            call.reject("Update download already in progress");
            return;
        }

        updateDownloading = true;
        new Thread(() -> {
            HttpURLConnection conn = null;
            try {
                String currentUrl = downloadUrl;
                for (int hop = 0; hop < 6; hop++) {
                    URL url = new URL(currentUrl);
                    conn = (HttpURLConnection) url.openConnection();
                    conn.setInstanceFollowRedirects(false);
                    conn.setConnectTimeout(15000);
                    conn.setReadTimeout(30000);
                    conn.setRequestProperty("User-Agent", "Nuwa-Android-Updater");
                    int code = conn.getResponseCode();
                    if (code == HttpURLConnection.HTTP_MOVED_PERM
                        || code == HttpURLConnection.HTTP_MOVED_TEMP
                        || code == HttpURLConnection.HTTP_SEE_OTHER
                        || code == 307
                        || code == 308) {
                        String location = conn.getHeaderField("Location");
                        conn.disconnect();
                        conn = null;
                        if (location == null || location.isEmpty()) {
                            throw new IllegalStateException("Redirect without Location header");
                        }
                        currentUrl = new URL(url, location).toString();
                        continue;
                    }
                    break;
                }

                if (conn == null || conn.getResponseCode() < 200 || conn.getResponseCode() >= 300) {
                    int status = conn != null ? conn.getResponseCode() : -1;
                    throw new IllegalStateException("HTTP " + status);
                }

                long totalBytes = conn.getContentLengthLong();
                File updateDir = new File(getContext().getCacheDir(), "updates");
                if (!updateDir.exists()) {
                    //noinspection ResultOfMethodCallIgnored
                    updateDir.mkdirs();
                }
                File partFile = new File(updateDir, "nuwa-update.apk.part");
                File targetFile = new File(updateDir, "nuwa-update.apk");
                if (partFile.exists()) {
                    //noinspection ResultOfMethodCallIgnored
                    partFile.delete();
                }

                try (InputStream in = conn.getInputStream();
                     FileOutputStream out = new FileOutputStream(partFile)) {
                    byte[] buffer = new byte[16384];
                    long downloaded = 0L;
                    int lastPercent = -1;
                    long lastEmitMs = 0L;
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                        downloaded += read;
                        if (totalBytes > 0) {
                            int pct = (int) Math.min(100L, (downloaded * 100L) / totalBytes);
                            long now = System.currentTimeMillis();
                            if (pct != lastPercent && (now - lastEmitMs >= 120 || pct == 100)) {
                                lastPercent = pct;
                                lastEmitMs = now;
                                emitWebEvent(
                                    "window.dispatchEvent(new CustomEvent('dsapp:update-progress',{detail:{progress:"
                                        + pct
                                        + "}}));"
                                );
                            }
                        }
                    }
                    out.flush();
                }

                if (targetFile.exists()) {
                    //noinspection ResultOfMethodCallIgnored
                    targetFile.delete();
                }
                if (!partFile.renameTo(targetFile)) {
                    throw new IllegalStateException("Failed to finalize APK file");
                }

                emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:update-progress',{detail:{progress:100}}));");

                Uri apkUri = FileProvider.getUriForFile(
                    getContext(),
                    getContext().getPackageName() + ".fileprovider",
                    targetFile
                );
                Intent installIntent = new Intent(Intent.ACTION_VIEW);
                installIntent.setDataAndType(apkUri, "application/vnd.android.package-archive");
                installIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);

                mainHandler.post(() -> {
                    getContext().startActivity(installIntent);
                    JSObject ret = new JSObject();
                    ret.put("started", true);
                    call.resolve(ret);
                });
            } catch (Exception e) {
                mainHandler.post(() -> call.reject("APK download failed: " + e.getMessage(), e));
            } finally {
                updateDownloading = false;
                if (conn != null) {
                    conn.disconnect();
                }
            }
        }).start();
    }

    @PluginMethod
    public void setSystemBarsStyle(PluginCall call) {
        final boolean dark = Boolean.TRUE.equals(call.getBoolean("dark", false));
        mainHandler.post(() -> {
            if (getActivity() instanceof MainActivity) {
                ((MainActivity) getActivity()).applySystemBarsStyle(dark);
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void getSpeechEngineInfo(PluginCall call) {
        OemSpeechHelper.Brand brand = OemSpeechHelper.detectBrand();
        boolean hyperOs = OemSpeechHelper.isHyperOs();
        String osLabel = OemSpeechHelper.getOsLabel();

        String asrPkg = lastWorkingAsrPkg;
        if (asrPkg == null || asrPkg.isEmpty()) {
            List<ComponentName> asrList = OemSpeechHelper.getRankedAsrCandidates(
                getContext(),
                "zh-CN",
                blacklistedAsrKeys
            );
            for (ComponentName cn : asrList) {
                if (cn != null && cn.getPackageName() != null && !cn.getPackageName().isEmpty()) {
                    asrPkg = cn.getPackageName();
                    break;
                }
            }
        }
        String ttsPkg = activeTtsEnginePkg;
        if (ttsPkg == null || ttsPkg.isEmpty()) {
            List<String> ttsList = OemSpeechHelper.getRankedTtsEngines(getContext(), "zh-CN");
            for (String pkg : ttsList) {
                if (pkg != null && !pkg.isEmpty()) {
                    ttsPkg = pkg;
                    break;
                }
            }
        }

        String resolvedAsrPkg = asrPkg != null ? asrPkg : "";
        String resolvedTtsPkg = ttsPkg != null ? ttsPkg : "";
        JSObject ret = new JSObject();
        ret.put("brand", brand.name().toLowerCase(Locale.ROOT));
        ret.put("osLabel", osLabel);
        ret.put("isHyperOs", hyperOs);
        ret.put("isFlyme", OemSpeechHelper.isFlyme());
        ret.put("asrEngine", resolvedAsrPkg);
        ret.put("asrLabel", OemSpeechHelper.describeEnginePackage(getContext(), resolvedAsrPkg));
        ret.put("ttsEngine", resolvedTtsPkg);
        ret.put("ttsLabel", OemSpeechHelper.describeEnginePackage(getContext(), resolvedTtsPkg));
        ret.put("browserMode", InAppBrowserHelper.getInstance().getMode());
        ret.put("browserPkg", InAppBrowserHelper.getInstance().getProviderPackage());
        call.resolve(ret);
    }

    @PluginMethod
    public void prepareExternalUrls(PluginCall call) {
        JSArray arr = call.getArray("urls");
        final List<String> urls = new ArrayList<>();
        if (arr != null) {
            int limit = Math.min(arr.length(), 5);
            for (int i = 0; i < limit; i++) {
                try {
                    String item = arr.getString(i);
                    if (item != null && !item.trim().isEmpty()) {
                        urls.add(item.trim());
                    }
                } catch (Exception ignored) {
                }
            }
        }
        if (!urls.isEmpty()) {
            mainHandler.post(() -> InAppBrowserHelper.getInstance().prepareUrls(getContext(), urls));
        }
        call.resolve();
    }

    @PluginMethod
    public void openExternalUrl(PluginCall call) {
        final String url = call.getString("url", "");
        final boolean dark = Boolean.TRUE.equals(call.getBoolean("dark", false));
        mainHandler.post(() -> {
            if (getActivity() != null && url != null && !url.isEmpty()) {
                InAppBrowserHelper.getInstance().openUrl(getActivity(), url, dark);
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void openSystemTtsSettings(PluginCall call) {
        try {
            Intent intent = new Intent("com.android.settings.TTS_SETTINGS");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(intent);
        } catch (Exception ignored) {
            try {
                Intent fallback = new Intent(Settings.ACTION_SETTINGS);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(fallback);
            } catch (Exception ignored2) {
            }
        }
        call.resolve();
    }

    @PluginMethod
    public void speakText(PluginCall call) {
        final String rawText = call.getString("text", "");
        final String locale = call.getString("locale", "zh-CN");
        final String voiceTone = call.getString("voice", "stella");
        final String text = rawText != null ? rawText.trim() : "";
        if (text.isEmpty()) {
            call.reject("EMPTY_TEXT");
            return;
        }
        mainHandler.post(() -> ensureTtsInitialized(
            locale,
            () -> {
                if (textToSpeech == null) {
                    call.reject("TTS_UNAVAILABLE");
                    return;
                }
                Locale targetLocale = (locale != null && locale.toLowerCase(Locale.ROOT).startsWith("en"))
                    ? Locale.US
                    : Locale.SIMPLIFIED_CHINESE;
                int langRes = textToSpeech.setLanguage(targetLocale);
                if (langRes == TextToSpeech.LANG_MISSING_DATA || langRes == TextToSpeech.LANG_NOT_SUPPORTED) {
                    textToSpeech.setLanguage(Locale.getDefault());
                }
                OemSpeechHelper.selectBestVoice(textToSpeech, targetLocale, voiceTone);
                requestTtsAudioFocus();

                final String utteranceId = UUID.randomUUID().toString();
                activeUtteranceId = utteranceId;
                utteranceChunkTexts.clear();
                int maxLen = Math.max(500, Math.min(3800, TextToSpeech.getMaxSpeechInputLength() - 200));
                List<String> chunks = splitIntoLyricSentences(text, maxLen);
                if (chunks.isEmpty()) {
                    chunks.add(text);
                }
                for (int i = 0; i < chunks.size(); i++) {
                    int queueMode = (i == 0) ? TextToSpeech.QUEUE_FLUSH : TextToSpeech.QUEUE_ADD;
                    String chunkId = (i == chunks.size() - 1) ? utteranceId : (utteranceId + ":" + i);
                    String chunkText = chunks.get(i);
                    utteranceChunkTexts.put(chunkId, chunkText);
                    int status = textToSpeech.speak(chunkText, queueMode, null, chunkId);
                    if (status != TextToSpeech.SUCCESS) {
                        activeUtteranceId = null;
                        utteranceChunkTexts.clear();
                        abandonTtsAudioFocus();
                        if (lyricsMediaHelper != null) {
                            lyricsMediaHelper.stop();
                        }
                        call.reject("TTS_SPEAK_FAILED");
                        return;
                    }
                }
                getLyricsMediaHelper().startOrUpdate(getActivity(), chunks.get(0));
                JSObject ret = new JSObject();
                ret.put("utteranceId", utteranceId);
                call.resolve(ret);
            },
            () -> call.reject("TTS_UNAVAILABLE")
        ));
    }

    @PluginMethod
    public void stopSpeaking(PluginCall call) {
        mainHandler.post(() -> {
            activeUtteranceId = null;
            utteranceChunkTexts.clear();
            pendingTtsActions.clear();
            pendingTtsErrors.clear();
            abandonTtsAudioFocus();
            if (lyricsMediaHelper != null) {
                lyricsMediaHelper.stop();
            }
            if (textToSpeech != null) {
                try {
                    textToSpeech.stop();
                } catch (Exception ignored) {
                }
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void updateReadAloudNotification(PluginCall call) {
        final String line = call.getString("line", "");
        mainHandler.post(() -> {
            if (line != null && !line.trim().isEmpty()) {
                getLyricsMediaHelper().startOrUpdate(getActivity(), line);
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void clearReadAloudNotification(PluginCall call) {
        mainHandler.post(() -> {
            if (lyricsMediaHelper != null) {
                lyricsMediaHelper.stop();
            }
            call.resolve();
        });
    }

    private void ensureTtsInitialized(final String locale, Runnable onReady, Runnable onError) {
        if (textToSpeech != null && ttsReady) {
            onReady.run();
            return;
        }
        pendingTtsActions.add(onReady);
        pendingTtsErrors.add(onError);
        if (ttsInitializing) {
            return;
        }
        ttsInitializing = true;
        Locale targetLocale = (locale != null && locale.toLowerCase(Locale.ROOT).startsWith("en"))
            ? Locale.US
            : Locale.SIMPLIFIED_CHINESE;
        List<String> engines = OemSpeechHelper.getRankedTtsEngines(getContext(), locale);
        tryInitTtsEngine(engines, 0, targetLocale);
    }

    private void tryInitTtsEngine(final List<String> engines, final int index, final Locale targetLocale) {
        if (index >= engines.size()) {
            ttsInitializing = false;
            ttsReady = false;
            activeTtsEnginePkg = null;
            List<Runnable> errorList = new ArrayList<>(pendingTtsErrors);
            pendingTtsActions.clear();
            pendingTtsErrors.clear();
            for (Runnable err : errorList) {
                err.run();
            }
            return;
        }

        final String enginePkg = engines.get(index);
        final TextToSpeech[] holder = new TextToSpeech[1];
        TextToSpeech.OnInitListener listener = (status) -> mainHandler.post(() -> {
            TextToSpeech instance = holder[0];
            if (status == TextToSpeech.SUCCESS && instance != null) {
                int avail = TextToSpeech.LANG_AVAILABLE;
                try {
                    avail = instance.isLanguageAvailable(targetLocale);
                } catch (Exception ignored) {
                }
                if ((avail == TextToSpeech.LANG_MISSING_DATA || avail == TextToSpeech.LANG_NOT_SUPPORTED)
                    && index + 1 < engines.size()) {
                    try {
                        instance.shutdown();
                    } catch (Exception ignored) {
                    }
                    if (textToSpeech == instance) {
                        textToSpeech = null;
                    }
                    tryInitTtsEngine(engines, index + 1, targetLocale);
                    return;
                }

                textToSpeech = instance;
                ttsInitializing = false;
                ttsReady = true;
                activeTtsEnginePkg = enginePkg != null ? enginePkg : instance.getDefaultEngine();
                try {
                    instance.setAudioAttributes(
                        new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    );
                } catch (Exception ignored) {
                }
                instance.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                    @Override
                    public void onStart(String id) {
                        emitTtsState(id, "playing", false);
                    }

                    @Override
                    public void onDone(String id) {
                        emitTtsState(id, "done", true);
                    }

                    @Override
                    public void onError(String id) {
                        emitTtsState(id, "error", false);
                    }

                    @Override
                    public void onError(String id, int errorCode) {
                        emitTtsState(id, "error", false);
                    }

                    @Override
                    public void onStop(String id, boolean interrupted) {
                        emitTtsState(id, "done", false);
                    }
                });

                List<Runnable> readyList = new ArrayList<>(pendingTtsActions);
                pendingTtsActions.clear();
                pendingTtsErrors.clear();
                for (Runnable action : readyList) {
                    action.run();
                }
            } else {
                if (instance != null) {
                    try {
                        instance.shutdown();
                    } catch (Exception ignored) {
                    }
                }
                if (textToSpeech == instance) {
                    textToSpeech = null;
                }
                tryInitTtsEngine(engines, index + 1, targetLocale);
            }
        });

        try {
            Context appCtx = getContext().getApplicationContext();
            holder[0] = enginePkg != null
                ? new TextToSpeech(appCtx, listener, enginePkg)
                : new TextToSpeech(appCtx, listener);
            textToSpeech = holder[0];
        } catch (Exception e) {
            tryInitTtsEngine(engines, index + 1, targetLocale);
        }
    }

    @SuppressWarnings("deprecation")
    private void requestTtsAudioFocus() {
        try {
            if (audioManager == null) {
                audioManager = (AudioManager) getContext().getApplicationContext()
                    .getSystemService(Context.AUDIO_SERVICE);
            }
            if (audioManager == null) {
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (audioFocusRequest == null) {
                    AudioAttributes attrs = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build();
                    audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                        .setAudioAttributes(attrs)
                        .setOnAudioFocusChangeListener(audioFocusListener)
                        .build();
                }
                audioManager.requestAudioFocus(audioFocusRequest);
            } else {
                audioManager.requestAudioFocus(
                    audioFocusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                );
            }
        } catch (Exception ignored) {
        }
    }

    @SuppressWarnings("deprecation")
    private void abandonTtsAudioFocus() {
        try {
            if (audioManager == null) {
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (audioFocusRequest != null) {
                    audioManager.abandonAudioFocusRequest(audioFocusRequest);
                }
            } else {
                audioManager.abandonAudioFocus(audioFocusListener);
            }
        } catch (Exception ignored) {
        }
    }

    private FlymeLyricsMediaHelper getLyricsMediaHelper() {
        if (lyricsMediaHelper == null) {
            lyricsMediaHelper = new FlymeLyricsMediaHelper(
                getContext(),
                mainHandler,
                this::handleMediaStopControl
            );
        }
        return lyricsMediaHelper;
    }

    private void handleMediaStopControl() {
        activeUtteranceId = null;
        utteranceChunkTexts.clear();
        pendingTtsActions.clear();
        pendingTtsErrors.clear();
        abandonTtsAudioFocus();
        if (lyricsMediaHelper != null) {
            lyricsMediaHelper.stop();
        }
        if (textToSpeech != null) {
            try {
                textToSpeech.stop();
            } catch (Exception ignored) {
            }
        }
        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:media-stop'));");
    }

    private void emitTtsState(final String id, final String state, final boolean requireExactId) {
        mainHandler.post(() -> {
            if (activeUtteranceId == null || id == null) {
                return;
            }
            boolean exact = id.equals(activeUtteranceId);
            boolean prefix = id.startsWith(activeUtteranceId + ":");
            if (requireExactId ? !exact : !(exact || prefix)) {
                return;
            }
            final String rootId = activeUtteranceId;
            if ("playing".equals(state)) {
                String lyricLine = utteranceChunkTexts.get(id);
                if (lyricLine != null && !lyricLine.isEmpty()) {
                    getLyricsMediaHelper().startOrUpdate(null, lyricLine);
                }
            } else {
                activeUtteranceId = null;
                utteranceChunkTexts.clear();
                abandonTtsAudioFocus();
                if (lyricsMediaHelper != null) {
                    lyricsMediaHelper.stop();
                }
            }
            emitWebEvent(
                "window.dispatchEvent(new CustomEvent('dsapp:tts-state',{detail:{id:'"
                    + rootId
                    + "',state:'"
                    + state
                    + "'}}));"
            );
        });
    }

    private List<String> splitIntoLyricSentences(String text, int hardMaxLen) {
        List<String> rawSentences = new ArrayList<>();
        int start = 0;
        int len = text.length();
        for (int i = 0; i < len; i++) {
            char c = text.charAt(i);
            boolean strongBreak = c == '。' || c == '！' || c == '？' || c == '；' || c == '\n';
            boolean asciiBreak = (c == '.' || c == '!' || c == '?' || c == ';')
                && (i + 1 >= len || Character.isWhitespace(text.charAt(i + 1)));
            if (strongBreak || asciiBreak) {
                appendClausePieces(rawSentences, text.substring(start, i + 1).trim(), hardMaxLen);
                start = i + 1;
            }
        }
        if (start < len) {
            appendClausePieces(rawSentences, text.substring(start).trim(), hardMaxLen);
        }

        List<String> merged = new ArrayList<>();
        for (String piece : rawSentences) {
            if (piece.isEmpty()) {
                continue;
            }
            if (!merged.isEmpty()) {
                int lastIdx = merged.size() - 1;
                String prev = merged.get(lastIdx);
                if ((prev.length() < 8 || piece.length() < 8) && prev.length() + piece.length() + 1 <= 56) {
                    merged.set(lastIdx, joinFragment(prev, piece));
                    continue;
                }
            }
            merged.add(piece);
        }
        return merged;
    }

    private void appendClausePieces(List<String> out, String sentence, int hardMaxLen) {
        if (sentence.isEmpty()) {
            return;
        }
        int clauseLimit = Math.min(52, hardMaxLen);
        if (sentence.length() <= clauseLimit) {
            out.add(sentence);
            return;
        }
        int start = 0;
        int len = sentence.length();
        for (int i = 0; i < len; i++) {
            char c = sentence.charAt(i);
            boolean clauseBreak = c == '，' || c == '、' || c == '：'
                || ((c == ',' || c == ':') && (i + 1 >= len || Character.isWhitespace(sentence.charAt(i + 1))));
            if (clauseBreak && (i + 1 - start) >= 16) {
                addBoundedChunks(out, sentence.substring(start, i + 1).trim(), hardMaxLen);
                start = i + 1;
            }
        }
        if (start < len) {
            addBoundedChunks(out, sentence.substring(start).trim(), hardMaxLen);
        }
    }

    private void addBoundedChunks(List<String> out, String text, int hardMaxLen) {
        if (text.isEmpty()) {
            return;
        }
        int maxLen = Math.min(52, hardMaxLen);
        if (text.length() <= maxLen) {
            out.add(text);
            return;
        }
        int start = 0;
        int total = text.length();
        while (start < total) {
            int end = Math.min(total, start + maxLen);
            if (end < total) {
                int minBreak = start + maxLen / 2;
                int breakAt = -1;
                for (int i = end - 1; i >= minBreak; i--) {
                    if (Character.isWhitespace(text.charAt(i))) {
                        breakAt = i + 1;
                        break;
                    }
                }
                if (breakAt > start) {
                    end = breakAt;
                }
            }
            String part = text.substring(start, end).trim();
            if (!part.isEmpty()) {
                out.add(part);
            }
            start = end;
        }
    }

    private static String joinFragment(String prev, String next) {
        char last = prev.charAt(prev.length() - 1);
        char first = next.charAt(0);
        boolean cjkOrPunct = last > 127 || first > 127;
        return cjkOrPunct ? (prev + next) : (prev + " " + next);
    }

    private void emitWebEvent(final String script) {
        if (getBridge() != null && getBridge().getWebView() != null) {
            mainHandler.post(() -> {
                if (getBridge() != null && getBridge().getWebView() != null) {
                    getBridge().getWebView().evaluateJavascript(script, null);
                }
            });
        }
    }
}
