import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { NativeAttachment } from './NativeChatAttachments';

const DRAFT_FILE = 'nuwa-native-drafts.json';
const STORAGE_VERSION = 1;
const FILE_NOT_FOUND = 13900002;
const MAX_DRAFT_FILES = 50;
const SNAPSHOT_CHUNK_CHARS = 64 * 1024;
const LOCAL_ATTACHMENT_ID = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i;

export interface NativeStoredDraft {
  sessionId: string | null;
  text: string;
  files: NativeAttachment[];
}

interface NativeDraftDocument {
  version: number;
  drafts: NativeStoredDraft[];
}

let pendingStorage: Promise<void> = Promise.resolve();

function queueStorageOperation<T>(operation: () => Promise<T>): Promise<T> {
  const result = pendingStorage.then<T>(operation);
  pendingStorage = result.then<void, void>(() => {}, () => {});
  return result;
}

function validAttachment(item: NativeAttachment): boolean {
  return !!item && typeof item.id === 'string' && !!item.id && typeof item.name === 'string' &&
    Number.isSafeInteger(item.size) && item.size >= 0 && typeof item.isImage === 'boolean' &&
    typeof item.mimeType === 'string' && (item.purpose === null || item.purpose === 'rich_layout_recognition' ||
    item.purpose === 'user_data') && Number.isFinite(item.createdAt) && item.createdAt >= 0 &&
    item.createdAt <= 8_640_000_000_000_000 && (item.serverId === null || typeof item.serverId === 'string') &&
    (item.serverBinding === undefined || typeof item.serverBinding === 'string') &&
    (item.archiveId === undefined || (typeof item.archiveId === 'string' && !!item.archiveId)) &&
    typeof item.local === 'boolean' && (!item.local || LOCAL_ATTACHMENT_ID.test(item.id));
}

function storedAttachment(item: NativeAttachment): NativeAttachment {
  return {
    id: item.id, name: item.name, size: item.size, isImage: item.isImage, mimeType: item.mimeType,
    purpose: item.purpose, createdAt: item.createdAt, serverId: item.serverId, serverBinding: item.serverBinding,
    archiveId: item.archiveId, local: item.local,
  };
}

function normalizeDrafts(drafts: NativeStoredDraft[]): NativeStoredDraft[] {
  const normalized: NativeStoredDraft[] = [];
  const sessionIds = new Set<string | null>();
  for (const draft of drafts) {
    if (!draft || (draft.sessionId !== null && (typeof draft.sessionId !== 'string' || !draft.sessionId)) ||
      sessionIds.has(draft.sessionId) || typeof draft.text !== 'string' || !Array.isArray(draft.files) ||
      draft.files.length > MAX_DRAFT_FILES) {
      throw new Error('Invalid native composer draft');
    }
    sessionIds.add(draft.sessionId);
    const fileIds = new Set<string>();
    for (const file of draft.files) {
      if (!validAttachment(file) || fileIds.has(file.id)) {
        throw new Error('Invalid native composer draft attachment');
      }
      fileIds.add(file.id);
    }
    if (draft.text || draft.files.length > 0) {
      normalized.push({ sessionId: draft.sessionId, text: draft.text, files: draft.files.map(storedAttachment) });
    }
  }
  return normalized;
}

async function readDrafts(path: string): Promise<NativeStoredDraft[]> {
  let raw: string;
  try {
    raw = await fileIo.readText(path);
  } catch (error) {
    if ((error as BusinessError).code === FILE_NOT_FOUND) {
      return [];
    }
    throw error as Error;
  }
  const document = JSON.parse(raw) as NativeDraftDocument;
  if (!document || document.version !== STORAGE_VERSION || !Array.isArray(document.drafts)) {
    throw new Error('Invalid native composer draft file');
  }
  return normalizeDrafts(document.drafts);
}

async function writeDrafts(path: string, snapshot: string): Promise<void> {
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
            throw new Error('Could not write native composer drafts');
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

export class NativeDraftStorage {
  load(context: common.UIAbilityContext): Promise<NativeStoredDraft[]> {
    const path = `${context.filesDir}/${DRAFT_FILE}`;
    return queueStorageOperation(() => readDrafts(path));
  }

  async save(context: common.UIAbilityContext, drafts: NativeStoredDraft[]): Promise<void> {
    const path = `${context.filesDir}/${DRAFT_FILE}`;
    const document: NativeDraftDocument = { version: STORAGE_VERSION, drafts: normalizeDrafts(drafts) };
    const snapshot = JSON.stringify(document);
    return queueStorageOperation(() => writeDrafts(path, snapshot));
  }
}
