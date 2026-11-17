import { useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import type { HarmonyConfig, IosConfig, PublicReleasesResponse, ReleaseItem } from '../types';
import { detectClientOS, formatBytes, formatDate } from '../utils';

interface PublicPortalProps {
  data: PublicReleasesResponse | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
  onOpenAdmin: () => void;
}

interface FeatureRow {
  eyebrow: string;
  title: string;
  description: string;
  image: string;
}

const NUWA_FEATURES: FeatureRow[] = [
  {
    eyebrow: '01 · 自由选择',
    title: '你的算力你决定，按需切换模型',
    description:
      '支持深度思考、联网搜索与语音输入。无论是日常问答还是复杂写作，都可以按自己的习惯选择服务商与模型。',
    image: '/nuwa-showcase/01-compute-choice.jpg'
  },
  {
    eyebrow: '02 · 账号授权',
    title: 'DeepSeek 账号授权即用',
    description:
      '直接通过官方账号授权登录，不用再去网页端到处复制配置密钥，打开应用就能开始对话。',
    image: '/nuwa-showcase/02-deepseek-oauth.jpg'
  },
  {
    eyebrow: '03 · 灵活接入',
    title: '自建或第三方模型也能接进来',
    description:
      '如果你有自己部署的模型或常用的第三方服务，只需填好地址与名称即可接入，所有配置仅保存在你的手机里。',
    image: '/nuwa-showcase/03-custom-api.jpg'
  },
  {
    eyebrow: '04 · 历史迁移',
    title: '旧对话一键迁移，不再丢失记忆',
    description:
      '支持登录后一键同步官方历史会话，也可以直接导入导出的压缩包，把过去聊过的内容完整带过来。',
    image: '/nuwa-showcase/04-oneclick-migrate.jpg'
  },
  {
    eyebrow: '05 · 本地备份',
    title: '会话留在本机，随时打包导出',
    description:
      '所有聊天记录与图片都安安静静保存在本地设备中，换手机时一键导出备份，安全又省心。',
    image: '/nuwa-showcase/05-local-backup.jpg'
  },
  {
    eyebrow: '06 · 额度透明',
    title: '沿用原账号额度，余额随时可看',
    description:
      '直接消耗原账号额度，侧边栏随时查看剩余金额与历史记录检索，用多少一目了然。',
    image: '/nuwa-showcase/06-balance-monitor.jpg'
  }
];

export function PublicPortal({
  data,
  loading,
  error,
  onRefresh
}: PublicPortalProps) {
  const [qrRelease, setQrRelease] = useState<ReleaseItem | null>(null);
  const [lightboxFeature, setLightboxFeature] = useState<FeatureRow | null>(null);
  const detectedOS = detectClientOS();

  const downloadBase = (data?.downloadBaseUrl || '').replace(/\/+$/, '');
  const getDownloadHref = (id: string) =>
    `${downloadBase}/api/releases/${encodeURIComponent(id)}/download`;

  const getAbsoluteDownloadUrl = (id: string) => {
    if (downloadBase) return getDownloadHref(id);
    if (typeof window === 'undefined') return getDownloadHref(id);
    return `${window.location.origin}${getDownloadHref(id)}`;
  };

  const androidLatest = data?.latest.android ?? null;
  const androidReleases = (data?.releases ?? []).filter((r) => r.platform === 'android');

  return (
    <div>
      {/* Consumer Hero */}
      <section className="site-container pt-[64px] pb-[76px] max-[680px]:pt-[42px] max-[680px]:pb-[52px] text-center">
        <div className="max-w-[780px] mx-auto">
          <div className="inline-flex items-center justify-center mb-6">
            <img
              src="/logo.png"
              alt="Nuwa"
              className="w-[84px] h-[84px] max-[680px]:w-[72px] max-[680px]:h-[72px] rounded-[22px] border border-[#e8e8e8] shadow-[0_10px_30px_rgba(24,24,27,0.08)] object-cover"
            />
          </div>

          <h1 className="text-[clamp(48px,5.4vw,68px)] max-[680px]:text-[40px] font-medium tracking-[-2px] max-[680px]:tracking-[-1.4px] leading-[1.05] text-[#18181b]">
            Nuwa
          </h1>

          <p className="mt-[18px] max-w-[560px] mx-auto text-[17px] max-[680px]:text-[15px] leading-[1.7] text-[#5d6168]">
            你的专属 AI 对话伙伴。自由切换模型、一键迁移旧对话，把所有聊天记录安心留在本机。
          </p>

          <div className="mt-[28px] flex flex-wrap justify-center gap-[10px]">
            {androidLatest ? (
              <a
                href={getDownloadHref(androidLatest.id)}
                className="rc-pill-dark min-w-[174px]"
              >
                <span>下载 Android 版 v{androidLatest.version}</span>
                <span aria-hidden="true">↓</span>
              </a>
            ) : (
              <a href="#downloads" className="rc-pill-dark min-w-[174px]">
                <span>立即获取</span>
                <span aria-hidden="true">↓</span>
              </a>
            )}

            <a href="#features" className="rc-pill-outline min-w-[174px]">
              <span>了解功能</span>
            </a>
          </div>
        </div>
      </section>

      {error && (
        <div className="site-container pb-8">
          <div className="border border-[#e8e8e8] rounded-[14px] px-5 py-4 flex items-center justify-between text-[14px] text-[#18181b] bg-[#f6f6f6]">
            <span>页面信息加载失败：{error}</span>
            <button type="button" onClick={onRefresh} className="rc-text-link">
              重新加载
            </button>
          </div>
        </div>
      )}

      {/* Platform Download Cards */}
      <section
        id="downloads"
        className="border-t border-[#e8e8e8] py-[88px] max-[680px]:py-[64px]"
      >
        <div className="site-container">
          <div className="mb-[44px] max-[680px]:mb-[32px]">
            <p className="eyebrow">DOWNLOAD</p>
            <h2 className="mt-[14px] text-[clamp(36px,3.6vw,48px)] font-medium tracking-[-1.2px] leading-[1.08] text-[#18181b]">
              下载客户端
            </h2>
          </div>

          <div className="grid grid-cols-1 min-[720px]:grid-cols-2 min-[1080px]:grid-cols-3 gap-[28px]">
            {/* Android — Official Direct APK */}
            <article
              className={`rounded-[18px] border bg-white p-[28px] flex flex-col justify-between ${
                detectedOS === 'android' ? 'border-[#18181b]' : 'border-[#e8e8e8]'
              }`}
            >
              <div>
                <div className="flex items-center justify-between gap-2">
                  <span className="rc-tag">官网直装包</span>
                  {detectedOS === 'android' && <span className="rc-tag-dark">当前设备</span>}
                </div>

                <h3 className="mt-5 text-[24px] font-medium text-[#18181b]">Android 版</h3>
                <p className="mt-2.5 text-[14px] leading-[1.7] text-[#5d6168]">
                  官方安装包直接下载安装，支持 Android 8.0 及以上手机与平板。
                </p>

                <div className="mt-6 border-t border-[#e8e8e8] pt-4 space-y-2 text-[13px]">
                  {loading ? (
                    <p className="text-[#686d74]">正在获取最新版本…</p>
                  ) : androidLatest ? (
                    <>
                      <div className="flex justify-between">
                        <span className="text-[#686d74]">最新版本</span>
                        <span className="text-[#18181b] font-medium">v{androidLatest.version}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-[#686d74]">安装包大小</span>
                        <span className="text-[#18181b]">{formatBytes(androidLatest.fileSize)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-[#686d74]">更新时间</span>
                        <span className="text-[#18181b]">
                          {formatDate(androidLatest.createdAt).split(' ')[0]}
                        </span>
                      </div>
                    </>
                  ) : (
                    <div className="flex justify-between">
                      <span className="text-[#686d74]">当前状态</span>
                      <span className="text-[#686d74]">即将提供下载</span>
                    </div>
                  )}
                </div>
              </div>

              <div className="mt-7 flex items-center gap-2.5">
                {androidLatest ? (
                  <>
                    <a
                      href={getDownloadHref(androidLatest.id)}
                      className="rc-pill-dark flex-1"
                    >
                      <span>下载安装包</span>
                      <span aria-hidden="true">↓</span>
                    </a>
                    <button
                      type="button"
                      onClick={() => setQrRelease(androidLatest)}
                      className="rc-pill-soft"
                    >
                      扫码
                    </button>
                  </>
                ) : (
                  <button type="button" disabled className="rc-pill-soft w-full">
                    暂未发布安装包
                  </button>
                )}
              </div>
            </article>

            {/* HarmonyOS — Store Redirect */}
            <StoreCard
              title="HarmonyOS 鸿蒙版"
              storeName="华为应用市场"
              recommended={detectedOS === 'harmony'}
              loading={loading}
              isReady={Boolean(
                data?.harmony && data.harmony.status === 'appgallery' && data.harmony.url
              )}
              badge={
                data?.harmony?.status === 'appgallery' && data?.harmony?.url
                  ? '华为应用市场'
                  : '即将上架'
              }
              note={
                data?.harmony?.note || '鸿蒙版正在上架审核中，即将登陆华为应用市场。'
              }
              url={data?.harmony?.url || ''}
              actionText="前往华为应用市场"
              disabledText="即将上架华为应用市场"
            />

            {/* iOS — Store Redirect */}
            <StoreCard
              title="iOS 版"
              storeName={
                data?.ios?.status === 'testflight' ? 'TestFlight' : 'App Store'
              }
              recommended={detectedOS === 'ios'}
              loading={loading}
              isReady={Boolean(
                data?.ios && data.ios.status !== 'coming_soon' && data.ios.url
              )}
              badge={
                data?.ios?.status === 'appstore'
                  ? 'App Store'
                  : data?.ios?.status === 'testflight'
                    ? 'TestFlight'
                    : '即将上架'
              }
              note={
                data?.ios?.note || 'iOS 版正在适配中，即将上架 App Store。'
              }
              url={data?.ios?.url || ''}
              actionText={
                data?.ios?.status === 'testflight'
                  ? '前往 TestFlight 获取'
                  : '前往 App Store 下载'
              }
              disabledText="即将上架 App Store"
            />
          </div>
        </div>
      </section>

      {/* Feature Showcase — Spacious 1 Row = 1 Image + 1 Text Block */}
      <section
        id="features"
        className="border-t border-[#e8e8e8] py-[96px] max-[680px]:py-[68px]"
      >
        <div className="site-container">
          <div className="max-w-[640px] mb-[64px] max-[680px]:mb-[44px]">
            <p className="eyebrow">FEATURES</p>
            <h2 className="mt-[14px] text-[clamp(36px,3.6vw,48px)] font-medium tracking-[-1.2px] leading-[1.08] text-[#18181b]">
              为日常使用而设计
            </h2>
          </div>

          <div className="divide-y divide-[#e8e8e8] border-t border-b border-[#e8e8e8]">
            {NUWA_FEATURES.map((feat, idx) => {
              const imageRight = idx % 2 === 1;
              return (
                <div
                  key={feat.eyebrow}
                  className="py-[68px] max-[680px]:py-[48px] grid grid-cols-1 min-[860px]:grid-cols-2 items-center gap-[48px] min-[1080px]:gap-[88px]"
                >
                  <div
                    className={`flex justify-center ${
                      imageRight ? 'min-[860px]:order-2' : 'min-[860px]:order-1'
                    }`}
                  >
                    <button
                      type="button"
                      onClick={() => setLightboxFeature(feat)}
                      className="block w-full max-w-[330px] rounded-[20px] overflow-hidden border border-[#e8e8e8] bg-[#f6f6f6] shadow-[0_12px_36px_rgba(24,24,27,0.06)] cursor-zoom-in group"
                    >
                      <img
                        src={feat.image}
                        alt={feat.title}
                        loading="lazy"
                        className="w-full h-auto block transition-transform duration-300 group-hover:scale-[1.015]"
                      />
                    </button>
                  </div>

                  <div
                    className={`max-w-[480px] ${
                      imageRight
                        ? 'min-[860px]:order-1 min-[860px]:justify-self-end'
                        : 'min-[860px]:order-2'
                    }`}
                  >
                    <p className="eyebrow">{feat.eyebrow}</p>
                    <h3 className="mt-4 text-[clamp(26px,2.5vw,34px)] font-medium tracking-[-0.6px] leading-[1.25] text-[#18181b]">
                      {feat.title}
                    </h3>
                    <p className="mt-4 text-[16px] leading-[1.8] text-[#5d6168] m-0">
                      {feat.description}
                    </p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      {/* Consumer-friendly Changelog (Only shown when Android builds exist) */}
      {androidReleases.length > 0 && (
        <section
          id="releases"
          className="border-t border-[#e8e8e8] py-[88px] max-[680px]:py-[64px]"
        >
          <div className="site-container grid grid-cols-1 min-[1041px]:grid-cols-[minmax(280px,0.72fr)_minmax(0,1.28fr)] items-start gap-[clamp(40px,6vw,96px)]">
            <div>
              <p className="eyebrow">UPDATES</p>
              <h2 className="mt-[14px] text-[clamp(34px,3.4vw,46px)] font-medium tracking-[-1.2px] leading-[1.08] text-[#18181b]">
                更新日志
              </h2>
              <p className="mt-4 text-[14px] leading-[1.7] text-[#686d74]">
                查看 Android 官方安装包的历史更新内容与下载。
              </p>
            </div>

            <div className="w-full border-b border-[#e8e8e8]">
              {androidReleases.map((item) => (
                <article
                  key={item.id}
                  className="border-t border-[#e8e8e8] py-[28px]"
                >
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="flex items-center gap-2.5">
                      <h3 className="text-[22px] font-medium text-[#18181b] m-0">
                        v{item.version}
                      </h3>
                      {item.isLatest && <span className="rc-tag-dark">最新版</span>}
                    </div>
                    <time className="text-[13px] text-[#686d74]">
                      {formatDate(item.createdAt).split(' ')[0]}
                    </time>
                  </div>

                  <p className="mt-3 whitespace-pre-line text-[15px] leading-[1.8] text-[#4b4f55]">
                    {item.changelog}
                  </p>

                  <div className="mt-5 flex items-center justify-between gap-4">
                    <span className="text-[13px] text-[#686d74]">
                      安装包大小：{formatBytes(item.fileSize)}
                    </span>

                    <a href={getDownloadHref(item.id)} className="rc-text-link">
                      <span>下载此版本</span>
                      <span aria-hidden="true">↓</span>
                    </a>
                  </div>
                </article>
              ))}
            </div>
          </div>
        </section>
      )}

      {/* Lightbox Modal */}
      {lightboxFeature && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-[2px]"
          onClick={() => setLightboxFeature(null)}
        >
          <div
            className="relative max-w-[440px] w-full rounded-[20px] border border-[#e8e8e8] bg-white p-4 shadow-2xl"
            onClick={(e) => e.stopPropagation()}
          >
            <img
              src={lightboxFeature.image}
              alt={lightboxFeature.title}
              className="w-full max-h-[78vh] object-contain rounded-[12px]"
            />
            <div className="mt-3 px-1 flex items-center justify-between gap-3">
              <p className="text-[15px] font-medium text-[#18181b] m-0">
                {lightboxFeature.title}
              </p>
              <button
                type="button"
                onClick={() => setLightboxFeature(null)}
                className="rc-pill-soft !min-h-[34px] !px-4 !text-[12px]"
              >
                关闭
              </button>
            </div>
          </div>
        </div>
      )}

      {/* QR Code Modal */}
      {qrRelease && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/35 p-4 backdrop-blur-[2px]"
          onClick={() => setQrRelease(null)}
        >
          <div
            className="w-full max-w-[340px] rounded-[20px] border border-[#e8e8e8] bg-white p-7 text-center shadow-[0_18px_50px_rgba(24,24,27,0.12)]"
            onClick={(e) => e.stopPropagation()}
          >
            <h3 className="text-[20px] font-medium text-[#18181b]">
              扫码下载 Android 版
            </h3>
            <p className="mt-1.5 text-[13px] text-[#5d6168]">
              使用手机相机或浏览器扫码即可下载 v{qrRelease.version}
            </p>

            <div className="my-6 inline-flex rounded-[14px] border border-[#e8e8e8] bg-white p-4">
              <QRCodeSVG value={getAbsoluteDownloadUrl(qrRelease.id)} size={176} />
            </div>

            <button
              type="button"
              onClick={() => setQrRelease(null)}
              className="w-full rc-pill-soft"
            >
              关闭
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

interface StoreCardProps {
  title: string;
  storeName: string;
  recommended: boolean;
  loading: boolean;
  isReady: boolean;
  badge: string;
  note: string;
  url: string;
  actionText: string;
  disabledText: string;
}

function StoreCard({
  title,
  storeName,
  recommended,
  loading,
  isReady,
  badge,
  note,
  url,
  actionText,
  disabledText
}: StoreCardProps) {
  return (
    <article
      className={`rounded-[18px] border bg-white p-[28px] flex flex-col justify-between ${
        recommended ? 'border-[#18181b]' : 'border-[#e8e8e8]'
      }`}
    >
      <div>
        <div className="flex items-center justify-between gap-2">
          <span className="rc-tag">{badge}</span>
          {recommended && <span className="rc-tag-dark">当前设备</span>}
        </div>

        <h3 className="mt-5 text-[24px] font-medium text-[#18181b]">{title}</h3>
        <p className="mt-2.5 text-[14px] leading-[1.7] text-[#5d6168]">
          {loading ? '正在加载状态…' : note}
        </p>

        <div className="mt-6 border-t border-[#e8e8e8] pt-4 space-y-2 text-[13px]">
          <div className="flex justify-between">
            <span className="text-[#686d74]">获取方式</span>
            <span className="text-[#18181b]">{storeName}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-[#686d74]">上架状态</span>
            <span className="text-[#686d74]">{isReady ? '已上架' : '准备中'}</span>
          </div>
        </div>
      </div>

      <div className="mt-7">
        {isReady && url ? (
          <a
            href={url}
            target="_blank"
            rel="noreferrer"
            className="rc-pill-dark w-full"
          >
            <span>{actionText}</span>
            <span aria-hidden="true">↗</span>
          </a>
        ) : (
          <button type="button" disabled className="rc-pill-soft w-full">
            {disabledText}
          </button>
        )}
      </div>
    </article>
  );
}
