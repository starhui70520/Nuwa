import { Capacitor, registerPlugin } from '@capacitor/core'

export type DeepSeekMigrationPlugin = {
  openExportBrowser: () => Promise<void>
  consumePendingExport: () => Promise<{
    hasPending: boolean
    filePath?: string
    fileName?: string
  }>
  clearPendingExport: () => Promise<void>
  startPlatformAuth: () => Promise<void>
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
}

export const DeepSeekMigration = registerPlugin<DeepSeekMigrationPlugin>('DeepSeekMigration')

export const isNativeAndroid = (): boolean =>
  Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'
