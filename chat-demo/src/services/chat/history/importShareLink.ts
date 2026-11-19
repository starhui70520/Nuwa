import { createId } from '../../../utils/id.js'
import { DeepSeekMigration, isNativeAndroid, isNativeIos } from '../../nativeBridge.js'
import { importSingleSession } from '../store.js'
import type {
  AssistantMessage,
  Message,
  ReplyBlock,
  Session,
  UserMessage,
} from '../types.js'

type ShareFragment = {
  type?: string
  content?: string
  elapsed_secs?: number | null
}

type ShareMessage = {
  message_id?: number
  id?: number
  parent_id?: number | null
  role?: string
  status?: string
  thinking_enabled?: boolean
  search_enabled?: boolean
  inserted_at?: number | string
  fragments?: ShareFragment[]
}

type ShareApiResponse = {
  code?: number
  msg?: string
  data?: {
    biz_code?: number
    biz_msg?: string
    biz_data?: {
      title?: string | null
      messages?: ShareMessage[]
    } | null
  } | null
}

const SHARE_URL_PATTERN =
  /(?:https?:\/\/)?chat\.deepseek\.com\/share\/([A-Za-z0-9_-]{4,64})/i
const BARE_SHARE_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/

/** 从用户输入（完整分享文案、URL 或纯 ID）中提取 DeepSeek 分享 ID */
export const extractDeepSeekShareId = (input: string): string | null => {
  const trimmed = input.trim()
  if (!trimmed) {
    return null
  }
  const urlMatch = SHARE_URL_PATTERN.exec(trimmed)
  if (urlMatch?.[1]) {
    return urlMatch[1]
  }
  if (BARE_SHARE_ID_PATTERN.test(trimmed)) {
    return trimmed
  }
  return null
}

const parseTimestampMs = (raw: number | string | undefined, fallback: number): number => {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return raw > 1e12 ? Math.round(raw) : Math.round(raw * 1000)
  }
  if (typeof raw === 'string' && raw.trim()) {
    const parsed = Date.parse(raw)
    if (Number.isFinite(parsed)) {
      return parsed
    }
  }
  return fallback
}

const fetchShareJson = async (shareId: string): Promise<ShareApiResponse> => {
  let status = 0
  let body = ''
  if (isNativeAndroid() || isNativeIos()) {
    const res = await DeepSeekMigration.fetchShareContent({ shareId })
    status = res.status
    body = res.body
  } else {
    const res = await fetch(
      `https://chat.deepseek.com/api/v0/share/content?share_id=${encodeURIComponent(shareId)}`,
      { headers: { Accept: 'application/json' } }
    )
    status = res.status
    body = await res.text()
  }
  if (status < 200 || status >= 300) {
    throw new Error(`HTTP ${status || 'network'}`)
  }
  return JSON.parse(body) as ShareApiResponse
}

const buildSessionFromShare = (
  rawTitle: string | null | undefined,
  rawMessages: ShareMessage[]
): Session => {
  const now = Date.now()
  const idMap = new Map<number, string>()
  const messages: Message[] = []
  let firstUserText = ''

  for (const item of rawMessages) {
    const numId = typeof item.message_id === 'number' ? item.message_id : item.id
    if (typeof numId !== 'number') {
      continue
    }
    const localId = createId()
    idMap.set(numId, localId)
    const parentId =
      typeof item.parent_id === 'number' ? (idMap.get(item.parent_id) ?? null) : null
    const createdAt = parseTimestampMs(item.inserted_at, now)
    const fragments = Array.isArray(item.fragments) ? item.fragments : []
    const role = (item.role || '').toUpperCase()

    if (role === 'USER') {
      const content = fragments
        .filter((f) => f.type === 'REQUEST' && typeof f.content === 'string')
        .map((f) => f.content ?? '')
        .join('\n')
        .trim()
      if (!firstUserText && content) {
        firstUserText = content
      }
      const userMsg: UserMessage = {
        id: localId,
        parentId,
        role: 'user',
        content,
        files: [],
        createdAt,
      }
      messages.push(userMsg)
    } else if (role === 'ASSISTANT') {
      const blocks: ReplyBlock[] = []
      for (const f of fragments) {
        if (!f.content) {
          continue
        }
        if (f.type === 'THINK') {
          blocks.push({
            type: 'thinking',
            thinking: f.content,
            ...(typeof f.elapsed_secs === 'number' ? { elapsedSeconds: f.elapsed_secs } : {}),
          })
        } else if (f.type === 'RESPONSE') {
          blocks.push({ type: 'text', text: f.content })
        } else if (f.type === 'TEMPLATE_RESPONSE') {
          blocks.push({ type: 'text', text: f.content, isTemplate: true })
        }
      }
      const assistantMsg: AssistantMessage = {
        id: localId,
        parentId,
        role: 'assistant',
        createdAt,
        model: null,
        thinking: Boolean(item.thinking_enabled),
        search: Boolean(item.search_enabled),
        prefix: false,
        status: item.status === 'FAILED' ? 'error' : 'done',
        blocks,
      }
      messages.push(assistantMsg)
    }
  }

  // 回填 selectedChildId 保证线性/分支链完整连通
  const byId = new Map(messages.map((m) => [m.id, m]))
  for (const m of messages) {
    if (m.parentId) {
      const parent = byId.get(m.parentId)
      if (parent) {
        parent.selectedChildId = m.id
      }
    }
  }

  const trimmedTitle = (rawTitle || '').trim()
  const isGenericTitle =
    !trimmedTitle ||
    trimmedTitle === 'Shared Conversation' ||
    trimmedTitle === '来自分享的对话'
  const title = isGenericTitle
    ? (firstUserText.replace(/\s+/g, ' ').slice(0, 28) || '分享导入的对话')
    : trimmedTitle

  const firstTs = messages[0]?.createdAt ?? now
  const lastTs = messages.at(-1)?.createdAt ?? now

  return {
    id: createId(),
    title,
    createdAt: firstTs,
    updatedAt: Math.max(now, lastTs),
    messages,
    rootMessageId: messages[0]?.id ?? null,
  }
}

/** 通过 DeepSeek 分享链接拉取对话并导入为本地新会话，返回导入后的会话对象 */
export const importFromShareLink = async (input: string): Promise<Session> => {
  const shareId = extractDeepSeekShareId(input)
  if (!shareId) {
    throw new Error('未识别到有效的 DeepSeek 分享链接（格式如 https://chat.deepseek.com/share/...）')
  }
  const payload = await fetchShareJson(shareId)
  if (payload.code !== 0 || payload.data?.biz_code !== 0) {
    throw new Error(payload.data?.biz_msg || payload.msg || '分享链接已失效或无法访问')
  }
  const biz = payload.data?.biz_data
  if (!biz || !Array.isArray(biz.messages) || biz.messages.length === 0) {
    throw new Error('该分享链接中没有可导入的对话内容')
  }
  const session = buildSessionFromShare(biz.title, biz.messages)
  if (session.messages.length === 0) {
    throw new Error('该分享链接中没有可导入的对话内容')
  }
  await importSingleSession(session)
  return session
}
