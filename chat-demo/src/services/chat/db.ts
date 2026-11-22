import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import { isLowPerfDevice, yieldToMain } from '../../app/devicePerf.js'
import { createId } from '../../utils/id.js'
import { toSessionSummary, type Message, type Session, type SessionSummary } from './types.js'

/** IndexedDB 存储结构版本；新增或调整存储、索引时递增。 */
const DB_VERSION = 11

/** 文件原件按附件的本地 id 存储，所有引用同一 id 的消息共用一份；用于缩略图、打开查看，以及没有 serverId 时补传。 */
export type StoredFile = {
  id: string
  blob: Blob
}

/** 文件引用留在摘要中，删除会话时通过索引判断原件是否仍被引用。 */
type StoredSessionSummary = SessionSummary & { fileIds: string[] }

interface ChatDB extends DBSchema {
  /** 当前使用的会话，界面读写都在这里 */
  sessions: { key: string; value: Session }
  sessionSummaries: {
    key: string
    value: StoredSessionSummary
    indexes: { fileIds: string }
  }
  /** 当前使用的文件原件 */
  files: { key: string; value: StoredFile }
  /**
   * 历史导入的暂存：导入过程中会话与原件只写入这两个存储，`sessions` / `files` 保持不变；
   * 全部校验通过后在一个事务中替换正式数据并清空暂存，失败时只清空暂存。
   */
  sessionsStaging: { key: string; value: Session }
  filesStaging: { key: string; value: StoredFile }
}

let dbPromise: Promise<IDBPDatabase<ChatDB>> | null = null

const storedSummary = (session: Session): StoredSessionSummary => {
  let seen: Set<string> | null = null
  const fileIds: string[] = []
  for (let i = 0; i < session.messages.length; i++) {
    const message = session.messages[i]
    if (message.role !== 'user' || message.files.length === 0) {
      continue
    }
    if (!seen) {
      seen = new Set<string>()
    }
    for (let j = 0; j < message.files.length; j++) {
      const id = message.files[j].id
      if (!seen.has(id)) {
        seen.add(id)
        fileIds.push(id)
      }
    }
  }
  return {
    ...toSessionSummary(session),
    fileIds,
  }
}

const abortTransaction = (tx: { abort(): void }) => {
  try {
    tx.abort()
  } catch {
    // 事务已因请求失败中止。
  }
}

// 每个操作拿到连接后立即创建事务；IndexedDB 按创建顺序执行范围重叠的事务，读取总能看到之前发起的写入。
const getDB = () =>
  (dbPromise ??= openDB<ChatDB>('chat-demo', DB_VERSION, {
    upgrade(db, _oldVersion, _newVersion, tx) {
      // 初始化当前格式需要的存储与索引，不迁移旧消息。
      for (const name of ['sessions', 'files', 'sessionsStaging', 'filesStaging'] as const) {
        if (!db.objectStoreNames.contains(name)) {
          db.createObjectStore(name, { keyPath: 'id' })
        }
      }
      const summaries = db.objectStoreNames.contains('sessionSummaries')
        ? tx.objectStore('sessionSummaries')
        : db.createObjectStore('sessionSummaries', { keyPath: 'id' })
      if (!summaries.indexNames.contains('fileIds')) {
        summaries.createIndex('fileIds', 'fileIds', { multiEntry: true })
      }
    },
    terminated() {
      // 系统回收存储进程或连接异常终止时释放旧连接，下次读写自动重连。
      dbPromise = null
    },
  }).catch((error: unknown) => {
    // 打开失败后允许界面重试，避免一直复用已拒绝的 Promise。
    dbPromise = null
    throw error
  }))

const isConnectionClosedError = (error: unknown): boolean => {
  if (!(error instanceof Error)) {
    return false
  }
  return (
    error.name === 'InvalidStateError' ||
    error.name === 'AbortError' ||
    error.name === 'TransactionInactiveError' ||
    error.name === 'UnknownError' ||
    /database connection is closing|connection.*closed|backing store|transaction.*abort|inactive/i.test(
      error.message
    )
  )
}

/** 切后台/息屏后 WebView 可能静默回收 IndexedDB 连接；捕获连接失效后重置并静默重连重试一次。 */
const withDbReconnect = async <T>(run: (db: IDBPDatabase<ChatDB>) => Promise<T>): Promise<T> => {
  try {
    return await run(await getDB())
  } catch (error) {
    if (!isConnectionClosedError(error)) {
      throw error
    }
    dbPromise = null
    return await run(await getDB())
  }
}

export const loadSessionSummaries = async (): Promise<SessionSummary[]> =>
  withDbReconnect(async (db) => (await db.getAll('sessionSummaries')).map(toSessionSummary))

export const loadSession = async (id: string): Promise<Session | undefined> =>
  withDbReconnect((db) => db.get('sessions', id))

export const saveSession = async (session: Session, files: StoredFile[] = []): Promise<void> =>
  withDbReconnect(async (db) => {
    const summary = storedSummary(session)
    const tx = db.transaction(['sessions', 'sessionSummaries', 'files'], 'readwrite')
    await Promise.all([
      (async () => {
        try {
          for (const file of files) {
            await tx.objectStore('files').put(file)
          }
          await tx.objectStore('sessions').put(session)
          await tx.objectStore('sessionSummaries').put(summary)
        } catch (error) {
          abortTransaction(tx)
          throw error
        }
      })(),
      tx.done,
    ])
  })

/** 未打开的会话也可重命名，只读取该会话，原子更新详情和列表。 */
export const renameSession = async (id: string, title: string): Promise<void> =>
  withDbReconnect(async (db) => {
    const tx = db.transaction(['sessions', 'sessionSummaries'], 'readwrite')
    await Promise.all([
      (async () => {
        try {
          const sessions = tx.objectStore('sessions')
          const session = await sessions.get(id)
          if (session) {
            session.title = title
            await sessions.put(session)
            await tx.objectStore('sessionSummaries').put(storedSummary(session))
          }
        } catch (error) {
          abortTransaction(tx)
          throw error
        }
      })(),
      tx.done,
    ])
  })

/** 未打开的会话也可置顶/取消置顶，原子更新详情和列表。 */
export const setSessionPinned = async (id: string, pinnedAt: number | undefined): Promise<void> =>
  withDbReconnect(async (db) => {
    const tx = db.transaction(['sessions', 'sessionSummaries'], 'readwrite')
    await Promise.all([
      (async () => {
        try {
          const sessions = tx.objectStore('sessions')
          const session = await sessions.get(id)
          if (session) {
            if (pinnedAt) {
              session.pinnedAt = pinnedAt
            } else {
              delete session.pinnedAt
            }
            await sessions.put(session)
            await tx.objectStore('sessionSummaries').put(storedSummary(session))
          }
        } catch (error) {
          abortTransaction(tx)
          throw error
        }
      })(),
      tx.done,
    ])
  })

/** 删除会话，仅清理已无会话引用的本地原件；远端文件不删。 */
export const deleteSession = async (sessionId: string): Promise<void> =>
  withDbReconnect(async (db) => {
    const tx = db.transaction(['sessions', 'sessionSummaries', 'files'], 'readwrite')
    await Promise.all([
      (async () => {
        try {
          const summaries = tx.objectStore('sessionSummaries')
          const summary = await summaries.get(sessionId)
          await tx.objectStore('sessions').delete(sessionId)
          await summaries.delete(sessionId)
          for (const id of summary?.fileIds ?? []) {
            if ((await summaries.index('fileIds').count(id)) === 0) {
              await tx.objectStore('files').delete(id)
            }
          }
        } catch (error) {
          abortTransaction(tx)
          throw error
        }
      })(),
      tx.done,
    ])
  })

const putFiles = async (store: 'files' | 'filesStaging', files: StoredFile[]) =>
  withDbReconnect(async (db) => {
    const tx = db.transaction(store, 'readwrite')
    await Promise.all([...files.map((file) => tx.store.put(file)), tx.done])
  })

export const saveFiles = (files: StoredFile[]): Promise<void> => putFiles('files', files)

export const loadFile = async (id: string): Promise<Blob | undefined> =>
  withDbReconnect(async (db) => (await db.get('files', id))?.blob)

/** 清空导入暂存：开始导入前清除上次中断（如关闭页面）遗留的数据，导入失败后清除本次写入。 */
export const clearStaging = async (): Promise<void> => {
  const tx = (await getDB()).transaction(['sessionsStaging', 'filesStaging'], 'readwrite')
  await Promise.all([
    tx.objectStore('sessionsStaging').clear(),
    tx.objectStore('filesStaging').clear(),
    tx.done,
  ])
}

export const addStagingSession = async (session: Session): Promise<void> => {
  await (await getDB()).add('sessionsStaging', session)
}

export const addStagingSessions = async (sessions: Session[]): Promise<void> => {
  if (sessions.length === 0) {
    return
  }
  const tx = (await getDB()).transaction('sessionsStaging', 'readwrite')
  await Promise.all([
    (async () => {
      try {
        for (const session of sessions) {
          await tx.store.add(session)
        }
      } catch (error) {
        abortTransaction(tx)
        throw error
      }
    })(),
    tx.done,
  ])
}

export const saveStagingFiles = (files: StoredFile[]): Promise<void> =>
  putFiles('filesStaging', files)

const applyFileTypesToSession = (
  session: Session,
  types: ReadonlyMap<string, string>
): boolean => {
  let changed = false
  for (let i = 0; i < session.messages.length; i++) {
    const message = session.messages[i]
    if (message.role !== 'user' || message.files.length === 0) {
      continue
    }
    for (let j = 0; j < message.files.length; j++) {
      const file = message.files[j]
      const type = types.get(file.id) ?? ''
      if (file.mimeType !== type) {
        file.mimeType = type
        changed = true
      }
    }
  }
  return changed
}

/** 图片位于会话 JSON 之后；全部读完后回填具体 MIME，保留归档给出的 isImage 标识。传入 targetSessionIds 时仅定向更新含图会话。 */
export const updateStagingFileTypes = async (
  types: ReadonlyMap<string, string>,
  targetSessionIds?: ReadonlySet<string>
): Promise<void> => {
  if (types.size === 0 || (targetSessionIds && targetSessionIds.size === 0)) {
    return
  }
  const tx = (await getDB()).transaction('sessionsStaging', 'readwrite')
  await Promise.all([
    (async () => {
      try {
        if (targetSessionIds) {
          for (const id of targetSessionIds) {
            const session = await tx.store.get(id)
            if (session && applyFileTypesToSession(session, types)) {
              await tx.store.put(session)
            }
          }
          return
        }
        for (let cursor = await tx.store.openCursor(); cursor; cursor = await cursor.continue()) {
          const session = cursor.value
          if (applyFileTypesToSession(session, types)) {
            await cursor.update(session)
          }
        }
      } catch (error) {
        abortTransaction(tx)
        throw error
      }
    })(),
    tx.done,
  ])
}

/**
 * 导入完成后用暂存替换正式数据：同一事务中顺序替换会话、摘要和原件并清空暂存。
 * 逐条游标复制且不并发交叠大 Blob 与大会话，降低低内存机型峰值占用；事务失败时整体回滚。
 */
export const commitStaging = async (): Promise<SessionSummary[]> => {
  const summaries: SessionSummary[] = []
  const tx = (await getDB()).transaction(
    ['sessions', 'sessionSummaries', 'files', 'sessionsStaging', 'filesStaging'],
    'readwrite'
  )
  const move = async (from: 'sessionsStaging' | 'filesStaging', to: 'sessions' | 'files') => {
    const target = tx.objectStore(to)
    await target.clear()
    if (to === 'sessions') {
      await tx.objectStore('sessionSummaries').clear()
    }
    for (
      let cursor = await tx.objectStore(from).openCursor();
      cursor;
      cursor = await cursor.continue()
    ) {
      await target.put(cursor.value)
      if (to === 'sessions') {
        const summary = storedSummary(cursor.value as Session)
        await tx.objectStore('sessionSummaries').put(summary)
        summaries.push(toSessionSummary(summary))
      }
    }
    await tx.objectStore(from).clear()
  }
  await Promise.all([
    (async () => {
      try {
        await move('sessionsStaging', 'sessions')
        await move('filesStaging', 'files')
      } catch (error) {
        // 同步抛出的错误不会让事务自动回滚，需显式中止，避免只提交清空和部分移入。
        abortTransaction(tx)
        throw error
      }
    })(),
    tx.done,
  ])
  // 直接返回本次提交的列表，调用方无需在替换成功后再发起可能失败的读取。
  return summaries
}

const messageSignature = (message: Message): string => {
  if (message.role === 'user') {
    if (message.files.length === 0) {
      return `U:${message.content}|`
    }
    let files = ''
    for (let i = 0; i < message.files.length; i++) {
      const file = message.files[i]
      if (i > 0) {
        files += ','
      }
      files += `${file.name}:${file.size}`
    }
    return `U:${message.content}|${files}`
  }
  let text = ''
  let hasText = false
  for (let i = 0; i < message.blocks.length; i++) {
    const block = message.blocks[i]
    if (block.type === 'text') {
      if (hasText) {
        text += '\n'
      }
      text += block.text
      hasText = true
    }
  }
  return `A:${text}`
}

/** 双 32 位 FNV-1a 迭代哈希，将任意长度文本压缩为 16 位十六进制指纹，避免长会话 O(N^2) 内存爆炸。 */
const hashStep = (seed: string, text: string): string => {
  let h1 = 0x811c9dc5
  let h2 = 0x01000193
  for (let i = 0; i < seed.length; i++) {
    const c = seed.charCodeAt(i)
    h1 = Math.imul(h1 ^ c, 0x01000193)
    h2 = Math.imul(h2 ^ (c + 17), 0x85ebca6b)
  }
  h1 = Math.imul(h1 ^ 0x3e, 0x01000193)
  h2 = Math.imul(h2 ^ 0x3e, 0x85ebca6b)
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    h1 = Math.imul(h1 ^ c, 0x01000193)
    h2 = Math.imul(h2 ^ (c + 31), 0x85ebca6b)
  }
  return `${(h1 >>> 0).toString(16).padStart(8, '0')}${(h2 >>> 0).toString(16).padStart(8, '0')}`
}

/** 为会话消息树中的每个节点计算从根到该节点的路径哈希集合（迭代计算，O(N) 时间与内存，无递归爆栈）。 */
const buildSessionPathSignatures = (session: Session): Set<string> => {
  const byId = new Map<string, Message>()
  for (let i = 0; i < session.messages.length; i++) {
    const message = session.messages[i]
    byId.set(message.id, message)
  }
  const memo = new Map<string, string>()
  const paths = new Set<string>()
  for (let idx = 0; idx < session.messages.length; idx++) {
    const start = session.messages[idx]
    if (memo.has(start.id)) {
      continue
    }
    const chain: Message[] = []
    const seen = new Set<string>()
    let cur: Message | undefined = start
    while (cur && !memo.has(cur.id) && !seen.has(cur.id)) {
      seen.add(cur.id)
      chain.push(cur)
      cur = cur.parentId ? byId.get(cur.parentId) : undefined
    }
    let parentHash = cur ? (memo.get(cur.id) ?? '') : ''
    for (let i = chain.length - 1; i >= 0; i--) {
      const node = chain[i]
      const digest = hashStep(parentHash, messageSignature(node))
      memo.set(node.id, digest)
      paths.add(digest)
      parentHash = digest
    }
  }
  return paths
}

const withBranchPrefix = (title: string, prefix: 'N分支·' | 'D分支·'): string => {
  const base = title.replace(/^[ND]分支·/, '')
  return `${prefix}${base || '未命名对话'}`
}

/**
 * 增量合并导入：按会话 ID 保护合并，保留已有本地对话不清空。
 * 同会话 ID 下：
 * 1. DeepSeek 记录落后于或等于本地（无新增内容）：跳过，不覆盖本地；
 * 2. DeepSeek 记录多于本地且本地无新增：直接覆盖更新为 DeepSeek 记录；
 * 3. 本地与 DeepSeek 各自均有新增（产生分叉）：保留本地并加「N分支·」前缀，DeepSeek 记录另存新 ID 并加「D分支·」前缀。
 * 返回本次实际写入/更新/分叉的会话数与合并后的全部会话摘要。
 */
export const mergeStaging = async (): Promise<{
  importedCount: number
  summaries: SessionSummary[]
}> => {
  let importedCount = 0
  let stored: StoredSessionSummary[] = []
  const tx = (await getDB()).transaction(
    ['sessions', 'sessionSummaries', 'files', 'sessionsStaging', 'filesStaging'],
    'readwrite'
  )
  const mergeSessions = async () => {
    const target = tx.objectStore('sessions')
    const summaryStore = tx.objectStore('sessionSummaries')
    for (
      let cursor = await tx.objectStore('sessionsStaging').openCursor();
      cursor;
      cursor = await cursor.continue()
    ) {
      const incoming = cursor.value
      const existing = await target.get(incoming.id)
      if (!existing) {
        await target.put(incoming)
        await summaryStore.put(storedSummary(incoming))
        importedCount += 1
        continue
      }
      const localPaths = buildSessionPathSignatures(existing)
      const incomingPaths = buildSessionPathSignatures(incoming)
      let localHasExtra = false
      for (const path of localPaths) {
        if (!incomingPaths.has(path)) {
          localHasExtra = true
          break
        }
      }
      let incomingHasExtra = false
      for (const path of incomingPaths) {
        if (!localPaths.has(path)) {
          incomingHasExtra = true
          break
        }
      }
      if (!incomingHasExtra) {
        // 规则 1：DeepSeek 记录落后或等于本地，跳过不覆盖
        continue
      }
      if (!localHasExtra) {
        // 规则 3：DeepSeek 记录多于本地且本地无新增，直接覆盖
        await target.put(incoming)
        await summaryStore.put(storedSummary(incoming))
        importedCount += 1
        continue
      }
      // 规则 2：两边均有各自新增，开分支保留两条独立会话
      const localBranched: Session = {
        ...existing,
        title: withBranchPrefix(existing.title, 'N分支·'),
      }
      const incomingBranched: Session = {
        ...incoming,
        id: createId(),
        title: withBranchPrefix(incoming.title, 'D分支·'),
      }
      await target.put(localBranched)
      await summaryStore.put(storedSummary(localBranched))
      await target.put(incomingBranched)
      await summaryStore.put(storedSummary(incomingBranched))
      importedCount += 1
    }
    await tx.objectStore('sessionsStaging').clear()
  }
  const mergeFiles = async () => {
    const target = tx.objectStore('files')
    for (
      let cursor = await tx.objectStore('filesStaging').openCursor();
      cursor;
      cursor = await cursor.continue()
    ) {
      await target.put(cursor.value)
    }
    await tx.objectStore('filesStaging').clear()
  }
  await Promise.all([
    (async () => {
      try {
        await mergeSessions()
        await mergeFiles()
        stored = (await tx.objectStore('sessionSummaries').getAll()) as StoredSessionSummary[]
      } catch (error) {
        abortTransaction(tx)
        throw error
      }
    })(),
    tx.done,
  ])
  return { importedCount, summaries: stored.map(toSessionSummary) }
}

/** 本地存储失败不打断对话，只在控制台留痕 */
export const reportStorageError = (action: string) => (error: unknown) => {
  // eslint-disable-next-line no-console
  console.error(`[storage] ${action} failed`, error)
}

const sessionMatchesKeyword = (session: Session, q: string): boolean => {
  if (session.title.toLowerCase().includes(q)) {
    return true
  }
  for (let i = 0; i < session.messages.length; i++) {
    const message = session.messages[i]
    if (message.role === 'user') {
      if (message.content.toLowerCase().includes(q)) {
        return true
      }
      continue
    }
    for (let j = 0; j < message.blocks.length; j++) {
      const block = message.blocks[j]
      if (block.type === 'text' && !block.isTemplate && block.text.toLowerCase().includes(q)) {
        return true
      }
    }
  }
  return false
}

/** 按关键词分片扫描本地会话正文，跳过已标题命中的会话并定期让出主线程，返回命中的会话 ID 集合 */
export const searchSessionIdsByContent = async (
  keyword: string,
  signal?: AbortSignal,
  skipIds?: ReadonlySet<string>
): Promise<Set<string>> => {
  const q = keyword.trim().toLowerCase()
  const matched = new Set<string>()
  if (!q || signal?.aborted) {
    return matched
  }
  const db = await getDB()
  if (signal?.aborted) {
    return matched
  }
  const allKeys = await db.getAllKeys('sessions')
  if (signal?.aborted) {
    return matched
  }
  const batchSize = isLowPerfDevice() ? 24 : 40
  let lastYieldAt = Date.now()
  for (let offset = 0; offset < allKeys.length; ) {
    if (signal?.aborted) {
      break
    }
    const keys: string[] = []
    while (offset < allKeys.length && keys.length < batchSize) {
      const id = allKeys[offset++]
      if (!skipIds?.has(id)) {
        keys.push(id)
      }
    }
    if (keys.length === 0) {
      break
    }
    const tx = db.transaction('sessions', 'readonly')
    const store = tx.store
    // 同一只读事务内并发管线化批读，消除逐条 await 的 IDB IPC 往返延迟，同时保持峰值驻留可控
    const sessions = await Promise.all(keys.map((id) => store.get(id)))
    if (signal?.aborted) {
      break
    }
    for (let i = 0; i < sessions.length; i++) {
      const session = sessions[i]
      if (session && sessionMatchesKeyword(session, q)) {
        matched.add(session.id)
      }
    }
    if (Date.now() - lastYieldAt >= 16) {
      await yieldToMain()
      lastYieldAt = Date.now()
    }
  }
  return matched
}
