import { isUsingDeepSeekAccount, useSettings } from '../settings.js'
import { ApiError, API_ORIGIN, request } from './client.js'

/**
 * 语音接口：
 * - ASR：POST /v1/tools/asr，multipart 上传 WAV / Ogg Opus，一次返回全文（第三方中转兼容 /v1/audio/transcriptions）
 * - TTS：POST /v1/tools/tts，返回音频字节流（产出首帧后即返回 200）
 */
const normalizeOrigin = (rawBaseUrl: string): string => {
  const trimmed = rawBaseUrl.trim().replace(/\/+$/, '')
  if (!trimmed) {
    return API_ORIGIN
  }
  return trimmed.replace(/\/(v1|anthropic\/v1)$/i, '')
}

/** DeepSeek 工具接口（ASR/TTS）当前需要 sk-... API Key 才能鉴权，dshToken 会返回 401 */
export const canUseCloudAsr = (): boolean => Boolean(useSettings.getState().apiKey)

const speechAuthHeaders = (secret: string, useBearer: boolean): Record<string, string> =>
  useBearer ? { Authorization: `Bearer ${secret}` } : { 'x-dsh-auth-token': secret }

const parseTranscriptResponse = async (response: Response): Promise<string> => {
  const raw = await response.text()
  let body: unknown
  try {
    body = JSON.parse(raw)
  } catch {
    throw new ApiError('protocol', raw)
  }
  if (
    typeof body !== 'object' ||
    body === null ||
    !('text' in body) ||
    typeof body.text !== 'string'
  ) {
    throw new ApiError('protocol', raw)
  }
  return body.text
}

export type TtsVoice = 'stella' | 'tide'

/** TTS 输出的裸 PCM 参数：24kHz、单声道、16-bit 小端 */
export const TTS_SAMPLE_RATE = 24000

/** 语音识别：audio 为 WAV（单声道 16-bit PCM）或 Ogg Opus，时长不超过 120 秒、大小不超过 8 MiB */
export const transcribe = async (
  apiKey: string,
  audio: Blob,
  signal?: AbortSignal
): Promise<string> => {
  const state = useSettings.getState()
  const useAccount = isUsingDeepSeekAccount(state)
  const effectiveKey = state.apiKey ?? apiKey
  const useBearer = Boolean(state.apiKey) || !useAccount
  const origin = useAccount ? API_ORIGIN : normalizeOrigin(state.apiBaseUrl)
  const headers = speechAuthHeaders(effectiveKey, useBearer)

  const form = new FormData()
  form.append('file', audio, 'recording.wav')
  try {
    const response = await request(`${origin}/v1/tools/asr`, {
      method: 'POST',
      headers,
      body: form,
      signal,
    })
    return await parseTranscriptResponse(response)
  } catch (error) {
    if (!useAccount && error instanceof ApiError && (error.status === 404 || error.status === 405)) {
      const whisperForm = new FormData()
      whisperForm.append('file', audio, 'recording.wav')
      whisperForm.append('model', 'whisper-1')
      const response = await request(`${origin}/v1/audio/transcriptions`, {
        method: 'POST',
        headers,
        body: whisperForm,
        signal,
      })
      return await parseTranscriptResponse(response)
    }
    throw error
  }
}

/** 语音合成：返回裸 PCM 字节流；服务端默认过滤代码块、表格、引用标记与长公式 */
export const synthesize = async (
  apiKey: string,
  text: string,
  voice: TtsVoice,
  signal: AbortSignal
): Promise<ReadableStream<Uint8Array>> => {
  const state = useSettings.getState()
  const useAccount = isUsingDeepSeekAccount(state)
  const effectiveKey = state.apiKey ?? apiKey
  const useBearer = Boolean(state.apiKey) || !useAccount
  const origin = useAccount ? API_ORIGIN : normalizeOrigin(state.apiBaseUrl)
  const response = await request(`${origin}/v1/tools/tts`, {
    method: 'POST',
    headers: { ...speechAuthHeaders(effectiveKey, useBearer), 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, voice_id: voice, format: 'pcm', filter_markdown: true }),
    signal,
  })
  if (!response.body) {
    throw new ApiError('protocol', await response.text())
  }
  return response.body
}
