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
  setStreamKeepAlive: (options: { active: boolean }) => Promise<void>
  vaultSaveSession: (options: { id: string; json: string }) => Promise<void>
  vaultDeleteSession: (options: { id: string }) => Promise<void>
  vaultClearSessions: () => Promise<void>
  vaultListSessionIds: () => Promise<{ ids: string[] }>
  vaultReadSession: (options: { id: string }) => Promise<{ json?: string }>
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
  saveFileToDocuments: (options: {
    name: string
    data: string
    mode?: 'save' | 'share'
  }) => Promise<{ presented: boolean; savedPath?: string }>
  icloudStatus: () => Promise<{ available: boolean }>
  icloudBackupNow: (options: { name: string; data: string }) => Promise<{ path: string }>
  fetchShareContent: (options: { shareId: string }) => Promise<{ status: number; body: string }>
  downloadRemoteFile: (options: { url: string }) => Promise<{
    status: number
    filePath: string
    fileName: string
    contentType: string
    finalUrl: string
  }>
  getRecentPhotos: (options?: { limit?: number; requestPermission?: boolean }) => Promise<{
    permission: 'granted' | 'denied'
    items: Array<{
      id: string
      name: string
      mimeType: string
      thumbnail: string
    }>
  }>
  readRecentPhoto: (options: { id: string }) => Promise<{
    name: string
    mimeType: string
    data: string
  }>
}

export const DeepSeekMigration = registerPlugin<DeepSeekMigrationPlugin>('DeepSeekMigration')

export const isNativeAndroid = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

export const isNativeIos = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios'

/** 在流式回复或上下文整理期间通知原生层开启/关闭后台保活与防休眠 */
export const setNativeStreamKeepAlive = (active: boolean): void => {
  if (!isNativeAndroid() && !isNativeIos()) {
    return
  }
  void DeepSeekMigration.setStreamKeepAlive({ active }).catch(() => {})
}

/** Android 原生沙盒会话保险库：异步镜像写入，抵御 WebView IndexedDB 损坏或配额驱逐 */
export const saveSessionToNativeVault = (id: string, json: string): void => {
  if (!isNativeAndroid() || !id || !json) {
    return
  }
  void DeepSeekMigration.vaultSaveSession({ id, json }).catch(() => {})
}

export const deleteSessionFromNativeVault = async (id: string): Promise<void> => {
  if (!isNativeAndroid() || !id) {
    return
  }
  try {
    await DeepSeekMigration.vaultDeleteSession({ id })
  } catch {
    // 忽略低版本壳未实现或 I/O 异常
  }
}

export const clearNativeVaultSessions = async (): Promise<void> => {
  if (!isNativeAndroid()) {
    return
  }
  try {
    await DeepSeekMigration.vaultClearSessions()
  } catch {
    // 忽略低版本壳未实现或 I/O 异常
  }
}

export const listNativeVaultSessionIds = async (): Promise<string[]> => {
  if (!isNativeAndroid()) {
    return []
  }
  try {
    const res = await DeepSeekMigration.vaultListSessionIds()
    return Array.isArray(res?.ids) ? res.ids.filter((id): id is string => typeof id === 'string') : []
  } catch {
    return []
  }
}

export const readSessionFromNativeVault = async (id: string): Promise<string | null> => {
  if (!isNativeAndroid() || !id) {
    return null
  }
  try {
    const res = await DeepSeekMigration.vaultReadSession({ id })
    return typeof res?.json === 'string' && res.json.length > 0 ? res.json : null
  } catch {
    return null
  }
}

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
