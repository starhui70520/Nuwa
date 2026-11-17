import { useCallback, useEffect, useState, type FormEvent } from 'react';
import {
  CheckCircle2,
  Database,
  Eye,
  EyeOff,
  Lock,
  LogOut,
  Star,
  Trash2,
  UploadCloud,
  AlertTriangle
} from 'lucide-react';
import type { AdminReleasesResponse, IosStatus, Platform, ReleaseItem } from '../types';
import { formatBytes, formatDate, getPlatformLabel } from '../utils';

interface AdminPanelProps {
  onDataChanged: () => void;
}

const TOKEN_STORAGE_KEY = 'nuwa_portal_admin_token';

export function AdminPanel({ onDataChanged }: AdminPanelProps) {
  const [token, setToken] = useState<string>(() => localStorage.getItem(TOKEN_STORAGE_KEY) || '');
  const [password, setPassword] = useState('');
  const [authError, setAuthError] = useState<string | null>(null);
  const [loggingIn, setLoggingIn] = useState(false);

  const [data, setData] = useState<AdminReleasesResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [actionMsg, setActionMsg] = useState<string | null>(null);

  // Upload form state
  const [platform, setPlatform] = useState<Platform>('android');
  const [version, setVersion] = useState('0.1.1');
  const [versionCode, setVersionCode] = useState('10001');
  const [changelog, setChangelog] = useState('');
  const [isLatest, setIsLatest] = useState(true);
  const [file, setFile] = useState<File | null>(null);
  const [uploading, setUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [uploadError, setUploadError] = useState<string | null>(null);

  // iOS config state
  const [iosStatus, setIosStatus] = useState<IosStatus>('coming_soon');
  const [iosUrl, setIosUrl] = useState('');
  const [iosNote, setIosNote] = useState('');
  const [savingIos, setSavingIos] = useState(false);

  const fetchAdminData = useCallback(async (activeToken: string) => {
    if (!activeToken) return;
    setLoading(true);
    try {
      const res = await fetch('/api/admin/releases', {
        headers: { Authorization: `Bearer ${activeToken}` }
      });
      if (res.status === 401) {
        localStorage.removeItem(TOKEN_STORAGE_KEY);
        setToken('');
        setAuthError('登录已失效，请重新输入管理密码。');
        return;
      }
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      const json = (await res.json()) as AdminReleasesResponse;
      setData(json);
      setIosStatus(json.ios.status);
      setIosUrl(json.ios.url);
      setIosNote(json.ios.note);
    } catch (err) {
      setActionMsg(`读取后台数据失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (token) {
      void fetchAdminData(token);
    }
  }, [token, fetchAdminData]);

  const handleLogin = async (e: FormEvent) => {
    e.preventDefault();
    setLoggingIn(true);
    setAuthError(null);
    try {
      const res = await fetch('/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password })
      });
      const json = (await res.json()) as { token?: string; error?: string };
      if (!res.ok || !json.token) {
        setAuthError(json.error || '密码错误');
        return;
      }
      localStorage.setItem(TOKEN_STORAGE_KEY, json.token);
      setToken(json.token);
      setPassword('');
    } catch {
      setAuthError('网络请求失败，请检查后端服务是否启动。');
    } finally {
      setLoggingIn(false);
    }
  };

  const handleLogout = () => {
    localStorage.removeItem(TOKEN_STORAGE_KEY);
    setToken('');
    setData(null);
  };

  const handleUpload = (e: FormEvent) => {
    e.preventDefault();
    if (!file) {
      setUploadError('请先选择安装包文件（.apk / .hap / .app）');
      return;
    }
    setUploading(true);
    setUploadProgress(0);
    setUploadError(null);
    setActionMsg(null);

    const formData = new FormData();
    formData.append('platform', platform);
    formData.append('version', version.trim());
    formData.append('versionCode', versionCode.trim());
    formData.append('changelog', changelog.trim());
    formData.append('isLatest', String(isLatest));
    formData.append('published', 'true');
    formData.append('file', file);

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/admin/releases');
    xhr.setRequestHeader('Authorization', `Bearer ${token}`);

    xhr.upload.onprogress = (ev) => {
      if (ev.lengthComputable) {
        setUploadProgress(Math.round((ev.loaded / ev.total) * 100));
      }
    };

    xhr.onload = () => {
      setUploading(false);
      if (xhr.status >= 200 && xhr.status < 300) {
        setFile(null);
        setChangelog('');
        setUploadProgress(100);
        setActionMsg('新版本已上传至存储并发布成功。');
        void fetchAdminData(token);
        onDataChanged();
      } else {
        try {
          const parsed = JSON.parse(xhr.responseText) as { error?: string };
          setUploadError(parsed.error || `上传失败 (${xhr.status})`);
        } catch {
          setUploadError(`上传失败 (${xhr.status})`);
        }
      }
    };

    xhr.onerror = () => {
      setUploading(false);
      setUploadError('网络错误，上传中断。');
    };

    xhr.send(formData);
  };

  const handlePatch = async (id: string, body: Record<string, unknown>) => {
    setActionMsg(null);
    const res = await fetch(`/api/admin/releases/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify(body)
    });
    if (res.ok) {
      await fetchAdminData(token);
      onDataChanged();
    }
  };

  const handleDelete = async (item: ReleaseItem) => {
    if (!window.confirm(`确定要删除 ${getPlatformLabel(item.platform)} v${item.version} (${item.fileName}) 吗？该操作会同时删除 MinIO 中的安装包文件。`)) {
      return;
    }
    const res = await fetch(`/api/admin/releases/${encodeURIComponent(item.id)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` }
    });
    if (res.ok) {
      setActionMsg(`已删除 v${item.version}`);
      await fetchAdminData(token);
      onDataChanged();
    }
  };

  const handleSaveIos = async (e: FormEvent) => {
    e.preventDefault();
    setSavingIos(true);
    setActionMsg(null);
    try {
      const res = await fetch('/api/admin/ios', {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`
        },
        body: JSON.stringify({
          status: iosStatus,
          url: iosUrl.trim(),
          note: iosNote.trim()
        })
      });
      if (res.ok) {
        setActionMsg('iOS 跳转配置已保存。');
        await fetchAdminData(token);
        onDataChanged();
      }
    } finally {
      setSavingIos(false);
    }
  };

  if (!token) {
    return (
      <div className="mx-auto max-w-md py-16">
        <form
          onSubmit={handleLogin}
          className="space-y-5 rounded-2xl border border-white/10 bg-[#111114] p-7 shadow-xl"
        >
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl border border-cyan-500/30 bg-cyan-500/10 text-cyan-300">
              <Lock className="h-5 w-5" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-white">发布管理后台</h2>
              <p className="text-xs text-zinc-400">请输入管理员密码以管理 MinIO 版本包</p>
            </div>
          </div>

          <div className="space-y-2">
            <label className="block text-xs text-zinc-400">管理密码 (ADMIN_PASSWORD)</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="默认: rankchord-admin"
              required
              className="w-full rounded-xl border border-white/10 bg-black/50 px-3.5 py-2.5 text-sm text-white outline-none focus:border-cyan-400"
            />
          </div>

          {authError && (
            <p className="text-xs text-red-400">{authError}</p>
          )}

          <button
            type="submit"
            disabled={loggingIn}
            className="w-full rounded-xl bg-white py-2.5 text-sm font-medium text-zinc-950 transition hover:bg-zinc-200 disabled:opacity-60"
          >
            {loggingIn ? '验证中...' : '登录后台'}
          </button>
        </form>
      </div>
    );
  }

  return (
    <div className="space-y-8 py-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold text-white">版本发布与 MinIO 存储管理</h1>
          <p className="mt-1 text-xs text-zinc-400">上传 Android / HarmonyOS 安装包至 MinIO，或配置 iOS 外部跳转链接</p>
        </div>

        <button
          type="button"
          onClick={handleLogout}
          className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-zinc-900 px-3 py-2 text-xs text-zinc-300 hover:bg-zinc-800"
        >
          <LogOut className="h-3.5 w-3.5" />
          <span>退出登录</span>
        </button>
      </div>

      {/* Storage Banner */}
      {data?.storage && (
        <div
          className={`flex flex-wrap items-center justify-between gap-3 rounded-xl border p-4 text-xs ${
            data.storage.minioConnected
              ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-200'
              : 'border-amber-500/30 bg-amber-500/10 text-amber-200'
          }`}
        >
          <div className="flex items-center gap-2.5">
            {data.storage.minioConnected ? (
              <Database className="h-4 w-4 text-emerald-400" />
            ) : (
              <AlertTriangle className="h-4 w-4 text-amber-400" />
            )}
            <span>
              {data.storage.minioConnected
                ? `MinIO 已连接 · ${data.storage.endpoint} · Bucket: ${data.storage.bucket}`
                : `当前运行在本地回退模式 (Local Disk)${data.storage.error ? ` — MinIO 连接失败: ${data.storage.error}` : ' — 请在 .env 中配置 MINIO_* 参数启用 MinIO'}`}
            </span>
          </div>
        </div>
      )}

      {actionMsg && (
        <div className="flex items-center gap-2 rounded-xl border border-cyan-500/30 bg-cyan-500/10 px-4 py-3 text-xs text-cyan-200">
          <CheckCircle2 className="h-4 w-4 text-cyan-400" />
          <span>{actionMsg}</span>
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        {/* Upload New Version */}
        <form
          onSubmit={handleUpload}
          className="space-y-4 rounded-2xl border border-white/10 bg-[#111114] p-6 lg:col-span-2"
        >
          <div className="flex items-center gap-2 text-base font-semibold text-white">
            <UploadCloud className="h-5 w-5 text-cyan-400" />
            <span>上传并发布新版本</span>
          </div>

          <div className="grid gap-4 sm:grid-cols-3">
            <div>
              <label className="mb-1.5 block text-xs text-zinc-400">目标平台</label>
              <select
                value={platform}
                onChange={(e) => setPlatform(e.target.value as Platform)}
                className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 text-sm text-white outline-none focus:border-cyan-400"
              >
                <option value="android">Android (.apk)</option>
                <option value="harmony">HarmonyOS (.hap / .app)</option>
              </select>
            </div>

            <div>
              <label className="mb-1.5 block text-xs text-zinc-400">版本号 (versionName)</label>
              <input
                type="text"
                value={version}
                onChange={(e) => setVersion(e.target.value)}
                placeholder="例如 0.1.2"
                required
                className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 font-mono text-sm text-white outline-none focus:border-cyan-400"
              />
            </div>

            <div>
              <label className="mb-1.5 block text-xs text-zinc-400">构建号 (versionCode)</label>
              <input
                type="number"
                value={versionCode}
                onChange={(e) => setVersionCode(e.target.value)}
                placeholder="10002"
                required
                className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 font-mono text-sm text-white outline-none focus:border-cyan-400"
              />
            </div>
          </div>

          <div>
            <label className="mb-1.5 block text-xs text-zinc-400">更新日志 (Changelog)</label>
            <textarea
              rows={3}
              value={changelog}
              onChange={(e) => setChangelog(e.target.value)}
              placeholder="- 新增语音输入与历史会话一键迁移&#10;- 优化连接稳定性"
              className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 text-sm text-white outline-none focus:border-cyan-400"
            />
          </div>

          <div>
            <label className="mb-1.5 block text-xs text-zinc-400">选择安装包文件</label>
            <label className="flex cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-white/15 bg-black/30 px-4 py-6 text-center transition hover:border-cyan-400/50">
              <UploadCloud className="mb-2 h-6 w-6 text-zinc-400" />
              <span className="text-sm text-zinc-200">
                {file ? `${file.name} (${formatBytes(file.size)})` : '点击选择 .apk / .hap / .app / .zip 文件'}
              </span>
              <span className="mt-1 text-xs text-zinc-500">最大支持 500 MB，上传后自动计算 SHA-256</span>
              <input
                type="file"
                accept=".apk,.hap,.app,.zip"
                className="hidden"
                onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              />
            </label>
          </div>

          <label className="flex items-center gap-2 text-xs text-zinc-300">
            <input
              type="checkbox"
              checked={isLatest}
              onChange={(e) => setIsLatest(e.target.checked)}
              className="rounded border-white/20 bg-black"
            />
            <span>设为该平台当前推荐的最新版本 (Latest)</span>
          </label>

          {uploading && (
            <div className="space-y-1.5">
              <div className="flex justify-between text-xs text-zinc-400">
                <span>正在上传到存储服务...</span>
                <span className="font-mono">{uploadProgress}%</span>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-zinc-800">
                <div
                  className="h-full bg-cyan-400 transition-all"
                  style={{ width: `${uploadProgress}%` }}
                />
              </div>
            </div>
          )}

          {uploadError && <p className="text-xs text-red-400">{uploadError}</p>}

          <button
            type="submit"
            disabled={uploading}
            className="inline-flex items-center gap-2 rounded-xl bg-white px-5 py-2.5 text-sm font-medium text-zinc-950 transition hover:bg-zinc-200 disabled:opacity-60"
          >
            <UploadCloud className="h-4 w-4" />
            <span>{uploading ? '上传发布中...' : '立即上传并发布'}</span>
          </button>
        </form>

        {/* iOS Redirect Config */}
        <form
          onSubmit={handleSaveIos}
          className="space-y-4 rounded-2xl border border-white/10 bg-[#111114] p-6"
        >
          <h2 className="text-base font-semibold text-white">iOS 分发跳转配置</h2>
          <p className="text-xs text-zinc-400">
            iOS 端尚未上架时保持「敬请期待」；后续有了 TestFlight 或 App Store 链接可在此直接开启跳转。
          </p>

          <div>
            <label className="mb-1.5 block text-xs text-zinc-400">当前状态</label>
            <select
              value={iosStatus}
              onChange={(e) => setIosStatus(e.target.value as IosStatus)}
              className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 text-sm text-white outline-none focus:border-indigo-400"
            >
              <option value="coming_soon">开发中 / 敬请期待</option>
              <option value="testflight">TestFlight 公测跳转</option>
              <option value="appstore">App Store 正式版跳转</option>
            </select>
          </div>

          <div>
            <label className="mb-1.5 block text-xs text-zinc-400">跳转链接 (URL)</label>
            <input
              type="url"
              value={iosUrl}
              onChange={(e) => setIosUrl(e.target.value)}
              placeholder="https://testflight.apple.com/join/..."
              className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 font-mono text-xs text-white outline-none focus:border-indigo-400"
            />
          </div>

          <div>
            <label className="mb-1.5 block text-xs text-zinc-400">卡片说明文案</label>
            <textarea
              rows={3}
              value={iosNote}
              onChange={(e) => setIosNote(e.target.value)}
              className="w-full rounded-xl border border-white/10 bg-black/50 px-3 py-2 text-xs text-white outline-none focus:border-indigo-400"
            />
          </div>

          <button
            type="submit"
            disabled={savingIos}
            className="w-full rounded-xl border border-indigo-400/40 bg-indigo-500/20 py-2.5 text-sm font-medium text-indigo-200 transition hover:bg-indigo-500/30 disabled:opacity-60"
          >
            {savingIos ? '保存中...' : '保存 iOS 配置'}
          </button>
        </form>
      </div>

      {/* Release List */}
      <div className="rounded-2xl border border-white/10 bg-[#111114] p-6">
        <h2 className="mb-4 text-base font-semibold text-white">已上传版本列表</h2>

        {loading ? (
          <p className="text-xs text-zinc-500">加载中...</p>
        ) : !data?.releases.length ? (
          <p className="text-xs text-zinc-500">暂无版本记录。</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs">
              <thead className="border-b border-white/10 text-zinc-400">
                <tr>
                  <th className="py-2.5 pr-4">平台</th>
                  <th className="py-2.5 pr-4">版本</th>
                  <th className="py-2.5 pr-4">文件名 / 大小</th>
                  <th className="py-2.5 pr-4">下载量</th>
                  <th className="py-2.5 pr-4">发布时间</th>
                  <th className="py-2.5 text-right">操作</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {data.releases.map((item) => (
                  <tr key={item.id} className="text-zinc-300">
                    <td className="py-3 pr-4 font-medium">{getPlatformLabel(item.platform)}</td>
                    <td className="py-3 pr-4 font-mono">
                      v{item.version} ({item.versionCode})
                      {item.isLatest && (
                        <span className="ml-2 rounded bg-cyan-500/20 px-1.5 py-0.5 text-[10px] text-cyan-300">
                          Latest
                        </span>
                      )}
                      {!item.published && (
                        <span className="ml-2 rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] text-zinc-400">
                          已下架
                        </span>
                      )}
                    </td>
                    <td className="py-3 pr-4 font-mono text-zinc-400">
                      {item.fileName} · {formatBytes(item.fileSize)}
                    </td>
                    <td className="py-3 pr-4 font-mono">{item.downloads}</td>
                    <td className="py-3 pr-4 font-mono text-zinc-400">{formatDate(item.createdAt)}</td>
                    <td className="py-3 text-right">
                      <div className="inline-flex items-center gap-1.5">
                        {!item.isLatest && (
                          <button
                            type="button"
                            onClick={() => handlePatch(item.id, { isLatest: true })}
                            title="设为最新"
                            className="rounded-lg border border-white/10 p-1.5 text-zinc-300 hover:border-cyan-400/50 hover:text-cyan-300"
                          >
                            <Star className="h-3.5 w-3.5" />
                          </button>
                        )}
                        <button
                          type="button"
                          onClick={() => handlePatch(item.id, { published: !item.published })}
                          title={item.published ? '下架' : '重新上架'}
                          className="rounded-lg border border-white/10 p-1.5 text-zinc-300 hover:border-white/30"
                        >
                          {item.published ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}
                        </button>
                        <button
                          type="button"
                          onClick={() => handleDelete(item)}
                          title="删除"
                          className="rounded-lg border border-white/10 p-1.5 text-red-400 hover:border-red-400/50 hover:bg-red-500/10"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
