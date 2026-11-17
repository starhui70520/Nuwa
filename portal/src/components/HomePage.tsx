import { useEffect, useState } from 'react';
import type { ArticleItem } from '../types';
import { formatDate } from '../utils';

interface HomePageProps {
  articles: ArticleItem[];
  onNavigate: (path: string) => void;
}

interface HeroSlide {
  id: string;
  title: string;
  eyebrow: string;
  titlePrefix: string;
  titleSuffix: string;
  accentColor: string;
  isWide?: boolean;
  description: string;
  image: string;
  imagePosition: string;
  imageAlt: string;
  captionLabel: string;
  captionDetail: string;
  primaryLabel: string;
  primaryHref: string;
  secondaryLabel: string;
  secondaryHref: string;
}

const HERO_SLIDES: HeroSlide[] = [
  {
    id: 'sakaliolabs',
    title: 'Sakalio Labs',
    eyebrow: 'AGENT-GROWN ORGANIZATION',
    titlePrefix: 'Sakalio',
    titleSuffix: 'Labs',
    accentColor: '#159455',
    description:
      '正在自我生长的 Agent 自代理组织，让智能体进入真实软件、开放世界与互动内容，在长期项目中持续研究、协作与交接。',
    image: '/official/sakalio-labs-showcase-v1.png',
    imagePosition: 'center 58%',
    imageAlt: '多个智能体在开放世界与真实项目空间中持续协作的概念场景',
    captionLabel: '正在生长的项目',
    captionDetail: 'FPV 飞行 · Minecraft 智能体 · 物语引擎 · Pivot',
    primaryLabel: '研究成果',
    primaryHref: 'https://github.com/SakalioLabs',
    secondaryLabel: '了解更多',
    secondaryHref: 'https://sakaliolabs.rankchord.com/'
  },
  {
    id: 'fpv-dronecraft',
    title: 'FPV Dronecraft',
    eyebrow: 'MULTIROTOR PHYSICS LABORATORY',
    titlePrefix: 'FPV',
    titleSuffix: 'Dronecraft',
    accentColor: '#d83a36',
    isWide: true,
    description:
      'Minecraft 中的多旋翼与 FPV 飞行实验室，把可游玩的穿越机体验与飞行动力学、遥测、诊断和模型验证结合在一起。',
    image: '/official/project-fpv-v1.webp',
    imagePosition: 'center 50%',
    imageAlt: 'FPV Dronecraft 在 Minecraft 山谷中进行多旋翼飞行的概念场景',
    captionLabel: '可游玩的实验版本',
    captionDetail: '多旋翼飞行 · 遥测 · 诊断 · 模型验证',
    primaryLabel: '项目仓库',
    primaryHref: 'https://github.com/SakalioLabs/FPV-Dronecraft',
    secondaryLabel: '了解 Sakalio',
    secondaryHref: 'https://sakaliolabs.rankchord.com/'
  },
  {
    id: 'singularity',
    title: 'Singularity',
    eyebrow: 'MINECRAFT LLM AGENT',
    titlePrefix: 'Singularity',
    titleSuffix: '',
    accentColor: '#2563eb',
    description:
      '在 Minecraft Java Edition 中由自然语言目标驱动的模块化 LLM Agent，以规划、分层记忆和技能复用为基础，持续探索自主行动与多智能体协作。',
    image: '/official/project-singularity-v1.webp',
    imagePosition: 'center 52%',
    imageAlt: 'Singularity Minecraft LLM Agent 在开放世界中执行建造任务的概念场景',
    captionLabel: '持续进化的模块化智能体',
    captionDetail: '规划 · 分层记忆 · 技能复用 · 多智能体协作',
    primaryLabel: '项目仓库',
    primaryHref: 'https://github.com/SakalioLabs/Singularity',
    secondaryLabel: '了解 Sakalio',
    secondaryHref: 'https://sakaliolabs.rankchord.com/'
  },
  {
    id: 'monogatari',
    title: 'Monogatari',
    eyebrow: 'AI-NATIVE NARRATIVE ENGINE',
    titlePrefix: 'Monogatari',
    titleSuffix: '',
    accentColor: '#d63c7c',
    description:
      '面向 AI 原生视觉小说与文字冒险的开源创作工作台和确定性运行时，让生成式角色与可审计的路线、评分和结局共同驱动互动叙事。',
    image: '/official/project-monogatari-v1.webp',
    imagePosition: 'center 48%',
    imageAlt: 'Monogatari AI 原生叙事引擎的互动故事概念场景',
    captionLabel: 'AI 原生叙事引擎',
    captionDetail: '视觉小说 · 状态机 · 角色扮演',
    primaryLabel: '项目仓库',
    primaryHref: 'https://github.com/SakalioLabs/Monogatari',
    secondaryLabel: '了解 Sakalio',
    secondaryHref: 'https://sakaliolabs.rankchord.com/'
  }
];

export function HomePage({ articles, onNavigate }: HomePageProps) {
  const [activeIndex, setActiveIndex] = useState(0);
  const [paused, setPaused] = useState(false);
  const latestArticles = articles.slice(0, 3);
  const slide = HERO_SLIDES[activeIndex];

  useEffect(() => {
    HERO_SLIDES.forEach((s) => {
      const img = new window.Image();
      img.src = s.image;
    });
  }, []);

  useEffect(() => {
    if (paused) return;
    const timer = window.setInterval(() => {
      setActiveIndex((prev) => (prev + 1) % HERO_SLIDES.length);
    }, 5000);
    return () => window.clearInterval(timer);
  }, [paused, activeIndex]);

  const goPrev = () => {
    setActiveIndex((prev) => (prev - 1 + HERO_SLIDES.length) % HERO_SLIDES.length);
  };

  const goNext = () => {
    setActiveIndex((prev) => (prev + 1) % HERO_SLIDES.length);
  };

  return (
    <div>
      {/* Hero Carousel — 1:1 restored from rankchord.com */}
      <section
        id="sakaliolabs"
        aria-label="成果展示"
        aria-roledescription="carousel"
        onMouseEnter={() => setPaused(true)}
        onMouseLeave={() => setPaused(false)}
        className="site-container pt-[26px] max-[1040px]:pt-[32px] max-[680px]:pt-[22px]"
      >
        <div className="max-w-[1120px] max-[1040px]:max-w-[900px] mx-auto text-center">
          <p className="eyebrow">{slide.eyebrow}</p>

          <h1
            className={`mt-2 font-medium tracking-[-2.2px] max-[680px]:tracking-[-1.6px] leading-none text-[#18181b] ${
              slide.isWide
                ? 'text-[clamp(52px,5.25vw,68px)] max-[680px]:text-[clamp(36px,10.5vw,44px)]'
                : 'text-[clamp(56px,5.95vw,76px)] max-[1040px]:text-[clamp(54px,8.5vw,70px)] max-[680px]:text-[clamp(44px,13.5vw,54px)]'
            }`}
          >
            <span style={{ color: slide.accentColor }}>{slide.titlePrefix}</span>
            {slide.titleSuffix && <> {slide.titleSuffix}</>}
          </h1>

          <p className="mt-3 max-w-[1100px] min-h-[28px] max-[680px]:min-h-[69px] mx-auto text-[16px] max-[680px]:text-[14px] leading-[1.7] max-[680px]:leading-[1.65] text-[#5d6168]">
            {slide.description}
          </p>

          <div className="mt-[18px] flex flex-wrap justify-center gap-[10px]">
            <a
              href={slide.primaryHref}
              target="_blank"
              rel="noopener noreferrer"
              className="rc-pill-dark min-w-[174px]"
            >
              <span>{slide.primaryLabel}</span>
              <span aria-hidden="true">↗</span>
            </a>

            <a
              href={slide.secondaryHref}
              target="_blank"
              rel="noopener noreferrer"
              className="rc-pill-outline min-w-[174px]"
            >
              <span>{slide.secondaryLabel}</span>
              <span aria-hidden="true">↗</span>
            </a>
          </div>
        </div>

        {/* Media Stage with Left/Right Arrows */}
        <div className="relative mt-[26px] max-[680px]:mt-[22px]">
          <figure className="relative rounded-[20px] max-[1040px]:rounded-[14px] overflow-hidden bg-[#eef1ef] m-0">
            <img
              src={slide.image}
              alt={slide.imageAlt}
              style={{ objectPosition: slide.imagePosition }}
              className="w-full aspect-[3.3] max-[1040px]:aspect-[2.2] max-[680px]:aspect-[4/3] object-cover block"
            />
            <figcaption className="absolute bottom-[18px] left-[18px] max-[680px]:bottom-3 max-[680px]:left-3 max-[680px]:max-w-[calc(100%-24px)] inline-flex items-center gap-[18px] rounded-full bg-[#121214]/88 backdrop-blur-md px-[15px] py-[10px] max-[680px]:px-3 max-[680px]:py-[9px] text-[12px] max-[680px]:text-[10.5px] text-white">
              <strong>{slide.captionLabel}</strong>
              <span className="text-white/65 max-[680px]:hidden">{slide.captionDetail}</span>
            </figcaption>
          </figure>

          <button
            type="button"
            aria-label="上一项成果"
            onClick={goPrev}
            className="absolute left-[18px] max-[680px]:left-[10px] top-1/2 -translate-y-1/2 w-[48px] h-[48px] max-[680px]:w-[42px] max-[680px]:h-[42px] rounded-full border border-[#e8e8e8] hover:border-[#cfcfcf] bg-white/92 hover:bg-white backdrop-blur-md shadow-[0_5px_22px_rgba(0,0,0,0.1)] inline-flex items-center justify-center text-[#18181b] text-[16px] transition-colors cursor-pointer"
          >
            ←
          </button>

          <button
            type="button"
            aria-label="下一项成果"
            onClick={goNext}
            className="absolute right-[18px] max-[680px]:right-[10px] top-1/2 -translate-y-1/2 w-[48px] h-[48px] max-[680px]:w-[42px] max-[680px]:h-[42px] rounded-full border border-[#e8e8e8] hover:border-[#cfcfcf] bg-white/92 hover:bg-white backdrop-blur-md shadow-[0_5px_22px_rgba(0,0,0,0.1)] inline-flex items-center justify-center text-[#18181b] text-[16px] transition-colors cursor-pointer"
          >
            →
          </button>
        </div>

        {/* 4 Progress Indicator Bars */}
        <div
          role="tablist"
          aria-label="成果轮播切换"
          className="max-w-[520px] mx-auto mt-[13px] mb-[74px] max-[680px]:mt-2 max-[680px]:mb-[60px] grid grid-cols-4 gap-[10px] max-[680px]:gap-[7px]"
        >
          {HERO_SLIDES.map((item, idx) => {
            const isActive = idx === activeIndex;
            return (
              <button
                key={item.id}
                type="button"
                role="tab"
                aria-selected={isActive}
                aria-label={item.title}
                onClick={() => setActiveIndex(idx)}
                className="py-2 cursor-pointer group"
              >
                <span className="block h-[3px] max-[680px]:h-[2px] w-full rounded-full bg-[#d4d4d4] overflow-hidden">
                  <span
                    className={`block h-full rounded-full transition-colors ${
                      isActive ? 'bg-[#18181b]' : 'bg-transparent group-hover:bg-[#a1a1aa]'
                    }`}
                  />
                </span>
              </button>
            );
          })}
        </div>
      </section>

      {/* Latest Research — 1:1 restored from rankchord.com, backed by MinIO /api/articles */}
      <section className="border-b border-[#e8e8e8] py-[126px] pb-[150px] max-[680px]:py-[88px] max-[680px]:pb-[104px]">
        <div className="site-container">
          <div className="flex flex-col min-[680px]:flex-row justify-between items-start min-[680px]:items-end gap-6 mb-[56px] max-[680px]:mb-[40px]">
            <div>
              <p className="eyebrow">RESEARCH</p>
              <h2 className="mt-[14px] text-[52px] max-[680px]:text-[40px] font-medium leading-[1.05] text-[#18181b]">
                最新研究
              </h2>
            </div>

            <button
              type="button"
              onClick={() => onNavigate('/research')}
              className="rc-text-link"
            >
              <span>查看全部</span>
              <span aria-hidden="true">↗</span>
            </button>
          </div>

          <div className="grid grid-cols-1 min-[681px]:grid-cols-2 min-[1041px]:grid-cols-3 gap-[28px]">
            {latestArticles.map((article) => (
              <article
                key={article.id}
                className="rounded-[18px] border border-[#e8e8e8] bg-white p-[12px_12px_22px] flex flex-col"
              >
                <button
                  type="button"
                  onClick={() => onNavigate(`/research/${encodeURIComponent(article.slug)}`)}
                  className="block w-full rounded-[12px] overflow-hidden bg-[#f6f6f6] text-left cursor-pointer group"
                >
                  {article.coverUrl ? (
                    <img
                      src={article.coverUrl}
                      alt={article.title}
                      className="w-full aspect-video object-cover transition-transform duration-300 group-hover:scale-[1.015]"
                    />
                  ) : (
                    <div className="w-full aspect-video flex items-center justify-center bg-[#f6f6f6] text-[12px] font-mono text-[#686d74]">
                      {article.slug}
                    </div>
                  )}
                </button>

                <div className="mt-[22px] px-1 flex items-start justify-between gap-3 text-[12px] text-[#686d74]">
                  <div className="flex flex-wrap gap-1.5">
                    {article.tags.map((tag) => (
                      <span key={tag} className="rc-tag">
                        {tag}
                      </span>
                    ))}
                  </div>
                  <time className="shrink-0 font-mono">
                    {formatDate(article.publishedAt).split(' ')[0].replace(/\//g, '-')}
                  </time>
                </div>

                <h3 className="mt-4 mx-1 text-[23px] font-medium leading-[1.45] text-[#18181b]">
                  <button
                    type="button"
                    onClick={() => onNavigate(`/research/${encodeURIComponent(article.slug)}`)}
                    className="text-left hover:opacity-70 transition-opacity cursor-pointer"
                  >
                    {article.title}
                  </button>
                </h3>

                <p className="mt-4 mx-1 mb-7 text-[14px] leading-[1.75] text-[#5d6168]">
                  {article.summary}
                </p>

                <button
                  type="button"
                  onClick={() => onNavigate(`/research/${encodeURIComponent(article.slug)}`)}
                  className="mt-auto ml-auto mr-1 inline-flex items-center justify-center gap-1.5 min-w-[146px] min-h-[44px] px-[18px] py-[10px] rounded-full bg-[#f6f6f6] hover:bg-[#e8e8e8] text-[13px] font-medium text-[#18181b] transition-colors cursor-pointer"
                >
                  <span>阅读更多</span>
                  <span aria-hidden="true">›</span>
                </button>
              </article>
            ))}
          </div>
        </div>
      </section>

      {/* Company Intro — 1:1 restored from rankchord.com */}
      <section className="pt-[94px] pb-[108px] max-[680px]:py-[72px_88px]">
        <div className="site-container grid grid-cols-1 min-[1041px]:grid-cols-[minmax(330px,0.72fr)_minmax(0,1.28fr)] items-start gap-[clamp(52px,6vw,96px)] max-[680px]:gap-[32px]">
          <div>
            <p className="eyebrow">COMPANY</p>
            <h2 className="mt-[21px] max-[680px]:mt-4 text-[clamp(60px,5.4vw,76px)] max-[680px]:text-[50px] font-medium tracking-[-1.5px] max-[680px]:tracking-[-1.2px] leading-none text-[#18181b]">
              RankChord
            </h2>
            <p className="mt-[30px] max-[680px]:mt-[22px] text-[14px] max-[680px]:text-[13px] leading-[1.65] text-[#686d74]">
              General intelligence systems,
              <br />
              built for real work.
            </p>
          </div>

          <div className="max-w-[680px] min-[1041px]:pt-[39px]">
            <p className="text-[clamp(19px,1.45vw,22px)] max-[680px]:text-[18px] font-normal tracking-[-0.2px] leading-[1.65] max-[680px]:leading-[1.7] text-[#18181b] m-0">
              RankChord 是一家专注于通用人工智能系统研发的科技公司。自 2023 年成立以来，我们持续研究智能体在长程任务中的理解、行动、记忆、协同与交接能力，致力于推动通用人工智能（AGI）的发展。
            </p>

            <div className="mt-[38px] max-[680px]:mt-[30px] border-t border-[#e8e8e8] pt-[29px] max-[680px]:pt-[24px] max-w-[660px] text-[15px] max-[680px]:text-[14px] leading-[1.85] max-[680px]:leading-[1.8] text-[#4b4f55] space-y-[18px]">
              <p className="m-0">
                RankChord 正在快速发展并即将推出语言模型 Chord A1。它面向 Agent 与对话任务，重点探索复杂问题的理解与推理能力。基于 Chord A1，我们计划推出 OpenPivot 智能体系统。它以人与 Agent 都是协作系统中的第一公民为设计起点，让这些能力进入真实软件、开放世界和互动内容项目中，而不是停留在一次对话或预设演示中。
              </p>
              <p className="m-0">
                Sakalio Labs 是这一方向的研究与实践：人可以理解 Agent 为何行动、在关键节点参与判断，并在需要时顺畅接手。这也构成了 Sakalio Labs 成立之初的方向。
              </p>

              <div className="pt-[12px]">
                <button
                  type="button"
                  onClick={() => onNavigate('/about')}
                  className="rc-text-link"
                >
                  <span>了解 RankChord</span>
                  <span aria-hidden="true">↗</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
