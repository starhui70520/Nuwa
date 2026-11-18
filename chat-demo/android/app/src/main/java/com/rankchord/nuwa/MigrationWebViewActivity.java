package com.rankchord.nuwa;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.Gravity;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MigrationWebViewActivity extends Activity {
    private static final String TAG = "DSAPP_MIGRATION";
    public static final String PREFS_NAME = "dsapp_migration";
    public static final String KEY_PENDING_PATH = "pending_path";
    public static final String KEY_PENDING_NAME = "pending_name";
    public static final String EXTRA_FILE_PATH = "filePath";
    public static final String EXTRA_FILE_NAME = "fileName";
    private static final String TARGET_URL = "https://chat.deepseek.com/";

    private WebView webView;
    private TextView guideView;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private volatile boolean completed = false;
    private volatile boolean autoExportTriggered = false;

    private final Runnable loginPollTask = new Runnable() {
        @Override
        public void run() {
            if (completed || autoExportTriggered || webView == null) {
                return;
            }
            checkLoginState();
            mainHandler.postDelayed(this, 1200);
        }
    };

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setLayoutParams(new ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ));

        LinearLayout banner = new LinearLayout(this);
        banner.setOrientation(LinearLayout.HORIZONTAL);
        banner.setGravity(Gravity.CENTER_VERTICAL);
        banner.setBackgroundColor(Color.parseColor("#1D4ED8"));
        int padH = dp(12);
        int padV = dp(8);
        banner.setPadding(padH, padV, padH, padV);

        guideView = new TextView(this);
        guideView.setText("请先登录 DeepSeek 账号，登录成功后将自动辅助导出");
        guideView.setTextColor(Color.WHITE);
        guideView.setTextSize(12.5f);
        LinearLayout.LayoutParams guideParams = new LinearLayout.LayoutParams(
            0,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            1f
        );
        banner.addView(guideView, guideParams);

        Button autoBtn = new Button(this);
        autoBtn.setText("自动导出");
        autoBtn.setTextColor(Color.WHITE);
        autoBtn.setTextSize(12.5f);
        autoBtn.setBackgroundColor(Color.TRANSPARENT);
        autoBtn.setOnClickListener(v -> runAutoExportScript(true));
        banner.addView(autoBtn);

        Button closeBtn = new Button(this);
        closeBtn.setText("关闭");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(12.5f);
        closeBtn.setBackgroundColor(Color.TRANSPARENT);
        closeBtn.setOnClickListener(v -> {
            setResult(RESULT_CANCELED);
            finish();
        });
        banner.addView(closeBtn);

        root.addView(banner, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ));

        webView = new WebView(this);
        WebView.setWebContentsDebuggingEnabled(true);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);

        CookieManager cookieManager = CookieManager.getInstance();
        cookieManager.setAcceptCookie(true);
        cookieManager.setAcceptThirdPartyCookies(webView, true);

        webView.addJavascriptInterface(new MigrationJsBridge(), "AndroidMigrationBridge");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (!autoExportTriggered) {
                    checkLoginState();
                }
            }

            @Override
            public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
                super.doUpdateVisitedHistory(view, url, isReload);
                if (!autoExportTriggered) {
                    checkLoginState();
                }
            }
        });
        webView.setWebChromeClient(new WebChromeClient());
        webView.setDownloadListener(new ExportDownloadListener());

        root.addView(webView, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f
        ));

        setContentView(root);
        webView.loadUrl(TARGET_URL);
        mainHandler.postDelayed(loginPollTask, 1500);
    }

    private void checkLoginState() {
        if (webView == null || autoExportTriggered || completed) {
            return;
        }
        String js = "(function(){"
            + "if (location.hostname !== 'chat.deepseek.com') return;"
            + "var p = location.pathname || '';"
            + "if (p.indexOf('sign_in') >= 0 || p.indexOf('login') >= 0) return;"
            + "var hasInput = !!document.querySelector('textarea');"
            + "var hasPassInput = !!document.querySelector('input[type=\"password\"]');"
            + "if (hasInput && !hasPassInput) {"
            + "  window.AndroidMigrationBridge.onLoggedIn();"
            + "}"
            + "})();";
        webView.evaluateJavascript(js, null);
    }

    private void runAutoExportScript(boolean manualTrigger) {
        if (webView == null || completed) {
            return;
        }
        if (manualTrigger) {
            guideView.setText("正在尝试自动点击导出，请稍候...");
        }
        String resetJs = manualTrigger
            ? "if (window.__dsappAutoExportTimer) { clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportTimer = null; } window.__dsappAutoExportRunning = false;"
            : "";
        String js = "(function(){"
            + resetJs
            + "if (window.__dsappAutoExportRunning) return;"
            + "window.__dsappAutoExportRunning = true;"
            + "var triggerClick = function(el) {"
            + "  if (!el) return false;"
            + "  var target = (el.closest && el.closest('button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], [tabindex=\"0\"], a')) || el;"
            + "  if (!target || typeof target.click !== 'function') return false;"
            + "  try { target.scrollIntoView({ block: 'nearest', inline: 'center' }); } catch (e) {}"
            + "  target.click();"
            + "  return true;"
            + "};"
            + "var findVisibleByText = function(patterns, excludeDanger) {"
            + "  var nodes = Array.from(document.querySelectorAll('button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], [tabindex=\"0\"], a, li, div, span'));"
            + "  var best = null;"
            + "  var bestLen = 999;"
            + "  var bestArea = 999999999;"
            + "  for (var i = 0; i < nodes.length; i++) {"
            + "    var el = nodes[i];"
            + "    var rect = el.getBoundingClientRect();"
            + "    if (rect.width <= 0 || rect.height <= 0) continue;"
            + "    var text = (el.innerText || '').trim();"
            + "    if (!text || text.length > 32) continue;"
            + "    if (excludeDanger && /^(删除|Delete)$/i.test(text)) continue;"
            + "    for (var j = 0; j < patterns.length; j++) {"
            + "      if (patterns[j].test(text)) {"
            + "        var area = rect.width * rect.height;"
            + "        if (text.length < bestLen || (text.length === bestLen && area < bestArea)) {"
            + "          best = el;"
            + "          bestLen = text.length;"
            + "          bestArea = area;"
            + "        }"
            + "        break;"
            + "      }"
            + "    }"
            + "  }"
            + "  return best;"
            + "};"
            + "var clickHamburger = function() {"
            + "  var els = Array.from(document.querySelectorAll('[tabindex=\"0\"], button, [role=\"button\"], div'));"
            + "  var best = null;"
            + "  var bestArea = 999999;"
            + "  for (var i = 0; i < els.length; i++) {"
            + "    var el = els[i];"
            + "    var r = el.getBoundingClientRect();"
            + "    if (r.width >= 20 && r.width <= 72 && r.height >= 20 && r.height <= 72 && r.left >= 0 && r.left < 80 && r.top >= 0 && r.top < 110 && el.querySelector('svg')) {"
            + "      var area = r.width * r.height;"
            + "      if (area < bestArea) { best = el; bestArea = area; }"
            + "    }"
            + "  }"
            + "  return triggerClick(best);"
            + "};"
            + "var clickProfileBar = function() {"
            + "  var els = Array.from(document.querySelectorAll('[tabindex=\"0\"], button, [role=\"button\"]'));"
            + "  for (var i = 0; i < els.length; i++) {"
            + "    var el = els[i];"
            + "    if (el.tagName === 'A') continue;"
            + "    var r = el.getBoundingClientRect();"
            + "    if (r.width >= 120 && r.width <= 340 && r.height >= 32 && r.height <= 80 && r.left >= 0 && r.left < 80 && r.bottom > window.innerHeight - 90) {"
            + "      return triggerClick(el);"
            + "    }"
            + "  }"
            + "  return false;"
            + "};"
            + "var ticks = 0;"
            + "var exportClicked = false;"
            + "var lastSection = '';"
            + "var lastAction = '';"
            + "var lastActionTick = -10;"
            + "var timer = setInterval(function() {"
            + "  try {"
            + "    ticks++;"
            + "    var maxTicks = exportClicked ? 260 : 30;"
            + "    if (ticks > maxTicks) {"
            + "      clearInterval(timer);"
            + "      window.__dsappAutoExportTimer = null;"
            + "      window.__dsappAutoExportRunning = false;"
            + "      window.AndroidMigrationBridge.onAutoExportTimeout();"
            + "      return;"
            + "    }"
            + "    var confirmBtn = findVisibleByText([/^(确认导出|确认|确定|Confirm)$/i], true);"
            + "    if (confirmBtn && triggerClick(confirmBtn)) {"
            + "      window.AndroidMigrationBridge.onStep('Clicked Confirm');"
            + "      return;"
            + "    }"
            + "    if (lastSection === 'data' || findVisibleByText([/导出所有历史对话|Export all/i], true)) {"
            + "      var dlBtn = findVisibleByText([/^(下载|Download)$/i], true);"
            + "      if (dlBtn && triggerClick(dlBtn)) {"
            + "        window.AndroidMigrationBridge.onStep('Clicked Download');"
            + "        clearInterval(timer);"
            + "        window.__dsappAutoExportTimer = null;"
            + "        window.__dsappAutoExportRunning = false;"
            + "        return;"
            + "      }"
            + "      if (!exportClicked) {"
            + "        var expBtn = findVisibleByText([/^(导出数据|导出|Export Data|Export)$/i], true);"
            + "        if (expBtn && triggerClick(expBtn)) {"
            + "          exportClicked = true;"
            + "          window.AndroidMigrationBridge.onStep('Clicked Export');"
            + "          window.AndroidMigrationBridge.onWaitingExport();"
            + "          return;"
            + "        }"
            + "      }"
            + "      return;"
            + "    }"
            + "    if (findVisibleByText([/^(通用设置|账号管理|General|Account)$/i], true) || findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true)) {"
            + "      var dataTab = findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true);"
            + "      if (dataTab && triggerClick(dataTab)) {"
            + "        lastSection = 'data';"
            + "        window.AndroidMigrationBridge.onStep('Clicked Data tab');"
            + "        return;"
            + "      }"
            + "    }"
            + "    var settingsItem = findVisibleByText([/^(系统设置|Settings)$/i], true);"
            + "    if (settingsItem && triggerClick(settingsItem)) {"
            + "      window.AndroidMigrationBridge.onStep('Clicked System Settings');"
            + "      return;"
            + "    }"
            + "    if (findVisibleByText([/^(开启新对话|New chat)$/i], true)) {"
            + "      if (lastAction !== 'profile' || ticks - lastActionTick >= 3) {"
            + "        if (clickProfileBar()) {"
            + "          lastAction = 'profile';"
            + "          lastActionTick = ticks;"
            + "          window.AndroidMigrationBridge.onStep('Clicked Profile bar');"
            + "        }"
            + "      }"
            + "      return;"
            + "    }"
            + "    if (lastAction !== 'hamburger' || ticks - lastActionTick >= 3) {"
            + "      if (clickHamburger()) {"
            + "        lastAction = 'hamburger';"
            + "        lastActionTick = ticks;"
            + "        window.AndroidMigrationBridge.onStep('Clicked Hamburger');"
            + "      }"
            + "    }"
            + "  } catch (err) {"
            + "    window.AndroidMigrationBridge.onStep('ERR: ' + err);"
            + "  }"
            + "}, 700);"
            + "window.__dsappAutoExportTimer = timer;"
            + "})();";
        webView.evaluateJavascript(js, null);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private class ExportDownloadListener implements DownloadListener {
        @Override
        public void onDownloadStart(
            String url,
            String userAgent,
            String contentDisposition,
            String mimetype,
            long contentLength
        ) {
            String guessedName = URLUtil.guessFileName(url, contentDisposition, mimetype);
            final String fileName = guessedName != null && guessedName.toLowerCase().endsWith(".zip")
                ? guessedName
                : "deepseek_data.zip";

            runOnUiThread(() ->
                Toast.makeText(MigrationWebViewActivity.this, "正在接管导出文件，请稍候...", Toast.LENGTH_SHORT).show()
            );

            if (url != null && url.startsWith("blob:")) {
                String safeUrl = Uri.encode(url);
                String js = "(function(){"
                    + "fetch(decodeURIComponent('" + safeUrl + "'))"
                    + ".then(function(r){return r.blob();})"
                    + ".then(function(b){"
                    + "  var rd=new FileReader();"
                    + "  rd.onloadend=function(){"
                    + "    var s=rd.result||'';"
                    + "    var i=s.indexOf(',');"
                    + "    window.AndroidMigrationBridge.onBlobDownloaded(i>=0?s.slice(i+1):s," + org.json.JSONObject.quote(fileName) + ");"
                    + "  };"
                    + "  rd.readAsDataURL(b);"
                    + "})"
                    + ".catch(function(e){window.AndroidMigrationBridge.onBlobError(String(e));});"
                    + "})();";
                webView.evaluateJavascript(js, null);
                return;
            }

            executor.execute(() -> downloadHttpFile(url, userAgent, fileName));
        }
    }

    private void downloadHttpFile(String urlStr, String userAgent, String fileName) {
        HttpURLConnection conn = null;
        try {
            String currentUrl = urlStr;
            int redirects = 0;
            int code = 0;
            while (true) {
                URL url = new URL(currentUrl);
                conn = (HttpURLConnection) url.openConnection();
                conn.setInstanceFollowRedirects(false);
                conn.setConnectTimeout(15000);
                conn.setReadTimeout(30000);
                String host = url.getHost() != null ? url.getHost().toLowerCase() : "";
                if (host.endsWith("deepseek.com")) {
                    String cookies = CookieManager.getInstance().getCookie(currentUrl);
                    if (cookies != null && !cookies.isEmpty()) {
                        conn.setRequestProperty("Cookie", cookies);
                    }
                    conn.setRequestProperty("Referer", TARGET_URL);
                }
                if (userAgent != null && !userAgent.isEmpty()) {
                    conn.setRequestProperty("User-Agent", userAgent);
                }
                conn.connect();
                code = conn.getResponseCode();
                if (code == HttpURLConnection.HTTP_MOVED_TEMP
                    || code == HttpURLConnection.HTTP_MOVED_PERM
                    || code == HttpURLConnection.HTTP_SEE_OTHER
                    || code == 307
                    || code == 308) {
                    String location = conn.getHeaderField("Location");
                    conn.disconnect();
                    conn = null;
                    if (location == null || location.isEmpty() || redirects >= 5) {
                        throw new RuntimeException("HTTP " + code);
                    }
                    currentUrl = new URL(url, location).toString();
                    redirects++;
                    continue;
                }
                break;
            }

            if (code < 200 || code >= 300) {
                throw new RuntimeException("HTTP " + code);
            }

            File outFile = new File(getFilesDir(), "pending_migration.zip");
            try (InputStream in = conn.getInputStream();
                 FileOutputStream out = new FileOutputStream(outFile)) {
                byte[] buf = new byte[8192];
                int len;
                while ((len = in.read(buf)) != -1) {
                    out.write(buf, 0, len);
                }
            }

            Log.d(TAG, "Downloaded HTTP file: size=" + outFile.length() + ", type=" + conn.getContentType());
            if (!isZipMagic(outFile)) {
                Log.e(TAG, "Downloaded file is not a ZIP archive");
                //noinspection ResultOfMethodCallIgnored
                outFile.delete();
                runOnUiThread(() ->
                    Toast.makeText(this, "下载到的不是有效 ZIP 导出包，请重试", Toast.LENGTH_LONG).show()
                );
                return;
            }
            finishWithFile(outFile, fileName);
        } catch (Exception e) {
            Log.e(TAG, "downloadHttpFile failed: " + e.getMessage(), e);
            runOnUiThread(() ->
                Toast.makeText(this, "下载接管失败: " + e.getMessage(), Toast.LENGTH_LONG).show()
            );
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private static boolean isZipMagic(File file) {
        if (file == null || !file.exists() || file.length() < 4) {
            return false;
        }
        try (java.io.FileInputStream fis = new java.io.FileInputStream(file)) {
            byte[] header = new byte[4];
            if (fis.read(header) != 4) {
                return false;
            }
            return isZipMagic(header);
        } catch (Exception ignored) {
            return false;
        }
    }

    private static boolean isZipMagic(byte[] bytes) {
        return bytes != null
            && bytes.length >= 4
            && bytes[0] == 0x50
            && bytes[1] == 0x4B
            && bytes[2] == 0x03
            && bytes[3] == 0x04;
    }

    private class MigrationJsBridge {
        @JavascriptInterface
        public void onLoggedIn() {
            Log.d(TAG, "onLoggedIn triggered, autoExportTriggered=" + autoExportTriggered);
            if (autoExportTriggered || completed) {
                return;
            }
            autoExportTriggered = true;
            mainHandler.post(() -> {
                guideView.setText("已检测到登录，正在自动打开设置并导出...");
                runAutoExportScript(false);
            });
        }

        @JavascriptInterface
        public void onStep(String msg) {
            Log.d(TAG, "AutoExport step: " + msg);
        }

        @JavascriptInterface
        public void onWaitingExport() {
            Log.d(TAG, "Waiting for DeepSeek server export to complete...");
            mainHandler.post(() ->
                guideView.setText("已触发官方导出，正在等待生成导出包（约需 1-3 分钟，生成后将自动下载）...")
            );
        }

        @JavascriptInterface
        public void onAutoExportTimeout() {
            Log.w(TAG, "AutoExport timed out");
            if (completed) {
                return;
            }
            mainHandler.post(() ->
                guideView.setText("未定位到按钮，请手动点「设置 → 数据管理 → 导出/下载」")
            );
        }

        @JavascriptInterface
        public void onBlobDownloaded(String base64Data, String fileName) {
            try {
                byte[] bytes = Base64.decode(base64Data, Base64.DEFAULT);
                Log.d(TAG, "onBlobDownloaded: bytes=" + bytes.length);
                if (!isZipMagic(bytes)) {
                    Log.e(TAG, "Blob is not a ZIP archive");
                    runOnUiThread(() ->
                        Toast.makeText(MigrationWebViewActivity.this, "导出的不是有效 ZIP 文件，请重试", Toast.LENGTH_LONG).show()
                    );
                    return;
                }
                File outFile = new File(getFilesDir(), "pending_migration.zip");
                try (FileOutputStream out = new FileOutputStream(outFile)) {
                    out.write(bytes);
                }
                finishWithFile(outFile, fileName);
            } catch (Exception e) {
                Log.e(TAG, "onBlobDownloaded failed", e);
                runOnUiThread(() ->
                    Toast.makeText(MigrationWebViewActivity.this, "解析导出包失败", Toast.LENGTH_LONG).show()
                );
            }
        }

        @JavascriptInterface
        public void onBlobError(String error) {
            runOnUiThread(() ->
                Toast.makeText(MigrationWebViewActivity.this, "导出失败: " + error, Toast.LENGTH_LONG).show()
            );
        }
    }

    private synchronized void finishWithFile(File file, String fileName) {
        if (completed) {
            return;
        }
        completed = true;
        // 持久化待导入标记，避免系统回收或重启 MainActivity 时丢失回调
        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        prefs.edit()
            .putString(KEY_PENDING_PATH, file.getAbsolutePath())
            .putString(KEY_PENDING_NAME, fileName)
            .apply();

        Intent result = new Intent();
        result.putExtra(EXTRA_FILE_PATH, file.getAbsolutePath());
        result.putExtra(EXTRA_FILE_NAME, fileName);
        setResult(RESULT_OK, result);
        runOnUiThread(this::finish);
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
            return;
        }
        setResult(RESULT_CANCELED);
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        mainHandler.removeCallbacks(loginPollTask);
        executor.shutdownNow();
        if (webView != null) {
            if (webView.getParent() instanceof ViewGroup) {
                ((ViewGroup) webView.getParent()).removeView(webView);
            }
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
