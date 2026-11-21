import { Capacitor } from '@capacitor/core'
import { createId } from '../../../utils/id.js'
import { DeepSeekMigration, isNativeAndroid, isNativeIos } from '../../nativeBridge.js'
import { importHistory } from '../backup.js'
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
  /(?:https?:\/\/)?(?:[a-z0-9-]+\.)*deepseek\.com\/(?:a\/chat\/s|share)\/([A-Za-z0-9_-]{4,64})/i
const BARE_SHARE_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/
const HTTP_URL_PATTERN = /https?:\/\/[^\s<>"'`）)】》]+/i

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

/** 从用户输入中提取任意 http(s) 链接（支持华为云 OBS 导出 ZIP 链接、短链/重定向链接等） */
export const extractHttpUrl = (input: string): string | null => {
  const match = HTTP_URL_PATTERN.exec(input.trim())
  if (!match?.[0]) {
    return null
  }
  return match[0].replace(/[.,;:!?。，；：！？]+$/, '')
}

const isZipHeader = (bytes: Uint8Array): boolean =>
  bytes.length >= 4 &&
  bytes[0] === 0x50 &&
  bytes[1] === 0x4b &&
  (bytes[2] === 0x03 || bytes[2] === 0x05)

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

const importByShareId = async (shareId: string): Promise<Session> => {
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

/** 通过 DeepSeek 分享链接拉取对话并导入为本地新会话，返回导入后的会话对象 */
export const importFromShareLink = async (input: string): Promise<Session> => {
  const shareId = extractDeepSeekShareId(input)
  if (!shareId) {
    throw new Error('未识别到有效的 DeepSeek 分享链接（格式如 https://chat.deepseek.com/share/...）')
  }
  return importByShareId(shareId)
}

export type ImportFromLinkResult =
  | { kind: 'share'; session: Session }
  | { kind: 'archive'; count: number }

/**
 * 统一链接导入入口：
 * 1. DeepSeek 分享链接（含各类子域名与分享文案）→ 直接拉取单条对话导入；
 * 2. DeepSeek 官方数据导出 ZIP 下载链接（如华为云 OBS 签名链接）或任意重定向短链 →
 *    自动追踪重定向并下载，若是分享页则按分享导入，若是 ZIP 压缩包则直接增量导入全部对话。
 */
export const importFromLink = async (
  input: string,
  onStage?: (stage: string) => void
): Promise<ImportFromLinkResult> => {
  const directShareId = extractDeepSeekShareId(input)
  if (directShareId) {
    onStage?.('正在拉取分享对话…')
    const session = await importByShareId(directShareId)
    return { kind: 'share', session }
  }

  const remoteUrl = extractHttpUrl(input)
  if (!remoteUrl) {
    throw new Error('未识别到有效链接（支持 DeepSeek 分享链接或官方数据导出 ZIP 下载链接）')
  }

  onStage?.('正在下载链接内容…')
  let blob: Blob
  let fileName = 'deepseek_export.zip'

  if (isNativeAndroid() || isNativeIos()) {
    const res = await DeepSeekMigration.downloadRemoteFile({ url: remoteUrl })
    const redirectedShareId = extractDeepSeekShareId(res.finalUrl)
    if (redirectedShareId) {
      onStage?.('正在拉取分享对话…')
      const session = await importByShareId(redirectedShareId)
      return { kind: 'share', session }
    }
    if (res.status === 403 || res.status === 404 || res.status === 410) {
      throw new Error('导出链接已失效或无权访问（DeepSeek 导出链接有时效限制，请重新导出后再试）')
    }
    if (res.status < 200 || res.status >= 300) {
      throw new Error(`链接下载失败（HTTP ${res.status || '网络错误'}）`)
    }
    fileName = res.fileName || fileName
    const localRes = await fetch(Capacitor.convertFileSrc(res.filePath))
    if (!localRes.ok) {
      throw new Error(`读取下载文件失败（HTTP ${localRes.status}）`)
    }
    blob = await localRes.blob()
  } else {
    let res: Response
    try {
      res = await fetch(remoteUrl)
    } catch {
      throw new Error(
        '浏览器受跨域限制无法直接拉取该链接，请先在浏览器打开链接下载 ZIP 文件后，点下方「导入对话记录」导入'
      )
    }
    const redirectedShareId = extractDeepSeekShareId(res.url)
    if (redirectedShareId) {
      onStage?.('正在拉取分享对话…')
      const session = await importByShareId(redirectedShareId)
      return { kind: 'share', session }
    }
    if (res.status === 403 || res.status === 404 || res.status === 410) {
      throw new Error('导出链接已失效或无权访问（DeepSeek 导出链接有时效限制，请重新导出后再试）')
    }
    if (!res.ok) {
      throw new Error(`链接下载失败（HTTP ${res.status}）`)
    }
    blob = await res.blob()
  }

  const head = new Uint8Array(await blob.slice(0, 4).arrayBuffer())
  if (isZipHeader(head)) {
    onStage?.('正在导入对话记录…')
    const count = await importHistory(new File([blob], fileName, { type: 'application/zip' }))
    return { kind: 'archive', count }
  }

  if (blob.size > 0 && blob.size <= 512 * 1024) {
    const embeddedShareId = extractDeepSeekShareId(await blob.text())
    if (embeddedShareId) {
      onStage?.('正在拉取分享对话…')
      const session = await importByShareId(embeddedShareId)
      return { kind: 'share', session }
    }
  }

  throw new Error('该链接返回的内容不是有效的 DeepSeek 导出压缩包（ZIP）或分享对话')
}
