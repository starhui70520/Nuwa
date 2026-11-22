import { BackupError, fail } from './errors.js'
import {
  EXPORT_FORMAT_VERSION,
  type ChatMessage,
  type FileEntry,
  type Fragment,
  type SearchResult,
  type SessionFile,
  type SessionIndexEntry,
} from './format.js'

/**
 * 按格式定义校验，返回只含已定义字段的新对象：容器与元数据严格校验，无法解析的内容片段丢弃。
 * 可空字段必须显式为 null；可选字段允许缺省，存在时严格校验。
 */

type Read<T> = (value: unknown) => T

const invalid = () => fail('backupIncomplete')

const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : invalid()

const string: Read<string> = (value) => (typeof value === 'string' ? value : invalid())

const boolean: Read<boolean> = (value) => (typeof value === 'boolean' ? value : invalid())

const number: Read<number> = (value) =>
  typeof value === 'number' && Number.isFinite(value) ? value : invalid()

/** 非负安全整数（u32 等） */
const count: Read<number> = (value) =>
  Number.isSafeInteger(value) && (value as number) >= 0 ? (value as number) : invalid()

const DAYS_IN_MONTH = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

const digit2 = (s: string, offset: number): number => {
  const a = s.charCodeAt(offset) - 48
  const b = s.charCodeAt(offset + 1) - 48
  return (a | b) < 0 || a > 9 || b > 9 ? -1 : a * 10 + b
}

const digit4 = (s: string, offset: number): number => {
  const hi = digit2(s, offset)
  const lo = digit2(s, offset + 2)
  return hi < 0 || lo < 0 ? -1 : hi * 100 + lo
}

/** 零分配纯整数 ISO-8601 UTC 日历校验，结果与 Date.prototype.toISOString 严格等价。 */
const time: Read<string> = (value) => {
  if (typeof value !== 'string') {
    return invalid()
  }
  const len = value.length
  if (
    len < 20 ||
    value.charCodeAt(4) !== 45 ||
    value.charCodeAt(7) !== 45 ||
    value.charCodeAt(10) !== 84 ||
    value.charCodeAt(13) !== 58 ||
    value.charCodeAt(16) !== 58 ||
    value.charCodeAt(len - 1) !== 90
  ) {
    return invalid()
  }
  if (len === 20) {
    // 无小数秒：位置 19 已确认是 'Z'
  } else if (len >= 22 && value.charCodeAt(19) === 46) {
    for (let i = 20; i < len - 1; i++) {
      const c = value.charCodeAt(i)
      if (c < 48 || c > 57) {
        return invalid()
      }
    }
  } else {
    return invalid()
  }
  const year = digit4(value, 0)
  const month = digit2(value, 5)
  const day = digit2(value, 8)
  const hour = digit2(value, 11)
  const minute = digit2(value, 14)
  const second = digit2(value, 17)
  if (
    year < 0 ||
    month < 1 ||
    month > 12 ||
    hour < 0 ||
    hour > 23 ||
    minute < 0 ||
    minute > 59 ||
    second < 0 ||
    second > 59
  ) {
    return invalid()
  }
  let maxDay = DAYS_IN_MONTH[month]
  if (month === 2 && ((year % 4 === 0 && year % 100 !== 0) || year % 400 === 0)) {
    maxDay = 29
  }
  return day >= 1 && day <= maxDay ? value : invalid()
}

/** 将已通过 schema 校验的 ISO-8601 UTC 时间直接换算为毫秒时间戳，避免重复走 Date.parse 正则解析。 */
export const parseValidatedIsoTime = (value: string): number => {
  const year = digit4(value, 0)
  if (year < 100) {
    return Date.parse(value)
  }
  const month = digit2(value, 5)
  const day = digit2(value, 8)
  const hour = digit2(value, 11)
  const minute = digit2(value, 14)
  const second = digit2(value, 17)
  let ms = 0
  const fracLen = value.length - 21
  if (fracLen > 0) {
    const d1 = value.charCodeAt(20) - 48
    const d2 = fracLen > 1 ? value.charCodeAt(21) - 48 : 0
    const d3 = fracLen > 2 ? value.charCodeAt(22) - 48 : 0
    ms = d1 * 100 + d2 * 10 + d3
  }
  return Date.UTC(year, month - 1, day, hour, minute, second, ms)
}

const nullable =
  <T>(read: Read<T>): Read<T | null> =>
  (value) =>
    value === null ? null : read(value)

const list =
  <T>(read: Read<T>): Read<T[]> =>
  (value) => {
    if (!Array.isArray(value)) {
      return invalid()
    }
    const result = new Array<T>(value.length)
    for (let i = 0; i < value.length; i++) {
      result[i] = read(value[i])
    }
    return result
  }

const oneOf =
  <const T extends string>(...values: T[]): Read<T> =>
  (value) =>
    values.includes(value as T) ? (value as T) : invalid()

const nullableString = nullable(string)
const nullableTime = nullable(time)
const nullableCount = nullable(count)
const nullableNumber = nullable(number)
const stringList = list(string)
const countList = list(count)

const tipStyle = oneOf('INFO', 'WARNING', 'CAUTION')
const searchStatus = oneOf('WIP', 'FINISHED', 'FAILED')
const findStatus = oneOf('WIP', 'FINISHED', 'NO_RESULT', 'FAILED')
const messageRole = oneOf('USER', 'ASSISTANT')
const messageStatus = oneOf(
  'WIP',
  'FINISHED',
  'CONTENT_FILTER',
  'FAILED',
  'INCOMPLETE',
  'CONTEXT_LENGTH_EXCEEDED',
  'TIMEOUT'
)
const toolMetadata = (item: Record<string, unknown>) => ({
  ...('stage_id' in item ? { stage_id: count(item.stage_id) } : {}),
  ...('group_id' in item ? { group_id: count(item.group_id) } : {}),
})

const searchResult: Read<SearchResult> = (value) => {
  const item = record(value)
  return {
    url: string(item.url),
    title: string(item.title),
    snippet: string(item.snippet),
    published_at: nullableTime(item.published_at),
    site_name: nullableString(item.site_name),
    ...('site_icon' in item ? { site_icon: nullableString(item.site_icon) } : {}),
  }
}
const searchResultList = list(searchResult)

const fileEntry: Read<FileEntry> = (value) => {
  const item = record(value)
  return {
    id: string(item.id),
    file_name: string(item.file_name),
    file_size: count(item.file_size),
    token_usage: nullableCount(item.token_usage),
    inserted_at: time(item.inserted_at),
    export_path: nullableString(item.export_path),
    is_image: boolean(item.is_image),
    width: nullableCount(item.width),
    height: nullableCount(item.height),
  }
}
const fileEntryList = list(fileEntry)

const readLinkResultList = list((result) => {
  const entry = record(result)
  return {
    signature: string(entry.signature),
    ...('url' in entry ? { url: string(entry.url) } : {}),
    ...('title' in entry ? { title: nullableString(entry.title) } : {}),
  }
})

const imageSearchResultList = list((result) => {
  const entry = record(result)
  return {
    title: string(entry.title),
    source_page_url: string(entry.source_page_url),
    snippet: string(entry.snippet),
    site_name: nullableString(entry.site_name),
    published_at: nullableTime(entry.published_at),
  }
})

const readFragment: Read<Fragment> = (value) => {
  const item = record(value)
  const type = string(item.type)
  switch (type) {
    case 'REQUEST':
      return { type, content: string(item.content) }
    case 'RESPONSE':
      return { type, content: string(item.content) }
    case 'TEMPLATE_RESPONSE':
      return { type, content: string(item.content) }
    case 'THINK':
      return {
        type,
        content: string(item.content),
        elapsed_secs: nullableNumber(item.elapsed_secs),
      }
    case 'TIP':
      return { type, content: string(item.content), style: tipStyle(item.style) }
    case 'CONTENT_RISK':
      return { type, content: string(item.content), style: tipStyle(item.style) }
    case 'PARTIAL_FILE_READ': {
      const ratio = number(item.ratio)
      return { type, ratio: ratio >= 0 && ratio <= 100 ? ratio : invalid() }
    }
    case 'TOOL_SEARCH':
      return {
        type,
        queries: stringList(item.queries),
        results: searchResultList(item.results),
        ...('status' in item ? { status: searchStatus(item.status) } : {}),
        ...toolMetadata(item),
      }
    case 'TOOL_OPEN':
      return {
        type,
        status: searchStatus(item.status),
        url: nullableString(item.url),
        title: nullableString(item.title),
        ...('snippet' in item ? { snippet: nullableString(item.snippet) } : {}),
        ...('site_name' in item ? { site_name: nullableString(item.site_name) } : {}),
        published_at: nullableTime(item.published_at),
        ...toolMetadata(item),
      }
    case 'TOOL_FIND':
      return {
        type,
        status: findStatus(item.status),
        ...('pattern' in item ? { pattern: string(item.pattern) } : {}),
        ...toolMetadata(item),
      }
    case 'READ_LINK':
      return {
        type,
        results: readLinkResultList(item.results),
      }
    case 'FILE':
      return { type, files: fileEntryList(item.files) }
    case 'TOOL_IMAGE_SEARCH':
      return {
        type,
        status: searchStatus(item.status),
        ...('image_indexes' in item ? { image_indexes: countList(item.image_indexes) } : {}),
        ...toolMetadata(item),
        results: imageSearchResultList(item.results),
      }
    default:
      return invalid()
  }
}

/** 单个内容片段不兼容不影响其余消息；容器、元数据和后续消息树校验仍严格执行。 */
const fragment: Read<Fragment | null> = (value) => {
  try {
    return readFragment(value)
  } catch (error) {
    if (error instanceof BackupError && error.key === 'backupIncomplete') {
      return null
    }
    throw error
  }
}

const readFragments = (value: unknown): Fragment[] => {
  if (!Array.isArray(value)) {
    return invalid()
  }
  const result: Fragment[] = []
  for (let i = 0; i < value.length; i++) {
    const parsed = fragment(value[i])
    if (parsed !== null) {
      result.push(parsed)
    }
  }
  return result
}

const message: Read<ChatMessage> = (value) => {
  const item = record(value)
  return {
    id: count(item.id),
    parent_id: nullableCount(item.parent_id),
    role: messageRole(item.role),
    status: messageStatus(item.status),
    thinking_enabled: boolean(item.thinking_enabled),
    search_enabled: boolean(item.search_enabled),
    accumulated_token_usage: count(item.accumulated_token_usage),
    inserted_at: time(item.inserted_at),
    fragments: readFragments(item.fragments),
  }
}
const messageList = list(message)

/** 会话 ID 用于拼接条目名，不能含路径分隔符 */
const sessionId: Read<string> = (value) => {
  const id = string(value)
  return id && !id.includes('/') && !id.includes('\\') && id !== '.' && id !== '..'
    ? id
    : invalid()
}

/** 版本号用于校验归档格式兼容性；字段结构由各字段的校验函数保证。 */
export const checkManifest = (value: unknown): void => {
  const version = record(value).export_format_version
  if (typeof version === 'number' && version > EXPORT_FORMAT_VERSION) {
    fail('backupNewerVersion')
  }
  if (version !== EXPORT_FORMAT_VERSION) {
    fail('backupInvalidVersion')
  }
}

export const readSessionIndex: Read<SessionIndexEntry[]> = list((value) => {
  const item = record(value)
  return {
    id: sessionId(item.id),
    title: nullableString(item.title),
    pinned: false,
    message_count: count(item.message_count),
    inserted_at: time(item.inserted_at),
    updated_at: time(item.updated_at),
  }
})

export const readSessionFile: Read<SessionFile> = (value) => {
  const item = record(value)
  return {
    id: sessionId(item.id),
    title: nullableString(item.title),
    pinned: false,
    current_message_id: count(item.current_message_id),
    inserted_at: time(item.inserted_at),
    updated_at: time(item.updated_at),
    messages: messageList(item.messages),
  }
}
