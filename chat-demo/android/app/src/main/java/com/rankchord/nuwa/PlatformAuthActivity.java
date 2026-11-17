package com.rankchord.nuwa;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.Gravity;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Locale;
import java.util.TimeZone;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class PlatformAuthActivity extends Activity {
    private static final String TAG = "DSAPP_PLATFORM_AUTH";
    private static final String CLIENT_VERSION = "0.2.2";
    public static final String AUTH_PREFS = "dsapp_platform_auth";
    public static final String KEY_DEVICE_ID = "device_id";
    public static final String KEY_PENDING_TOKEN = "pending_token";
    public static final String KEY_PENDING_LABEL = "pending_label";
    private static final String PLATFORM_ORIGIN = "https://platform.deepseek.com";

    private WebView webView;
    private TextView statusView;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private volatile boolean completed = false;
    private volatile boolean exchanging = false;

    private String verifier;
    private String state;
    private String redirectUri;
    private String authorizeId;

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
        banner.setBackgroundColor(Color.parseColor("#18181B"));
        int padH = dp(14);
        int padV = dp(10);
        banner.setPadding(padH, padV, padH, padV);

        statusView = new TextView(this);
        statusView.setText("正在连接 DeepSeek 开放平台...");
        statusView.setTextColor(Color.WHITE);
        statusView.setTextSize(13f);
        banner.addView(statusView, new LinearLayout.LayoutParams(
            0,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            1f
        ));

        Button closeBtn = new Button(this);
        closeBtn.setText("关闭");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(13f);
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
        // 去掉 WebView "; wv" 标记，避免 Google OAuth 等第三方登录被拦截
        String ua = settings.getUserAgentString();
        if (ua != null) {
            settings.setUserAgentString(ua.replace("; wv)", ")").replace("; wv", ""));
        }

        CookieManager cookieManager = CookieManager.getInstance();
        cookieManager.setAcceptCookie(true);
        cookieManager.setAcceptThirdPartyCookies(webView, true);

        webView.setWebChromeClient(new WebChromeClient());
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return handleIntercept(request.getUrl().toString());
            }

            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return handleIntercept(url);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                CookieManager.getInstance().flush();
            }
        });

        root.addView(webView, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f
        ));

        setContentView(root);
        startPkceInit();
    }

    public static String platformWireLocale() {
        String lang = Locale.getDefault().getLanguage();
        return lang != null && lang.toLowerCase(Locale.ROOT).startsWith("zh") ? "zh_CN" : "en_US";
    }

    public static void applyPlatformClientHeaders(HttpURLConnection conn) {
        int offsetSeconds = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000;
        conn.setRequestProperty("x-client-bundle-id", "");
        conn.setRequestProperty("x-client-platform", "web");
        conn.setRequestProperty("x-client-version", CLIENT_VERSION);
        conn.setRequestProperty("x-client-locale", platformWireLocale());
        conn.setRequestProperty("x-client-timezone-offset", String.valueOf(offsetSeconds));
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String randomBase64Url(int byteCount) {
        byte[] bytes = new byte[byteCount];
        new SecureRandom().nextBytes(bytes);
        return Base64.encodeToString(bytes, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private String sha256Base64Url(String input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(input.getBytes(StandardCharsets.US_ASCII));
        return Base64.encodeToString(hash, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private String getOrCreateDeviceId() {
        SharedPreferences prefs = getSharedPreferences(AUTH_PREFS, MODE_PRIVATE);
        String id = prefs.getString(KEY_DEVICE_ID, null);
        if (id == null || id.isEmpty()) {
            id = UUID.randomUUID().toString();
            prefs.edit().putString(KEY_DEVICE_ID, id).apply();
        }
        return id;
    }

    private void startPkceInit() {
        executor.execute(() -> {
            try {
                verifier = randomBase64Url(32);
                state = randomBase64Url(32);
                String challenge = sha256Base64Url(verifier);
                int port = 30000 + new SecureRandom().nextInt(25000);
                redirectUri = "http://127.0.0.1:" + port + "/oauth/callback";

                JSONObject reqBody = new JSONObject();
                reqBody.put("code_challenge", challenge);
                reqBody.put("code_challenge_method", "S256");
                reqBody.put("state", state);
                reqBody.put("redirect_uri", redirectUri);
                reqBody.put("locale", platformWireLocale());
                reqBody.put("login_source", "web");

                JSONObject bizData = postPlatform("auth_init", reqBody);
                String authUrl = bizData.getString("authorize_url");
                authorizeId = bizData.getString("authorize_id");

                if (!authUrl.startsWith(PLATFORM_ORIGIN + "/dsh/authorize")) {
                    throw new IllegalStateException("Unexpected authorize_url");
                }

                runOnUiThread(() -> {
                    statusView.setText("请登录并授权 Nuwa 使用你的 DeepSeek API 账号");
                    if (webView != null) {
                        webView.loadUrl(authUrl);
                    }
                });
            } catch (Exception e) {
                Log.e(TAG, "auth_init failed", e);
                runOnUiThread(() -> {
                    statusView.setText("连接开放平台失败，请检查网络后重试");
                    Toast.makeText(this, "登录初始化失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private boolean handleIntercept(String url) {
        if (url == null || redirectUri == null) {
            return false;
        }
        if (!url.startsWith(redirectUri)) {
            return false;
        }
        if (exchanging || completed) {
            return true;
        }

        Uri uri = Uri.parse(url);
        String receivedState = uri.getQueryParameter("state");
        String code = uri.getQueryParameter("code");
        if (receivedState == null || !receivedState.equals(state) || code == null || code.isEmpty()) {
            runOnUiThread(() ->
                Toast.makeText(this, "授权回调校验失败，请重试", Toast.LENGTH_LONG).show()
            );
            return true;
        }

        exchanging = true;
        runOnUiThread(() -> statusView.setText("授权成功，正在获取账号令牌..."));
        exchangeCode(code);
        return true;
    }

    private void exchangeCode(String code) {
        executor.execute(() -> {
            try {
                JSONObject reqBody = new JSONObject();
                reqBody.put("code", code);
                reqBody.put("code_verifier", verifier);
                reqBody.put("redirect_uri", redirectUri);
                reqBody.put("device_id", getOrCreateDeviceId());
                reqBody.put("device_model", Build.MANUFACTURER + "-" + Build.MODEL);
                reqBody.put("os_version", "Android " + Build.VERSION.RELEASE);

                JSONObject bizData = postPlatform("auth_exchange", reqBody);
                String token = bizData.getString("token");
                String label = extractLabel(bizData.optJSONObject("user"));

                SharedPreferences prefs = getSharedPreferences(AUTH_PREFS, MODE_PRIVATE);
                prefs.edit()
                    .putString(KEY_PENDING_TOKEN, token)
                    .putString(KEY_PENDING_LABEL, label)
                    .commit();

                CookieManager.getInstance().flush();
                completed = true;
                setResult(RESULT_OK, new Intent());
                runOnUiThread(this::finish);
            } catch (Exception e) {
                exchanging = false;
                Log.e(TAG, "auth_exchange failed", e);
                runOnUiThread(() -> {
                    statusView.setText("换取账号令牌失败，正在刷新授权页面...");
                    Toast.makeText(this, "登录失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
                });
                startPkceInit();
            }
        });
    }

    private String extractLabel(JSONObject user) {
        if (user == null) {
            return "DeepSeek API 账号";
        }
        JSONObject idProfile = user.optJSONObject("id_profile");
        if (idProfile != null) {
            String name = idProfile.optString("name", "").trim();
            if (!name.isEmpty()) {
                return name;
            }
        }
        for (String key : new String[] { "mobile", "mobile_number", "email" }) {
            String val = user.optString(key, "").trim();
            if (!val.isEmpty()) {
                return val;
            }
        }
        return "DeepSeek API 账号";
    }

    private JSONObject postPlatform(String method, JSONObject body) throws Exception {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(PLATFORM_ORIGIN + "/auth-api/v0/dsh/" + method);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            applyPlatformClientHeaders(conn);
            conn.setRequestProperty("Content-Type", "application/json");

            byte[] outBytes = body.toString().getBytes(StandardCharsets.UTF_8);
            try (OutputStream out = conn.getOutputStream()) {
                out.write(outBytes);
            }

            int status = conn.getResponseCode();
            InputStream stream = status >= 200 && status < 300 ? conn.getInputStream() : conn.getErrorStream();
            String raw = readAll(stream);
            if (status < 200 || status >= 300) {
                Log.e(TAG, "Platform " + method + " HTTP " + status + ": " + raw);
                throw new RuntimeException("HTTP " + status);
            }
            JSONObject envelope = new JSONObject(raw);
            if (envelope.optInt("code", -1) != 0) {
                throw new RuntimeException("code=" + envelope.optInt("code"));
            }
            JSONObject data = envelope.getJSONObject("data");
            if (data.optInt("biz_code", -1) != 0) {
                String bizMsg = data.optString("biz_msg", "");
                throw new RuntimeException(
                    "biz_code=" + data.optInt("biz_code") + (bizMsg.isEmpty() ? "" : " (" + bizMsg + ")")
                );
            }
            return data.getJSONObject("biz_data");
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private String readAll(InputStream in) throws Exception {
        if (in == null) {
            return "";
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int len;
        while ((len = in.read(buf)) != -1) {
            out.write(buf, 0, len);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
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
        if (!completed && authorizeId != null && verifier != null) {
            final String cancelId = authorizeId;
            final String cancelVerifier = verifier;
            executor.execute(() -> {
                try {
                    JSONObject body = new JSONObject();
                    body.put("authorize_id", cancelId);
                    body.put("code_verifier", cancelVerifier);
                    postPlatform("auth_cancel", body);
                } catch (Exception ignored) {
                }
            });
        }
        executor.shutdown();
        if (webView != null) {
            webView.destroy();
        }
        super.onDestroy();
    }
}
