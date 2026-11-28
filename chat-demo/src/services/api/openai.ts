import { readServerSentEvents } from './sse.js'
import type {
  CreateMessageRequest,
  MessageParam,
  MessageStreamEvent,
  MessageUsage,
  StopReason,
} from './types.js'

type OpenAIContentPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string } }

type OpenAIMessage = {
  role: 'system' | 'user' | 'assistant'
  content: string | OpenAIContentPart[]
}

type OpenAIChunk = {
  id?: string
  model?: string
  error?: { message?: string }
  choices?: Array<{
    delta?: {
      content?: string | null
      reasoning_content?: string | null
      reasoning?: string | null
    }
    finish_reason?: string | null
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    prompt_cache_hit_tokens?: number
    prompt_tokens_details?: {
      cached_tokens?: number
    }
  }
}

/** 规范化第三方 OpenAI 兼容接口地址，自动补全 /v1/chat/completions 或 /models */
export const resolveOpenAIEndpoint = (
  rawBaseUrl: string,
  endpoint: 'chat/completions' | 'models'
): string => {
  const trimmed = rawBaseUrl.trim().replace(/\/+$/, '')
  if (!trimmed) {
    return `/v1/${endpoint}`
  }
  if (trimmed.endsWith('/chat/completions')) {
    return endpoint === 'chat/completions'
      ? trimmed
      : `${trimmed.slice(0, -'/chat/completions'.length)}/models`
  }
  try {
    const parsed = new URL(trimmed)
    const pathname = parsed.pathname.replace(/\/+$/, '')
    if (!pathname) {
      return `${trimmed}/v1/${endpoint}`
    }
    return `${trimmed}/${endpoint}`
  } catch {
    return `${trimmed}/${endpoint}`
  }
}

const extractText = (content: MessageParam['content']): string => {
  if (typeof content === 'string') {
    return content
  }
  return content
    .filter((block): block is { type: 'text'; text: string } => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
}

const buildOpenAIUserContent = (
  content: Extract<MessageParam, { role: 'user' }>['content']
): string | OpenAIContentPart[] | null => {
  if (typeof content === 'string') {
    return content || null
  }
  const imageParts: OpenAIContentPart[] = []
  const textParts: string[] = []
  for (const block of content) {
    if (block.type === 'image_url' && block.image_url.url) {
      imageParts.push({ type: 'image_url', image_url: { url: block.image_url.url } })
    } else if (block.type === 'text' && block.text) {
      textParts.push(block.text)
    }
  }
  const text = textParts.join('\n')
  if (imageParts.length === 0) {
    return text || null
  }
  return text ? [...imageParts, { type: 'text', text }] : imageParts
}

export const buildOpenAIChatBody = (
  body: CreateMessageRequest,
  options?: { includeThinking?: boolean }
) => {
  const messages: OpenAIMessage[] = []
  if (body.system.trim()) {
    messages.push({ role: 'system', content: body.system })
  }
  for (const message of body.messages) {
    if (message.role === 'latest_reminder') {
      continue
    }
    if (message.role === 'user') {
      const content = buildOpenAIUserContent(message.content)
      if (content) {
        messages.push({ role: 'user', content })
      }
      continue
    }
    const content = extractText(message.content)
    if (content) {
      messages.push({ role: message.role, content })
    }
  }
  return {
    model: body.model,
    messages,
    stream: true,
    ...(options?.includeThinking && body.thinking ? { thinking: body.thinking } : {}),
  }
}

const toStopReason = (finishReason: string | null | undefined): StopReason => {
  if (finishReason === 'length') {
    return 'max_tokens'
  }
  if (finishReason === 'content_filter') {
    return 'refusal'
  }
  return 'end_turn'
}

/** 将 OpenAI 兼容 SSE 流转换为应用内部统一的 MessageStreamEvent */
export async function* parseOpenAIStream(
  body: ReadableStream<Uint8Array>,
  signal: AbortSignal,
  createStreamError: (message: string) => Error
): AsyncGenerator<MessageStreamEvent> {
  let started = false
  let blockIndex = 0
  let thinkingIndex: number | null = null
  let textIndex: number | null = null
  let finishReason: string | null | undefined
  let usage: MessageUsage | undefined

  const closeThinking = function* (): Generator<MessageStreamEvent> {
    if (thinkingIndex !== null) {
      yield { type: 'content_block_stop', index: thinkingIndex }
      thinkingIndex = null
    }
  }

  const closeText = function* (): Generator<MessageStreamEvent> {
    if (textIndex !== null) {
      yield { type: 'content_block_stop', index: textIndex }
      textIndex = null
    }
  }

  for await (const { event: eventName, data } of readServerSentEvents(body, signal)) {
    if (data === '[DONE]') {
      break
    }
    let chunk: OpenAIChunk
    try {
      chunk = JSON.parse(data) as OpenAIChunk
    } catch {
      if (eventName === 'error') {
        throw createStreamError(data)
      }
      continue
    }
    if (chunk.error?.message) {
      throw createStreamError(chunk.error.message)
    }
    if (!started) {
      started = true
      yield {
        type: 'message_start',
        message: {
          id: chunk.id ?? `openai-${Date.now()}`,
          model: chunk.model ?? '',
        },
      }
    }
    if (chunk.usage) {
      const totalPrompt = chunk.usage.prompt_tokens ?? 0
      const cached = Math.min(
        totalPrompt,
        Math.max(
          0,
          chunk.usage.prompt_tokens_details?.cached_tokens ??
            chunk.usage.prompt_cache_hit_tokens ??
            0
        )
      )
      usage = {
        input_tokens: Math.max(0, totalPrompt - cached),
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: cached,
        output_tokens: chunk.usage.completion_tokens ?? 0,
      }
    }
    const choice = chunk.choices?.[0]
    if (!choice) {
      continue
    }
    if (choice.finish_reason) {
      finishReason = choice.finish_reason
    }
    const reasoning = choice.delta?.reasoning_content ?? choice.delta?.reasoning
    if (reasoning) {
      yield* closeText()
      if (thinkingIndex === null) {
        thinkingIndex = blockIndex++
        yield {
          type: 'content_block_start',
          index: thinkingIndex,
          content_block: { type: 'thinking', thinking: '', signature: '' },
        }
      }
      yield {
        type: 'content_block_delta',
        index: thinkingIndex,
        delta: { type: 'thinking_delta', thinking: reasoning },
      }
    }
    const content = choice.delta?.content
    if (content) {
      yield* closeThinking()
      if (textIndex === null) {
        textIndex = blockIndex++
        yield {
          type: 'content_block_start',
          index: textIndex,
          content_block: { type: 'text', text: '', citations: [] },
        }
      }
      yield {
        type: 'content_block_delta',
        index: textIndex,
        delta: { type: 'text_delta', text: content },
      }
    }
  }

  yield* closeThinking()
  yield* closeText()
  yield {
    type: 'message_delta',
    delta: {
      stop_reason: toStopReason(finishReason),
      stop_sequence: null,
    },
    ...(usage ? { usage } : {}),
  }
  yield { type: 'message_stop' }
}
