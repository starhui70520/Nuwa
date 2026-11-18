import { create } from 'zustand'
import type { TtsVoice } from './api/speech.js'
import { normalizeLocation, type UserLocation } from './location.js'

export type Locale = 'zh-CN' | 'en-US'

/** 主题偏好；默认跟随系统 */
export type ThemePreference = 'light' | 'dark' | 'system'

/** 聊天正文字号（px）；默认 16px */
export const CHAT_FONT_SIZES = [12, 14, 16, 18, 20, 22] as const
export type ChatFontSize = (typeof CHAT_FONT_SIZES)[number]
export const DEFAULT_CHAT_FONT_SIZE: ChatFontSize = 16

/** API 接口协议 */
export type ApiProtocol = 'openai' | 'anthropic'

/** 当前鉴权模式：DeepSeek API 账号授权登录 或 手动 API Key */
export type AuthMode = 'deepseek-account' | 'api-key'

/** 本机设置，存 localStorage：鉴权凭据、API 配置、语言、主题、位置、朗读音色、深度思考与智能搜索开关、侧边栏收起状态 */
type Settings = {
  authMode: AuthMode
  dshToken: string | null
  dshAccountLabel: string | null
  apiKey: string | null
  apiProtocol: ApiProtocol
  apiBaseUrl: string
  apiModel: string
  migrationPromptHandled: boolean
  showMigrationPrompt: boolean
  locale: Locale
  themePreference: ThemePreference
  chatFontSize: ChatFontSize
  location: UserLocation | null
  ttsVoice: TtsVoice
  ttsMuted: boolean
  speechEngine: SpeechEngine
  icloudAutoBackup: boolean
  thinking: boolean
  search: boolean
  siderCollapsed: boolean
}

const KEYS = {
  authMode: 'chat-demo:auth-mode',
  dshToken: 'chat-demo:dsh-token',
  dshAccountLabel: 'chat-demo:dsh-account-label',
  apiKey: 'chat-demo:api-key',
  apiProtocol: 'chat-demo:api-protocol',
  apiBaseUrl: 'chat-demo:api-base-url',
  apiModel: 'chat-demo:api-model',
  migrationPromptHandled: 'chat-demo:migration-prompt-handled',
  locale: 'chat-demo:locale',
  location: 'chat-demo:location',
  themePreference: 'chat-demo:theme-preference',
  chatFontSize: 'chat-demo:chat-font-size',
  ttsVoice: 'chat-demo:tts-voice',
  ttsMuted: 'chat-demo:tts-muted',
  speechEngine: 'chat-demo:speech-engine',
  icloudAutoBackup: 'chat-demo:icloud-auto-backup',
  thinking: 'chat-demo:thinking',
  search: 'chat-demo:search',
  siderCollapsed: 'chat-demo:sider-collapsed',
} as const

const read = (key: string) => {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

const write = (key: string, value: string | null) => {
  try {
    if (value === null) {
      localStorage.removeItem(key)
    } else {
      localStorage.setItem(key, value)
    }
  } catch {
    // 存储不可用时只在内存中生效
  }
}

/** 位置选择模式跟随浏览器语言，与应用内选择的界面语言无关。 */
export const isChineseBrowser = (): boolean =>
  (typeof navigator === 'undefined' ? 'zh' : navigator.language).toLowerCase().startsWith('zh')

const initialLocale = (): Locale => {
  const saved = read(KEYS.locale)
  if (saved === 'zh-CN' || saved === 'en-US') {
    return saved
  }
  return isChineseBrowser() ? 'zh-CN' : 'en-US'
}

const initialLocation = (): UserLocation | null => {
  try {
    const location = normalizeLocation(JSON.parse(read(KEYS.location) ?? 'null'))
    if (!location) {
      return null
    }
    return isChineseBrowser()
      ? location.region === 'CN' && location.province
        ? location
        : null
      : { region: location.region }
  } catch {
    return null
  }
}

/** 未保存过时跟随系统 */
const initialThemePreference = (): ThemePreference => {
  const saved = read(KEYS.themePreference)
  return saved === 'light' || saved === 'dark' ? saved : 'system'
}

/** 未保存过时默认 16px */
const initialChatFontSize = (): ChatFontSize => {
  const saved = Number(read(KEYS.chatFontSize))
  return (CHAT_FONT_SIZES as readonly number[]).includes(saved)
    ? (saved as ChatFontSize)
    : DEFAULT_CHAT_FONT_SIZE
}

/** 未保存过时使用服务端默认音色 stella（海星） */
const initialTtsVoice = (): TtsVoice => (read(KEYS.ttsVoice) === 'tide' ? 'tide' : 'stella')

/** 语音引擎：auto 有 API Key 时云端、否则设备原生；native 强制原生（仅原生壳可选）；cloud 强制云端 */
export type SpeechEngine = 'auto' | 'native' | 'cloud'
const initialSpeechEngine = (): SpeechEngine => {
  const saved = read(KEYS.speechEngine)
  return saved === 'native' || saved === 'cloud' ? saved : 'auto'
}

const initialApiProtocol = (): ApiProtocol =>
  read(KEYS.apiProtocol) === 'anthropic' ? 'anthropic' : 'openai'

const initialDshToken = read(KEYS.dshToken)

const initialAuthMode = (): AuthMode => {
  const saved = read(KEYS.authMode)
  if (saved === 'deepseek-account' && initialDshToken) {
    return 'deepseek-account'
  }
  if (saved === 'api-key') {
    return 'api-key'
  }
  return initialDshToken ? 'deepseek-account' : 'api-key'
}

export const useSettings = create<Settings>(() => ({
  authMode: initialAuthMode(),
  dshToken: initialDshToken,
  dshAccountLabel: read(KEYS.dshAccountLabel),
  apiKey: read(KEYS.apiKey),
  apiProtocol: initialApiProtocol(),
  apiBaseUrl: read(KEYS.apiBaseUrl) ?? 'https://api.deepseek.com',
  apiModel: read(KEYS.apiModel) ?? 'deepseek-chat',
  migrationPromptHandled: read(KEYS.migrationPromptHandled) === 'true',
  showMigrationPrompt: false,
  locale: initialLocale(),
  location: initialLocation(),
  themePreference: initialThemePreference(),
  chatFontSize: initialChatFontSize(),
  ttsVoice: initialTtsVoice(),
  ttsMuted: read(KEYS.ttsMuted) !== 'false',
  speechEngine: initialSpeechEngine(),
  icloudAutoBackup: read(KEYS.icloudAutoBackup) === 'true',
  thinking: read(KEYS.thinking) === 'true',
  search: read(KEYS.search) === 'true',
  siderCollapsed: read(KEYS.siderCollapsed) === 'true',
}))

export const hasActiveCredential = (state: Settings = useSettings.getState()): boolean =>
  (state.authMode === 'deepseek-account' && Boolean(state.dshToken)) || Boolean(state.apiKey)

export const isUsingDeepSeekAccount = (state: Settings = useSettings.getState()): boolean =>
  state.authMode === 'deepseek-account' && Boolean(state.dshToken)

export const getActiveSecret = (state: Settings = useSettings.getState()): string =>
  isUsingDeepSeekAccount(state) ? (state.dshToken ?? '') : (state.apiKey ?? '')

export const setLocale = (locale: Locale) => {
  write(KEYS.locale, locale)
  useSettings.setState({ locale })
}

export const setLocation = (value: UserLocation | null) => {
  const location = normalizeLocation(value)
  write(KEYS.location, location ? JSON.stringify(location) : null)
  useSettings.setState({ location })
}

export const setThemePreference = (themePreference: ThemePreference) => {
  write(KEYS.themePreference, themePreference)
  useSettings.setState({ themePreference })
}

export const setChatFontSize = (chatFontSize: ChatFontSize) => {
  write(KEYS.chatFontSize, String(chatFontSize))
  useSettings.setState({ chatFontSize })
}

export const setTtsVoice = (ttsVoice: TtsVoice) => {
  write(KEYS.ttsVoice, ttsVoice)
  useSettings.setState({ ttsVoice })
}

export const setSpeechEngine = (speechEngine: SpeechEngine) => {
  write(KEYS.speechEngine, speechEngine)
  useSettings.setState({ speechEngine })
}

export const setIcloudAutoBackup = (icloudAutoBackup: boolean) => {
  write(KEYS.icloudAutoBackup, String(icloudAutoBackup))
  useSettings.setState({ icloudAutoBackup })
}

export const setTtsMuted = (ttsMuted: boolean) => {
  write(KEYS.ttsMuted, String(ttsMuted))
  useSettings.setState({ ttsMuted })
}

export const setApiKey = (apiKey: string | null) => {
  write(KEYS.apiKey, apiKey)
  if (apiKey) {
    write(KEYS.authMode, 'api-key')
    const handled = useSettings.getState().migrationPromptHandled
    useSettings.setState({
      apiKey,
      authMode: 'api-key',
      ...(!handled ? { showMigrationPrompt: true } : {}),
    })
    return
  }
  useSettings.setState({ apiKey })
}

export const setDeepSeekAccountAuth = (dshToken: string, dshAccountLabel: string | null) => {
  write(KEYS.dshToken, dshToken)
  write(KEYS.dshAccountLabel, dshAccountLabel)
  write(KEYS.authMode, 'deepseek-account')
  const handled = useSettings.getState().migrationPromptHandled
  useSettings.setState({
    dshToken,
    dshAccountLabel,
    authMode: 'deepseek-account',
    ...(!handled ? { showMigrationPrompt: true } : {}),
  })
}

export const clearDeepSeekAccountAuth = () => {
  write(KEYS.dshToken, null)
  write(KEYS.dshAccountLabel, null)
  write(KEYS.authMode, 'api-key')
  useSettings.setState({
    dshToken: null,
    dshAccountLabel: null,
    authMode: 'api-key',
  })
}

export const setAuthMode = (authMode: AuthMode) => {
  write(KEYS.authMode, authMode)
  useSettings.setState({ authMode })
}

export const dismissMigrationPrompt = () => {
  write(KEYS.migrationPromptHandled, 'true')
  useSettings.setState({ migrationPromptHandled: true, showMigrationPrompt: false })
}

export const setApiProtocol = (apiProtocol: ApiProtocol) => {
  write(KEYS.apiProtocol, apiProtocol)
  useSettings.setState({ apiProtocol })
}

export const setApiBaseUrl = (apiBaseUrl: string) => {
  write(KEYS.apiBaseUrl, apiBaseUrl)
  useSettings.setState({ apiBaseUrl })
}

export const setApiModel = (apiModel: string) => {
  write(KEYS.apiModel, apiModel)
  useSettings.setState({ apiModel })
}

export const setThinking = (thinking: boolean) => {
  write(KEYS.thinking, String(thinking))
  useSettings.setState({ thinking })
}

export const setSearch = (search: boolean) => {
  write(KEYS.search, String(search))
  useSettings.setState({ search })
}

export const setSiderCollapsed = (siderCollapsed: boolean) => {
  write(KEYS.siderCollapsed, String(siderCollapsed))
  useSettings.setState({ siderCollapsed })
}
