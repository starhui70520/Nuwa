import { common } from '@kit.AbilityKit';
import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { existingNativeAvifPreview, writeNativeAvifPreview } from './NativeAvifPreview';
import {
  attachmentMime, attachmentPurpose, attachmentRasterMime, attachmentUploadImageMime, fileAttachmentRasterMime,
  isArchiveRasterPreviewMime, NativeAttachment, NativeChatAttachments,
} from './NativeChatAttachments';
import { NativeChatCitation, NativeChatSource, nativeSearchResults, safeNativeSourceUrl } from './NativeChatSources';
import { NativeConversation, NativeConversationMessage, NativeConversationState, visibleMessages } from './NativeConversation';
import { NativeLocale } from './NativeLocation';
import { describeNativeReplyFailure, nativeRefusalText } from './NativeReplyNotice';
import {
  buildArchivedNativeTimeline, NativeArchiveTimelineFragment, NativeArchiveTimelineResult,
  NativeTimelinePage, NativeTimelinePattern, NativeToolStatus, NativeToolTimelineView,
} from './NativeToolTimeline';
import { NativeReadLink, validNativeReadLinks } from './NativeReadLinks';
import { NativePrefillBlock } from './NativeReplyPrefill';
import {
  backupPath, backupUtf8, backupZipChecksum, MAX_BACKUP_BYTES, MAX_BACKUP_ENTRY_BYTES, memoryBackupInput,
  NativeBackupZipEntry, NativeBackupZipInput, NativeBackupZipStreamEntry, NativeBackupZipWriter, readBackupZipEntries,
  readBackupText, readBackupZipEntry, readBackupZipText, writeBackupJson, writeBackupZip,
} from './NativeBackupZip';
import {
  backupAvifPreviewPath, backupImageIds, backupImagePath, copyBackupFile, removeBackupImage, stageBackupBlob,
  stageBackupImageWithHeader, withBackupInput, writeBackupFile,
} from './NativeBackupFiles';
import { isHarmonyLowPerfDevice, yieldNativeTurn } from './NativeDevicePerf';

const MANIFEST = 'manifest.json';
const SESSION_INDEX = 'chat_session_index.json';
const USER = 'user.json';
const VERSION = 3;
const BACKUP_ORIGINAL_NOT_FOUND = 13900002;
export const NATIVE_BACKUP_UNREADABLE_CONVERSATION = 'NATIVE_BACKUP_UNREADABLE_CONVERSATION';
const MAX_INLINE_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_PREVIEW_BYTES = 1024 * 1024;
const MAX_EMBEDDED_ARCHIVE_BYTES = 16 * 1024 * 1024;
const MAX_EMBEDDED_ARCHIVE_BYTES_LOW_PERF = 2 * 1024 * 1024;
const ARCHIVE_TEXT_READ_CHUNK = 256 * 1024;
const MAX_PORTABLE_SOURCES = 256;
const MAX_PORTABLE_CITATIONS = 4_096;
const SESSION_PATH_PATTERN = /^chat_sessions\/[^/]+\.json$/;
const IMAGE_OWNER_PATTERN = /^chat_sessions\/([^/]+)_files\/[^/]/;
const DAYS_IN_MONTH: number[] = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
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
  nuwa_harmony_responses_before?: number;
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
  softwareAvifPreview?: boolean;
}

interface ArchivePreviewInfo {
  mimeType: string;
  softwareAvifPreview?: boolean;
}

interface BackupImageSource {
  retained?: ArchiveImage;
  live?: NativeAttachment;
}

interface ArchiveOrigin {
  session: ArchiveSession;
  images: ArchiveImage[];
  source?: ArchiveSourceReference;
}

interface ArchiveSourceReference {
  blobId: string;
  size: number;
  digest: string;
}

interface PreparedSession {
  session: NativeConversation;
  origin?: ArchiveOrigin;
  imagePaths: Map<string, string>;
  hasImageFiles: boolean;
  fragmentsModified: boolean;
  archiveSize: number;
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

function digit2(value: string, offset: number): number {
  const a = value.charCodeAt(offset) - 48;
  const b = value.charCodeAt(offset + 1) - 48;
  return (a | b) < 0 || a > 9 || b > 9 ? -1 : a * 10 + b;
}

function digit4(value: string, offset: number): number {
  const hi = digit2(value, offset);
  const lo = digit2(value, offset + 2);
  return hi < 0 || lo < 0 ? -1 : hi * 100 + lo;
}

function parseArchiveTime(value: string): number | undefined {
  if (typeof value !== 'string') return undefined;
  const len = value.length;
  if (len < 20 || value.charCodeAt(4) !== 45 || value.charCodeAt(7) !== 45 ||
    value.charCodeAt(10) !== 84 || value.charCodeAt(13) !== 58 ||
    value.charCodeAt(16) !== 58 || value.charCodeAt(len - 1) !== 90) {
    return undefined;
  }
  let ms = 0;
  if (len === 20) {
    // No fractional seconds.
  } else if (len >= 22 && value.charCodeAt(19) === 46) {
    for (let i = 20; i < len - 1; i++) {
      const c = value.charCodeAt(i);
      if (c < 48 || c > 57) return undefined;
    }
    const fracLen = len - 21;
    const d1 = value.charCodeAt(20) - 48;
    const d2 = fracLen > 1 ? value.charCodeAt(21) - 48 : 0;
    const d3 = fracLen > 2 ? value.charCodeAt(22) - 48 : 0;
    ms = d1 * 100 + d2 * 10 + d3;
  } else {
    return undefined;
  }
  const year = digit4(value, 0);
  const month = digit2(value, 5);
  const day = digit2(value, 8);
  const hour = digit2(value, 11);
  const minute = digit2(value, 14);
  const second = digit2(value, 17);
  if (year < 1970 || month < 1 || month > 12 || hour < 0 || hour > 23 ||
    minute < 0 || minute > 59 || second < 0 || second > 59) {
    return undefined;
  }
  let maxDay = DAYS_IN_MONTH[month];
  if (month === 2 && ((year % 4 === 0 && year % 100 !== 0) || year % 400 === 0)) {
    maxDay = 29;
  }
  if (day < 1 || day > maxDay) return undefined;
  const time = Date.UTC(year, month - 1, day, hour, minute, second, ms);
  return count(time) ? time : undefined;
}

function timestamp(value: string): number {
  return parseArchiveTime(value) ?? invalidArchive();
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

function validArchiveFile(file: ArchiveFile): boolean {
  return !!file && typeof file.id === 'string' && !!file.id && typeof file.file_name === 'string' &&
    count(file.file_size) && typeof file.is_image === 'boolean' &&
    (file.export_path === null || typeof file.export_path === 'string') &&
    parseArchiveTime(file.inserted_at) !== undefined &&
    (file.token_usage == null || count(file.token_usage)) &&
    (file.width == null || count(file.width)) && (file.height == null || count(file.height));
}

function readableArchiveFragment(fragment: ArchiveFragment): boolean {
  if (!fragment || typeof fragment.type !== 'string') return false;
  switch (fragment.type) {
    case 'REQUEST':
    case 'RESPONSE':
    case 'TEMPLATE_RESPONSE':
      return typeof fragment.content === 'string';
    case 'THINK':
      return typeof fragment.content === 'string' &&
        (fragment.elapsed_secs == null || Number.isFinite(fragment.elapsed_secs));
    case 'FILE':
      return Array.isArray(fragment.files) && fragment.files.every(validArchiveFile);
    default:
      return true;
  }
}

function forEachArchiveImageFile(message: ArchiveMessage, visit: (file: ArchiveFile) => void): void {
  for (const fragment of message.fragments) {
    if (fragment.type !== 'FILE') continue;
    for (const file of fragment.files ?? []) {
      if (file.is_image) visit(file);
    }
  }
}

function registerArchiveImages(message: ArchiveMessage, sessionId: string, imagePaths: Map<string, string>): void {
  forEachArchiveImageFile(message, (file: ArchiveFile): void => {
    if (file.export_path === null) return;
    const path = backupPath(file.export_path);
    if (!path.startsWith(filesPrefix(sessionId)) || path.endsWith('/') ||
      (imagePaths.has(path) && imagePaths.get(path) !== file.id)) {
      invalidImages();
    }
    imagePaths.set(path, file.id);
  });
}

function archiveImagePaths(session: ArchiveSession): Map<string, string> {
  const paths = new Map<string, string>();
  for (const message of session.messages) registerArchiveImages(message, session.id, paths);
  return paths;
}

function archiveImagesById(origin: ArchiveOrigin, paths: Map<string, string>): Map<string, ArchiveImage> {
  const images = new Map<string, ArchiveImage>();
  for (const image of origin.images) {
    const id = paths.get(image.path);
    if (id && !images.has(id)) images.set(id, image);
  }
  return images;
}

let recentTemplateArchive = '';
const recentArchiveTemplates = new Map<string, string>();

function textFragments(message: ArchiveMessage, type: string): string {
  return message.fragments.filter((fragment: ArchiveFragment): boolean => fragment.type === type)
    .map((fragment: ArchiveFragment): string => fragment.content ?? '')
    .join(type === 'RESPONSE' || type === 'TEMPLATE_RESPONSE' ? '' : '\n');
}

export function nativeArchivedReplyTemplate(session: NativeConversation, messageId: string): string | undefined {
  if (!session.archiveJson) return undefined;
  if (recentTemplateArchive !== session.archiveJson) {
    recentTemplateArchive = session.archiveJson;
    recentArchiveTemplates.clear();
    try {
      const origin = JSON.parse(session.archiveJson) as ArchiveOrigin;
      for (const message of origin.session.messages) {
        if (message.fragments.some((fragment: ArchiveFragment): boolean => fragment.type === 'TEMPLATE_RESPONSE')) {
          recentArchiveTemplates.set(message.id.toString(), textFragments(message, 'TEMPLATE_RESPONSE'));
        }
      }
    } catch {
      recentArchiveTemplates.clear();
    }
  }
  return recentArchiveTemplates.get(messageId);
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

function importedPrefillBlocks(message: ArchiveMessage, refused: boolean): NativePrefillBlock[] | undefined {
  if (refused) return undefined;
  const blocks: NativePrefillBlock[] = [];
  for (const fragment of message.fragments) {
    if (fragment.type === 'RESPONSE' && typeof fragment.content === 'string') {
      blocks.push({ type: 'text', text: fragment.content });
    } else if (fragment.type === 'THINK' && typeof fragment.content === 'string') {
      blocks.push({ type: 'thinking', text: fragment.content });
    } else if (fragment.type === 'TOOL_SEARCH' || fragment.type === 'TOOL_FIND' ||
      (fragment.type === 'TOOL_OPEN' && !!safeNativeSourceUrl(fragment.url)) ||
      (fragment.type === 'READ_LINK' && Array.isArray(fragment.results) && fragment.results.some(
        (result: ArchiveSearchResult): boolean => !!safeNativeSourceUrl(result?.url) ||
          (typeof result?.signature === 'string' && !!result.signature.trim())))) {
      // Android turns these recognized fragments into non-text ReplyBlocks. Preserve
      // their boundary while omitting the historical tool payload from text prefill.
      blocks.push({ type: 'separator', text: '' });
    }
  }
  return blocks;
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
      searchOrder: item.searchOrder !== undefined && count(item.searchOrder) ? item.searchOrder : undefined,
    });
  }
  const citations = value.citations.slice(0, MAX_PORTABLE_CITATIONS)
    .filter((item: NativeChatCitation): boolean =>
      !!item && count(item.offset) && item.offset <= contentLength && indexes.has(item.sourceIndex))
    .map((item: NativeChatCitation): NativeChatCitation => ({ offset: item.offset, sourceIndex: item.sourceIndex }));
  return sources.length ? { version: 1, sources: sources, citations: citations } : undefined;
}

function addPortableSource(sources: NativeChatSource[], seen: Map<string, NativeChatSource>,
  item: ArchiveSearchResult, searchOrder?: number): void {
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
    cached.searchOrder = cached.searchOrder ?? searchOrder;
    cached.searchResult = cached.searchOrder !== undefined;
    return;
  }
  if (sources.length < MAX_PORTABLE_SOURCES) {
    const source: NativeChatSource = {
      index: sources.length + 1, url: address, title: title, siteName: siteName, snippet: snippet,
      publishedAt: publishedAt, siteIcon: siteIcon, searchResult: searchOrder !== undefined, searchOrder: searchOrder,
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
  let searchOrder = 0;
  for (const fragment of message.fragments) {
    if (fragment.type === 'TOOL_SEARCH' && Array.isArray(fragment.results)) {
      for (const result of fragment.results) {
        addPortableSource(sources, seen, result, searchOrder);
        searchOrder += 1;
      }
    } else if (fragment.type === 'TOOL_OPEN' && fragment.status === 'FINISHED' && fragment.url) {
      addPortableSource(sources, seen, {
        url: fragment.url, title: fragment.title ?? '', snippet: fragment.snippet ?? '',
        site_name: fragment.site_name ?? null, site_icon: null, published_at: fragment.published_at ?? null,
      });
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
  const results = nativeSearchResults(validated.sources)
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

function archivePayloadDigest(origin: ArchiveOrigin): string {
  if (origin.source) return origin.source.digest;
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: backupUtf8(JSON.stringify(origin.session)) });
  return base64.encodeToStringSync(digest.digestSync().data);
}

function retainedArchiveFragments(fragments: ArchiveFragment[]): ArchiveFragment[] {
  const retained: ArchiveFragment[] = [];
  let responses = 0;
  for (const fragment of fragments) {
    if (fragment.type === 'RESPONSE') responses++;
    else if (fragment.type === 'FILE') retained.push(fragment);
    else if (fragment.type === 'TEMPLATE_RESPONSE') {
      retained.push({ type: 'TEMPLATE_RESPONSE', content: fragment.content, nuwa_harmony_responses_before: responses });
    }
  }
  return retained;
}

async function retainArchiveOrigin(origin: ArchiveOrigin, archiveSize: number, context: common.UIAbilityContext,
  staged: string[]): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  let size = 0;
  const blobId = await stageBackupBlob(context, archiveSize,
    (write: (chunk: Uint8Array) => Promise<void>): Promise<void> =>
      writeBackupJson(origin.session, async (chunk: Uint8Array): Promise<void> => {
        digest.updateSync({ data: chunk });
        size += chunk.byteLength;
        await write(chunk);
      }));
  staged.push(blobId);
  // Keep only the fragments needed for inline previews and merge when the full source is on disk.
  const metadata: ArchiveSession = {
    id: origin.session.id, title: origin.session.title, pinned: origin.session.pinned,
    inserted_at: origin.session.inserted_at, updated_at: origin.session.updated_at,
    current_message_id: origin.session.current_message_id,
    messages: origin.session.messages.map((message: ArchiveMessage): ArchiveMessage => {
      return {
        id: message.id, parent_id: message.parent_id, role: message.role, status: message.status,
        thinking_enabled: message.thinking_enabled, search_enabled: message.search_enabled,
        accumulated_token_usage: message.accumulated_token_usage, inserted_at: message.inserted_at,
        fragments: retainedArchiveFragments(message.fragments),
      };
    }),
  };
  const record: ArchiveOrigin = { session: metadata, images: origin.images,
    source: { blobId: blobId, size: size, digest: base64.encodeToStringSync(digest.digestSync().data) } };
  return JSON.stringify(record);
}

async function loadArchiveOrigin(context: common.UIAbilityContext, session: NativeConversation): Promise<ArchiveOrigin | undefined> {
  const metadata = original(session);
  const source = metadata?.source;
  if (!metadata || !source) return metadata;
  const path = backupImagePath(context, source.blobId);
  const digest = cryptoFramework.createMd('SHA256');
  return withBackupInput<ArchiveOrigin>(path, async (input: NativeBackupZipInput): Promise<ArchiveOrigin> => {
    if (input.size !== source.size) return invalidArchive();
    const text = await readBackupText(input.size, async (write: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
      for (let offset = 0; offset < input.size; offset += ARCHIVE_TEXT_READ_CHUNK) {
        const bytes = await input.read(offset, Math.min(input.size - offset, ARCHIVE_TEXT_READ_CHUNK));
        digest.updateSync({ data: bytes });
        await write(bytes);
      }
    });
    if (base64.encodeToStringSync(digest.digestSync().data) !== source.digest) return invalidArchive();
    const archived = JSON.parse(text) as ArchiveSession;
    if (archived?.id !== metadata.session.id) return invalidArchive();
    const images = archiveImagesById(metadata, archiveImagePaths(metadata.session));
    // Image aliases repaired by a later import live in the current metadata.
    if (images.size) {
      for (const message of archived.messages) {
        forEachArchiveImageFile(message, (file: ArchiveFile): void => {
          if (!file.export_path) file.export_path = images.get(file.id)?.path ?? null;
        });
      }
    }
    return { session: archived, images: metadata.images };
  });
}

function retainedImage(session: NativeConversation, item: NativeAttachment): ArchiveImage | undefined {
  if (!item.isImage || !session.archiveJson) {
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
    if (context && image.blobId && image.size !== undefined && image.size > 0) {
      const originalPath = backupImagePath(context, image.blobId);
      if (isArchiveRasterPreviewMime(image.mimeType ?? '')) {
        return fileUri.getUriFromPath(originalPath);
      }
      const preview = existingNativeAvifPreview(originalPath);
      if (preview) return fileUri.getUriFromPath(preview);
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

export function importedAttachmentOriginalPath(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): string {
  const image = retainedImage(session, item);
  try {
    return image?.blobId ? backupImagePath(context, image.blobId) : '';
  } catch {
    return '';
  }
}

export function importedAttachmentOriginalUri(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): string {
  try {
    const path = importedAttachmentOriginalPath(context, session, item);
    return path ? fileUri.getUriFromPath(path) : '';
  } catch {
    return '';
  }
}

async function fileBackedPreviewInfo(path: string): Promise<ArchivePreviewInfo> {
  return withBackupInput<ArchivePreviewInfo>(path, async (file: NativeBackupZipInput): Promise<ArchivePreviewInfo> => {
    const header = await file.read(0, Math.min(file.size, 64 * 1024));
    const mimeType = await fileAttachmentRasterMime(path, header);
    const softwareAvifPreview = !mimeType && attachmentUploadImageMime(header) === 'image/avif';
    return { mimeType: mimeType, softwareAvifPreview: softwareAvifPreview || undefined };
  });
}

export async function resolveImportedAttachmentPreview(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): Promise<string> {
  const retained = retainedImage(session, item);
  if (!retained?.blobId || !retained.size) return '';
  try {
    const path = backupImagePath(context, retained.blobId);
    const info = await fileBackedPreviewInfo(path);
    if (info.mimeType) return fileUri.getUriFromPath(path);
    if (!info.softwareAvifPreview) return '';
    const preview = backupAvifPreviewPath(context, retained.blobId);
    return await writeNativeAvifPreview(path, preview) ? fileUri.getUriFromPath(preview) : '';
  } catch {
    return '';
  }
}

export async function hydrateImportedAttachment(context: common.UIAbilityContext, session: NativeConversation,
  item: NativeAttachment): Promise<NativeAttachment | null> {
  if (item.local) return null;
  const image = retainedImage(session, item);
  if (!image) return null;
  const store = async (input: NativeBackupZipInput, checksum?: number): Promise<NativeAttachment | null> => {
    if (image.size !== undefined && input.size !== image.size) {
      throw new Error('图片原件大小无效。');
    }
    if (input.size === 0) return null;
    // Upload detection is independent of the inline preview's stricter format and dimension checks.
    const mime = attachmentUploadImageMime(await input.read(0, Math.min(input.size, 16)));
    return new NativeChatAttachments().storeOriginal(context, item, input, mime, checksum);
  };
  if (image.blobId) {
    return withBackupInput<NativeAttachment | null>(backupImagePath(context, image.blobId),
      (input: NativeBackupZipInput): Promise<NativeAttachment | null> => store(input, image.crc));
  }
  if (!image.bytes || image.bytes.length > Math.ceil(MAX_INLINE_IMAGE_BYTES / 3) * 4) return null;
  const bytes = base64.decodeSync(image.bytes);
  if (image.crc !== undefined && backupZipChecksum(bytes) !== image.crc) {
    throw new Error('图片原件校验失败。');
  }
  return store(memoryBackupInput(bytes));
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

function nativeSession(source: ArchiveSession, archiveSize: number): PreparedSession {
  validateSummary(source);
  if (!Array.isArray(source.messages) || !count(source.current_message_id)) {
    return invalidArchive();
  }
  const byId = new Map<string, NativeConversationMessage>();
  const imagePaths = new Map<string, string>();
  let hasImageFiles = false;
  let fragmentsModified = false;
  let alreadySorted = true;
  for (let i = 0; i < source.messages.length; i++) {
    validateMessage(source.messages[i]);
    if (i > 0 && source.messages[i - 1].id > source.messages[i].id) {
      alreadySorted = false;
    }
  }
  const ordered = alreadySorted ? source.messages :
    source.messages.slice().sort((left: ArchiveMessage, right: ArchiveMessage): number => left.id - right.id);
  const messages: NativeConversationMessage[] = [];
  for (const raw of ordered) {
    // A malformed content fragment must not hide otherwise usable messages in this session.
    const prevFragCount = raw.fragments.length;
    const filteredFrags = raw.fragments.filter(readableArchiveFragment);
    if (filteredFrags.length !== prevFragCount) {
      raw.fragments = filteredFrags;
      fragmentsModified = true;
    }
    forEachArchiveImageFile(raw, (): void => { hasImageFiles = true; });
    registerArchiveImages(raw, source.id, imagePaths);
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
      prefillBlocks: role === 'assistant' ? importedPrefillBlocks(raw, refused) : undefined,
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
    session: session, origin: { session: source, images: [] }, imagePaths: imagePaths,
    hasImageFiles: hasImageFiles, fragmentsModified: fragmentsModified, archiveSize: archiveSize,
  };
}

function addImageAlias(origin: ArchiveOrigin, image: ArchiveImage, path: string): void {
  origin.images.push({ path: path, blobId: image.blobId, bytes: image.bytes, size: image.size,
    crc: image.crc, mimeType: image.mimeType, softwareAvifPreview: image.softwareAvifPreview });
}

function restoreArchiveImages(origin: ArchiveOrigin, imagePaths: Map<string, string>, images: Map<string, ArchiveImage>): boolean {
  const localImages = archiveImagesById(origin, imagePaths);
  const retainedPaths = new Set(origin.images.map((image: ArchiveImage): string => image.path));
  const availablePaths = new Map<string, string>();
  let restored = false;
  imagePaths.forEach((id: string, path: string): void => {
    if (retainedPaths.has(path)) {
      availablePaths.set(id, path);
      return;
    }
    const image = localImages.get(id) ?? images.get(id);
    if (!image) return;
    addImageAlias(origin, image, path);
    availablePaths.set(id, path);
    restored = true;
  });
  for (const message of origin.session.messages) {
    forEachArchiveImageFile(message, (file: ArchiveFile): void => {
      if (file.export_path) return;
      let path = availablePaths.get(file.id);
      if (!path) {
        const image = images.get(file.id);
        if (!image) return;
        const base = filesPrefix(origin.session.id) + safeFileName(file.id) + '_' + safeFileName(file.file_name);
        path = backupPath(base);
        let suffix = 1;
        while (imagePaths.has(path)) {
          path = backupPath(base + '_' + suffix++);
        }
        imagePaths.set(path, file.id);
        availablePaths.set(file.id, path);
        addImageAlias(origin, image, path);
      }
      file.export_path = path;
      restored = true;
    });
  }
  return restored;
}

export async function decodeChatBackup(bytes: Uint8Array): Promise<NativeConversation[]> {
  return readChatBackup(memoryBackupInput(bytes), undefined, MAX_BACKUP_BYTES);
}

async function readChatBackup(input: NativeBackupZipInput, context?: common.UIAbilityContext,
  limit?: number, onVerified?: () => Promise<void>,
  onProgress?: (sessions: number, images: number) => void): Promise<NativeConversation[]> {
  const sessions: PreparedSession[] = [];
  const ids = new Set<string>();
  const wantedImages = new Map<string, string>();
  const loadedImages = new Map<string, ArchiveImage>();
  const staged: string[] = [];
  const embeddedArchiveLimit = isHarmonyLowPerfDevice() ?
    MAX_EMBEDDED_ARCHIVE_BYTES_LOW_PERF : MAX_EMBEDDED_ARCHIVE_BYTES;
  let inlineBytes = 0;
  let manifest = false;
  let index: ArchiveIndexEntry[] | undefined;
  let lastProgressAt = 0;
  const emitProgress = (force: boolean = false): void => {
    if (!onProgress) return;
    const now = Date.now();
    if (force || now - lastProgressAt >= 100) {
      lastProgressAt = now;
      onProgress(sessions.length, loadedImages.size);
    }
  };
  try {
    await readBackupZipEntries(input, async (entry: NativeBackupZipStreamEntry): Promise<void> => {
      const path = entry.name;
      if (!manifest) {
        if (path !== MANIFEST) {
          throw new Error('无法识别历史备份。请选择 DeepSeek 或 Nuwa 的 ZIP 备份。');
        }
        const header = JSON.parse(await readBackupZipText(entry)) as ArchiveManifest;
        if (header?.export_format_version !== VERSION) {
          throw new Error('暂不支持此备份版本，请选择第 3 版历史备份。');
        }
        manifest = true;
        await onVerified?.();
        return;
      }
      if ((path === USER && !sessions.length && !index) || path === 'yejian_meta.json' || path.startsWith('yejian/')) {
        return;
      }
      if (path === SESSION_INDEX) {
        index = JSON.parse(await readBackupZipText(entry)) as ArchiveIndexEntry[];
        if (!Array.isArray(index)) {
          invalidArchive();
        }
        return;
      }
      if (SESSION_PATH_PATTERN.test(path) && !index) {
        const rawText = await readBackupZipText(entry);
        const original = JSON.parse(rawText) as ArchiveSession;
        if (!original || !validId(original.id) || sessionPath(original.id) !== path || ids.has(original.id)) {
          return invalidArchive();
        }
        const prepared = nativeSession(original, entry.size);
        // 无图片引用且未过滤片段的会话直接复用原始 JSON 文本，免去整会话 JSON.stringify 并立即释放 AST。
        if (!prepared.hasImageFiles && prepared.origin) {
          prepared.session.archiveJson = context && prepared.archiveSize > embeddedArchiveLimit ?
            await retainArchiveOrigin(prepared.origin, prepared.archiveSize, context, staged) :
            (!prepared.fragmentsModified ? '{"session":' + rawText + ',"images":[]}' : JSON.stringify(prepared.origin));
          prepared.origin = undefined;
        }
        sessions.push(prepared);
        ids.add(original.id);
        prepared.imagePaths.forEach((id: string, imagePath: string): void => { wantedImages.set(imagePath, id); });
        emitProgress();
        return;
      }
      const imageOwner = IMAGE_OWNER_PATTERN.exec(path)?.[1];
      if (!imageOwner || (index ? !ids.has(imageOwner) : sessions[sessions.length - 1]?.session.id !== imageOwner)) {
        return invalidArchive();
      }
      const imageId = wantedImages.get(path);
      if (imageId === undefined || loadedImages.has(imageId)) {
        // Unreferenced and repeated originals still have their ZIP size and CRC checked.
        return;
      }
      if (context) {
        const stagedImg = await stageBackupImageWithHeader(context, entry, 64 * 1024);
        staged.push(stagedImg.id);
        const imgPath = backupImagePath(context, stagedImg.id);
        const mimeType = await fileAttachmentRasterMime(imgPath, stagedImg.header);
        const softwareAvifPreview = !mimeType && attachmentUploadImageMime(stagedImg.header) === 'image/avif';
        loadedImages.set(imageId, { path: path, blobId: stagedImg.id, size: entry.size, crc: entry.crc,
          mimeType: mimeType, softwareAvifPreview: softwareAvifPreview || undefined });
      } else {
        inlineBytes += entry.size;
        if (inlineBytes > MAX_INLINE_IMAGE_BYTES) {
          throw new Error('图片原件超过 16 MB，请使用应用中的文件导入。');
        }
        const bytes = await readBackupZipEntry(entry);
        loadedImages.set(imageId, { path: path, bytes: base64.encodeToStringSync(bytes), size: entry.size, crc: entry.crc });
      }
      emitProgress();
    }, limit);
    emitProgress(true);
    if (!manifest || !index || index.length !== sessions.length) {
      return invalidArchive();
    }
    for (const summary of index) {
      validateSummary(summary);
      if (!count(summary.message_count) || !ids.delete(summary.id)) {
        return invalidArchive();
      }
    }
    const imported: NativeConversation[] = [];
    let lastYieldAt = Date.now();
    for (let i = 0; i < sessions.length; i++) {
      const prepared = sessions[i];
      if (prepared.origin) {
        restoreArchiveImages(prepared.origin, prepared.imagePaths, loadedImages);
        prepared.session.archiveJson = context && prepared.archiveSize > embeddedArchiveLimit ?
          await retainArchiveOrigin(prepared.origin, prepared.archiveSize, context, staged) :
          JSON.stringify(prepared.origin);
        prepared.origin = undefined;
      }
      imported.push(prepared.session);
      if ((i & 0x0f) === 0x0f && Date.now() - lastYieldAt >= 20) {
        await yieldNativeTurn();
        lastYieldAt = Date.now();
      }
    }
    return imported;
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
  locale: NativeLocale = 'zh-CN', previous: ArchiveOrigin | undefined = original(session)): ArchiveSession {
  if (session.unreadable) {
    throw new Error(NATIVE_BACKUP_UNREADABLE_CONVERSATION);
  }
  if (!validId(session.id) || previous?.source) {
    return invalidArchive();
  }
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

function compactArchiveTextBlocks(archived: ArchiveMessage, responses: string[]): string[] {
  const blocks: string[] = [];
  let index = 0;
  for (const fragment of archived.fragments) {
    if (fragment.type !== 'TEMPLATE_RESPONSE') continue;
    // Older compact records keep templates but do not have their positions.
    const before = Math.min(fragment.nuwa_harmony_responses_before ?? responses.length, responses.length);
    while (index < before) blocks.push(responses[index++]);
    blocks.push(fragment.content ?? '');
  }
  while (index < responses.length) blocks.push(responses[index++]);
  return blocks;
}

function assistantArchiveSignature(row: NativeConversationMessage, compact: boolean, archived?: ArchiveMessage): string {
  const responses = row.prefillBlocks?.filter((block: NativePrefillBlock): boolean =>
    block.type === 'text').map((block: NativePrefillBlock): string => block.text);
  if (archived) {
    if (row.content === '' && (row.stopReason === 'refusal' || archived.status === 'CONTENT_FILTER')) {
      return archived.fragments.filter((fragment: ArchiveFragment): boolean => fragment.type === 'TEMPLATE_RESPONSE')
        .map((fragment: ArchiveFragment): string => fragment.content ?? '').join('\n');
    }
    if (compact && responses && responses.join('') === row.content) {
      return compactArchiveTextBlocks(archived, responses).join('\n');
    }
    if (!compact && textFragments(archived, 'RESPONSE') === row.content) {
      return archived.fragments.filter((fragment: ArchiveFragment): boolean =>
        fragment.type === 'RESPONSE' || fragment.type === 'TEMPLATE_RESPONSE')
        .map((fragment: ArchiveFragment): string => fragment.content ?? '').join('\n');
    }
  }
  // Legacy snapshots retain one flat block when the original boundaries are unavailable.
  return responses?.join('\n') ?? row.content;
}

function messagePaths(session: NativeConversation): Set<string> {
  const source = original(session);
  const archivedMessages = new Map<string, ArchiveMessage>();
  for (const message of source?.session.messages ?? []) {
    archivedMessages.set(message.id.toString(), message);
  }
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
    const key = row.role === 'user' ? 'U:' + row.content + '|' + files :
      'A:' + assistantArchiveSignature(row, !!source?.source, archivedMessages.get(row.id));
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
    unreadable: session.unreadable,
  };
}

function allocateConversationId(usedIds: Set<string>): string {
  let id = util.generateRandomUUID(true);
  while (usedIds.has(id)) id = util.generateRandomUUID(true);
  usedIds.add(id);
  return id;
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
  if (first.images.length !== second.images.length) {
    return false;
  }
  const samePayload = first.source || second.source ? archivePayloadDigest(first) === archivePayloadDigest(second) :
    JSON.stringify(first.session) === JSON.stringify(second.session);
  if (!samePayload) return false;
  const imageKeys = new Map<string, string>();
  first.images.forEach((image: ArchiveImage): void => { imageKeys.set(image.path, retainedImageKey(image)); });
  return second.images.every((image: ArchiveImage): boolean => imageKeys.get(image.path) === retainedImageKey(image));
}

function extractArchiveSessionId(session: NativeConversation): string | undefined {
  const json = session.archiveJson;
  if (!json) return undefined;
  // 常见归档格式固定以 {"session":{"id":"..." 开头，零分配提取原归档 ID；非标准顺序再回退 JSON.parse。
  const prefix = '{"session":{"id":"';
  if (json.startsWith(prefix)) {
    const start = prefix.length;
    let end = start;
    while (end < json.length) {
      const ch = json.charCodeAt(end);
      if (ch === 34) {
        const extracted = json.slice(start, end);
        return extracted || undefined;
      }
      if (ch === 92) break;
      end++;
    }
  }
  return original(session)?.session.id;
}

function sameArchiveConversation(stored: NativeConversation, incoming: NativeConversation,
  incomingParsed?: ArchiveOrigin): boolean {
  if (!stored.archiveJson || !incoming.archiveJson) return false;
  // 字节完全一致的 archiveJson 必然拥有完全一致的 session/images/source，直接零解析短路。
  if (stored.archiveJson === incoming.archiveJson) return true;
  const first = original(stored);
  const second = incomingParsed ?? original(incoming);
  return !!(first && second && sameArchiveSource(first, second));
}

function restoreMergedArchiveImages(sessions: NativeConversation[], existing: NativeConversation[],
  imported: NativeConversation[]): void {
  const images = new Map<string, ArchiveImage>();
  for (const source of [existing, imported]) {
    for (const session of source) {
      if (!session.archiveJson || (!session.archiveJson.includes('"blobId":') && !session.archiveJson.includes('"bytes":'))) {
        continue;
      }
      const origin = original(session);
      if (!origin?.images.length) continue;
      archiveImagesById(origin, archiveImagePaths(origin.session)).forEach((image: ArchiveImage, id: string): void => {
        if (!images.has(id)) images.set(id, image);
      });
    }
  }
  if (!images.size) return;
  for (let index = 0; index < sessions.length; index++) {
    const session = sessions[index];
    if (!session.archiveJson || !session.archiveJson.includes('"is_image":true')) {
      continue;
    }
    const origin = original(session);
    if (origin && restoreArchiveImages(origin, archiveImagePaths(origin.session), images)) {
      const restored = copyMerged(session, session.id, session.title, session.pinnedAt);
      restored.archiveJson = JSON.stringify(origin);
      sessions[index] = restored;
    }
  }
}

export function mergeChatBackup(history: NativeConversationState, imported: NativeConversation[]): NativeBackupMergeResult {
  const sessions = history.sessions.slice();
  const indexById = new Map<string, number>();
  const usedIds = new Set<string>();
  const priorArchiveSessions = new Map<string, NativeConversation[]>();
  for (let i = 0; i < sessions.length; i++) {
    const stored = sessions[i];
    indexById.set(stored.id, i);
    usedIds.add(stored.id);
    const archiveId = extractArchiveSessionId(stored);
    if (archiveId) {
      const sameId = priorArchiveSessions.get(archiveId) ?? [];
      sameId.push(stored);
      priorArchiveSessions.set(archiveId, sameId);
    }
  }
  let total = 0;
  for (const incoming of imported) {
    // A previously diverged import retains the source archive ID and payload.
    const incomingArchiveId = priorArchiveSessions.size > 0 ? extractArchiveSessionId(incoming) : undefined;
    const existingCandidates = incomingArchiveId ? priorArchiveSessions.get(incomingArchiveId) : undefined;
    if (existingCandidates && existingCandidates.length > 0) {
      let matched = false;
      let incomingParsed: ArchiveOrigin | undefined = undefined;
      for (let k = 0; k < existingCandidates.length; k++) {
        const stored = existingCandidates[k];
        if (stored.archiveJson === incoming.archiveJson) {
          matched = true;
          break;
        }
        if (!incomingParsed) incomingParsed = original(incoming);
        if (sameArchiveConversation(stored, incoming, incomingParsed)) {
          matched = true;
          break;
        }
      }
      if (matched) {
        continue;
      }
    }
    const index = indexById.get(incoming.id);
    if (index === undefined) {
      indexById.set(incoming.id, sessions.length);
      usedIds.add(incoming.id);
      sessions.push(incoming);
      total++;
      continue;
    }
    const existing = sessions[index];
    if (existing.unreadable) {
      // Keep the exact unreadable placeholder and its metadata. Never compare an empty
      // fallback snapshot against the incoming paths; preserve the imported branch separately.
      total++;
      const newId = allocateConversationId(usedIds);
      indexById.set(newId, sessions.length);
      sessions.push(copyMerged(incoming, newId, withPrefix(incoming.title, 'D分支·')));
      continue;
    }
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
    const branchId = allocateConversationId(usedIds);
    indexById.set(branchId, sessions.length);
    sessions.push(copyMerged(incoming, branchId, withPrefix(incoming.title, 'D分支·')));
  }
  restoreMergedArchiveImages(sessions, history.sessions, imported);
  return { history: { sessions: sessions, activeId: history.activeId }, importedCount: total };
}

export async function commitChatBackup(context: common.UIAbilityContext, history: NativeConversationState,
  imported: NativeConversation[], save: (value: NativeConversationState) => Promise<void>): Promise<NativeBackupMergeResult> {
  const merged = mergeChatBackup(history, imported);
  await save(merged.history);
  // Every staged blob ID is unique to this import. Leave potentially committed files intact if the save throws.
  const retained = new Set<string>();
  for (const session of merged.history.sessions) {
    for (const id of backupImageIds(session.archiveJson)) retained.add(id);
  }
  const staged = new Set<string>();
  const avifPreviews = new Set<string>();
  for (const session of imported) {
    for (const id of backupImageIds(session.archiveJson, avifPreviews)) staged.add(id);
  }
  for (const id of staged) {
    if (!retained.has(id)) await removeBackupImage(context, id);
  }
  // Save history and originals before spending space on optional PNG previews.
  for (const id of avifPreviews) {
    if (retained.has(id)) await writeNativeAvifPreview(backupImagePath(context, id), backupAvifPreviewPath(context, id));
  }
  return merged;
}

export class NativeChatBackup {
  private readonly attachments = new NativeChatAttachments();

  async importFromUri(uri: string, context?: common.UIAbilityContext,
    onVerified?: () => Promise<void>,
    onProgress?: (sessions: number, images: number) => void): Promise<NativeConversation[]> {
    return withBackupInput<NativeConversation[]>(uri,
      (input: NativeBackupZipInput): Promise<NativeConversation[]> =>
        readChatBackup(input, context, context ? undefined : MAX_BACKUP_BYTES, onVerified, onProgress));
  }

  async importFromPicker(context: common.UIAbilityContext, onFileSelected?: () => Promise<boolean>,
    onVerified?: () => Promise<void>,
    onProgress?: (sessions: number, images: number) => void): Promise<NativeConversation[] | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['历史备份|.zip'];
    const selected = await new picker.DocumentViewPicker(context).select(options);
    if (!selected[0]) {
      return null;
    }
    if (onFileSelected && !await onFileSelected()) return null;
    return this.importFromUri(selected[0], context, onVerified, onProgress);
  }

  private originalImagePath(context: common.UIAbilityContext, image: BackupImageSource): string {
    if (image.retained?.blobId) return backupImagePath(context, image.retained.blobId);
    return image.live ? this.attachments.originalPath(context, image.live) : '';
  }

  private async hasOriginalImage(context: common.UIAbilityContext, image: BackupImageSource): Promise<boolean> {
    if (image.retained?.bytes !== undefined) return true;
    const path = this.originalImagePath(context, image);
    if (!path) return false;
    try {
      await fileIo.stat(path);
      return true;
    } catch (error) {
      if ((error as BusinessError).code === BACKUP_ORIGINAL_NOT_FOUND) return false;
      throw error as Error;
    }
  }

  private async collectExportImages(context: common.UIAbilityContext, file: ArchiveSession,
    candidates: Map<string, BackupImageSource>, images: Map<string, BackupImageSource>): Promise<void> {
    const references = new Map<string, ArchiveFile[]>();
    for (const message of file.messages) {
      forEachArchiveImageFile(message, (attachment: ArchiveFile): void => {
        const path = attachment.export_path;
        if (!path) return;
        const entries = references.get(path) ?? [];
        entries.push(attachment);
        references.set(path, entries);
      });
    }
    for (const path of references.keys()) {
      const image = candidates.get(path);
      if (image && await this.hasOriginalImage(context, image)) {
        images.set(path, image);
      } else {
        for (const attachment of references.get(path) ?? []) attachment.export_path = null;
      }
    }
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
    const path = this.originalImagePath(context, image);
    if (!path) {
      throw new Error('本地图片原件未能读取：' + (live?.name ?? name));
    }
    await withBackupInput<void>(path, async (input: NativeBackupZipInput): Promise<void> => {
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
      await writer.addJson(MANIFEST, manifest);
      for (const session of sessions) {
        const previous = await loadArchiveOrigin(context, session);
        const candidates = new Map<string, BackupImageSource>();
        const file = archiveSession(session, candidates, locale, previous);
        await this.collectExportImages(context, file, candidates, images);
        await writer.addJson(sessionPath(file.id), file);
        index.push(summaryEntry(file));
      }
      await writer.addJson(SESSION_INDEX, index);
      for (const name of images.keys()) {
        const image = images.get(name);
        if (image) {
          await this.writeImage(context, writer, name, image);
        }
      }
      await writer.finish();
    });
  }

  async exportSessionToPath(context: common.UIAbilityContext, session: NativeConversation,
    path: string, locale: NativeLocale = 'zh-CN'): Promise<void> {
    await this.writeArchive(context, path, [session], locale);
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
