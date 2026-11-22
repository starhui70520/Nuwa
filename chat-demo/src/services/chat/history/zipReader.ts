import { Inflate } from 'fflate'
import { isLowPerfDevice, yieldToMain } from '../../../app/devicePerf.js'

const READ_CHUNK_BYTES = 256 * 1024
// 低性能设备用较小解压步进降低单帧延迟，常规设备放大步进减少生成器调度开销。
const LOW_PERF_INFLATE_CHUNK_BYTES = 8 * 1024
const NORMAL_INFLATE_CHUNK_BYTES = 16 * 1024
const LOCAL_HEADER_PREFETCH_EXTRA = 64
// 图片拼装成 Blob 时的合并分片上限：既将 JS 堆峰值锁在 256KB 内，又把 Blob 句柄数降低 32 倍。
const BLOB_COALESCE_BYTES = 256 * 1024

/** ZIP 结构损坏或使用了不支持的特性 */
export class ArchiveError extends Error {
  constructor() {
    super('Invalid or unsupported history archive')
    this.name = 'ArchiveError'
  }
}

const invalid = (): never => {
  throw new ArchiveError()
}

/** 本地文件头签名 PK\x03\x04，用于在解析前区分 ZIP 与其他文件。 */
export const isZipFile = async (file: File) => {
  const bytes = new Uint8Array(await file.slice(0, 4).arrayBuffer())
  return (
    bytes.length === 4 &&
    bytes[0] === 0x50 &&
    bytes[1] === 0x4b &&
    bytes[2] === 0x03 &&
    bytes[3] === 0x04
  )
}

const viewOf = (bytes: Uint8Array) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

// Slice-by-4 CRC32 查表：4KB 常量表换取约 3-4 倍校验吞吐提升，结果与逐字节 IEEE 802.3 完全一致。
const crcTable0 = new Uint32Array(256)
const crcTable1 = new Uint32Array(256)
const crcTable2 = new Uint32Array(256)
const crcTable3 = new Uint32Array(256)
for (let i = 0; i < 256; i++) {
  let c = i
  for (let bit = 0; bit < 8; bit++) {
    c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0)
  }
  crcTable0[i] = c >>> 0
}
for (let i = 0; i < 256; i++) {
  const t1 = (crcTable0[i] >>> 8) ^ crcTable0[crcTable0[i] & 0xff]
  const t2 = (t1 >>> 8) ^ crcTable0[t1 & 0xff]
  const t3 = (t2 >>> 8) ^ crcTable0[t2 & 0xff]
  crcTable1[i] = t1 >>> 0
  crcTable2[i] = t2 >>> 0
  crcTable3[i] = t3 >>> 0
}

const updateCrc32 = (crc: number, chunk: Uint8Array): number => {
  let c = crc
  let i = 0
  const end4 = chunk.length - 3
  while (i < end4) {
    c ^= chunk[i] | (chunk[i + 1] << 8) | (chunk[i + 2] << 16) | (chunk[i + 3] << 24)
    c =
      crcTable3[c & 0xff] ^
      crcTable2[(c >>> 8) & 0xff] ^
      crcTable1[(c >>> 16) & 0xff] ^
      crcTable0[c >>> 24]
    i += 4
  }
  while (i < chunk.length) {
    c = (c >>> 8) ^ crcTable0[(c ^ chunk[i++]) & 0xff]
  }
  return c
}

const utf8FatalDecoder = new TextDecoder('utf-8', { fatal: true })

const readBytes = async (file: File, start: number, length: number) => {
  if (start < 0 || length < 0 || start + length > file.size) {
    invalid()
  }
  if (length === 0) {
    return new Uint8Array(0)
  }
  const bytes = new Uint8Array(await file.slice(start, start + length).arrayBuffer())
  if (bytes.length !== length) {
    invalid()
  }
  return bytes
}

/** ZIP64、分卷与加密文件不属于导出格式，一律拒绝。 */
const checkExtra = (bytes: Uint8Array) => {
  if (bytes.length === 0) {
    return
  }
  const view = viewOf(bytes)
  let offset = 0
  while (offset < bytes.length) {
    if (offset + 4 > bytes.length || view.getUint16(offset, true) === 1) {
      invalid()
    }
    offset += 4 + view.getUint16(offset + 2, true)
    if (offset > bytes.length) {
      invalid()
    }
  }
}

const decodePath = (bytes: Uint8Array, flags: number) => {
  // 非 UTF-8 编码的 ZIP 文件名仅接受 ASCII，确保附件路径解码准确。
  if (!(flags & 0x800)) {
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] > 0x7f) {
        invalid()
      }
    }
  }
  let path: string
  try {
    path = utf8FatalDecoder.decode(bytes).normalize('NFC')
  } catch {
    return invalid()
  }
  if (!path || path.includes('\\') || path.includes('\0') || /^[A-Za-z]:/.test(path)) {
    invalid()
  }
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path
  const parts = trimmed.split('/')
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i]
    if (!part || part === '.' || part === '..') {
      invalid()
    }
  }
  return path
}

type Entry = {
  path: string
  name: Uint8Array
  flags: number
  method: number
  crc: number
  compressedSize: number
  size: number
  offset: number
}

const readDirectory = async (file: File): Promise<{ entries: Entry[]; offset: number }> => {
  if (file.size < 22) {
    invalid()
  }
  const tailStart = Math.max(0, file.size - 22 - 0xffff)
  const tail = await readBytes(file, tailStart, file.size - tailStart)
  const tailView = viewOf(tail)
  let end = tail.length - 22
  while (
    end >= 0 &&
    (tailView.getUint32(end, true) !== 0x06054b50 ||
      end + 22 + tailView.getUint16(end + 20, true) !== tail.length)
  ) {
    end--
  }
  if (end < 0) {
    invalid()
  }
  const count = tailView.getUint16(end + 10, true)
  const size = tailView.getUint32(end + 12, true)
  const offset = tailView.getUint32(end + 16, true)
  if (
    tailView.getUint16(end + 4, true) !== 0 ||
    tailView.getUint16(end + 6, true) !== 0 ||
    tailView.getUint16(end + 8, true) !== count ||
    count === 0xffff ||
    size === 0xffffffff ||
    offset === 0xffffffff ||
    offset + size !== tailStart + end
  ) {
    invalid()
  }
  // 256KB 窗口顺序缓冲读取 Central Directory，把数千次 WebView ContentResolver IPC 降为个位数。
  let bufStart = 0
  let buf = new Uint8Array(0)
  const readDirSlice = async (relOffset: number, length: number): Promise<Uint8Array> => {
    if (length === 0) {
      return new Uint8Array(0)
    }
    if (relOffset < bufStart || relOffset + length > bufStart + buf.length) {
      const readLen = Math.min(size - relOffset, Math.max(READ_CHUNK_BYTES, length))
      buf = await readBytes(file, offset + relOffset, readLen)
      bufStart = relOffset
    }
    const localStart = relOffset - bufStart
    return buf.subarray(localStart, localStart + length)
  }

  const entries: Entry[] = []
  const paths = new Set<string>()
  let cursor = 0
  let lastYield = Date.now()
  for (let index = 0; index < count; index++) {
    if ((index & 0xff) === 0 && index > 0 && Date.now() - lastYield >= 16) {
      await yieldToMain()
      lastYield = Date.now()
    }
    if (cursor + 46 > size) {
      invalid()
    }
    const header = await readDirSlice(cursor, 46)
    const view = viewOf(header)
    if (view.getUint32(0, true) !== 0x02014b50) {
      invalid()
    }
    const flags = view.getUint16(8, true)
    const method = view.getUint16(10, true)
    const crc = view.getUint32(16, true)
    const compressedSize = view.getUint32(20, true)
    const entrySize = view.getUint32(24, true)
    const nameLength = view.getUint16(28, true)
    const extraLength = view.getUint16(30, true)
    const commentLength = view.getUint16(32, true)
    const diskStart = view.getUint16(34, true)
    const externalAttr = view.getUint32(38, true)
    const entryOffset = view.getUint32(42, true)
    const next = cursor + 46 + nameLength + extraLength + commentLength
    // 只允许 deflate 选项、data descriptor 与 UTF-8 标志。
    if (
      flags & ~0x80e ||
      (method !== 0 && method !== 8) ||
      compressedSize === 0xffffffff ||
      entrySize === 0xffffffff ||
      (method === 0 && compressedSize !== entrySize) ||
      entryOffset >= offset ||
      diskStart !== 0 ||
      ((externalAttr >>> 16) & 0xf000) === 0xa000 ||
      next > size
    ) {
      invalid()
    }
    const nameView = await readDirSlice(cursor + 46, nameLength)
    // 仅复制几十字节文件名，避免条目数组持有整个 256KB 目录缓冲区。
    const name = nameView.slice()
    const path = decodePath(name, flags)
    // 目录和同名文件也不能互相覆盖。
    const identity = path.endsWith('/') ? path.slice(0, -1) : path
    if (paths.has(identity) || (path.endsWith('/') && entrySize !== 0)) {
      invalid()
    }
    paths.add(identity)
    if (extraLength > 0) {
      checkExtra(await readDirSlice(cursor + 46 + nameLength, extraLength))
    }
    entries.push({
      path,
      name,
      flags,
      method,
      crc,
      compressedSize,
      size: entrySize,
      offset: entryOffset,
    })
    cursor = next
  }
  if (cursor !== size) {
    invalid()
  }
  return { entries: entries.sort((a, b) => a.offset - b.offset), offset }
}

const readEntryOffset = async (file: File, entry: Entry, boundary: number) => {
  if (entry.offset + 30 > boundary) {
    invalid()
  }
  // 合并预读本地文件头 + 文件名 + 常见长度扩展区，绝大部分条目只需 1 次文件切片 IPC。
  const prefetchLen = Math.min(
    boundary - entry.offset,
    30 + entry.name.length + LOCAL_HEADER_PREFETCH_EXTRA
  )
  const head = await readBytes(file, entry.offset, prefetchLen)
  const view = viewOf(head)
  const nameLength = view.getUint16(26, true)
  const extraLength = view.getUint16(28, true)
  const start = entry.offset + 30 + nameLength + extraLength
  const end = start + entry.compressedSize
  if (
    view.getUint32(0, true) !== 0x04034b50 ||
    view.getUint16(6, true) !== entry.flags ||
    view.getUint16(8, true) !== entry.method ||
    nameLength !== entry.name.length ||
    end > boundary
  ) {
    invalid()
  }
  const hasDescriptor = (entry.flags & 8) !== 0
  const localCrc = view.getUint32(14, true)
  const localComp = view.getUint32(18, true)
  const localSize = view.getUint32(22, true)
  if (
    (localCrc !== entry.crc && (!hasDescriptor || localCrc !== 0)) ||
    (localComp !== entry.compressedSize && (!hasDescriptor || localComp !== 0)) ||
    (localSize !== entry.size && (!hasDescriptor || localSize !== 0))
  ) {
    invalid()
  }
  const metaLen = nameLength + extraLength
  const metadata =
    30 + metaLen <= head.length
      ? head.subarray(30, 30 + metaLen)
      : await readBytes(file, entry.offset + 30, metaLen)
  for (let i = 0; i < entry.name.length; i++) {
    if (entry.name[i] !== metadata[i]) {
      invalid()
    }
  }
  if (extraLength > 0) {
    checkExtra(metadata.subarray(nameLength))
  }
  if (hasDescriptor) {
    if (end + 12 > boundary) {
      invalid()
    }
    const descriptor = viewOf(await readBytes(file, end, Math.min(16, boundary - end)))
    const shift = descriptor.getUint32(0, true) === 0x08074b50 ? 4 : 0
    if (
      shift + 12 > descriptor.byteLength ||
      descriptor.getUint32(shift, true) !== entry.crc ||
      descriptor.getUint32(shift + 4, true) !== entry.compressedSize ||
      descriptor.getUint32(shift + 8, true) !== entry.size
    ) {
      invalid()
    }
  }
  return start
}

export type ArchiveEntry = {
  path: string
  size: number
  stream: AsyncIterable<Uint8Array>
}

/**
 * 按条目在文件中的物理顺序逐条、逐块解压，跳过目录条目。
 * 调用方必须消费完当前条目的数据，再请求下一个条目。
 */
export async function* readArchive(file: File): AsyncGenerator<ArchiveEntry> {
  const directory = await readDirectory(file)
  const lowPerf = isLowPerfDevice()
  const inflateChunkBytes = lowPerf ? LOW_PERF_INFLATE_CHUNK_BYTES : NORMAL_INFLATE_CHUNK_BYTES
  const yieldBudgetMs = lowPerf ? 12 : 20
  let lastYieldAt = Date.now()
  for (let index = 0; index < directory.entries.length; index++) {
    const entry = directory.entries[index]
    const boundary = directory.entries[index + 1]?.offset ?? directory.offset
    const start = await readEntryOffset(file, entry, boundary)
    if (entry.path.endsWith('/')) {
      continue
    }
    let completed = false
    const stream = async function* (): AsyncGenerator<Uint8Array> {
      let written = 0
      let crc = 0xffffffff
      const pending: Uint8Array[] = []
      const append = (chunk: Uint8Array) => {
        written += chunk.length
        if (written > entry.size) {
          invalid()
        }
        crc = updateCrc32(crc, chunk)
        if (chunk.length) {
          pending.push(chunk)
        }
      }
      const inflate = entry.method === 8 ? new Inflate(append) : null
      for (let offset = 0; offset < entry.compressedSize; offset += READ_CHUNK_BYTES) {
        const chunk = await readBytes(
          file,
          start + offset,
          Math.min(READ_CHUNK_BYTES, entry.compressedSize - offset)
        )
        if (!inflate) {
          append(chunk)
          for (let i = 0; i < pending.length; i++) {
            yield pending[i]
          }
          pending.length = 0
          if (Date.now() - lastYieldAt >= yieldBudgetMs) {
            await yieldToMain()
            lastYieldAt = Date.now()
          }
          continue
        }
        for (let cursor = 0; cursor < chunk.length; cursor += inflateChunkBytes) {
          const end = Math.min(cursor + inflateChunkBytes, chunk.length)
          inflate.push(chunk.subarray(cursor, end), offset + end === entry.compressedSize)
          // yield 暂停解压，等待调用方完成异步写入；不缓存整个条目。
          for (let i = 0; i < pending.length; i++) {
            yield pending[i]
          }
          pending.length = 0
          if (Date.now() - lastYieldAt >= yieldBudgetMs) {
            await yieldToMain()
            lastYieldAt = Date.now()
          }
        }
      }
      if (inflate && entry.compressedSize === 0) {
        inflate.push(new Uint8Array(0), true)
        for (let i = 0; i < pending.length; i++) {
          yield pending[i]
        }
        pending.length = 0
      }
      if (written !== entry.size || (crc ^ 0xffffffff) >>> 0 !== entry.crc) {
        invalid()
      }
      completed = true
    }
    yield { path: entry.path, size: entry.size, stream: stream() }
    if (!completed) {
      invalid()
    }
  }
}

/** 读出整个文本条目：直接流式 UTF-8 解码，跳过中间 Blob 包装与 Storage IPC 往返。 */
export const readEntryText = async (entry: ArchiveEntry): Promise<string> => {
  const decoder = new TextDecoder('utf-8')
  const parts: string[] = []
  for await (const chunk of entry.stream) {
    parts.push(decoder.decode(chunk, { stream: true }))
  }
  const tail = decoder.decode()
  if (tail) {
    parts.push(tail)
  }
  return parts.length === 1 ? parts[0] : parts.join('')
}

/** 读出整个二进制条目：按 256KB 合并后封入 Blob，避免每 8KB 产生一个 Blink Blob 句柄，同时顺带嗅探前 16 字节。 */
export const readEntry = async (
  entry: ArchiveEntry,
  resolveType?: (head: Uint8Array) => string
): Promise<Blob> => {
  const parts: Blob[] = []
  const head = resolveType ? new Uint8Array(16) : null
  let headLen = 0
  const staging = new Uint8Array(Math.min(BLOB_COALESCE_BYTES, Math.max(entry.size, 1)))
  let stagingUsed = 0

  const flushStaging = () => {
    if (stagingUsed > 0) {
      parts.push(new Blob([staging.subarray(0, stagingUsed)]))
      stagingUsed = 0
    }
  }

  for await (const chunk of entry.stream) {
    if (head && headLen < 16) {
      const copyLen = Math.min(16 - headLen, chunk.length)
      head.set(chunk.subarray(0, copyLen), headLen)
      headLen += copyLen
    }
    if (chunk.length >= staging.length) {
      flushStaging()
      parts.push(new Blob([chunk as Uint8Array<ArrayBuffer>]))
      continue
    }
    if (stagingUsed + chunk.length > staging.length) {
      flushStaging()
    }
    staging.set(chunk, stagingUsed)
    stagingUsed += chunk.length
  }
  flushStaging()
  const type = resolveType && head ? resolveType(head.subarray(0, headLen)) : ''
  return parts.length === 1 && !type ? parts[0] : new Blob(parts, type ? { type } : undefined)
}

/** 不需要的条目也要读完，以校验大小与 CRC。 */
export const skipEntry = async (entry: ArchiveEntry): Promise<void> => {
  const reader = entry.stream[Symbol.asyncIterator]()
  while (!(await reader.next()).done) {
    // 丢弃数据。
  }
}
