interface AboutPageProps {
  onNavigate: (path: string) => void;
}

export function AboutPage({ onNavigate }: AboutPageProps) {
  return (
    <div className="bg-white">
      <section className="site-container text-center pt-[82px] pb-[80px] max-[680px]:pt-[56px] max-[680px]:pb-[58px]">
        <p className="eyebrow">ABOUT RANKCHORD</p>
        <h1 className="mt-4 text-[clamp(56px,5.95vw,76px)] max-[680px]:text-[44px] font-medium tracking-[-2.2px] max-[680px]:tracking-[-1.2px] leading-none text-[#18181b]">
          关于我们
        </h1>
        <p className="mt-[26px] text-[15px] max-[680px]:text-[13px] leading-[1.7] text-[#686d74]">
          General intelligence systems, built for real work.
        </p>
      </section>

      <section className="border-t border-[#e8e8e8]">
        <div className="site-container grid grid-cols-1 min-[1041px]:grid-cols-[minmax(330px,0.72fr)_minmax(0,1.28fr)] items-start gap-[clamp(52px,6vw,96px)] pt-[96px] pb-[112px]">
          <div>
            <p className="eyebrow">FOCUS AREAS</p>
            <h2 className="mt-[21px] max-w-[380px] text-[clamp(40px,4vw,52px)] font-medium tracking-[-1.2px] leading-[1.12] text-[#18181b]">
              核心研发方向
            </h2>
          </div>

          <div className="max-w-[760px]">
            <article
              id="chord-a1"
              className="border-t border-[#e8e8e8] py-[32px] grid grid-cols-1 min-[681px]:grid-cols-[minmax(210px,0.7fr)_minmax(0,1.3fr)] gap-8 scroll-mt-[110px]"
            >
              <div>
                <p className="text-[11px] font-semibold tracking-[1px] text-[#686d74] m-0">
                  <span className="inline-block w-[34px] text-[#18181b]">01</span>
                  FOUNDATION MODEL
                </p>
                <h3 className="mt-[18px] text-[27px] font-medium tracking-[-0.4px] leading-[1.2] text-[#18181b]">
                  Chord A1
                </h3>
              </div>
              <p className="text-[15px] leading-[1.85] text-[#5d6168] m-0">
                正在研发中的基础语言模型，面向复杂对话与长程智能体任务，重点强化推理链一致性、工具调用与环境状态理解能力。
              </p>
            </article>

            <article
              id="openpivot"
              className="border-t border-[#e8e8e8] py-[32px] grid grid-cols-1 min-[681px]:grid-cols-[minmax(210px,0.7fr)_minmax(0,1.3fr)] gap-8 scroll-mt-[110px]"
            >
              <div>
                <p className="text-[11px] font-semibold tracking-[1px] text-[#686d74] m-0">
                  <span className="inline-block w-[34px] text-[#18181b]">02</span>
                  AGENT SYSTEM
                </p>
                <h3 className="mt-[18px] text-[27px] font-medium tracking-[-0.4px] leading-[1.2] text-[#18181b]">
                  OpenPivot
                </h3>
              </div>
              <p className="text-[15px] leading-[1.85] text-[#5d6168] m-0">
                面向人机协作的智能体系统。让智能体具备记忆、协同与可交接能力，使用户能够在关键节点清晰理解 Agent 决策并随时无缝接手。
              </p>
            </article>

            <article className="border-t border-b border-[#e8e8e8] py-[32px] grid grid-cols-1 min-[681px]:grid-cols-[minmax(210px,0.7fr)_minmax(0,1.3fr)] gap-8">
              <div>
                <p className="text-[11px] font-semibold tracking-[1px] text-[#686d74] m-0">
                  <span className="inline-block w-[34px] text-[#18181b]">03</span>
                  CLIENT APPLICATION
                </p>
                <h3 className="mt-[18px] text-[27px] font-medium tracking-[-0.4px] leading-[1.2] text-[#18181b]">
                  Nuwa 客户端
                </h3>
              </div>
              <div className="space-y-4">
                <p className="text-[15px] leading-[1.85] text-[#5d6168] m-0">
                  面向 Android、HarmonyOS 与桌面端的跨端 AI 客户端及历史会话迁移工具，所有正式构建产物均通过 MinIO 版本库分发。
                </p>
                <button
                  type="button"
                  onClick={() => onNavigate('/nuwa')}
                  className="rc-text-link"
                >
                  <span>前往 Nuwa 下载页</span>
                  <span aria-hidden="true">↗</span>
                </button>
              </div>
            </article>
          </div>
        </div>
      </section>
    </div>
  );
}
