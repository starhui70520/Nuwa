package com.dsapp.chat;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

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
    private volatile boolean updateDownloading = false;
    @PluginMethod
    public void openExportBrowser(PluginCall call) {
        Intent intent = new Intent(getContext(), MigrationWebViewActivity.class);
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
            if (!SpeechRecognizer.isRecognitionAvailable(getContext())) {
                call.reject("UNAVAILABLE");
                return;
            }
            destroySpeechRecognizerInternal();
            speechCommitted.setLength(0);
            speechPartial = "";
            speechLocale = locale != null && !locale.isEmpty() ? locale : "zh-CN";
            speechActive = true;
            pendingStopCall = null;

            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(getContext());
            speechRecognizer.setRecognitionListener(new RecognitionListener() {
                @Override
                public void onReadyForSpeech(Bundle params) {
                }

                @Override
                public void onBeginningOfSpeech() {
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
                    if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                        speechActive = false;
                        destroySpeechRecognizerInternal();
                        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'PERMISSION_DENIED'}))");
                        return;
                    }
                    if (error == SpeechRecognizer.ERROR_NO_MATCH
                        || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
                        || error == SpeechRecognizer.ERROR_CLIENT) {
                        mainHandler.postDelayed(() -> {
                            if (speechActive && speechRecognizer != null) {
                                try {
                                    speechRecognizer.startListening(buildRecognizerIntent(speechLocale));
                                } catch (Exception ignored) {
                                }
                            }
                        }, 120L);
                        return;
                    }
                    if (getCombinedSpeechText().isEmpty()) {
                        speechActive = false;
                        destroySpeechRecognizerInternal();
                        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'FAILED'}))");
                    } else {
                        mainHandler.postDelayed(() -> {
                            if (speechActive && speechRecognizer != null) {
                                try {
                                    speechRecognizer.startListening(buildRecognizerIntent(speechLocale));
                                } catch (Exception ignored) {
                                }
                            }
                        }, 150L);
                    }
                }

                @Override
                public void onResults(Bundle results) {
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
                        mainHandler.postDelayed(() -> {
                            if (speechActive && speechRecognizer != null) {
                                try {
                                    speechRecognizer.startListening(buildRecognizerIntent(speechLocale));
                                } catch (Exception ignored) {
                                }
                            }
                        }, 60L);
                    }
                }

                @Override
                public void onPartialResults(Bundle partialResults) {
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
                speechRecognizer.startListening(buildRecognizerIntent(speechLocale));
                call.resolve();
            } catch (Exception e) {
                speechActive = false;
                destroySpeechRecognizerInternal();
                call.reject("START_FAILED", e);
            }
        });
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
        });
        super.handleOnDestroy();
    }

    private Intent buildRecognizerIntent(String locale) {
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        String resolved = locale != null && !locale.isEmpty() ? locale : "zh-CN";
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, resolved);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, resolved);
        intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        return intent;
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
