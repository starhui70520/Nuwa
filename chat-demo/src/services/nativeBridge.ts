import { Capacitor, registerPlugin } from '@capacitor/core'

export type DeepSeekMigrationPlugin = {
  openExportBrowser: () => Promise<{ filePath?: string; fileName?: string } | void>
  consumePendingExport: () => Promise<{
    hasPending: boolean
    filePath?: string
    fileName?: string
  }>
  clearPendingExport: () => Promise<void>
  startPlatformAuth: () => Promise<{ token?: string; accountLabel?: string | null } | void>
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
  speakText: (options: { text: string; locale: string }) => Promise<{ utteranceId: string }>
  stopSpeaking: () => Promise<void>
}

export const DeepSeekMigration = registerPlugin<DeepSeekMigrationPlugin>('DeepSeekMigration')

export const isNativeAndroid = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

export const isNativeIos = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios'
