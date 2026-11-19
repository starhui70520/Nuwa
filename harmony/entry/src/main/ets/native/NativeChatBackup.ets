import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { NativeConversation, NativeConversationMessage, NativeConversationState, visibleMessages } from './NativeConversation';
import {
  backupPath, backupText, backupUtf8, MAX_BACKUP_BYTES, NativeBackupZipEntry, readBackupZip, writeBackupZip,
} from './NativeBackupZip';

const MANIFEST = 'manifest.json';
const SESSION_INDEX = 'chat_session_index.json';
const USER = 'user.json';
const VERSION = 3;
const IO_CHUNK = 256 * 1024;
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
const base64 = new util.Base64Helper();

interface ArchiveManifest {
  export_format_version: number;
}

interface ArchiveFile {
  id: string;
  file_name: string;
  file_size: number;
  export_path: string | null;
  is_image: boolean;
}

interface ArchiveFragment {
  type: string;
  content?: string;
  elapsed_secs?: number | null;
  files?: ArchiveFile[];
}

interface ArchiveMessage {
  id: number;
  parent_id: number | null;
  role: string;
  status: string;
  thinking_enabled: boolean;
  search_enabled: boolean;
  accumulated_token_usage: number;
  inserted_at: string;
  fragments: ArchiveFragment[];
}

interface ArchiveSummary {
  id: string;
  title: string | null;
  pinned: boolean;
  inserted_at: string;
  updated_at: string;
}

interface ArchiveSession extends ArchiveSummary {
  current_message_id: number;
  messages: ArchiveMessage[];
}

interface ArchiveIndexEntry extends ArchiveSummary {
  message_count: number;
}

interface ArchiveImage {
  path: string;
  bytes: string;
}

interface ArchiveOrigin {
  session: ArchiveSession;
  images: ArchiveImage[];
}

export interface NativeBackupMergeResult {
  history: NativeConversationState;
  importedCount: number;
}

function invalidArchive(): never {
  throw new Error('历史备份中的会话或索引无效。');
}

function invalidTree(): never {
  throw new Error('历史备份中的对话分支无效。');
}

function invalidImages(): never {
  throw new Error('历史备份中的图片原件没有匹配的附件记录。');
}

function filesPrefix(id: string): string {
  return 'chat_sessions/' + id + '_files/';
}

function sessionPath(id: string): string {
  return 'chat_sessions/' + id + '.json';
}

function validId(id: string): boolean {
  return typeof id === 'string' && !!id && id !== '.' && id !== '..' && id.normalize('NFC') === id &&
    !id.includes('/') && !id.includes('\\') && !id.includes('\0');
}

function count(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function timestamp(value: string): number {
  if (typeof value !== 'string') {
    return invalidArchive();
  }
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?Z$/.exec(value);
  if (!match) {
    return invalidArchive();
  }
  const normalized = match[1] + '.' + (match[2] ?? '').padEnd(3, '0').slice(0, 3) + 'Z';
  const date = new Date(normalized);
  const time = date.getTime();
  if (!count(time) || date.toISOString() !== normalized) {
    return invalidArchive();
  }
  return time;
}

function archiveDate(time: number, previous?: string): string {
  return previous && timestamp(previous) === time ? previous : new Date(time).toISOString();
}

function validateSummary(summary: ArchiveSummary): void {
  if (!summary || !validId(summary.id) || (summary.title !== null && typeof summary.title !== 'string')) {
    invalidArchive();
  }
  timestamp(summary.inserted_at);
  timestamp(summary.updated_at);
}

function validateMessage(message: ArchiveMessage): void {
  if (!message || !count(message.id) || (message.parent_id !== null && !count(message.parent_id)) ||
    (message.role !== 'USER' && message.role !== 'ASSISTANT') ||
    typeof message.thinking_enabled !== 'boolean' || typeof message.search_enabled !== 'boolean' ||
    !count(message.accumulated_token_usage) || !Array.isArray(message.fragments)) {
    invalidArchive();
  }
  nativeStatus(message.status);
  timestamp(message.inserted_at);
}

function nativeStatus(status: string): string {
  switch (status) {
    case 'FINISHED': return 'done';
    case 'INCOMPLETE':
    case 'WIP': return 'stopped';
    case 'CONTENT_FILTER':
    case 'FAILED':
    case 'CONTEXT_LENGTH_EXCEEDED':
    case 'TIMEOUT': return 'error';
    default: return invalidArchive();
  }
}

function archiveStatus(status: string | undefined): string {
  switch (status) {
    case 'pending':
    case 'streaming':
    case 'stopped': return 'INCOMPLETE';
    case 'error': return 'FAILED';
    default: return 'FINISHED';
  }
}

function validateFragment(fragment: ArchiveFragment, sessionId: string, imagePaths: Map<string, string>): void {
  if (!fragment || typeof fragment.type !== 'string') {
    invalidArchive();
  }
  if (fragment.type === 'REQUEST' || fragment.type === 'RESPONSE' || fragment.type === 'THINK' ||
    fragment.type === 'TEMPLATE_RESPONSE') {
    if (typeof fragment.content !== 'string') {
      invalidArchive();
    }
  } else if (fragment.type === 'FILE') {
    if (!Array.isArray(fragment.files)) {
      return invalidArchive();
    }
    for (const file of fragment.files) {
      if (!file || typeof file.id !== 'string' || !file.id || typeof file.file_name !== 'string' ||
        !count(file.file_size) || typeof file.is_image !== 'boolean' ||
        (file.export_path !== null && typeof file.export_path !== 'string')) {
        invalidArchive();
      }
      if (file.is_image && file.export_path) {
        const path = backupPath(file.export_path);
        if (!path.startsWith(filesPrefix(sessionId)) || path.endsWith('/') ||
          (imagePaths.has(path) && imagePaths.get(path) !== file.id)) {
          invalidImages();
        }
        imagePaths.set(path, file.id);
      }
    }
  }
}

function textFragments(message: ArchiveMessage, type: string): string {
  return message.fragments.filter((fragment: ArchiveFragment): boolean => fragment.type === type)
    .map((fragment: ArchiveFragment): string => fragment.content ?? '').join('\n');
}

function original(session: NativeConversation): ArchiveOrigin | undefined {
  return session.archiveJson ? JSON.parse(session.archiveJson) as ArchiveOrigin : undefined;
}

function nativeSession(source: ArchiveSession, entries: Map<string, Uint8Array>): NativeConversation {
  validateSummary(source);
  if (!Array.isArray(source.messages) || !count(source.current_message_id)) {
    return invalidArchive();
  }
  const byId = new Map<string, NativeConversationMessage>();
  const imagePaths = new Map<string, string>();
  const ordered = source.messages.slice().sort((left: ArchiveMessage, right: ArchiveMessage): number =>
    left.id - right.id);
  const messages: NativeConversationMessage[] = [];
  for (const raw of ordered) {
    validateMessage(raw);
    raw.fragments.forEach((fragment: ArchiveFragment): void => validateFragment(fragment, source.id, imagePaths));
    const id = raw.id.toString();
    const parentId = raw.parent_id === null ? null : raw.parent_id.toString();
    const parent = parentId === null ? undefined : byId.get(parentId);
    const role = raw.role === 'USER' ? 'user' : 'assistant';
    if (byId.has(id) || (parentId === null ? role !== 'user' : !parent || parent.role === role)) {
      return invalidTree();
    }
    const message: NativeConversationMessage = {
      id: id,
      parentId: parentId,
      role: role,
      content: textFragments(raw, role === 'user' ? 'REQUEST' : 'RESPONSE'),
      reasoning: textFragments(raw, 'THINK'),
      createdAt: timestamp(raw.inserted_at),
      status: role === 'user' ? undefined : nativeStatus(raw.status),
    };
    if (parent) {
      parent.selectedChildId = id;
    }
    byId.set(id, message);
    messages.push(message);
  }
  let root: string | null = null;
  if (messages.length > 0) {
    let current = byId.get(source.current_message_id.toString());
    if (!current) {
      return invalidTree();
    }
    current.selectedChildId = undefined;
    while (current.parentId !== null) {
      const parent = byId.get(current.parentId);
      if (!parent) {
        return invalidTree();
      }
      parent.selectedChildId = current.id;
      current = parent;
    }
    root = current.id;
  }
  const images: ArchiveImage[] = [];
  for (const path of imagePaths.keys()) {
    const bytes = entries.get(path);
    if (bytes) {
      images.push({ path: path, bytes: base64.encodeToStringSync(bytes) });
      entries.delete(path);
    }
  }
  const retained: ArchiveOrigin = { session: source, images: images };
  return {
    id: source.id,
    title: source.title ?? '',
    createdAt: timestamp(source.inserted_at),
    updatedAt: timestamp(source.updated_at),
    rootMessageId: root,
    messages: messages,
    archiveJson: JSON.stringify(retained),
  };
}

export async function decodeChatBackup(bytes: Uint8Array): Promise<NativeConversation[]> {
  const entries = await readBackupZip(bytes);
  if (entries[0]?.name !== MANIFEST) {
    throw new Error('无法识别历史备份。请选择 DeepSeek 或 Nuwa 的 ZIP 备份。');
  }
  const manifest = JSON.parse(backupText(entries[0].data)) as ArchiveManifest;
  if (manifest?.export_format_version !== VERSION) {
    throw new Error('暂不支持此备份版本，请选择第 3 版历史备份。');
  }
  const sessions: ArchiveSession[] = [];
  const ids = new Set<string>();
  const images = new Map<string, Uint8Array>();
  let imageBytes = 0;
  let index: ArchiveIndexEntry[] | undefined;
  for (let position = 1; position < entries.length; position++) {
    const entry = entries[position];
    const path = entry.name;
    if ((path === USER && !sessions.length && !index) || path === 'yejian_meta.json' || path.startsWith('yejian/')) {
      // The v3 archive can contain account or third-party app metadata.
      continue;
    }
    if (path === SESSION_INDEX) {
      index = JSON.parse(backupText(entry.data)) as ArchiveIndexEntry[];
      if (!Array.isArray(index)) {
        return invalidArchive();
      }
      continue;
    }
    if (/^chat_sessions\/[^/]+\.json$/.test(path) && !index) {
      const session = JSON.parse(backupText(entry.data)) as ArchiveSession;
      if (!session || !validId(session.id) || sessionPath(session.id) !== path || ids.has(session.id)) {
        return invalidArchive();
      }
      sessions.push(session);
      ids.add(session.id);
      continue;
    }
    if (/^chat_sessions\/[^/]+_files\/[^/]/.test(path)) {
      imageBytes += entry.data.length;
      if (imageBytes > MAX_IMAGE_BYTES) {
        throw new Error('图片原件超过 16 MB，无法导入此历史备份。');
      }
      images.set(path, entry.data);
      continue;
    }
    return invalidArchive();
  }
  if (!index || index.length !== sessions.length) {
    return invalidArchive();
  }
  for (const summary of index) {
    validateSummary(summary);
    if (!count(summary.message_count) || !ids.delete(summary.id)) {
      return invalidArchive();
    }
  }
  const imported = sessions.map((session: ArchiveSession): NativeConversation => nativeSession(session, images));
  if (images.size > 0) {
    return invalidImages();
  }
  return imported;
}

function updateText(message: ArchiveMessage, type: string, value: string): void {
  const previous = textFragments(message, type);
  if (value === previous) {
    return;
  }
  if (previous && value.startsWith(previous)) {
    for (let index = message.fragments.length - 1; index >= 0; index--) {
      const fragment = message.fragments[index];
      if (fragment.type === type) {
        fragment.content = (fragment.content ?? '') + value.slice(previous.length);
        return;
      }
    }
  }
  let first = -1;
  for (let index = 0; index < message.fragments.length; index++) {
    const fragment = message.fragments[index];
    if (fragment.type !== type) {
      continue;
    }
    if (first < 0) {
      first = index;
      fragment.content = value;
    } else {
      message.fragments.splice(index--, 1);
    }
  }
  if (first < 0 && value) {
    message.fragments.push({ type: type, content: value, elapsed_secs: type === 'THINK' ? null : undefined });
  }
}

function rewriteImagePath(path: string, source: string, target: string): string {
  const prefix = filesPrefix(source);
  const normalized = backupPath(path);
  if (!normalized.startsWith(prefix)) {
    return invalidImages();
  }
  return filesPrefix(target) + normalized.slice(prefix.length);
}

function archiveSession(session: NativeConversation, images: NativeBackupZipEntry[]): ArchiveSession {
  if (!validId(session.id)) {
    return invalidArchive();
  }
  const previous = original(session);
  const rawById = new Map<string, ArchiveMessage>();
  if (previous) {
    for (const message of previous.session.messages) {
      rawById.set(message.id.toString(), message);
    }
    for (const image of previous.images) {
      const path = rewriteImagePath(image.path, previous.session.id, session.id);
      images.push({ name: path, data: base64.decodeSync(image.bytes) });
    }
  }
  const ids = new Map<string, number>();
  const roles = new Map<string, string>();
  const messages = session.messages.map((item: NativeConversationMessage, index: number): ArchiveMessage => {
    const role = item.role === 'user' ? 'USER' : 'ASSISTANT';
    const parent = item.parentId === null ? null : ids.get(item.parentId);
    if ((item.role !== 'user' && item.role !== 'assistant') || ids.has(item.id) ||
      (item.parentId === null ? role !== 'USER' : parent === undefined || roles.get(item.parentId) === role)) {
      throw new Error('本地对话的消息分支不符合历史备份格式。');
    }
    let message = rawById.get(item.id);
    if (!message) {
      message = {
        id: index + 1,
        parent_id: parent ?? null,
        role: role,
        status: archiveStatus(item.status),
        thinking_enabled: !!item.reasoning,
        search_enabled: false,
        accumulated_token_usage: 0,
        inserted_at: archiveDate(item.createdAt),
        fragments: [],
      };
    } else {
      message.id = index + 1;
      message.parent_id = parent ?? null;
      message.role = role;
      if (role === 'ASSISTANT' && item.status !== nativeStatus(message.status)) {
        message.status = archiveStatus(item.status);
      }
      message.inserted_at = archiveDate(item.createdAt, message.inserted_at);
      if (previous && previous.session.id !== session.id) {
        for (const fragment of message.fragments) {
          for (const file of fragment.files ?? []) {
            if (file.is_image && file.export_path) {
              file.export_path = rewriteImagePath(file.export_path, previous.session.id, session.id);
            }
          }
        }
      }
    }
    if (role === 'ASSISTANT') {
      updateText(message, 'THINK', item.reasoning);
    }
    updateText(message, role === 'USER' ? 'REQUEST' : 'RESPONSE', item.content);
    ids.set(item.id, index + 1);
    roles.set(item.id, role);
    return message;
  });
  const path = visibleMessages(session);
  const current = path[path.length - 1];
  const backup: ArchiveSession = previous?.session ?? {
    id: session.id, title: null, pinned: false, current_message_id: 0, inserted_at: '', updated_at: '', messages: [],
  };
  backup.id = session.id;
  backup.title = session.title || null;
  backup.pinned = backup.pinned ?? false;
  backup.current_message_id = current ? (ids.get(current.id) ?? 0) : 0;
  backup.inserted_at = archiveDate(session.createdAt, backup.inserted_at);
  backup.updated_at = archiveDate(session.updatedAt, backup.updated_at);
  backup.messages = messages;
  return backup;
}

function jsonEntry(name: string, value: Object): NativeBackupZipEntry {
  return { name: name, data: backupUtf8(JSON.stringify(value)) };
}

export function encodeChatBackup(sessions: NativeConversation[]): Uint8Array {
  const manifest: ArchiveManifest = { export_format_version: VERSION };
  const entries = [jsonEntry(MANIFEST, manifest)];
  const images: NativeBackupZipEntry[] = [];
  const index: ArchiveIndexEntry[] = [];
  for (const session of sessions) {
    const file = archiveSession(session, images);
    entries.push(jsonEntry(sessionPath(file.id), file));
    index.push({
      id: file.id,
      title: file.title,
      pinned: file.pinned,
      message_count: file.messages.length,
      inserted_at: file.inserted_at,
      updated_at: file.updated_at,
    });
  }
  entries.push(jsonEntry(SESSION_INDEX, index));
  return writeBackupZip(entries.concat(images));
}

function pathHash(seed: string, text: string): string {
  let first = 0x811c9dc5;
  let second = 0x01000193;
  for (let index = 0; index < seed.length; index++) {
    const code = seed.charCodeAt(index);
    first = Math.imul(first ^ code, 0x01000193);
    second = Math.imul(second ^ (code + 17), 0x85ebca6b);
  }
  first = Math.imul(first ^ 0x3e, 0x01000193);
  second = Math.imul(second ^ 0x3e, 0x85ebca6b);
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    first = Math.imul(first ^ code, 0x01000193);
    second = Math.imul(second ^ (code + 31), 0x85ebca6b);
  }
  return (first >>> 0).toString(16).padStart(8, '0') + (second >>> 0).toString(16).padStart(8, '0');
}

function messagePaths(session: NativeConversation): Set<string> {
  const source = original(session);
  const signatures = new Map<string, string>();
  if (source) {
    for (const row of source.session.messages) {
      if (row.role !== 'USER') {
        continue;
      }
      const files: string[] = [];
      for (const fragment of row.fragments) {
        for (const file of fragment.files ?? []) {
          files.push(file.file_name + ':' + file.file_size.toString());
        }
      }
      signatures.set(row.id.toString(), files.join(','));
    }
  }
  const parents = new Map<string, string>();
  const paths = new Set<string>();
  for (const row of session.messages) {
    const seed = row.parentId === null ? '' : (parents.get(row.parentId) ?? '');
    const key = row.role === 'user' ? 'U:' + row.content + '|' + (signatures.get(row.id) ?? '') : 'A:' + row.content;
    const digest = pathHash(seed, key);
    parents.set(row.id, digest);
    paths.add(digest);
  }
  return paths;
}

function hasNewPath(paths: Set<string>, other: Set<string>): boolean {
  for (const path of paths) {
    if (!other.has(path)) {
      return true;
    }
  }
  return false;
}

function withPrefix(title: string, prefix: string): string {
  return prefix + (title.replace(/^[ND]分支·/, '') || '未命名对话');
}

export function mergeChatBackup(history: NativeConversationState, imported: NativeConversation[]): NativeBackupMergeResult {
  const sessions = history.sessions.slice();
  let total = 0;
  for (const incoming of imported) {
    // A previously diverged import retains the source archive ID and payload.
    if (incoming.archiveJson && sessions.some((stored: NativeConversation): boolean =>
      stored.archiveJson === incoming.archiveJson)) {
      continue;
    }
    const index = sessions.findIndex((stored: NativeConversation): boolean => stored.id === incoming.id);
    if (index < 0) {
      sessions.push(incoming);
      total++;
      continue;
    }
    const existing = sessions[index];
    const localPaths = messagePaths(existing);
    const addedPaths = messagePaths(incoming);
    if (!hasNewPath(addedPaths, localPaths)) {
      continue;
    }
    total++;
    if (!hasNewPath(localPaths, addedPaths)) {
      incoming.pinnedAt = existing.pinnedAt;
      sessions[index] = incoming;
      continue;
    }
    sessions[index] = {
      id: existing.id,
      title: withPrefix(existing.title, 'N分支·'),
      createdAt: existing.createdAt,
      updatedAt: existing.updatedAt,
      pinnedAt: existing.pinnedAt,
      rootMessageId: existing.rootMessageId,
      messages: existing.messages,
      archiveJson: existing.archiveJson,
    };
    incoming.id = util.generateRandomUUID(true);
    incoming.title = withPrefix(incoming.title, 'D分支·');
    sessions.push(incoming);
  }
  return { history: { sessions: sessions, activeId: history.activeId }, importedCount: total };
}

async function readFile(uri: string): Promise<Uint8Array> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const length = (await fileIo.stat(file.fd)).size;
    if (!length || length > MAX_BACKUP_BYTES) {
      throw new Error('历史备份不能为空或超过 64 MB。');
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    while (offset < length) {
      const chunk = new ArrayBuffer(Math.min(IO_CHUNK, length - offset));
      const read = await fileIo.read(file.fd, chunk);
      if (read <= 0) {
        throw new Error('历史备份读取未完成。');
      }
      bytes.set(new Uint8Array(chunk, 0, read), offset);
      offset += read;
    }
    return bytes;
  } finally {
    await fileIo.close(file);
  }
}

async function writeFile(uri: string, bytes: Uint8Array): Promise<void> {
  const file = await fileIo.open(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    let offset = 0;
    while (offset < bytes.length) {
      const chunk = bytes.slice(offset, offset + IO_CHUNK).buffer as ArrayBuffer;
      const written = await fileIo.write(file.fd, chunk);
      if (written <= 0) {
        throw new Error('历史备份写入未完成。');
      }
      offset += written;
    }
    await fileIo.fsync(file.fd);
  } finally {
    await fileIo.close(file);
  }
}

export class NativeChatBackup {
  async importFromUri(uri: string): Promise<NativeConversation[]> {
    return decodeChatBackup(await readFile(uri));
  }

  async importFromPicker(context: common.UIAbilityContext): Promise<NativeConversation[] | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['历史备份|.zip'];
    const selected = await new picker.DocumentViewPicker(context).select(options);
    return selected[0] ? await this.importFromUri(selected[0]) : null;
  }

  async exportToPicker(context: common.UIAbilityContext, sessions: NativeConversation[]): Promise<boolean> {
    const bytes = encodeChatBackup(sessions);
    const options = new picker.DocumentSaveOptions();
    const date = new Date();
    const day = date.getFullYear().toString() + '-' + (date.getMonth() + 1).toString().padStart(2, '0') + '-' +
      date.getDate().toString().padStart(2, '0');
    options.newFileNames = ['deepseek_data-' + day + '.zip'];
    const selected = await new picker.DocumentViewPicker(context).save(options);
    if (!selected[0]) {
      return false;
    }
    await writeFile(selected[0], bytes);
    return true;
  }
}
