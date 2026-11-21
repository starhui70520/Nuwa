import { EXPORT_FORMAT_VERSION, type Manifest, type SessionIndexEntry } from '../../chat-demo/src/services/chat/history/format.js'
import { INDEX_PATH, MANIFEST_PATH, imagePath, sessionPath } from '../../chat-demo/src/services/chat/history/paths.js'
import { toIndexEntry, toSessionFile } from '../../chat-demo/src/services/chat/history/toArchive.js'
import { writeArchive } from '../../chat-demo/src/services/chat/history/zipWriter.js'
import type { Session } from '../../chat-demo/src/services/chat/types.js'

interface LegacyPin {
  id: string
  pinnedAt: number
}

interface LegacyStatus {
  state: 'pending' | 'ready' | 'error'
  size: number
  settings: Record<string, string>
  pins: LegacyPin[]
  documents: number
}

interface LegacyChunk {
  state: 'pending' | 'ready' | 'error'
  offset: number
  data: string
}

interface StoredFileRow {
  id: string
  blob: Blob
}

interface LegacyDocumentEntry {
  id: string
  blob: Blob
}

const DB_NAME = 'chat-demo'

const ALLOWED_SETTINGS_KEYS = [
  'chat-demo:locale',
  'chat-demo:location',
  'chat-demo:theme-preference',
  'chat-demo:chat-font-size',
  'chat-demo:thinking',
  'chat-demo:search',
  'chat-demo:tts-muted',
  'chat-demo:tts-voice',
  'chat-demo:speech-engine',
  'chat-demo:api-base-url',
  'chat-demo:api-protocol',
  'chat-demo:api-model',
  'chat-demo:auth-mode',
  'chat-demo:dsh-token',
  'chat-demo:dsh-account-label',
  'chat-demo:api-key',
  'chat-demo:migration-prompt-handled',
  'chat-demo:sider-collapsed',
] as const

const jsonBlob = (value: unknown): Blob =>
  new Blob([JSON.stringify(value)], { type: 'application/json' })

const readAllowedSettings = (): Record<string, string> => {
  const result: Record<string, string> = {}
  try {
    for (const key of ALLOWED_SETTINGS_KEYS) {
      const value = window.localStorage.getItem(key)
      if (typeof value === 'string') {
        result[key] = value
      }
    }
  } catch {
    // Ignore storage access errors in restricted contexts.
  }
  return result
}

const openExistingDatabase = (): Promise<IDBDatabase | null> =>
  new Promise((resolve, reject) => {
    let missingDatabase = false
    const request = window.indexedDB.open(DB_NAME)
    request.onupgradeneeded = () => {
      // Never create or mutate IndexedDB during read-only legacy inspection.
      missingDatabase = true
      try {
        request.transaction?.abort()
      } catch {
        // Ignore abort errors.
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => {
      if (missingDatabase || request.error?.name === 'AbortError') {
        resolve(null)
      } else {
        reject(request.error ?? new Error('Unable to open legacy IndexedDB'))
      }
    }
    request.onblocked = () => reject(new Error('Legacy IndexedDB is blocked'))
  })

const readAllSessions = (db: IDBDatabase): Promise<Session[]> =>
  new Promise((resolve, reject) => {
    const sessions: Session[] = []
    const tx = db.transaction('sessions', 'readonly')
    const request = tx.objectStore('sessions').openCursor()
    request.onsuccess = () => {
      const cursor = request.result
      if (!cursor) return
      const value = cursor.value as Session | undefined
      if (value && typeof value.id === 'string' && value.id && Array.isArray(value.messages)) {
        sessions.push(value)
      }
      cursor.continue()
    }
    request.onerror = () => reject(request.error ?? new Error('Unable to read legacy sessions'))
    tx.oncomplete = () => resolve(sessions)
    tx.onerror = () => reject(tx.error ?? new Error('Legacy sessions transaction failed'))
    tx.onabort = () => reject(tx.error ?? new Error('Legacy sessions transaction aborted'))
  })

const readStoredFile = (db: IDBDatabase, id: string): Promise<Blob | undefined> =>
  new Promise((resolve, reject) => {
    const tx = db.transaction('files', 'readonly')
    const request = tx.objectStore('files').get(id)
    request.onsuccess = () => {
      const row = request.result as StoredFileRow | undefined
      resolve(row?.blob instanceof Blob ? row.blob : undefined)
    }
    request.onerror = () => reject(request.error ?? new Error('Unable to read legacy file'))
    tx.onabort = () => reject(tx.error ?? new Error('Legacy file transaction aborted'))
  })

const encodeBase64 = (bytes: Uint8Array): string => {
  let binary = ''
  const step = 0x8000
  for (let offset = 0; offset < bytes.length; offset += step) {
    const slice = bytes.subarray(offset, Math.min(bytes.length, offset + step))
    binary += String.fromCharCode(...slice)
  }
  return window.btoa(binary)
}

let statusState: LegacyStatus = {
  state: 'pending',
  size: 0,
  settings: {},
  pins: [],
  documents: 0,
}

let chunkState: LegacyChunk = {
  state: 'pending',
  offset: 0,
  data: '',
}

let archiveBlob: Blob | null = null
let documentEntries: LegacyDocumentEntry[] = []
let prepareStarted = false
let readGeneration = 0

async function runPrepare(): Promise<void> {
  const settings = readAllowedSettings()
  const db = await openExistingDatabase()
  if (!db) {
    archiveBlob = null
    documentEntries = []
    statusState = { state: 'ready', size: 0, settings, pins: [], documents: 0 }
    return
  }

  try {
    if (!db.objectStoreNames.contains('sessions')) {
      archiveBlob = null
      documentEntries = []
      statusState = { state: 'ready', size: 0, settings, pins: [], documents: 0 }
      return
    }

    const sessions = await readAllSessions(db)
    if (sessions.length === 0) {
      archiveBlob = null
      documentEntries = []
      statusState = { state: 'ready', size: 0, settings, pins: [], documents: 0 }
      return
    }

    const hasFilesStore = db.objectStoreNames.contains('files')
    const imageOriginals = new Map<string, Blob | undefined>()
    const seenDocuments = new Set<string>()
    const documents: LegacyDocumentEntry[] = []
    const pins: LegacyPin[] = []
    const manifest: Manifest = { export_format_version: EXPORT_FORMAT_VERSION }
    const entries: { name: string; blob: Blob }[] = [{ name: MANIFEST_PATH, blob: jsonBlob(manifest) }]
    const imageEntries: { name: string; blob: Blob }[] = []
    const index: SessionIndexEntry[] = []

    for (const session of sessions) {
      const sessionFiles = new Map<string, Blob>()
      if (hasFilesStore) {
        for (const message of session.messages) {
          if (message.role !== 'user' || !Array.isArray(message.files)) continue
          for (const file of message.files) {
            if (!file || typeof file.id !== 'string' || !file.id) continue
            if (file.isImage) {
              if (!imageOriginals.has(file.id)) {
                imageOriginals.set(file.id, await readStoredFile(db, file.id).catch(() => undefined))
              }
            } else if (!seenDocuments.has(file.id)) {
              seenDocuments.add(file.id)
              const blob = await readStoredFile(db, file.id).catch(() => undefined)
              if (blob && blob.size > 0) {
                documents.push({ id: file.id, blob })
              }
            }
          }
        }
      }

      let data
      try {
        data = toSessionFile(session, ({ id, name, isImage }) => {
          const blob = imageOriginals.get(id)
          if (!blob || !isImage) {
            return null
          }
          const path = imagePath(session.id, id, name)
          sessionFiles.set(path, blob)
          return path
        })
      } catch {
        continue
      }

      if (typeof session.pinnedAt === 'number' && Number.isFinite(session.pinnedAt) && session.pinnedAt > 0) {
        pins.push({ id: session.id, pinnedAt: session.pinnedAt })
      }
      entries.push({ name: sessionPath(session.id), blob: jsonBlob(data) })
      for (const [name, blob] of sessionFiles) {
        imageEntries.push({ name, blob })
      }
      index.push(toIndexEntry(data))
    }

    if (index.length === 0) {
      archiveBlob = null
      documentEntries = []
      statusState = { state: 'ready', size: 0, settings, pins: [], documents: 0 }
      return
    }

    entries.push({ name: INDEX_PATH, blob: jsonBlob(index) })
    const zip = await writeArchive(entries.concat(imageEntries))
    archiveBlob = zip
    documentEntries = documents
    statusState = {
      state: 'ready',
      size: zip.size,
      settings,
      pins,
      documents: documents.length,
    }
  } finally {
    db.close()
  }
}

interface NuwaLegacyMigrationBridge {
  prepare: () => void
  status: () => string
  document: (index: number) => string
  read: (offset: number, length: number, documentIndex?: number) => void
  chunk: () => string
}

const bridge: NuwaLegacyMigrationBridge = {
  prepare() {
    if (prepareStarted) return
    prepareStarted = true
    statusState = { state: 'pending', size: 0, settings: {}, pins: [], documents: 0 }
    void runPrepare().catch(() => {
      archiveBlob = null
      documentEntries = []
      statusState = { state: 'error', size: 0, settings: {}, pins: [], documents: 0 }
    })
  },
  status() {
    return JSON.stringify(statusState)
  },
  document(index: number) {
    const entry = Number.isInteger(index) && index >= 0 ? documentEntries[index] : undefined
    if (!entry) return '{}'
    return JSON.stringify({ id: entry.id, size: entry.blob.size })
  },
  read(offset: number, length: number, documentIndex?: number) {
    const generation = ++readGeneration
    chunkState = { state: 'pending', offset, data: '' }
    const target = documentIndex === undefined
      ? archiveBlob
      : (Number.isInteger(documentIndex) && documentIndex >= 0 ? documentEntries[documentIndex]?.blob ?? null : null)
    if (!target || !Number.isSafeInteger(offset) || !Number.isSafeInteger(length) ||
      offset < 0 || length <= 0 || offset + length > target.size) {
      chunkState = { state: 'error', offset, data: '' }
      return
    }
    void target.slice(offset, offset + length).arrayBuffer().then((buffer) => {
      if (generation !== readGeneration) return
      const bytes = new Uint8Array(buffer)
      if (bytes.byteLength !== length) {
        chunkState = { state: 'error', offset, data: '' }
        return
      }
      chunkState = { state: 'ready', offset, data: encodeBase64(bytes) }
    }).catch(() => {
      if (generation !== readGeneration) return
      chunkState = { state: 'error', offset, data: '' }
    })
  },
  chunk() {
    return JSON.stringify(chunkState)
  },
}

;(window as unknown as { nuwaLegacyMigration: NuwaLegacyMigrationBridge }).nuwaLegacyMigration = bridge
