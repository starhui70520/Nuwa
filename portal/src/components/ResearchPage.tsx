import { useMemo, useState } from 'react';
import { marked } from 'marked';
import type { ArticleItem } from '../types';
import { formatDate } from '../utils';

interface ResearchListPageProps {
  articles: ArticleItem[];
  loading: boolean;
  onNavigate: (path: string) => void;
}

export function ResearchListPage({ articles, loading, onNavigate }: ResearchListPageProps) {
  const [activeTag, setActiveTag] = useState<string>('all');

  const allTags = useMemo(() => {
    const set = new Set<string>();
    for (const a of articles) {
      for (const t of a.tags) set.add(t);
    }
    return Array.from(set);
  }, [articles]);

  const filtered =
    activeTag === 'all' ? articles : articles.filter((a) => a.tags.includes(activeTag));

  return (
    <div className="site-container pb-[104px]">
      <section className="pt-[76px] pb-[56px] max-[680px]:pt-[48px] max-[680px]:pb-[40px]">
        <p className="eyebrow">RESEARCH &amp; UPDATES</p>
        <h1 className="mt-4 text-[clamp(42px,5vw,64px)] font-medium tracking-[-1.8px] leading-[1.05] text-[#18181b]">
          研究与技术发布
        </h1>
        <p className="mt-4 max-w-[620px] text-[15px] leading-[1.7] text-[#5d6168]">
          记录 RankChord 在语言模型、智能体协同、物理仿真与跨端客户端工程上的最新进展。
        </p>

        {allTags.length > 0 && (
          <div className="mt-7 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => setActiveTag('all')}
              className={`h-[34px] px-4 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
                activeTag === 'all'
                  ? 'bg-[#18181b] text-white'
                  : 'bg-[#f6f6f6] text-[#18181b] hover:bg-[#e8e8e8]'
              }`}
            >
              全部 ({articles.length})
            </button>
            {allTags.map((tag) => (
              <button
                key={tag}
                type="button"
                onClick={() => setActiveTag(tag)}
                className={`h-[34px] px-4 rounded-full text-[13px] font-medium transition-colors cursor-pointer ${
                  activeTag === tag
                    ? 'bg-[#18181b] text-white'
                    : 'bg-[#f6f6f6] text-[#18181b] hover:bg-[#e8e8e8]'
                }`}
              >
                {tag}
              </button>
            ))}
          </div>
        )}
      </section>

      {loading ? (
        <div className="border-t border-[#e8e8e8] py-12 text-[14px] text-[#686d74]">
          正在加载文章列表…
        </div>
      ) : filtered.length === 0 ? (
        <div className="border-t border-b border-[#e8e8e8] py-12 text-[14px] text-[#5d6168]">
          暂无符合条件的文章。
        </div>
      ) : (
        <div className="border-b border-[#e8e8e8]">
          {filtered.map((article) => (
            <article
              key={article.id}
              className="border-t border-[#e8e8e8] py-[34px] grid grid-cols-1 min-[820px]:grid-cols-[180px_minmax(0,1fr)_160px] items-start gap-6"
            >
              <time className="font-mono text-[13px] text-[#686d74] pt-1">
                {formatDate(article.publishedAt).split(' ')[0]}
              </time>

              <div>
                <div className="flex flex-wrap gap-1.5 mb-3">
                  {article.tags.map((tag) => (
                    <span key={tag} className="rc-tag">
                      {tag}
                    </span>
                  ))}
                </div>
                <h2 className="text-[24px] font-medium leading-[1.35] text-[#18181b]">
                  <button
                    type="button"
                    onClick={() => onNavigate(`/research/${encodeURIComponent(article.slug)}`)}
                    className="text-left hover:opacity-65 transition-opacity cursor-pointer"
                  >
                    {article.title}
                  </button>
                </h2>
                <p className="mt-3 text-[14px] leading-[1.75] text-[#5d6168]">
                  {article.summary}
                </p>
              </div>

              <div className="min-[820px]:text-right pt-1">
                <button
                  type="button"
                  onClick={() => onNavigate(`/research/${encodeURIComponent(article.slug)}`)}
                  className="rc-text-link"
                >
                  <span>阅读全文</span>
                  <span aria-hidden="true">›</span>
                </button>
              </div>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}

interface ResearchDetailPageProps {
  slug: string;
  articles: ArticleItem[];
  onNavigate: (path: string) => void;
}

export function ResearchDetailPage({ slug, articles, onNavigate }: ResearchDetailPageProps) {
  const article = articles.find((a) => a.slug === slug || a.id === slug);

  if (!article) {
    return (
      <div className="site-container py-[96px]">
        <p className="eyebrow">404</p>
        <h1 className="mt-3 text-[36px] font-medium text-[#18181b]">文章不存在或未发布</h1>
        <button
          type="button"
          onClick={() => onNavigate('/research')}
          className="mt-6 rc-text-link"
        >
          <span>返回研究列表</span>
          <span aria-hidden="true">←</span>
        </button>
      </div>
    );
  }

  const html = marked.parse(article.content || '', { async: false }) as string;

  return (
    <article className="site-container pb-[104px]">
      <header className="max-w-[820px] mx-auto pt-[58px] pb-[44px] border-b border-[#e8e8e8]">
        <button
          type="button"
          onClick={() => onNavigate('/research')}
          className="text-[13px] text-[#686d74] hover:text-[#18181b] transition-colors cursor-pointer"
        >
          ← 返回全部研究
        </button>

        <div className="mt-8 flex flex-wrap items-center gap-2">
          {article.tags.map((tag) => (
            <span key={tag} className="rc-tag">
              {tag}
            </span>
          ))}
        </div>

        <h1 className="mt-5 text-[clamp(32px,4vw,48px)] font-medium tracking-[-1.2px] leading-[1.15] text-[#18181b]">
          {article.title}
        </h1>

        {article.summary && (
          <p className="mt-5 text-[17px] leading-[1.7] text-[#5d6168]">{article.summary}</p>
        )}

        <div className="mt-6 flex flex-wrap items-center gap-4 text-[13px] text-[#686d74]">
          <span>作者：{article.author || 'RankChord Team'}</span>
          <span>·</span>
          <time className="font-mono">{formatDate(article.publishedAt).split(' ')[0]}</time>
        </div>
      </header>

      {article.coverUrl && (
        <div className="max-w-[960px] mx-auto mt-10">
          <img
            src={article.coverUrl}
            alt={article.title}
            className="w-full rounded-[14px] border border-[#e8e8e8] object-cover max-h-[520px]"
          />
        </div>
      )}

      <div
        className="research-article-body max-w-[760px] mx-auto pt-[48px]"
        dangerouslySetInnerHTML={{ __html: html }}
      />
    </article>
  );
}
