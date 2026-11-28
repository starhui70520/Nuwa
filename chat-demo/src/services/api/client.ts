import { translate, type TranslationMessage } from '../../i18n/index.js'
import { recordAppLog } from '../errorLog.js'
import {
  isUsingDeepSeekAccount,
  isUsingRankAIFree,
  RANKAI_API_KEY,
  RANKAI_BASE_URL,
  RANKAI_MODEL,
  useSettings,
} from '../settings.js'
import { buildOpenAIChatBody, parseOpenAIStream, resolveOpenAIEndpoint } from './openai.js'
import { readMessageEvent } from './parseEvent.js'
import { readServerSentEvents } from './sse.js'
import type {
  ApiErrorBody,
  CreateMessageRequest,
  FileObject,
  FilePurpose,
  MessageStreamEvent,
} from './types.js'

/** 构建期 API 地址，默认 https://api.deepseek.com；本地开发支持开发服务器代理 */
export const API_ORIGIN = __API_ORIGIN__
/** Anthropic 兼容接口的前缀 */
const ANTHROPIC_BASE_URL = `${API_ORIGIN}/anthropic/v1`
/** 引用 Files API 上传的图片、调用 Anthropic 兼容 Files API 时必须携带 */
const FILES_BETA = 'files-api-2025-04-14'

export type ApiErrorKind =
  /** 非 2xx 响应 */
  | 'http'
  /** 流中返回的错误帧（如等待生成超时），随后连接关闭 */
  | 'stream'
  /** 请求没有到达服务端（断网、跨域被拦截等） */
  | 'network'
  /** 流在 message_stop 之前结束 */
  | 'interrupted'
  /** 响应不符合协议（如非 SSE 响应） */
  | 'protocol'

export class ApiError extends Error {
  readonly localMessage?: TranslationMessage

  constructor(
    readonly kind: ApiErrorKind,
    message: string | TranslationMessage,
    readonly status?: number
  ) {
    super(typeof message === 'string' ? message : translate(message.key, message.params))
    this.name = 'ApiError'
    this.localMessage = typeof message === 'string' ? undefined : message
  }
}

const isErrorBody = (value: unknown): value is ApiErrorBody =>
  typeof value === 'object' &&
  value !== null &&
  'error' in value &&
  typeof (value as ApiErrorBody).error?.message === 'string'

const readErrorResponse = async (
  response: Response,
  kind: 'http' | 'protocol' = 'http',
  fallback = response.statusText
): Promise<ApiError> => {
  const text = await response.text().catch(() => '')
  let message = text || fallback
  try {
    const body: unknown = JSON.parse(text)
    if (isErrorBody(body)) {
      message = body.error.message
    }
  } catch {
    // 非 JSON 响应体直接展示原文
  }
  return new ApiError(kind, message, response.status)
}

export const request = async (url: string, init: RequestInit): Promise<Response> => {
  let response: Response
  try {
    response = await fetch(url, init)
  } catch (error) {
    if (init.signal?.aborted) {
      throw error
    }
    const msg = error instanceof Error ? error.message : String(error)
    recordAppLog('error', 'api.network', `${init.method || 'GET'} ${url.split('?')[0]}`, msg)
    throw new ApiError('network', msg)
  }
  if (!response.ok) {
    const apiErr = await readErrorResponse(response)
    recordAppLog(
      'error',
      'api.http',
      `${init.method || 'GET'} ${url.split('?')[0]} -> HTTP ${response.status}`,
      apiErr.message
    )
    throw apiErr
  }
  return response
}

const anthropicHeaders = (
  secret: string,
  beta: boolean,
  useAccountToken = false
): Record<string, string> => ({
  ...(useAccountToken ? { 'x-dsh-auth-token': secret } : { 'x-api-key': secret }),
  // Files API 和通过 file_id 引用图片时必传；纯文本聊天无需携带。
  ...(beta ? { 'anthropic-beta': FILES_BETA } : {}),
})

const getBaseOrigin = () => {
  const raw = useSettings.getState().apiBaseUrl.trim().replace(/\/+$/, '')
  if (!raw) {
    return API_ORIGIN
  }
  return raw.replace(/\/(v1|anthropic(?:\/v1)?)$/i, '')
}

/** 用 GET /models 校验 API Key（不产生费用）；第三方中转若未开放 /models（404/405）则放行 */
export const verifyApiKey = async (apiKey: string, signal?: AbortSignal): Promise<void> => {
  const cleanKey = apiKey.trim()
  if (!/^[\x21-\x7e]+$/.test(cleanKey)) {
    throw new ApiError('protocol', { key: 'apiKeyInvalidFormat' })
  }
  const { apiProtocol, apiBaseUrl } = useSettings.getState()
  const url =
    apiProtocol === 'openai'
      ? resolveOpenAIEndpoint(apiBaseUrl || API_ORIGIN, 'models')
      : `${getBaseOrigin()}/models`
  try {
    await request(url, {
      method: 'GET',
      headers: { Authorization: `Bearer ${cleanKey}` },
      signal,
    })
  } catch (error) {
    if (
      apiProtocol === 'openai' &&
      error instanceof ApiError &&
      (error.status === 404 || error.status === 405)
    ) {
      return
    }
    throw error
  }
}

/**
 * POST /anthropic/v1/files 上传附件（不设过期时间，会话里的历史附件一直可用）。
 * purpose 为 null 时不传该字段（图片）；purpose 必须排在 file 之前。
 */
export const uploadFile = async (
  apiKey: string,
  file: File,
  purpose: FilePurpose | null,
  signal?: AbortSignal
): Promise<FileObject> => {
  const form = new FormData()
  if (purpose) {
    form.append('purpose', purpose)
  }
  form.append('file', file)
  const useAccount = isUsingDeepSeekAccount()
  const base = useAccount ? ANTHROPIC_BASE_URL : `${getBaseOrigin()}/anthropic/v1`
  const response = await request(`${base}/files`, {
    method: 'POST',
    headers: anthropicHeaders(apiKey, true, useAccount),
    body: form,
    signal,
  })
  return (await response.json()) as FileObject
}

/** DELETE /anthropic/v1/files/{file_id} */
export const deleteFile = async (apiKey: string, fileId: string): Promise<void> => {
  const useAccount = isUsingDeepSeekAccount()
  const base = useAccount ? ANTHROPIC_BASE_URL : `${getBaseOrigin()}/anthropic/v1`
  await request(`${base}/files/${encodeURIComponent(fileId)}`, {
    method: 'DELETE',
    headers: anthropicHeaders(apiKey, true, useAccount),
  })
}

const hasFile = (body: CreateMessageRequest) =>
  body.messages.some(
    (message) =>
      typeof message.content !== 'string' &&
      message.content.some((block) => block.type === 'image' || block.type === 'document')
  )

async function* streamOpenAICompatible(
  endpoint: string,
  apiKey: string,
  body: CreateMessageRequest,
  signal: AbortSignal,
  includeThinking = false
): AsyncGenerator<MessageStreamEvent> {
  const response = await request(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
    },
    body: JSON.stringify(buildOpenAIChatBody(body, { includeThinking })),
    signal,
  })
  const contentType = response.headers.get('Content-Type') ?? ''
  if (!response.body || !contentType.includes('text/event-stream')) {
    const protocolErr = await readErrorResponse(response, 'protocol', '')
    recordAppLog(
      'error',
      'api.stream',
      `POST ${endpoint.split('?')[0]} non-SSE (${contentType || 'unknown'})`,
      protocolErr.message
    )
    throw protocolErr
  }
  try {
    yield* parseOpenAIStream(response.body, signal, (message) => {
      recordAppLog('error', 'api.stream', `OpenAI stream error`, message)
      return new ApiError('stream', message)
    })
  } catch (error) {
    if (signal.aborted || error instanceof ApiError) {
      throw error
    }
    const msg = error instanceof Error ? error.message : String(error)
    recordAppLog('error', 'api.stream', `POST ${endpoint.split('?')[0]} stream read failed`, msg)
    throw new ApiError('interrupted', '')
  }
}

/**
 * 所有上下文压缩请求统一走内置 RankAI 免费接口（关闭深度思考），不消耗用户自有额度。
 */
export async function* streamRankAICompaction(
  body: CreateMessageRequest,
  signal: AbortSignal
): AsyncGenerator<MessageStreamEvent> {
  const endpoint = resolveOpenAIEndpoint(RANKAI_BASE_URL, 'chat/completions')
  yield* streamOpenAICompatible(
    endpoint,
    RANKAI_API_KEY,
    {
      ...body,
      model: RANKAI_MODEL,
      thinking: { type: 'disabled' },
    },
    signal,
    true
  )
}

/**
 * 发送流式对话请求，支持 RankAI 免费额度、OpenAI 兼容协议与 Anthropic 兼容协议。
 */
export async function* streamMessage(
  apiKey: string,
  body: CreateMessageRequest,
  signal: AbortSignal
): AsyncGenerator<MessageStreamEvent> {
  const useRankAIFree = isUsingRankAIFree()
  if (useRankAIFree) {
    const endpoint = resolveOpenAIEndpoint(RANKAI_BASE_URL, 'chat/completions')
    yield* streamOpenAICompatible(
      endpoint,
      RANKAI_API_KEY,
      { ...body, model: RANKAI_MODEL },
      signal,
      true
    )
    return
  }

  const useAccount = isUsingDeepSeekAccount()
  const { apiProtocol, apiBaseUrl } = useSettings.getState()
  if (!useAccount && apiProtocol === 'openai') {
    const endpoint = resolveOpenAIEndpoint(apiBaseUrl || API_ORIGIN, 'chat/completions')
    const isRankAIHost = endpoint.toLowerCase().includes('api.rankai.rankchord.com')
    yield* streamOpenAICompatible(endpoint, apiKey, body, signal, isRankAIHost)
    return
  }

  const anthropicUrl = useAccount
    ? `${ANTHROPIC_BASE_URL}/messages`
    : `${getBaseOrigin()}/anthropic/v1/messages`
  const response = await request(anthropicUrl, {
    method: 'POST',
    headers: {
      ...anthropicHeaders(apiKey, hasFile(body), useAccount),
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
    },
    body: JSON.stringify({ ...body, stream: true }),
    signal,
  })
  const contentType = response.headers.get('Content-Type') ?? ''
  if (!response.body || !contentType.includes('text/event-stream')) {
    const protocolErr = await readErrorResponse(response, 'protocol', '')
    recordAppLog(
      'error',
      'api.stream',
      `POST ${anthropicUrl.split('?')[0]} non-SSE (${contentType || 'unknown'})`,
      protocolErr.message
    )
    throw protocolErr
  }
  try {
    for await (const { event: eventName, data } of readServerSentEvents(response.body, signal)) {
      let payload: unknown
      try {
        payload = JSON.parse(data)
      } catch {
        if (eventName !== 'error') {
          continue
        }
      }
      if (isErrorBody(payload)) {
        recordAppLog('error', 'api.stream', 'Anthropic stream error', payload.error.message)
        throw new ApiError('stream', payload.error.message)
      }
      if (eventName === 'error') {
        recordAppLog('error', 'api.stream', 'Anthropic stream error event', data)
        throw new ApiError('stream', data)
      }
      const event = readMessageEvent(payload)
      if (!event) {
        continue
      }
      yield event
      if (event.type === 'message_stop') {
        return
      }
    }
  } catch (error) {
    if (signal.aborted || error instanceof ApiError) {
      throw error
    }
    const msg = error instanceof Error ? error.message : String(error)
    recordAppLog(
      'error',
      'api.stream',
      `POST ${anthropicUrl.split('?')[0]} stream read failed`,
      msg
    )
    throw new ApiError('interrupted', '')
  }
  recordAppLog(
    'error',
    'api.stream',
    `POST ${anthropicUrl.split('?')[0]} interrupted before message_stop`
  )
  // 服务端没有提供错误内容时保持为空，由展示层映射为统一中断提示。
  throw new ApiError('interrupted', '')
}
