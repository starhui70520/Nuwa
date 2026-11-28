import { useCallback, useEffect, useRef, useState } from 'react';
import { AboutPage } from './components/AboutPage';
import { AdminPanel } from './components/AdminPanel';
import { HomePage } from './components/HomePage';
import { NuwaPrivacyPage } from './components/NuwaPrivacyPage';
import { PublicPortal } from './components/PublicPortal';
import { ResearchDetailPage, ResearchListPage } from './components/ResearchPage';
import type { ArticleItem, PublicReleasesResponse } from './types';

export function App() {
  const [pathname, setPathname] = useState<string>(() => window.location.pathname || '/');
  const [releasesData, setReleasesData] = useState<PublicReleasesResponse | null>(null);
  const [articles, setArticles] = useState<ArticleItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [openMenu, setOpenMenu] = useState<'models' | 'results' | null>(null);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const navRef = useRef<HTMLDivElement>(null);

  const loadAllPublicData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [relRes, artRes] = await Promise.all([fetch('/api/releases'), fetch('/api/articles')]);
      if (!relRes.ok) throw new Error(`HTTP ${relRes.status}`);
      const relJson = (await relRes.json()) as PublicReleasesResponse;
      setReleasesData(relJson);

      if (artRes.ok) {
        const artJson = (await artRes.json()) as { articles: ArticleItem[] };
        setArticles(artJson.articles || []);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAllPublicData();
  }, [loadAllPublicData]);

  useEffect(() => {
    const onPopState = () => {
      setPathname(window.location.pathname || '/');
      setOpenMenu(null);
      setMobileMenuOpen(false);
    };
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  useEffect(() => {
    const onClickOutside = (e: MouseEvent) => {
      if (navRef.current && !navRef.current.contains(e.target as Node)) {
        setOpenMenu(null);
      }
    };
    document.addEventListener('mousedown', onClickOutside);
    return () => document.removeEventListener('mousedown', onClickOutside);
  }, []);

  const navigate = (nextPath: string) => {
    const [pathOnly, hash] = nextPath.split('#');
    const cleanPath = pathOnly || '/';
    if (window.location.pathname !== cleanPath || hash) {
      window.history.pushState({}, '', nextPath);
    }
    setPathname(cleanPath);
    setOpenMenu(null);
    setMobileMenuOpen(false);

    if (hash) {
      setTimeout(() => {
        document.getElementById(hash)?.scrollIntoView({ behavior: 'smooth' });
      }, 60);
    } else {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  };

  const isAdmin = pathname.startsWith('/admin');
  const isNuwaPrivacy =
    pathname === '/nuwa/privacy' || pathname === '/nuwa/privacy/' || pathname === '/privacy';
  const isNuwa =
    !isNuwaPrivacy && (pathname.startsWith('/nuwa') || pathname.startsWith('/download'));
  const isAbout = pathname.startsWith('/about');
  const isResearchDetail =
    pathname.startsWith('/research/') && pathname.length > '/research/'.length;
  const isResearchList = pathname === '/research';
  const researchSlug = isResearchDetail
    ? decodeURIComponent(pathname.slice('/research/'.length))
    : '';

  useEffect(() => {
    if (isAdmin) {
      document.title = '管理后台 | RankChord';
    } else if (isNuwaPrivacy) {
      document.title = 'Nuwa 隐私政策 | RankChord';
    } else if (isNuwa) {
      document.title = 'Nuwa 客户端下载 | RankChord';
    } else if (isAbout) {
      document.title = '关于我们 | RankChord';
    } else if (isResearchDetail) {
      const matched = articles.find((a) => a.slug === researchSlug);
      document.title = matched ? `${matched.title} | RankChord` : '研究 | RankChord';
    } else if (isResearchList) {
      document.title = '研究 | RankChord';
    } else {
      document.title = 'RankChord | 通用人工智能系统';
    }
    const iconLink = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (iconLink) {
      const useNuwaIcon = isNuwa || isNuwaPrivacy;
      iconLink.type = useNuwaIcon ? 'image/png' : 'image/svg+xml';
      iconLink.href = useNuwaIcon ? '/logo.png' : '/rankchord-favicon.svg';
    }
  }, [
    articles,
    isAbout,
    isAdmin,
    isNuwa,
    isNuwaPrivacy,
    isResearchDetail,
    isResearchList,
    researchSlug
  ]);

  return (
    <div className="min-h-screen flex flex-col bg-white text-[#18181b]">
      {/* Header — 1:1 restored from rankchord.com + Nuwa added under 成果 */}
      <header className="sticky top-0 z-[100] h-[78px] max-[860px]:h-[64px] max-[680px]:h-[56px] bg-white/96 backdrop-blur-sm">
        <div ref={navRef} className="header-shell h-full flex items-center relative">
          <button
            type="button"
            onClick={() => navigate('/')}
            aria-label="RankChord 首页"
            className="mr-[34px] inline-flex items-center cursor-pointer"
          >
            <img
              src="/rankchord-logo-light.svg"
              alt="RankChord"
              className="h-[32px] max-[680px]:h-[28px] w-auto block"
            />
          </button>

          {/* Desktop Nav */}
          <nav aria-label="主导航" className="hidden min-[861px]:flex items-center gap-1">
            {/* 模型 Dropdown */}
            <div className="relative">
              <button
                type="button"
                aria-haspopup="true"
                aria-expanded={openMenu === 'models'}
                onClick={() => setOpenMenu((m) => (m === 'models' ? null : 'models'))}
                className={`h-10 px-[14px] rounded-full inline-flex items-center gap-2 text-[15px] font-medium leading-none transition-colors cursor-pointer ${
                  openMenu === 'models' ? 'bg-[#f6f6f6]' : 'hover:bg-[#f6f6f6]'
                }`}
              >
                <span>模型</span>
                <span
                  aria-hidden="true"
                  className={`w-[5px] h-[5px] border-b border-r border-current transition-transform ${
                    openMenu === 'models' ? 'rotate-[225deg] translate-y-[1px]' : 'rotate-45 -translate-y-[1px]'
                  }`}
                />
              </button>

              {openMenu === 'models' && (
                <div className="absolute left-0 top-[52px] w-[420px] rounded-[20px] border border-[#e8e8e8] bg-white p-[22px] shadow-[0_18px_50px_rgba(24,24,27,0.09)] z-50">
                  <p className="text-[12px] font-medium text-[#686d74] mb-3">语言模型</p>
                  <button
                    type="button"
                    onClick={() => navigate('/about#chord-a1')}
                    className="w-full flex items-center justify-between rounded-[14px] p-3 text-left hover:bg-[#f6f6f6] transition-colors cursor-pointer"
                  >
                    <span>
                      <strong className="block text-[15px] font-medium text-[#18181b]">
                        Chord A1
                      </strong>
                      <small className="block text-[13px] text-[#686d74] mt-0.5">
                        面向对话与智能体任务
                      </small>
                    </span>
                    <em className="not-italic text-[12px] text-[#686d74] rounded-full bg-[#f6f6f6] px-2.5 py-1">
                      即将推出
                    </em>
                  </button>
                </div>
              )}
            </div>

            {/* 成果 Dropdown (Sakalio Labs, Pivot, Nuwa) */}
            <div className="relative">
              <button
                type="button"
                aria-haspopup="true"
                aria-expanded={openMenu === 'results'}
                onClick={() => setOpenMenu((m) => (m === 'results' ? null : 'results'))}
                className={`h-10 px-[14px] rounded-full inline-flex items-center gap-2 text-[15px] font-medium leading-none transition-colors cursor-pointer ${
                  openMenu === 'results' ? 'bg-[#f6f6f6]' : 'hover:bg-[#f6f6f6]'
                }`}
              >
                <span>成果</span>
                <span
                  aria-hidden="true"
                  className={`w-[5px] h-[5px] border-b border-r border-current transition-transform ${
                    openMenu === 'results' ? 'rotate-[225deg] translate-y-[1px]' : 'rotate-45 -translate-y-[1px]'
                  }`}
                />
              </button>

              {openMenu === 'results' && (
                <div className="absolute left-0 top-[52px] w-[460px] rounded-[20px] border border-[#e8e8e8] bg-white p-[22px] shadow-[0_18px_50px_rgba(24,24,27,0.09)] z-50">
                  <p className="text-[12px] font-medium text-[#686d74] mb-3">成果</p>
                  <div className="space-y-1">
                    <button
                      type="button"
                      onClick={() => navigate('/#sakaliolabs')}
                      className="w-full block rounded-[14px] p-3 text-left hover:bg-[#f6f6f6] transition-colors cursor-pointer"
                    >
                      <strong className="block text-[15px] font-medium text-[#18181b]">
                        <span className="text-[#159455]">Sakalio</span> Labs
                      </strong>
                      <small className="block text-[13px] text-[#686d74] mt-0.5">
                        智能体研究与真实项目实践
                      </small>
                    </button>

                    <button
                      type="button"
                      onClick={() => navigate('/about#openpivot')}
                      className="w-full block rounded-[14px] p-3 text-left hover:bg-[#f6f6f6] transition-colors cursor-pointer"
                    >
                      <strong className="block text-[15px] font-medium text-[#18181b]">
                        Pivot
                      </strong>
                      <small className="block text-[13px] text-[#686d74] mt-0.5">
                        面向人机协作的智能体系统
                      </small>
                    </button>

                    <button
                      type="button"
                      onClick={() => navigate('/nuwa')}
                      className="w-full flex items-center justify-between rounded-[14px] p-3 text-left hover:bg-[#f6f6f6] transition-colors cursor-pointer"
                    >
                      <span className="flex items-center gap-3">
                        <img
                          src="/logo.png"
                          alt=""
                          className="w-8 h-8 rounded-[8px] border border-[#e8e8e8] object-cover shrink-0"
                        />
                        <span>
                          <strong className="block text-[15px] font-medium text-[#18181b]">
                            Nuwa
                          </strong>
                          <small className="block text-[13px] text-[#686d74] mt-0.5">
                            跨端 AI 客户端与版本分发中心
                          </small>
                        </span>
                      </span>
                      <span className="text-[12px] text-[#686d74]">下载 →</span>
                    </button>
                  </div>
                </div>
              )}
            </div>

            <a
              href="https://rankai.rankchord.com/status"
              target="_blank"
              rel="noreferrer"
              className="h-10 px-[14px] rounded-full inline-flex items-center text-[15px] font-medium leading-none text-[#18181b] hover:bg-[#f6f6f6] transition-colors"
            >
              API
            </a>

            <button
              type="button"
              onClick={() => navigate('/research')}
              className="h-10 px-[14px] rounded-full inline-flex items-center text-[15px] font-medium leading-none text-[#18181b] hover:bg-[#f6f6f6] transition-colors cursor-pointer"
            >
              研究
            </button>

            <button
              type="button"
              onClick={() => navigate('/about')}
              className="h-10 px-[14px] rounded-full inline-flex items-center text-[15px] font-medium leading-none text-[#18181b] hover:bg-[#f6f6f6] transition-colors cursor-pointer"
            >
              关于
            </button>
          </nav>

          {/* Desktop Right Actions */}
          <div className="hidden min-[861px]:flex ml-auto items-center gap-[10px]">
            <a
              href="https://rankai.rankchord.com/login"
              target="_blank"
              rel="noreferrer"
              className="min-w-[74px] min-h-[44px] px-[20px] py-[10px] rounded-full bg-[#f6f6f6] hover:bg-[#e8e8e8] inline-flex items-center justify-center text-[14px] font-medium leading-none text-[#18181b] transition-colors"
            >
              登录
            </a>
            <a
              href="https://pivot.rankchord.com/login"
              target="_blank"
              rel="noreferrer"
              className="min-h-[44px] px-[21px] py-[10px] rounded-full bg-[#18181b] hover:bg-[#313131] inline-flex items-center justify-center gap-2 text-[14px] font-medium leading-none text-white transition-colors"
            >
              <span>试用 Pivot</span>
              <span aria-hidden="true">↗</span>
            </a>
          </div>

          {/* Mobile Menu Toggle */}
          <button
            type="button"
            aria-label="打开导航菜单"
            onClick={() => setMobileMenuOpen((v) => !v)}
            className="min-[861px]:hidden ml-auto w-[44px] h-[44px] rounded-full bg-[#f6f6f6] inline-flex flex-col items-center justify-center gap-[5px] cursor-pointer"
          >
            <span className="w-[18px] h-[1px] bg-[#18181b] block" />
            <span className="w-[18px] h-[1px] bg-[#18181b] block" />
          </button>
        </div>
      </header>

      {/* Mobile Drawer (outside <header> so fixed positioning uses viewport, not backdrop-blur containing block) */}
      {mobileMenuOpen && (
        <div className="min-[861px]:hidden fixed inset-x-0 top-[64px] max-[680px]:top-[56px] bottom-0 bg-white border-t border-[#e8e8e8] p-6 space-y-5 overflow-y-auto z-[99]">
          <div className="space-y-1">
            <p className="eyebrow px-2">模型</p>
            <button
              type="button"
              onClick={() => navigate('/about#chord-a1')}
              className="w-full flex items-center justify-between px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              <span>Chord A1</span>
              <span className="text-[12px] text-[#686d74]">即将推出</span>
            </button>
          </div>

          <div className="border-t border-[#e8e8e8] pt-4 space-y-1">
            <p className="eyebrow px-2">成果</p>
            <button
              type="button"
              onClick={() => navigate('/#sakaliolabs')}
              className="w-full text-left px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              <span className="text-[#159455]">Sakalio</span> Labs
            </button>
            <button
              type="button"
              onClick={() => navigate('/about#openpivot')}
              className="w-full text-left px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              Pivot
            </button>
            <button
              type="button"
              onClick={() => navigate('/nuwa')}
              className="w-full flex items-center justify-between px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              <span>Nuwa 客户端</span>
              <span className="text-[12px] text-[#686d74]">下载 →</span>
            </button>
          </div>

          <div className="border-t border-[#e8e8e8] pt-4 space-y-1">
            <a
              href="https://rankai.rankchord.com/status"
              target="_blank"
              rel="noreferrer"
              className="block px-2 py-2.5 text-[16px] font-medium text-[#18181b]"
            >
              API
            </a>
            <button
              type="button"
              onClick={() => navigate('/research')}
              className="w-full text-left px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              研究
            </button>
            <button
              type="button"
              onClick={() => navigate('/about')}
              className="w-full text-left px-2 py-2.5 text-[16px] font-medium text-[#18181b] cursor-pointer"
            >
              关于
            </button>
          </div>

          <div className="pt-2 pb-8 flex gap-3">
            <a
              href="https://rankai.rankchord.com/login"
              target="_blank"
              rel="noreferrer"
              className="rc-pill-soft flex-1"
            >
              登录
            </a>
            <a
              href="https://pivot.rankchord.com/login"
              target="_blank"
              rel="noreferrer"
              className="rc-pill-dark flex-1"
            >
              试用 Pivot ↗
            </a>
          </div>
        </div>
      )}

      {/* Main Content */}
      <main id="main-content" className="flex-1">
        {isAdmin ? (
          <AdminPanel onDataChanged={loadAllPublicData} />
        ) : isNuwaPrivacy ? (
          <NuwaPrivacyPage onNavigate={navigate} />
        ) : isNuwa ? (
          <PublicPortal
            data={releasesData}
            loading={loading}
            error={error}
            onRefresh={loadAllPublicData}
            onOpenAdmin={() => navigate('/admin')}
          />
        ) : isAbout ? (
          <AboutPage onNavigate={navigate} />
        ) : isResearchList ? (
          <ResearchListPage articles={articles} loading={loading} onNavigate={navigate} />
        ) : isResearchDetail ? (
          <ResearchDetailPage slug={researchSlug} articles={articles} onNavigate={navigate} />
        ) : (
          <HomePage articles={articles} onNavigate={navigate} />
        )}
      </main>

      {/* Footer — 1:1 restored from rankchord.com */}
      <footer className="border-t border-[#e8e8e8] bg-white">
        <div className="site-container">
          <div className="flex flex-col min-[681px]:flex-row justify-between items-start gap-12 min-h-[172px] pt-[40px] pb-[38px]">
            <div>
              <button
                type="button"
                onClick={() => navigate('/')}
                className="inline-flex items-center gap-2 cursor-pointer"
              >
                <img
                  src="/rankchord-logo-light.svg"
                  alt="RankChord"
                  className="h-[32px] w-auto block"
                />
              </button>
              <p className="mt-[18px] text-[12px] text-[#686d74]">
                General intelligence systems, built for real work.
              </p>
            </div>

            <nav
              aria-label="页脚导航"
              className="flex flex-wrap gap-x-[28px] gap-y-3 text-[13px] text-[#18181b]"
            >
              <button
                type="button"
                onClick={() => navigate('/research')}
                className="hover:opacity-55 transition-opacity cursor-pointer"
              >
                研究
              </button>
              <button
                type="button"
                onClick={() => navigate('/about')}
                className="hover:opacity-55 transition-opacity cursor-pointer"
              >
                关于
              </button>
              <button
                type="button"
                onClick={() => navigate('/nuwa')}
                className="hover:opacity-55 transition-opacity cursor-pointer"
              >
                Nuwa
              </button>
              <button
                type="button"
                onClick={() => navigate('/nuwa/privacy')}
                className="hover:opacity-55 transition-opacity cursor-pointer"
              >
                隐私政策
              </button>
              <a
                href="https://github.com/RankChord"
                target="_blank"
                rel="noreferrer"
                className="hover:opacity-55 transition-opacity"
              >
                GitHub ↗
              </a>
              <a
                href="https://rankai.rankchord.com"
                target="_blank"
                rel="noreferrer"
                className="hover:opacity-55 transition-opacity"
              >
                秩算平台 ↗
              </a>
              <button
                type="button"
                onClick={() => navigate('/admin')}
                className="text-[#686d74] hover:opacity-55 transition-opacity cursor-pointer"
              >
                管理
              </button>
            </nav>
          </div>

          <div className="border-t border-[#e8e8e8] pt-[20px] pb-[38px] flex flex-col min-[681px]:flex-row justify-between gap-2 min-[681px]:gap-8 text-[12px] text-[#686d74]">
            <p className="m-0">
              © 2026 广州秩弦科技有限公司（Canton RankChord）. All Rights Reserved.
            </p>
            <div className="flex flex-wrap gap-[22px]">
              <span>HarmonyOS Sans</span>
              <a
                href="https://beian.miit.gov.cn/"
                target="_blank"
                rel="noreferrer"
                className="hover:text-[#18181b] transition-colors"
              >
                粤ICP备2026010599号
              </a>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}
