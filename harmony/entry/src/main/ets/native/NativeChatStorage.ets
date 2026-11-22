import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { NativeChatSource, NativeChatCitation } from './NativeChatSources';
import { fileIo } from '@kit.CoreFileKit';
import { NativeAttachment } from './NativeChatAttachments';
import { ensureNativeDirectory } from './NativeFileSystem';
import { NativeFailedUpload, NativeReplyFailure } from './NativeReplyNotice';
import { validNativeReadLinks } from './NativeReadLinks';
import { validNativePrefillBlocks } from './NativeReplyPrefill';
import { isValidNativeToolTimeline, settleInterruptedNativeToolTimeline } from './NativeToolTimeline';
import { backupImageIds, pruneBackupImages, removeBackupImage } from './NativeBackupFiles';
import { yieldNativeTurn } from './NativeDevicePerf';
import {
  NativeConversation,
  NativeConversationMessage,
  NativeConversationState,
  NativeConversationSummary,
  NativeStoredMessage,
  appendBranch,
  createConversation,
  createConversationMessage,
  upsertConversation,
  unloadedConversation,
} from './NativeConversation';

const TRANSCRIPT_FILE = 'nuwa-native-chat.json';
const HISTORY_DIRECTORY = 'nuwa-native-history';
const INDEX_FILE = 'index.json';
const FILE_NOT_FOUND = 13900002;
const LEGACY_HISTORY_VERSION = 1;
const STORAGE_VERSION = 2;
const SNAPSHOT_CHUNK_CHARS = 64 * 1024;
const RECORD_FILE = /^session-[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}\.json$/i;

interface LegacyConversationDocument extends NativeConversationState {
  version: number;
}

interface SessionMetadata extends NativeConversationSummary {
  rootMessageId: string | null;
  messageCount: number;
}

interface SessionIndexEntry {
  metadata: SessionMetadata;
  file: string;
  digest: string;
}

interface SessionIndex {
  version: number;
  activeId: string | null;
  sessions: SessionIndexEntry[];
}

interface SessionWrite {
  metadata: SessionMetadata;
  snapshot?: string;
  sessionRef?: NativeConversation;
  retainsSnapshot?: boolean;
}

interface HistoryWrite {
  activeId: string | null;
  sessions: SessionWrite[];
  incremental: boolean;
}

interface SessionImageIds {
  archiveJson: string;
  ids: string[];
}

interface CommittedSessionStamp {
  directory: string;
  file: string;
  digest: string;
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  pinnedAt?: number;
  rootMessageId: string | null;
  messageCount: number;
  messagesRef: NativeConversationMessage[];
  archiveJson?: string;
  hasAttachments: boolean;
}

interface PendingCommitStamp {
  session: NativeConversation;
  entry: SessionIndexEntry;
}

const SNAPSHOT_TEXT_ENCODER = new util.TextEncoder();
const BULK_WRITE_CONCURRENCY = 4;
const SEARCH_READ_CONCURRENCY = 4;
const JSON_ESCAPE_SENSITIVE_PATTERN = /["\\\u0000-\u001f]/;
let pendingStorage: Promise<void> = Promise.resolve();
const committedIndexes = new Map<string, SessionIndex>();
const committedIndexById = new Map<string, Map<string, SessionIndexEntry>>();
const committedSessionStamps = new WeakMap<NativeConversation, CommittedSessionStamp>();
const cachedSessionImages = new Map<string, Map<string, SessionImageIds>>();
const committedImages = new Map<string, Set<string>>();
const pendingImageWrites = new Map<string, Set<Set<string>>>();

function cacheCommittedIndex(directory: string, index: SessionIndex): void {
  committedIndexes.set(directory, index);
  const byId = new Map<string, SessionIndexEntry>();
  for (let i = 0; i < index.sessions.length; i++) {
    const entry = index.sessions[i];
    byId.set(entry.metadata.id, entry);
  }
  committedIndexById.set(directory, byId);
}

function clearCommittedIndex(directory: string): void {
  committedIndexes.delete(directory);
  committedIndexById.delete(directory);
}

function conversationHasAttachments(session: NativeConversation): boolean {
  for (let i = 0; i < session.messages.length; i++) {
    const files = session.messages[i].files;
    if (files && files.length > 0) {
      return true;
    }
  }
  return false;
}

function stampCommittedSession(directory: string, session: NativeConversation, entry: SessionIndexEntry): void {
  const hasAttachments = conversationHasAttachments(session);
  if (hasAttachments) {
    committedSessionStamps.delete(session);
    return;
  }
  committedSessionStamps.set(session, {
    directory,
    file: entry.file,
    digest: entry.digest,
    id: session.id,
    title: session.title,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    pinnedAt: session.pinnedAt,
    rootMessageId: session.rootMessageId,
    messageCount: session.messages.length,
    messagesRef: session.messages,
    archiveJson: session.archiveJson,
    hasAttachments: false,
  });
}

function matchesCommittedStamp(directory: string, session: NativeConversation,
  entry: SessionIndexEntry | undefined): boolean {
  if (!entry) return false;
  const stamp = committedSessionStamps.get(session);
  if (!stamp || stamp.hasAttachments) return false;
  return stamp.directory === directory &&
    stamp.file === entry.file &&
    stamp.digest === entry.digest &&
    stamp.id === session.id &&
    stamp.title === session.title &&
    stamp.createdAt === session.createdAt &&
    stamp.updatedAt === session.updatedAt &&
    stamp.pinnedAt === session.pinnedAt &&
    stamp.rootMessageId === session.rootMessageId &&
    stamp.messageCount === session.messages.length &&
    stamp.messagesRef === session.messages &&
    stamp.archiveJson === session.archiveJson;
}

function queueStorageOperation<T>(operation: () => Promise<T>): Promise<T> {
  const result = pendingStorage.then<T>(operation);
  pendingStorage = result.then<void, void>(() => {}, () => {});
  return result;
}

function isStoredMessage(message: NativeStoredMessage): boolean {
  return !!message && typeof message.role === 'string' && typeof message.content === 'string' &&
    typeof message.reasoning === 'string';
}

function isTimestamp(value: number): boolean {
  return Number.isFinite(value) && value >= 0 && value <= 8_640_000_000_000_000;
}

function validAttachment(item: NativeAttachment): boolean {
  return !!item && typeof item.id === 'string' && !!item.id && typeof item.name === 'string' &&
    Number.isSafeInteger(item.size) && item.size >= 0 && typeof item.isImage === 'boolean' &&
    typeof item.mimeType === 'string' && (item.purpose === null || item.purpose === 'rich_layout_recognition' ||
    item.purpose === 'user_data') && isTimestamp(item.createdAt) &&
    (item.serverId === null || typeof item.serverId === 'string') && typeof item.local === 'boolean' &&
    (item.serverBinding === undefined || typeof item.serverBinding === 'string') &&
    (item.archiveId === undefined || (typeof item.archiveId === 'string' && !!item.archiveId)) &&
    (item.nativeAvifPreview === undefined || typeof item.nativeAvifPreview === 'boolean') &&
    (!item.local || /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(item.id));
}

function validSource(source: NativeChatSource): boolean {
  return !!source && Number.isSafeInteger(source.index) && source.index > 0 &&
    typeof source.url === 'string' && /^https?:\/\//i.test(source.url) &&
    typeof source.title === 'string' && typeof source.siteName === 'string' &&
    (source.snippet === null || typeof source.snippet === 'string') &&
    (source.publishedAt === null || typeof source.publishedAt === 'string') &&
    (source.siteIcon === null || typeof source.siteIcon === 'string') && typeof source.searchResult === 'boolean';
}

function validCitation(citation: NativeChatCitation): boolean {
  return !!citation && Number.isSafeInteger(citation.offset) && citation.offset >= 0 &&
    Number.isSafeInteger(citation.sourceIndex) && citation.sourceIndex > 0;
}

function validFailureStatus(status: number | undefined): boolean {
  return status === undefined || (Number.isSafeInteger(status) && status >= 100 && status <= 599);
}

function validFailedUpload(file: NativeFailedUpload): boolean {
  return !!file && typeof file.id === 'string' && !!file.id && typeof file.detail === 'string' && file.detail.length <= 512 &&
    typeof file.retryable === 'boolean' && validFailureStatus(file.status);
}

function validReplyFailure(failure: NativeReplyFailure): boolean {
  return !!failure && ['network', 'upload', 'response', 'unsupported-image'].includes(failure.kind) &&
    typeof failure.detail === 'string' && failure.detail.length <= 512 && validFailureStatus(failure.status) &&
    (failure.uploadFiles === undefined ||
      (failure.kind === 'upload' && Array.isArray(failure.uploadFiles) && failure.uploadFiles.every(validFailedUpload)));
}

function validateConversation(session: NativeConversation): boolean {
  if (!session || typeof session.id !== 'string' || !session.id || typeof session.title !== 'string' ||
    !isTimestamp(session.createdAt) || !isTimestamp(session.updatedAt) ||
    session.unloaded !== undefined || session.unreadable !== undefined ||
    (session.archiveJson !== undefined && typeof session.archiveJson !== 'string') ||
    (session.pinnedAt !== undefined && !isTimestamp(session.pinnedAt)) || !Array.isArray(session.messages)) {
    return false;
  }
  const byId = new Map<string, NativeConversationMessage>();
  for (const message of session.messages) {
    if (!isStoredMessage(message) || typeof message.id !== 'string' || !message.id || byId.has(message.id) ||
      !isTimestamp(message.createdAt) || (message.parentId !== null && !byId.has(message.parentId)) ||
      (message.status !== undefined && typeof message.status !== 'string') ||
      (message.failure !== undefined && !validReplyFailure(message.failure)) ||
      (message.readLinks !== undefined && !validNativeReadLinks(message.readLinks, message.content.length)) ||
      (message.toolTimeline !== undefined && !isValidNativeToolTimeline(message.toolTimeline)) ||
      (message.model !== undefined && typeof message.model !== 'string') ||
      (message.stopReason !== undefined && typeof message.stopReason !== 'string') ||
      (message.canPrefill !== undefined && typeof message.canPrefill !== 'boolean') ||
      (message.prefillBlocks !== undefined && (message.role !== 'assistant' ||
        !validNativePrefillBlocks(message.prefillBlocks))) ||
      (message.thinking !== undefined && typeof message.thinking !== 'boolean') ||
      (message.search !== undefined && typeof message.search !== 'boolean') ||
      (message.thinkingSignature !== undefined && typeof message.thinkingSignature !== 'string') ||
      (message.latestReminder !== undefined && typeof message.latestReminder !== 'string') ||
      (message.sources !== undefined && (!Array.isArray(message.sources) || !message.sources.every(validSource))) ||
      (message.citations !== undefined && (!Array.isArray(message.citations) || !message.citations.every(validCitation))) ||
      (message.files !== undefined && (!Array.isArray(message.files) || !message.files.every(validAttachment)))) {
      return false;
    }
    byId.set(message.id, message);
  }
  if (session.rootMessageId === null ? byId.size > 0 : byId.get(session.rootMessageId)?.parentId !== null) {
    return false;
  }
  return session.messages.every((message: NativeConversationMessage): boolean =>
    message.selectedChildId === undefined || byId.get(message.selectedChildId)?.parentId === message.id);
}

function readLegacyDocument(document: LegacyConversationDocument): NativeConversationState {
  if (!document || document.version !== LEGACY_HISTORY_VERSION || !Array.isArray(document.sessions)) {
    throw new Error('Invalid native conversation history');
  }
  const ids = new Set<string>();
  for (const session of document.sessions) {
    if (!validateConversation(session) || ids.has(session.id)) {
      throw new Error('Invalid native conversation');
    }
    ids.add(session.id);
  }
  if (document.activeId !== null && !ids.has(document.activeId)) {
    throw new Error('Invalid active native conversation');
  }
  return { sessions: document.sessions, activeId: document.activeId };
}

function recoverInterruptedConversation(session: NativeConversation): NativeConversation {
  for (const message of session.messages) {
    if (message.role === 'assistant' && (message.status === 'pending' || message.status === 'streaming')) {
      message.status = 'stopped';
      if (message.toolTimeline) {
        // A pending link is hidden after stopping, but still rules out continuing after reload.
        if (message.toolTimeline.steps.some(step => step.type === 'read_link')) message.canPrefill = false;
        settleInterruptedNativeToolTimeline(message.toolTimeline);
      }
    }
  }
  return session;
}

function recoverInterrupted(state: NativeConversationState): NativeConversationState {
  for (const session of state.sessions) recoverInterruptedConversation(session);
  return state;
}

function sessionMetadata(session: NativeConversation): SessionMetadata {
  return {
    id: session.id, title: session.title, createdAt: session.createdAt, updatedAt: session.updatedAt,
    pinnedAt: session.pinnedAt, rootMessageId: session.rootMessageId, messageCount: session.messages.length,
  };
}

function sameSessionSummary(left: SessionMetadata, right: SessionMetadata): boolean {
  return left.id === right.id && left.title === right.title && left.createdAt === right.createdAt &&
    left.updatedAt === right.updatedAt && left.pinnedAt === right.pinnedAt;
}

function sameMetadata(left: SessionMetadata, right: SessionMetadata): boolean {
  return sameSessionSummary(left, right) && left.rootMessageId === right.rootMessageId &&
    left.messageCount === right.messageCount;
}

function validateIndex(index: SessionIndex): void {
  if (!index || index.version !== STORAGE_VERSION || !Array.isArray(index.sessions)) {
    throw new Error('Invalid native conversation index');
  }
  const ids = new Set<string>();
  const files = new Set<string>();
  for (const entry of index.sessions) {
    const metadata = entry?.metadata;
    if (!metadata || typeof metadata.id !== 'string' || !metadata.id || ids.has(metadata.id) ||
      typeof metadata.title !== 'string' || !isTimestamp(metadata.createdAt) || !isTimestamp(metadata.updatedAt) ||
      (metadata.pinnedAt !== undefined && !isTimestamp(metadata.pinnedAt)) ||
      !Number.isSafeInteger(metadata.messageCount) || metadata.messageCount < 0 ||
      (metadata.rootMessageId !== null && typeof metadata.rootMessageId !== 'string') ||
      typeof entry.file !== 'string' || !RECORD_FILE.test(entry.file) || files.has(entry.file) ||
      typeof entry.digest !== 'string' || !/^[\da-f]{64}$/.test(entry.digest)) {
      throw new Error('Invalid native conversation index entry');
    }
    ids.add(metadata.id);
    files.add(entry.file);
  }
  if (index.activeId !== null && !ids.has(index.activeId)) {
    throw new Error('Invalid active native conversation');
  }
}

function captureHistory(state: NativeConversationState, dirtySessionIds?: string[]): HistoryWrite {
  const dirty = dirtySessionIds === undefined ? undefined : new Set<string>(dirtySessionIds);
  if (dirty && dirty.size !== dirtySessionIds?.length) {
    throw new Error('Duplicate dirty native conversation');
  }
  const ids = new Set<string>();
  const sessions = state.sessions.map<SessionWrite>((session: NativeConversation): SessionWrite => {
    if (ids.has(session.id)) {
      throw new Error('Duplicate native conversation');
    }
    ids.add(session.id);
    const metadata = sessionMetadata(session);
    if (session.unloaded || session.unreadable) {
      if (metadata.rootMessageId !== null || metadata.messageCount !== 0 || session.archiveJson !== undefined) {
        throw new Error('Native conversation reference cannot be modified without loading its messages');
      }
      return { metadata, retainsSnapshot: true };
    }
    if (dirty) {
      if (!dirty.has(session.id)) {
        return { metadata };
      }
      if (!validateConversation(session)) {
        throw new Error('Invalid native conversation');
      }
      return { metadata, snapshot: JSON.stringify(session), sessionRef: session };
    }
    // 全量保存延后到 commitHistory 逐条校验与序列化，避免批量导入时几百份 JSON 字符串同时驻留内存。
    return { metadata, sessionRef: session };
  });
  if (state.activeId !== null && !ids.has(state.activeId)) {
    throw new Error('Invalid active native conversation');
  }
  if (dirty && Array.from(dirty).some((id: string): boolean => !ids.has(id))) {
    throw new Error('Unknown dirty native conversation');
  }
  return { activeId: state.activeId, sessions, incremental: dirty !== undefined };
}

function chunkEnd(value: string, start: number): number {
  const end = Math.min(value.length, start + SNAPSHOT_CHUNK_CHARS);
  const last = value.charCodeAt(end - 1);
  return end < value.length && last >= 0xd800 && last <= 0xdbff ? end - 1 : end;
}

interface EncodedSnapshot {
  chunks: Uint8Array[];
  digest: string;
}

function encodeAndDigestSnapshot(snapshot: string): EncodedSnapshot {
  const md = cryptoFramework.createMd('SHA256');
  const chunks: Uint8Array[] = [];
  let offset = 0;
  while (offset < snapshot.length) {
    const end = chunkEnd(snapshot, offset);
    const bytes = SNAPSHOT_TEXT_ENCODER.encodeInto(snapshot.slice(offset, end));
    md.updateSync({ data: bytes });
    chunks.push(bytes);
    offset = end;
  }
  let hash = '';
  for (const byte of md.digestSync().data) {
    hash += byte.toString(16).padStart(2, '0');
  }
  return { chunks, digest: hash };
}

function sessionDigest(snapshot: string): string {
  const md = cryptoFramework.createMd('SHA256');
  let offset = 0;
  while (offset < snapshot.length) {
    const end = chunkEnd(snapshot, offset);
    md.updateSync({ data: SNAPSHOT_TEXT_ENCODER.encodeInto(snapshot.slice(offset, end)) });
    offset = end;
  }
  let hash = '';
  for (const byte of md.digestSync().data) {
    hash += byte.toString(16).padStart(2, '0');
  }
  return hash;
}

async function writeEncodedChunks(path: string, chunks: Uint8Array[]): Promise<void> {
  const temporaryPath = `${path}.tmp`;
  try {
    const file = await fileIo.open(temporaryPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      for (let i = 0; i < chunks.length; i++) {
        let remaining = chunks[i].buffer as ArrayBuffer;
        while (remaining.byteLength > 0) {
          const written = await fileIo.write(file.fd, remaining);
          if (written <= 0) {
            throw new Error('Could not write native conversation history');
          }
          if (written >= remaining.byteLength) {
            break;
          }
          remaining = remaining.slice(written);
        }
      }
      await fileIo.fsync(file.fd);
    } finally {
      await fileIo.close(file);
    }
    await fileIo.rename(temporaryPath, path);
  } catch (error) {
    await fileIo.unlink(temporaryPath).catch(() => {});
    throw error as Error;
  }
}

async function writeSnapshot(path: string, snapshot: string): Promise<void> {
  const temporaryPath = `${path}.tmp`;
  try {
    const file = await fileIo.open(temporaryPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      let start = 0;
      while (start < snapshot.length) {
        const end = chunkEnd(snapshot, start);
        let remaining = SNAPSHOT_TEXT_ENCODER.encodeInto(snapshot.slice(start, end)).buffer as ArrayBuffer;
        while (remaining.byteLength > 0) {
          const written = await fileIo.write(file.fd, remaining);
          if (written <= 0) {
            throw new Error('Could not write native conversation history');
          }
          if (written >= remaining.byteLength) {
            break;
          }
          remaining = remaining.slice(written);
        }
        start = end;
      }
      await fileIo.fsync(file.fd);
    } finally {
      await fileIo.close(file);
    }
    await fileIo.rename(temporaryPath, path);
  } catch (error) {
    await fileIo.unlink(temporaryPath).catch(() => {});
    throw error as Error;
  }
}

async function syncDirectory(path: string): Promise<void> {
  const directory = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR);
  try {
    await fileIo.fsync(directory.fd);
  } finally {
    await fileIo.close(directory);
  }
}

async function readOptionalText(path: string): Promise<string | undefined> {
  try {
    return await fileIo.readText(path);
  } catch (error) {
    if ((error as BusinessError).code === FILE_NOT_FOUND) {
      return undefined;
    }
    throw error as Error;
  }
}

async function readIndex(directory: string): Promise<SessionIndex | undefined> {
  const value = await readOptionalText(directory + '/' + INDEX_FILE);
  if (value === undefined) {
    return undefined;
  }
  const index = JSON.parse(value) as SessionIndex;
  validateIndex(index);
  return index;
}

async function readIndexedConversation(directory: string, entry: SessionIndexEntry): Promise<NativeConversation> {
  const value = await fileIo.readText(directory + '/' + entry.file);
  if (sessionDigest(value) !== entry.digest) {
    throw new Error('Native conversation checksum does not match');
  }
  const session = JSON.parse(value) as NativeConversation;
  if (!validateConversation(session) || !sameMetadata(entry.metadata, sessionMetadata(session))) {
    throw new Error('Invalid native conversation snapshot');
  }
  const recovered = recoverInterruptedConversation(session);
  stampCommittedSession(directory, recovered, entry);
  return recovered;
}

async function loadIndexedHistory(directory: string, index: SessionIndex): Promise<NativeConversationState> {
  const sessions: NativeConversation[] = [];
  for (const entry of index.sessions) {
    try {
      sessions.push(await readIndexedConversation(directory, entry));
    } catch {
      const metadata = entry.metadata;
      sessions.push({
        id: metadata.id, title: metadata.title, createdAt: metadata.createdAt, updatedAt: metadata.updatedAt,
        pinnedAt: metadata.pinnedAt, rootMessageId: null, messages: [], unreadable: true,
      });
    }
  }
  return { sessions, activeId: index.activeId };
}

function resolveBaseEntries(previous: SessionIndex | undefined, write: HistoryWrite): Map<string, SessionIndexEntry> {
  const existing = new Map<string, SessionIndexEntry>();
  for (const entry of previous?.sessions ?? []) {
    existing.set(entry.metadata.id, entry);
  }
  if (write.incremental && (!previous || existing.size !== write.sessions.length)) {
    throw new Error('Incremental native history requires the complete committed session list');
  }
  for (const session of write.sessions) {
    const entry = existing.get(session.metadata.id);
    if (session.retainsSnapshot) {
      if (!entry || !sameSessionSummary(entry.metadata, session.metadata)) {
        throw new Error('Native conversation reference does not match a committed entry');
      }
    } else if (write.incremental &&
      (!entry || (session.snapshot === undefined && !sameMetadata(entry.metadata, session.metadata)))) {
      throw new Error('Incremental native history omits a changed session');
    }
  }
  return existing;
}

async function commitHistory(filesDir: string, directory: string, previous: SessionIndex | undefined,
  write: HistoryWrite): Promise<SessionIndex> {
  const existing = resolveBaseEntries(previous, write);
  const next: SessionIndex = { version: STORAGE_VERSION, activeId: write.activeId, sessions: [] };
  const created: string[] = [];
  const pendingStamps: PendingCommitStamp[] = [];
  let published = false;
  if (!previous) {
    await ensureNativeDirectory(directory);
    await syncDirectory(filesDir);
  }
  try {
    let lastYieldAt = Date.now();
    const pendingWrites: Promise<void>[] = [];
    const flushPendingWrites = async (): Promise<void> => {
      if (pendingWrites.length === 0) return;
      const batch = pendingWrites.splice(0, pendingWrites.length);
      await Promise.all(batch);
    };
    for (let i = 0; i < write.sessions.length; i++) {
      const session = write.sessions[i];
      const entry = existing.get(session.metadata.id);
      if (session.snapshot === undefined && session.sessionRef === undefined) {
        if (!entry) {
          throw new Error('Missing native session snapshot');
        }
        next.sessions.push(entry);
        continue;
      }
      if (session.snapshot === undefined && session.sessionRef &&
        matchesCommittedStamp(directory, session.sessionRef, entry) && entry) {
        next.sessions.push(entry);
        continue;
      }
      let snapshot = session.snapshot;
      let metadata = session.metadata;
      if (snapshot === undefined) {
        const ref = session.sessionRef;
        if (!ref || !validateConversation(ref)) {
          throw new Error('Invalid native conversation');
        }
        metadata = sessionMetadata(ref);
        snapshot = JSON.stringify(ref);
      }
      // 单遍完成 UTF-8 编码与 SHA-256，复用编码后的字节落盘，避免对每条会话重复 encodeInto。
      const encoded = encodeAndDigestSnapshot(snapshot);
      if (entry?.digest === encoded.digest) {
        next.sessions.push(entry);
        if (session.sessionRef) {
          pendingStamps.push({ session: session.sessionRef, entry });
        }
      } else {
        const file = 'session-' + util.generateRandomUUID(true) + '.json';
        created.push(file);
        const committedEntry: SessionIndexEntry = { metadata, file, digest: encoded.digest };
        next.sessions.push(committedEntry);
        if (session.sessionRef) {
          pendingStamps.push({ session: session.sessionRef, entry: committedEntry });
        }
        if (write.sessions.length > 8) {
          // 批量导入时以受控并发数（6）并发落盘，既把在途缓冲压在 ~240KB 内，又让文件系统合并 fsync 提交。
          pendingWrites.push(writeEncodedChunks(directory + '/' + file, encoded.chunks));
          if (pendingWrites.length >= BULK_WRITE_CONCURRENCY) {
            await flushPendingWrites();
          }
        } else {
          await writeEncodedChunks(directory + '/' + file, encoded.chunks);
        }
      }
      // 及时释放本次序列化快照引用，并定期让出主线程片避免大批量导入提交掉帧。
      session.snapshot = undefined;
      if (write.sessions.length > 8 && Date.now() - lastYieldAt >= 16) {
        await yieldNativeTurn();
        lastYieldAt = Date.now();
      }
    }
    await flushPendingWrites();
    if (previous && previous.activeId === next.activeId && previous.sessions.length === next.sessions.length &&
      next.sessions.every((entry: SessionIndexEntry, index: number): boolean =>
        entry.file === previous.sessions[index].file)) {
      for (const item of pendingStamps) {
        stampCommittedSession(directory, item.session, item.entry);
      }
      return previous;
    }
    if (created.length > 0) {
      await syncDirectory(directory);
    }
    await writeSnapshot(directory + '/' + INDEX_FILE, JSON.stringify(next));
    published = true;
    await syncDirectory(directory);
    for (const item of pendingStamps) {
      stampCommittedSession(directory, item.session, item.entry);
    }
  } catch (error) {
    if (published) {
      // The rename already published this index, so retain both generations.
      clearCommittedIndex(directory);
    } else {
      for (const file of created) {
        await fileIo.unlink(directory + '/' + file).catch(() => {});
      }
    }
    throw error as Error;
  }
  const retained = new Set<string>(next.sessions.map((entry: SessionIndexEntry): string => entry.file));
  for (const entry of previous?.sessions ?? []) {
    if (!retained.has(entry.file)) {
      await fileIo.unlink(directory + '/' + entry.file).catch(() => {});
    }
  }
  return next;
}

async function pruneSessionSnapshots(directory: string, index: SessionIndex): Promise<void> {
  const retained = new Set<string>(index.sessions.map((entry: SessionIndexEntry): string => entry.file));
  const files = await fileIo.listFile(directory).catch((): string[] => []);
  for (const file of files) {
    const candidate = file.endsWith('.tmp') ? file.slice(0, -4) : file;
    if ((RECORD_FILE.test(candidate) && !retained.has(file)) || file === INDEX_FILE + '.tmp') {
      await fileIo.unlink(directory + '/' + file).catch(() => {});
    }
  }
}

function retainedImageIds(path: string, state: NativeConversationState): Set<string> {
  const cached = cachedSessionImages.get(path);
  const next = new Map<string, SessionImageIds>();
  const ids = new Set<string>();
  for (const session of state.sessions) {
    const archive = session.archiveJson;
    if (!archive) {
      continue;
    }
    const known = cached?.get(session.id);
    const images: SessionImageIds = known?.archiveJson === archive ?
      known : { archiveJson: archive, ids: backupImageIds(archive) };
    next.set(session.id, images);
    for (const id of images.ids) {
      ids.add(id);
    }
  }
  cachedSessionImages.set(path, next);
  return ids;
}

function migrateTranscript(messages: NativeStoredMessage[], now: number): NativeConversation {
  const nodes = messages.map((message: NativeStoredMessage): NativeConversationMessage =>
    createConversationMessage(message.role, message.content, message.reasoning, now,
      message.role === 'assistant' ? 'done' : undefined));
  return appendBranch(createConversation(now), null, nodes, now);
}

async function readLegacySnapshot(path: string): Promise<NativeConversationState | undefined> {
  const value = await readOptionalText(path);
  if (value === undefined) {
    return undefined;
  }
  const parsed = JSON.parse(value) as LegacyConversationDocument | NativeStoredMessage[];
  if (!Array.isArray(parsed)) {
    return recoverInterrupted(readLegacyDocument(parsed as LegacyConversationDocument));
  }
  const messages = parsed as NativeStoredMessage[];
  if (!messages.every(isStoredMessage)) {
    throw new Error('Invalid native chat transcript');
  }
  let state: NativeConversationState = { sessions: [], activeId: null };
  if (messages.length > 0) {
    let timestamp = Date.now();
    try {
      timestamp = (await fileIo.stat(path)).mtime * 1_000;
    } catch {
      // The old format did not record timestamps.
    }
    state = upsertConversation(state, migrateTranscript(messages, timestamp), true);
  }
  return state;
}

export class NativeChatStorage {
  loadConversations(context: common.UIAbilityContext, summariesOnly: boolean = false): Promise<NativeConversationState> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const directory = `${context.filesDir}/${HISTORY_DIRECTORY}`;
    return queueStorageOperation<NativeConversationState>(async (): Promise<NativeConversationState> => {
      let index = await readIndex(directory);
      let state: NativeConversationState;
      if (index) {
        await syncDirectory(directory);
        if (summariesOnly) {
          cacheCommittedIndex(directory, index);
          return {
            activeId: index.activeId,
            sessions: index.sessions.map<NativeConversation>((entry: SessionIndexEntry): NativeConversation =>
              unloadedConversation(entry.metadata)),
          };
        }
        state = await loadIndexedHistory(directory, index);
      } else {
        const legacy = await readLegacySnapshot(path);
        state = legacy ?? { sessions: [], activeId: null };
        if (legacy) {
          index = await commitHistory(context.filesDir, directory, undefined, captureHistory(legacy));
        }
      }
      const unreadable = state.sessions.some((session: NativeConversation): boolean => session.unreadable === true);
      if (index) {
        cacheCommittedIndex(directory, index);
        if (!unreadable) {
          await fileIo.unlink(path).catch(() => {});
          await pruneSessionSnapshots(directory, index);
        }
      } else {
        clearCommittedIndex(directory);
      }
      const retained = retainedImageIds(path, state);
      committedImages.set(path, retained);
      if (!unreadable) {
        const protectedImages = new Set<string>(retained);
        for (const scheduled of pendingImageWrites.get(path) ?? []) {
          for (const id of scheduled) {
            protectedImages.add(id);
          }
        }
        await pruneBackupImages(context, protectedImages).catch(() => {});
      }
      return state;
    });
  }

  loadConversation(context: common.UIAbilityContext, id: string,
    useCachedIndex: boolean = false): Promise<NativeConversation> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const directory = `${context.filesDir}/${HISTORY_DIRECTORY}`;
    return queueStorageOperation<NativeConversation>(async (): Promise<NativeConversation> => {
      let entry: SessionIndexEntry | undefined;
      if (useCachedIndex) {
        entry = committedIndexById.get(directory)?.get(id);
      }
      if (!entry) {
        const index = await readIndex(directory);
        if (index && useCachedIndex) {
          cacheCommittedIndex(directory, index);
          entry = committedIndexById.get(directory)?.get(id);
        } else {
          entry = index?.sessions.find((row: SessionIndexEntry): boolean => row.metadata.id === id);
        }
      }
      if (!entry) throw new Error('Native conversation is missing from the index');
      const session = await readIndexedConversation(directory, entry);
      if (!useCachedIndex && session.archiveJson) {
        const retained = committedImages.get(path) ?? new Set<string>();
        for (const id of backupImageIds(session.archiveJson)) retained.add(id);
        committedImages.set(path, retained);
      }
      return session;
    });
  }

  /**
   * 侧边栏全文检索专用批量只读匹配：单次队列入队内按 4 路并发读取不可变快照文件，
   * 先以 O(1) 索引与零漏报原始文本预过滤淘汰绝大多数未命中会话（跳过 SHA-256 / JSON.parse / 整树校验），
   * 仅对命中候选走完整校验与精确匹配。
   */
  searchConversationMatches(context: common.UIAbilityContext, ids: string[], query: string,
    matcher: (session: NativeConversation) => boolean): Promise<string[]> {
    if (ids.length === 0) return Promise.resolve([]);
    const directory = `${context.filesDir}/${HISTORY_DIRECTORY}`;
    const escapeSensitive = JSON_ESCAPE_SENSITIVE_PATTERN.test(query);
    return queueStorageOperation<string[]>(async (): Promise<string[]> => {
      let byId = committedIndexById.get(directory);
      if (!byId) {
        const index = await readIndex(directory);
        if (!index) return [];
        cacheCommittedIndex(directory, index);
        byId = committedIndexById.get(directory);
        if (!byId) return [];
      }
      const matchedIds: string[] = [];
      const checkOne = async (id: string): Promise<void> => {
        const entry = byId?.get(id);
        if (!entry) return;
        let raw: string;
        try {
          raw = await fileIo.readText(directory + '/' + entry.file);
        } catch {
          return;
        }
        if (!escapeSensitive && !raw.toLowerCase().includes(query)) {
          return;
        }
        try {
          if (sessionDigest(raw) !== entry.digest) return;
          const parsed = JSON.parse(raw) as NativeConversation;
          if (!validateConversation(parsed) || !sameMetadata(entry.metadata, sessionMetadata(parsed))) return;
          if (matcher(recoverInterruptedConversation(parsed))) {
            matchedIds.push(id);
          }
        } catch {
          // 单个损坏快照不阻断其余会话检索。
        }
      };
      for (let i = 0; i < ids.length; i += SEARCH_READ_CONCURRENCY) {
        const end = Math.min(i + SEARCH_READ_CONCURRENCY, ids.length);
        const batch: Promise<void>[] = [];
        for (let k = i; k < end; k++) {
          batch.push(checkOne(ids[k]));
        }
        await Promise.all(batch);
      }
      return matchedIds;
    });
  }

  forgetConversationImageCache(context: common.UIAbilityContext, ids: string[]): void {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const cached = cachedSessionImages.get(path);
    for (const id of ids) cached?.delete(id);
  }

  // Pass every modified session ID for a streaming-only checkpoint of an existing history.
  // Full saves also persist additions, deletions, and nested changes outside the active requests.
  async saveConversations(context: common.UIAbilityContext, state: NativeConversationState,
    dirtySessionIds?: string[]): Promise<void> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const directory = `${context.filesDir}/${HISTORY_DIRECTORY}`;
    const write = captureHistory(state, dirtySessionIds);
    const unopened = write.sessions.some((session: SessionWrite): boolean => session.retainsSnapshot === true);
    const retained = retainedImageIds(path, state);
    const pending = pendingImageWrites.get(path) ?? new Set<Set<string>>();
    pending.add(retained);
    pendingImageWrites.set(path, pending);
    try {
      await queueStorageOperation<void>(async (): Promise<void> => {
        let previous = committedIndexes.get(directory);
        if (!previous) {
          previous = await readIndex(directory);
          if (previous) {
            await syncDirectory(directory);
          }
        }
        const next = await commitHistory(context.filesDir, directory, previous, write);
        cacheCommittedIndex(directory, next);
        if (!previous) {
          await fileIo.unlink(path).catch(() => {});
        }
        const prior = committedImages.get(path);
        if ((write.incremental || unopened) && prior) {
          // Preserve known sidecars while any referenced snapshot remains outside this write.
          for (const id of prior) {
            retained.add(id);
          }
        }
        committedImages.set(path, retained);
        if (prior && !unopened) {
          for (const id of prior) {
            if (!retained.has(id) && !Array.from(pending).some((scheduled: Set<string>): boolean => scheduled.has(id))) {
              await removeBackupImage(context, id).catch(() => {});
            }
          }
        }
      });
    } finally {
      pending.delete(retained);
      if (pending.size === 0) {
        pendingImageWrites.delete(path);
      }
    }
  }
}
