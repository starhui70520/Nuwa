import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { NativeAttachment } from './NativeChatAttachments';
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

interface NativeConversationDocument extends NativeConversationState {
  version: number;
}

let pendingStorage: Promise<void> = Promise.resolve();

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
      (message.model !== undefined && typeof message.model !== 'string') ||
      (message.stopReason !== undefined && typeof message.stopReason !== 'string') ||
      (message.canPrefill !== undefined && typeof message.canPrefill !== 'boolean') ||
      (message.thinking !== undefined && typeof message.thinking !== 'boolean') ||
      (message.search !== undefined && typeof message.search !== 'boolean') ||
      (message.thinkingSignature !== undefined && typeof message.thinkingSignature !== 'string') ||
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
      let remaining = new util.TextEncoder().encodeInto(snapshot).buffer as ArrayBuffer;
      while (remaining.byteLength > 0) {
        const written = await fileIo.write(file.fd, remaining);
        if (written <= 0) {
          throw new Error('Could not write native conversation history');
        }
        remaining = remaining.slice(written);
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
    return queueStorageOperation<NativeConversationState>(() => readSnapshot(path));
  }

  async saveConversations(context: common.UIAbilityContext, state: NativeConversationState): Promise<void> {
    const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
    const snapshot = serialize(state);
    await queueStorageOperation<void>(() => writeSnapshot(path, snapshot));
  }
}
