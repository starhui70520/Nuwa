import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { NativeConversation, NativeConversationMessage } from './NativeConversation';
import { buildArchivedNativeTimeline, NativeArchiveTimelineFragment } from './NativeToolTimeline';

const SHARE_ENDPOINT = 'https://chat.deepseek.com/api/v0/share/content?share_id=';
const SHARE_URL = /(?:^|[^A-Za-z0-9_@%/.\-])(?:https?:\/\/)?chat\.deepseek\.com\/share\/([A-Za-z0-9_-]{4,64})(?=$|[/?#\s)"'!.,;>\]，。！？）】”》])/i;
const BARE_SHARE_ID = /^[A-Za-z0-9_-]{8,64}$/;
const MAX_INPUT = 8_192;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
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

function parseShareId(input: string): string {
  if (input.length > MAX_INPUT) {
    return tooLarge();
  }
  const trimmed = input.trim();
  const id = SHARE_URL.exec(trimmed)?.[1];
  if (id) {
    return id;
  }
  if (BARE_SHARE_ID.test(trimmed)) {
    return trimmed;
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
      } else if (fragment.type === 'THINK') {
        thoughts.push(fragment.content);
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

function buildSession(payload: SharePayload, raw: ShareRow[], now: number): NativeConversation {
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
  const id = util.generateRandomUUID(true);
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

export async function importNativeShareLink(input: string): Promise<NativeConversation> {
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
  return buildSession(data, data.messages, Date.now());
}
