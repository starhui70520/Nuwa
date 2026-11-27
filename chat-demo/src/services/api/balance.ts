import { create } from 'zustand'
import {
  hasActiveCredential,
  isUsingDeepSeekAccount,
  isUsingRankAIFree,
  useSettings,
} from '../settings.js'
import { API_ORIGIN } from './client.js'

export type AccountBalance = {
  currency: string
  totalBalance: string
  formatted: string
  isAvailable: boolean
}

type SettingsState = ReturnType<typeof useSettings.getState>

type CachedBalance = {
  tag: string
  balance: AccountBalance
}

const CACHE_KEY = 'chat-demo:balance-cache'
const REQUEST_TIMEOUT_MS = 10_000
const REFRESH_COOLDOWN_MS = 15_000
const POST_REPLY_REFRESH_DELAY_MS = 2500

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null

const normalizeOrigin = (rawBaseUrl: string): string => {
  const trimmed = rawBaseUrl.trim().replace(/\/+$/, '')
  if (!trimmed) {
    return API_ORIGIN
  }
  return trimmed.replace(/\/(v1|anthropic(?:\/v1)?)$/i, '')
}

const getCredentialTag = (state: SettingsState = useSettings.getState()): string | null => {
  if (!hasActiveCredential(state) || isUsingRankAIFree(state)) {
    return null
  }
  if (isUsingDeepSeekAccount(state)) {
    const token = state.dshToken ?? ''
    return `dsh:${token.slice(0, 6)}:${String(token.length)}`
  }
  const key = state.apiKey ?? ''
  return `key:${normalizeOrigin(state.apiBaseUrl)}:${key.slice(0, 6)}:${String(key.length)}`
}

const buildAccountBalance = (
  currency: string,
  rawTotal: string | number,
  isAvailable: boolean
): AccountBalance | null => {
  const numeric = typeof rawTotal === 'number' ? rawTotal : Number(rawTotal.trim())
  if (!Number.isFinite(numeric)) {
    return null
  }
  let amount: string
  if (typeof rawTotal === 'string' && /^-?\d+\.\d{2}$/.test(rawTotal.trim())) {
    amount = rawTotal.trim()
  } else if (numeric !== 0 && Math.abs(numeric) < 0.01) {
    amount = numeric.toFixed(4).replace(/0+$/, '').replace(/\.$/, '')
  } else {
    amount = numeric.toFixed(2)
  }

  const upperCurrency = currency.trim().toUpperCase()
  let formatted: string
  if (upperCurrency === 'CNY' || upperCurrency === 'RMB') {
    formatted = `¥${amount}`
  } else if (upperCurrency === 'USD') {
    formatted = `$${amount}`
  } else if (upperCurrency === 'EUR') {
    formatted = `€${amount}`
  } else {
    formatted = `${upperCurrency} ${amount}`
  }

  return {
    currency: upperCurrency,
    totalBalance: amount,
    formatted,
    isAvailable,
  }
}

const parseDeepSeekBalance = (payload: unknown, locale: string): AccountBalance | null => {
  if (!isRecord(payload) || !Array.isArray(payload.balance_infos)) {
    return null
  }
  const candidates: Array<{ currency: string; total: string | number; numeric: number }> = []
  for (const item of payload.balance_infos) {
    if (!isRecord(item) || typeof item.currency !== 'string') {
      continue
    }
    const total = item.total_balance
    if (typeof total !== 'string' && typeof total !== 'number') {
      continue
    }
    const numeric = typeof total === 'number' ? total : Number(total.trim())
    if (!Number.isFinite(numeric)) {
      continue
    }
    candidates.push({ currency: item.currency, total, numeric })
  }
  if (candidates.length === 0) {
    return null
  }

  const preferredCurrency = locale.toLowerCase().startsWith('zh') ? 'CNY' : 'USD'
  const positive = candidates.filter((entry) => entry.numeric > 0)
  const pool = positive.length > 0 ? positive : candidates
  const chosen =
    pool.find((entry) => entry.currency.trim().toUpperCase() === preferredCurrency) ?? pool[0]
  if (!chosen) {
    return null
  }
  const isAvailable =
    typeof payload.is_available === 'boolean' ? payload.is_available : chosen.numeric > 0
  return buildAccountBalance(chosen.currency, chosen.total, isAvailable)
}

const fetchJson = async (
  url: string,
  headers: Record<string, string>,
  signal: AbortSignal
): Promise<unknown> => {
  if (signal.aborted) {
    return null
  }
  const controller = new AbortController()
  const onAbort = () => controller.abort()
  signal.addEventListener('abort', onAbort, { once: true })
  const timer = window.setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers,
      signal: controller.signal,
    })
    if (!response.ok) {
      return null
    }
    return (await response.json()) as unknown
  } catch {
    return null
  } finally {
    window.clearTimeout(timer)
    signal.removeEventListener('abort', onAbort)
  }
}

const toYmd = (timestamp: number): string => {
  const date = new Date(timestamp)
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

const fetchBalanceForCurrentSettings = async (
  signal: AbortSignal
): Promise<AccountBalance | null> => {
  const state = useSettings.getState()
  if (!hasActiveCredential(state) || isUsingRankAIFree(state)) {
    return null
  }

  if (isUsingDeepSeekAccount(state)) {
    const token = state.dshToken ?? ''
    // DeepSeek API 账号授权令牌需通过 x-dsh-auth-token 查询余额（Bearer 会返回 401）
    const payload = await fetchJson(
      `${API_ORIGIN}/user/balance`,
      { 'x-dsh-auth-token': token },
      signal
    )
    return parseDeepSeekBalance(payload, state.locale)
  }

  const origin = normalizeOrigin(state.apiBaseUrl)
  const authHeaders = { Authorization: `Bearer ${state.apiKey ?? ''}` }

  const deepseekPayload = await fetchJson(`${origin}/user/balance`, authHeaders, signal)
  const direct = parseDeepSeekBalance(deepseekPayload, state.locale)
  if (direct) {
    return direct
  }

  const lowerOrigin = origin.toLowerCase()
  if (lowerOrigin.includes('openrouter.ai')) {
    const payload = await fetchJson(`${origin}/api/v1/credits`, authHeaders, signal)
    const dataNode = isRecord(payload) && isRecord(payload.data) ? payload.data : payload
    if (
      isRecord(dataNode) &&
      typeof dataNode.total_credits === 'number' &&
      typeof dataNode.total_usage === 'number'
    ) {
      const remaining = dataNode.total_credits - dataNode.total_usage
      return buildAccountBalance('USD', remaining, remaining > 0)
    }
    return null
  }

  if (lowerOrigin.includes('siliconflow')) {
    const payload = await fetchJson(`${origin}/v1/user/info`, authHeaders, signal)
    const dataNode = isRecord(payload) && isRecord(payload.data) ? payload.data : payload
    if (
      isRecord(dataNode) &&
      (typeof dataNode.totalBalance === 'string' || typeof dataNode.totalBalance === 'number')
    ) {
      const numeric = Number(dataNode.totalBalance)
      return buildAccountBalance('CNY', dataNode.totalBalance, numeric > 0)
    }
    return null
  }

  const subscription = await fetchJson(
    `${origin}/v1/dashboard/billing/subscription`,
    authHeaders,
    signal
  )
  if (
    !isRecord(subscription) ||
    typeof subscription.hard_limit_usd !== 'number' ||
    !Number.isFinite(subscription.hard_limit_usd) ||
    subscription.hard_limit_usd <= 0 ||
    subscription.hard_limit_usd >= 10_000_000
  ) {
    return null
  }

  const now = Date.now()
  const startDate = toYmd(now - 99 * 86_400_000)
  const endDate = toYmd(now + 86_400_000)
  const usage = await fetchJson(
    `${origin}/v1/dashboard/billing/usage?start_date=${startDate}&end_date=${endDate}`,
    authHeaders,
    signal
  )
  if (!isRecord(usage) || typeof usage.total_usage !== 'number' || !Number.isFinite(usage.total_usage)) {
    return null
  }
  const remaining = subscription.hard_limit_usd - usage.total_usage / 100
  return buildAccountBalance('USD', remaining, remaining > 0)
}

const readCachedBalance = (expectedTag: string | null): AccountBalance | null => {
  if (!expectedTag) {
    return null
  }
  try {
    const raw = localStorage.getItem(CACHE_KEY)
    if (!raw) {
      return null
    }
    const parsed: unknown = JSON.parse(raw)
    if (!isRecord(parsed) || parsed.tag !== expectedTag || !isRecord(parsed.balance)) {
      return null
    }
    const { currency, totalBalance, formatted, isAvailable } = parsed.balance
    if (
      typeof currency !== 'string' ||
      typeof totalBalance !== 'string' ||
      typeof formatted !== 'string' ||
      typeof isAvailable !== 'boolean'
    ) {
      return null
    }
    return { currency, totalBalance, formatted, isAvailable }
  } catch {
    return null
  }
}

const writeCachedBalance = (entry: CachedBalance | null) => {
  try {
    if (!entry) {
      localStorage.removeItem(CACHE_KEY)
    } else {
      localStorage.setItem(CACHE_KEY, JSON.stringify(entry))
    }
  } catch {
    // 存储不可用时仅在内存中生效
  }
}

const initialTag = getCredentialTag()

export const useBalance = create<{ balance: AccountBalance | null; loading: boolean }>(() => ({
  balance: readCachedBalance(initialTag),
  loading: false,
}))

let lastTag: string | null = initialTag
let lastFetchedAt = 0
let activeRequest: { tag: string; controller: AbortController } | null = null
let postReplyTimer = 0

/** 刷新当前生效凭据的账户余额；冷却期内非强制调用会跳过重复请求 */
export const refreshBalance = async (options?: { force?: boolean }): Promise<void> => {
  const tag = getCredentialTag()
  if (!tag) {
    activeRequest?.controller.abort()
    activeRequest = null
    lastFetchedAt = 0
    writeCachedBalance(null)
    useBalance.setState({ balance: null, loading: false })
    return
  }

  if (!options?.force) {
    if (activeRequest && activeRequest.tag === tag) {
      return
    }
    if (Date.now() - lastFetchedAt < REFRESH_COOLDOWN_MS && useBalance.getState().balance !== null) {
      return
    }
  }

  if (activeRequest) {
    activeRequest.controller.abort()
    activeRequest = null
  }

  const controller = new AbortController()
  activeRequest = { tag, controller }
  useBalance.setState({ loading: true })

  try {
    const next = await fetchBalanceForCurrentSettings(controller.signal)
    if (controller.signal.aborted || getCredentialTag() !== tag) {
      return
    }
    if (next) {
      lastFetchedAt = Date.now()
      writeCachedBalance({ tag, balance: next })
      useBalance.setState({ balance: next, loading: false })
    } else {
      useBalance.setState({ loading: false })
    }
  } finally {
    if (activeRequest?.controller === controller) {
      activeRequest = null
      if (getCredentialTag() === tag) {
        useBalance.setState((state) => (state.loading ? { loading: false } : state))
      }
    }
  }
}

/** 每次回复结束后刷新余额，并延迟补刷一次以等待服务端计费入账 */
export const refreshBalanceAfterReply = (): void => {
  window.clearTimeout(postReplyTimer)
  void refreshBalance({ force: true })
  postReplyTimer = window.setTimeout(() => {
    void refreshBalance({ force: true })
  }, POST_REPLY_REFRESH_DELAY_MS)
}

useSettings.subscribe((state) => {
  const nextTag = getCredentialTag(state)
  if (nextTag === lastTag) {
    return
  }
  lastTag = nextTag
  lastFetchedAt = 0
  window.clearTimeout(postReplyTimer)
  activeRequest?.controller.abort()
  activeRequest = null
  if (!nextTag) {
    writeCachedBalance(null)
    useBalance.setState({ balance: null, loading: false })
    return
  }
  useBalance.setState({ balance: null, loading: false })
  void refreshBalance({ force: true })
})
