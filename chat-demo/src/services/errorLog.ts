import { getCurrentAppVersion } from './appUpdate.js'
import { isNativeAndroid, isNativeIos } from './nativeBridge.js'
import { useSettings } from './settings.js'

const STORAGE_KEY = 'nuwa:error-logs-v1'
const MAX_LOGS = 150
const REPORT_API_URL = 'https://dl.rankchord.com/api/reports'

export type AppLogLevel = 'error' | 'warn' | 'info'

export type AppLogEntry = {
  ts: string
  level: AppLogLevel
  source: string
  message: string
  detail?: string
}

export type AppDeviceInfo = {
  appVersion: string
  platform: string
  userAgent: string
  language: string
  screen: string
  viewport: string
  online: boolean
  timezone: string
  apiProtocol: string
  authMode: string
}

export type IssueReportResult = {
  code: string
  createdAt: string
}

export const ISSUE_TYPE_OPTIONS = [
  '页面白屏或闪退',
  '对话报错 / 无法回复',
  '语音或朗读异常',
  '一键导入记录失败',
  '文件 / 图片上传失败',
  '界面显示或排版异常',
  '其他问题',
] as const

const sanitizeText = (input: string, maxLen = 1000): string => {
  const masked = input
    .replace(/sk-[a-zA-Z0-9_-]{8,}/g, 'sk-***')
    .replace(/Bearer\s+[a-zA-Z0-9._-]{8,}/gi, 'Bearer ***')
    .replace(/(x-api-key|x-dsh-auth-token|apiKey|dshToken)\s*[:=]\s*["']?[^\s"',}]+/gi, '$1: ***')
  return masked.length > maxLen ? `${masked.slice(0, maxLen)}…` : masked
}

const formatArg = (arg: unknown): string => {
  if (arg instanceof Error) {
    return `${arg.name}: ${arg.message}`
  }
  if (typeof arg === 'string') {
    return arg
  }
  try {
    return JSON.stringify(arg)
  } catch {
    return String(arg)
  }
}

let logsBuffer: AppLogEntry[] = []
let loaded = false
let installed = false

const loadBuffer = () => {
  if (loaded) {
    return
  }
  loaded = true
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) {
      return
    }
    const parsed: unknown = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      logsBuffer = parsed
        .filter((item): item is AppLogEntry => Boolean(item && typeof item === 'object'))
        .slice(-MAX_LOGS)
    }
  } catch {
    logsBuffer = []
  }
}

const saveBuffer = () => {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(logsBuffer.slice(-MAX_LOGS)))
  } catch {
    // 忽略 localStorage 满或隐私模式异常
  }
}

export const recordAppLog = (
  level: AppLogLevel,
  source: string,
  message: string,
  detail?: string
): void => {
  loadBuffer()
  const entry: AppLogEntry = {
    ts: new Date().toISOString(),
    level,
    source: sanitizeText(source, 80),
    message: sanitizeText(message, 800),
    detail: detail ? sanitizeText(detail, 2500) : undefined,
  }
  logsBuffer.push(entry)
  if (logsBuffer.length > MAX_LOGS) {
    logsBuffer = logsBuffer.slice(-MAX_LOGS)
  }
  saveBuffer()
}

export const getAppLogs = (): AppLogEntry[] => {
  loadBuffer()
  return [...logsBuffer]
}

export const clearAppLogs = (): void => {
  logsBuffer = []
  loaded = true
  try {
    localStorage.removeItem(STORAGE_KEY)
  } catch {
    // ignore
  }
}

export const setupErrorLogging = (): void => {
  if (installed || typeof window === 'undefined') {
    return
  }
  installed = true
  loadBuffer()

  window.addEventListener('error', (event) => {
    const err = event.error instanceof Error ? event.error : null
    const msg = event.message || err?.message || 'Uncaught window error'
    const loc = event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : ''
    const detail = [loc, err?.stack].filter(Boolean).join('\n') || undefined
    recordAppLog('error', 'window.error', msg, detail)
  })

  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason
    const msg = reason instanceof Error ? `${reason.name}: ${reason.message}` : formatArg(reason)
    const detail = reason instanceof Error ? reason.stack : undefined
    recordAppLog('error', 'unhandledrejection', msg, detail)
  })

  // oxlint-disable-next-line no-console
  const origError = console.error.bind(console)
  // oxlint-disable-next-line no-console
  console.error = (...args: unknown[]) => {
    try {
      const msg = args.map(formatArg).join(' ')
      const firstErr = args.find((a): a is Error => a instanceof Error)
      recordAppLog('error', 'console.error', msg, firstErr?.stack)
    } catch {
      // ignore
    }
    origError(...args)
  }

  // oxlint-disable-next-line no-console
  const origWarn = console.warn.bind(console)
  // oxlint-disable-next-line no-console
  console.warn = (...args: unknown[]) => {
    try {
      const msg = args.map(formatArg).join(' ')
      recordAppLog('warn', 'console.warn', msg)
    } catch {
      // ignore
    }
    origWarn(...args)
  }
}

const detectPlatformName = (): string => {
  if (isNativeAndroid()) {
    return 'android'
  }
  if (isNativeIos()) {
    return 'ios'
  }
  if (typeof window !== 'undefined' && window.__NUWA_HARMONY__) {
    return 'harmony'
  }
  return 'web'
}

export const collectDeviceInfo = async (): Promise<AppDeviceInfo> => {
  const appVersion = await getCurrentAppVersion()
  const settings = useSettings.getState()
  const dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
  const screen =
    typeof window !== 'undefined' && window.screen
      ? `${window.screen.width}x${window.screen.height}@${dpr.toFixed(2)}`
      : 'unknown'
  const viewport =
    typeof window !== 'undefined' ? `${window.innerWidth}x${window.innerHeight}` : 'unknown'
  let timezone = 'unknown'
  try {
    timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'unknown'
  } catch {
    // ignore
  }

  return {
    appVersion,
    platform: detectPlatformName(),
    userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : 'unknown',
    language: typeof navigator !== 'undefined' ? navigator.language : 'unknown',
    screen,
    viewport,
    online: typeof navigator !== 'undefined' ? navigator.onLine : true,
    timezone,
    apiProtocol: settings.apiProtocol,
    authMode: settings.authMode,
  }
}

export const submitIssueReport = async (params: {
  issueType: string
  description: string
  contact?: string
  includeLogs?: boolean
}): Promise<IssueReportResult> => {
  const deviceInfo = await collectDeviceInfo()
  const logs = params.includeLogs === false ? [] : getAppLogs()

  const response = await fetch(REPORT_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      issueType: params.issueType.trim(),
      description: params.description.trim(),
      contact: params.contact?.trim() || undefined,
      deviceInfo,
      logs,
    }),
  })

  let data: { code?: string; createdAt?: string; error?: string } = {}
  try {
    data = (await response.json()) as typeof data
  } catch {
    // ignore non-json
  }

  if (!response.ok || !data.code) {
    throw new Error(data.error || `上报失败（HTTP ${response.status}）`)
  }

  return {
    code: data.code,
    createdAt: data.createdAt || new Date().toISOString(),
  }
}
