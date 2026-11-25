import { formatDate } from '../../utils/format.js'
import { DeepSeekMigration, isNativeAndroid, isNativeIos } from '../nativeBridge.js'
import { useSettings } from '../settings.js'
import * as db from './db.js'
import { mergeHistory, replaceHistory, setImportProgress, useChatStore } from './store.js'
import type { Session } from './types.js'

export { BackupError } from './history/errors.js'

// 导入、导出与全部删除串行处理，避免读取归档时数据被清空或两个替换事务交错。
let backupQueue: Promise<unknown> = Promise.resolve()

const enqueueBackup = <T>(run: () => Promise<T>): Promise<T> => {
  const task = backupQueue.then(run)
  backupQueue = task.catch(() => {})
  return task
}

const backupFileName = (date: Date) => `deepseek_data-${formatDate(date)}.zip`

const sanitizeExportTitle = (title: string): string => {
  const cleaned = title
    .replace(/[\\/:*?"<>|\r\n\t]+/g, ' ')
    .trim()
    .replace(/\s+/g, '_')
    .slice(0, 32)
  return cleaned || 'session'
}

/** 导出单个会话及其图片为标准 ZIP 归档，可再次导入到任意端。 */
export const exportSession = (sessionId: string): Promise<{ name: string; blob: Blob }> =>
  enqueueBackup(async () => {
    const { sessions, sessionCache } = useChatStore.getState()
    const summary = sessions.find((s) => s.id === sessionId)
    const loaded = Object.hasOwn(sessionCache, sessionId)
      ? sessionCache[sessionId]
      : await db.loadSession(sessionId)
    if (!loaded) {
      throw new Error(`History session not found during export: ${sessionId}`)
    }
    const merged: Session = summary ? { ...loaded, ...summary } : loaded
    async function* readSingle(): AsyncGenerator<Session> {
      yield merged
    }
    const { exportArchive } = await import('./history/exportArchive.js')
    const now = new Date()
    const blob = await exportArchive(readSingle())
    const safeTitle = sanitizeExportTitle(merged.title)
    return { name: `nuwa-${safeTitle}-${formatDate(now)}.zip`, blob }
  })

export type ExportDestination = 'share' | 'save'

/** 跨端保存或分享导出的 ZIP 文件（Android 支持系统分享 / 写入 Download/Nuwa，iOS 支持系统分享 / 文件保存，Web 支持分享或下载）。 */
export const saveExportArchive = async (
  name: string,
  blob: Blob,
  mode: ExportDestination = 'save'
): Promise<{ savedPath?: string }> => {
  if (isNativeIos() || isNativeAndroid()) {
    const res = await DeepSeekMigration.saveFileToDocuments({
      name,
      data: await blobToBase64(blob),
      mode,
    })
    return { savedPath: res?.savedPath }
  }
  if (mode === 'share' && typeof navigator !== 'undefined' && typeof navigator.share === 'function') {
    const file = new File([blob], name, { type: 'application/zip' })
    if (typeof navigator.canShare !== 'function' || navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file], title: name })
      return {}
    }
  }
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = name
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
  return {}
}

/** 导出为历史会话导出格式的 ZIP，可再次导入。 */
export const exportHistory = (): Promise<{ name: string; blob: Blob }> =>
  enqueueBackup(async () => {
    // 列表和已加载内容保留导出开始时的快照；未打开的会话逐条读取，不填满详情缓存。
    const { sessions, sessionCache } = useChatStore.getState()
    async function* readSessions(): AsyncGenerator<Session> {
      for (const summary of sessions) {
        const session = Object.hasOwn(sessionCache, summary.id)
          ? sessionCache[summary.id]
          : await db.loadSession(summary.id)
        if (!session) {
          throw new Error(`History session disappeared during export: ${summary.id}`)
        }
        // 详情读取期间可能重命名，归档标题与开始时的列表保持一致。
        yield { ...session, ...summary }
      }
    }
    const { exportArchive } = await import('./history/exportArchive.js')
    const now = new Date()
    const blob = await exportArchive(readSessions())
    return { name: backupFileName(now), blob }
  })

let importRunning = false

/**
 * 增量合并导入：先检查 ZIP 格式与版本，校验失败时保留正在生成的回答；
 * 通过后从 ZIP 流式写入暂存，成功按 ID 合并进本地会话与图片原件。返回本次导入的会话数。
 * 已有导入进行中时直接拒绝重复排队，避免误操作连续触发两次导入。
 */
export const importHistory = (file: File): Promise<number> => {
  if (importRunning || useChatStore.getState().importingHistory) {
    return Promise.reject(new Error('History import is already in progress'))
  }
  importRunning = true
  return enqueueBackup(async () => {
    try {
      const { checkArchiveFormat, importArchive } = await import('./history/importArchive.js')
      await checkArchiveFormat(file)
      return await mergeHistory(() =>
        importArchive(file, (progress) =>
          setImportProgress({ phase: 'reading', sessions: progress.sessions, images: progress.images })
        )
      )
    } finally {
      importRunning = false
    }
  })
}

/** 供桌面端 Tauri / 移动端 Capacitor / 浏览器插件直接传入 ZIP 字节流完成导入 */
export const importHistoryFromBytes = (
  data: Uint8Array | ArrayBuffer,
  name = 'deepseek_data.zip'
): Promise<number> => {
  const part: BlobPart =
    data instanceof Uint8Array
      ? data.byteOffset === 0 &&
        data.byteLength === data.buffer.byteLength &&
        data.buffer instanceof ArrayBuffer
        ? data.buffer
        : data.slice()
      : data
  return importHistory(new File([part], name, { type: 'application/zip' }))
}

/** 确认删除后调用：以空历史原子替换全部本地会话与附件，保留 API Key 和其他设置。 */
export const clearHistory = (): Promise<void> =>
  enqueueBackup(async () => {
    await replaceHistory(async () => {})
  })

const ICLOUD_BACKUP_NAME = 'deepseek_data-latest.zip'
let lastIcloudBackupAt = 0

const blobToBase64 = async (blob: Blob): Promise<string> => {
  const bytes = new Uint8Array(await blob.arrayBuffer())
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}

/**
 * iCloud 自动备份（iOS）：开启后每次进入应用且距上次超过 1 小时，把最新快照
 * 覆盖写入 ubiquity container（iCloud Drive Documents 目录，随系统自动同步到云端）。
 * 未开通 iCloud entitlement 时静默跳过。
 */
export const maybeAutoBackupToIcloud = async (): Promise<void> => {
  if (!isNativeIos() || !useSettings.getState().icloudAutoBackup) {
    return
  }
  const now = Date.now()
  if (now - lastIcloudBackupAt < 60 * 60 * 1000) {
    return
  }
  try {
    const { available } = await DeepSeekMigration.icloudStatus()
    if (!available) {
      return
    }
    lastIcloudBackupAt = now
    const { blob } = await exportHistory()
    await DeepSeekMigration.icloudBackupNow({
      name: ICLOUD_BACKUP_NAME,
      data: await blobToBase64(blob),
    })
  } catch {
    // 自动备份失败不打扰用户；下次进入应用重试
  }
}
