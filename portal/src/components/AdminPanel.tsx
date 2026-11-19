import { useCallback, useEffect, useState, type FormEvent } from 'react';
import type {
  AdminReleasesResponse,
  ArticleItem,
  HarmonyStatus,
  IosStatus,
  Platform,
  ReleaseItem
} from '../types';
import { formatBytes, formatDate, getPlatformLabel } from '../utils';
import { AdminReportsTab } from './AdminReportsTab';

interface AdminPanelProps {
  onDataChanged: () => void;
}

const TOKEN_STORAGE_KEY = 'nuwa_portal_admin_token';

type AdminTab = 'apps' | 'articles' | 'reports';

export function AdminPanel({ onDataChanged }: AdminPanelProps) {
  const [token, setToken] = useState<string>(() => localStorage.getItem(TOKEN_STORAGE_KEY) || '');
  const [password, setPassword] = useState('');
  const [authError, setAuthError] = useState<string | null>(null);
  const [loggingIn, setLoggingIn] = useState(false);

  const [tab, setTab] = useState<AdminTab>('apps');
  const [data, setData] = useState<AdminReleasesResponse | null>(null);
  const [articles, setArticles] = useState<ArticleItem[]>([]);
  const [reportsCount, setReportsCount] = useState<number>(0);
  const [loading, setLoading] = useState(false);
  const [actionMsg, setActionMsg] = useState<string | null>(null);

  // App upload form state
  const [platform, setPlatform] = useState<Platform>('android');
  const [version, setVersion] = useState('0.1.1');
  const [versionCode, setVersionCode] = useState('10001');
  const [changelog, setChangelog] = useState('');
  const [isLatest, setIsLatest] = useState(true);
  const [file, setFile] = useState<File | null>(null);
  const [uploading, setUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [uploadError, setUploadError] = useState<string | null>(null);

  // iOS & HarmonyOS store config state
  const [iosStatus, setIosStatus] = useState<IosStatus>('coming_soon');
  const [iosUrl, setIosUrl] = useState('');
  const [iosNote, setIosNote] = useState('');
  const [savingIos, setSavingIos] = useState(false);

  const [harmonyStatus, setHarmonyStatus] = useState<HarmonyStatus>('coming_soon');
  const [harmonyUrl, setHarmonyUrl] = useState('');
  const [harmonyNote, setHarmonyNote] = useState('');
  const [savingHarmony, setSavingHarmony] = useState(false);

  // Article editor state
  const [editingId, setEditingId] = useState<string | null>(null);
  const [artTitle, setArtTitle] = useState('');
  const [artSlug, setArtSlug] = useState('');
  const [artTags, setArtTags] = useState('');
  const [artCoverUrl, setArtCoverUrl] = useState('');
  const [artAuthor, setArtAuthor] = useState('RankChord Team');
  const [artSummary, setArtSummary] = useState('');
  const [artContent, setArtContent] = useState('');
  const [artPublished, setArtPublished] = useState(true);
  const [savingArticle, setSavingArticle] = useState(false);
  const [uploadingMedia, setUploadingMedia] = useState(false);

  const fetchAdminData = useCallback(async (activeToken: string) => {
    if (!activeToken) return;
    setLoading(true);
    try {
      const [relRes, artRes, repRes] = await Promise.all([
        fetch('/api/admin/releases', {
          headers: { Authorization: `Bearer ${activeToken}` }
        }),
        fetch('/api/admin/articles', {
          headers: { Authorization: `Bearer ${activeToken}` }
        }),
        fetch('/api/admin/reports', {
          headers: { Authorization: `Bearer ${activeToken}` }
        })
      ]);

      if (relRes.status === 401 || artRes.status === 401 || repRes.status === 401) {
        localStorage.removeItem(TOKEN_STORAGE_KEY);
        setToken('');
        setAuthError('会话已过期，请重新输入管理密码。');
        return;
      }
      if (!relRes.ok) throw new Error(`HTTP ${relRes.status}`);

      const relJson = (await relRes.json()) as AdminReleasesResponse;
      setData(relJson);
      setIosStatus(relJson.ios.status);
      setIosUrl(relJson.ios.url);
      setIosNote(relJson.ios.note);
      if (relJson.harmony) {
        setHarmonyStatus(relJson.harmony.status);
        setHarmonyUrl(relJson.harmony.url);
        setHarmonyNote(relJson.harmony.note);
      }

      if (artRes.ok) {
        const artJson = (await artRes.json()) as { articles: ArticleItem[] };
        setArticles(artJson.articles || []);
      }
      if (repRes.ok) {
        const repJson = (await repRes.json()) as { reports?: unknown[] };
        setReportsCount(Array.isArray(repJson.reports) ? repJson.reports.length : 0);
      }
    } catch (err) {
      setActionMsg(`读取管理数据失败：${err instanceof Error ? err.message : String(err)}`);
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
        setAuthError(json.error || '管理密码错误');
        return;
      }
      localStorage.setItem(TOKEN_STORAGE_KEY, json.token);
      setToken(json.token);
      setPassword('');
    } catch {
      setAuthError('请求失败，请确认后端服务已启动。');
    } finally {
      setLoggingIn(false);
    }
  };

  const handleLogout = () => {
    localStorage.removeItem(TOKEN_STORAGE_KEY);
    setToken('');
    setData(null);
    setArticles([]);
  };

  const handleUpload = (e: FormEvent) => {
    e.preventDefault();
    if (!file) {
      setUploadError('请先选择要上传的安装包文件（.apk / .hap / .app）');
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
        setActionMsg('新版本已上传至存储并完成发布。');
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
      setUploadError('网络中断，上传未完成。');
    };

    xhr.send(formData);
  };

  const handlePatchRelease = async (id: string, body: Record<string, unknown>) => {
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

  const handleDeleteRelease = async (item: ReleaseItem) => {
    if (
      !window.confirm(
        `确认删除 ${getPlatformLabel(item.platform)} v${item.version} (${item.fileName})？此操作会同步移除存储桶中的安装包。`
      )
    ) {
      return;
    }
    const res = await fetch(`/api/admin/releases/${encodeURIComponent(item.id)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` }
    });
    if (res.ok) {
      setActionMsg(`已删除版本 v${item.version}`);
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
        setActionMsg('iOS 商店跳转配置已更新。');
        await fetchAdminData(token);
        onDataChanged();
      }
    } finally {
      setSavingIos(false);
    }
  };

  const handleSaveHarmony = async (e: FormEvent) => {
    e.preventDefault();
    setSavingHarmony(true);
    setActionMsg(null);
    try {
      const res = await fetch('/api/admin/harmony', {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`
        },
        body: JSON.stringify({
          status: harmonyStatus,
          url: harmonyUrl.trim(),
          note: harmonyNote.trim()
        })
      });
      if (res.ok) {
        setActionMsg('HarmonyOS 应用市场跳转配置已更新。');
        await fetchAdminData(token);
        onDataChanged();
      }
    } finally {
      setSavingHarmony(false);
    }
  };

  // --- Article handlers ---
  const resetArticleForm = () => {
    setEditingId(null);
    setArtTitle('');
    setArtSlug('');
    setArtTags('');
    setArtCoverUrl('');
    setArtAuthor('RankChord Team');
    setArtSummary('');
    setArtContent('');
    setArtPublished(true);
  };

  const startEditArticle = (a: ArticleItem) => {
    setEditingId(a.id);
    setArtTitle(a.title);
    setArtSlug(a.slug);
    setArtTags(a.tags.join(', '));
    setArtCoverUrl(a.coverUrl);
    setArtAuthor(a.author);
    setArtSummary(a.summary);
    setArtContent(a.content);
    setArtPublished(a.published);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const handleUploadMedia = async (mediaFile: File, target: 'cover' | 'inline') => {
    setUploadingMedia(true);
    try {
      const fd = new FormData();
      fd.append('file', mediaFile);
      const res = await fetch('/api/admin/media', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body: fd
      });
      const json = (await res.json()) as { url?: string; error?: string };
      if (!res.ok || !json.url) {
        setActionMsg(json.error || '图片上传失败');
        return;
      }
      if (target === 'cover') {
        setArtCoverUrl(json.url);
        setActionMsg('封面图已上传至存储桶。');
      } else {
        setArtContent((prev) => `${prev}\n\n![配图](${json.url})\n`);
        setActionMsg('插图已上传并插入到正文末尾。');
      }
    } finally {
      setUploadingMedia(false);
    }
  };

  const handleSaveArticle = async (e: FormEvent) => {
    e.preventDefault();
    if (!artTitle.trim()) return;
    setSavingArticle(true);
    setActionMsg(null);
    try {
      const payload = {
        title: artTitle.trim(),
        slug: artSlug.trim() || undefined,
        tags: artTags,
        coverUrl: artCoverUrl.trim(),
        author: artAuthor.trim() || 'RankChord Team',
        summary: artSummary.trim(),
        content: artContent,
        published: artPublished
      };

      const res = await fetch(
        editingId ? `/api/admin/articles/${encodeURIComponent(editingId)}` : '/api/admin/articles',
        {
          method: editingId ? 'PUT' : 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`
          },
          body: JSON.stringify(payload)
        }
      );

      if (res.ok) {
        setActionMsg(editingId ? '文章已更新。' : '新文章已发布。');
        resetArticleForm();
        await fetchAdminData(token);
        onDataChanged();
      } else {
        const errJson = (await res.json()) as { error?: string };
        setActionMsg(errJson.error || '保存文章失败');
      }
    } finally {
      setSavingArticle(false);
    }
  };

  const handleToggleArticlePublished = async (a: ArticleItem) => {
    const res = await fetch(`/api/admin/articles/${encodeURIComponent(a.id)}`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({ published: !a.published })
    });
    if (res.ok) {
      await fetchAdminData(token);
      onDataChanged();
    }
  };

  const handleDeleteArticle = async (a: ArticleItem) => {
    if (!window.confirm(`确认删除文章《${a.title}》？`)) return;
    const res = await fetch(`/api/admin/articles/${encodeURIComponent(a.id)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` }
    });
    if (res.ok) {
      if (editingId === a.id) resetArticleForm();
      setActionMsg(`已删除文章《${a.title}》`);
      await fetchAdminData(token);
      onDataChanged();
    }
  };

  if (!token) {
    return (
      <div className="site-container py-[96px] max-[680px]:py-[56px]">
        <div className="max-w-[440px] mx-auto">
          <p className="eyebrow">UNIFIED CONSOLE</p>
          <h1 className="mt-3 text-[36px] font-medium tracking-[-1px] leading-[1.1] text-[#18181b]">
            管理员验证
          </h1>
          <p className="mt-3 text-[14px] text-[#5d6168]">
            登录后可统一管理 Nuwa 客户端安装包（MinIO 存储）以及 RankChord 官网研究文章。
          </p>

          <form
            onSubmit={handleLogin}
            className="mt-8 rounded-[18px] border border-[#e8e8e8] bg-white p-7 space-y-5"
          >
            <div>
              <label className="block text-[13px] font-medium text-[#18181b] mb-2">
                管理密码 (ADMIN_PASSWORD)
              </label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="请输入管理密码"
                required
                className="w-full h-[44px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3.5 text-[14px] text-[#18181b] outline-none transition-colors"
              />
            </div>

            {authError && <p className="text-[13px] text-[#d83a36]">{authError}</p>}

            <button type="submit" disabled={loggingIn} className="rc-pill-dark w-full">
              {loggingIn ? '验证中…' : '进入统一控制台'}
            </button>
          </form>
        </div>
      </div>
    );
  }

  return (
    <div className="site-container py-[56px] max-[680px]:py-[36px] space-y-10">
      {/* Page Heading & Tabs */}
      <div className="flex flex-wrap items-end justify-between gap-4 border-b border-[#e8e8e8] pb-7">
        <div>
          <p className="eyebrow">UNIFIED CONSOLE</p>
          <h1 className="mt-3 text-[clamp(32px,3.4vw,46px)] font-medium tracking-[-1.2px] leading-[1.08] text-[#18181b]">
            应用与内容发布台
          </h1>
          <div className="mt-5 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => setTab('apps')}
              className={`h-[38px] px-5 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
                tab === 'apps'
                  ? 'bg-[#18181b] text-white'
                  : 'bg-[#f6f6f6] text-[#18181b] hover:bg-[#e8e8e8]'
              }`}
            >
              应用分发管理 ({data?.releases.length ?? 0})
            </button>
            <button
              type="button"
              onClick={() => setTab('articles')}
              className={`h-[38px] px-5 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
                tab === 'articles'
                  ? 'bg-[#18181b] text-white'
                  : 'bg-[#f6f6f6] text-[#18181b] hover:bg-[#e8e8e8]'
              }`}
            >
              文章内容管理 ({articles.length})
            </button>
            <button
              type="button"
              onClick={() => setTab('reports')}
              className={`h-[38px] px-5 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
                tab === 'reports'
                  ? 'bg-[#18181b] text-white'
                  : 'bg-[#f6f6f6] text-[#18181b] hover:bg-[#e8e8e8]'
              }`}
            >
              问题日志 ({reportsCount})
            </button>
          </div>
        </div>

        <div className="flex items-center gap-3">
          {data?.storage && (
            <span className="rc-tag font-mono">
              {data.storage.minioConnected
                ? `MinIO · ${data.storage.bucket}`
                : 'Local Fallback Mode'}
            </span>
          )}
          <button
            type="button"
            onClick={handleLogout}
            className="rc-pill-soft !min-h-[38px] !px-4 !text-[13px]"
          >
            退出登录
          </button>
        </div>
      </div>

      {data?.storage && !data.storage.minioConnected && (
        <div className="rounded-[14px] border border-[#e8e8e8] bg-[#f6f6f6] px-5 py-4 text-[13px] text-[#5d6168]">
          当前未检测到可用的 MinIO 连接，已自动启用本地磁盘存储回退模式
          {data.storage.error ? `（原因：${data.storage.error}）` : ''}。
        </div>
      )}

      {actionMsg && (
        <div className="rounded-[14px] border border-[#18181b] bg-white px-5 py-3.5 text-[14px] text-[#18181b]">
          {actionMsg}
        </div>
      )}

      {tab === 'reports' ? (
        <AdminReportsTab
          token={token}
          onUnauthorized={handleLogout}
          onNotify={setActionMsg}
          onCountChange={setReportsCount}
        />
      ) : tab === 'apps' ? (
        <>
          <div className="grid grid-cols-1 min-[1041px]:grid-cols-[minmax(0,1.45fr)_minmax(320px,0.85fr)] gap-[28px]">
            <form
              onSubmit={handleUpload}
              className="rounded-[18px] border border-[#e8e8e8] bg-white p-[28px] space-y-5"
            >
              <div>
                <p className="eyebrow">NEW BUILD</p>
                <h2 className="mt-2 text-[23px] font-medium text-[#18181b]">上传并发布安装包</h2>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">目标平台</label>
                  <select
                    value={platform}
                    onChange={(e) => setPlatform(e.target.value as Platform)}
                    className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[14px] text-[#18181b] outline-none"
                  >
                    <option value="android">Android (.apk)</option>
                    <option value="harmony">HarmonyOS (.hap / .app)</option>
                  </select>
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">版本号</label>
                  <input
                    type="text"
                    value={version}
                    onChange={(e) => setVersion(e.target.value)}
                    placeholder="0.1.2"
                    required
                    className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[14px] text-[#18181b] outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">构建号</label>
                  <input
                    type="number"
                    value={versionCode}
                    onChange={(e) => setVersionCode(e.target.value)}
                    placeholder="10002"
                    required
                    className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[14px] text-[#18181b] outline-none"
                  />
                </div>
              </div>

              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">更新说明 (Changelog)</label>
                <textarea
                  rows={3}
                  value={changelog}
                  onChange={(e) => setChangelog(e.target.value)}
                  placeholder="简述本次构建的核心变更与修复…"
                  className="w-full rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] p-3 text-[14px] text-[#18181b] outline-none"
                />
              </div>

              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">构建产物文件</label>
                <label className="flex flex-col items-center justify-center rounded-[12px] border border-[#e8e8e8] hover:border-[#18181b] bg-[#f6f6f6]/60 px-4 py-7 text-center transition-colors cursor-pointer">
                  <span className="text-[14px] font-medium text-[#18181b]">
                    {file
                      ? `${file.name} (${formatBytes(file.size)})`
                      : '点击选择安装包文件 (.apk / .hap / .app / .zip)'}
                  </span>
                  <span className="mt-1 text-[12px] text-[#686d74]">
                    单文件上限 500 MB · 上传后自动计算 SHA-256
                  </span>
                  <input
                    type="file"
                    accept=".apk,.hap,.app,.zip"
                    className="hidden"
                    onChange={(e) => setFile(e.target.files?.[0] ?? null)}
                  />
                </label>
              </div>

              <label className="inline-flex items-center gap-2 text-[13px] text-[#5d6168] cursor-pointer">
                <input
                  type="checkbox"
                  checked={isLatest}
                  onChange={(e) => setIsLatest(e.target.checked)}
                  className="accent-[#18181b]"
                />
                <span>将该版本标记为对应平台的最新推荐版本 (Latest)</span>
              </label>

              {uploading && (
                <div className="space-y-1.5">
                  <div className="flex justify-between text-[12px] text-[#686d74]">
                    <span>正在上传至存储桶…</span>
                    <span className="font-mono text-[#18181b]">{uploadProgress}%</span>
                  </div>
                  <div className="h-[3px] w-full rounded-full bg-[#e8e8e8] overflow-hidden">
                    <div
                      className="h-full bg-[#18181b] transition-all"
                      style={{ width: `${uploadProgress}%` }}
                    />
                  </div>
                </div>
              )}

              {uploadError && <p className="text-[13px] text-[#d83a36]">{uploadError}</p>}

              <div className="pt-1">
                <button type="submit" disabled={uploading} className="rc-pill-dark min-w-[174px]">
                  {uploading ? '正在上传…' : '上传并发布'}
                </button>
              </div>
            </form>

            <div className="space-y-6">
              <form
                onSubmit={handleSaveHarmony}
                className="rounded-[18px] border border-[#e8e8e8] bg-white p-[24px] space-y-4"
              >
                <div>
                  <p className="eyebrow">HARMONYOS STORE</p>
                  <h2 className="mt-1.5 text-[20px] font-medium text-[#18181b]">鸿蒙应用市场跳转</h2>
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">上架状态</label>
                  <select
                    value={harmonyStatus}
                    onChange={(e) => setHarmonyStatus(e.target.value as HarmonyStatus)}
                    className="w-full h-[40px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[13px] text-[#18181b] outline-none"
                  >
                    <option value="coming_soon">准备中 / 即将上架</option>
                    <option value="appgallery">已上架华为应用市场</option>
                  </select>
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">应用市场链接</label>
                  <input
                    type="url"
                    value={harmonyUrl}
                    onChange={(e) => setHarmonyUrl(e.target.value)}
                    placeholder="https://appgallery.huawei.com/..."
                    className="w-full h-[40px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[12px] text-[#18181b] outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">说明文案</label>
                  <textarea
                    rows={2}
                    value={harmonyNote}
                    onChange={(e) => setHarmonyNote(e.target.value)}
                    className="w-full rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] p-2.5 text-[13px] text-[#18181b] outline-none"
                  />
                </div>

                <button type="submit" disabled={savingHarmony} className="rc-pill-outline w-full !min-h-[40px]">
                  {savingHarmony ? '保存中…' : '保存鸿蒙配置'}
                </button>
              </form>

              <form
                onSubmit={handleSaveIos}
                className="rounded-[18px] border border-[#e8e8e8] bg-white p-[24px] space-y-4"
              >
                <div>
                  <p className="eyebrow">IOS STORE</p>
                  <h2 className="mt-1.5 text-[20px] font-medium text-[#18181b]">iOS 商店跳转</h2>
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">分发状态</label>
                  <select
                    value={iosStatus}
                    onChange={(e) => setIosStatus(e.target.value as IosStatus)}
                    className="w-full h-[40px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[13px] text-[#18181b] outline-none"
                  >
                    <option value="coming_soon">准备中 / 即将上架</option>
                    <option value="testflight">TestFlight 公测跳转</option>
                    <option value="appstore">App Store 正式版跳转</option>
                  </select>
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">跳转目标 URL</label>
                  <input
                    type="url"
                    value={iosUrl}
                    onChange={(e) => setIosUrl(e.target.value)}
                    placeholder="https://apps.apple.com/..."
                    className="w-full h-[40px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[12px] text-[#18181b] outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[12px] text-[#686d74] mb-1.5">说明文案</label>
                  <textarea
                    rows={2}
                    value={iosNote}
                    onChange={(e) => setIosNote(e.target.value)}
                    className="w-full rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] p-2.5 text-[13px] text-[#18181b] outline-none"
                  />
                </div>

                <button type="submit" disabled={savingIos} className="rc-pill-outline w-full !min-h-[40px]">
                  {savingIos ? '保存中…' : '保存 iOS 配置'}
                </button>
              </form>
            </div>
          </div>

          <div className="pt-4">
            <div className="mb-5">
              <p className="eyebrow">ARCHIVE</p>
              <h2 className="mt-2 text-[26px] font-medium text-[#18181b]">已归档构建列表</h2>
            </div>

            {loading ? (
              <p className="border-t border-[#e8e8e8] py-8 text-[14px] text-[#686d74]">正在加载…</p>
            ) : !data?.releases.length ? (
              <p className="border-t border-b border-[#e8e8e8] py-8 text-[14px] text-[#686d74]">
                暂无已上传的版本记录。
              </p>
            ) : (
              <div className="overflow-x-auto border-t border-b border-[#e8e8e8]">
                <table className="w-full text-left text-[13px]">
                  <thead className="border-b border-[#e8e8e8] text-[#686d74]">
                    <tr>
                      <th className="py-3.5 pr-4 font-medium">平台</th>
                      <th className="py-3.5 pr-4 font-medium">版本号</th>
                      <th className="py-3.5 pr-4 font-medium">文件与大小</th>
                      <th className="py-3.5 pr-4 font-medium">下载次数</th>
                      <th className="py-3.5 pr-4 font-medium">发布时间</th>
                      <th className="py-3.5 text-right font-medium">操作</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-[#e8e8e8]">
                    {data.releases.map((item) => (
                      <tr key={item.id}>
                        <td className="py-4 pr-4 font-medium text-[#18181b]">
                          {getPlatformLabel(item.platform)}
                        </td>
                        <td className="py-4 pr-4 font-mono text-[#18181b]">
                          <span>
                            v{item.version} ({item.versionCode})
                          </span>
                          {item.isLatest && <span className="ml-2 rc-tag-dark">Latest</span>}
                          {!item.published && <span className="ml-2 rc-tag">已下架</span>}
                        </td>
                        <td className="py-4 pr-4 font-mono text-[#5d6168]">
                          {item.fileName} · {formatBytes(item.fileSize)}
                        </td>
                        <td className="py-4 pr-4 font-mono text-[#18181b]">{item.downloads}</td>
                        <td className="py-4 pr-4 font-mono text-[#686d74]">
                          {formatDate(item.createdAt)}
                        </td>
                        <td className="py-4 text-right">
                          <div className="inline-flex items-center gap-3 text-[13px]">
                            {!item.isLatest && (
                              <button
                                type="button"
                                onClick={() => handlePatchRelease(item.id, { isLatest: true })}
                                className="text-[#18181b] hover:opacity-55 cursor-pointer"
                              >
                                设为最新
                              </button>
                            )}
                            <button
                              type="button"
                              onClick={() =>
                                handlePatchRelease(item.id, { published: !item.published })
                              }
                              className="text-[#5d6168] hover:text-[#18181b] cursor-pointer"
                            >
                              {item.published ? '下架' : '上架'}
                            </button>
                            <button
                              type="button"
                              onClick={() => handleDeleteRelease(item)}
                              className="text-[#d83a36] hover:opacity-65 cursor-pointer"
                            >
                              删除
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
        </>
      ) : (
        /* Articles Management Tab */
        <div className="space-y-10">
          <form
            onSubmit={handleSaveArticle}
            className="rounded-[18px] border border-[#e8e8e8] bg-white p-[28px] space-y-5"
          >
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="eyebrow">{editingId ? 'EDIT ARTICLE' : 'NEW ARTICLE'}</p>
                <h2 className="mt-2 text-[23px] font-medium text-[#18181b]">
                  {editingId ? '编辑研究文章' : '撰写并发布新文章'}
                </h2>
              </div>
              {editingId && (
                <button
                  type="button"
                  onClick={resetArticleForm}
                  className="rc-pill-soft !min-h-[36px] !px-4 !text-[12px]"
                >
                  取消编辑
                </button>
              )}
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">文章标题</label>
                <input
                  type="text"
                  value={artTitle}
                  onChange={(e) => setArtTitle(e.target.value)}
                  placeholder="例如：OpenPivot 长程智能体协同架构"
                  required
                  className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[14px] text-[#18181b] outline-none"
                />
              </div>

              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">
                  URL Slug（留空自动生成）
                </label>
                <input
                  type="text"
                  value={artSlug}
                  onChange={(e) => setArtSlug(e.target.value)}
                  placeholder="openpivot-architecture"
                  className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[13px] text-[#18181b] outline-none"
                />
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">
                  标签（逗号分隔）
                </label>
                <input
                  type="text"
                  value={artTags}
                  onChange={(e) => setArtTags(e.target.value)}
                  placeholder="OpenPivot, 智能体, 工程"
                  className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[14px] text-[#18181b] outline-none"
                />
              </div>

              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">作者</label>
                <input
                  type="text"
                  value={artAuthor}
                  onChange={(e) => setArtAuthor(e.target.value)}
                  className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[14px] text-[#18181b] outline-none"
                />
              </div>

              <div>
                <label className="block text-[12px] text-[#686d74] mb-1.5">封面图 URL</label>
                <div className="flex gap-2">
                  <input
                    type="text"
                    value={artCoverUrl}
                    onChange={(e) => setArtCoverUrl(e.target.value)}
                    placeholder="/api/media/... 或外部图片链接"
                    className="w-full h-[42px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 font-mono text-[12px] text-[#18181b] outline-none"
                  />
                  <label className="shrink-0 h-[42px] px-3 rounded-[10px] bg-[#f6f6f6] hover:bg-[#e8e8e8] inline-flex items-center text-[12px] font-medium text-[#18181b] cursor-pointer">
                    {uploadingMedia ? '上传中' : '上传'}
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => {
                        const f = e.target.files?.[0];
                        if (f) void handleUploadMedia(f, 'cover');
                      }}
                    />
                  </label>
                </div>
              </div>
            </div>

            <div>
              <label className="block text-[12px] text-[#686d74] mb-1.5">文章摘要</label>
              <textarea
                rows={2}
                value={artSummary}
                onChange={(e) => setArtSummary(e.target.value)}
                placeholder="用于首页卡片与列表页展示的简短摘要…"
                className="w-full rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] p-3 text-[14px] text-[#18181b] outline-none"
              />
            </div>

            <div>
              <div className="flex items-center justify-between mb-1.5">
                <label className="block text-[12px] text-[#686d74]">正文（Markdown）</label>
                <label className="text-[12px] font-medium text-[#18181b] hover:opacity-65 cursor-pointer">
                  + 插入图片到正文（MinIO）
                  <input
                    type="file"
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => {
                      const f = e.target.files?.[0];
                      if (f) void handleUploadMedia(f, 'inline');
                    }}
                  />
                </label>
              </div>
              <textarea
                rows={10}
                value={artContent}
                onChange={(e) => setArtContent(e.target.value)}
                placeholder="支持标准 Markdown 语法（标题、代码块、引用、列表、图片）…"
                className="w-full rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] p-3 font-mono text-[13px] leading-[1.7] text-[#18181b] outline-none"
              />
            </div>

            <label className="inline-flex items-center gap-2 text-[13px] text-[#5d6168] cursor-pointer">
              <input
                type="checkbox"
                checked={artPublished}
                onChange={(e) => setArtPublished(e.target.checked)}
                className="accent-[#18181b]"
              />
              <span>立即公开展示在官网首页与研究列表</span>
            </label>

            <div>
              <button type="submit" disabled={savingArticle} className="rc-pill-dark min-w-[174px]">
                {savingArticle ? '保存中…' : editingId ? '保存修改' : '发布文章'}
              </button>
            </div>
          </form>

          <div>
            <div className="mb-5">
              <p className="eyebrow">ARTICLES</p>
              <h2 className="mt-2 text-[26px] font-medium text-[#18181b]">已创建文章列表</h2>
            </div>

            {articles.length === 0 ? (
              <p className="border-t border-b border-[#e8e8e8] py-8 text-[14px] text-[#686d74]">
                暂无文章记录。
              </p>
            ) : (
              <div className="overflow-x-auto border-t border-b border-[#e8e8e8]">
                <table className="w-full text-left text-[13px]">
                  <thead className="border-b border-[#e8e8e8] text-[#686d74]">
                    <tr>
                      <th className="py-3.5 pr-4 font-medium">标题</th>
                      <th className="py-3.5 pr-4 font-medium">标签</th>
                      <th className="py-3.5 pr-4 font-medium">状态</th>
                      <th className="py-3.5 pr-4 font-medium">发布日期</th>
                      <th className="py-3.5 text-right font-medium">操作</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-[#e8e8e8]">
                    {articles.map((a) => (
                      <tr key={a.id}>
                        <td className="py-4 pr-4 font-medium text-[#18181b]">{a.title}</td>
                        <td className="py-4 pr-4 text-[#5d6168]">{a.tags.join(' · ') || '—'}</td>
                        <td className="py-4 pr-4">
                          <span className={a.published ? 'rc-tag-dark' : 'rc-tag'}>
                            {a.published ? '已发布' : '草稿'}
                          </span>
                        </td>
                        <td className="py-4 pr-4 font-mono text-[#686d74]">
                          {formatDate(a.publishedAt).split(' ')[0]}
                        </td>
                        <td className="py-4 text-right">
                          <div className="inline-flex items-center gap-3">
                            <button
                              type="button"
                              onClick={() => startEditArticle(a)}
                              className="text-[#18181b] hover:opacity-55 cursor-pointer"
                            >
                              编辑
                            </button>
                            <button
                              type="button"
                              onClick={() => handleToggleArticlePublished(a)}
                              className="text-[#5d6168] hover:text-[#18181b] cursor-pointer"
                            >
                              {a.published ? '转为草稿' : '发布'}
                            </button>
                            <button
                              type="button"
                              onClick={() => handleDeleteArticle(a)}
                              className="text-[#d83a36] hover:opacity-65 cursor-pointer"
                            >
                              删除
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
      )}
    </div>
  );
}
