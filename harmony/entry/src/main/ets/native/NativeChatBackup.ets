import { common } from '@kit.AbilityKit';
import { url, util } from '@kit.ArkTS';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import {
  attachmentMime, attachmentPurpose, attachmentRasterMime, NativeAttachment, NativeChatAttachments,
} from './NativeChatAttachments';
import { NativeChatCitation, NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
import { NativeConversation, NativeConversationMessage, NativeConversationState, visibleMessages } from './NativeConversation';
import { NativeLocale } from './NativeLocation';
import { describeNativeReplyFailure, nativeRefusalText } from './NativeReplyNotice';
import {
  buildArchivedNativeTimeline, NativeArchiveTimelineFragment, NativeArchiveTimelineResult,
  NativeTimelinePage, NativeTimelinePattern, NativeToolStatus, NativeToolTimelineView,
} from './NativeToolTimeline';
import { NativeReadLink, validNativeReadLinks } from './NativeReadLinks';
import {
  backupPath, backupText, backupUtf8, backupZipChecksum, MAX_BACKUP_BYTES, MAX_BACKUP_ENTRY_BYTES, memoryBackupInput,
  NativeBackupZipEntry, NativeBackupZipInput, NativeBackupZipStreamEntry, NativeBackupZipWriter, readBackupZipEntries,
  readBackupZipEntry, writeBackupZip,
} from './NativeBackupZip';
import {
  backupImagePath, copyBackupFile, removeBackupImage, stageBackupImage, withBackupInput, writeBackupFile,
} from './NativeBackupFiles';

const MANIFEST = 'manifest.json';
const SESSION_INDEX = 'chat_session_index.json';
const USER = 'user.json';
const VERSION = 3;
const MAX_INLINE_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_PREVIEW_BYTES = 1024 * 1024;
const MAX_HYDRATE_BYTES = 16 * 1024 * 1024;
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
  pattern?: string;
}

interface ArchiveSearchResult {
  url?: string;
  title?: string | null;
  snippet?: string;
  site_name?: string | null;
  site_icon?: string | null;
  published_at?: string | null;
  signature?: string;
  nuwa_harmony_binding?: string;
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
  bytes?: string;
  blobId?: string;
  size?: number;
  crc?: number;
  mimeType?: string;
}

interface BackupImageSource {
  retained?: ArchiveImage;
  live?: NativeAttachment;
}

interface ArchiveOrigin {
  session: ArchiveSession;
  images: ArchiveImage[];
}

interface PreparedSession {
  session: NativeConversation;
  origin: ArchiveOrigin;
  imagePaths: string[];
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
    case 'FINISHED':
    case 'CONTENT_FILTER': return 'done';
    case 'INCOMPLETE':
    case 'WIP': return 'stopped';
    case 'FAILED':
    case 'CONTEXT_LENGTH_EXCEEDED':
    case 'TIMEOUT': return 'error';
    default: return invalidArchive();
  }
}

function archiveStatus(status: string | undefined, stopReason?: string): string {
  if (stopReason === 'refusal') return 'CONTENT_FILTER';
  switch (status) {
    case 'pending':
    case 'streaming': return 'WIP';
    case 'stopped': return 'INCOMPLETE';
    case 'error': return 'FAILED';
    default: return stopReason === 'max_tokens' ? 'INCOMPLETE' : 'FINISHED';
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
    .map((fragment: ArchiveFragment): string => fragment.content ?? '').join(type === 'RESPONSE' ? '' : '\n');
}

function importedTimeline(message: ArchiveMessage): NativeToolTimelineView | undefined {
  const fragments = message.fragments.map<NativeArchiveTimelineFragment>((fragment: ArchiveFragment): NativeArchiveTimelineFragment => ({
    type: fragment.type, content: fragment.content, elapsed_secs: fragment.elapsed_secs, status: fragment.status,
    queries: fragment.queries, url: fragment.url, title: fragment.title, pattern: fragment.pattern,
    results: Array.isArray(fragment.results) ? fragment.results.map<NativeArchiveTimelineResult>(
      (result: ArchiveSearchResult): NativeArchiveTimelineResult => ({
        url: result?.url, title: result?.title, signature: result?.signature,
      })) : undefined,
  }));
  const view = buildArchivedNativeTimeline(fragments, message.id.toString());
  return view.steps.length ? { steps: view.steps, answer: '', answerOffset: view.answerOffset,
    thinkingSeconds: view.thinkingSeconds } : undefined;
}

function importedReadLinks(message: ArchiveMessage, textLength: number): NativeReadLink[] | undefined {
  const links: NativeReadLink[] = [];
  let offset = 0;
  for (let index = 0; index < message.fragments.length; index++) {
    const fragment = message.fragments[index];
    if (fragment.type === 'RESPONSE') {
      offset += fragment.content?.length ?? 0;
    }
    if (fragment.type !== 'READ_LINK' || !Array.isArray(fragment.results)) continue;
    for (let resultIndex = 0; resultIndex < fragment.results.length; resultIndex++) {
      const result = fragment.results[resultIndex];
      if (typeof result?.signature !== 'string' || !result.signature.trim()) continue;
      links.push({
        id: `history-${message.id}-${index}-${resultIndex}`, url: safeNativeSourceUrl(result.url),
        title: typeof result.title === 'string' ? result.title.slice(0, 512) : null,
        signature: result.signature, offset, binding: result.nuwa_harmony_binding,
      });
    }
  }
  return links.length > 0 && validNativeReadLinks(links, textLength) ? links : undefined;
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

function searchArchiveRow(source: NativeChatSource): ArchiveSearchResult {
  return {
    url: source.url, title: source.title, snippet: source.snippet ?? '',
    site_name: source.siteName || null, site_icon: source.siteIcon, published_at: portableSourceDate(source.publishedAt),
  };
}

function portableToolStatus(status?: NativeToolStatus): string {
  return status === 'done' ? 'FINISHED' : status === 'failed' ? 'FAILED' : 'WIP';
}

function exportTimeline(message: ArchiveMessage, item: NativeConversationMessage, view: NativeToolTimelineView): void {
  let written = 0;
  let firstThinking = true;
  const appendResponse = (end: number): void => {
    const next = Math.min(item.content.length, Math.max(written, end));
    if (next > written) {
      message.fragments.push({ type: 'RESPONSE', content: item.content.slice(written, next) });
      written = next;
    }
  };
  const sources = new Map<string, NativeChatSource>();
  (item.sources ?? []).forEach((source: NativeChatSource): void => { sources.set(source.url, source); });
  for (const step of view.steps) {
    if (step.type === 'text') {
      appendResponse((step.startOffset ?? written) + (step.text?.length ?? 0));
    } else if (step.type === 'thinking' && step.text) {
      message.fragments.push({ type: 'THINK', content: step.text,
        elapsed_secs: view.thinkingSeconds === undefined ? null : firstThinking ? view.thinkingSeconds : 0 });
      firstThinking = false;
    } else if (step.type === 'search') {
      const results: ArchiveSearchResult[] = [];
      for (const address of step.resultUrls ?? []) {
        const source = sources.get(address);
        if (source) results.push(searchArchiveRow(source));
      }
      message.fragments.push({
        type: 'TOOL_SEARCH', queries: step.queries ?? [], status: portableToolStatus(step.status), results,
      });
    } else if (step.type === 'open') {
      (step.pages ?? []).forEach((page: NativeTimelinePage): void => {
        const site = sources.get(page.url);
        message.fragments.push({
          type: 'TOOL_OPEN', url: page.url || null, title: page.title || null, status: portableToolStatus(page.status),
          snippet: site?.snippet ?? null, site_name: site?.siteName ?? null,
          published_at: portableSourceDate(site?.publishedAt ?? null),
        });
      });
    } else if (step.type === 'find') {
      (step.patterns ?? []).forEach((item: NativeTimelinePattern): void => {
        message.fragments.push({ type: 'TOOL_FIND', pattern: item.pattern, status: portableToolStatus(item.status) });
      });
    }
  }
  appendResponse(item.content.length);
}

function exportReadLinks(message: ArchiveMessage, item: NativeConversationMessage): void {
  const links = item.readLinks ?? [];
  if (!links.length || !validNativeReadLinks(links, item.content.length) ||
    message.fragments.some((fragment: ArchiveFragment): boolean => fragment.type === 'READ_LINK')) {
    return;
  }
  const output: ArchiveFragment[] = [];
  let index = 0;
  let position = 0;
  const writeLink = (link: NativeReadLink): void => {
    output.push({ type: 'READ_LINK', results: [{
      url: link.url || undefined, title: link.title, signature: link.signature, nuwa_harmony_binding: link.binding,
    }] });
  };
  for (const fragment of message.fragments) {
    if (fragment.type !== 'RESPONSE') {
      output.push(fragment);
      continue;
    }
    const text = fragment.content ?? '';
    let cursor = 0;
    while (index < links.length && links[index].offset <= position + text.length) {
      const end = Math.max(cursor, links[index].offset - position);
      if (end > cursor) output.push({ type: 'RESPONSE', content: text.slice(cursor, end) });
      writeLink(links[index++]);
      cursor = end;
    }
    if (cursor < text.length) output.push({ type: 'RESPONSE', content: text.slice(cursor) });
    position += text.length;
  }
  while (index < links.length) writeLink(links[index++]);
  message.fragments = output;
}

function original(session: NativeConversation): ArchiveOrigin | undefined {
  return session.archiveJson ? JSON.parse(session.archiveJson) as ArchiveOrigin : undefined;
}

function retainedImage(session: NativeConversation, item: NativeAttachment): ArchiveImage | undefined {
  if (!item.isImage || item.local || !session.archiveJson) {
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
          const found = archive.images.find((image: ArchiveImage): boolean => image.path === path);
          if (found) {
            return found;
          }
        }
      }
    }
  } catch {
    return undefined;
  }
  return undefined;
}

export function importedAttachmentPreview(session: NativeConversation, item: NativeAttachment,
  context?: common.UIAbilityContext): string {
  const image = retainedImage(session, item);
  if (!image) {
    return '';
  }
  try {
    if (context && image.blobId && image.size !== undefined && image.size <= MAX_HYDRATE_BYTES &&
      ['image/png', 'image/jpeg', 'image/gif', 'image/webp'].includes(image.mimeType ?? '')) {
      return fileUri.getUriFromPath(backupImagePath(context, image.blobId));
    }
    if (image.bytes && image.bytes.length <= Math.ceil(MAX_PREVIEW_BYTES / 3) * 4) {
      const bytes = base64.decodeSync(image.bytes);
      const mime = attachmentRasterMime(bytes);
      if (mime && bytes.length <= MAX_PREVIEW_BYTES) {
        return 'data:' + mime + ';base64,' + image.bytes;
      }
    }
  } catch {
    return '';
  }
  return '';
}

export async function hydrateImportedAttachment(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): Promise<NativeAttachment | null> {
  const image = retainedImage(session, item);
  if (!image || (image.size ?? item.size) > MAX_HYDRATE_BYTES) {
    return null;
  }
  const bytes = image.blobId ? await withBackupInput<Uint8Array>(backupImagePath(context, image.blobId),
    (input: NativeBackupZipInput): Promise<Uint8Array> => {
      if (input.size !== image.size || input.size > MAX_HYDRATE_BYTES) {
        return Promise.reject(new Error('图片原件大小无效。'));
      }
      return input.read(0, input.size);
    }) : (image.bytes && image.bytes.length <= Math.ceil(MAX_HYDRATE_BYTES / 3) * 4 ?
    base64.decodeSync(image.bytes) : new Uint8Array(0));
  if (image.crc !== undefined && backupZipChecksum(bytes) !== image.crc) {
    throw new Error('图片原件校验失败。');
  }
  const mime = attachmentRasterMime(bytes);
  return mime && bytes.length <= MAX_HYDRATE_BYTES ?
    new NativeChatAttachments().storeOriginal(context, item, bytes, mime) : null;
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

function nativeSession(source: ArchiveSession): PreparedSession {
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
    const refused = role === 'assistant' && raw.status === 'CONTENT_FILTER';
    const body = refused ? '' : textFragments(raw, role === 'user' ? 'REQUEST' : 'RESPONSE');
    const sources = role === 'assistant' ? portableSources(raw, body.length) : undefined;
    const message: NativeConversationMessage = {
      id: id,
      parentId: parentId,
      role: role,
      content: body,
      reasoning: refused ? '' : textFragments(raw, 'THINK'),
      createdAt: timestamp(raw.inserted_at),
      status: role === 'user' ? undefined : nativeStatus(raw.status),
      stopReason: refused ? 'refusal' : undefined,
      thinking: role === 'assistant' ? raw.thinking_enabled : undefined,
      search: role === 'assistant' ? raw.search_enabled : undefined,
      sources: sources?.sources,
      citations: sources?.citations,
      toolTimeline: role === 'assistant' && !refused ? importedTimeline(raw) : undefined,
      readLinks: role === 'assistant' && !refused ? importedReadLinks(raw, body.length) : undefined,
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
  const session: NativeConversation = {
    id: source.id,
    title: source.title ?? '',
    createdAt: timestamp(source.inserted_at),
    updatedAt: timestamp(source.updated_at),
    rootMessageId: root,
    messages: messages,
  };
  return {
    session: session, origin: { session: source, images: [] }, imagePaths: Array.from(imagePaths.keys()),
  };
}

export async function decodeChatBackup(bytes: Uint8Array): Promise<NativeConversation[]> {
  return readChatBackup(memoryBackupInput(bytes), undefined, MAX_BACKUP_BYTES);
}

async function readChatBackup(input: NativeBackupZipInput, context?: common.UIAbilityContext,
  limit?: number): Promise<NativeConversation[]> {
  const sessions: PreparedSession[] = [];
  const ids = new Set<string>();
  const wantedImages = new Map<string, ArchiveImage[]>();
  const staged: string[] = [];
  let inlineBytes = 0;
  let manifest = false;
  let index: ArchiveIndexEntry[] | undefined;
  try {
    await readBackupZipEntries(input, async (entry: NativeBackupZipStreamEntry): Promise<void> => {
      const path = entry.name;
      if (!manifest) {
        if (path !== MANIFEST) {
          throw new Error('无法识别历史备份。请选择 DeepSeek 或 Nuwa 的 ZIP 备份。');
        }
        const header = JSON.parse(backupText(await readBackupZipEntry(entry))) as ArchiveManifest;
        if (header?.export_format_version !== VERSION) {
          throw new Error('暂不支持此备份版本，请选择第 3 版历史备份。');
        }
        manifest = true;
        return;
      }
      if ((path === USER && !sessions.length && !index) || path === 'yejian_meta.json' || path.startsWith('yejian/')) {
        return;
      }
      if (path === SESSION_INDEX) {
        index = JSON.parse(backupText(await readBackupZipEntry(entry))) as ArchiveIndexEntry[];
        if (!Array.isArray(index)) {
          invalidArchive();
        }
        return;
      }
      if (/^chat_sessions\/[^/]+\.json$/.test(path) && !index) {
        const original = JSON.parse(backupText(await readBackupZipEntry(entry))) as ArchiveSession;
        if (!original || !validId(original.id) || sessionPath(original.id) !== path || ids.has(original.id)) {
          return invalidArchive();
        }
        const prepared = nativeSession(original);
        sessions.push(prepared);
        ids.add(original.id);
        for (const imagePath of prepared.imagePaths) {
          wantedImages.set(imagePath, prepared.origin.images);
        }
        return;
      }
      const imageOwner = /^chat_sessions\/([^/]+)_files\/[^/]/.exec(path)?.[1];
      if (!imageOwner || (index ? !ids.has(imageOwner) : sessions[sessions.length - 1]?.session.id !== imageOwner)) {
        return invalidArchive();
      }
      const images = wantedImages.get(path);
      if (!images) {
        // Android accepts files in the session directory even when no fragment references them.
        return;
      }
      if (context) {
        const id = await stageBackupImage(context, entry);
        staged.push(id);
        const mimeType = await withBackupInput<string>(backupImagePath(context, id),
          async (file: NativeBackupZipInput): Promise<string> =>
            attachmentRasterMime(await file.read(0, Math.min(file.size, 64 * 1024))));
        images.push({ path: path, blobId: id, size: entry.size, crc: entry.crc, mimeType: mimeType });
      } else {
        inlineBytes += entry.size;
        if (inlineBytes > MAX_INLINE_IMAGE_BYTES) {
          throw new Error('图片原件超过 16 MB，请使用应用中的文件导入。');
        }
        const bytes = await readBackupZipEntry(entry);
        images.push({ path: path, bytes: base64.encodeToStringSync(bytes), size: entry.size, crc: entry.crc });
      }
    }, limit);
    if (!manifest || !index || index.length !== sessions.length) {
      return invalidArchive();
    }
    for (const summary of index) {
      validateSummary(summary);
      if (!count(summary.message_count) || !ids.delete(summary.id)) {
        return invalidArchive();
      }
    }
    return sessions.map((prepared: PreparedSession): NativeConversation => {
      prepared.session.archiveJson = JSON.stringify(prepared.origin);
      return prepared.session;
    });
  } catch (error) {
    if (context) {
      for (const id of staged) {
        await removeBackupImage(context, id);
      }
    }
    throw error as Error;
  }
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
  sourceId: string, images: Map<string, BackupImageSource>): ArchiveFile {
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
    path = backupPath(filesPrefix(sessionId) + safeFileName(item.id) + '_' + safeFileName(item.name));
    images.set(path, { live: item });
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

function archiveSession(session: NativeConversation, images: Map<string, BackupImageSource>,
  locale: NativeLocale = 'zh-CN'): ArchiveSession {
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
      images.set(path, { retained: image });
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
        status: archiveStatus(item.status, item.stopReason),
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
        message.status = archiveStatus(item.status, item.stopReason);
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
      if (!preexisting && item.toolTimeline) {
        exportTimeline(message, item, item.toolTimeline);
      } else {
        updateText(message, 'THINK', item.reasoning);
        updateText(message, 'RESPONSE', item.content);
      }
    } else {
      updateText(message, 'REQUEST', item.content);
    }
    if (role === 'ASSISTANT') {
      appendPortableSources(message, item);
      exportReadLinks(message, item);
      if (!message.fragments.some((fragment: ArchiveFragment): boolean => fragment.type === 'TEMPLATE_RESPONSE')) {
        const notice = item.stopReason === 'refusal' ? nativeRefusalText(locale) :
          item.status === 'error' && item.failure ? describeNativeReplyFailure(item.failure, locale).text : '';
        if (notice) {
          message.fragments.push({ type: 'TEMPLATE_RESPONSE', content: notice });
        }
      }
    }
    if (!preexisting && item.files?.length) {
      const files = item.files.map((file: NativeAttachment): ArchiveFile =>
        outgoingFile(file, session.id, originalFiles, sourceId, images));
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

function summaryEntry(file: ArchiveSession): ArchiveIndexEntry {
  return {
    id: file.id, title: file.title, pinned: file.pinned, message_count: file.messages.length,
    inserted_at: file.inserted_at, updated_at: file.updated_at,
  };
}

export function encodeChatBackup(sessions: NativeConversation[],
  liveImages: Map<string, Uint8Array> = new Map<string, Uint8Array>()): Uint8Array {
  const manifest: ArchiveManifest = { export_format_version: VERSION };
  const entries = [jsonEntry(MANIFEST, manifest)];
  const images = new Map<string, BackupImageSource>();
  const index: ArchiveIndexEntry[] = [];
  for (const session of sessions) {
    const file = archiveSession(session, images);
    entries.push(jsonEntry(sessionPath(file.id), file));
    index.push(summaryEntry(file));
  }
  entries.push(jsonEntry(SESSION_INDEX, index));
  let imageBytes = 0;
  images.forEach((image: BackupImageSource, name: string): void => {
    const data = image.retained?.bytes !== undefined ? base64.decodeSync(image.retained.bytes) :
      liveImages.get(image.retained?.blobId ?? image.live?.id ?? '');
    if (!data || data.length !== (image.live?.size ?? image.retained?.size ?? data.length) ||
      (image.retained?.crc !== undefined && backupZipChecksum(data) !== image.retained.crc)) {
      throw new Error('本地图片原件未能读取：' + (image.live?.name ?? name));
    }
    imageBytes += data.length;
    if (imageBytes > MAX_INLINE_IMAGE_BYTES) {
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

function retainedImageKey(image: ArchiveImage): string {
  if (image.size !== undefined && image.crc !== undefined) {
    return image.size.toString() + ':' + image.crc.toString();
  }
  if (image.bytes !== undefined) {
    const data = base64.decodeSync(image.bytes);
    return data.length.toString() + ':' + backupZipChecksum(data).toString();
  }
  return '';
}

function sameArchiveSource(first: ArchiveOrigin, second: ArchiveOrigin): boolean {
  if (first.images.length !== second.images.length || JSON.stringify(first.session) !== JSON.stringify(second.session)) {
    return false;
  }
  const imageKeys = new Map<string, string>();
  first.images.forEach((image: ArchiveImage): void => { imageKeys.set(image.path, retainedImageKey(image)); });
  return second.images.every((image: ArchiveImage): boolean => imageKeys.get(image.path) === retainedImageKey(image));
}

export function mergeChatBackup(history: NativeConversationState, imported: NativeConversation[]): NativeBackupMergeResult {
  const sessions = history.sessions.slice();
  const priorArchives = new Map<string, ArchiveOrigin[]>();
  for (const stored of sessions) {
    const archive = original(stored);
    if (archive) {
      const sameId = priorArchives.get(archive.session.id) ?? [];
      sameId.push(archive);
      priorArchives.set(archive.session.id, sameId);
    }
  }
  let total = 0;
  for (const incoming of imported) {
    // A previously diverged import retains the source archive ID and payload.
    const source = original(incoming);
    const existingSources = source ? priorArchives.get(source.session.id) : undefined;
    if (source && existingSources?.some((stored: ArchiveOrigin): boolean => sameArchiveSource(stored, source))) {
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

export class NativeChatBackup {
  private readonly attachments = new NativeChatAttachments();

  async importFromUri(uri: string, context?: common.UIAbilityContext): Promise<NativeConversation[]> {
    return withBackupInput<NativeConversation[]>(uri,
      (input: NativeBackupZipInput): Promise<NativeConversation[]> =>
        readChatBackup(input, context, context ? undefined : MAX_BACKUP_BYTES));
  }

  async importFromPicker(context: common.UIAbilityContext, onFileSelected?: () => void): Promise<NativeConversation[] | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['历史备份|.zip'];
    const selected = await new picker.DocumentViewPicker(context).select(options);
    if (!selected[0]) {
      return null;
    }
    onFileSelected?.();
    return this.importFromUri(selected[0], context);
  }

  private async writeImage(context: common.UIAbilityContext, writer: NativeBackupZipWriter, name: string,
    image: BackupImageSource): Promise<void> {
    const retained = image.retained;
    if (retained?.bytes !== undefined) {
      if (retained.bytes.length > Math.ceil(MAX_BACKUP_ENTRY_BYTES / 3) * 4) {
        throw new Error('单个图片原件超过 64 MB。');
      }
      const bytes = base64.decodeSync(retained.bytes);
      const crc = await writer.add(name, memoryBackupInput(bytes));
      if ((retained.size !== undefined && retained.size !== bytes.length) ||
        (retained.crc !== undefined && retained.crc !== crc)) {
        throw new Error('图片原件校验失败。');
      }
      return;
    }
    const live = image.live;
    const uri = retained?.blobId ? backupImagePath(context, retained.blobId) :
      (live ? this.attachments.previewUri(context, live) : '');
    if (!uri) {
      throw new Error('本地图片原件未能读取：' + (live?.name ?? name));
    }
    await withBackupInput<void>(uri, async (input: NativeBackupZipInput): Promise<void> => {
      if (input.size !== (retained?.size ?? live?.size)) {
        throw new Error('图片原件大小无效。');
      }
      const crc = await writer.add(name, input);
      if (retained?.crc !== undefined && retained.crc !== crc) {
        throw new Error('图片原件校验失败。');
      }
    });
  }

  private async writeArchive(context: common.UIAbilityContext, path: string,
    sessions: NativeConversation[], locale: NativeLocale): Promise<void> {
    await writeBackupFile(path, true, async (write: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
      const writer = new NativeBackupZipWriter(write);
      const manifest: ArchiveManifest = { export_format_version: VERSION };
      const images = new Map<string, BackupImageSource>();
      const index: ArchiveIndexEntry[] = [];
      await writer.add(MANIFEST, memoryBackupInput(backupUtf8(JSON.stringify(manifest))));
      for (const session of sessions) {
        const file = archiveSession(session, images, locale);
        await writer.add(sessionPath(file.id), memoryBackupInput(backupUtf8(JSON.stringify(file))));
        index.push(summaryEntry(file));
      }
      await writer.add(SESSION_INDEX, memoryBackupInput(backupUtf8(JSON.stringify(index))));
      for (const name of images.keys()) {
        const image = images.get(name);
        if (image) {
          await this.writeImage(context, writer, name, image);
        }
      }
      await writer.finish();
    });
  }

  async exportToPicker(context: common.UIAbilityContext, sessions: NativeConversation[],
    locale: NativeLocale = 'zh-CN'): Promise<boolean> {
    const options = new picker.DocumentSaveOptions();
    const date = new Date();
    const day = date.getFullYear().toString() + '-' + (date.getMonth() + 1).toString().padStart(2, '0') + '-' +
      date.getDate().toString().padStart(2, '0');
    options.newFileNames = ['deepseek_data-' + day + '.zip'];
    const temporary = (context.cacheDir || context.filesDir) + '/nuwa-backup-' + util.generateRandomUUID(true) + '.zip';
    try {
      await this.writeArchive(context, temporary, sessions, locale);
      const selected = await new picker.DocumentViewPicker(context).save(options);
      if (!selected[0]) {
        return false;
      }
      await copyBackupFile(temporary, selected[0]);
      return true;
    } finally {
      await fileIo.unlink(temporary).catch(() => {});
    }
  }
}
