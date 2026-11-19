import { common } from '@kit.AbilityKit';
import { url, util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import {
  attachmentMime, attachmentPurpose, attachmentRasterMime, NativeAttachment, NativeChatAttachments,
} from './NativeChatAttachments';
import { NativeChatCitation, NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
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
const MAX_PREVIEW_BYTES = 1024 * 1024;
const MAX_PORTABLE_SOURCES = 256;
const MAX_PORTABLE_CITATIONS = 4_096;
const base64 = new util.Base64Helper();

interface ArchiveManifest {
  export_format_version: number;
}

interface ArchiveFile {
  id: string;
  file_name: string;
  file_size: number;
  token_usage?: number | null;
  inserted_at: string;
  export_path: string | null;
  is_image: boolean;
  width?: number | null;
  height?: number | null;
}

interface ArchiveFragment {
  type: string;
  content?: string;
  elapsed_secs?: number | null;
  files?: ArchiveFile[];
  queries?: string[];
  results?: ArchiveSearchResult[];
  status?: string;
  url?: string | null;
  title?: string | null;
  snippet?: string | null;
  site_name?: string | null;
  published_at?: string | null;
}

interface ArchiveSearchResult {
  url: string;
  title: string;
  snippet: string;
  site_name: string | null;
  site_icon: string | null;
  published_at: string | null;
}

interface ArchiveSourceMetadata {
  version: number;
  sources: NativeChatSource[];
  citations: NativeChatCitation[];
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
  nuwa_harmony_sources?: ArchiveSourceMetadata;
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

interface ArchiveRaster {
  encoded: string;
  data: Uint8Array;
  mimeType: string;
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
      timestamp(file.inserted_at);
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

function sourceString(value: string | null | undefined, limit: number): string {
  return typeof value === 'string' ? value.trim().slice(0, limit) : '';
}

function sourceHost(address: string): string {
  return url.URL.parseURL(address).hostname.replace(/^www\./i, '');
}

function readSourceMetadata(value: ArchiveSourceMetadata | undefined, contentLength: number): ArchiveSourceMetadata | undefined {
  if (!value || value.version !== 1 || !Array.isArray(value.sources) || !Array.isArray(value.citations)) {
    return undefined;
  }
  const sources: NativeChatSource[] = [];
  const indexes = new Set<number>();
  const addresses = new Set<string>();
  for (const item of value.sources.slice(0, MAX_PORTABLE_SOURCES)) {
    const address = safeNativeSourceUrl(item?.url);
    if (!address || !count(item.index) || item.index === 0 || indexes.has(item.index) || addresses.has(address)) {
      continue;
    }
    indexes.add(item.index);
    addresses.add(address);
    sources.push({
      index: item.index,
      url: address,
      title: sourceString(item.title, 320) || address,
      siteName: sourceString(item.siteName, 120) || sourceHost(address),
      snippet: sourceString(item.snippet, 1_600) || null,
      publishedAt: sourceString(item.publishedAt, 120) || null,
      siteIcon: safeNativeSourceUrl(item.siteIcon) || null,
      searchResult: item.searchResult === true,
    });
  }
  const citations = value.citations.slice(0, MAX_PORTABLE_CITATIONS)
    .filter((item: NativeChatCitation): boolean =>
      !!item && count(item.offset) && item.offset <= contentLength && indexes.has(item.sourceIndex))
    .map((item: NativeChatCitation): NativeChatCitation => ({ offset: item.offset, sourceIndex: item.sourceIndex }));
  return sources.length ? { version: 1, sources: sources, citations: citations } : undefined;
}

function addPortableSource(sources: NativeChatSource[], seen: Map<string, NativeChatSource>,
  item: ArchiveSearchResult, searchResult: boolean): void {
  const address = safeNativeSourceUrl(item?.url);
  if (!address) {
    return;
  }
  const host = sourceHost(address);
  const title = sourceString(item.title, 320) || address;
  const siteName = sourceString(item.site_name, 120) || host;
  const snippet = sourceString(item.snippet, 1_600) || null;
  const publishedAt = sourceString(item.published_at, 120) || null;
  const siteIcon = safeNativeSourceUrl(item.site_icon) || null;
  const cached = seen.get(address);
  if (cached) {
    if (cached.title === address) {
      cached.title = title;
    }
    if (cached.siteName === host) {
      cached.siteName = siteName;
    }
    cached.snippet = cached.snippet ?? snippet;
    cached.publishedAt = cached.publishedAt ?? publishedAt;
    cached.siteIcon = cached.siteIcon ?? siteIcon;
    cached.searchResult = cached.searchResult || searchResult;
    return;
  }
  if (sources.length < MAX_PORTABLE_SOURCES) {
    const source: NativeChatSource = {
      index: sources.length + 1, url: address, title: title, siteName: siteName, snippet: snippet,
      publishedAt: publishedAt, siteIcon: siteIcon, searchResult: searchResult,
    };
    sources.push(source);
    seen.set(address, source);
  }
}

function portableSources(message: ArchiveMessage, contentLength: number): ArchiveSourceMetadata | undefined {
  const native = readSourceMetadata(message.nuwa_harmony_sources, contentLength);
  if (native) {
    return native;
  }
  const sources: NativeChatSource[] = [];
  const seen = new Map<string, NativeChatSource>();
  for (const fragment of message.fragments) {
    if (fragment.type === 'TOOL_SEARCH' && Array.isArray(fragment.results)) {
      for (const result of fragment.results) {
        addPortableSource(sources, seen, result, true);
      }
    } else if (fragment.type === 'TOOL_OPEN' && fragment.status === 'FINISHED' && fragment.url) {
      addPortableSource(sources, seen, {
        url: fragment.url, title: fragment.title ?? '', snippet: fragment.snippet ?? '',
        site_name: fragment.site_name ?? null, site_icon: null, published_at: fragment.published_at ?? null,
      }, false);
    }
  }
  return sources.length ? { version: 1, sources: sources, citations: [] } : undefined;
}

function portableSourceDate(value: string | null): string | null {
  const parsed = value ? Date.parse(value) : NaN;
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 253_402_300_799_999) {
    return null;
  }
  return new Date(parsed).toISOString();
}

function appendPortableSources(message: ArchiveMessage, item: NativeConversationMessage): void {
  const metadata: ArchiveSourceMetadata = { version: 1, sources: item.sources ?? [], citations: item.citations ?? [] };
  const validated = readSourceMetadata(metadata, item.content.length);
  message.nuwa_harmony_sources = validated;
  if (!validated || message.fragments.some((fragment: ArchiveFragment): boolean => fragment.type === 'TOOL_SEARCH')) {
    return;
  }
  const results = validated.sources.filter((source: NativeChatSource): boolean => source.searchResult)
    .map((source: NativeChatSource): ArchiveSearchResult => ({
      url: source.url, title: source.title, snippet: source.snippet ?? '', site_name: source.siteName || null,
      site_icon: source.siteIcon, published_at: portableSourceDate(source.publishedAt),
    }));
  if (!results.length) {
    return;
  }
  // The v3 schema has source rows but no inline citation offsets.
  const fragment: ArchiveFragment = { type: 'TOOL_SEARCH', queries: [], results: results, status: 'FINISHED' };
  const responseIndex = message.fragments.findIndex((row: ArchiveFragment): boolean => row.type === 'RESPONSE');
  if (responseIndex < 0) {
    message.fragments.push(fragment);
  } else {
    message.fragments.splice(responseIndex, 0, fragment);
  }
}

function original(session: NativeConversation): ArchiveOrigin | undefined {
  return session.archiveJson ? JSON.parse(session.archiveJson) as ArchiveOrigin : undefined;
}

function archiveRaster(session: NativeConversation, item: NativeAttachment): ArchiveRaster | undefined {
  if (!item.isImage || item.local || item.size > MAX_PREVIEW_BYTES || !session.archiveJson) {
    return undefined;
  }
  try {
    const archive = original(session);
    if (!archive || archive.images.length === 0) {
      return undefined;
    }
    for (const message of archive.session.messages) {
      for (const fragment of message.fragments) {
        if (fragment.type !== 'FILE') {
          continue;
        }
        for (const file of fragment.files ?? []) {
          if (!file.is_image || file.id !== (item.archiveId ?? item.id) ||
            file.file_name !== item.name || !file.export_path) {
            continue;
          }
          const path = backupPath(file.export_path);
          const entry = archive.images.find((image: ArchiveImage): boolean => image.path === path);
          if (!entry || entry.bytes.length > Math.ceil(MAX_PREVIEW_BYTES / 3) * 4) {
            continue;
          }
          const bytes = base64.decodeSync(entry.bytes);
          const mime = attachmentRasterMime(bytes);
          if (mime && bytes.length <= MAX_PREVIEW_BYTES) {
            return { encoded: entry.bytes, data: bytes, mimeType: mime };
          }
        }
      }
    }
  } catch {
    return undefined;
  }
  return undefined;
}

export function importedAttachmentPreview(session: NativeConversation, item: NativeAttachment): string {
  const raster = archiveRaster(session, item);
  return raster ? 'data:' + raster.mimeType + ';base64,' + raster.encoded : '';
}

export async function hydrateImportedAttachment(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): Promise<NativeAttachment | null> {
  const raster = archiveRaster(session, item);
  return raster ? new NativeChatAttachments().storeOriginal(context, item, raster.data, raster.mimeType) : null;
}

function nativeFiles(message: ArchiveMessage): NativeAttachment[] | undefined {
  const result: NativeAttachment[] = [];
  for (const fragment of message.fragments) {
    if (fragment.type !== 'FILE') {
      continue;
    }
    for (const file of fragment.files ?? []) {
      result.push({
        id: file.id,
        name: file.file_name,
        size: file.file_size,
        isImage: file.is_image,
        mimeType: attachmentMime(file.file_name),
        purpose: attachmentPurpose(file.file_name, file.is_image),
        createdAt: timestamp(file.inserted_at),
        serverId: null,
        local: false,
      });
    }
  }
  return result.length > 0 ? result : undefined;
}

function nativeSession(source: ArchiveSession, entries: Map<string, Uint8Array>): NativeConversation {
  validateSummary(source);
  if (!Array.isArray(source.messages) || !count(source.current_message_id)) {
    return invalidArchive();
  }
  const byId = new Map<string, NativeConversationMessage>();
  const imagePaths = new Map<string, string>();
  source.messages.forEach(validateMessage);
  const ordered = source.messages.slice().sort((left: ArchiveMessage, right: ArchiveMessage): number =>
    left.id - right.id);
  const messages: NativeConversationMessage[] = [];
  for (const raw of ordered) {
    raw.fragments.forEach((fragment: ArchiveFragment): void => validateFragment(fragment, source.id, imagePaths));
    const id = raw.id.toString();
    const parentId = raw.parent_id === null ? null : raw.parent_id.toString();
    const parent = parentId === null ? undefined : byId.get(parentId);
    const role = raw.role === 'USER' ? 'user' : 'assistant';
    if (byId.has(id) || (parentId === null ? role !== 'user' : !parent || parent.role === role)) {
      return invalidTree();
    }
    const body = textFragments(raw, role === 'user' ? 'REQUEST' : 'RESPONSE');
    const sources = role === 'assistant' ? portableSources(raw, body.length) : undefined;
    const message: NativeConversationMessage = {
      id: id,
      parentId: parentId,
      role: role,
      content: body,
      reasoning: textFragments(raw, 'THINK'),
      createdAt: timestamp(raw.inserted_at),
      status: role === 'user' ? undefined : nativeStatus(raw.status),
      thinking: role === 'assistant' ? raw.thinking_enabled : undefined,
      search: role === 'assistant' ? raw.search_enabled : undefined,
      sources: sources?.sources,
      citations: sources?.citations,
      files: nativeFiles(raw),
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

function safeFileName(name: string): string {
  const safe = name.replace(/[/\\\0]/g, '_');
  return safe && safe !== '.' && safe !== '..' ? safe : 'unnamed';
}

function outgoingFile(item: NativeAttachment, sessionId: string, originalFiles: Map<string, ArchiveFile>,
  sourceId: string, images: Map<string, Uint8Array>, liveImages: Map<string, Uint8Array>): ArchiveFile {
  const existing = originalFiles.get(item.archiveId ?? item.id);
  if (existing) {
    const retained = JSON.parse(JSON.stringify(existing)) as ArchiveFile;
    if (retained.is_image && retained.export_path) {
      retained.export_path = rewriteImagePath(retained.export_path, sourceId, sessionId);
    }
    return retained;
  }
  let path: string | null = null;
  if (item.isImage && item.local) {
    const bytes = liveImages.get(item.id);
    if (!bytes || bytes.length !== item.size) {
      throw new Error('本地图片原件未能读取：' + item.name);
    }
    path = backupPath(filesPrefix(sessionId) + safeFileName(item.id) + '_' + safeFileName(item.name));
    images.set(path, bytes);
  }
  return {
    id: item.id,
    file_name: item.name,
    file_size: item.size,
    token_usage: null,
    inserted_at: archiveDate(item.createdAt),
    export_path: path,
    is_image: item.isImage,
    width: null,
    height: null,
  };
}

function archiveSession(session: NativeConversation, images: Map<string, Uint8Array>,
  liveImages: Map<string, Uint8Array>): ArchiveSession {
  if (!validId(session.id)) {
    return invalidArchive();
  }
  const previous = original(session);
  const sourceId = previous?.session.id ?? session.id;
  const rawById = new Map<string, ArchiveMessage>();
  const originalFiles = new Map<string, ArchiveFile>();
  if (previous) {
    for (const message of previous.session.messages) {
      rawById.set(message.id.toString(), message);
      for (const fragment of message.fragments) {
        if (fragment.type === 'FILE') {
          for (const file of fragment.files ?? []) {
            originalFiles.set(file.id, JSON.parse(JSON.stringify(file)) as ArchiveFile);
          }
        }
      }
    }
    for (const image of previous.images) {
      const path = rewriteImagePath(image.path, sourceId, session.id);
      images.set(path, base64.decodeSync(image.bytes));
    }
  }
  const ids = new Map<string, number>();
  const roles = new Map<string, string>();
  const firstReplies = new Map<string, NativeConversationMessage>();
  for (const item of session.messages) {
    if (item.role === 'assistant' && item.parentId !== null && !firstReplies.has(item.parentId)) {
      firstReplies.set(item.parentId, item);
    }
  }
  const messages = session.messages.map((item: NativeConversationMessage, index: number): ArchiveMessage => {
    const role = item.role === 'user' ? 'USER' : 'ASSISTANT';
    const parent = item.parentId === null ? null : ids.get(item.parentId);
    if ((item.role !== 'user' && item.role !== 'assistant') || ids.has(item.id) ||
      (item.parentId === null ? role !== 'USER' : parent === undefined || roles.get(item.parentId) === role)) {
      throw new Error('本地对话的消息分支不符合历史备份格式。');
    }
    const preexisting = rawById.get(item.id);
    let message = preexisting;
    if (!message) {
      const request = role === 'ASSISTANT' ? item : firstReplies.get(item.id);
      message = {
        id: index + 1,
        parent_id: parent ?? null,
        role: role,
        status: archiveStatus(item.status),
        thinking_enabled: request?.thinking ?? !!request?.reasoning,
        search_enabled: request?.search ?? false,
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
      if (sourceId !== session.id) {
        for (const fragment of message.fragments) {
          if (fragment.type !== 'FILE') {
            continue;
          }
          for (const file of fragment.files ?? []) {
            if (file.is_image && file.export_path) {
              file.export_path = rewriteImagePath(file.export_path, sourceId, session.id);
            }
          }
        }
      }
    }
    if (role === 'ASSISTANT') {
      message.thinking_enabled = item.thinking ?? message.thinking_enabled;
      message.search_enabled = item.search ?? message.search_enabled;
      updateText(message, 'THINK', item.reasoning);
    }
    updateText(message, role === 'USER' ? 'REQUEST' : 'RESPONSE', item.content);
    if (role === 'ASSISTANT') {
      appendPortableSources(message, item);
    }
    if (!preexisting && item.files?.length) {
      const files = item.files.map((file: NativeAttachment): ArchiveFile =>
        outgoingFile(file, session.id, originalFiles, sourceId, images, liveImages));
      message.fragments.push({ type: 'FILE', files: files });
    }
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

export function encodeChatBackup(sessions: NativeConversation[],
  liveImages: Map<string, Uint8Array> = new Map<string, Uint8Array>()): Uint8Array {
  const manifest: ArchiveManifest = { export_format_version: VERSION };
  const entries = [jsonEntry(MANIFEST, manifest)];
  const images = new Map<string, Uint8Array>();
  const index: ArchiveIndexEntry[] = [];
  for (const session of sessions) {
    const file = archiveSession(session, images, liveImages);
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
  let imageBytes = 0;
  images.forEach((data: Uint8Array, name: string): void => {
    imageBytes += data.length;
    if (imageBytes > MAX_IMAGE_BYTES) {
      throw new Error('图片原件超过 16 MB，无法导出此历史备份。');
    }
    entries.push({ name: name, data: data });
  });
  return writeBackupZip(entries);
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
        if (fragment.type !== 'FILE') {
          continue;
        }
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
    const files = row.files?.map((item: NativeAttachment): string => item.name + ':' + item.size.toString()).join(',') ??
      signatures.get(row.id) ?? '';
    const key = row.role === 'user' ? 'U:' + row.content + '|' + files : 'A:' + row.content;
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

function copyMerged(session: NativeConversation, id: string, title: string, pinnedAt?: number): NativeConversation {
  return {
    id: id,
    title: title,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    pinnedAt: pinnedAt,
    rootMessageId: session.rootMessageId,
    messages: session.messages,
    archiveJson: session.archiveJson,
  };
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
      sessions[index] = copyMerged(incoming, incoming.id, incoming.title, existing.pinnedAt);
      continue;
    }
    sessions[index] = copyMerged(existing, existing.id, withPrefix(existing.title, 'N分支·'), existing.pinnedAt);
    sessions.push(copyMerged(incoming, util.generateRandomUUID(true), withPrefix(incoming.title, 'D分支·')));
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
  private readonly attachments = new NativeChatAttachments();

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
    const images = new Map<string, Uint8Array>();
    let size = 0;
    for (const session of sessions) {
      for (const message of session.messages) {
        for (const file of message.files ?? []) {
          if (!file.isImage || !file.local || file.archiveId || images.has(file.id)) {
            continue;
          }
          size += file.size;
          if (size > MAX_IMAGE_BYTES) {
            throw new Error('图片原件超过 16 MB，无法导出此历史备份。');
          }
          const bytes = await this.attachments.readOriginal(context, file);
          if (!bytes) {
            throw new Error('本地图片原件未能读取：' + file.name);
          }
          images.set(file.id, bytes);
        }
      }
    }
    const bytes = encodeChatBackup(sessions, images);
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
