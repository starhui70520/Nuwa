package com.rankchord.nuwa;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.ActivityManager;
import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.Display;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.MimeTypeMap;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import androidx.activity.OnBackPressedCallback;
import androidx.core.content.ContextCompat;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.BridgeWebChromeClient;
import com.getcapacitor.WebViewListener;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class MainActivity extends BridgeActivity {
    private static final Pattern CHROME_MAJOR_PATTERN = Pattern.compile("Chrome/(\\d+)");
    private static long lastRecreateMs = 0L;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(DeepSeekMigrationPlugin.class);
        super.onCreate(savedInstanceState);

        enableHighRefreshRate();
        setupEdgeToEdgeAndInsets();
        configureWebView();
        setupBackNavigation();
        InAppBrowserHelper.getInstance().init(getApplicationContext());
    }

    private void setupBackNavigation() {
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (getBridge() == null || getBridge().getWebView() == null) {
                    moveTaskToBack(true);
                    return;
                }
                WebView webView = getBridge().getWebView();
                webView.evaluateJavascript(
                    "(function(){try{return !!(window.__NUWA_HANDLE_BACK__&&window.__NUWA_HANDLE_BACK__());}catch(e){return false;}})()",
                    value -> {
                        if (!"true".equals(value)) {
                            moveTaskToBack(true);
                        }
                    }
                );
            }
        });
    }

    @Override
    public void onResume() {
        super.onResume();
        if (getBridge() != null && getBridge().getWebView() != null) {
            getBridge().getWebView().evaluateJavascript(
                "window.dispatchEvent(new Event('dsapp:native-resume'))",
                null
            );
        }
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if ((level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
            || level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND)
            && getBridge() != null
            && getBridge().getWebView() != null) {
            runOnUiThread(() -> {
                if (getBridge() != null && getBridge().getWebView() != null) {
                    getBridge().getWebView().clearCache(false);
                }
            });
        }
    }

    public void applySystemBarsStyle(boolean dark) {
        Window window = getWindow();
        if (window == null) {
            return;
        }
        int bg = dark ? Color.parseColor("#151517") : Color.WHITE;
        View decor = window.getDecorView();
        decor.setBackgroundColor(bg);
        View content = findViewById(android.R.id.content);
        if (content != null) {
            content.setBackgroundColor(bg);
        }
        WindowInsetsControllerCompat controller = WindowCompat.getInsetsController(window, decor);
        if (controller != null) {
            controller.setAppearanceLightStatusBars(!dark);
            controller.setAppearanceLightNavigationBars(!dark);
        }
    }

    private void enableHighRefreshRate() {
        Window window = getWindow();
        if (window == null) {
            return;
        }
        Display display = getActiveDisplay();
        if (display == null) {
            return;
        }
        Display.Mode currentMode = display.getMode();
        Display.Mode[] modes = display.getSupportedModes();
        if (currentMode == null || modes == null || modes.length == 0) {
            return;
        }
        Display.Mode bestMode = currentMode;
        for (Display.Mode mode : modes) {
            if (mode.getPhysicalWidth() == currentMode.getPhysicalWidth()
                && mode.getPhysicalHeight() == currentMode.getPhysicalHeight()
                && mode.getRefreshRate() > bestMode.getRefreshRate()) {
                bestMode = mode;
            }
        }
        if (bestMode.getModeId() != currentMode.getModeId()
            || bestMode.getRefreshRate() > currentMode.getRefreshRate()) {
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.preferredDisplayModeId = bestMode.getModeId();
            lp.preferredRefreshRate = bestMode.getRefreshRate();
            window.setAttributes(lp);
        }
    }

    @SuppressWarnings("deprecation")
    private Display getActiveDisplay() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Display d = getDisplay();
            if (d != null) {
                return d;
            }
        }
        WindowManager wm = getWindowManager();
        return wm != null ? wm.getDefaultDisplay() : null;
    }

    @SuppressWarnings("deprecation")
    private void setupEdgeToEdgeAndInsets() {
        Window window = getWindow();
        if (window == null) {
            return;
        }
        WindowCompat.setDecorFitsSystemWindows(window, false);
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.TRANSPARENT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.setNavigationBarContrastEnforced(false);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            window.setAttributes(lp);
        }

        boolean night = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
            == Configuration.UI_MODE_NIGHT_YES;
        applySystemBarsStyle(night);

        View content = findViewById(android.R.id.content);
        if (content != null) {
            ViewCompat.setOnApplyWindowInsetsListener(content, (view, windowInsets) ->
                new WindowInsetsCompat.Builder(windowInsets)
                    .setInsets(WindowInsetsCompat.Type.ime(), Insets.NONE)
                    .setVisible(WindowInsetsCompat.Type.ime(), false)
                    .build()
            );
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void configureWebView() {
        if (getBridge() == null || getBridge().getWebView() == null) {
            return;
        }
        WebView webView = getBridge().getWebView();
        WebView.setWebContentsDebuggingEnabled(true);
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);

        WebSettings settings = webView.getSettings();
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setTextZoom(100);
        settings.setOffscreenPreRaster(true);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            settings.setAlgorithmicDarkeningAllowed(false);
        }

        webView.setWebChromeClient(new BridgeWebChromeClient(getBridge()) {
            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                boolean wantsAudio = false;
                boolean wantsVideo = false;
                for (String res : request.getResources()) {
                    if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(res)) {
                        wantsAudio = true;
                    } else if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res)) {
                        wantsVideo = true;
                    }
                }
                if (wantsAudio && !wantsVideo
                    && ContextCompat.checkSelfPermission(MainActivity.this, Manifest.permission.RECORD_AUDIO)
                        == PackageManager.PERMISSION_GRANTED) {
                    request.grant(request.getResources());
                    return;
                }
                super.onPermissionRequest(request);
            }

            @Override
            public boolean onShowFileChooser(
                WebView view,
                ValueCallback<Uri[]> filePathCallback,
                FileChooserParams fileChooserParams
            ) {
                FileChooserParams safeParams = sanitizeFileChooserParams(fileChooserParams);
                try {
                    return super.onShowFileChooser(view, filePathCallback, safeParams);
                } catch (Exception e) {
                    try {
                        filePathCallback.onReceiveValue(null);
                    } catch (Exception ignored) {
                    }
                    return true;
                }
            }
        });

        getBridge().addWebViewListener(new WebViewListener() {
            @Override
            public void onPageLoaded(WebView view) {
                if (view == null) {
                    return;
                }
                int major = getCurrentWebViewMajorVersion(view);
                boolean lowRam = isLowRamDevice();
                if ((major > 0 && major < 115) || lowRam) {
                    view.evaluateJavascript(
                        "document.body && document.body.setAttribute('data-low-webview','true');",
                        null
                    );
                }
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                long now = SystemClock.elapsedRealtime();
                if (now - lastRecreateMs > 3000L) {
                    lastRecreateMs = now;
                    runOnUiThread(MainActivity.this::recreate);
                }
                return true;
            }
        });
    }

    private int getCurrentWebViewMajorVersion(WebView view) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PackageInfo pkg = WebView.getCurrentWebViewPackage();
                if (pkg != null && pkg.versionName != null) {
                    int dot = pkg.versionName.indexOf('.');
                    String majorStr = dot > 0 ? pkg.versionName.substring(0, dot) : pkg.versionName;
                    return Integer.parseInt(majorStr.trim());
                }
            }
        } catch (Exception ignored) {
        }
        try {
            String ua = view.getSettings().getUserAgentString();
            if (ua != null) {
                Matcher matcher = CHROME_MAJOR_PATTERN.matcher(ua);
                if (matcher.find()) {
                    String group = matcher.group(1);
                    if (group != null) {
                        return Integer.parseInt(group);
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return 0;
    }

    private boolean isLowRamDevice() {
        try {
            ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            return am != null && am.isLowRamDevice();
        } catch (Exception ignored) {
            return false;
        }
    }

    /**
     * 兼容老版本 Android/WebView：Capacitor BridgeWebChromeClient 在 acceptTypes 包含无法映射的
     * 扩展名（如 .md/.ts）时会触发 validTypes[0] 越界闪退。这里统一清洗为安全 MIME 或降级为 * / *。
     */
    private WebChromeClient.FileChooserParams sanitizeFileChooserParams(
        final WebChromeClient.FileChooserParams orig
    ) {
        if (orig == null) {
            return null;
        }
        String[] rawTypes = orig.getAcceptTypes();
        List<String> valid = new ArrayList<>();
        MimeTypeMap mtm = MimeTypeMap.getSingleton();
        if (rawTypes != null) {
            for (String raw : rawTypes) {
                if (raw == null) {
                    continue;
                }
                for (String token : raw.split(",")) {
                    String t = token.trim();
                    if (t.isEmpty()) {
                        continue;
                    }
                    if (t.startsWith(".")) {
                        String ext = t.substring(1).toLowerCase();
                        String mapped = mtm.getMimeTypeFromExtension(ext);
                        if (mapped != null && !valid.contains(mapped)) {
                            valid.add(mapped);
                        }
                    } else if (t.contains("/") && !valid.contains(t)) {
                        valid.add(t);
                    }
                }
            }
        }
        final String[] safeTypes = valid.isEmpty()
            ? new String[]{"*/*"}
            : valid.toArray(new String[0]);

        return new WebChromeClient.FileChooserParams() {
            @Override
            public int getMode() {
                return orig.getMode();
            }

            @Override
            public String[] getAcceptTypes() {
                return safeTypes;
            }

            @Override
            public boolean isCaptureEnabled() {
                return orig.isCaptureEnabled();
            }

            @Override
            public CharSequence getTitle() {
                return orig.getTitle();
            }

            @Override
            public String getFilenameHint() {
                return orig.getFilenameHint();
            }

            @Override
            public Intent createIntent() {
                Intent intent = orig.createIntent();
                if (intent == null) {
                    intent = new Intent(Intent.ACTION_GET_CONTENT);
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                }
                String type = intent.getType();
                if (type == null || type.isEmpty() || type.startsWith(".")) {
                    intent.setType("*/*");
                }
                return intent;
            }
        };
    }
}
