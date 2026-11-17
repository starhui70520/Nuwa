import { useState } from 'react';
import {
  Check,
  Copy,
  Download,
  ExternalLink,
  HardDrive,
  QrCode,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Clock,
  Cpu,
  History
} from 'lucide-react';
import { QRCodeSVG } from 'qrcode.react';
import type { IosConfig, Platform, PublicReleasesResponse, ReleaseItem } from '../types';
import { detectClientOS, formatBytes, formatDate, getPlatformLabel } from '../utils';

interface PublicPortalProps {
  data: PublicReleasesResponse | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
}

export function PublicPortal({ data, loading, error, onRefresh }: PublicPortalProps) {
  const [filter, setFilter] = useState<'all' | Platform>('all');
  const [qrRelease, setQrRelease] = useState<ReleaseItem | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const detectedOS = detectClientOS();

  const handleCopySha = async (id: string, sha256: string) => {
    try {
      await navigator.clipboard.writeText(sha256);
      setCopiedId(id);
      setTimeout(() => setCopiedId((prev) => (prev === id ? null : prev)), 2000);
    } catch {
      // ignore clipboard errors
    }
  };

  const getDownloadHref = (id: string) => `/api/releases/${encodeURIComponent(id)}/download`;

  const getAbsoluteDownloadUrl = (id: string) => {
    if (typeof window === 'undefined') return getDownloadHref(id);
    return `${window.location.origin}${getDownloadHref(id)}`;
  };

  const releases = data?.releases ?? [];
  const filteredReleases = filter === 'all' ? releases : releases.filter((r) => r.platform === filter);

  return (
    <div className="space-y-16">
      {/* Hero Section */}
      <section className="relative pt-10 pb-4">
        <div className="pointer-events-none absolute -top-20 left-1/2 h-72 w-[680px] -translate-x-1/2 rounded-full bg-cyan-500/10 blur-[120px]" />

        <div className="relative max-w-3xl space-y-5">
          <div className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-3.5 py-1 text-xs text-zinc-300">
            <Sparkles className="h-3.5 w-3.5 text-cyan-400" />
            <span>RankChord · General Intelligence Systems, Built for Real Work</span>
          </div>

          <h1 className="text-4xl font-semibold tracking-tight text-white sm:text-5xl">
            Nuwa 跨端客户端发布中心
          </h1>
          <p className="text-base leading-relaxed text-zinc-400 sm:text-lg">
            由 <a href="https://rankchord.com/" target="_blank" rel="noreferrer" className="text-zinc-200 underline decoration-white/25 underline-offset-4 hover:text-cyan-300">RankChord（秩弦科技）</a> 构建的多端 AI 对话与历史会话迁移客户端。所有安装包均通过 MinIO 对象存储分发，并提供 SHA-256 完整性校验。
          </p>

          <div className="flex flex-wrap items-center gap-3 pt-1 text-xs text-zinc-400">
            <span className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-zinc-900/70 px-2.5 py-1 font-mono">
              <ShieldCheck className="h-3.5 w-3.5 text-emerald-400" />
              SHA-256 校验
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-zinc-900/70 px-2.5 py-1 font-mono">
              <HardDrive className="h-3.5 w-3.5 text-cyan-400" />
              存储引擎: {data?.storageDriver === 'minio' ? 'MinIO Object Storage' : 'Local Fallback'}
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-zinc-900/70 px-2.5 py-1 font-mono">
              <Cpu className="h-3.5 w-3.5 text-indigo-400" />
              Bundle: com.rankchord.nuwa
            </span>
          </div>
        </div>
      </section>

      {error && (
        <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-200 flex items-center justify-between">
          <span>加载版本信息失败：{error}</span>
          <button
            type="button"
            onClick={onRefresh}
            className="rounded-lg border border-red-400/30 px-3 py-1 text-xs hover:bg-red-500/20"
          >
            重试
          </button>
        </div>
      )}

      {/* Platform Download Cards */}
      <section className="grid gap-5 md:grid-cols-3">
        <PlatformCard
          title="Android 客户端"
          subtitle="适用于 Android 8.0 及以上设备 (.apk)"
          platform="android"
          recommended={detectedOS === 'android'}
          release={data?.latest.android ?? null}
          loading={loading}
          downloadHref={data?.latest.android ? getDownloadHref(data.latest.android.id) : undefined}
          onShowQr={(rel) => setQrRelease(rel)}
        />

        <PlatformCard
          title="HarmonyOS 鸿蒙版"
          subtitle="适用于 HarmonyOS / OpenHarmony (.hap / .app)"
          platform="harmony"
          recommended={detectedOS === 'harmony'}
          release={data?.latest.harmony ?? null}
          loading={loading}
          downloadHref={data?.latest.harmony ? getDownloadHref(data.latest.harmony.id) : undefined}
          onShowQr={(rel) => setQrRelease(rel)}
        />

        <IosCard
          ios={data?.ios ?? null}
          recommended={detectedOS === 'ios'}
          loading={loading}
        />
      </section>

      {/* Release History */}
      <section id="history" className="space-y-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-2.5">
            <History className="h-5 w-5 text-cyan-400" />
            <h2 className="text-xl font-semibold text-white">历史版本与更新日志</h2>
          </div>

          <div className="inline-flex rounded-lg border border-white/10 bg-zinc-900/80 p-1 text-xs">
            {(['all', 'android', 'harmony'] as const).map((tab) => (
              <button
                key={tab}
                type="button"
                onClick={() => setFilter(tab)}
                className={`rounded-md px-3 py-1.5 font-medium transition ${
                  filter === tab
                    ? 'bg-zinc-800 text-white shadow-sm'
                    : 'text-zinc-400 hover:text-zinc-200'
                }`}
              >
                {tab === 'all' ? '全部平台' : getPlatformLabel(tab)}
              </button>
            ))}
          </div>
        </div>

        {loading ? (
          <div className="rounded-2xl border border-white/10 bg-zinc-900/40 p-10 text-center text-sm text-zinc-500">
            正在从服务端读取版本列表...
          </div>
        ) : filteredReleases.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-white/10 bg-zinc-900/30 p-10 text-center text-sm text-zinc-400">
            当前暂无已发布的安装包，请前往右上角「发布管理」上传首个版本。
          </div>
        ) : (
          <div className="space-y-3">
            {filteredReleases.map((item) => (
              <div
                key={item.id}
                className="group rounded-2xl border border-white/10 bg-[#111114] p-5 transition hover:border-white/20"
              >
                <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                  <div className="space-y-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <span
                        className={`rounded-md px-2 py-0.5 text-xs font-medium ${
                          item.platform === 'android'
                            ? 'bg-emerald-500/15 text-emerald-300 border border-emerald-500/25'
                            : 'bg-cyan-500/15 text-cyan-300 border border-cyan-500/25'
                        }`}
                      >
                        {getPlatformLabel(item.platform)}
                      </span>
                      <span className="font-mono text-base font-semibold text-white">
                        v{item.version}
                      </span>
                      <span className="font-mono text-xs text-zinc-500">
                        build {item.versionCode}
                      </span>
                      {item.isLatest && (
                        <span className="rounded-full bg-cyan-500/20 px-2.5 py-0.5 text-[11px] font-medium text-cyan-300">
                          Latest
                        </span>
                      )}
                    </div>

                    <p className="whitespace-pre-line text-sm text-zinc-300">{item.changelog}</p>

                    <div className="flex flex-wrap items-center gap-x-5 gap-y-1.5 pt-1 text-xs text-zinc-500 font-mono">
                      <span>文件: {item.fileName}</span>
                      <span>大小: {formatBytes(item.fileSize)}</span>
                      <span>发布于: {formatDate(item.createdAt)}</span>
                      <span>下载次数: {item.downloads}</span>
                    </div>
                  </div>

                  <div className="flex flex-wrap items-center gap-2.5 shrink-0">
                    <button
                      type="button"
                      onClick={() => handleCopySha(item.id, item.sha256)}
                      title={item.sha256}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-300 transition hover:border-white/25 hover:text-white"
                    >
                      {copiedId === item.id ? (
                        <>
                          <Check className="h-3.5 w-3.5 text-emerald-400" />
                          <span>已复制 SHA-256</span>
                        </>
                      ) : (
                        <>
                          <Copy className="h-3.5 w-3.5 text-zinc-400" />
                          <span>SHA256: {item.sha256.slice(0, 10)}...</span>
                        </>
                      )}
                    </button>

                    <button
                      type="button"
                      onClick={() => setQrRelease(item)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-zinc-900 px-3 py-2 text-xs text-zinc-300 transition hover:border-white/25 hover:text-white"
                    >
                      <QrCode className="h-3.5 w-3.5" />
                      <span>扫码</span>
                    </button>

                    <a
                      href={getDownloadHref(item.id)}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-white px-4 py-2 text-xs font-medium text-zinc-950 transition hover:bg-zinc-200"
                    >
                      <Download className="h-3.5 w-3.5" />
                      <span>下载安装包</span>
                    </a>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {/* QR Code Modal */}
      {qrRelease && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 p-4 backdrop-blur-sm"
          onClick={() => setQrRelease(null)}
        >
          <div
            className="w-full max-w-sm rounded-2xl border border-white/15 bg-[#121216] p-6 text-center shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <h3 className="text-base font-semibold text-white">
              扫码下载 {getPlatformLabel(qrRelease.platform)} v{qrRelease.version}
            </h3>
            <p className="mt-1 text-xs text-zinc-400">
              使用手机相机或浏览器扫描二维码直接获取安装包
            </p>
            <div className="my-5 inline-flex rounded-2xl bg-white p-4">
              <QRCodeSVG value={getAbsoluteDownloadUrl(qrRelease.id)} size={184} />
            </div>
            <p className="truncate font-mono text-[11px] text-zinc-500">{qrRelease.fileName}</p>
            <button
              type="button"
              onClick={() => setQrRelease(null)}
              className="mt-4 w-full rounded-lg border border-white/10 bg-zinc-900 py-2 text-xs text-zinc-300 hover:bg-zinc-800"
            >
              关闭
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

interface PlatformCardProps {
  title: string;
  subtitle: string;
  platform: Platform;
  recommended: boolean;
  release: ReleaseItem | null;
  loading: boolean;
  downloadHref?: string;
  onShowQr: (release: ReleaseItem) => void;
}

function PlatformCard({
  title,
  subtitle,
  platform,
  recommended,
  release,
  loading,
  downloadHref,
  onShowQr
}: PlatformCardProps) {
  return (
    <div
      className={`relative flex flex-col justify-between rounded-2xl border p-6 transition ${
        recommended
          ? 'border-cyan-400/50 bg-gradient-to-b from-cyan-500/10 to-[#111114] shadow-[0_0_40px_-15px_rgba(34,211,238,0.25)]'
          : 'border-white/10 bg-[#111114] hover:border-white/20'
      }`}
    >
      <div className="space-y-4">
        <div className="flex items-start justify-between gap-2">
          <div className="flex items-center gap-2.5">
            <div
              className={`flex h-10 w-10 items-center justify-center rounded-xl border ${
                platform === 'android'
                  ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-300'
                  : 'border-cyan-500/30 bg-cyan-500/10 text-cyan-300'
              }`}
            >
              <Smartphone className="h-5 w-5" />
            </div>
            <div>
              <h3 className="text-base font-semibold text-white">{title}</h3>
              <p className="text-xs text-zinc-400">{subtitle}</p>
            </div>
          </div>

          {recommended && (
            <span className="shrink-0 rounded-full bg-cyan-400/20 px-2.5 py-0.5 text-[11px] font-medium text-cyan-300">
              当前设备推荐
            </span>
          )}
        </div>

        {loading ? (
          <div className="h-24 animate-pulse rounded-xl bg-white/[0.03]" />
        ) : release ? (
          <div className="space-y-2 rounded-xl border border-white/5 bg-black/30 p-3.5 text-xs">
            <div className="flex items-center justify-between">
              <span className="text-zinc-400">最新版本</span>
              <span className="font-mono font-semibold text-white">
                v{release.version} ({release.versionCode})
              </span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-zinc-400">包体大小</span>
              <span className="font-mono text-zinc-200">{formatBytes(release.fileSize)}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-zinc-400">更新时间</span>
              <span className="font-mono text-zinc-300">{formatDate(release.createdAt)}</span>
            </div>
          </div>
        ) : (
          <div className="rounded-xl border border-dashed border-white/10 bg-black/20 p-4 text-xs text-zinc-500">
            暂未发布该平台安装包，请在管理后台上传。
          </div>
        )}
      </div>

      <div className="mt-5 flex items-center gap-2">
        {release && downloadHref ? (
          <>
            <a
              href={downloadHref}
              className="inline-flex flex-1 items-center justify-center gap-2 rounded-xl bg-white px-4 py-2.5 text-sm font-medium text-zinc-950 transition hover:bg-zinc-200"
            >
              <Download className="h-4 w-4" />
              <span>立即下载</span>
            </a>
            <button
              type="button"
              onClick={() => onShowQr(release)}
              title="扫码下载"
              className="inline-flex items-center justify-center rounded-xl border border-white/10 bg-zinc-900 p-2.5 text-zinc-300 transition hover:border-white/25 hover:text-white"
            >
              <QrCode className="h-4 w-4" />
            </button>
          </>
        ) : (
          <button
            type="button"
            disabled
            className="w-full cursor-not-allowed rounded-xl border border-white/10 bg-zinc-900/60 py-2.5 text-sm text-zinc-500"
          >
            暂无可下载版本
          </button>
        )}
      </div>
    </div>
  );
}

function IosCard({
  ios,
  recommended,
  loading
}: {
  ios: IosConfig | null;
  recommended: boolean;
  loading: boolean;
}) {
  const isReady = Boolean(ios && ios.status !== 'coming_soon' && ios.url);
  const badgeText =
    ios?.status === 'appstore'
      ? 'App Store'
      : ios?.status === 'testflight'
        ? 'TestFlight 公测'
        : '敬请期待';

  return (
    <div
      className={`relative flex flex-col justify-between rounded-2xl border p-6 transition ${
        recommended
          ? 'border-indigo-400/50 bg-gradient-to-b from-indigo-500/10 to-[#111114]'
          : 'border-white/10 bg-[#111114] hover:border-white/20'
      }`}
    >
      <div className="space-y-4">
        <div className="flex items-start justify-between gap-2">
          <div className="flex items-center gap-2.5">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl border border-indigo-500/30 bg-indigo-500/10 text-indigo-300">
              <Smartphone className="h-5 w-5" />
            </div>
            <div>
              <h3 className="text-base font-semibold text-white">iOS 客户端</h3>
              <p className="text-xs text-zinc-400">iPhone / iPad 跳转分发</p>
            </div>
          </div>

          <span
            className={`shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-medium ${
              isReady
                ? 'bg-indigo-400/20 text-indigo-300'
                : 'bg-zinc-800 text-zinc-400'
            }`}
          >
            {badgeText}
          </span>
        </div>

        {loading ? (
          <div className="h-24 animate-pulse rounded-xl bg-white/[0.03]" />
        ) : (
          <div className="space-y-2 rounded-xl border border-white/5 bg-black/30 p-3.5 text-xs text-zinc-300 leading-relaxed">
            <div className="flex items-center gap-1.5 text-zinc-400">
              <Clock className="h-3.5 w-3.5" />
              <span>分发状态：{badgeText}</span>
            </div>
            <p className="text-zinc-400">
              {ios?.note || 'iOS 客户端正在适配中，后续将通过 TestFlight / App Store 跳转链接提供安装。'}
            </p>
          </div>
        )}
      </div>

      <div className="mt-5">
        {isReady && ios ? (
          <a
            href={ios.url}
            target="_blank"
            rel="noreferrer"
            className="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-indigo-500 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-indigo-400"
          >
            <span>{ios.status === 'testflight' ? '前往 TestFlight 安装' : '前往 App Store 下载'}</span>
            <ExternalLink className="h-4 w-4" />
          </a>
        ) : (
          <button
            type="button"
            disabled
            className="inline-flex w-full cursor-not-allowed items-center justify-center gap-2 rounded-xl border border-white/10 bg-zinc-900/60 py-2.5 text-sm text-zinc-500"
          >
            <Clock className="h-4 w-4" />
            <span>iOS 跳转暂未开放</span>
          </button>
        )}
      </div>
    </div>
  );
}
