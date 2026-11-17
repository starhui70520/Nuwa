import { Capacitor } from '@capacitor/core'
import { showToast } from '../../components/base/toastState.js'
import { checkPendingAndroidPlatformAuth, handleWebOAuthCallback } from '../api/dshAuth.js'
import { DeepSeekMigration, isNativeAndroid } from '../nativeBridge.js'
import { setDeepSeekAccountAuth } from '../settings.js'
import { BackupError, importHistory, importHistoryFromBytes } from './backup.js'

export { isNativeAndroid }

declare global {
  interface Window {
    __DSAPP_IMPORT_ZIP__?: (data: File | Uint8Array | ArrayBuffer, name?: string) => Promise<number>
  }
}

export const runZipImport = async (
  input: File | Uint8Array | ArrayBuffer,
  name?: string
): Promise<number> => {
  try {
    const count =
      input instanceof File ? await importHistory(input) : await importHistoryFromBytes(input, name)
    showToast(
      count === 1 ? { key: 'historyImportedOne' } : { key: 'historyImported', params: { count } }
    )
    return count
  } catch (error) {
    showToast({
      key: error instanceof BackupError ? error.key : 'historyImportFailed',
      type: 'error',
    })
    throw error
  }
}

let consumingPending = false

/** 检查并导入安卓原生下载接管落盘的导出包（即使 MainActivity 被系统重启也不会丢失） */
export const checkPendingAndroidMigration = async (): Promise<void> => {
  if (!isNativeAndroid() || consumingPending) {
    return
  }
  consumingPending = true
  try {
    const pending = await DeepSeekMigration.consumePendingExport()
    if (!pending.hasPending || !pending.filePath) {
      return
    }
    const res = await fetch(Capacitor.convertFileSrc(pending.filePath))
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`)
    }
    const buffer = await res.arrayBuffer()
    await DeepSeekMigration.clearPendingExport()
    await runZipImport(buffer, pending.fileName || 'deepseek_data.zip')
  } finally {
    consumingPending = false
  }
}

/** 绑定跨端导入与登录桥接（桌面端 Tauri / 移动端 Capacitor / 浏览器插件统一入口） */
export const bindMigrationBridge = (): (() => void) => {
  window.__DSAPP_IMPORT_ZIP__ = (data, name) => runZipImport(data, name)

  const handleMessage = (event: MessageEvent) => {
    if (event.source !== window && event.origin !== window.location.origin) {
      return
    }
    const data = event.data as {
      type?: string
      payload?: File | Uint8Array | ArrayBuffer
      name?: string
    } | null
    if (data?.type === 'dsapp:import-zip' && data.payload) {
      void runZipImport(data.payload, data.name).catch(() => {})
    }
  }

  const handleVisibility = () => {
    if (document.visibilityState === 'visible') {
      void checkPendingAndroidPlatformAuth().catch(() => {})
      void checkPendingAndroidMigration().catch(() => {})
    }
  }

  const handleNativeResume = () => {
    void checkPendingAndroidPlatformAuth().catch(() => {})
    void checkPendingAndroidMigration().catch(() => {})
  }

  const handleHarmonyAuth = (event: Event) => {
    const detail = (event as CustomEvent<{ token?: string; accountLabel?: string | null }>).detail
    if (detail?.token) {
      setDeepSeekAccountAuth(detail.token, detail.accountLabel ?? null)
      showToast({ key: 'dshLoginSuccess' })
    }
  }

  const handleHarmonyAuthError = (event: Event) => {
    const detail = (event as CustomEvent<{ message?: string }>).detail
    if (detail?.message) {
      showToast({
        key: 'apiKeyVerificationFailed',
        params: { message: detail.message },
        type: 'error',
      })
      return
    }
    showToast({ key: 'dshLoginFailed', type: 'error' })
  }

  window.addEventListener('message', handleMessage)
  document.addEventListener('visibilitychange', handleVisibility)
  window.addEventListener('focus', handleVisibility)
  window.addEventListener('dsapp:native-resume', handleNativeResume)
  window.addEventListener('nuwa:harmony-auth', handleHarmonyAuth)
  window.addEventListener('nuwa:harmony-auth-error', handleHarmonyAuthError)
  void handleWebOAuthCallback().catch(() => {})
  void checkPendingAndroidPlatformAuth().catch(() => {})
  void checkPendingAndroidMigration().catch(() => {})

  return () => {
    delete window.__DSAPP_IMPORT_ZIP__
    window.removeEventListener('message', handleMessage)
    document.removeEventListener('visibilitychange', handleVisibility)
    window.removeEventListener('focus', handleVisibility)
    window.removeEventListener('dsapp:native-resume', handleNativeResume)
    window.removeEventListener('nuwa:harmony-auth', handleHarmonyAuth)
    window.removeEventListener('nuwa:harmony-auth-error', handleHarmonyAuthError)
  }
}

/** 安卓原生内嵌浏览器迁移：打开官方页，用户登录并点导出后自动接管并导入 */
export const launchAndroidMigrationBrowser = async (): Promise<void> => {
  await DeepSeekMigration.openExportBrowser()
}

/** 跨端统一一键迁移入口 */
export const triggerOneClickMigration = async (): Promise<void> => {
  if (isNativeAndroid()) {
    await launchAndroidMigrationBrowser()
    return
  }
  window.open('https://chat.deepseek.com/', '_blank', 'noopener,noreferrer')
  showToast({ key: 'migrationGuideDropHint' })
}
