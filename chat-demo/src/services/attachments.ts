import { create } from 'zustand'
import type { LinkedMessage, TranslationMessage } from '../i18n/index.js'
import { ApiError, uploadFile } from './api/client.js'
import { classifyApiError, getUploadErrorInfo, isRetryableApiError } from './api/errors.js'
import type { FilePurpose } from './api/types.js'
import { recordAppLog } from './errorLog.js'
import { ACCEPT_FILE_EXTS } from './uploadExts.js'

/** 允许上传的扩展名，按扩展名白名单过滤，清单见 uploadExts.ts */
export const ACCEPTED_EXTS = ACCEPT_FILE_EXTS
/** 选择文件对话框的过滤条件 */
export const ACCEPT = ACCEPTED_EXTS.map((ext) => `.${ext}`).join(',')
/** 单文件大小上限与 Files API 一致 */
export const MAX_SIZE_MB = 64
/** 按 user_data 上传的文件（纯文本、代码、表格、电子书）原文件上限更小 */
export const MAX_USER_DATA_SIZE_MB = 32
export const MAX_COUNT = 50
/** 同时上传的文件数 */
const MAX_CONCURRENT = 3

/** 文件扩展名（小写，不含点）；没有扩展名时为空 */
export const getFileExt = (name: string) => {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

export const isAcceptedExt = (name: string) => ACCEPTED_EXTS.includes(getFileExt(name))

/** 需要服务端做版面解析的文档；其余非图片文件（纯文本、代码、表格、电子书）无需解析 */
const LAYOUT_RECOGNITION_EXTS = new Set(['pdf', 'doc', 'docx', 'ppt', 'pptx'])

/** 上传时的 purpose：图片不传，PDF 与 Word、PPT 做版面解析，其余按 user_data 上传 */
export const getUploadPurpose = (name: string, isImage: boolean): FilePurpose | null => {
  if (isImage) {
    return null
  }
  return LAYOUT_RECOGNITION_EXTS.has(getFileExt(name)) ? 'rich_layout_recognition' : 'user_data'
}

/** 文件允许的最大体积（MB），按上传时的 purpose 区分 */
const getMaxSizeMB = (file: File) =>
  getUploadPurpose(file.name, isImage(resolveMimeType(file))) === 'user_data'
    ? MAX_USER_DATA_SIZE_MB
    : MAX_SIZE_MB

/** 添加前校验：格式 → 大小 → 数量，任一不满足即整批不添加 */
export const validateFiles = (files: File[], currentCount: number): TranslationMessage | null => {
  if (files.some((file) => !isAcceptedExt(file.name))) {
    return { key: 'uploadUnsupportedFormat' }
  }
  const oversized = files.find((file) => file.size > getMaxSizeMB(file) * 1024 * 1024)
  if (oversized) {
    return { key: 'uploadMaxMBSize', params: { size: getMaxSizeMB(oversized) } }
  }
  if (currentCount + files.length > MAX_COUNT) {
    return { key: 'uploadMaxFiles', params: { count: MAX_COUNT } }
  }
  return null
}

/**
 * 上传失败在附件上显示的文案：与设计稿状态对应的用具体原因，其余统一「上传失败」。
 * 服务端原文多为英文且较长，不直接展示。
 */
export const describeUploadError = (error: unknown): TranslationMessage => {
  if (classifyApiError(error) === 'serverBusy') {
    return { key: 'uploadServerBusy' }
  }
  if (getUploadErrorInfo(error)?.code === 'parseFailed') {
    return { key: 'uploadParseFailed' }
  }
  return { key: 'uploadFileStatusFailed' }
}

const sanitizeUploadDetail = (raw: string): string =>
  raw
    .replace(/sk-[a-zA-Z0-9_-]{8,}/g, 'sk-***')
    .replace(/Bearer\s+[a-zA-Z0-9._-]{8,}/gi, 'Bearer ***')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 200)

/**
 * 回复提示与草稿 toast 使用的详细上传错误文案：
 * 保留配额上限、401/402/413/429/5xx、网络异常以及其他 HTTP 状态码与服务端精简原文，不再全部折叠为「上传失败」。
 */
export const describeUploadFailure = (error: unknown): TranslationMessage => {
  const info = getUploadErrorInfo(error)
  if (info?.code === 'fileCountLimit') {
    return { key: 'uploadFileCountLimitReply', params: { limit: info.limit ?? '' } }
  }
  if (info?.code === 'storageLimit') {
    return { key: 'uploadStorageLimitReply', params: { limit: info.limit ?? '' } }
  }
  if (info?.code === 'parseFailed') {
    return { key: 'uploadParseFailedDetail' }
  }
  const condition = classifyApiError(error)
  if (condition === 'unauthorized') {
    return { key: 'replyInvalidApiKey' }
  }
  if (condition === 'insufficientBalance') {
    return { key: 'replyInsufficientBalance' }
  }
  if (condition === 'tooLarge') {
    return { key: 'uploadTooLargeDetail' }
  }
  if (condition === 'rateLimited') {
    return { key: 'uploadRateLimitedDetail' }
  }
  if (condition === 'serverBusy') {
    const status = error instanceof ApiError && error.status ? String(error.status) : '500'
    return { key: 'uploadServerBusyDetail', params: { status } }
  }
  if (condition === 'network') {
    return { key: 'uploadNetworkErrorDetail' }
  }
  if (error instanceof ApiError && error.status !== undefined) {
    const detail = sanitizeUploadDetail(error.message)
    return detail
      ? { key: 'uploadFailedWithStatus', params: { status: String(error.status), detail } }
      : { key: 'uploadFailedWithStatusOnly', params: { status: String(error.status) } }
  }
  if (error instanceof Error) {
    const detail = sanitizeUploadDetail(error.message)
    if (detail) {
      return { key: 'uploadFailedWithDetail', params: { detail } }
    }
  }
  return { key: 'uploadFileStatusFailed' }
}

type NoticeListener = (notice: LinkedMessage) => void
const noticeListeners = new Set<NoticeListener>()

/** 订阅需要额外提示的上传失败（配额达到上限），由界面层转成 toast */
export const onUploadNotice = (listener: NoticeListener) => {
  noticeListeners.add(listener)
  return () => {
    noticeListeners.delete(listener)
  }
}

/** 删除已上传文件的接口文档 */
const DELETE_FILE_DOCS_URL = 'https://api-docs.deepseek.com/api/delete-file'

/** 文件数或存储空间达到上限：附件上只放得下「上传失败」，原因另用 toast 说明并引导删除旧文件 */
export const describeUploadQuota = (error: unknown): LinkedMessage | undefined => {
  const info = getUploadErrorInfo(error)
  const link = { key: 'uploadDeleteFiles', href: DELETE_FILE_DOCS_URL } as const
  if (info?.code === 'fileCountLimit') {
    return { type: 'error', key: 'uploadFileCountLimit', params: { limit: info.limit ?? '' }, link }
  }
  if (info?.code === 'storageLimit') {
    return { type: 'error', key: 'uploadStorageLimit', params: { limit: info.limit ?? '' }, link }
  }
  return undefined
}

type Job = () => Promise<void>
const queue: Job[] = []
let running = 0

const next = () => {
  while (running < MAX_CONCURRENT) {
    const job = queue.shift()
    if (!job) {
      return
    }
    running++
    void job().finally(() => {
      running--
      next()
    })
  }
}

/** DeepSeek Messages API 原生稳定支持的图片格式 */
const API_SUPPORTED_IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/gif', 'image/webp'])

const sniffApiSupportedImageMime = async (blob: Blob): Promise<string | null> => {
  try {
    const bytes = new Uint8Array(await blob.slice(0, 16).arrayBuffer())
    if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
      return 'image/jpeg'
    }
    if (
      bytes.length >= 8 &&
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
    const header = new TextDecoder('ascii').decode(bytes.subarray(0, 12))
    if (header.startsWith('GIF87a') || header.startsWith('GIF89a')) {
      return 'image/gif'
    }
    if (header.startsWith('RIFF') && header.slice(8, 12) === 'WEBP') {
      return 'image/webp'
    }
  } catch {
    // 忽略读取异常
  }
  return null
}

const replaceExtension = (name: string, ext: string) => {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? `${name.slice(0, dot)}.${ext}` : `${name}.${ext}`
}

/** 服务端视觉模型单边最大像素上限 */
const MAX_IMAGE_DIMENSION = 4096

/**
 * 上传前规范化图片：
 * - BMP / AVIF / HEIC 等非标准格式经 Canvas 转为 JPEG；
 * - 任意宽或高超过 4096px 的长图（如手机长截图）等比缩放至 4096px 以内，避免服务端报 too large to process；
 * - 标准格式且尺寸合规的图片原样上传，无损保留。
 */
const normalizeImageForUpload = async (file: Blob, name: string): Promise<File> => {
  const sniffed = await sniffApiSupportedImageMime(file)
  const formatSupported = Boolean(sniffed && API_SUPPORTED_IMAGE_TYPES.has(sniffed))
  const fallbackFile = () =>
    file instanceof File && (!sniffed || file.type === sniffed)
      ? file
      : new File([file], name, { type: sniffed || file.type })

  if (typeof document === 'undefined' || typeof URL === 'undefined') {
    return fallbackFile()
  }
  const objectUrl = URL.createObjectURL(file)
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image()
      el.onload = () => resolve(el)
      el.onerror = () => reject(new Error('Image decode failed'))
      el.src = objectUrl
    })
    const width = img.naturalWidth || img.width
    const height = img.naturalHeight || img.height
    if (!width || !height) {
      return fallbackFile()
    }
    const needsResize = width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION
    if (formatSupported && !needsResize) {
      return fallbackFile()
    }
    const scale = needsResize ? MAX_IMAGE_DIMENSION / Math.max(width, height) : 1
    const targetW = Math.max(1, Math.floor(width * scale))
    const targetH = Math.max(1, Math.floor(height * scale))
    const canvas = document.createElement('canvas')
    canvas.width = targetW
    canvas.height = targetH
    const ctx = canvas.getContext('2d')
    if (!ctx) {
      return fallbackFile()
    }
    ctx.drawImage(img, 0, 0, targetW, targetH)
    const converted = await new Promise<Blob | null>((resolve) => {
      canvas.toBlob(resolve, 'image/jpeg', 0.92)
    })
    if (converted && converted.size > 0) {
      return new File([converted], replaceExtension(name, 'jpg'), { type: 'image/jpeg' })
    }
  } catch {
    // 浏览器无法解码时原样回退，由请求层兜底处理
  } finally {
    URL.revokeObjectURL(objectUrl)
  }
  return fallbackFile()
}

/** 排队上传，最多同时上传 MAX_CONCURRENT 个；排队期间中止的任务不会发出请求 */
const enqueueUpload = (
  apiKey: string,
  file: Blob,
  name: string,
  isImage: boolean,
  signal: AbortSignal
) =>
  new Promise<string>((resolve, reject) => {
    queue.push(async () => {
      if (signal.aborted) {
        reject(signal.reason)
        return
      }
      try {
        const body = isImage
          ? await normalizeImageForUpload(file, name)
          : file instanceof File
            ? file
            : new File([file], name, { type: file.type })
        resolve((await uploadFile(apiKey, body, getUploadPurpose(body.name, isImage), signal)).id)
      } catch (error) {
        reject(error)
      }
    })
    next()
  })

/**
 * 上传任务按附件的本地 id 登记：输入框选中即开始上传，全部成功后携带 serverId 发送，
 * 不会重复上传；导入的历史附件没有任务，发送前按本地原件补传。
 * 任务只在内存里，历史附件补传未完成时，刷新后会在下次请求前重新上传。
 */
export type UploadTask =
  | { status: 'uploading' }
  | { status: 'done'; serverId: string }
  | { status: 'error'; error: TranslationMessage; retryable: boolean }

type UploadState = { tasks: Record<string, UploadTask> }

export const useUploads = create<UploadState>(() => ({ tasks: {} }))

const setTask = (id: string, task: UploadTask | null) =>
  useUploads.setState((state) => ({
    tasks: task
      ? { ...state.tasks, [id]: task }
      : Object.fromEntries(Object.entries(state.tasks).filter(([key]) => key !== id)),
  }))

const pending = new Map<string, { promise: Promise<string>; controller: AbortController }>()

/** 开始（或复用进行中的）上传，返回服务端 file_id；失败时任务记为 error 并抛出原错误 */
export const uploadAttachment = (
  apiKey: string,
  id: string,
  blob: Blob,
  name: string,
  isImage: boolean
): Promise<string> => {
  const current = pending.get(id)
  if (current) {
    return current.promise
  }
  const controller = new AbortController()
  setTask(id, { status: 'uploading' })
  const promise = enqueueUpload(apiKey, blob, name, isImage, controller.signal)
    .then((serverId) => {
      setTask(id, { status: 'done', serverId })
      return serverId
    })
    .catch((error: unknown) => {
      if (controller.signal.aborted) {
        setTask(id, null)
      } else {
        if (!(error instanceof ApiError)) {
          const msg = error instanceof Error ? `${error.name}: ${error.message}` : String(error)
          recordAppLog('error', 'attachment.upload', `Upload failed (${name})`, msg)
        }
        setTask(id, {
          status: 'error',
          error: describeUploadError(error),
          retryable: isRetryableApiError(error),
        })
        const notice = describeUploadQuota(error)
        if (notice) {
          for (const listener of noticeListeners) {
            listener(notice)
          }
        }
      }
      throw error
    })
    .finally(() => pending.delete(id))
  pending.set(id, { promise, controller })
  return promise
}

export const cancelUpload = (id: string) => {
  pending.get(id)?.controller.abort()
  setTask(id, null)
}

/** 各扩展名对应的 MIME：部分系统（如 Windows）给不出 file.type，按扩展名补齐 */
const MIME_BY_EXT: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
}

/** 取文件的 MIME：优先用浏览器给出的类型，缺失时按扩展名推断 */
export const resolveMimeType = (file: File) => file.type || MIME_BY_EXT[getFileExt(file.name)] || ''

export const isImage = (mimeType: string) => mimeType.startsWith('image/')

/** 文件扩展名（大写），用于卡片元信息 */
export const getExtension = (name: string) => {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toUpperCase() : ''
}

export const formatSize = (bytes: number) => {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  const units = ['KB', 'MB', 'GB']
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`
}
