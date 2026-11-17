import { showToast } from '../../components/base/toastState.js'
import {
  DeepSeekMigration,
  isNativeAndroid,
  isNativeIos,
  type HarmonySpeechBridge,
} from '../nativeBridge.js'
import { clearDeepSeekAccountAuth, setDeepSeekAccountAuth, useSettings } from '../settings.js'

const WEB_PKCE_STORAGE_KEY = 'nuwa:dsh-pkce-state'
const WEB_DEVICE_ID_KEY = 'nuwa:dsh-device-id'

declare global {
  interface Window {
    __NUWA_HARMONY__?: HarmonySpeechBridge & {
      startPlatformAuth?: () => void
      logoutPlatformAuth?: (token: string) => void
      openExportBrowser?: () => void
      openPrivacyPolicy?: () => void
    }
  }
}

export const hasHarmonyBridge = (): boolean =>
  typeof window !== 'undefined' && Boolean(window.__NUWA_HARMONY__?.startPlatformAuth)

const getOrCreateWebDeviceId = (): string => {
  try {
    const existing = localStorage.getItem(WEB_DEVICE_ID_KEY)
    if (existing) {
      return existing
    }
    const created = crypto.randomUUID()
    localStorage.setItem(WEB_DEVICE_ID_KEY, created)
    return created
  } catch {
    return crypto.randomUUID()
  }
}

const platformWireLocale = (): 'zh_CN' | 'en_US' =>
  useSettings.getState().locale.toLowerCase().startsWith('zh') ? 'zh_CN' : 'en_US'

const platformClientHeaders = (): Record<string, string> => ({
  'x-client-bundle-id': '',
  'x-client-platform': 'web',
  'x-client-version': '0.2.2',
  'x-client-locale': platformWireLocale(),
  'x-client-timezone-offset': String(-new Date().getTimezoneOffset() * 60 || 0),
})

export class PlatformAuthUnavailableError extends Error {
  constructor(message = 'Web PKCE auth endpoint unavailable') {
    super(message)
    this.name = 'PlatformAuthUnavailableError'
  }
}

const toBase64Url = (bytes: Uint8Array): string => {
  let binary = ''
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

const randomBase64Url = (length: number): string => {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  return toBase64Url(bytes)
}

const sha256Base64Url = async (input: string): Promise<string> => {
  const encoded = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest('SHA-256', encoded)
  return toBase64Url(new Uint8Array(digest))
}

const extractUserLabel = (user: unknown): string | null => {
  if (!user || typeof user !== 'object') {
    return null
  }
  const record = user as Record<string, unknown>
  const idProfile = record.id_profile
  if (idProfile && typeof idProfile === 'object') {
    const name = (idProfile as Record<string, unknown>).name
    if (typeof name === 'string' && name.trim()) {
      return name.trim()
    }
  }
  for (const key of ['mobile', 'mobile_number', 'email']) {
    const val = record[key]
    if (typeof val === 'string' && val.trim()) {
      return val.trim()
    }
  }
  return null
}

let checkingPendingAuth = false

/** 检查并消费安卓原生 PKCE 授权结果 */
export const checkPendingAndroidPlatformAuth = async (): Promise<boolean> => {
  if (!isNativeAndroid() || checkingPendingAuth) {
    return false
  }
  checkingPendingAuth = true
  try {
    const result = await DeepSeekMigration.consumePendingPlatformAuth()
    if (!result.hasPending || !result.token) {
      return false
    }
    setDeepSeekAccountAuth(result.token, result.accountLabel ?? null)
    showToast({ key: 'dshLoginSuccess' })
    return true
  } finally {
    checkingPendingAuth = false
  }
}

/** 处理 Web 开发代理模式下 /oauth/callback 回跳 */
export const handleWebOAuthCallback = async (): Promise<boolean> => {
  if (isNativeAndroid() || window.location.pathname !== '/oauth/callback') {
    return false
  }
  const params = new URLSearchParams(window.location.search)
  const code = params.get('code')
  const state = params.get('state')
  const rawSaved = sessionStorage.getItem(WEB_PKCE_STORAGE_KEY)
  sessionStorage.removeItem(WEB_PKCE_STORAGE_KEY)
  window.history.replaceState(null, '', '/')

  if (!code || !state || !rawSaved) {
    return false
  }
  const saved = JSON.parse(rawSaved) as {
    verifier: string
    state: string
    redirectUri: string
  }
  if (saved.state !== state) {
    return false
  }
  const res = await fetch('/auth-api/v0/dsh/auth_exchange', {
    method: 'POST',
    headers: {
      ...platformClientHeaders(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      code,
      code_verifier: saved.verifier,
      redirect_uri: saved.redirectUri,
      device_id: getOrCreateWebDeviceId(),
      device_model: 'Web-Browser',
      os_version: navigator.platform || 'Web',
    }),
  })
  if (!res.ok) {
    return false
  }
  const payload = (await res.json()) as {
    code?: number
    data?: { biz_code?: number; biz_data?: { token?: string; user?: unknown } }
  }
  const token = payload.data?.biz_data?.token
  if (payload.code !== 0 || payload.data?.biz_code !== 0 || !token) {
    return false
  }
  setDeepSeekAccountAuth(token, extractUserLabel(payload.data.biz_data?.user))
  showToast({ key: 'dshLoginSuccess' })
  return true
}

/** 发起 DeepSeek Harness PKCE 账号授权登录 */
export const startDeepSeekAccountLogin = async (): Promise<void> => {
  if (isNativeAndroid()) {
    await DeepSeekMigration.startPlatformAuth()
    return
  }
  if (window.__NUWA_HARMONY__?.startPlatformAuth) {
    window.__NUWA_HARMONY__.startPlatformAuth()
    return
  }
  if (isNativeIos()) {
    const result = await DeepSeekMigration.startPlatformAuth()
    if (result?.token) {
      setDeepSeekAccountAuth(result.token, result.accountLabel ?? null)
      showToast({ key: 'dshLoginSuccess' })
    }
    return
  }

  if (!window.crypto?.subtle) {
    throw new PlatformAuthUnavailableError()
  }
  const verifier = randomBase64Url(32)
  const state = randomBase64Url(32)
  const challenge = await sha256Base64Url(verifier)
  const redirectUri = `${window.location.origin}/oauth/callback`

  let res: Response
  try {
    res = await fetch('/auth-api/v0/dsh/auth_init', {
      method: 'POST',
      headers: {
        ...platformClientHeaders(),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        code_challenge: challenge,
        code_challenge_method: 'S256',
        state,
        redirect_uri: redirectUri,
        locale: platformWireLocale(),
        login_source: 'web',
      }),
    })
  } catch {
    throw new PlatformAuthUnavailableError()
  }
  if (!res.ok) {
    throw new PlatformAuthUnavailableError()
  }
  let payload: {
    code?: number
    data?: { biz_code?: number; biz_data?: { authorize_url?: string } }
  }
  try {
    payload = await res.json()
  } catch {
    throw new PlatformAuthUnavailableError()
  }
  const authorizeUrl = payload.data?.biz_data?.authorize_url
  if (payload.code !== 0 || payload.data?.biz_code !== 0 || !authorizeUrl) {
    throw new PlatformAuthUnavailableError()
  }
  sessionStorage.setItem(WEB_PKCE_STORAGE_KEY, JSON.stringify({ verifier, state, redirectUri }))
  window.location.href = authorizeUrl
}

/** 退出 DeepSeek API 账号登录并吊销远端令牌 */
export const logoutDeepSeekAccount = async (): Promise<void> => {
  const token = useSettings.getState().dshToken
  clearDeepSeekAccountAuth()
  if (!token) {
    return
  }
  if (isNativeAndroid() || isNativeIos()) {
    await DeepSeekMigration.logoutPlatformAuth({ token }).catch(() => {})
    return
  }
  if (window.__NUWA_HARMONY__?.logoutPlatformAuth) {
    window.__NUWA_HARMONY__.logoutPlatformAuth(token)
    return
  }
  await fetch('/auth-api/v0/users/logout', {
    method: 'POST',
    headers: {
      ...platformClientHeaders(),
      'x-dsh-auth-token': token,
    },
  }).catch(() => {})
}
