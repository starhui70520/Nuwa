package com.dsapp.chat;

import android.annotation.SuppressLint;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.speech.RecognitionService;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.Voice;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * OEM device detection and speech engine ranking for Xiaomi HyperOS/MIUI,
 * OPPO/OnePlus/Realme ColorOS, vivo/iQOO OriginOS, Honor/Huawei, and Google.
 */
final class OemSpeechHelper {
    enum Brand {
        XIAOMI,
        OPPO,
        VIVO,
        HONOR_HUAWEI,
        SAMSUNG,
        OTHER,
    }

    private static final class ScoredCandidate<T> {
        final T item;
        final int score;

        ScoredCandidate(T item, int score) {
            this.item = item;
            this.score = score;
        }
    }

    private OemSpeechHelper() {}

    static Brand detectBrand() {
        String id = ((Build.MANUFACTURER != null ? Build.MANUFACTURER : "")
            + " "
            + (Build.BRAND != null ? Build.BRAND : "")).toLowerCase(Locale.ROOT);
        if (id.contains("xiaomi") || id.contains("redmi") || id.contains("poco") || id.contains("blackshark")) {
            return Brand.XIAOMI;
        }
        if (id.contains("oppo") || id.contains("oneplus") || id.contains("realme")) {
            return Brand.OPPO;
        }
        if (id.contains("vivo") || id.contains("iqoo")) {
            return Brand.VIVO;
        }
        if (id.contains("honor") || id.contains("huawei")) {
            return Brand.HONOR_HUAWEI;
        }
        if (id.contains("samsung")) {
            return Brand.SAMSUNG;
        }
        return Brand.OTHER;
    }

    static boolean isHyperOs() {
        String name = getSystemProperty("ro.mi.os.version.name");
        String code = getSystemProperty("ro.mi.os.version.code");
        return !name.isEmpty() || !code.isEmpty();
    }

    static String getOsLabel() {
        if (isHyperOs()) {
            return "HyperOS";
        }
        switch (detectBrand()) {
            case XIAOMI:
                return "MIUI";
            case OPPO:
                return "ColorOS";
            case VIVO:
                return "OriginOS";
            case HONOR_HUAWEI:
                return "MagicOS";
            case SAMSUNG:
                return "OneUI";
            default:
                return "Android";
        }
    }

    static String describeEnginePackage(Context context, String pkg) {
        if (pkg == null || pkg.isEmpty()) {
            return "";
        }
        String lower = pkg.toLowerCase(Locale.ROOT);
        if (lower.startsWith("com.xiaomi.mibrain") || lower.startsWith("com.miui.voiceassist") || lower.startsWith("com.xiaomi.aicr")) {
            return "小爱语音引擎";
        }
        if (lower.startsWith("com.heytap.speechassist") || lower.startsWith("com.coloros.speechassist") || lower.startsWith("com.oplus.aiunit")) {
            return "小布语音引擎";
        }
        if (lower.startsWith("com.vivo.") || lower.equals("com.bbk.voiceassistant")) {
            return "蓝心/Jovi 语音引擎";
        }
        if (lower.startsWith("com.hihonor.") || lower.startsWith("com.huawei.")) {
            return "智慧语音引擎";
        }
        if (lower.startsWith("com.iflytek.")) {
            return "科大讯飞语音引擎";
        }
        if (lower.startsWith("com.baidu.")) {
            return "百度语音引擎";
        }
        if (lower.startsWith("com.samsung.")) {
            return "Samsung 语音引擎";
        }
        if (lower.equals("com.google.android.tts") || lower.equals("com.google.android.googlequicksearchbox")) {
            return "Google 语音服务";
        }
        try {
            PackageManager pm = context.getPackageManager();
            ApplicationInfo info = pm.getApplicationInfo(pkg, 0);
            CharSequence label = pm.getApplicationLabel(info);
            if (label != null && label.length() > 0) {
                return label.toString();
            }
        } catch (Exception ignored) {
        }
        return pkg;
    }

    static int scorePackageForBrand(String pkg, Brand brand, boolean preferChinese) {
        if (pkg == null || pkg.isEmpty()) {
            return 0;
        }
        String lower = pkg.toLowerCase(Locale.ROOT);
        if (brand == Brand.XIAOMI && (lower.startsWith("com.xiaomi.") || lower.startsWith("com.miui."))) {
            return 1000;
        }
        if (brand == Brand.OPPO && (lower.startsWith("com.heytap.") || lower.startsWith("com.coloros.") || lower.startsWith("com.oplus."))) {
            return 1000;
        }
        if (brand == Brand.VIVO && (lower.startsWith("com.vivo.") || lower.startsWith("com.bbk."))) {
            return 1000;
        }
        if (brand == Brand.HONOR_HUAWEI && (lower.startsWith("com.hihonor.") || lower.startsWith("com.huawei."))) {
            return 1000;
        }
        if (brand == Brand.SAMSUNG && lower.startsWith("com.samsung.")) {
            return 1000;
        }
        if (lower.startsWith("com.iflytek.")) {
            return 750;
        }
        if (lower.startsWith("com.baidu.")) {
            return 650;
        }
        if (lower.equals("com.google.android.tts") || lower.equals("com.google.android.googlequicksearchbox")) {
            if (brand == Brand.OTHER && !preferChinese) {
                return 950;
            }
            return preferChinese ? 500 : 850;
        }
        return 100;
    }

    static List<ComponentName> getRankedAsrCandidates(Context context, String locale, Set<String> blacklistedKeys) {
        boolean preferChinese = locale == null || !locale.toLowerCase(Locale.ROOT).startsWith("en");
        Brand brand = detectBrand();
        PackageManager pm = context.getPackageManager();
        List<ResolveInfo> services;
        try {
            services = pm.queryIntentServices(new Intent(RecognitionService.SERVICE_INTERFACE), 0);
        } catch (Exception e) {
            services = Collections.emptyList();
        }

        List<ScoredCandidate<ComponentName>> scored = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        if (services != null) {
            for (ResolveInfo ri : services) {
                ServiceInfo si = ri != null ? ri.serviceInfo : null;
                if (si == null || !si.enabled || si.packageName == null || si.name == null) {
                    continue;
                }
                ComponentName cn = new ComponentName(si.packageName, si.name);
                String key = cn.flattenToString();
                if (seen.contains(key) || (blacklistedKeys != null && blacklistedKeys.contains(key))) {
                    continue;
                }
                seen.add(key);
                boolean isSystem = si.applicationInfo != null
                    && (si.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                int score = scorePackageForBrand(si.packageName, brand, preferChinese) + (isSystem ? 80 : 0);
                scored.add(new ScoredCandidate<>(cn, score));
            }
        }

        Collections.sort(scored, (a, b) -> Integer.compare(b.score, a.score));
        List<ComponentName> result = new ArrayList<>(scored.size() + 1);
        for (ScoredCandidate<ComponentName> candidate : scored) {
            result.add(candidate.item);
        }

        boolean defaultBlacklisted = blacklistedKeys != null && blacklistedKeys.contains("__default__");
        if (!defaultBlacklisted && SpeechRecognizer.isRecognitionAvailable(context)) {
            result.add(null);
        }
        return result;
    }

    static List<String> getRankedTtsEngines(Context context, String locale) {
        boolean preferChinese = locale == null || !locale.toLowerCase(Locale.ROOT).startsWith("en");
        Brand brand = detectBrand();
        PackageManager pm = context.getPackageManager();
        List<ResolveInfo> services;
        try {
            services = pm.queryIntentServices(new Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0);
        } catch (Exception e) {
            services = Collections.emptyList();
        }

        List<ScoredCandidate<String>> scored = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        if (services != null) {
            for (ResolveInfo ri : services) {
                ServiceInfo si = ri != null ? ri.serviceInfo : null;
                if (si == null || !si.enabled || si.packageName == null || seen.contains(si.packageName)) {
                    continue;
                }
                seen.add(si.packageName);
                boolean isSystem = si.applicationInfo != null
                    && (si.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                int score = scorePackageForBrand(si.packageName, brand, preferChinese) + (isSystem ? 80 : 0);
                scored.add(new ScoredCandidate<>(si.packageName, score));
            }
        }

        Collections.sort(scored, (a, b) -> Integer.compare(b.score, a.score));
        List<String> result = new ArrayList<>(scored.size() + 1);
        for (ScoredCandidate<String> candidate : scored) {
            result.add(candidate.item);
        }
        result.add(null);
        return result;
    }

    static Intent buildRecognizerIntent(Context context, String locale, Brand brand) {
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        intent.putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.getPackageName());

        String resolved = (locale != null && locale.toLowerCase(Locale.ROOT).startsWith("en"))
            ? "en-US"
            : "zh-CN";
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, resolved);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, resolved);

        // Relax silence timeouts so HyperOS/ColorOS/OriginOS ASR engines don't cut off mid-sentence.
        long completeSilence = (brand == Brand.XIAOMI || brand == Brand.OPPO || brand == Brand.VIVO) ? 2400L : 2200L;
        intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, completeSilence);
        intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1800L);
        intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 1500L);
        return intent;
    }

    static void selectBestVoice(TextToSpeech tts, Locale targetLocale, String tonePreference) {
        if (tts == null || targetLocale == null) {
            return;
        }
        try {
            Set<Voice> voices = tts.getVoices();
            if (voices == null || voices.isEmpty()) {
                return;
            }
            String targetLang = targetLocale.getLanguage();
            String expectedCountry = "en".equalsIgnoreCase(targetLang) ? "US" : "CN";
            boolean wantMale = "tide".equalsIgnoreCase(tonePreference);

            Voice best = null;
            int bestScore = Integer.MIN_VALUE;

            for (Voice v : voices) {
                if (v == null || v.getLocale() == null) {
                    continue;
                }
                if (!targetLang.equalsIgnoreCase(v.getLocale().getLanguage())) {
                    continue;
                }
                Set<String> features = v.getFeatures();
                if (features != null && features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) {
                    continue;
                }

                int score = 0;
                if (expectedCountry.equalsIgnoreCase(v.getLocale().getCountry())) {
                    score += 250;
                }
                if (!v.isNetworkConnectionRequired()) {
                    score += 200;
                }
                score += v.getQuality();
                score += Math.max(0, 400 - v.getLatency()) / 4;

                String name = v.getName() != null ? v.getName().toLowerCase(Locale.ROOT) : "";
                if (wantMale) {
                    if ((name.contains("male") && !name.contains("female"))
                        || name.contains("m88")
                        || name.contains("xiaofeng")
                        || name.contains("yunxi")
                        || name.contains("kangkang")
                        || name.contains("yunjian")) {
                        score += 180;
                    }
                } else {
                    if (name.contains("female")
                        || name.contains("xiaoai")
                        || name.contains("xiaoyan")
                        || name.contains("xiaoxiao")
                        || name.contains("huihui")
                        || name.contains("yaoyao")) {
                        score += 180;
                    }
                }

                if (score > bestScore) {
                    bestScore = score;
                    best = v;
                }
            }

            if (best != null) {
                tts.setVoice(best);
            }
        } catch (Throwable ignored) {
        }
    }

    @SuppressLint("PrivateApi")
    private static String getSystemProperty(String key) {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            Method get = sp.getMethod("get", String.class, String.class);
            Object value = get.invoke(null, key, "");
            return value instanceof String ? ((String) value).trim() : "";
        } catch (Throwable ignored) {
            return "";
        }
    }
}
