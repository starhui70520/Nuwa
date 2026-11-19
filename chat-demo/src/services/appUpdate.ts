import { create } from 'zustand'
import { showToast } from '../components/base/toastState.js'
import { DeepSeekMigration, isNativeAndroid } from './nativeBridge.js'

const PORTAL_BASE_URL = 'https://dl.rankchord.com'
const PORTAL_RELEASES_URL = `${PORTAL_BASE_URL}/api/releases`
const LAST_AUTO_CHECK_KEY = 'nuwa_last_update_check_at'
const CACHED_UPDATE_KEY = 'nuwa_cached_pending_update'
const DISMISSED_UPDATE_KEY = 'nuwa_dismissed_update_prompt'
/** 运行期间定时探查间隔：30 分钟 */
const POLL_INTERVAL_MS = 30 * 60 * 1000
/** 切回前台时节流间隔：10 分钟 */
const RESUME_THROTTLE_MS = 10 * 60 * 1000
/** 用户点击“稍后再说”后，同一版本的静默期：6 小时 */
const DISMISS_SNOOZE_MS = 6 * 60 * 60 * 1000

export type AppUpdateInfo = {
  currentVersion: string
  latestVersion: string
  hasUpdate: boolean
  notes: string
  releaseUrl: string
  apkUrl: string | null
}

export type ReleaseHistoryItem = {
  id: string
  version: string
  changelog: string
  createdAt: string
}

type PortalReleaseItem = {
  id?: string
  platform?: string
  version?: string
  changelog?: string
  createdAt?: string
  published?: boolean
}

type PortalReleasesResponse = {
  latest?: {
    android?: PortalReleaseItem | null
  }
  releases?: PortalReleaseItem[]
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

const fetchPortalReleases = async (): Promise<PortalReleasesResponse> => {
  const res = await fetch(PORTAL_RELEASES_URL, {
    headers: { Accept: 'application/json' },
    cache: 'no-store',
  })
  if (!res.ok) {
    throw new Error(`Portal releases API ${res.status}`)
  }
  return (await res.json()) as PortalReleasesResponse
}

/** 从官网 MinIO 发布服务查询最新版本 */
export const fetchLatestAppUpdate = async (): Promise<AppUpdateInfo> => {
  const currentVersion = normalizeVersion(await getCurrentAppVersion())
  const data = await fetchPortalReleases()
  const latest =
    data.latest?.android ??
    data.releases?.find((item) => item.platform === 'android' && item.published !== false) ??
    null

  if (!latest) {
    return {
      currentVersion,
      latestVersion: currentVersion,
      hasUpdate: false,
      notes: '',
      releaseUrl: PORTAL_BASE_URL,
      apkUrl: null,
    }
  }

  const latestVersion = normalizeVersion(latest.version || currentVersion)
  const apkUrl = latest.id
    ? `${PORTAL_BASE_URL}/api/releases/${encodeURIComponent(latest.id)}/download`
    : null

  return {
    currentVersion,
    latestVersion,
    hasUpdate: compareVersions(latestVersion, currentVersion) > 0,
    notes: (latest.changelog || '').trim(),
    releaseUrl: PORTAL_BASE_URL,
    apkUrl,
  }
}

/** 获取历史版本更新日志列表（按发布时间倒序） */
export const fetchReleaseHistory = async (): Promise<ReleaseHistoryItem[]> => {
  const data = await fetchPortalReleases()
  const list = (data.releases ?? []).filter(
    (item) => item.platform === 'android' && item.published !== false && item.version
  )
  return list.map((item, index) => ({
    id: item.id || `${item.version}-${index}`,
    version: normalizeVersion(item.version || ''),
    changelog: (item.changelog || '').trim(),
    createdAt: item.createdAt || '',
  }))
}

type AppUpdateState = {
  modalUpdate: AppUpdateInfo | null
  checking: boolean
  downloading: boolean
  progress: number
  closeModal: () => void
  checkForUpdates: (options?: { silent?: boolean; promptOnFound?: boolean }) => Promise<void>
  installUpdate: () => Promise<void>
}

const readCachedUpdate = (): AppUpdateInfo | null => {
  try {
    const raw = localStorage.getItem(CACHED_UPDATE_KEY)
    if (!raw) {
      return null
    }
    const parsed = JSON.parse(raw) as Partial<AppUpdateInfo>
    if (
      parsed &&
      typeof parsed.latestVersion === 'string' &&
      typeof parsed.currentVersion === 'string' &&
      parsed.hasUpdate
    ) {
      return {
        currentVersion: parsed.currentVersion,
        latestVersion: parsed.latestVersion,
        hasUpdate: true,
        notes: typeof parsed.notes === 'string' ? parsed.notes : '',
        releaseUrl: typeof parsed.releaseUrl === 'string' ? parsed.releaseUrl : PORTAL_BASE_URL,
        apkUrl: typeof parsed.apkUrl === 'string' ? parsed.apkUrl : null,
      }
    }
  } catch {
    // 忽略损坏缓存
  }
  return null
}

const writeCachedUpdate = (info: AppUpdateInfo | null): void => {
  try {
    if (info && info.hasUpdate) {
      localStorage.setItem(CACHED_UPDATE_KEY, JSON.stringify(info))
    } else {
      localStorage.removeItem(CACHED_UPDATE_KEY)
    }
  } catch {
    // 忽略存储受限
  }
}

const isVersionSnoozed = (version: string): boolean => {
  try {
    const raw = localStorage.getItem(DISMISSED_UPDATE_KEY)
    if (!raw) {
      return false
    }
    const parsed = JSON.parse(raw) as { version?: string; at?: number }
    if (
      parsed.version === normalizeVersion(version) &&
      typeof parsed.at === 'number' &&
      Date.now() - parsed.at < DISMISS_SNOOZE_MS
    ) {
      return true
    }
  } catch {
    // 忽略存储受限
  }
  return false
}

const markVersionDismissed = (version: string): void => {
  try {
    localStorage.setItem(
      DISMISSED_UPDATE_KEY,
      JSON.stringify({ version: normalizeVersion(version), at: Date.now() })
    )
  } catch {
    // 忽略存储受限
  }
}

export const useAppUpdateStore = create<AppUpdateState>((set, get) => ({
  modalUpdate: null,
  checking: false,
  downloading: false,
  progress: 0,

  closeModal: () => {
    const { downloading, modalUpdate } = get()
    if (!downloading) {
      if (modalUpdate) {
        markVersionDismissed(modalUpdate.latestVersion)
      }
      set({ modalUpdate: null, progress: 0 })
    }
  },

  checkForUpdates: async ({ silent = false, promptOnFound = true } = {}) => {
    if (get().checking) {
      return
    }
    set({ checking: true })
    try {
      const info = await fetchLatestAppUpdate()
      try {
        localStorage.setItem(LAST_AUTO_CHECK_KEY, String(Date.now()))
      } catch {
        // 忽略存储受限
      }
      if (info.hasUpdate) {
        writeCachedUpdate(info)
        const shouldPrompt =
          !silent || (promptOnFound && !isVersionSnoozed(info.latestVersion) && !get().modalUpdate)
        if (shouldPrompt) {
          set({ modalUpdate: info })
        }
      } else {
        writeCachedUpdate(null)
        if (!silent) {
          showToast({ key: 'updateAlreadyLatest' })
        }
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

/** 若本地已有探查到的新版本且未被静默忽略，进入应用时直接弹窗提示 */
const promptCachedUpdateIfNeeded = async (): Promise<void> => {
  const cached = readCachedUpdate()
  if (!cached || isVersionSnoozed(cached.latestVersion)) {
    return
  }
  const currentVersion = normalizeVersion(await getCurrentAppVersion())
  if (compareVersions(cached.latestVersion, currentVersion) <= 0) {
    writeCachedUpdate(null)
    return
  }
  const state = useAppUpdateStore.getState()
  if (!state.modalUpdate && !state.downloading) {
    useAppUpdateStore.setState({
      modalUpdate: { ...cached, currentVersion },
    })
  }
}

const getLastAutoCheckAt = (): number => {
  try {
    const raw = localStorage.getItem(LAST_AUTO_CHECK_KEY)
    const parsed = raw ? Number.parseInt(raw, 10) : 0
    return Number.isFinite(parsed) ? parsed : 0
  } catch {
    return 0
  }
}

/**
 * 启动应用更新定时探查与进入前台提示：
 * - 冷启动进入应用时：先展示已探查到的待更新版本，并立即静默拉取最新一次；
 * - 切回前台（native-resume / visibilitychange）时：若有待更新版本直接提示，距上次探查满 10 分钟则重新探查；
 * - 运行期间每 30 分钟后台静默探查一次并缓存，不打断当前对话，下次进入/切回应用时提示。
 */
export const startAppUpdateWatcher = (): (() => void) => {
  if (!isNativeAndroid()) {
    return () => {}
  }

  // 1. 冷启动进入应用：优先提示上次探查缓存的新版本，并立即做一次最新探查
  void promptCachedUpdateIfNeeded().then(() => {
    void useAppUpdateStore.getState().checkForUpdates({ silent: true, promptOnFound: true })
  })

  // 2. 切回应用前台时：有待更新则提示；距上次探查超过节流窗口则顺便探查
  const onEnterApp = () => {
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
      return
    }
    void promptCachedUpdateIfNeeded()
    if (Date.now() - getLastAutoCheckAt() >= RESUME_THROTTLE_MS) {
      void useAppUpdateStore.getState().checkForUpdates({ silent: true, promptOnFound: true })
    }
  }

  const onVisibilityChange = () => {
    if (document.visibilityState === 'visible') {
      onEnterApp()
    }
  }

  window.addEventListener('dsapp:native-resume', onEnterApp)
  document.addEventListener('visibilitychange', onVisibilityChange)

  // 3. 运行期间定时探查（30 分钟一次，仅缓存不打断当前操作，进入/切回应用时弹出提示）
  const timer = window.setInterval(() => {
    if (document.visibilityState === 'visible') {
      void useAppUpdateStore.getState().checkForUpdates({ silent: true, promptOnFound: false })
    }
  }, POLL_INTERVAL_MS)

  return () => {
    window.clearInterval(timer)
    window.removeEventListener('dsapp:native-resume', onEnterApp)
    document.removeEventListener('visibilitychange', onVisibilityChange)
  }
}
