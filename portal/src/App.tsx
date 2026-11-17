import { useCallback, useEffect, useState } from 'react';
import { ArrowUpRight, Settings2 } from 'lucide-react';
import { AdminPanel } from './components/AdminPanel';
import { PublicPortal } from './components/PublicPortal';
import type { PublicReleasesResponse } from './types';

type ViewMode = 'public' | 'admin';

export function App() {
  const [view, setView] = useState<ViewMode>(() =>
    window.location.pathname.startsWith('/admin') ? 'admin' : 'public'
  );
  const [data, setData] = useState<PublicReleasesResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadPublicReleases = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/api/releases');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = (await res.json()) as PublicReleasesResponse;
      setData(json);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadPublicReleases();
  }, [loadPublicReleases]);

  useEffect(() => {
    const onPopState = () => {
      setView(window.location.pathname.startsWith('/admin') ? 'admin' : 'public');
    };
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  const navigate = (next: ViewMode) => {
    const targetPath = next === 'admin' ? '/admin' : '/';
    if (window.location.pathname !== targetPath) {
      window.history.pushState({}, '', targetPath);
    }
    setView(next);
  };

  return (
    <div className="min-h-screen bg-[#09090b] bg-grid-pattern text-zinc-100 flex flex-col">
      {/* Header */}
      <header className="sticky top-0 z-30 border-b border-white/10 bg-[#09090b]/80 backdrop-blur-md">
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
          <button
            type="button"
            onClick={() => navigate('public')}
            className="flex items-center gap-3 text-left"
          >
            <img src="/logo.png" alt="Nuwa Logo" className="h-8 w-8 rounded-lg object-cover" />
            <div className="flex items-baseline gap-2">
              <span className="text-base font-semibold tracking-tight text-white">Nuwa</span>
              <span className="hidden text-xs text-zinc-500 sm:inline">by RankChord</span>
            </div>
          </button>

          <nav className="flex items-center gap-2 sm:gap-4 text-xs sm:text-sm">
            <a
              href="https://rankchord.com/"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1 rounded-lg px-2.5 py-1.5 text-zinc-300 transition hover:bg-white/5 hover:text-white"
            >
              <span>RankChord 官网</span>
              <ArrowUpRight className="h-3.5 w-3.5 text-zinc-400" />
            </a>

            {view === 'admin' ? (
              <button
                type="button"
                onClick={() => navigate('public')}
                className="rounded-lg border border-white/15 bg-white/5 px-3 py-1.5 text-xs font-medium text-white hover:bg-white/10"
              >
                返回下载页
              </button>
            ) : (
              <button
                type="button"
                onClick={() => navigate('admin')}
                className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-300 transition hover:border-white/25 hover:text-white"
              >
                <Settings2 className="h-3.5 w-3.5" />
                <span>发布管理</span>
              </button>
            )}
          </nav>
        </div>
      </header>

      {/* Main */}
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 pb-20 sm:px-6">
        {view === 'admin' ? (
          <AdminPanel onDataChanged={loadPublicReleases} />
        ) : (
          <PublicPortal
            data={data}
            loading={loading}
            error={error}
            onRefresh={loadPublicReleases}
          />
        )}
      </main>

      {/* Footer */}
      <footer className="border-t border-white/10 bg-[#09090b]/90 py-6">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-3 px-4 text-xs text-zinc-500 sm:flex-row sm:px-6">
          <span>© {new Date().getFullYear()} RankChord（广州秩弦科技有限公司）· Nuwa App Distribution</span>
          <div className="flex items-center gap-4">
            <a href="https://rankchord.com/" target="_blank" rel="noreferrer" className="hover:text-zinc-300">
              rankchord.com
            </a>
            <span>MinIO Object Storage Powered</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
