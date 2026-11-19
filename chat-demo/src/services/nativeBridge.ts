import { Capacitor, registerPlugin } from '@capacitor/core'

export type DeepSeekMigrationPlugin = {
  openExportBrowser: (options?: {
    clearSession?: boolean
    forceReExport?: boolean
  }) => Promise<{ filePath?: string; fileName?: string } | undefined>
  consumePendingExport: () => Promise<{
    hasPending: boolean
    filePath?: string
    fileName?: string
  }>
  clearPendingExport: () => Promise<void>
  startPlatformAuth: () => Promise<{ token?: string; accountLabel?: string | null } | undefined>
  consumePendingPlatformAuth: () => Promise<{
    hasPending: boolean
    token?: string
    accountLabel?: string
  }>
  logoutPlatformAuth: (options: { token: string }) => Promise<void>
  ensureMicrophonePermission: () => Promise<{ granted: boolean }>
  startSpeechRecognition: (options: { locale: string }) => Promise<void>
  stopSpeechRecognition: () => Promise<{ text: string }>
  cancelSpeechRecognition: () => Promise<void>
  getAppVersion: () => Promise<{ versionName: string; versionCode: number }>
  downloadAndInstallApk: (options: { url: string }) => Promise<{
    started: boolean
    needsInstallPermission?: boolean
  }>
  speakText: (options: { text: string; locale: string; voice?: string }) => Promise<{
    utteranceId: string
  }>
  stopSpeaking: () => Promise<void>
  updateReadAloudNotification: (options: { line: string }) => Promise<void>
  clearReadAloudNotification: () => Promise<void>
  setSystemBarsStyle: (options: { dark: boolean }) => Promise<void>
  getSpeechEngineInfo: () => Promise<{
    brand: string
    osLabel: string
    isHyperOs: boolean
    isFlyme?: boolean
    asrEngine: string
    asrLabel: string
    ttsEngine: string
    ttsLabel: string
  }>
  openSystemTtsSettings: () => Promise<void>
  prepareExternalUrls: (options: { urls: string[] }) => Promise<void>
  openExternalUrl: (options: { url: string; dark?: boolean }) => Promise<void>
  saveFileToDocuments: (options: { name: string; data: string }) => Promise<{ presented: boolean }>
  icloudStatus: () => Promise<{ available: boolean }>
  icloudBackupNow: (options: { name: string; data: string }) => Promise<{ path: string }>
  fetchShareContent: (options: { shareId: string }) => Promise<{ status: number; body: string }>
}

export const DeepSeekMigration = registerPlugin<DeepSeekMigrationPlugin>('DeepSeekMigration')

export const isNativeAndroid = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

export const isNativeIos = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios'

const MIN_MODERN_WEBVIEW_CHROME_MAJOR = 80

export const getChromeMajorVersion = (): number | null => {
  if (typeof navigator === 'undefined') {
    return null
  }
  const match = navigator.userAgent.match(/Chrome\/(\d+)/)
  if (!match) {
    return null
  }
  const major = Number.parseInt(match[1], 10)
  return Number.isFinite(major) ? major : null
}

/** 检测是否为不支持 DeepSeek 官方现代网页（如登录/一键迁移）的老版本 WebView */
export const isLegacyWebView = (): boolean => {
  const major = getChromeMajorVersion()
  return major !== null && major < MIN_MODERN_WEBVIEW_CHROME_MAJOR
}

export type HarmonySpeechBridge = {
  startSpeechRecognition?: (id: string, locale: string) => void
  stopSpeechRecognition?: (id: string) => void
  cancelSpeechRecognition?: (id: string) => void
  speakText?: (id: string, text: string, locale: string) => void
  stopSpeaking?: (id: string) => void
}

export type HarmonyAsrError = 'permission-denied' | 'unavailable' | 'failed'
export type HarmonyAsrEvent =
  | { id: string; state: 'started' }
  | { id: string; state: 'done'; text?: string }
  | { id: string; state: 'error'; code?: HarmonyAsrError }

export type HarmonyTtsEvent = { id: string; state: 'playing' | 'done' | 'error' }

export const getHarmonySpeechBridge = (): HarmonySpeechBridge | undefined =>
  typeof window === 'undefined' ? undefined : window.__NUWA_HARMONY__

let nextHarmonySpeechId = 0
export const createHarmonySpeechId = (): string => `${Date.now()}-${++nextHarmonySpeechId}`
