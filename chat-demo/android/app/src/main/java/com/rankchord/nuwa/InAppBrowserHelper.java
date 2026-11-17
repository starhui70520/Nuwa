package com.rankchord.nuwa;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import androidx.annotation.NonNull;
import androidx.browser.customtabs.CustomTabColorSchemeParams;
import androidx.browser.customtabs.CustomTabsCallback;
import androidx.browser.customtabs.CustomTabsClient;
import androidx.browser.customtabs.CustomTabsIntent;
import androidx.browser.customtabs.CustomTabsService;
import androidx.browser.customtabs.CustomTabsServiceConnection;
import androidx.browser.customtabs.CustomTabsSession;

import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * In-app external link pre-warming and instant browser launcher.
 * Uses Xiaomi MiCT SDK via reflection when bundled & configured, and seamlessly
 * falls back to AndroidX Custom Tabs (Xiaomi Browser / OEM Browser / Chrome).
 */
final class InAppBrowserHelper {
    private static final InAppBrowserHelper INSTANCE = new InAppBrowserHelper();

    private final Set<String> prewarmedUrls = Collections.synchronizedSet(
        Collections.newSetFromMap(new LinkedHashMap<String, Boolean>(64, 0.75f, true) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, Boolean> eldest) {
                return size() > 64;
            }
        })
    );

    private volatile boolean initialized = false;
    private volatile boolean mictReady = false;
    private Object mictHelper = null;
    private String customTabsPkg = null;
    private CustomTabsClient customTabsClient = null;
    private CustomTabsSession customTabsSession = null;
    private boolean serviceBound = false;

    private final CustomTabsServiceConnection serviceConnection = new CustomTabsServiceConnection() {
        @Override
        public void onCustomTabsServiceConnected(@NonNull ComponentName name, @NonNull CustomTabsClient client) {
            customTabsClient = client;
            try {
                client.warmup(0L);
            } catch (Throwable ignored) {
            }
            try {
                customTabsSession = client.newSession(new CustomTabsCallback());
            } catch (Throwable ignored) {
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            customTabsClient = null;
            customTabsSession = null;
            serviceBound = false;
        }
    };

    private InAppBrowserHelper() {}

    static InAppBrowserHelper getInstance() {
        return INSTANCE;
    }

    synchronized void init(Context context) {
        if (initialized || context == null) {
            return;
        }
        initialized = true;
        Context appCtx = context.getApplicationContext();
        tryInitXiaomiMict(appCtx);
        bindStandardCustomTabs(appCtx);
    }

    String getMode() {
        if (mictHelper != null && mictReady) {
            return "mict";
        }
        if (customTabsPkg != null && !customTabsPkg.isEmpty()) {
            return "custom-tabs";
        }
        return "system";
    }

    String getProviderPackage() {
        if (mictHelper != null && mictReady) {
            return "com.android.browser";
        }
        return customTabsPkg != null ? customTabsPkg : "";
    }

    void prepareUrls(Context context, List<String> urls) {
        if (context == null || urls == null || urls.isEmpty()) {
            return;
        }
        if (!initialized) {
            init(context);
        }

        List<String> fresh = new ArrayList<>();
        for (String raw : urls) {
            if (!isHttpUrl(raw) || prewarmedUrls.contains(raw)) {
                continue;
            }
            prewarmedUrls.add(raw);
            fresh.add(raw);
            if (fresh.size() >= 4) {
                break;
            }
        }
        if (fresh.isEmpty()) {
            return;
        }

        if (mictHelper != null && mictReady) {
            try {
                Method prepare = mictHelper.getClass().getMethod("prepare", Context.class, String.class);
                for (String url : fresh) {
                    prepare.invoke(mictHelper, context.getApplicationContext(), url);
                }
            } catch (Throwable ignored) {
            }
        }

        if (customTabsSession != null) {
            try {
                Uri primary = Uri.parse(fresh.get(0));
                List<Bundle> likely = null;
                if (fresh.size() > 1) {
                    likely = new ArrayList<>(fresh.size() - 1);
                    for (int i = 1; i < fresh.size(); i++) {
                        Bundle bundle = new Bundle();
                        bundle.putParcelable(CustomTabsService.KEY_URL, Uri.parse(fresh.get(i)));
                        likely.add(bundle);
                    }
                }
                customTabsSession.mayLaunchUrl(primary, null, likely);
            } catch (Throwable ignored) {
            }
        }
    }

    void openUrl(Activity activity, String url, boolean dark) {
        if (activity == null || !isHttpUrl(url)) {
            return;
        }
        if (!initialized) {
            init(activity.getApplicationContext());
        }

        int barColor = dark ? Color.parseColor("#151517") : Color.WHITE;
        CustomTabColorSchemeParams colors = new CustomTabColorSchemeParams.Builder()
            .setToolbarColor(barColor)
            .setNavigationBarColor(barColor)
            .build();
        CustomTabsIntent customTabsIntent = new CustomTabsIntent.Builder(customTabsSession)
            .setDefaultColorSchemeParams(colors)
            .setColorScheme(dark ? CustomTabsIntent.COLOR_SCHEME_DARK : CustomTabsIntent.COLOR_SCHEME_LIGHT)
            .setShowTitle(true)
            .setShareState(CustomTabsIntent.SHARE_STATE_ON)
            .setUrlBarHidingEnabled(true)
            .build();

        Uri uri = Uri.parse(url);
        if (mictHelper != null && mictReady && tryOpenWithMict(activity, uri, customTabsIntent)) {
            return;
        }

        if (customTabsPkg != null && !customTabsPkg.isEmpty()) {
            try {
                customTabsIntent.intent.setPackage(customTabsPkg);
                customTabsIntent.launchUrl(activity, uri);
                return;
            } catch (Throwable ignored) {
                customTabsIntent.intent.setPackage(null);
            }
        }

        try {
            customTabsIntent.launchUrl(activity, uri);
        } catch (Throwable ignored) {
            try {
                Intent fallback = new Intent(Intent.ACTION_VIEW, uri);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                activity.startActivity(fallback);
            } catch (Throwable ignored2) {
            }
        }
    }

    private void tryInitXiaomiMict(Context appCtx) {
        if (OemSpeechHelper.detectBrand() != OemSpeechHelper.Brand.XIAOMI) {
            return;
        }
        String appId = readXiaomiAppId(appCtx);
        if (appId.isEmpty()) {
            return;
        }
        try {
            Class<?> helperClass = Class.forName("com.android.browser.customtabs.CustomTabsHelper");
            Method getInstance = helperClass.getMethod("getInstance");
            Object instance = getInstance.invoke(null);
            if (instance == null) {
                return;
            }
            mictHelper = instance;

            for (Method method : helperClass.getMethods()) {
                if (!"auth".equals(method.getName())) {
                    continue;
                }
                Class<?>[] params = method.getParameterTypes();
                if (params.length == 2 && params[0].isAssignableFrom(Context.class) && params[1].isInterface()) {
                    Object callbackProxy = Proxy.newProxyInstance(
                        helperClass.getClassLoader(),
                        new Class<?>[] { params[1] },
                        (proxy, cbMethod, args) -> {
                            boolean ok = true;
                            if (args != null && args.length > 0) {
                                if (args[0] instanceof Boolean) {
                                    ok = (Boolean) args[0];
                                } else if (args[0] instanceof Integer) {
                                    ok = ((Integer) args[0]) == 0;
                                }
                            }
                            mictReady = ok;
                            return null;
                        }
                    );
                    method.invoke(instance, appCtx, callbackProxy);
                    return;
                }
                if (params.length == 1 && params[0].isAssignableFrom(Context.class)) {
                    method.invoke(instance, appCtx);
                    mictReady = true;
                    return;
                }
            }
        } catch (Throwable ignored) {
            mictHelper = null;
            mictReady = false;
        }
    }

    private static String readXiaomiAppId(Context context) {
        try {
            ApplicationInfo ai = context.getPackageManager().getApplicationInfo(
                context.getPackageName(),
                PackageManager.GET_META_DATA
            );
            if (ai != null && ai.metaData != null) {
                Object value = ai.metaData.get("com.xiaomi.xms.APP_ID");
                if (value != null) {
                    return String.valueOf(value).trim();
                }
            }
        } catch (Throwable ignored) {
        }
        return "";
    }

    private void bindStandardCustomTabs(Context appCtx) {
        customTabsPkg = resolveBestCustomTabsPackage(appCtx);
        if (customTabsPkg != null && !customTabsPkg.isEmpty() && !serviceBound) {
            try {
                serviceBound = CustomTabsClient.bindCustomTabsService(appCtx, customTabsPkg, serviceConnection);
            } catch (Throwable ignored) {
                serviceBound = false;
            }
        }
    }

    private boolean tryOpenWithMict(Activity activity, Uri uri, CustomTabsIntent customTabsIntent) {
        try {
            Class<?> helperClass = mictHelper.getClass();
            for (Method method : helperClass.getMethods()) {
                if (!"openCustomTab".equals(method.getName())) {
                    continue;
                }
                Class<?>[] params = method.getParameterTypes();
                if (params.length == 4
                    && params[0].isAssignableFrom(Activity.class)
                    && params[1] == Uri.class
                    && params[2].isAssignableFrom(CustomTabsIntent.class)) {
                    method.invoke(mictHelper, activity, uri, customTabsIntent, null);
                    return true;
                }
                if (params.length == 3
                    && params[0].isAssignableFrom(Activity.class)
                    && params[1] == Uri.class
                    && params[2].isAssignableFrom(CustomTabsIntent.class)) {
                    method.invoke(mictHelper, activity, uri, customTabsIntent);
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private static String resolveBestCustomTabsPackage(Context context) {
        PackageManager pm = context.getPackageManager();
        Intent activityIntent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://www.example.com"));
        List<ResolveInfo> resolvedViews = pm.queryIntentActivities(activityIntent, PackageManager.MATCH_ALL);
        Set<String> supporting = new LinkedHashSet<>();

        for (ResolveInfo info : resolvedViews) {
            if (info == null || info.activityInfo == null || info.activityInfo.packageName == null) {
                continue;
            }
            String pkg = info.activityInfo.packageName;
            Intent serviceIntent = new Intent(CustomTabsService.ACTION_CUSTOM_TABS_SERVICE);
            serviceIntent.setPackage(pkg);
            if (pm.resolveService(serviceIntent, 0) != null) {
                supporting.add(pkg);
            }
        }

        if (supporting.isEmpty()) {
            Intent serviceQuery = new Intent(CustomTabsService.ACTION_CUSTOM_TABS_SERVICE);
            List<ResolveInfo> services = pm.queryIntentServices(serviceQuery, 0);
            for (ResolveInfo ri : services) {
                if (ri != null && ri.serviceInfo != null && ri.serviceInfo.packageName != null) {
                    supporting.add(ri.serviceInfo.packageName);
                }
            }
        }

        if (supporting.isEmpty()) {
            return null;
        }

        for (String preferred : getPreferredBrowsersForBrand(OemSpeechHelper.detectBrand())) {
            if (supporting.contains(preferred)) {
                return preferred;
            }
        }

        ResolveInfo defaultView = pm.resolveActivity(activityIntent, PackageManager.MATCH_DEFAULT_ONLY);
        if (defaultView != null && defaultView.activityInfo != null) {
            String defaultPkg = defaultView.activityInfo.packageName;
            if (supporting.contains(defaultPkg)) {
                return defaultPkg;
            }
        }

        return supporting.iterator().next();
    }

    private static List<String> getPreferredBrowsersForBrand(OemSpeechHelper.Brand brand) {
        switch (brand) {
            case XIAOMI:
                return Arrays.asList("com.android.browser", "com.mi.globalbrowser", "com.android.chrome");
            case OPPO:
                return Arrays.asList("com.heytap.browser", "com.coloros.browser", "com.android.chrome");
            case VIVO:
                return Arrays.asList("com.vivo.browser", "com.android.chrome");
            case HONOR_HUAWEI:
                return Arrays.asList("com.hihonor.baidu.browser", "com.huawei.browser", "com.android.chrome");
            case SAMSUNG:
                return Arrays.asList("com.sec.android.app.sbrowser", "com.android.chrome");
            default:
                return Arrays.asList("com.android.chrome", "com.android.browser");
        }
    }

    private static boolean isHttpUrl(String url) {
        return url != null && (url.startsWith("https://") || url.startsWith("http://"));
    }
}
