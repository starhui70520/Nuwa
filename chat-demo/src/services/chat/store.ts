import { create } from 'zustand'
import { isLowPerfDevice, onLowMemory } from '../../app/devicePerf.js'
import { showToast } from '../../components/base/toastState.js'
import { clearMdAstCache } from '../markdown/parse.js'
import { createId } from '../../utils/id.js'
import { refreshBalanceAfterReply } from '../api/balance.js'
import { ApiError, streamMessage } from '../api/client.js'
import type {
  ChatModel,
  CreateMessageRequest,
  InlineImageBlockParam,
  MessageParam,
} from '../api/types.js'
import { extractFileIds, getFileErrorCode, isRetryableApiError } from '../api/errors.js'
import {
  blobToDataUrl,
  cancelUpload,
  describeUploadFailure,
  normalizeImageForUpload,
  uploadAttachment,
  useUploads,
} from '../attachments.js'
import { recordAppLog } from '../errorLog.js'
import { setNativeStreamKeepAlive } from '../nativeBridge.js'
import {
  getActiveSecret,
  isUsingDeepSeekAccount,
  isUsingRankAIFree,
  RANKAI_MODEL,
  useSettings,
} from '../settings.js'
import { isBillingSupportedSettings } from './billing.js'
import { appendBranch, getVisibleMessages, normalizeSession, selectVersion } from './branches.js'
import * as db from './db.js'
import {
  clearAllDrafts,
  clearDraft,
  clearSentDraft,
  getDraft,
  prepareDraftMessage,
} from './drafts.js'
import { createLatestReminder } from './latestReminder.js'
import {
  applyEvent,
  canContinueReply,
  getContextRounds,
  getReplyText,
  settleReply,
  toRequestMessages,
  type RequestHistoryItem,
} from './reply.js'
import {
  estimateTextTokens,
  generateCompactionSpan,
  projectContextItems,
  recallRelevantHistory,
  removeCompactionSpan,
  selectBatchCompactionTargets,
  selectCompactionTarget,
  toCompactionMessagePair,
  upsertCompactionSpan,
} from './compaction.js'
import {
  toSessionSummary,
  type AssistantMessage,
  type CompactionSource,
  type CompactionSpan,
  type FileAttachment,
  type Message,
  type Session,
  type SessionSummary,
  type UserMessage,
} from './types.js'

/** deepseek-flash 同时支持深度思考与图片输入 */
const MODEL: ChatModel = 'deepseek-flash'
/** 所有生成请求统一携带的助手身份说明 */
const SYSTEM_PROMPT = '该助手为DeepSeek，由深度求索公司创造。'
/** 保留最近打开的详情；当前会话、生成中及尚未成功保存的会话不淘汰。低性能设备缩减缓存上限降低常驻内存。 */
const SESSION_CACHE_LIMIT = 5
const LOW_PERF_SESSION_CACHE_LIMIT = 2
const LOW_PERF_STREAM_COALESCE_MS = 48
/** 安全审核默认 high（走扩展模式）；走 1M 长上下文通道时降为 low（官方默认审查），避免触发 32K 上限 */
const SAFETY_CHECK_HIGH = { level: 'high' } as const
const SAFETY_CHECK_LOW = { level: 'low' } as const
/** 服务端判定 file_id 失效后，重新补传并重发的最多次数（不含首次请求） */
const FILE_RETRY_LIMIT = 2
/** 退避基数，第 n 次重试等待 2^n 倍；连续失败达到上限就放弃，把原始报错展示出来 */
const FILE_RETRY_BASE_DELAY = 1000
/** 切后台断链后允许回前台自动无缝重连的最长间隔（5 分钟） */
const BACKGROUND_RESUME_RETRY_WINDOW_MS = 5 * 60 * 1000
/** 切回前台后等待网络接口恢复的短暂缓冲时间 */
const BACKGROUND_RESUME_SETTLE_DELAY_MS = 450

/**
 * 扩展工具会触发服务端 32K 输入上限；仅在需要时声明：
 * - 开启智能搜索时声明搜索 + 读链接；
 * - 未开搜索但未走 1M 降级时，仅在消息或上下文中出现网址（或非文档普通对话）时声明读链接。
 */
const serverTools = (search: boolean, allowExtended: boolean): CreateMessageRequest['tools'] => {
  if (!allowExtended) {
    return []
  }
  const tools: CreateMessageRequest['tools'] = [
    { type: 'deepseek_read_url', name: 'deepseek_read_url' },
  ]
  if (search) {
    tools.push({ type: 'deepseek_web_search', name: 'deepseek_web_search' })
  }
  return tools
}

const is32kInputLimitError = (error: unknown): boolean =>
  error instanceof ApiError &&
  /user input too long.*exceeds max 32768 tokens/i.test(error.message)

/** 被服务端判定为不支持/已损坏/超尺寸的历史图片 file_id；持久化到 localStorage，后续轮次与重启后直接跳过，避免整段对话死锁。 */
const REJECTED_IMAGES_STORAGE_KEY = 'nuwa_rejected_history_images'
const MAX_STORED_REJECTED_IMAGES = 500
const MAX_SKIPPED_BAD_IMAGES = 60

const loadRejectedHistoryImages = (): Set<string> => {
  try {
    const raw = localStorage.getItem(REJECTED_IMAGES_STORAGE_KEY)
    if (!raw) {
      return new Set()
    }
    const parsed: unknown = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      return new Set(parsed.filter((item): item is string => typeof item === 'string'))
    }
  } catch {
    // 忽略存储受限或损坏数据
  }
  return new Set()
}

const rejectedHistoryImageIds = loadRejectedHistoryImages()

const markRejectedHistoryImage = (fileId: string): boolean => {
  if (!fileId || rejectedHistoryImageIds.has(fileId)) {
    return false
  }
  rejectedHistoryImageIds.add(fileId)
  try {
    const list = Array.from(rejectedHistoryImageIds).slice(-MAX_STORED_REJECTED_IMAGES)
    localStorage.setItem(REJECTED_IMAGES_STORAGE_KEY, JSON.stringify(list))
  } catch {
    // 忽略存储受限
  }
  return true
}

const parseUnsupportedImageError = (
  error: unknown
): { messageIndex: number; blockIndex: number } | null => {
  if (!(error instanceof ApiError)) {
    return null
  }
  const match =
    /messages\.(\d+)\.content\.(\d+):.*(?:unsupported image|invalid image|image is too large|too large to process)/i.exec(
      error.message
    )
  if (!match) {
    return null
  }
  return {
    messageIndex: Number.parseInt(match[1], 10),
    blockIndex: Number.parseInt(match[2], 10),
  }
}

/**
 * 根据服务端报错的 `messages.{N}.content.{M}` 定位被拒绝的历史图片 file_id。
 * 兼容服务端是否剔除/合并 `latest_reminder` 导致的索引偏移，确保一定能准确命中并跳过坏图。
 */
const resolveBadHistoryImageIds = (
  sentMessages: MessageParam[],
  messageIndex: number,
  blockIndex: number
): { ids: string[]; isCurrentTurn: boolean } => {
  const lastUserMsg = sentMessages.findLast((m) => m.role === 'user')
  const nonReminders = sentMessages.filter((m) => m.role !== 'latest_reminder')
  const candidates: MessageParam[] = []
  const direct = sentMessages[messageIndex]
  const withoutReminder = nonReminders[messageIndex]
  // 若请求中包含 latest_reminder，服务端通常按剔除/合并后的消息序号报错，优先检查无 reminder 序号，再查原始序号
  if (withoutReminder && withoutReminder !== direct) {
    candidates.push(withoutReminder)
  }
  if (direct) {
    candidates.push(direct)
  }

  for (const msg of candidates) {
    if (msg.role !== 'user' || !Array.isArray(msg.content)) {
      continue
    }
    if (msg === lastUserMsg) {
      return { ids: [], isCurrentTurn: true }
    }
    // 1. 精确命中 content[M] 或因前置文本块偏移 1 位的 content[M - 1]
    for (const idx of [blockIndex, blockIndex - 1]) {
      const block = idx >= 0 ? msg.content[idx] : undefined
      if (block?.type === 'image' && !rejectedHistoryImageIds.has(block.source.file_id)) {
        return { ids: [block.source.file_id], isCurrentTurn: false }
      }
    }
    // 2. 按图片在消息内的序号兜底
    const imageBlocks = msg.content.filter((block) => block.type === 'image')
    const byImageIdx = imageBlocks[blockIndex]
    if (
      byImageIdx?.type === 'image' &&
      !rejectedHistoryImageIds.has(byImageIdx.source.file_id)
    ) {
      return { ids: [byImageIdx.source.file_id], isCurrentTurn: false }
    }
  }

  // 3. 若候选历史用户消息本身带图但块序号仍偏移，跳过该历史消息内尚未跳过的图片，保证绝不死循环卡死
  for (const msg of candidates) {
    if (msg.role !== 'user' || msg === lastUserMsg || !Array.isArray(msg.content)) {
      continue
    }
    const ids = msg.content
      .filter((block) => block.type === 'image' && !rejectedHistoryImageIds.has(block.source.file_id))
      .map((block) => (block.type === 'image' ? block.source.file_id : ''))
      .filter(Boolean)
    if (ids.length > 0) {
      return { ids, isCurrentTurn: false }
    }
  }

  return { ids: [], isCurrentTurn: false }
}

/** 服务端单次请求允许携带的最大图片数；超出时仅在请求中裁剪最早的历史图片，本地记录完整保留。 */
const MAX_REQUEST_IMAGES = 600

const parseTooManyImagesLimit = (error: unknown): number | null => {
  if (!(error instanceof ApiError)) {
    return null
  }
  const match = /Too many images:\s*max\s+(\d+)\s+images/i.exec(error.message)
  if (!match) {
    return null
  }
  const parsed = Number.parseInt(match[1], 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null
}

/** 从最新消息往前保留最多 maxImages 张图片，超出的更早历史图片在请求中省略（不改动本地数据）。 */
const limitRequestImages = (
  messages: MessageParam[],
  maxImages = MAX_REQUEST_IMAGES
): MessageParam[] => {
  let remaining = Math.max(0, maxImages)
  let changed = false
  const result = new Array<MessageParam>(messages.length)
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i]
    if (message.role !== 'user' || typeof message.content === 'string') {
      result[i] = message
      continue
    }
    const kept: typeof message.content = []
    let droppedInMessage = false
    for (let j = message.content.length - 1; j >= 0; j--) {
      const block = message.content[j]
      if (block.type === 'image') {
        if (remaining > 0) {
          remaining -= 1
          kept.push(block)
        } else {
          droppedInMessage = true
          changed = true
        }
      } else {
        kept.push(block)
      }
    }
    if (!droppedInMessage) {
      result[i] = message
    } else {
      kept.reverse()
      result[i] = {
        ...message,
        content: kept.length > 0 ? kept : [{ type: 'text', text: '[图片]' }],
      }
    }
  }
  return changed ? result : messages
}

const stripRejectedImages = (
  messages: MessageParam[],
  rejectedIds: ReadonlySet<string>
): MessageParam[] => {
  if (rejectedIds.size === 0) {
    return messages
  }
  return messages.map((message) => {
    if (message.role !== 'user' || typeof message.content === 'string') {
      return message
    }
    const filtered = message.content.filter(
      (block) => !(block.type === 'image' && rejectedIds.has(block.source.file_id))
    )
    if (filtered.length === message.content.length) {
      return message
    }
    return {
      ...message,
      content: filtered.length > 0 ? filtered : [{ type: 'text', text: '[图片]' }],
    }
  })
}

/** 允许自动补标题的请求；手动重命名后取消本轮标题写入，包含主动清空标题的情况。 */
const titleRequests = new Set<AbortController>()

export type ImportProgress = {
  phase: 'reading' | 'merging'
  sessions: number
  images: number
}

type ChatState = {
  ready: boolean
  initError: boolean
  /** 历史导入或全部删除期间锁定交互，提交成功前仍展示原有记录。 */
  importingHistory: boolean
  importProgress: ImportProgress | null
  /** 仅列表元数据，按 updatedAt 降序；流式消息更新不会改变此数组。 */
  sessions: SessionSummary[]
  sessionCache: Record<string, Session>
  sessionLoadErrors: Record<string, boolean>
  sessionSaveErrors: Record<string, boolean>
  /** null 表示新对话（欢迎页） */
  activeId: string | null
  /** 正在生成回复的会话 */
  streaming: Record<string, AbortController>
  /** 正在后台整理记忆的会话进度 */
  compacting: Record<string, { done: number; total: number }>
}

export const useChatStore = create<ChatState>(() => ({
  ready: false,
  initError: false,
  importingHistory: false,
  importProgress: null,
  sessions: [],
  sessionCache: {},
  sessionLoadErrors: {},
  sessionSaveErrors: {},
  activeId: null,
  streaming: {},
  compacting: {},
}))

export const setImportProgress = (importProgress: ImportProgress | null) => {
  set({ importProgress })
}

const { getState: get, setState: set } = useChatStore

const sortSessions = (sessions: SessionSummary[]) =>
  [...sessions].sort((a, b) => {
    const pinA = a.pinnedAt ?? 0
    const pinB = b.pinnedAt ?? 0
    if (pinA !== pinB) {
      return pinB - pinA
    }
    return b.updatedAt - a.updatedAt
  })

const getSession = (id: string) => {
  const cache = get().sessionCache
  return Object.hasOwn(cache, id) ? cache[id] : undefined
}

const getStreamController = (id: string) => {
  const streams = get().streaming
  return Object.hasOwn(streams, id) ? streams[id] : undefined
}

const sameSummary = (a: SessionSummary, b: SessionSummary) =>
  a.title === b.title &&
  a.createdAt === b.createdAt &&
  a.updatedAt === b.updatedAt &&
  a.pinnedAt === b.pinnedAt

const sessionAccess = new Map<string, number>()
const unsavedSessions = new Set<string>()
/** 保存失败时保留原件，重试成功后才释放。 */
const pendingFiles = new Map<string, db.StoredFile[]>()
const deletingSessions = new Set<string>()
const deletionTasks = new Set<Promise<boolean>>()
const streamFlushes = new Map<string, () => void>()
let accessSequence = 0
let historyEpoch = 0
let initTask: Promise<void> | undefined
const sessionLoads = new Map<string, { promise: Promise<void> }>()

const touchSession = (id: string) => sessionAccess.set(id, ++accessSequence)

const trimSessionCache = (limitOverride?: number) => {
  const state = get()
  const limit =
    limitOverride ?? (isLowPerfDevice() ? LOW_PERF_SESSION_CACHE_LIMIT : SESSION_CACHE_LIMIT)
  const ids = Object.keys(state.sessionCache)
  if (ids.length <= limit) {
    return
  }
  const removable = ids
    .filter(
      (id) =>
        id !== state.activeId &&
        !Object.hasOwn(state.streaming, id) &&
        !unsavedSessions.has(id) &&
        !deletingSessions.has(id)
    )
    .sort((a, b) => (sessionAccess.get(a) ?? 0) - (sessionAccess.get(b) ?? 0))
  const evicted = new Set(removable.slice(0, ids.length - limit))
  for (const id of evicted) {
    sessionAccess.delete(id)
  }
  if (evicted.size > 0) {
    set({
      sessionCache: Object.fromEntries(
        Object.entries(state.sessionCache).filter(([id]) => !evicted.has(id))
      ),
    })
  }
}

const updateSession = (id: string, update: (session: Session) => Session) =>
  set((state) => {
    const previous = Object.hasOwn(state.sessionCache, id) ? state.sessionCache[id] : undefined
    if (!previous) {
      return state
    }
    const session = update(previous)
    if (session === previous) {
      return state
    }
    return {
      sessionCache: { ...state.sessionCache, [id]: session },
      sessions: sameSummary(previous, session)
        ? state.sessions
        : sortSessions(
            state.sessions.map((summary) =>
              summary.id === id ? toSessionSummary(session) : summary
            )
          ),
    }
  })

const updateReply = (sessionId: string, reply: AssistantMessage) =>
  updateSession(sessionId, (session) => {
    const messages = session.messages
    const lastIndex = messages.length - 1
    if (lastIndex >= 0 && messages[lastIndex].id === reply.id) {
      const target = messages[lastIndex]
      const nextMessages = messages.slice()
      nextMessages[lastIndex] = {
        ...reply,
        parentId: target.parentId,
        selectedChildId: target.selectedChildId,
      }
      return { ...session, messages: nextMessages }
    }
    let found = -1
    for (let i = lastIndex - 1; i >= 0; i--) {
      if (messages[i].id === reply.id) {
        found = i
        break
      }
    }
    if (found < 0) {
      return session
    }
    const target = messages[found]
    const nextMessages = messages.slice()
    nextMessages[found] = {
      ...reply,
      parentId: target.parentId,
      selectedChildId: target.selectedChildId,
    }
    return { ...session, messages: nextMessages }
  })

const savingSessions = new Set<string>()
const pendingPersistAgain = new Set<string>()
const persistRetryTimers = new Map<string, ReturnType<typeof setTimeout>>()
const persistRetryCounts = new Map<string, number>()

const clearPersistRetry = (sessionId: string) => {
  const timer = persistRetryTimers.get(sessionId)
  if (timer !== undefined) {
    clearTimeout(timer)
    persistRetryTimers.delete(sessionId)
  }
  persistRetryCounts.delete(sessionId)
}

const persist = (sessionId: string) => {
  const session = getSession(sessionId)
  if (!session) {
    return
  }
  unsavedSessions.add(sessionId)
  if (deletingSessions.has(sessionId)) {
    return
  }
  if (savingSessions.has(sessionId)) {
    // 已有进行中的大事务写入，合并到本轮结束后再写一次，避免长对话并发写爆内存或事务中止。
    pendingPersistAgain.add(sessionId)
    return
  }
  savingSessions.add(sessionId)
  const epoch = historyEpoch
  const files = pendingFiles.get(sessionId)
  void db
    .saveSession(session, files)
    .then(() => {
      savingSessions.delete(sessionId)
      if (epoch !== historyEpoch || !getSession(sessionId)) {
        pendingPersistAgain.delete(sessionId)
        clearPersistRetry(sessionId)
        return
      }
      if (pendingFiles.get(sessionId) === files) {
        pendingFiles.delete(sessionId)
      }
      clearPersistRetry(sessionId)
      if (pendingPersistAgain.delete(sessionId) || getSession(sessionId) !== session) {
        persist(sessionId)
        return
      }
      unsavedSessions.delete(sessionId)
      set((state) => ({
        sessionSaveErrors: Object.fromEntries(
          Object.entries(state.sessionSaveErrors).filter(([id]) => id !== sessionId)
        ),
      }))
      trimSessionCache()
    })
    .catch((error: unknown) => {
      savingSessions.delete(sessionId)
      pendingPersistAgain.delete(sessionId)
      db.reportStorageError('save session')(error)
      if (epoch !== historyEpoch || !getSession(sessionId) || deletingSessions.has(sessionId)) {
        clearPersistRetry(sessionId)
        return
      }
      const attempt = (persistRetryCounts.get(sessionId) ?? 0) + 1
      if (attempt <= 2) {
        persistRetryCounts.set(sessionId, attempt)
        const delay = attempt === 1 ? 1000 : 2500
        const existing = persistRetryTimers.get(sessionId)
        if (existing !== undefined) {
          clearTimeout(existing)
        }
        persistRetryTimers.set(
          sessionId,
          setTimeout(() => {
            persistRetryTimers.delete(sessionId)
            if (epoch === historyEpoch && unsavedSessions.has(sessionId)) {
              persist(sessionId)
            }
          }, delay)
        )
        return
      }
      clearPersistRetry(sessionId)
      set((state) => ({
        sessionSaveErrors: { ...state.sessionSaveErrors, [sessionId]: true },
      }))
    })
}

export const retrySaveSessions = () => {
  if (!get().importingHistory) {
    unsavedSessions.forEach((id) => {
      clearPersistRetry(id)
      persist(id)
    })
  }
}

/** 离开前先合并尚未绘制的增量；切回前台时自动重试未保存成功的会话。 */
export const bindChatPersistence = () => {
  const save = () => {
    if (get().importingHistory) {
      return
    }
    for (const [id, flush] of streamFlushes) {
      flush()
      persist(id)
    }
    for (const id of unsavedSessions) {
      if (!streamFlushes.has(id)) {
        persist(id)
      }
    }
  }
  const onResume = () => {
    if (unsavedSessions.size > 0) {
      retrySaveSessions()
    }
  }
  const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden') {
      save()
    } else if (document.visibilityState === 'visible') {
      onResume()
    }
  }
  const offLowMemory = onLowMemory(() => {
    clearMdAstCache()
    trimSessionCache(1)
  })
  document.addEventListener('visibilitychange', onVisibilityChange)
  window.addEventListener('pagehide', save)
  window.addEventListener('dsapp:native-resume', onResume)
  return () => {
    offLowMemory()
    document.removeEventListener('visibilitychange', onVisibilityChange)
    window.removeEventListener('pagehide', save)
    window.removeEventListener('dsapp:native-resume', onResume)
  }
}

/** 按当前开关创建回复：深度思考对应 thinking，智能搜索控制 deepseek_web_search。 */
const createReply = (): AssistantMessage => {
  const { thinking, search } = useSettings.getState()
  const settings = useSettings.getState()
  const resolvedModel = isUsingRankAIFree(settings)
    ? RANKAI_MODEL
    : isUsingDeepSeekAccount(settings)
      ? MODEL
      : settings.apiModel.trim() || MODEL
  const billingSource: AssistantMessage['billingSource'] = isUsingRankAIFree(settings)
    ? 'rankai'
    : isBillingSupportedSettings(settings)
      ? 'deepseek'
      : undefined
  return {
    id: createId(),
    role: 'assistant',
    createdAt: Date.now(),
    model: resolvedModel,
    thinking,
    search,
    prefix: true,
    status: 'pending',
    blocks: [],
    ...(billingSource ? { billingSource } : {}),
  }
}

/** 仍在生成中的回复（页面关闭或导出时未结束）按「已停止」处理 */
const settleInterrupted = (session: Session): Session => {
  if (
    !session.messages.some(
      (m) => m.role === 'assistant' && (m.status === 'pending' || m.status === 'streaming')
    )
  ) {
    return session
  }
  return {
    ...session,
    messages: session.messages.map((m) =>
      m.role === 'assistant' && (m.status === 'pending' || m.status === 'streaming')
        ? settleReply(m, 'stopped', session.updatedAt)
        : m
    ),
  }
}

export const initChat = (): Promise<void> => {
  if (get().ready) {
    return Promise.resolve()
  }
  if (initTask) {
    return initTask
  }
  const epoch = historyEpoch
  set({ initError: false })
  initTask = (async () => {
    try {
      const summaries = await db.loadSessionSummaries()
      if (epoch === historyEpoch) {
        set({ ready: true, sessions: sortSessions(summaries) })
      }
    } catch (error) {
      if (epoch === historyEpoch) {
        set({ initError: true })
        db.reportStorageError('read local sessions')(error)
      }
    } finally {
      if (epoch === historyEpoch) {
        initTask = undefined
      }
    }
  })()
  return initTask
}

/** 同一会话合并并发读取；切换只改变 activeId，旧请求不会把界面切回去。 */
const ensureSessionLoaded = (id: string): Promise<void> => {
  if (getSession(id)) {
    return Promise.resolve()
  }
  const pending = sessionLoads.get(id)
  if (pending) {
    return pending.promise
  }
  const epoch = historyEpoch
  set((state) => ({ sessionLoadErrors: { ...state.sessionLoadErrors, [id]: false } }))
  const load = { promise: Promise.resolve() }
  sessionLoads.set(id, load)
  load.promise = (async () => {
    try {
      const stored = await db.loadSession(id)
      if (epoch !== historyEpoch || sessionLoads.get(id) !== load) {
        return
      }
      const summary = get().sessions.find((session) => session.id === id)
      if (!summary) {
        return
      }
      if (!stored) {
        throw new Error(`Session ${id} is missing from local storage`)
      }
      const settled = settleInterrupted(normalizeSession(stored))
      // 读取期间可能已在列表重命名，保留最新元数据，不能让旧读取覆盖它。
      const session = sameSummary(settled, summary) ? settled : { ...settled, ...summary }
      touchSession(id)
      set((state) => ({ sessionCache: { ...state.sessionCache, [id]: session } }))
      if (session !== stored) {
        persist(id)
      }
      trimSessionCache()
    } catch (error) {
      if (epoch === historyEpoch && sessionLoads.get(id) === load) {
        set((state) => ({ sessionLoadErrors: { ...state.sessionLoadErrors, [id]: true } }))
        db.reportStorageError('read session')(error)
      }
    } finally {
      if (sessionLoads.get(id) === load) {
        sessionLoads.delete(id)
      }
    }
  })()
  return load.promise
}

/** 等所有回复的收尾（落盘）完成 */
const waitForIdle = (sessionId?: string) =>
  new Promise<void>((resolve) => {
    const isIdle = (state: ChatState) =>
      sessionId === undefined
        ? Object.keys(state.streaming).length === 0
        : !Object.hasOwn(state.streaming, sessionId)
    if (isIdle(get())) {
      resolve()
      return
    }
    const unsubscribe = useChatStore.subscribe((state) => {
      if (isIdle(state)) {
        unsubscribe()
        resolve()
      }
    })
  })

/**
 * 替换历史对话：先写入暂存，成功后原子替换旧记录；写入为空即删除全部会话与附件。
 * 期间停止生成并禁止修改会话；失败时清除暂存，保留原有记录。
 */
export const replaceHistory = async (write: () => Promise<void>): Promise<number> => {
  if (get().importingHistory) {
    throw new Error('History replacement is already in progress')
  }
  set({ importingHistory: true })
  try {
    for (const controller of Object.values(get().streaming)) {
      controller.abort()
    }
    // 已开始的单条删除先同步到内存，避免本次替换失败后列表残留已被删除的记录。
    await Promise.all(deletionTasks)
    historyEpoch += 1
    initTask = undefined
    sessionLoads.clear()
    await waitForIdle()
    await db.clearStaging()
    let summaries: SessionSummary[]
    try {
      await write()
      summaries = await db.commitStaging()
    } catch (error) {
      await db.clearStaging().catch(db.reportStorageError('clear unfinished history replacement'))
      throw error
    }
    sessionAccess.clear()
    unsavedSessions.clear()
    pendingFiles.clear()
    clearAllDrafts()
    set({
      ready: true,
      initError: false,
      sessions: sortSessions(summaries),
      sessionCache: {},
      sessionLoadErrors: {},
      sessionSaveErrors: {},
      activeId: null,
    })
    return summaries.length
  } finally {
    set({ importingHistory: false })
    retrySaveSessions()
    const { activeId, ready } = get()
    // 替换失败时恢复被取消的详情读取，原有记录继续可用。
    if (activeId !== null) {
      void ensureSessionLoaded(activeId)
    } else if (!ready) {
      void initChat()
    }
  }
}

/**
 * 增量合并历史对话：先写入暂存，成功后按会话 ID 合并进本地记录，保留已有对话。
 */
export const mergeHistory = async (write: () => Promise<void>): Promise<number> => {
  if (get().importingHistory) {
    throw new Error('History import is already in progress')
  }
  set({ importingHistory: true, importProgress: { phase: 'reading', sessions: 0, images: 0 } })
  try {
    for (const controller of Object.values(get().streaming)) {
      controller.abort()
    }
    await Promise.all(deletionTasks)
    historyEpoch += 1
    initTask = undefined
    sessionLoads.clear()
    await waitForIdle()
    await db.clearStaging()
    let result: { importedCount: number; summaries: SessionSummary[] }
    try {
      await write()
      const current = get().importProgress
      set({
        importProgress: {
          phase: 'merging',
          sessions: current?.sessions ?? 0,
          images: current?.images ?? 0,
        },
      })
      result = await db.mergeStaging()
    } catch (error) {
      await db.clearStaging().catch(db.reportStorageError('clear unfinished history merge'))
      throw error
    }
    set({
      ready: true,
      initError: false,
      sessions: sortSessions(result.summaries),
      sessionCache: {},
      sessionLoadErrors: {},
    })
    return result.importedCount
  } finally {
    set({ importingHistory: false, importProgress: null })
    retrySaveSessions()
    const { activeId, ready } = get()
    if (activeId !== null) {
      void ensureSessionLoaded(activeId)
    } else if (!ready) {
      void initChat()
    }
  }
}

export const importSingleSession = async (session: Session): Promise<void> => {
  if (get().importingHistory) {
    throw new Error('History import is already in progress')
  }
  await db.saveSession(session)
  touchSession(session.id)
  set((state) => ({
    ready: true,
    initError: false,
    sessions: sortSessions([
      toSessionSummary(session),
      ...state.sessions.filter((item) => item.id !== session.id),
    ]),
    sessionCache: { ...state.sessionCache, [session.id]: session },
    activeId: session.id,
  }))
  trimSessionCache()
}

export const newChat = (options?: { silentIfAlreadyNew?: boolean }): boolean => {
  if (get().importingHistory) {
    return false
  }
  if (get().activeId === null) {
    if (!options?.silentIfAlreadyNew) {
      showToast({ key: 'alreadyInNewChat' })
    }
    return false
  }
  set({ activeId: null })
  trimSessionCache()
  return true
}

export const selectSession = (id: string) => {
  if (!get().importingHistory && get().sessions.some((session) => session.id === id)) {
    touchSession(id)
    set({ activeId: id })
    void ensureSessionLoaded(id)
    trimSessionCache()
  }
}

export const renameSession = (id: string, title: string) => {
  if (get().importingHistory || deletingSessions.has(id)) {
    return
  }
  const controller = getStreamController(id)
  if (controller) {
    titleRequests.delete(controller)
  }
  if (getSession(id)) {
    updateSession(id, (session) => ({ ...session, title }))
    persist(id)
  } else {
    set((state) => ({
      sessions: state.sessions.map((session) =>
        session.id === id ? { ...session, title } : session
      ),
    }))
    void db.renameSession(id, title).catch(db.reportStorageError('rename session'))
  }
}

export const togglePinSession = (id: string) => {
  if (get().importingHistory || deletingSessions.has(id)) {
    return
  }
  const summary = get().sessions.find((session) => session.id === id)
  if (!summary) {
    return
  }
  const nextPinnedAt = summary.pinnedAt ? undefined : Date.now()
  if (getSession(id)) {
    updateSession(id, (session) => {
      const next: Session = { ...session }
      if (nextPinnedAt) {
        next.pinnedAt = nextPinnedAt
      } else {
        delete next.pinnedAt
      }
      return next
    })
    persist(id)
  } else {
    set((state) => ({
      sessions: sortSessions(
        state.sessions.map((session) => {
          if (session.id !== id) {
            return session
          }
          const next: SessionSummary = { ...session }
          if (nextPinnedAt) {
            next.pinnedAt = nextPinnedAt
          } else {
            delete next.pinnedAt
          }
          return next
        })
      ),
    }))
    void db.setSessionPinned(id, nextPinnedAt).catch(db.reportStorageError('pin session'))
  }
}

export const setSessionsPinned = (ids: string[], pinned: boolean) => {
  if (get().importingHistory || ids.length === 0) {
    return
  }
  const baseTime = Date.now()
  ids.forEach((id, index) => {
    if (deletingSessions.has(id)) {
      return
    }
    const nextPinnedAt = pinned ? baseTime + (ids.length - index) : undefined
    if (getSession(id)) {
      updateSession(id, (session) => {
        const next: Session = { ...session }
        if (nextPinnedAt) {
          next.pinnedAt = nextPinnedAt
        } else {
          delete next.pinnedAt
        }
        return next
      })
      persist(id)
    } else {
      set((state) => ({
        sessions: sortSessions(
          state.sessions.map((session) => {
            if (session.id !== id) {
              return session
            }
            const next: SessionSummary = { ...session }
            if (nextPinnedAt) {
              next.pinnedAt = nextPinnedAt
            } else {
              delete next.pinnedAt
            }
            return next
          })
        ),
      }))
      void db.setSessionPinned(id, nextPinnedAt).catch(db.reportStorageError('pin session'))
    }
  })
}

/**
 * 删除会话；本地原件仅在没有其他会话引用时清理。远端文件不删：导入、编辑、重新生成都会复用同一个附件，
 * 同一服务端文件可能被多个会话引用，不维护引用计数。
 */
export const removeSession = (id: string): Promise<boolean> => {
  const task = removeSessionData(id).finally(() => deletionTasks.delete(task))
  deletionTasks.add(task)
  return task
}

const removeSessionData = async (id: string): Promise<boolean> => {
  if (get().importingHistory || deletingSessions.has(id)) {
    return false
  }
  const epoch = historyEpoch
  deletingSessions.add(id)
  try {
    getStreamController(id)?.abort()
    // 等本会话的流收尾，避免删除之后又被收尾保存写回来。
    await waitForIdle(id)
    if (epoch !== historyEpoch) {
      return false
    }
    await db.deleteSession(id)
    if (epoch !== historyEpoch) {
      return true
    }
    sessionLoads.delete(id)
    sessionAccess.delete(id)
    unsavedSessions.delete(id)
    pendingFiles.delete(id)
    clearDraft(id)
    set((state) => ({
      sessions: state.sessions.filter((session) => session.id !== id),
      sessionCache: Object.fromEntries(
        Object.entries(state.sessionCache).filter(([key]) => key !== id)
      ),
      sessionLoadErrors: Object.fromEntries(
        Object.entries(state.sessionLoadErrors).filter(([key]) => key !== id)
      ),
      sessionSaveErrors: Object.fromEntries(
        Object.entries(state.sessionSaveErrors).filter(([key]) => key !== id)
      ),
      activeId: state.activeId === id ? null : state.activeId,
    }))
    return true
  } catch (error) {
    db.reportStorageError('delete session')(error)
    return false
  } finally {
    deletingSessions.delete(id)
    // 删除失败时保留会话，并保存停止生成后的最新状态。
    if (getSession(id)) {
      if (get().importingHistory) {
        unsavedSessions.add(id)
      } else {
        persist(id)
      }
    }
  }
}

export const stopReply = (sessionId: string) => getStreamController(sessionId)?.abort()

/**
 * 提交指定会话的最新草稿；null 表示新建会话。
 * 同步接收成功才清空草稿，附件原件由会话接管；保存失败仍通过保存入口重试。
 */
export const sendMessage = (targetSessionId: string | null) => {
  if (get().importingHistory || !get().ready) {
    return false
  }
  const prepared = prepareDraftMessage(getDraft(targetSessionId), useUploads.getState().tasks)
  if (!prepared) {
    return false
  }
  const { text, files } = prepared
  const now = Date.now()
  let sessionId = targetSessionId
  if (
    sessionId !== null &&
    (deletingSessions.has(sessionId) || getStreamController(sessionId) || !getSession(sessionId))
  ) {
    return false
  }
  if (sessionId === null) {
    const session: Session = {
      id: createId(),
      title: '',
      createdAt: now,
      updatedAt: now,
      messages: [],
      rootMessageId: null,
    }
    sessionId = session.id
    touchSession(session.id)
    set((state) => ({
      sessions: sortSessions([toSessionSummary(session), ...state.sessions]),
      sessionCache: { ...state.sessionCache, [session.id]: session },
      activeId: session.id,
    }))
  }
  const current = getSession(sessionId)
  if (!current) {
    return false
  }
  const history = getVisibleMessages(current)
  const question: UserMessage = {
    id: createId(),
    role: 'user',
    content: text,
    files: files.map(({ id, serverId, name, size, isImage, mimeType }) => ({
      id,
      serverId,
      name,
      size,
      isImage,
      mimeType,
    })),
    createdAt: now,
  }
  const reply = createReply()
  updateSession(sessionId, (session) => ({
    ...appendBranch(session, history.at(-1)?.id ?? null, [question, reply]),
    updatedAt: now,
  }))
  if (files.length > 0) {
    pendingFiles.set(sessionId, [
      ...(pendingFiles.get(sessionId) ?? []),
      ...files.map(({ id, blob }) => ({ id, blob })),
    ])
  }
  persist(sessionId)
  clearSentDraft(targetSessionId)
  void streamReply(sessionId, reply, { history, question })
  return true
}

/** 重新生成当前路径上的回答：在原问题下新增版本，不覆盖旧回答和后续对话。 */
export const regenerateReply = (sessionId: string, messageId?: string) => {
  if (get().importingHistory || deletingSessions.has(sessionId)) {
    return
  }
  const session = getSession(sessionId)
  if (!session || getStreamController(sessionId)) {
    return
  }
  const path = getVisibleMessages(session)
  const index =
    messageId === undefined ? path.length - 1 : path.findIndex((m) => m.id === messageId)
  const question = path[index - 1]
  if (question?.role !== 'user' || path[index]?.role !== 'assistant') {
    return
  }
  const history = path.slice(0, index - 1)
  const reply = createReply()
  updateSession(sessionId, (s) => ({
    ...appendBranch(s, question.id, [reply]),
    updatedAt: Date.now(),
  }))
  persist(sessionId)
  void streamReply(sessionId, reply, { history, question })
}

/** 编辑提问后新增同父版本，保留原文件；旧问题的所有回答与后续对话仍可切回。 */
export const editMessage = (sessionId: string, messageId: string, content: string): boolean => {
  if (get().importingHistory || deletingSessions.has(sessionId)) {
    return false
  }
  const session = getSession(sessionId)
  if (!session || getStreamController(sessionId)) {
    return false
  }
  const path = getVisibleMessages(session)
  const index = path.findIndex((message) => message.id === messageId)
  const previous = path[index]
  const text = content.trim()
  if (previous?.role !== 'user' || (!text && previous.files.length === 0)) {
    return false
  }
  const question: UserMessage = {
    id: createId(),
    role: 'user',
    content: text,
    files: previous.files,
    createdAt: Date.now(),
  }
  const reply = createReply()
  updateSession(sessionId, (s) => ({
    ...appendBranch(s, path[index - 1]?.id ?? null, [question, reply]),
    updatedAt: Date.now(),
  }))
  persist(sessionId)
  void streamReply(sessionId, reply, { history: path.slice(0, index), question })
  return true
}

export const selectMessageVersion = (sessionId: string, messageId: string) => {
  if (get().importingHistory || deletingSessions.has(sessionId)) {
    return
  }
  if (getStreamController(sessionId)) {
    return
  }
  updateSession(sessionId, (session) => selectVersion(session, messageId))
  persist(sessionId)
}

/** 继续最后一条未完成的回答：保留原消息与开关，仅将新流的内容追加到原块之后。 */
export const continueReply = (sessionId: string, messageId: string) => {
  if (get().importingHistory || deletingSessions.has(sessionId)) {
    return
  }
  const session = getSession(sessionId)
  if (!session || getStreamController(sessionId)) {
    return
  }
  const path = getVisibleMessages(session)
  const question = path.at(-2)
  const previous = path.at(-1)
  if (
    question?.role !== 'user' ||
    previous?.role !== 'assistant' ||
    previous.id !== messageId ||
    !canContinueReply(previous)
  ) {
    return
  }
  const { thinking, search } = useSettings.getState()
  const reply: AssistantMessage = {
    ...previous,
    // 未记录请求配置的回复，续写时使用默认模型和当前开关。
    model: previous.model ?? MODEL,
    thinking: previous.thinking ?? thinking,
    search: previous.search ?? search,
    status: 'pending',
    stopReason: undefined,
    stopDetails: undefined,
    error: undefined,
  }
  updateReply(sessionId, reply)
  updateSession(sessionId, (s) => ({ ...s, updatedAt: Date.now() }))
  persist(sessionId)
  void streamReply(sessionId, reply, { history: path.slice(0, -2), question, prefix: previous })
}

/** 附件补传失败后重试：保留原回答位置，重新补传并请求 */
export const retryUpload = (sessionId: string, messageId: string) => {
  if (get().importingHistory || deletingSessions.has(sessionId)) {
    return
  }
  const session = getSession(sessionId)
  if (!session || getStreamController(sessionId)) {
    return
  }
  const path = getVisibleMessages(session)
  const index = path.findIndex((message) => message.id === messageId)
  const question = path[index - 1]
  const previous = path[index]
  if (
    question?.role !== 'user' ||
    previous?.role !== 'assistant' ||
    previous.error?.kind !== 'upload'
  ) {
    return
  }
  const reply: AssistantMessage = { ...previous, status: 'pending', error: undefined }
  updateReply(sessionId, reply)
  persist(sessionId)
  void streamReply(sessionId, reply, { history: path.slice(0, index - 1), question })
}

type Request = { history: Message[]; question: UserMessage; prefix?: AssistantMessage }

/** 把补传得到的 serverId 写回会话里所有引用同一附件的消息（编辑、重新生成会共用附件） */
const saveServerIds = (sessionId: string, serverIds: Map<string, string>) => {
  if (serverIds.size === 0) {
    return
  }
  updateSession(sessionId, (session) => ({
    ...session,
    messages: session.messages.map((message) =>
      message.role === 'user' && message.files.some((file) => serverIds.has(file.id))
        ? {
            ...message,
            files: message.files.map((file) =>
              serverIds.has(file.id) ? { ...file, serverId: serverIds.get(file.id) ?? null } : file
            ),
          }
        : message
    ),
  }))
  persist(sessionId)
}

const MAX_OPENAI_INLINE_IMAGES = 16
const MAX_OPENAI_INLINE_IMAGE_BYTES = 20 * 1024 * 1024

const assertNotAborted = (signal: AbortSignal) => {
  if (signal.aborted) {
    const reason = (signal as AbortSignal & { reason?: unknown }).reason
    throw reason !== undefined
      ? reason
      : typeof DOMException === 'function'
        ? new DOMException('The operation was aborted.', 'AbortError')
        : new Error('Aborted')
  }
}

const isOpenAIProtocolActive = () =>
  isUsingRankAIFree() || (!isUsingDeepSeekAccount() && useSettings.getState().apiProtocol === 'openai')

const loadLocalFileBlob = async (sessionId: string, fileId: string): Promise<Blob | null> => {
  const inMemory = pendingFiles.get(sessionId)?.find((entry) => entry.id === fileId)
  if (inMemory) {
    return inMemory.blob
  }
  return (await db.loadFile(fileId)) ?? null
}

const buildOpenAIImageBlock = async (
  sessionId: string,
  file: FileAttachment
): Promise<InlineImageBlockParam | null> => {
  if (!file.isImage) {
    return null
  }
  const blob = await loadLocalFileBlob(sessionId, file.id)
  if (!blob || blob.size === 0) {
    return null
  }
  const normalized = await normalizeImageForUpload(blob, file.name)
  if (normalized.size === 0 || normalized.size > MAX_OPENAI_INLINE_IMAGE_BYTES) {
    return null
  }
  const url = await blobToDataUrl(normalized)
  return url ? { type: 'image_url', image_url: { url } } : null
}

const buildOpenAIRequestMessages = async (
  sessionId: string,
  request: Request,
  signal: AbortSignal,
  imageCap: number,
  compactions?: CompactionSpan[]
): Promise<MessageParam[]> => {
  const projected = projectContextItems(request.history, compactions)
  let remaining = Math.min(MAX_OPENAI_INLINE_IMAGES, Math.max(0, imageCap))
  const questionBlocks: InlineImageBlockParam[] = []
  for (const file of request.question.files) {
    if (!file.isImage || remaining <= 0) {
      continue
    }
    assertNotAborted(signal)
    const block = await buildOpenAIImageBlock(sessionId, file)
    if (block) {
      questionBlocks.push(block)
      remaining -= 1
    }
  }

  const historyBlocksByItem = new Map<number, InlineImageBlockParam[]>()
  for (let i = projected.length - 1; i >= 0 && remaining > 0; i--) {
    const item = projected[i]
    if (item.type !== 'round') {
      continue
    }
    const { user } = item
    if (!user.files.some((file) => file.isImage)) {
      continue
    }
    const collected: InlineImageBlockParam[] = []
    for (let j = user.files.length - 1; j >= 0 && remaining > 0; j--) {
      const file = user.files[j]
      if (!file.isImage) {
        continue
      }
      assertNotAborted(signal)
      const block = await buildOpenAIImageBlock(sessionId, file)
      if (block) {
        collected.push(block)
        remaining -= 1
      }
    }
    if (collected.length > 0) {
      historyBlocksByItem.set(i, collected.reverse())
    }
  }

  const messages: MessageParam[] = []
  for (let i = 0; i < projected.length; i++) {
    const item = projected[i]
    if (item.type === 'compaction') {
      const [userMem, assistantAck] = toCompactionMessagePair(item.span)
      messages.push(userMem, assistantAck)
      continue
    }
    const { user, reply } = item
    const imageBlocks = historyBlocksByItem.get(i) ?? []
    if (!user.content && imageBlocks.length === 0) {
      continue
    }
    const recalledPrefix = reply.recalledMemory?.blockText
    const userText = recalledPrefix ? `${recalledPrefix}\n\n${user.content}` : user.content
    messages.push({
      role: 'user',
      content:
        imageBlocks.length > 0
          ? [...imageBlocks, ...(userText ? [{ type: 'text' as const, text: userText }] : [])]
          : userText,
    })
    messages.push({
      role: 'assistant',
      content: [{ type: 'text', text: getReplyText(reply) }],
    })
  }
  messages.push({
    role: 'user',
    content:
      questionBlocks.length > 0
        ? [
            ...questionBlocks,
            ...(request.question.content
              ? [{ type: 'text' as const, text: request.question.content }]
              : []),
          ]
        : request.question.content,
  })
  if (request.prefix?.prefix) {
    const prefixText = getReplyText(request.prefix)
    if (prefixText.trim()) {
      messages.push({
        role: 'assistant',
        content: [{ type: 'text', text: prefixText }],
      })
    }
  }
  return messages
}

/**
 * 附件的服务端 id：已有直接用；正在上传的等待同一任务；否则读取本地原件补传。
 * 本地也没有原件（导入的文档附件只有元数据）时返回 null，该附件只展示、不进入请求。
 */
const ensureServerId = async (apiKey: string, file: FileAttachment): Promise<string | null> => {
  if (file.serverId) {
    return file.serverId
  }
  const task = useUploads.getState().tasks[file.id]
  if (task?.status === 'done' && task.serverId) {
    return task.serverId
  }
  const blob = await db.loadFile(file.id)
  if (!blob) {
    return null
  }
  return uploadAttachment(apiKey, file.id, blob, file.name, file.isImage)
}

/** 用会话里的最新消息替换请求快照：重传前会重置附件的 serverId，快照必须跟着更新 */
const refreshRequest = (sessionId: string, request: Request): Request => {
  const session = getSession(sessionId)
  if (!session) {
    return request
  }
  const byId = new Map(session.messages.map((message) => [message.id, message]))
  const pick = <T extends Message>(message: T): T =>
    (byId.get(message.id) as T | undefined) ?? message
  return {
    history: request.history.map(pick),
    question: pick(request.question),
    prefix: request.prefix,
  }
}

/**
 * 发送前补齐附件的 serverId。
 * - 本轮提问的附件并行补齐，任一失败则整体失败，已成功的照常写回，重试时复用成功结果；
 * - 历史轮次（仅进入上下文的）中没有 serverId 的附件，多为导入的图片：从最新的消息往前逐张补传，
 *   失败静默跳过，该附件不进入本次请求，下次发送时再试。
 */
const prepareFiles = async (sessionId: string, request: Request, signal: AbortSignal) => {
  const epoch = historyEpoch
  // 服务端判定 file_id 失效时会清掉会话里的 serverId，先用最新消息替换请求快照，
  // 否则快照里仍是旧 id，补传会直接复用它。
  request = refreshRequest(sessionId, request)
  // OpenAI 兼容协议直接走内联 base64 image_url，不调用 Anthropic Files API。
  if (isOpenAIProtocolActive()) {
    return request
  }
  const apiKey = getActiveSecret()
  const serverIds = new Map<string, string>()
  // 停止生成立即生效；上传本身不取消（输入框与其他消息可能共用同一任务），完成后照常写回 serverId
  const aborted = new Promise<never>((_, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true })
  })
  const uploads = Promise.allSettled(
    request.question.files.map(async (file) => {
      const serverId = await ensureServerId(apiKey, file)
      if (serverId) {
        serverIds.set(file.id, serverId)
      }
    })
  )
  void uploads.then(() => {
    if (epoch === historyEpoch) {
      saveServerIds(sessionId, serverIds)
    }
  })
  const results = await Promise.race([uploads, aborted])
  const failed = results.find((result) => result.status === 'rejected')
  if (failed) {
    throw failed.reason
  }

  const pending = new Map<string, FileAttachment>()
  let imageBudget = Math.max(
    0,
    MAX_REQUEST_IMAGES - request.question.files.filter((file) => file.isImage).length
  )
  for (const [user] of getContextRounds(request.history).toReversed()) {
    for (const file of user.files.toReversed()) {
      if (file.isImage) {
        if (imageBudget <= 0) {
          continue
        }
        imageBudget -= 1
      }
      if (!file.serverId && !serverIds.has(file.id) && !pending.has(file.id)) {
        pending.set(file.id, file)
      }
    }
  }
  for (const file of pending.values()) {
    assertNotAborted(signal)
    try {
      const serverId = await Promise.race([ensureServerId(apiKey, file), aborted])
      if (serverId) {
        serverIds.set(file.id, serverId)
        saveServerIds(sessionId, new Map([[file.id, serverId]]))
      }
    } catch {
      assertNotAborted(signal)
    }
  }

  // 用补齐后的会话重新取历史与提问，保证请求里都是 serverId
  const session = getSession(sessionId)
  const resolve = <T extends Message>(message: T): T =>
    (session?.messages.find((m) => m.id === message.id) as T | undefined) ?? message
  return {
    history: request.history.map(resolve),
    question: resolve(request.question),
    prefix: request.prefix,
  }
}

/** 本次请求实际会用到的服务端 file_id */
const collectServerFileIds = (request: Request): Set<string> => {
  const ids = new Set<string>()
  const add = (files: FileAttachment[]) => {
    for (const file of files) {
      if (file.serverId) {
        ids.add(file.serverId)
      }
    }
  }
  add(request.question.files)
  for (const [user] of getContextRounds(request.history)) {
    add(user.files)
  }
  return ids
}

/**
 * 服务端判定 file_id 失效时，清掉对应附件的 serverId 并丢弃旧的上传任务，
 * 下一次补齐会重新读取本地原件上传。报错里点名了 file_id 就只重置这些，
 * 没点名（如 invalid file_id）则重置本次请求用到的全部附件。
 */
const reuploadInvalidatedFiles = (sessionId: string, request: Request, error: unknown): boolean => {
  if (!(error instanceof ApiError) || !getFileErrorCode(error)) {
    return false
  }
  const mentioned = extractFileIds(error.message)
  // 重试时原始快照里还是上一轮已被清掉的 serverId，先换成会话里的最新消息
  const targets =
    mentioned.length > 0
      ? new Set(mentioned)
      : collectServerFileIds(refreshRequest(sessionId, request))
  const session = getSession(sessionId)
  if (targets.size === 0 || !session) {
    return false
  }
  const localIds: string[] = []
  const messages = session.messages.map((message) => {
    if (message.role !== 'user') {
      return message
    }
    let changed = false
    const files = message.files.map((file) => {
      if (!file.serverId || !targets.has(file.serverId)) {
        return file
      }
      localIds.push(file.id)
      changed = true
      return { ...file, serverId: null }
    })
    return changed ? { ...message, files } : message
  })
  if (localIds.length === 0) {
    return false
  }
  updateSession(sessionId, (current) => ({ ...current, messages }))
  // 上传任务里可能还留着同一个失效的 serverId，清掉后 ensureServerId 才会重新上传
  localIds.forEach(cancelUpload)
  persist(sessionId)
  return true
}

/** 重传前的退避等待；停止生成时立即返回，由调用方按已停止收尾 */
const waitForRetry = (attempt: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    function onAbort() {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(
      () => {
        signal.removeEventListener('abort', onAbort)
        resolve()
      },
      FILE_RETRY_BASE_DELAY * 2 ** attempt
    )
    signal.addEventListener('abort', onAbort, { once: true })
  })

let streamKeepAliveActive = false

const syncStreamKeepAlive = () => {
  const state = get()
  const active =
    Object.keys(state.streaming).length > 0 || Object.keys(state.compacting).length > 0
  if (active === streamKeepAliveActive) {
    return
  }
  streamKeepAliveActive = active
  setNativeStreamKeepAlive(active)
}

/** 等待页面回到前台（或原生层 resume）；超时或停止生成时返回 false */
const waitForForegroundResume = (signal: AbortSignal, maxWaitMs: number): Promise<boolean> => {
  if (signal.aborted) {
    return Promise.resolve(false)
  }
  if (typeof document === 'undefined' || document.visibilityState === 'visible') {
    return Promise.resolve(true)
  }
  return new Promise<boolean>((resolve) => {
    let settled = false
    const finish = (resumed: boolean) => {
      if (settled) {
        return
      }
      settled = true
      clearTimeout(timer)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('dsapp:native-resume', onResume)
      signal.removeEventListener('abort', onAbort)
      resolve(resumed)
    }
    const onVisibility = () => {
      if (document.visibilityState === 'visible') {
        finish(true)
      }
    }
    const onResume = () => {
      if (document.visibilityState === 'visible') {
        finish(true)
      }
    }
    const onAbort = () => finish(false)
    const timer = setTimeout(() => finish(false), maxWaitMs)
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('dsapp:native-resume', onResume)
    signal.addEventListener('abort', onAbort, { once: true })
  })
}

const waitAbortableDelay = (ms: number, signal: AbortSignal): Promise<boolean> => {
  if (signal.aborted) {
    return Promise.resolve(false)
  }
  return new Promise<boolean>((resolve) => {
    const onAbort = () => {
      clearTimeout(timer)
      resolve(false)
    }
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort)
      resolve(true)
    }, ms)
    signal.addEventListener('abort', onAbort, { once: true })
  })
}

/**
 * 请求并消费流：先补齐附件的 serverId，再发请求；流式增量按动画帧刷新内存，完成、失败或停止后落盘。
 * 补传失败时回复记为 upload 错误，可重试。
 * 服务端判定 file_id 失效时重新补传后重发，退避重试且次数有上限，超过则按原始报错收尾。
 */
const streamReply = async (sessionId: string, initial: AssistantMessage, request: Request) => {
  const controller = new AbortController()
  if (!getSession(sessionId)?.title) {
    titleRequests.add(controller)
  }
  set((state) => ({ streaming: { ...state.streaming, [sessionId]: controller } }))
  syncStreamKeepAlive()
  let reply = initial
  let frame = 0
  let flushTimer: ReturnType<typeof setTimeout> | null = null
  let dropExtendedFor1M = false
  let skippedBadImages = 0
  let imageCap = MAX_REQUEST_IMAGES
  let sentMessages: MessageParam[] = []
  let cachedPrepared: Request | null = null
  let sawBackground = typeof document !== 'undefined' && document.visibilityState === 'hidden'
  let backgroundedAt = sawBackground ? Date.now() : 0
  let backgroundRetryUsed = false
  const trackVisibility = () => {
    if (document.visibilityState === 'hidden') {
      sawBackground = true
      backgroundedAt = Date.now()
    }
  }
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', trackVisibility)
  }
  const cancelScheduledFlush = () => {
    if (frame) {
      cancelAnimationFrame(frame)
      frame = 0
    }
    if (flushTimer !== null) {
      clearTimeout(flushTimer)
      flushTimer = null
    }
  }
  const flush = () => {
    cancelScheduledFlush()
    updateReply(sessionId, reply)
  }
  streamFlushes.set(sessionId, flush)

  try {
    for (let attempt = 0; ; attempt += 1) {
      /** 附件补齐前出错属于上传失败，请求还没有发出 */
      let preparing = !cachedPrepared
      let receivedContent = false
      try {
        const prepared: Request =
          cachedPrepared ?? (await prepareFiles(sessionId, request, controller.signal))
        const firstPrepared = !cachedPrepared
        cachedPrepared = prepared
        preparing = false
        // 附件就绪后获取本轮信息；续写沿用原回答快照，重新生成的快照独立保存。
        const latestReminder = prepared.prefix
          ? prepared.prefix.latestReminder
          : createLatestReminder(useSettings.getState())
        if (firstPrepared) {
          reply = { ...reply, latestReminder }
          updateReply(sessionId, reply)
          persist(sessionId)
        }
        const currentSession = get().sessionCache[sessionId]
        const initialCompactions = currentSession?.compactions
        const autoCompactEnabled = currentSession?.autoCompact === true
        // 发送前检查：仅当当前会话主动开启自动压缩，且上下文达到阈值时，才在回复气泡内自动分块整理。
        if (
          firstPrepared &&
          !prepared.prefix &&
          autoCompactEnabled &&
          selectCompactionTarget(prepared.history, initialCompactions, 'auto') !== null
        ) {
          await compactSession(sessionId, 'auto', controller.signal, prepared.history)
          assertNotAborted(controller.signal)
        }
        const sessionCompactions = get().sessionCache[sessionId]?.compactions
        // V1 纯本地 0 延迟记忆回溯：仅对当前请求在 Zone 4 临时注入，不修改本地原消息，不破坏 Prefix Cache
        const recalled = prepared.prefix
          ? null
          : recallRelevantHistory(prepared.question.content, prepared.history, sessionCompactions)
        if (firstPrepared && recalled) {
          reply = {
            ...reply,
            recalledMemory: {
              roundNumbers: recalled.roundNumbers,
              spanTitles: recalled.spanTitles,
              blockText: recalled.blockText,
            },
          }
          updateReply(sessionId, reply)
          persist(sessionId)
        }
        const requestQuestion: UserMessage = recalled
          ? {
              ...prepared.question,
              content: `${recalled.blockText}\n\n${prepared.question.content}`,
            }
          : prepared.question
        const requestForSend: Request = recalled
          ? { ...prepared, question: requestQuestion }
          : prepared
        const projectedHistory: RequestHistoryItem[] = projectContextItems(
          prepared.history,
          sessionCompactions
        ).map((item) =>
          item.type === 'compaction'
            ? { type: 'compaction', pair: toCompactionMessagePair(item.span) }
            : item
        )
        const messages = isOpenAIProtocolActive()
          ? await buildOpenAIRequestMessages(
              sessionId,
              requestForSend,
              controller.signal,
              imageCap,
              sessionCompactions
            )
          : limitRequestImages(
              stripRejectedImages(
                toRequestMessages(
                  prepared.history,
                  requestQuestion,
                  prepared.prefix,
                  initial.thinking ?? false,
                  latestReminder,
                  projectedHistory
                ),
                rejectedHistoryImageIds
              ),
              imageCap
            )
        sentMessages = messages
        const configuredModel = useSettings.getState().apiModel.trim()
        const resolvedModel = isUsingDeepSeekAccount()
          ? MODEL
          : isUsingRankAIFree()
            ? RANKAI_MODEL
            : configuredModel || initial.model || MODEL
        // 服务端只要收到 tools 或 title.enabled 就会把用户输入上限降到 32,768 tokens；
        // 有文档附件且未开搜索、未带网址时直接走 1M 通道，其他场景命中 32K 上限则自动降级重试。
        const omitExtended =
          dropExtendedFor1M ||
          (!initial.search &&
            prepared.question.files.some((file) => !file.isImage) &&
            !/https?:\/\//i.test(prepared.question.content))
        const tools = serverTools(initial.search ?? false, !omitExtended) ?? []
        const events = streamMessage(
          getActiveSecret(),
          {
            model: resolvedModel,
            system: SYSTEM_PROMPT,
            messages,
            thinking: { type: initial.thinking ? 'enabled' : 'disabled' },
            safety_check: omitExtended ? SAFETY_CHECK_LOW : SAFETY_CHECK_HIGH,
            ...(tools.length > 0 ? { tools } : {}),
            ...(!omitExtended && titleRequests.has(controller) ? { title: { enabled: true } } : {}),
          },
          controller.signal
        )
        const blockIndexes = new Map<number, number>()
        for await (const event of events) {
          receivedContent ||= event.type === 'content_block_start'
          if (
            event.type === 'message_delta' &&
            (event.delta.stop_reason === 'end_turn' || event.delta.stop_reason === 'max_tokens') &&
            event.delta.title?.trim() &&
            titleRequests.has(controller) &&
            !controller.signal.aborted &&
            !get().importingHistory
          ) {
            const title = event.delta.title.trim()
            updateSession(sessionId, (session) => (session.title ? session : { ...session, title }))
            titleRequests.delete(controller)
          }
          reply = applyEvent(reply, event, Date.now(), blockIndexes)
          if (document.visibilityState === 'hidden') {
            flush()
          } else if (isLowPerfDevice()) {
            if (flushTimer === null) {
              flushTimer = setTimeout(flush, LOW_PERF_STREAM_COALESCE_MS)
            }
          } else {
            frame ||= requestAnimationFrame(flush)
          }
        }
        reply = settleReply(reply, 'done', Date.now())
        break
      } catch (error) {
        if (controller.signal.aborted) {
          reply = settleReply(reply, 'stopped', Date.now())
          break
        }
        if (preparing) {
          const status = error instanceof ApiError ? error.status : undefined
          const rawMessage =
            error instanceof Error
              ? error.message.trim().slice(0, 300)
              : String(error).trim().slice(0, 300)
          reply = settleReply(reply, 'error', Date.now(), {
            kind: 'upload',
            message: rawMessage,
            ...(status === undefined ? {} : { status }),
            localMessage: describeUploadFailure(error),
            retryable: isRetryableApiError(error),
          })
          break
        }
        // 扩展参数（tools / title）触发服务端 32K 限流时，自动剥离并重试一次以使用 1M 上下文。
        if (!receivedContent && !dropExtendedFor1M && is32kInputLimitError(error)) {
          dropExtendedFor1M = true
          continue
        }
        // 若服务端返回更严格的图片数上限（如 Too many images: max N images），按上限裁剪历史旧图后自动重试。
        const reportedImageCap = !receivedContent ? parseTooManyImagesLimit(error) : null
        if (reportedImageCap !== null && reportedImageCap < imageCap) {
          imageCap = reportedImageCap
          continue
        }
        // 历史消息夹带不支持/已损坏/超尺寸的图片时，兼容 latest_reminder 索引偏移，跳过坏图并重试。
        const badImage = !receivedContent ? parseUnsupportedImageError(error) : null
        if (badImage) {
          const resolved = resolveBadHistoryImageIds(
            sentMessages,
            badImage.messageIndex,
            badImage.blockIndex
          )
          if (resolved.ids.length > 0 && skippedBadImages < MAX_SKIPPED_BAD_IMAGES) {
            let added = 0
            for (const fileId of resolved.ids) {
              if (markRejectedHistoryImage(fileId)) {
                added += 1
              }
            }
            if (added > 0) {
              skippedBadImages += added
              continue
            }
          }
          if (resolved.isCurrentTurn && error instanceof ApiError) {
            reply = settleReply(reply, 'error', Date.now(), {
              kind: error.kind,
              message: error.message,
              status: error.status,
              localMessage: { key: 'replyUnsupportedImage' },
            })
            break
          }
        }
        // 附件失效：重新补传后重发。收到过内容块（含丢弃的客户端工具）后不自动重发。
        if (
          attempt < FILE_RETRY_LIMIT &&
          !receivedContent &&
          reuploadInvalidatedFiles(sessionId, request, error)
        ) {
          cachedPrepared = null
          await waitForRetry(attempt, controller.signal)
          if (controller.signal.aborted) {
            reply = settleReply(reply, 'stopped', Date.now())
            break
          }
          continue
        }
        // 切后台期间在收到任何内容前被系统断链时：回到前台后自动无缝重连一次，避免直接弹「请重试」。
        if (
          !receivedContent &&
          !backgroundRetryUsed &&
          error instanceof ApiError &&
          (error.kind === 'network' || error.kind === 'interrupted') &&
          (sawBackground ||
            (typeof document !== 'undefined' && document.visibilityState === 'hidden'))
        ) {
          const elapsedSinceHide = backgroundedAt > 0 ? Date.now() - backgroundedAt : 0
          const remainingWait = Math.max(0, BACKGROUND_RESUME_RETRY_WINDOW_MS - elapsedSinceHide)
          if (remainingWait > 0) {
            backgroundRetryUsed = true
            const resumed = await waitForForegroundResume(controller.signal, remainingWait)
            if (controller.signal.aborted) {
              reply = settleReply(reply, 'stopped', Date.now())
              break
            }
            if (resumed) {
              const readyToRetry = await waitAbortableDelay(
                BACKGROUND_RESUME_SETTLE_DELAY_MS,
                controller.signal
              )
              if (!readyToRetry || controller.signal.aborted) {
                reply = settleReply(reply, 'stopped', Date.now())
                break
              }
              sawBackground =
                typeof document !== 'undefined' && document.visibilityState === 'hidden'
              backgroundedAt = sawBackground ? Date.now() : 0
              continue
            }
          }
        }
        if (error instanceof ApiError && error.kind === 'interrupted' && reply.stopReason) {
          // 已收到 message_delta 的结束原因，只是缺了结尾的 message_stop
          reply = settleReply(reply, 'done', Date.now())
        } else if (error instanceof ApiError) {
          reply = settleReply(reply, 'error', Date.now(), {
            kind: error.kind,
            message: error.message,
            status: error.status,
            localMessage: error.localMessage,
          })
        } else {
          reply = settleReply(reply, 'error', Date.now(), {
            kind: 'protocol',
            message: error instanceof Error ? error.message : String(error),
          })
        }
        break
      }
    }
  } finally {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', trackVisibility)
    }
    titleRequests.delete(controller)
    streamFlushes.delete(sessionId)
    cancelScheduledFlush()
    updateReply(sessionId, reply)
    set((state) => ({
      streaming: Object.fromEntries(
        Object.entries(state.streaming).filter(([id]) => id !== sessionId)
      ),
    }))
    syncStreamKeepAlive()
    persist(sessionId)
    refreshBalanceAfterReply()
  }
}

const compactionControllers = new Map<string, AbortController>()
const BATCH_COMPACT_CONCURRENCY = 3

/** 中止指定会话正在进行的批量记忆整理（已完成的块保留落盘） */
export const stopCompaction = (sessionId: string): void => {
  compactionControllers.get(sessionId)?.abort()
}

/**
 * 触发非破坏性记忆整理：
 * - auto / manual 均支持超长历史自动分块 3 路并发追赶（每块完成立即落盘并更新进度）；
 * - 传入 externalSignal 时与当前发送请求的停止按钮联动，停止回复会同步中止整理。
 */
export const compactSession = async (
  sessionId: string,
  source: CompactionSource = 'manual',
  externalSignal?: AbortSignal,
  historyOverride?: Message[]
): Promise<boolean> => {
  if (compactionControllers.has(sessionId) || get().importingHistory) {
    return false
  }
  const session = get().sessionCache[sessionId]
  if (!session) {
    return false
  }
  const visible = historyOverride ?? getVisibleMessages(session)
  if (
    source === 'auto' &&
    (session.autoCompact !== true ||
      selectCompactionTarget(visible, session.compactions, 'auto') === null)
  ) {
    return false
  }
  const targets = selectBatchCompactionTargets(visible, session.compactions)
  if (targets.length === 0) {
    return false
  }

  const controller = new AbortController()
  const onExternalAbort = () => controller.abort()
  if (externalSignal) {
    if (externalSignal.aborted) {
      return false
    }
    externalSignal.addEventListener('abort', onExternalAbort, { once: true })
  }
  compactionControllers.set(sessionId, controller)
  let completed = 0
  let succeeded = 0
  const total = targets.length
  const updateProgress = () => {
    set((state) => ({
      compacting: { ...state.compacting, [sessionId]: { done: completed, total } },
    }))
  }
  updateProgress()
  syncStreamKeepAlive()

  try {
    let nextIndex = 0
    const workerCount = Math.min(BATCH_COMPACT_CONCURRENCY, total)
    const runWorker = async () => {
      while (nextIndex < total && !controller.signal.aborted) {
        const currentIdx = nextIndex++
        const target = targets[currentIdx]
        try {
          const span = await generateCompactionSpan(target, source, controller.signal)
          if (controller.signal.aborted || !get().sessionCache[sessionId] || get().importingHistory) {
            return
          }
          updateSession(sessionId, (current) => upsertCompactionSpan(current, span))
          persist(sessionId)
          succeeded += 1
        } catch (error) {
          if (!controller.signal.aborted) {
            recordAppLog(
              'error',
              'chat.compaction',
              `compaction (${source}) chunk ${currentIdx + 1}/${total} failed for session ${sessionId}`,
              error instanceof Error ? error.message : String(error)
            )
          }
        } finally {
          completed += 1
          if (!controller.signal.aborted) {
            updateProgress()
          }
        }
      }
    }

    await Promise.all(Array.from({ length: workerCount }, () => runWorker()))
    return succeeded > 0
  } finally {
    externalSignal?.removeEventListener('abort', onExternalAbort)
    compactionControllers.delete(sessionId)
    set((state) => ({
      compacting: Object.fromEntries(
        Object.entries(state.compacting).filter(([id]) => id !== sessionId)
      ),
    }))
    syncStreamKeepAlive()
  }
}

/** 用户手动编辑某条剧情记忆摘要内容，自动标记 editedByUser 防止后续覆盖 */
export const updateCompactionSummary = (
  sessionId: string,
  spanId: string,
  summary: string,
  title?: string
): void => {
  const cleaned = summary.trim()
  if (!cleaned) {
    return
  }
  updateSession(sessionId, (session) => {
    const list = session.compactions
    if (!list) {
      return session
    }
    return {
      ...session,
      compactions: list.map((span) =>
        span.id === spanId
          ? {
              ...span,
              title: title?.trim() || span.title,
              summary: cleaned,
              summaryTokensEstimate: estimateTextTokens(cleaned),
              editedByUser: true,
              updatedAt: Date.now(),
            }
          : span
      ),
    }
  })
  persist(sessionId)
}

/** 撤销某条剧情记忆折叠（完全无损，原对话恢复进入请求上下文） */
export const deleteCompactionSpan = (sessionId: string, spanId: string): void => {
  updateSession(sessionId, (session) => removeCompactionSpan(session, spanId))
  persist(sessionId)
}

/** 设置当前会话是否开启发送前自动上下文压缩（默认关闭） */
export const setSessionAutoCompact = (sessionId: string, enabled: boolean): void => {
  updateSession(sessionId, (session) =>
    Boolean(session.autoCompact) === enabled ? session : { ...session, autoCompact: enabled }
  )
  persist(sessionId)
}
