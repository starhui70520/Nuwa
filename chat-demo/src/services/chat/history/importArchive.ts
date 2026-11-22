import { isLowPerfDevice } from '../../../app/devicePerf.js'
import * as db from '../db.js'
import { BackupError, fail } from './errors.js'
import type { SessionIndexEntry } from './format.js'
import { INDEX_PATH, MANIFEST_PATH, USER_PATH, parseSessionPath, sessionFilesDir } from './paths.js'
import { checkManifest, readSessionFile, readSessionIndex } from './schema.js'
import { toLocalSession } from './toLocal.js'
import {
  ArchiveError,
  isZipFile,
  readArchive,
  readEntry,
  readEntryText,
  skipEntry,
  type ArchiveEntry,
} from './zipReader.js'

/** 从原件前 16 字节补充图片 MIME（零对象分配）；无法识别时为空字符串，图片身份仍由归档的 is_image 决定。 */
const imageType = (bytes: Uint8Array): string => {
  const len = bytes.length
  if (len >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg'
  }
  if (
    len >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return 'image/png'
  }
  if (
    len >= 6 &&
    bytes[0] === 0x47 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x38 &&
    (bytes[4] === 0x37 || bytes[4] === 0x39) &&
    bytes[5] === 0x61
  ) {
    return 'image/gif'
  }
  if (
    len >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return 'image/webp'
  }
  if (len >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
    return 'image/bmp'
  }
  if (
    len >= 4 &&
    ((bytes[0] === 0x49 && bytes[1] === 0x49 && bytes[2] === 0x2a && bytes[3] === 0x00) ||
      (bytes[0] === 0x4d && bytes[1] === 0x4d && bytes[2] === 0x00 && bytes[3] === 0x2a))
  ) {
    return 'image/tiff'
  }
  if (
    len >= 12 &&
    bytes[4] === 0x66 &&
    bytes[5] === 0x74 &&
    bytes[6] === 0x79 &&
    bytes[7] === 0x70 &&
    bytes[8] === 0x61 &&
    bytes[9] === 0x76 &&
    bytes[10] === 0x69 &&
    (bytes[11] === 0x66 || bytes[11] === 0x73)
  ) {
    return 'image/avif'
  }
  return ''
}

const readJson = async (entry: ArchiveEntry): Promise<unknown> => {
  const text = await readEntryText(entry)
  try {
    return JSON.parse(text)
  } catch {
    return fail('backupInvalidJson')
  }
}

const SESSION_FILES_DIR_PATTERN = /^chat_sessions\/([^/]+)_files\//

/**
 * 检查 ZIP 格式、首个 manifest 条目及格式版本。
 * 校验失败时保留正在生成的回答和现有暂存数据。
 */
export const checkArchiveFormat = async (file: File): Promise<void> => {
  if (!(await isZipFile(file))) {
    fail('backupUnrecognized')
  }
  try {
    for await (const entry of readArchive(file)) {
      if (entry.path !== MANIFEST_PATH) {
        fail('backupUnrecognized')
      }
      checkManifest(await readJson(entry))
      return
    }
  } catch (error) {
    throw error instanceof ArchiveError ? new BackupError('backupIncomplete') : error
  }
  fail('backupUnrecognized')
}

/**
 * 流式导入：manifest → user（不导入）→ 全部会话 JSON → index → 全部图片。
 * 也支持会话与图片交错排列、index 位于末尾的条目顺序。
 * 会话读完立即暂存，只保留图片路径映射；图片全部读完后仅对含图片会话回填 MIME，不改变图片身份。
 * 写入导入暂存存储；调用方负责先清空暂存，成功后替换正式数据，失败时清理暂存。
 */
export const importArchive = async (
  file: File,
  onProgress?: (progress: { sessions: number; images: number }) => void
): Promise<void> => {
  if (!(await isZipFile(file))) {
    fail('backupUnrecognized')
  }
  const lowPerf = isLowPerfDevice()
  const imported = new Set<string>()
  const sessionsWithImages = new Set<string>()
  const images = new Map<string, string>()
  /** 已保存的原件：文件 ID → MIME。同一图片出现在多个会话目录时只保存一次。 */
  const stored = new Map<string, string>()
  let manifest = false
  let index: SessionIndexEntry[] | undefined
  let currentSessionId: string | undefined
  let currentSessionDir = ''
  const stagingBatch: Awaited<ReturnType<typeof toLocalSession>>['session'][] = []
  const STAGING_BATCH_SIZE = lowPerf ? 12 : 24
  const imageBatch: db.StoredFile[] = []
  let imageBatchBytes = 0
  const IMAGE_BATCH_COUNT = lowPerf ? 8 : 16
  const IMAGE_BATCH_BYTES = lowPerf ? 3 * 1024 * 1024 : 8 * 1024 * 1024
  let lastProgressAt = 0

  const emitProgress = (force = false) => {
    if (!onProgress) {
      return
    }
    const now = Date.now()
    if (force || now - lastProgressAt >= 100) {
      lastProgressAt = now
      onProgress({ sessions: imported.size, images: stored.size })
    }
  }

  const flushSessions = async () => {
    if (stagingBatch.length === 0) {
      return
    }
    const batch = stagingBatch.splice(0, stagingBatch.length)
    await db.addStagingSessions(batch)
    emitProgress()
  }

  const flushImages = async () => {
    if (imageBatch.length === 0) {
      return
    }
    const batch = imageBatch.splice(0, imageBatch.length)
    imageBatchBytes = 0
    await db.saveStagingFiles(batch)
    emitProgress()
  }

  const saveImage = async (entry: ArchiveEntry, id: string) => {
    if (stored.has(id)) {
      await skipEntry(entry)
      return
    }
    let detectedType = ''
    const blob = await readEntry(entry, (head) => {
      detectedType = imageType(head)
      return detectedType
    })
    stored.set(id, detectedType)
    imageBatch.push({ id, blob })
    imageBatchBytes += entry.size
    if (imageBatch.length >= IMAGE_BATCH_COUNT || imageBatchBytes >= IMAGE_BATCH_BYTES) {
      await flushImages()
    } else {
      emitProgress()
    }
  }

  try {
    for await (const entry of readArchive(file)) {
      const { path } = entry
      const sessionId = parseSessionPath(path)
      if (!manifest) {
        if (path !== MANIFEST_PATH) {
          fail('backupUnrecognized')
        }
        checkManifest(await readJson(entry))
        manifest = true
      } else if (path === USER_PATH && !index && imported.size === 0) {
        // 账号信息（已脱敏）不导入；文件可能缺失。
        await skipEntry(entry)
      } else if (path === 'yejian_meta.json' || path.startsWith('yejian/')) {
        // 兼容第三方衍生客户端（如夜笺）附带的扩展元数据/配置条目，导入时跳过。
        await skipEntry(entry)
      } else if (sessionId !== null && !index) {
        const local = toLocalSession(readSessionFile(await readJson(entry)))
        if (local.session.id !== sessionId || imported.has(sessionId)) {
          fail('backupIncomplete')
        }
        imported.add(sessionId)
        currentSessionId = sessionId
        currentSessionDir = sessionFilesDir(sessionId)
        if (local.images.size > 0) {
          sessionsWithImages.add(sessionId)
          for (const [imagePath, id] of local.images) {
            images.set(imagePath, id)
          }
        }
        stagingBatch.push(local.session)
        if (stagingBatch.length >= STAGING_BATCH_SIZE) {
          await flushSessions()
        }
      } else if (path === INDEX_PATH && !index) {
        await flushSessions()
        index = readSessionIndex(await readJson(entry))
      } else if (
        index
          ? imported.has(SESSION_FILES_DIR_PATTERN.exec(path)?.[1] ?? '')
          : currentSessionId !== undefined && path.startsWith(currentSessionDir)
      ) {
        await flushSessions()
        // 没有被引用的条目不保存，引用了但缺失的图片只展示文件名。
        const id = images.get(path)
        await (id === undefined ? skipEntry(entry) : saveImage(entry, id))
      } else {
        fail('backupIncomplete')
      }
    }
    await flushSessions()
    await flushImages()
    emitProgress(true)
  } catch (error) {
    throw error instanceof ArchiveError ? new BackupError('backupIncomplete') : error
  }
  if (!manifest) {
    fail('backupUnrecognized')
  }
  // index 只列出成功写出的会话，与会话文件一一对应。
  const listed = new Set<string>()
  if (index) {
    for (let i = 0; i < index.length; i++) {
      listed.add(index[i].id)
    }
  }
  let missingInIndex = false
  for (const id of imported) {
    if (!listed.has(id)) {
      missingInIndex = true
      break
    }
  }
  if (!index || listed.size !== index.length || listed.size !== imported.size || missingInIndex) {
    fail('backupIncomplete')
  }
  await db.updateStagingFileTypes(stored, sessionsWithImages)
}
