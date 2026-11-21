import { common } from '@kit.AbilityKit';
import { url, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { NativeConversation, NativeConversationMessage } from './NativeConversation';
import { buildArchivedNativeTimeline, NativeArchiveTimelineFragment } from './NativeToolTimeline';
import { NativePrefillBlock } from './NativeReplyPrefill';

const SHARE_ENDPOINT = 'https://chat.deepseek.com/api/v0/share/content?share_id=';
const SHARE_URL = /(?:^|[^A-Za-z0-9_@%/.\-])(?:https?:\/\/)?(?:[a-z0-9-]+\.)*deepseek\.com\/(?:a\/chat\/s|share)\/([A-Za-z0-9_-]{4,64})(?=$|[/?#\s)"'!.,;>\]，。！？）】”》])/i;
const BARE_SHARE_ID = /^[A-Za-z0-9_-]{8,64}$/;
const HTTP_URL_PATTERN = /https?:\/\/[^\s<>"'`）)】》]+/i;
const MAX_INPUT = 8_192;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_DOWNLOAD_BYTES = 512 * 1024 * 1024;
const MAX_REDIRECT_HOPS = 6;
const MAX_MESSAGES = 4_000;
const MAX_FRAGMENTS = 512;
const MAX_MESSAGE_TEXT = 512 * 1024;
const MAX_TIMESTAMP = 253_402_300_799_999;
const SHARE_USER_AGENT = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0.0.0 Mobile Safari/537.36';

interface ShareFragment {
  type?: string;
  content?: string;
  elapsed_secs?: number | null;
}

interface ShareRow {
  message_id?: number;
  id?: number;
  parent_id?: number | null;
  role?: string;
  status?: string;
  thinking_enabled?: boolean;
  search_enabled?: boolean;
  inserted_at?: number | string;
  fragments?: ShareFragment[];
}

interface SharePayload {
  title?: string | null;
  messages?: ShareRow[];
}

interface ShareResult {
  biz_code?: number;
  biz_msg?: string;
  biz_data?: SharePayload | null;
}

interface ShareResponse {
  code?: number;
  msg?: string;
  data?: ShareResult | null;
}

interface ShareArchiveMessage {
  id: number;
  parent_id: number | null;
  role: string;
  status: string;
  thinking_enabled: boolean;
  search_enabled: boolean;
  accumulated_token_usage: number;
  inserted_at: string;
  fragments: NativeArchiveTimelineFragment[];
}

interface ShareArchiveSession {
  id: string;
  title: string;
  pinned: boolean;
  current_message_id: number;
  inserted_at: string;
  updated_at: string;
  share_import: boolean;
  messages: ShareArchiveMessage[];
}

interface ShareArchiveOrigin {
  session: ShareArchiveSession;
  images: string[];
}

interface ShareNode {
  message: NativeConversationMessage;
  archived: ShareArchiveMessage;
  children: ShareNode[];
}

function invalidGraph(): never {
  throw new Error('分享对话中的消息分支无效');
}

function tooLarge(): never {
  throw new Error('分享对话过大，无法导入');
}

export function extractDeepSeekShareId(input: string): string | null {
  if (!input || input.length > MAX_INPUT) {
    return null;
  }
  const trimmed = input.trim();
  const id = SHARE_URL.exec(trimmed)?.[1];
  if (id) {
    return id;
  }
  if (BARE_SHARE_ID.test(trimmed)) {
    return trimmed;
  }
  return null;
}

export function extractHttpUrl(input: string): string | null {
  const trimmed = input.trim();
  if (!trimmed || trimmed.length > MAX_INPUT) {
    return null;
  }
  const match = HTTP_URL_PATTERN.exec(trimmed);
  if (!match?.[0]) {
    return null;
  }
  return match[0].replace(/[.,;:!?。，；：！？]+$/, '');
}

function parseShareId(input: string): string {
  if (input.length > MAX_INPUT) {
    return tooLarge();
  }
  const id = extractDeepSeekShareId(input);
  if (id) {
    return id;
  }
  throw new Error('未识别到有效的 DeepSeek 分享链接（格式如 https://chat.deepseek.com/share/...）');
}

async function fetchShare(id: string): Promise<ShareResponse> {
  const request = http.createHttp();
  try {
    let response: http.HttpResponse;
    try {
      response = await request.request(SHARE_ENDPOINT + encodeURIComponent(id), {
        method: http.RequestMethod.GET,
        header: { 'accept': 'application/json', 'user-agent': SHARE_USER_AGENT },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        maxLimit: MAX_RESPONSE_BYTES,
        maxRedirects: 0,
        connectTimeout: 15000,
        readTimeout: 20000,
      });
    } catch {
      throw new Error('无法读取分享对话，请检查网络或链接是否有效');
    }
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error('无法读取分享对话 (HTTP ' + response.responseCode.toString() + ')');
    }
    if (!(response.result instanceof ArrayBuffer)) {
      throw new Error('分享服务返回了无效的内容');
    }
    if (response.result.byteLength > MAX_RESPONSE_BYTES) {
      return tooLarge();
    }
    try {
      const decoded = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(response.result));
      return JSON.parse(decoded) as ShareResponse;
    } catch {
      throw new Error('分享服务返回了无效的内容');
    }
  } finally {
    try {
      request.destroy();
    } catch {
      // The network stack can release the request when a transfer fails.
    }
  }
}

function timestamp(value: number | string | undefined, fallback: number): number {
  let parsed = NaN;
  if (typeof value === 'number' && Number.isFinite(value)) {
    parsed = Math.round(value > 1e12 ? value : value * 1_000);
  } else if (typeof value === 'string' && value.trim()) {
    parsed = Date.parse(value);
  }
  return Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= MAX_TIMESTAMP ? parsed : fallback;
}

function numberId(value: number | undefined): boolean {
  return Number.isSafeInteger(value) && (value ?? -1) >= 0;
}

function normalizedNode(row: ShareRow, role: string, now: number): ShareNode {
  const id = typeof row.message_id === 'number' ? row.message_id : row.id;
  if (id === undefined || !numberId(id)) {
    return invalidGraph();
  }
  const parent = row.parent_id ?? null;
  if (parent !== null && (!numberId(parent) || parent === id)) {
    return invalidGraph();
  }
  const fragments: NativeArchiveTimelineFragment[] = [];
  const prefillBlocks: NativePrefillBlock[] = [];
  const response: string[] = [];
  const thoughts: string[] = [];
  const raw = Array.isArray(row.fragments) ? row.fragments : [];
  if (raw.length > MAX_FRAGMENTS) {
    return tooLarge();
  }
  let length = 0;
  for (const fragment of raw) {
    if (!fragment || typeof fragment.content !== 'string') {
      continue;
    }
    length += fragment.content.length;
    if (length > MAX_MESSAGE_TEXT) {
      tooLarge();
    }
    if (role === 'USER' && fragment.type === 'REQUEST') {
      response.push(fragment.content);
    } else if (role === 'ASSISTANT' && fragment.content &&
      (fragment.type === 'RESPONSE' || fragment.type === 'THINK' || fragment.type === 'TEMPLATE_RESPONSE')) {
      if (fragment.type === 'RESPONSE') {
        response.push(fragment.content);
        prefillBlocks.push({ type: 'text', text: fragment.content });
      } else if (fragment.type === 'THINK') {
        thoughts.push(fragment.content);
        prefillBlocks.push({ type: 'thinking', text: fragment.content });
      }
      const elapsed = fragment.elapsed_secs;
      fragments.push({
        type: fragment.type,
        content: fragment.content,
        elapsed_secs: fragment.type === 'THINK' ?
          (typeof elapsed === 'number' && Number.isFinite(elapsed) && elapsed >= 0 ? elapsed : null) : undefined,
      });
    }
  }
  const content = role === 'USER' ? response.join('\n').trim() : response.join('');
  if (role === 'USER' && content) {
    fragments.push({ type: 'REQUEST', content: content });
  }
  const time = timestamp(row.inserted_at, now);
  const error = role === 'ASSISTANT' && row.status === 'FAILED';
  const message: NativeConversationMessage = {
    id: id.toString(),
    parentId: parent === null ? null : parent.toString(),
    role: role === 'USER' ? 'user' : 'assistant',
    content: content,
    reasoning: thoughts.join('\n'),
    createdAt: time,
    status: role === 'ASSISTANT' ? (error ? 'error' : 'done') : undefined,
    prefillBlocks: role === 'ASSISTANT' &&
      !raw.some((fragment: ShareFragment): boolean => fragment?.type === 'TEMPLATE_RESPONSE') ? prefillBlocks : undefined,
  };
  if (role === 'ASSISTANT') {
    message.thinking = row.thinking_enabled === true;
    message.search = row.search_enabled === true;
    const view = buildArchivedNativeTimeline(fragments, message.id);
    if (view.steps.length) {
      message.toolTimeline = { steps: view.steps, answer: '', answerOffset: view.answerOffset,
        thinkingSeconds: view.thinkingSeconds };
    }
  }
  const archived: ShareArchiveMessage = {
    id: id,
    parent_id: parent,
    role: role,
    status: error ? 'FAILED' : 'FINISHED',
    thinking_enabled: row.thinking_enabled === true,
    search_enabled: row.search_enabled === true,
    accumulated_token_usage: 0,
    inserted_at: new Date(time).toISOString(),
    fragments: fragments,
  };
  return { message: message, archived: archived, children: [] };
}

function shareTitle(value: string | null | undefined, firstText: string): string {
  const title = typeof value === 'string' ? value.trim() : '';
  if (title && title !== 'Shared Conversation' && title !== '来自分享的对话') {
    return Array.from(title.slice(0, 512)).slice(0, 256).join('');
  }
  return Array.from(firstText.replace(/\s+/g, ' ')).slice(0, 28).join('') || '分享导入的对话';
}

function buildSession(payload: SharePayload, raw: ShareRow[], now: number,
  reservedIds: Set<string>): NativeConversation {
  if (raw.length > MAX_MESSAGES) {
    return tooLarge();
  }
  const byId = new Map<string, ShareNode>();
  const inputOrder: ShareNode[] = [];
  let prompt = '';
  for (const row of raw) {
    const role = row && typeof row.role === 'string' ? row.role.toUpperCase() : '';
    if (role !== 'USER' && role !== 'ASSISTANT') {
      continue;
    }
    const node = normalizedNode(row, role, now);
    if (byId.has(node.message.id)) {
      return invalidGraph();
    }
    byId.set(node.message.id, node);
    inputOrder.push(node);
    if (!prompt && role === 'USER') {
      prompt = node.message.content;
    }
  }
  if (inputOrder.length === 0) {
    throw new Error('该分享链接中没有可导入的对话内容');
  }
  const roots: ShareNode[] = [];
  for (const node of inputOrder) {
    const parentId = node.message.parentId;
    if (parentId === null || (parentId === '0' && !byId.has('0'))) {
      if (node.message.role !== 'user') {
        return invalidGraph();
      }
      node.message.parentId = null;
      node.archived.parent_id = null;
      roots.push(node);
      continue;
    }
    const parent = byId.get(parentId);
    if (!parent || parent.message.role === node.message.role) {
      return invalidGraph();
    }
    parent.children.push(node);
    parent.message.selectedChildId = node.message.id;
  }
  const ordered = roots.slice();
  for (let index = 0; index < ordered.length; index++) {
    for (const child of ordered[index].children) {
      ordered.push(child);
    }
  }
  if (ordered.length !== inputOrder.length) {
    return invalidGraph();
  }
  const root = roots[0];
  let last = root;
  while (last.children.length > 0) {
    last = last.children[last.children.length - 1];
  }
  let id = util.generateRandomUUID(true);
  while (reservedIds.has(id)) id = util.generateRandomUUID(true);
  const title = shareTitle(payload.title, prompt);
  const createdAt = root.message.createdAt;
  const updatedAt = Math.max(now, inputOrder[inputOrder.length - 1].message.createdAt);
  const archive: ShareArchiveOrigin = {
    session: {
      id: id, title: title, pinned: false, current_message_id: last.archived.id,
      inserted_at: new Date(createdAt).toISOString(), updated_at: new Date(updatedAt).toISOString(),
      share_import: true, messages: ordered.map((node: ShareNode): ShareArchiveMessage => node.archived),
    },
    images: [],
  };
  return {
    id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
    rootMessageId: root.message.id,
    messages: ordered.map((node: ShareNode): NativeConversationMessage => node.message),
    archiveJson: JSON.stringify(archive),
  };
}

export async function importNativeShareLink(input: string, reservedIds: Set<string> = new Set<string>()): Promise<NativeConversation> {
  const payload = await fetchShare(parseShareId(input));
  if (payload?.code !== 0 || payload.data?.biz_code !== 0) {
    const message = payload?.data?.biz_msg || payload?.msg;
    const hint = typeof message === 'string' ? message.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 160) : '';
    throw new Error(hint || '分享链接已失效或无法访问');
  }
  const data = payload.data?.biz_data;
  if (!data || !Array.isArray(data.messages) || data.messages.length === 0) {
    throw new Error('该分享链接中没有可导入的对话内容');
  }
  return buildSession(data, data.messages, Date.now(), reservedIds);
}

export interface NativeLinkImportResult {
  kind: 'share' | 'archive';
  session?: NativeConversation;
  archivePath?: string;
}

interface RemoteDownloadResult {
  status: number;
  finalUrl: string;
  filePath: string;
  size: number;
}

function headerValue(headers: Object | undefined, targetName: string): string {
  if (!headers || typeof headers !== 'object') {
    return '';
  }
  const lower = targetName.toLowerCase();
  const entries = Object.entries(headers as Record<string, Object>);
  for (let i = 0; i < entries.length; i++) {
    if (entries[i][0].toLowerCase() === lower) {
      const value = entries[i][1];
      if (typeof value === 'string') return value;
      if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string') {
        return value[0] as string;
      }
    }
  }
  return '';
}

function resolveRedirectUrl(baseUrl: string, location: string): string {
  const trimmed = location.trim();
  if (!trimmed) return '';
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  try {
    return url.URL.parseURL(trimmed, baseUrl).toString();
  } catch {
    return '';
  }
}

async function downloadRemoteUrlToCache(context: common.UIAbilityContext, initialUrl: string): Promise<RemoteDownloadResult> {
  let currentUrl = initialUrl;
  for (let hop = 0; hop <= MAX_REDIRECT_HOPS; hop++) {
    const tempPath = context.cacheDir + '/nuwa_link_import_' + util.generateRandomUUID(true) + '.bin';
    const file = await fileIo.open(tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const request = http.createHttp();
    let totalBytes = 0;
    let writeFailedMessage: string = '';
    let redirectLocation = '';
    try {
      request.on('headersReceive', (headers: Object): void => {
        const loc = headerValue(headers, 'location');
        if (loc) {
          redirectLocation = loc;
        }
      });
      request.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (writeFailedMessage || chunk.byteLength === 0) return;
        if (totalBytes + chunk.byteLength > MAX_DOWNLOAD_BYTES) {
          writeFailedMessage = '导出文件过大，无法导入';
          return;
        }
        try {
          fileIo.writeSync(file.fd, chunk);
          totalBytes += chunk.byteLength;
        } catch {
          writeFailedMessage = '保存下载文件失败，请检查设备存储空间';
        }
      });
      const status = await request.requestInStream(currentUrl, {
        method: http.RequestMethod.GET,
        header: { 'user-agent': SHARE_USER_AGENT },
        usingCache: false,
        maxRedirects: 0,
        connectTimeout: 15000,
        readTimeout: 60000,
      });
      await fileIo.close(file);
      request.destroy();
      if (status === 301 || status === 302 || status === 303 || status === 307 || status === 308) {
        await fileIo.unlink(tempPath).catch(() => {});
        const nextUrl = resolveRedirectUrl(currentUrl, redirectLocation);
        if (!nextUrl || hop === MAX_REDIRECT_HOPS) {
          throw new Error('链接重定向失败，请检查链接是否有效');
        }
        currentUrl = nextUrl;
        const redirectedShareId = extractDeepSeekShareId(currentUrl);
        if (redirectedShareId) {
          return { status: 200, finalUrl: currentUrl, filePath: '', size: 0 };
        }
        continue;
      }
      if (writeFailedMessage) {
        await fileIo.unlink(tempPath).catch(() => {});
        throw new Error(writeFailedMessage);
      }
      return { status, finalUrl: currentUrl, filePath: tempPath, size: totalBytes };
    } catch (error) {
      await fileIo.close(file).catch(() => {});
      try {
        request.destroy();
      } catch {
        // Ignore teardown race.
      }
      await fileIo.unlink(tempPath).catch(() => {});
      if (error instanceof Error && (error.message.includes('重定向') || error.message.includes('过大') || error.message.includes('存储空间'))) {
        throw new Error(error.message);
      }
      throw new Error('链接下载失败，请检查网络或链接是否有效');
    }
  }
  throw new Error('链接重定向次数过多');
}

function isZipMagic(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && (bytes[2] === 0x03 || bytes[2] === 0x05);
}

async function readHeadBytes(path: string, count: number): Promise<Uint8Array> {
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const buf = new ArrayBuffer(count);
    const read = await fileIo.read(file.fd, buf);
    return new Uint8Array(buf, 0, Math.max(0, read));
  } finally {
    await fileIo.close(file).catch(() => {});
  }
}

/**
 * Unified link importer matching Android v0.1.34:
 * 1. DeepSeek share links (all subdomains, `/share/...` and `/a/chat/s/...`, or bare share ID) -> single chat import;
 * 2. DeepSeek official data export ZIP URLs (e.g. Huawei Cloud OBS signed links) or redirect short links ->
 *    follows redirects, imports share page if redirected to one, or imports ZIP archive incrementally.
 */
export async function importNativeLink(
  context: common.UIAbilityContext,
  input: string,
  reservedIds: Set<string> = new Set<string>(),
  onStage?: (stage: string) => void
): Promise<NativeLinkImportResult> {
  const directShareId = extractDeepSeekShareId(input);
  if (directShareId) {
    onStage?.('正在拉取分享对话…');
    const session = await importNativeShareLink(directShareId, reservedIds);
    return { kind: 'share', session };
  }

  const remoteUrl = extractHttpUrl(input);
  if (!remoteUrl) {
    throw new Error('未识别到有效链接（支持 DeepSeek 分享链接或官方数据导出 ZIP 下载链接）');
  }

  onStage?.('正在下载链接内容…');
  const downloaded = await downloadRemoteUrlToCache(context, remoteUrl);
  const redirectedShareId = extractDeepSeekShareId(downloaded.finalUrl);
  if (redirectedShareId) {
    if (downloaded.filePath) {
      await fileIo.unlink(downloaded.filePath).catch(() => {});
    }
    onStage?.('正在拉取分享对话…');
    const session = await importNativeShareLink(redirectedShareId, reservedIds);
    return { kind: 'share', session };
  }

  if (downloaded.status === 403 || downloaded.status === 404 || downloaded.status === 410) {
    if (downloaded.filePath) await fileIo.unlink(downloaded.filePath).catch(() => {});
    throw new Error('导出链接已失效或无权访问（DeepSeek 导出链接有时效限制，请重新导出后再试）');
  }
  if (downloaded.status < 200 || downloaded.status >= 300 || !downloaded.filePath) {
    if (downloaded.filePath) await fileIo.unlink(downloaded.filePath).catch(() => {});
    throw new Error(`链接下载失败（HTTP ${downloaded.status > 0 ? downloaded.status.toString() : '网络错误'}）`);
  }

  const head = await readHeadBytes(downloaded.filePath, 4);
  if (isZipMagic(head)) {
    onStage?.('正在导入对话记录…');
    return { kind: 'archive', archivePath: downloaded.filePath };
  }

  if (downloaded.size > 0 && downloaded.size <= 512 * 1024) {
    const bodyBytes = await readHeadBytes(downloaded.filePath, downloaded.size);
    const bodyText = util.TextDecoder.create('utf-8').decodeToString(bodyBytes);
    const embeddedShareId = extractDeepSeekShareId(bodyText);
    if (embeddedShareId) {
      await fileIo.unlink(downloaded.filePath).catch(() => {});
      onStage?.('正在拉取分享对话…');
      const session = await importNativeShareLink(embeddedShareId, reservedIds);
      return { kind: 'share', session };
    }
  }

  await fileIo.unlink(downloaded.filePath).catch(() => {});
  throw new Error('该链接返回的内容不是有效的 DeepSeek 导出压缩包（ZIP）或分享对话');
}
