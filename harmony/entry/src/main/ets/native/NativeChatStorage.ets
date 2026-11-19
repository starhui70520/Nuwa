import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeChatSource, NativeChatCitation } from './NativeChatSources';
import { fileIo } from '@kit.CoreFileKit';
import { NativeAttachment } from './NativeChatAttachments';
import { NativeReplyFailure } from './NativeReplyNotice';
import { validNativeReadLinks } from './NativeReadLinks';
import { isValidNativeToolTimeline } from './NativeToolTimeline';
import { backupImageIds, pruneBackupImages, removeBackupImage } from './NativeBackupFiles';
import {
  NativeConversation,
  NativeConversationMessage,
  NativeConversationState,
  NativeStoredMessage,
  appendBranch,
  createConversation,
  createConversationMessage,
  upsertConversation,
} from './NativeConversation';

const TRANSCRIPT_FILE = 'nuwa-native-chat.json';
const FILE_NOT_FOUND = 13900002;
const STORAGE_VERSION = 1;
const SNAPSHOT_CHUNK_CHARS = 64 * 1024;

interface NativeConversationDocument extends NativeConversationState {
  version: number;
}

interface SessionImageIds {
  archiveJson: string;
  ids: string[];
}

let pendingStorage: Promise<void> = Promise.resolve();
const cachedSessionImages = new Map<string, Map<string, SessionImageIds>>();
const committedImages = new Map<string, Set<string>>();
const pendingImageWrites = new Map<string, Set<Set<string>>>();

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

function validReplyFailure(failure: NativeReplyFailure): boolean {
  return !!failure && ['network', 'upload', 'response', 'unsupported-image'].includes(failure.kind) &&
    typeof failure.detail === 'string' && failure.detail.length <= 512 &&
    (failure.status === undefined || (Number.isSafeInteger(failure.status) && failure.status >= 100 && failure.status <= 599));
}

function validateConversation(session: NativeConversation): boolean {
  if (!session || typeof session.id !== 'string' || !session.id || typeof session.title !== 'string' ||
    !isTimestamp(session.createdAt) || !isTimestamp(session.updatedAt) ||
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

function readDocument(document: NativeConversationDocument): NativeConversationState {
  if (!document || document.version !== STORAGE_VERSION || !Array.isArray(document.sessions)) {
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
  for (const session of document.sessions) {
    for (const message of session.messages) {
      if (message.status === 'pending' || message.status === 'streaming') {
        message.status = 'stopped';
      }
    }
  }
  return { sessions: document.sessions, activeId: document.activeId };
}

function serialize(state: NativeConversationState): string {
  const document: NativeConversationDocument = {
    version: STORAGE_VERSION,
    sessions: state.sessions,
    activeId: state.activeId,
  };
  return JSON.stringify(document);
}

async function writeSnapshot(path: string, snapshot: string): Promise<void> {
  const temporaryPath = `${path}.tmp`;
  try {
    const file = await fileIo.open(temporaryPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      const encoder = new util.TextEncoder();
      let start = 0;
      while (start < snapshot.length) {
        let end = Math.min(snapshot.length, start + SNAPSHOT_CHUNK_CHARS);
        const last = snapshot.charCodeAt(end - 1);
        if (end < snapshot.length && last >= 0xd800 && last <= 0xdbff) {
          end--;
        }
        let remaining = encoder.encodeInto(snapshot.slice(start, end)).buffer as ArrayBuffer;
        while (remaining.byteLength > 0) {
          const written = await fileIo.write(file.fd, remaining);
          if (written <= 0) {
            throw new Error('Could not write native conversation history');
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

async function readSnapshot(path: string): Promise<NativeConversationState> {
  let value: string;
  try {
    value = await fileIo.readText(path);
  } catch (error) {
    if ((error as BusinessError).code === FILE_NOT_FOUND) {
      return { sessions: [], activeId: null };
    }
    throw error as Error;
  }

  const parsed = JSON.parse(value) as NativeConversationDocument | NativeStoredMessage[];
  if (!Array.isArray(parsed)) {
    return readDocument(parsed as NativeConversationDocument);
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
  await writeSnapshot(path, serialize(state));
  return state;
}

export class NativeChatStorage {
  loadConversations(context: common.UIAbilityContext): Promise<NativeConversationState> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    return queueStorageOperation<NativeConversationState>(async (): Promise<NativeConversationState> => {
      const state = await readSnapshot(path);
      const retained = retainedImageIds(path, state);
      committedImages.set(path, retained);
      await pruneBackupImages(context, retained).catch(() => {});
      return state;
    });
  }

  async saveConversations(context: common.UIAbilityContext, state: NativeConversationState): Promise<void> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const snapshot = serialize(state);
    const retained = retainedImageIds(path, state);
    const pending = pendingImageWrites.get(path) ?? new Set<Set<string>>();
    pending.add(retained);
    pendingImageWrites.set(path, pending);
    try {
      await queueStorageOperation<void>(async (): Promise<void> => {
        await writeSnapshot(path, snapshot);
        const prior = committedImages.get(path);
        committedImages.set(path, retained);
        if (prior) {
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
