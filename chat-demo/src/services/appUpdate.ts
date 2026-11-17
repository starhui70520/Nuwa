import { create } from 'zustand'
import { showToast } from '../components/base/toastState.js'
import { DeepSeekMigration, isNativeAndroid } from './nativeBridge.js'

const GITHUB_LATEST_RELEASE_URL = 'https://api.github.com/repos/starhui70520/Nuwa/releases/latest'
const LAST_AUTO_CHECK_KEY = 'nuwa_last_update_check_at'
const AUTO_CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000

export type AppUpdateInfo = {
  currentVersion: string
  latestVersion: string
  hasUpdate: boolean
  notes: string
  releaseUrl: string
  apkUrl: string | null
}

type GitHubReleaseResponse = {
  tag_name?: string
  body?: string
  html_url?: string
  assets?: Array<{
    name?: string
    browser_download_url?: string
  }>
}

/** 从构建注入的 meta 标签读取默认版本号 */
export const getWebAppVersion = (): string => {
  if (typeof document === 'undefined') {
    return '0.1.1'
  }
  return (
    document.querySelector('meta[name="application-version"]')?.getAttribute('content') || '0.1.1'
  )
}

/** 读取当前运行的客户端版本号（Android 原生优先读取 PackageInfo.versionName） */
export const getCurrentAppVersion = async (): Promise<string> => {
  if (isNativeAndroid()) {
    try {
      const info = await DeepSeekMigration.getAppVersion()
      if (info.versionName?.trim()) {
        return info.versionName.trim()
      }
    } catch {
      // 回退到 Web 注入版本
    }
  }
  return getWebAppVersion()
}

const normalizeVersion = (raw: string): string => raw.trim().replace(/^v/i, '')

/** 比较两个语义化版本号：a > b 返回 1，a < b 返回 -1，相等返回 0 */
export const compareVersions = (a: string, b: string): number => {
  const pa = normalizeVersion(a)
    .split(/[^0-9]+/)
    .filter(Boolean)
    .map((n) => Number.parseInt(n, 10) || 0)
  const pb = normalizeVersion(b)
    .split(/[^0-9]+/)
    .filter(Boolean)
    .map((n) => Number.parseInt(n, 10) || 0)
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i++) {
    const va = pa[i] ?? 0
    const vb = pb[i] ?? 0
    if (va > vb) {
      return 1
    }
    if (va < vb) {
      return -1
    }
  }
  return 0
}

/** 查询 GitHub Releases 最新版本 */
export const fetchLatestAppUpdate = async (): Promise<AppUpdateInfo> => {
  const currentVersion = normalizeVersion(await getCurrentAppVersion())
  const res = await fetch(GITHUB_LATEST_RELEASE_URL, {
    headers: { Accept: 'application/vnd.github+json' },
    cache: 'no-store',
  })

  if (res.status === 404) {
    return {
      currentVersion,
      latestVersion: currentVersion,
      hasUpdate: false,
      notes: '',
      releaseUrl: 'https://github.com/starhui70520/Nuwa/releases',
      apkUrl: null,
    }
  }

  if (!res.ok) {
    throw new Error(`GitHub API ${res.status}`)
  }

  const data = (await res.json()) as GitHubReleaseResponse
  const latestVersion = normalizeVersion(data.tag_name || currentVersion)
  const apkAsset = data.assets?.find(
    (asset) => typeof asset.name === 'string' && asset.name.toLowerCase().endsWith('.apk')
  )

  return {
    currentVersion,
    latestVersion,
    hasUpdate: compareVersions(latestVersion, currentVersion) > 0,
    notes: (data.body || '').trim(),
    releaseUrl: data.html_url || 'https://github.com/starhui70520/Nuwa/releases',
    apkUrl: apkAsset?.browser_download_url || null,
  }
}

type AppUpdateState = {
  modalUpdate: AppUpdateInfo | null
  checking: boolean
  downloading: boolean
  progress: number
  closeModal: () => void
  checkForUpdates: (options?: { silent?: boolean }) => Promise<void>
  installUpdate: () => Promise<void>
}

export const useAppUpdateStore = create<AppUpdateState>((set, get) => ({
  modalUpdate: null,
  checking: false,
  downloading: false,
  progress: 0,

  closeModal: () => {
    if (!get().downloading) {
      set({ modalUpdate: null, progress: 0 })
    }
  },

  checkForUpdates: async ({ silent = false } = {}) => {
    if (get().checking) {
      return
    }
    set({ checking: true })
    try {
      const info = await fetchLatestAppUpdate()
      if (info.hasUpdate) {
        set({ modalUpdate: info })
      } else if (!silent) {
        showToast({ key: 'updateAlreadyLatest' })
      }
    } catch {
      if (!silent) {
        showToast({ key: 'updateCheckFailed', type: 'error' })
      }
    } finally {
      set({ checking: false })
    }
  },

  installUpdate: async () => {
    const update = get().modalUpdate
    if (!update || get().downloading) {
      return
    }

    if (!isNativeAndroid() || !update.apkUrl) {
      window.open(update.apkUrl || update.releaseUrl, '_blank', 'noopener,noreferrer')
      set({ modalUpdate: null })
      return
    }

    set({ downloading: true, progress: 0 })
    const onProgress = (event: Event) => {
      const detail = (event as CustomEvent<{ progress?: number }>).detail
      if (typeof detail?.progress === 'number' && Number.isFinite(detail.progress)) {
        set({ progress: Math.max(0, Math.min(100, Math.round(detail.progress))) })
      }
    }
    window.addEventListener('dsapp:update-progress', onProgress)

    try {
      const result = await DeepSeekMigration.downloadAndInstallApk({ url: update.apkUrl })
      if (result.needsInstallPermission) {
        showToast({ key: 'updatePermissionRequired' })
      } else if (result.started) {
        showToast({ key: 'updateDownloadStarted' })
        set({ modalUpdate: null })
      }
    } catch {
      showToast({ key: 'updateDownloadFailed', type: 'error' })
    } finally {
      window.removeEventListener('dsapp:update-progress', onProgress)
      set({ downloading: false, progress: 0 })
    }
  },
}))

/** Android 端启动后按 12 小时节流静默检查更新 */
export const scheduleSilentAppUpdateCheck = (): void => {
  if (!isNativeAndroid()) {
    return
  }
  try {
    const raw = localStorage.getItem(LAST_AUTO_CHECK_KEY)
    const last = raw ? Number.parseInt(raw, 10) : 0
    const now = Date.now()
    if (Number.isFinite(last) && now - last < AUTO_CHECK_INTERVAL_MS) {
      return
    }
    localStorage.setItem(LAST_AUTO_CHECK_KEY, String(now))
  } catch {
    // 忽略存储受限
  }
  void useAppUpdateStore.getState().checkForUpdates({ silent: true })
}
