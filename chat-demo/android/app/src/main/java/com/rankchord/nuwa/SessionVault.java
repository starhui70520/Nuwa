package com.rankchord.nuwa;

import android.content.Context;
import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

/**
 * Android 原生沙盒会话保险库（getFilesDir()/nuwa_vault/sessions/<key>.json.gz）。
 *
 * 每个会话独立保存为 GZIP 压缩 JSON，写入采用「临时文件 + fsync + 原子重命名」，
 * 完全独立于 WebView IndexedDB（LevelDB），防止切后台强杀（大退）、LevelDB 损坏
 * 或系统清理 WebView 临时配额时造成历史对话全部丢失。
 */
final class SessionVault {
    private static final String VAULT_REL_PATH = "nuwa_vault/sessions";
    private static final String SUFFIX = ".json.gz";
    private static final String TMP_SUFFIX = ".json.gz.tmp";
    private static final Pattern SAFE_KEY_PATTERN = Pattern.compile("^[A-Za-z0-9_-]{1,128}$");

    private static volatile SessionVault instance;

    private final File sessionsDir;
    private final ExecutorService executor;
    private final Object pendingLock = new Object();
    private final Map<String, String> pendingWrites = new HashMap<>();
    private final Set<String> scheduledKeys = new LinkedHashSet<>();

    private SessionVault(Context context) {
        this.sessionsDir = new File(context.getApplicationContext().getFilesDir(), VAULT_REL_PATH);
        this.executor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "nuwa-session-vault");
            t.setDaemon(true);
            return t;
        });
    }

    static SessionVault getInstance(Context context) {
        SessionVault local = instance;
        if (local == null) {
            synchronized (SessionVault.class) {
                local = instance;
                if (local == null) {
                    local = new SessionVault(context);
                    instance = local;
                }
            }
        }
        return local;
    }

    static String toSafeKey(String rawId) {
        if (rawId == null) {
            return null;
        }
        String trimmed = rawId.trim();
        if (trimmed.isEmpty() || ".".equals(trimmed) || "..".equals(trimmed)) {
            return null;
        }
        if (SAFE_KEY_PATTERN.matcher(trimmed).matches()) {
            return trimmed;
        }
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(trimmed.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder("h_");
            for (int i = 0; i < 16 && i < hash.length; i++) {
                sb.append(String.format(Locale.US, "%02x", hash[i] & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return "h_" + Math.abs(trimmed.hashCode());
        }
    }

    /** 合并同一会话的连续写请求并异步原子落盘，避免超长会话高频写入阻塞主线程。 */
    void enqueueSave(String rawId, String json) {
        final String key = toSafeKey(rawId);
        if (key == null || json == null || json.isEmpty()) {
            return;
        }
        boolean shouldSchedule;
        synchronized (pendingLock) {
            pendingWrites.put(key, json);
            shouldSchedule = scheduledKeys.add(key);
        }
        if (shouldSchedule) {
            executor.execute(() -> flushKey(key));
        }
    }

    private void flushKey(String key) {
        while (true) {
            String payload;
            synchronized (pendingLock) {
                payload = pendingWrites.remove(key);
                if (payload == null) {
                    scheduledKeys.remove(key);
                    return;
                }
            }
            try {
                writeAtomicGzip(key, payload);
            } catch (Throwable ignored) {
                // 原生镜像失败不阻断前台对话流程
            }
            synchronized (pendingLock) {
                if (!pendingWrites.containsKey(key)) {
                    scheduledKeys.remove(key);
                    return;
                }
            }
        }
    }

    void deleteSync(String rawId) {
        final String key = toSafeKey(rawId);
        if (key == null) {
            return;
        }
        synchronized (pendingLock) {
            pendingWrites.remove(key);
        }
        runOnExecutorSync(() -> {
            synchronized (pendingLock) {
                pendingWrites.remove(key);
            }
            File target = new File(sessionsDir, key + SUFFIX);
            File tmp = new File(sessionsDir, key + TMP_SUFFIX);
            //noinspection ResultOfMethodCallIgnored
            target.delete();
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            return null;
        });
    }

    void clearSync() {
        synchronized (pendingLock) {
            pendingWrites.clear();
        }
        runOnExecutorSync(() -> {
            synchronized (pendingLock) {
                pendingWrites.clear();
            }
            File[] files = sessionsDir.listFiles();
            if (files != null) {
                for (File f : files) {
                    if (f != null && f.isFile()) {
                        //noinspection ResultOfMethodCallIgnored
                        f.delete();
                    }
                }
            }
            return null;
        });
    }

    List<String> listKeysSync() {
        List<String> result = runOnExecutorSync(() -> {
            Set<String> keys = new LinkedHashSet<>();
            synchronized (pendingLock) {
                keys.addAll(pendingWrites.keySet());
            }
            File[] files = sessionsDir.listFiles();
            if (files != null) {
                for (File f : files) {
                    if (f != null && f.isFile()) {
                        String name = f.getName();
                        if (name.endsWith(SUFFIX) && name.length() > SUFFIX.length()) {
                            keys.add(name.substring(0, name.length() - SUFFIX.length()));
                        }
                    }
                }
            }
            return new ArrayList<>(keys);
        });
        return result != null ? result : new ArrayList<>();
    }

    String readSync(String rawId) {
        final String key = toSafeKey(rawId);
        if (key == null) {
            return null;
        }
        return runOnExecutorSync(() -> {
            synchronized (pendingLock) {
                String pending = pendingWrites.get(key);
                if (pending != null) {
                    return pending;
                }
            }
            File target = new File(sessionsDir, key + SUFFIX);
            if (!target.exists() || !target.isFile()) {
                return null;
            }
            return readGzipUtf8(target);
        });
    }

    private <T> T runOnExecutorSync(Callable<T> task) {
        try {
            Future<T> future = executor.submit(task);
            return future.get();
        } catch (Throwable ignored) {
            return null;
        }
    }

    private void ensureDir() throws IOException {
        if (!sessionsDir.exists() && !sessionsDir.mkdirs() && !sessionsDir.exists()) {
            throw new IOException("Unable to create session vault directory");
        }
    }

    private void writeAtomicGzip(String key, String json) throws IOException {
        ensureDir();
        File tmp = new File(sessionsDir, key + TMP_SUFFIX);
        File target = new File(sessionsDir, key + SUFFIX);
        byte[] utf8 = json.getBytes(StandardCharsets.UTF_8);

        try (FileOutputStream fos = new FileOutputStream(tmp)) {
            GZIPOutputStream gz = new GZIPOutputStream(fos, 8192);
            gz.write(utf8);
            gz.finish();
            gz.flush();
            fos.flush();
            try {
                fos.getFD().sync();
            } catch (IOException ignored) {
                // 极少数虚拟存储卷不支持 fsync 时仍继续执行原子重命名
            }
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw e;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                Files.move(
                    tmp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE
                );
                return;
            } catch (IOException ignored) {
                try {
                    Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
                    return;
                } catch (IOException ignored2) {
                    // 回退到 File.renameTo
                }
            }
        }
        if (!tmp.renameTo(target)) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw new IOException("Atomic rename failed for session vault key: " + key);
        }
    }

    private static String readGzipUtf8(File file) {
        try (FileInputStream fis = new FileInputStream(file);
             GZIPInputStream gz = new GZIPInputStream(fis, 8192);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = gz.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (Throwable ignored) {
            return null;
        }
    }
}
