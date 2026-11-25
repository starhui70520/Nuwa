import { createId } from '../../utils/id.js'
import { streamMessage } from '../api/client.js'
import type { MessageParam } from '../api/types.js'
import { getActiveSecret, isUsingDeepSeekAccount, useSettings } from '../settings.js'
import { getContextRounds, getReplyText } from './reply.js'
import type {
  AssistantMessage,
  CompactionSource,
  CompactionSpan,
  Message,
  Session,
  UserMessage,
} from './types.js'

/** 自动压缩时保护的最近原文轮数，确保文风、语气与近期细节原汁原味 */
export const PROTECTED_TAIL_ROUNDS = 8
/** 未压缩轮数达到该值时自动触发一次区块级 Compaction（兼顾 Prefix Cache 命中率） */
export const AUTO_COMPACT_UNCOMPACTED_ROUNDS = 20
/** 上下文输入 Token 达到该阈值时自动触发区块级 Compaction */
export const AUTO_COMPACT_TOKEN_THRESHOLD = 28_000
/** 自动压缩单次至少需要折叠的轮数，避免频繁碎块打碎缓存 */
const AUTO_MIN_COMPACTABLE_ROUNDS = 6
/** 单次压缩区块的最大轮数上限，避免导入上千轮超长会话时单次摘要请求超窗 */
const MAX_COMPACT_ROUNDS_PER_SPAN = 50
/** 单次压缩区块的最大估算 Token 上限（兼容 128K 模型） */
const MAX_COMPACT_TOKENS_PER_SPAN = 60_000
/** 手动批量追赶时，每块的最大轮数与估算 Token 上限（减少上千轮会话的总请求次数） */
const BATCH_MAX_ROUNDS_PER_SPAN = 80
const BATCH_MAX_TOKENS_PER_SPAN = 75_000
/** 手动触发时，对话较短也至少保留的近期原文轮数 */
const MANUAL_MIN_TAIL_ROUNDS = 2
/** 手动触发最少可折叠轮数 */
const MANUAL_MIN_COMPACTABLE_ROUNDS = 2

type ConversationScene = 'creative' | 'general'

const CREATIVE_SCENE_RE =
  /角色扮演|扮演|人设|世界观|小说|剧情|伏笔|口癖|第一章|第一卷|章节|主控|设定|修仙|穿越|重生|「[^」]{2,}」|『[^』]{2,}』|(?:他|她)[^。\n]{0,12}(?:说道|低声|轻笑|皱眉|冷声|问道)/

/** 纯本地轻量场景识别：自动区分「写作/角色扮演」与「通用/工作/问答」对话，无需用户手动选择 */
const detectConversationScene = (
  rounds: [UserMessage, AssistantMessage][]
): ConversationScene => {
  let score = 0
  const sampleCount = Math.min(rounds.length, 6)
  for (let i = 0; i < sampleCount; i++) {
    const [user, reply] = rounds[i]
    const text = `${user.content}\n${getReplyText(reply)}`
    const matches = text.match(new RegExp(CREATIVE_SCENE_RE.source, 'g'))
    if (matches) {
      score += matches.length
    }
  }
  return score >= 3 ? 'creative' : 'general'
}

const COMPACTION_SYSTEM_PROMPT_CREATIVE = `你是一位专业的小说编辑与剧情档案员，擅长为长篇写作与角色扮演整理高保真、低幻觉的记忆档案。
你必须严格遵守以下规则：
1. 忠实原文：严禁编造、脑补对话中未发生的事件、台词或心理活动。
2. 保留专有名词：所有人名、昵称、地名、组织、招式、道具、特定称呼与角色口癖必须原样保留。
3. 双轨保真：既要提炼不可丢失的核心设定与人设锚点，也要按时间顺序记录剧情脉络与状态变更。
4. 增量不重复：若提供了既有记忆，仅总结本次新增片段，不要重复抄写未变化的内容。
5. 直接输出记忆档案正文，不要输出任何开场白或元解释。`

const COMPACTION_SYSTEM_PROMPT_GENERAL = `你是一位严谨的对话上下文整理助手，擅长为长对话（日常咨询、学习、分析、技术协作等）提炼高保真、低冗余的阶段记忆。
你必须严格遵守以下规则：
1. 忠实原文：严禁编造对话中未出现的结论、数字、参数或事实。
2. 保留关键信息：人名、项目名、文件路径、代码标识、明确的数字/日期/偏好与约束条件必须原样保留。
3. 增量不重复：若提供了既有记忆，仅总结本次新增片段，不要重复抄写未变化的内容。
4. 高信息密度：删去客套寒暄与重复解释，保留目标、已定结论、关键依据与待办事项。
5. 直接输出整理后的正文，不要输出任何开场白或元解释。`

/** 快速中英文 Token 估算（CJK 字符按 1.5 token、其余按 0.3 token 粗估） */
export const estimateTextTokens = (text: string): number => {
  if (!text) {
    return 0
  }
  let cjk = 0
  let other = 0
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i)
    if (
      (code >= 0x4e00 && code <= 0x9fff) ||
      (code >= 0x3400 && code <= 0x4dbf) ||
      (code >= 0x3000 && code <= 0x303f) ||
      (code >= 0xff00 && code <= 0xffef)
    ) {
      cjk += 1
    } else {
      other += 1
    }
  }
  return Math.max(1, Math.ceil(cjk * 1.5 + other * 0.3))
}

const estimateRoundTokens = ([user, reply]: [UserMessage, AssistantMessage]): number =>
  estimateTextTokens(user.content) + estimateTextTokens(getReplyText(reply)) + 16

export type ResolvedCompaction = {
  span: CompactionSpan
  startRoundIndex: number
  endRoundIndex: number
}

/**
 * 树状分支感知的压缩块解析：
 * 只有起止消息 ID 同时落在当前活跃分支路径上的压缩块才会生效，
 * 从而天然实现平行剧情分支之间的记忆隔离；若存在嵌套/重叠，优先保留更外层或更新的块。
 */
export const resolveActiveCompactions = (
  rounds: [UserMessage, AssistantMessage][],
  compactions?: CompactionSpan[]
): ResolvedCompaction[] => {
  if (!compactions || compactions.length === 0 || rounds.length === 0) {
    return []
  }
  const userIndexById = new Map<string, number>()
  const replyIndexById = new Map<string, number>()
  for (let i = 0; i < rounds.length; i++) {
    userIndexById.set(rounds[i][0].id, i)
    replyIndexById.set(rounds[i][1].id, i)
  }

  const matched: ResolvedCompaction[] = []
  for (const span of compactions) {
    const startRoundIndex = userIndexById.get(span.startMessageId)
    const endRoundIndex = replyIndexById.get(span.endMessageId)
    if (
      startRoundIndex !== undefined &&
      endRoundIndex !== undefined &&
      startRoundIndex <= endRoundIndex
    ) {
      matched.push({ span, startRoundIndex, endRoundIndex })
    }
  }
  if (matched.length <= 1) {
    return matched
  }

  // 起点升序 -> 覆盖跨度降序（优先外层合并块）-> 更新时间降序
  matched.sort((a, b) => {
    if (a.startRoundIndex !== b.startRoundIndex) {
      return a.startRoundIndex - b.startRoundIndex
    }
    const lenA = a.endRoundIndex - a.startRoundIndex
    const lenB = b.endRoundIndex - b.startRoundIndex
    if (lenA !== lenB) {
      return lenB - lenA
    }
    return b.span.updatedAt - a.span.updatedAt
  })

  const active: ResolvedCompaction[] = []
  let coveredUntil = -1
  for (const item of matched) {
    if (item.startRoundIndex > coveredUntil) {
      active.push(item)
      coveredUntil = item.endRoundIndex
    }
  }
  return active
}

export type ProjectedContextItem =
  | { type: 'compaction'; span: CompactionSpan }
  | { type: 'round'; user: UserMessage; reply: AssistantMessage }

/**
 * 将当前活跃分支的成对历史轮次投影为「冻结摘要块 + 未压缩原文轮次」序列。
 * 本地原消息完全无损，仅用于组装发给大模型的请求上下文。
 */
export const projectContextItems = (
  history: Message[],
  compactions?: CompactionSpan[]
): ProjectedContextItem[] => {
  const rounds = getContextRounds(history)
  const active = resolveActiveCompactions(rounds, compactions)
  if (active.length === 0) {
    return rounds.map(([user, reply]) => ({ type: 'round', user, reply }))
  }

  const byStart = new Map<number, ResolvedCompaction>()
  for (const item of active) {
    byStart.set(item.startRoundIndex, item)
  }

  const projected: ProjectedContextItem[] = []
  for (let i = 0; i < rounds.length; i++) {
    const hit = byStart.get(i)
    if (hit) {
      projected.push({ type: 'compaction', span: hit.span })
      i = hit.endRoundIndex
      continue
    }
    const [user, reply] = rounds[i]
    projected.push({ type: 'round', user, reply })
  }
  return projected
}

/** 将压缩摘要块格式化为协议安全的 user/assistant 交替对，确保兼容所有 OpenAI/Anthropic 严格校验 */
export const toCompactionMessagePair = (
  span: CompactionSpan
): [MessageParam, MessageParam] => [
  {
    role: 'user',
    content: `<context_memory title="${span.title}" rounds="${span.coveredRounds}">\n${span.summary.trim()}\n</context_memory>\n以上是此前已整理的对话记忆，请严格遵循其中的设定、事实、约束与上下文状态，自然承接后续对话。`,
  },
  {
    role: 'assistant',
    content: [{ type: 'text', text: '已载入此前记忆，我将保持上下文与设定连贯继续。' }],
  },
]

export type CompactionTarget = {
  rounds: [UserMessage, AssistantMessage][]
  startMessageId: string
  endMessageId: string
  startRoundNumber: number
  endRoundNumber: number
  scene: ConversationScene
  title: string
  originalTokensEstimate: number
  previousSummaries: CompactionSpan[]
}

/**
 * 估算当前活跃分支的上下文状态，供 UI 展示或判断是否需要自动压缩。
 */
export const inspectContextStats = (
  visibleMessages: Message[],
  compactions?: CompactionSpan[]
) => {
  const rounds = getContextRounds(visibleMessages)
  const active = resolveActiveCompactions(rounds, compactions)

  // 逐轮判断是否已被任一活跃记忆块覆盖（兼容 3 路并发压缩乱序完成时的实时统计）
  const coveredRoundFlags = new Uint8Array(rounds.length)
  let latestCompactionTime = 0
  let summaryTokens = 0
  for (const item of active) {
    summaryTokens += item.span.summaryTokensEstimate
    if (item.span.updatedAt > latestCompactionTime) {
      latestCompactionTime = item.span.updatedAt
    }
    for (let i = item.startRoundIndex; i <= item.endRoundIndex; i++) {
      coveredRoundFlags[i] = 1
    }
  }

  let uncompactedCount = 0
  let uncompactedTokens = 0
  for (let i = 0; i < rounds.length; i++) {
    if (coveredRoundFlags[i] === 0) {
      uncompactedCount += 1
      uncompactedTokens += estimateRoundTokens(rounds[i])
    }
  }

  // 只有当最后一次服务端真实 usage 晚于最新一次压缩时间时，才直接采用服务端 usage；
  // 否则（刚压缩完或正在批量压缩中）实时采用投影后的 estimatedProjectedTokens，确保进度条与数字实时下降。
  let latestUsageInput: number | undefined
  for (let i = rounds.length - 1; i >= 0; i--) {
    const reply = rounds[i][1]
    const tokens = reply.usage?.input_tokens
    if (typeof tokens === 'number' && tokens > 0) {
      if (latestCompactionTime === 0 || reply.createdAt > latestCompactionTime) {
        latestUsageInput = tokens
      }
      break
    }
  }

  const estimatedProjectedTokens = summaryTokens + uncompactedTokens
  const effectiveTokens = latestUsageInput ?? estimatedProjectedTokens

  return {
    totalRounds: rounds.length,
    activeCompactions: active,
    uncompactedCount,
    effectiveTokens,
    estimatedProjectedTokens,
    canManualCompact:
      uncompactedCount >= MANUAL_MIN_COMPACTABLE_ROUNDS + MANUAL_MIN_TAIL_ROUNDS,
  }
}

/**
 * 选取下一个待压缩的连续对话区块：
 * - 自动模式：严格保护最近 PROTECTED_TAIL_ROUNDS 轮原文，仅在达到轮数或 Token 阈值时一次性折叠一块，最大化 Prefix Cache 命中率；
 * - 手动模式：对话较长时保留 PROTECTED_TAIL_ROUNDS 轮，对话较短时至少保留 MANUAL_MIN_TAIL_ROUNDS 轮，方便用户随时整理。
 */
export const selectCompactionTarget = (
  visibleMessages: Message[],
  compactions: CompactionSpan[] | undefined,
  source: CompactionSource
): CompactionTarget | null => {
  const rounds = getContextRounds(visibleMessages)
  const active = resolveActiveCompactions(rounds, compactions)
  const startOffset = active.length > 0 ? active[active.length - 1].endRoundIndex + 1 : 0
  const uncompacted = rounds.slice(startOffset)

  if (source === 'auto') {
    const stats = inspectContextStats(visibleMessages, compactions)
    const hitRoundThreshold = uncompacted.length >= AUTO_COMPACT_UNCOMPACTED_ROUNDS
    const hitTokenThreshold = stats.effectiveTokens >= AUTO_COMPACT_TOKEN_THRESHOLD
    if (!hitRoundThreshold && !hitTokenThreshold) {
      return null
    }
    const compactCount = uncompacted.length - PROTECTED_TAIL_ROUNDS
    if (compactCount < AUTO_MIN_COMPACTABLE_ROUNDS) {
      return null
    }
    return buildTarget(uncompacted.slice(0, compactCount), startOffset, active.map((a) => a.span))
  }

  // manual：优先保护 8 轮；如果当前未压缩轮次不足 10 轮但 >= 4 轮，则降级保护最近 2 轮
  const tailKeep =
    uncompacted.length >= PROTECTED_TAIL_ROUNDS + MANUAL_MIN_COMPACTABLE_ROUNDS
      ? PROTECTED_TAIL_ROUNDS
      : MANUAL_MIN_TAIL_ROUNDS
  const compactCount = uncompacted.length - tailKeep
  if (compactCount < MANUAL_MIN_COMPACTABLE_ROUNDS) {
    return null
  }
  return buildTarget(uncompacted.slice(0, compactCount), startOffset, active.map((a) => a.span))
}

const capCompactionSlice = (
  slice: [UserMessage, AssistantMessage][],
  maxRounds = MAX_COMPACT_ROUNDS_PER_SPAN,
  maxTokens = MAX_COMPACT_TOKENS_PER_SPAN
): [UserMessage, AssistantMessage][] => {
  const capped: [UserMessage, AssistantMessage][] = []
  let tokens = 0
  for (const round of slice) {
    const roundTokens = estimateRoundTokens(round)
    if (
      capped.length >= MANUAL_MIN_COMPACTABLE_ROUNDS &&
      (capped.length >= maxRounds || tokens + roundTokens > maxTokens)
    ) {
      break
    }
    capped.push(round)
    tokens += roundTokens
  }
  return capped
}

const buildTarget = (
  rawSlice: [UserMessage, AssistantMessage][],
  startOffset: number,
  previousSummaries: CompactionSpan[],
  maxRounds = MAX_COMPACT_ROUNDS_PER_SPAN,
  maxTokens = MAX_COMPACT_TOKENS_PER_SPAN
): CompactionTarget => {
  const slice = capCompactionSlice(rawSlice, maxRounds, maxTokens)
  const startRoundNumber = startOffset + 1
  const endRoundNumber = startOffset + slice.length
  const scene = detectConversationScene(slice)
  const originalTokensEstimate = slice.reduce((sum, round) => sum + estimateRoundTokens(round), 0)
  return {
    rounds: slice,
    startMessageId: slice[0][0].id,
    endMessageId: slice[slice.length - 1][1].id,
    startRoundNumber,
    endRoundNumber,
    scene,
    title:
      scene === 'creative'
        ? `第 ${startRoundNumber}–${endRoundNumber} 轮剧情记忆`
        : `第 ${startRoundNumber}–${endRoundNumber} 轮对话记忆`,
    originalTokensEstimate,
    previousSummaries,
  }
}

/**
 * 为手动「一键整理」生成全部待压缩区块列表：
 * - 普通对话只返回 1 块；
 * - 导入的几百/上千轮超长历史自动按 80 轮 / 75K tokens 切分成多块，供并发批量追赶整理。
 */
export const selectBatchCompactionTargets = (
  visibleMessages: Message[],
  compactions: CompactionSpan[] | undefined
): CompactionTarget[] => {
  const rounds = getContextRounds(visibleMessages)
  const active = resolveActiveCompactions(rounds, compactions)
  const startOffset = active.length > 0 ? active[active.length - 1].endRoundIndex + 1 : 0
  const uncompacted = rounds.slice(startOffset)

  const tailKeep =
    uncompacted.length >= PROTECTED_TAIL_ROUNDS + MANUAL_MIN_COMPACTABLE_ROUNDS
      ? PROTECTED_TAIL_ROUNDS
      : MANUAL_MIN_TAIL_ROUNDS
  const compactableTotal = uncompacted.length - tailKeep
  if (compactableTotal < MANUAL_MIN_COMPACTABLE_ROUNDS) {
    return []
  }

  const allCompactable = uncompacted.slice(0, compactableTotal)
  const previousSummaries = active.map((item) => item.span)
  const targets: CompactionTarget[] = []
  let cursor = 0
  while (cursor < allCompactable.length) {
    const remaining = allCompactable.slice(cursor)
    // 尾部若只剩 1 轮不足最小成块要求，并入前一块末尾或留作保护尾部
    if (remaining.length < MANUAL_MIN_COMPACTABLE_ROUNDS) {
      break
    }
    const target = buildTarget(
      remaining,
      startOffset + cursor,
      cursor === 0 ? previousSummaries : [],
      BATCH_MAX_ROUNDS_PER_SPAN,
      BATCH_MAX_TOKENS_PER_SPAN
    )
    targets.push(target)
    cursor += target.rounds.length
  }
  return targets
}

const formatTranscriptForCompaction = (target: CompactionTarget): string => {
  const sections: string[] = []

  if (target.previousSummaries.length > 0) {
    const prevText = target.previousSummaries
      .map((item) => `[${item.title}]\n${item.summary}`)
      .join('\n\n')
    sections.push(`【既有记忆（仅供参考，请勿重复抄写未变化内容）】\n${prevText}`)
  }

  const isOpeningBlock = target.startRoundNumber === 1
  const transcript = target.rounds
    .map(([user, reply], idx) => {
      const roundNo = target.startRoundNumber + idx
      const userText = user.content.trim() || '（附件消息）'
      const replyText = getReplyText(reply).trim()
      return `--- 第 ${roundNo} 轮 ---\n【用户】\n${userText}\n\n【助手】\n${replyText}`
    })
    .join('\n\n')

  sections.push(
    `【本次需要整理的对话片段（第 ${target.startRoundNumber}–${target.endRoundNumber} 轮）】\n${transcript}`
  )

  if (target.scene === 'creative') {
    sections.push(
      `请按以下结构输出整理后的记忆档案（无内容的条目可省略）：
### 1. 核心设定与人设锚点${isOpeningBlock ? '（完整提炼角色性格、称呼、口癖、文风要求与世界观规则）' : '（仅记录本段新增或变更的设定）'}
- ...
### 2. 剧情脉络
- ...
### 3. 人物状态与关系变化
- 角色名：当前位置 / 状态 / 关系变化 / 秘密
### 4. 关键物品、约定与未回收伏笔
- ...
### 5. 尾声衔接锚点
- （本片段结束时的精确时间、地点、在场人物与动作）

最后另起一行，列出 5–12 个本段最核心的专有名词、人名、地点或道具关键词（用顿号分隔）：
<!-- KEYWORDS: 关键词1、关键词2、关键词3 -->`
    )
  } else {
    sections.push(
      `请按以下结构输出整理后的阶段记忆（无内容的条目可省略）：
### 1. 核心目标与约束偏好${isOpeningBlock ? '（提炼用户背景、核心需求、格式或风格要求）' : '（仅记录本段新增或变更的要求）'}
- ...
### 2. 已确认的结论与关键事实
- ...
### 3. 重要细节（数据 / 专有名词 / 路径 / 决策依据）
- ...
### 4. 未决问题与后续衔接点
- ...

最后另起一行，列出 5–12 个本段最核心的专有名词、主题或实体关键词（用顿号分隔）：
<!-- KEYWORDS: 关键词1、关键词2、关键词3 -->`
    )
  }

  return sections.join('\n\n')
}

const KEYWORDS_LINE_RE = /\n*<!--\s*KEYWORDS:\s*([^\n]+?)\s*-->\s*$/i

const parseSummaryAndKeywords = (raw: string): { summary: string; keywords: string[] } => {
  const trimmed = raw.trim()
  const match = KEYWORDS_LINE_RE.exec(trimmed)
  if (!match) {
    return { summary: trimmed, keywords: [] }
  }
  const summary = trimmed.slice(0, match.index).trim()
  const keywords = match[1]
    .split(/[、,，/｜|]+/)
    .map((item) => item.trim())
    .filter((item) => item.length >= 2 && item.length <= 24)
  return { summary: summary || trimmed, keywords: Array.from(new Set(keywords)) }
}

/** 调用当前已配置的 LLM 生成结构化剧情记忆摘要（关闭深度思考以加快速度、降低成本） */
export const generateCompactionSpan = async (
  target: CompactionTarget,
  source: CompactionSource,
  signal: AbortSignal,
  fallbackModel: string
): Promise<CompactionSpan> => {
  const settings = useSettings.getState()
  const model = isUsingDeepSeekAccount(settings)
    ? fallbackModel
    : settings.apiModel.trim() || fallbackModel

  const promptText = formatTranscriptForCompaction(target)
  const events = streamMessage(
    getActiveSecret(settings),
    {
      model,
      system:
        target.scene === 'creative'
          ? COMPACTION_SYSTEM_PROMPT_CREATIVE
          : COMPACTION_SYSTEM_PROMPT_GENERAL,
      messages: [{ role: 'user', content: promptText }],
      thinking: { type: 'disabled' },
    },
    signal
  )

  let rawSummary = ''
  for await (const event of events) {
    if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
      rawSummary += event.delta.text
    }
  }

  const { summary: cleaned, keywords } = parseSummaryAndKeywords(rawSummary)
  if (!cleaned) {
    throw new Error('Compaction model returned empty summary')
  }

  const now = Date.now()
  return {
    id: createId(),
    startMessageId: target.startMessageId,
    endMessageId: target.endMessageId,
    title: target.title,
    summary: cleaned,
    ...(keywords.length > 0 ? { keywords } : {}),
    source,
    coveredRounds: target.rounds.length,
    originalTokensEstimate: target.originalTokensEstimate,
    summaryTokensEstimate: estimateTextTokens(cleaned),
    model,
    createdAt: now,
    updatedAt: now,
  }
}

// ---------- V1 纯本地 0 延迟记忆回溯（Zone 4 单轮临时注入） ----------

const RECALL_STOP_WORDS = new Set([
  '我们', '你们', '他们', '自己', '这个', '那个', '什么', '怎么', '为什么', '可以', '已经',
  '还是', '但是', '因为', '所以', '如果', '然后', '现在', '觉得', '知道', '看着', '抬头',
  '低声', '问道', '笑着', '摇头', '点头', '时候', '地方', '东西', '一下', '一点', '有些',
  '有点', '好像', '刚才', '其实', '不是', '没有', '不会', '不能', '应该', '可能', '这么',
  '那么', '这里', '那里', '出来', '进去',
])

const RECALL_INTENT_RE =
  /记得|记不记得|来着|当初|之前|最早|上次|那次|那块|那半张|那个|刻着|写着|发誓|答应|说过|原话|临终|临走|叫什么|具体|背错|暗号|押的|真名|付出|失去|记得吗/

const extractRecallTerms = (text: string): string[] => {
  const terms = new Set<string>()
  for (const m of text.matchAll(/[A-Za-z0-9][A-Za-z0-9._-]{1,}/g)) {
    terms.add(m[0].toLowerCase())
  }
  for (const m of text.matchAll(/[「『“"]([^「『“"」』”]{2,12})[」』”"]/g)) {
    const phrase = m[1].trim()
    if (phrase && !RECALL_STOP_WORDS.has(phrase)) {
      terms.add(phrase)
    }
  }
  for (const m of text.matchAll(/[\u4e00-\u9fff]{2,}/g)) {
    const seg = m[0]
    for (let n = 2; n <= 3; n++) {
      for (let i = 0; i <= seg.length - n; i++) {
        const gram = seg.slice(i, i + n)
        if (!RECALL_STOP_WORDS.has(gram)) {
          terms.add(gram)
        }
      }
    }
  }
  return Array.from(terms)
}

const extractFocusedSnippet = (text: string, terms: string[], maxLen = 700): string => {
  const trimmed = text.trim()
  if (trimmed.length <= maxLen) {
    return trimmed
  }
  const paras = trimmed.split(/\n+/)
  let bestIdx = paras.length - 1
  let bestHits = -1
  for (let i = 0; i < paras.length; i++) {
    const lower = paras[i].toLowerCase()
    let hits = 0
    for (const term of terms) {
      if (lower.includes(term.toLowerCase())) {
        hits += 1
      }
    }
    if (hits >= bestHits) {
      bestHits = hits
      bestIdx = i
    }
  }
  return paras
    .slice(Math.max(0, bestIdx - 1), bestIdx + 2)
    .join('\n')
    .slice(0, maxLen)
}

export type RecalledMemoryResult = {
  blockText: string
  roundNumbers: number[]
  spanTitles: string[]
}

/**
 * V1 纯本地 0 延迟记忆回溯：
 * 仅在当前分支存在已折叠 CompactionSpan 时生效；
 * 在已折叠区间内做 IDF 加权检索，命中后截取聚焦原文切片供 Zone 4 单轮临时注入，绝不破坏 Prefix Cache。
 */
export const recallRelevantHistory = (
  queryText: string,
  history: Message[],
  compactions?: CompactionSpan[]
): RecalledMemoryResult | null => {
  const trimmedQuery = queryText.trim()
  if (!trimmedQuery || !compactions || compactions.length === 0) {
    return null
  }
  const rounds = getContextRounds(history)
  const active = resolveActiveCompactions(rounds, compactions)
  if (active.length === 0) {
    return null
  }

  // 收集所有被折叠覆盖的轮次（带 1-based 轮号与所属摘要标题）
  const covered: Array<{
    roundNumber: number
    spanTitle: string
    userText: string
    replyText: string
    docLower: string
  }> = []
  const coveredIndexes = new Set<number>()
  const allKeywords = new Set<string>()

  for (const item of active) {
    for (const kw of item.span.keywords ?? []) {
      allKeywords.add(kw.toLowerCase())
    }
    for (let i = item.startRoundIndex; i <= item.endRoundIndex; i++) {
      coveredIndexes.add(i)
      const [user, reply] = rounds[i]
      const userText = user.content.trim()
      const replyText = getReplyText(reply).trim()
      covered.push({
        roundNumber: i + 1,
        spanTitle: item.span.title,
        userText,
        replyText,
        docLower: `${userText}\n${replyText}`.toLowerCase(),
      })
    }
  }

  if (covered.length === 0) {
    return null
  }

  const tailParts: string[] = []
  const alreadyRecalledInTail = new Set<number>()
  for (let i = 0; i < rounds.length; i++) {
    if (!coveredIndexes.has(i)) {
      tailParts.push(rounds[i][0].content, getReplyText(rounds[i][1]))
      for (const num of rounds[i][1].recalledMemory?.roundNumbers ?? []) {
        alreadyRecalledInTail.add(num)
      }
    }
  }
  const tailLower = tailParts.join('\n').toLowerCase()

  const hasIntent = RECALL_INTENT_RE.test(trimmedQuery)
  const queryTerms = extractRecallTerms(trimmedQuery)
  if (queryTerms.length === 0) {
    return null
  }

  const hitIndexKeyword = queryTerms.some((term) => {
    const lower = term.toLowerCase()
    return allKeywords.has(lower) && !tailLower.includes(lower)
  })

  // 无回溯意图且未命中摘要专有索引词：直接 0.1ms 跳过，杜绝日常续写与干扰词误触发
  if (!hasIntent && !hitIndexKeyword) {
    return null
  }

  const N = covered.length
  const maxDf = Math.max(3, Math.floor(N * 0.12))
  const usefulTerms: Array<{ lower: string; weight: number }> = []

  for (const term of queryTerms) {
    const lower = term.toLowerCase()
    let df = 0
    for (let i = 0; i < N; i++) {
      if (covered[i].docLower.includes(lower)) {
        df += 1
      }
    }
    if (df > 0 && df <= maxDf) {
      const idf = Math.log((N + 1) / (df + 0.5)) + 0.5
      const lengthBoost = term.length >= 3 ? 1.5 : 1.0
      const indexBoost = allKeywords.has(lower) ? 1.6 : 1.0
      const tailPenalty = tailLower.includes(lower) ? 0.35 : 1.0
      usefulTerms.push({ lower, weight: idf * lengthBoost * indexBoost * tailPenalty })
    }
  }

  if (usefulTerms.length === 0) {
    return null
  }

  const scored: Array<{ entry: (typeof covered)[number]; score: number }> = []
  for (let i = 0; i < N; i++) {
    // 同轮去重：当前未压缩尾部里已经回溯过的历史轮次不再重复注入，既省 Token 又保缓存
    if (alreadyRecalledInTail.has(covered[i].roundNumber)) {
      continue
    }
    let score = 0
    const doc = covered[i].docLower
    for (const t of usefulTerms) {
      if (doc.includes(t.lower)) {
        score += t.weight
      }
    }
    if (score > 0) {
      scored.push({ entry: covered[i], score })
    }
  }

  scored.sort((a, b) => b.score - a.score)
  const threshold = N >= 30 ? 8.0 : 4.2
  const top = scored
    .filter((item) => item.score >= threshold)
    .slice(0, 2)
    .map((item) => item.entry)
    .sort((a, b) => a.roundNumber - b.roundNumber)

  if (top.length === 0) {
    return null
  }

  const snippets = top.map(
    (entry) =>
      `[第 ${entry.roundNumber} 轮原始片段 · ${entry.spanTitle}]\n用户：${extractFocusedSnippet(entry.userText, queryTerms)}\n助手：${extractFocusedSnippet(entry.replyText, queryTerms)}`
  )

  return {
    blockText: `<recalled_memory note="以下仅是较早时间点的历史原文切片，仅供核对具体细节；人物当前关系与场景状态请严格以近期对话为准">\n${snippets.join('\n\n')}\n</recalled_memory>`,
    roundNumbers: top.map((entry) => entry.roundNumber),
    spanTitles: Array.from(new Set(top.map((entry) => entry.spanTitle))),
  }
}

/** 辅助：从 Session 上移除或更新某条 CompactionSpan */
export const upsertCompactionSpan = (session: Session, span: CompactionSpan): Session => {
  const existing = session.compactions ?? []
  const index = existing.findIndex((item) => item.id === span.id)
  const next =
    index >= 0
      ? existing.map((item, i) => (i === index ? span : item))
      : [...existing, span]
  return { ...session, compactions: next }
}

export const removeCompactionSpan = (session: Session, spanId: string): Session => {
  const existing = session.compactions
  if (!existing || existing.length === 0) {
    return session
  }
  const next = existing.filter((item) => item.id !== spanId)
  return { ...session, compactions: next.length > 0 ? next : undefined }
}
