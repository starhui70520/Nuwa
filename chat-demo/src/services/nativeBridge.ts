import { Capacitor, registerPlugin } from '@capacitor/core'

export type DeepSeekMigrationPlugin = {
  openExportBrowser: () => Promise<{ filePath?: string; fileName?: string } | undefined>
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
  setSystemBarsStyle: (options: { dark: boolean }) => Promise<void>
  getSpeechEngineInfo: () => Promise<{
    brand: string
    osLabel: string
    isHyperOs: boolean
    asrEngine: string
    asrLabel: string
    ttsEngine: string
    ttsLabel: string
  }>
  openSystemTtsSettings: () => Promise<void>
  saveFileToDocuments: (options: { name: string; data: string }) => Promise<{ presented: boolean }>
  icloudStatus: () => Promise<{ available: boolean }>
  icloudBackupNow: (options: { name: string; data: string }) => Promise<{ path: string }>
}

export const DeepSeekMigration = registerPlugin<DeepSeekMigrationPlugin>('DeepSeekMigration')

export const isNativeAndroid = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

export const isNativeIos = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios'

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
