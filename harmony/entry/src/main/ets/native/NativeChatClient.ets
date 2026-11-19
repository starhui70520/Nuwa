import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { allowsKeylessNativeApi } from './NativeApiCredential';
import { NativeReadLink } from './NativeReadLinks';

export interface NativeChatFileRef {
  serverId: string;
  isImage: boolean;
}

export interface NativeChatMessage {
  role: string;
  content: string;
  files?: NativeChatFileRef[];
  readLinks?: NativeReadLink[];
}

export interface NativeReplyOutcome {
  stopReason: string;
  canPrefill: boolean;
  thinkingSignature: string;
  title?: string;
}

export interface NativeReplyPrefill {
  text: string;
  reasoning: string;
  thinkingSignature: string;
}

export interface NativeChatConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  /** Omitted protocol preserves the original OpenAI-compatible transport. */
  protocol?: 'openai' | 'anthropic';
  /** OAuth token for the official DeepSeek App account endpoint; never used as an API key. */
  accountToken?: string;
  system?: string;
  thinking?: boolean;
  search?: boolean;
  prefill?: NativeReplyPrefill;
  omitExtended?: boolean;
  requestTitle?: boolean;
}

interface ChatRequestBody {
  model: string;
  messages: NativeChatMessage[];
  stream: boolean;
}

interface ChatDelta {
  content?: string | null;
  reasoning_content?: string | null;
  reasoning?: string | null;
}

interface ChatChoice {
  finish_reason?: string | null;
  delta?: ChatDelta;
}

interface ChatError {
  message?: string;
}

interface ChatChunk {
  choices?: ChatChoice[];
  error?: ChatError;
  message?: string;
}

interface AnthropicEventDelta {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  stop_reason?: string | null;
  title?: string;
  partial_json?: string;
  citation?: AnthropicCitation;
}

interface AnthropicEventError {
  message?: string;
}

interface AnthropicStartedBlock {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  id?: string;
  name?: string;
  kind?: string;
  input?: AnthropicToolInput;
  content?: Object;
  tool_use_id?: string;
}

interface AnthropicToolInput {
  action?: string;
  queries?: string[];
  url?: string;
  pattern?: string;
}

interface AnthropicFetchResultBlock {
  type?: string;
  error_code?: string;
  url?: string;
  content?: AnthropicFetchDocument;
  published_at?: string | null;
}

interface AnthropicFetchDocument {
  title?: string | null;
}

interface AnthropicCitation {
  type?: string;
  url?: string;
  title?: string | null;
}

interface AnthropicDeltaEvent {
  type?: string;
  index?: number;
  delta?: AnthropicEventDelta;
  content_block?: AnthropicStartedBlock;
  error?: AnthropicEventError;
  message?: Object;
}

interface AnthropicThinking {
  type: 'enabled' | 'disabled';
}

interface AnthropicSafetyCheck {
  level: 'high' | 'low';
}

interface AnthropicTool {
  type: 'deepseek_read_url' | 'deepseek_web_search';
  name: 'deepseek_read_url' | 'deepseek_web_search';
}

interface AnthropicFileSource {
  type: 'file';
  file_id: string;
}

interface AnthropicContentBlock {
  type: 'text' | 'image' | 'document' | 'thinking';
  thinking?: string;
  signature?: string;
  source?: AnthropicFileSource;
  text?: string;
}

interface AnthropicReadLinkInput {
  action: 'read_link';
  url: string;
}

interface AnthropicReadLinkCall {
  type: 'server_tool_use';
  id: string;
  name: 'deepseek_read_url';
  input: AnthropicReadLinkInput;
  kind: 'read_link';
}

interface AnthropicReadLinkDocumentSource {
  type: 'text';
  media_type: 'text/plain';
  data: string;
}

interface AnthropicReadLinkDocument {
  type: 'document';
  source: AnthropicReadLinkDocumentSource;
  title: string | null;
}

interface AnthropicReadLinkContent {
  type: 'web_fetch_result';
  url: string;
  content: AnthropicReadLinkDocument;
  published_at: string | null;
}

interface AnthropicReadLinkResult {
  type: 'web_fetch_tool_result';
  tool_use_id: string;
  kind: 'read_link';
  content: AnthropicReadLinkContent;
  signature: string;
}

type AnthropicBlock = AnthropicContentBlock | AnthropicReadLinkCall | AnthropicReadLinkResult;

interface AnthropicChatMessage {
  role: string;
  content: string | AnthropicBlock[];
}

interface AnthropicRequestBody {
  model: string;
  system: string;
  messages: AnthropicChatMessage[];
  stream: boolean;
  thinking: AnthropicThinking;
  safety_check: AnthropicSafetyCheck;
  tools?: AnthropicTool[];
  title?: AnthropicTitle;
}

interface AnthropicTitle {
  enabled: boolean;
}

const DEEPSEEK_ACCOUNT_ORIGIN: string = 'https://api.deepseek.com';
const DEFAULT_DEEPSEEK_SYSTEM: string = '该助手为DeepSeek，由深度求索公司创造。';
const MAX_ERROR_BODY_BYTES: number = 8192;
const MAX_BYTES_AWAITING_HEADERS: number = 1024 * 1024;
const ANTHROPIC_STOP_REASONS: Set<string> = new Set<string>(['end_turn', 'max_tokens', 'tool_use', 'refusal']);
const ANTHROPIC_SEARCH_KINDS: Set<string> = new Set<string>(['search', 'deep_search', 'image_search', 'deep_image_search']);

export class NativeModelError extends Error {
  readonly status: number;
  readonly receivedContent: boolean;
  readonly inputLimit: boolean;
  readonly invalidFile: boolean;
  readonly fileIds: string[];
  readonly imageMessageIndex: number;
  readonly imageBlockIndex: number;

  constructor(message: string, status: number, receivedContent: boolean, apiKey: string, accountToken: string) {
    super(redactCredentials(message, apiKey, accountToken));
    this.status = status;
    this.receivedContent = receivedContent;
    this.inputLimit = /user input too long.*exceeds max 32768 tokens/i.test(message);
    this.invalidFile = status === 400 && /file_ids do not exist or are not created under your account|file data not found for file_id|\.source\.file_id: invalid file_id/i.test(message);
    this.fileIds = this.invalidFile ? Array.from(new Set(message.match(/file-api-[\w-]+/g) ?? [])) : [];
    const image = /messages\.(\d+)\.content\.(\d+):.*unsupported image/i.exec(message);
    this.imageMessageIndex = image ? Number(image[1]) : -1;
    this.imageBlockIndex = image ? Number(image[2]) : -1;
  }
}

export function usesExtendedNativeRequest(config: NativeChatConfig, messages: NativeChatMessage[]): boolean {
  if (config.omitExtended || (!config.accountToken && config.protocol !== 'anthropic')) {
    return false;
  }
  const prompt = messages[messages.length - 1];
  return !(prompt?.files?.some((file: NativeChatFileRef): boolean => !file.isImage) &&
    !config.search && !/https?:\/\//i.test(prompt.content));
}

function httpErrorMessage(bytes: Uint8Array, fallback: string): string {
  const response = util.TextDecoder.create('utf-8').decodeToString(bytes).trim();
  try {
    const body = JSON.parse(response) as ChatChunk;
    const message = body?.error?.message ?? body?.message;
    if (typeof message === 'string' && message.trim()) {
      return message;
    }
  } catch {
    // Plain text error bodies from compatible providers are meaningful as well.
  }
  return response || fallback;
}

interface StreamResponseHead {
  status: number;
  stream: boolean;
  interim: boolean;
}

function streamResponseHead(header: Object): StreamResponseHead {
  const fields = header as Record<string, string>;
  let status = 0;
  let stream = false;
  let interim = false;
  for (const key of Object.keys(fields)) {
    const name = key.toLowerCase();
    if (name === 'content-type') {
      stream = typeof fields[key] === 'string' && fields[key].split(';')[0].trim().toLowerCase() === 'text/event-stream';
      continue;
    }
    // NetStack inserts the HTTP status line as a key. Some versions report it as Status-Line instead.
    const line = name === 'status-line' ? fields[key] : key;
    const match = /^HTTP\/[\d.]+\s+(\d{3})\b/i.exec(line);
    if (!match) continue;
    const code = Number(match[1]);
    if (code < 200 || /\bconnection established\b/i.test(line)) {
      interim = true;
    } else {
      status = code;
    }
  }
  return { status, stream, interim: interim && !status };
}

function isRecord(value: Object | null | undefined): boolean {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function nullableString(value?: string | null): boolean {
  return value == null || typeof value === 'string';
}

function validAnthropicToolInput(input?: AnthropicToolInput): boolean {
  if (!input || !isRecord(input)) return false;
  switch (input.action) {
    case 'search':
      return Array.isArray(input.queries) && input.queries.every((query: string): boolean => typeof query === 'string');
    case 'open_page':
    case 'read_link':
      return typeof input.url === 'string';
    case 'find_in_page':
      return typeof input.url === 'string' && typeof input.pattern === 'string';
    default:
      // The timeline also handles input_json_delta when a provider starts with an empty input object.
      return Object.keys(input).length === 0;
  }
}

function validAnthropicFetchResult(content?: Object): boolean {
  if (!isRecord(content)) return false;
  const result = content as AnthropicFetchResultBlock;
  if (result.type === 'web_fetch_tool_result_error') return typeof result.error_code === 'string';
  return result.type === 'web_fetch_result' && typeof result.url === 'string' &&
    isRecord(result.content) && nullableString(result.content?.title) && nullableString(result.published_at);
}

function validAnthropicStart(block: AnthropicStartedBlock): boolean {
  if (!isRecord(block)) return false;
  switch (block.type) {
    case 'text': return typeof block.text === 'string';
    case 'thinking': return typeof block.thinking === 'string';
    case 'tool_use': return true;
    case 'server_tool_use':
      return typeof block.id === 'string' &&
        (block.kind === 'read_link' || ANTHROPIC_SEARCH_KINDS.has(block.kind ?? '')) &&
        (block.name === 'deepseek_web_search' || block.name === 'deepseek_read_url') &&
        validAnthropicToolInput(block.input);
    case 'web_search_tool_result':
      return typeof block.tool_use_id === 'string' && ANTHROPIC_SEARCH_KINDS.has(block.kind ?? '') &&
        Array.isArray(block.content);
    case 'web_fetch_tool_result':
      return typeof block.tool_use_id === 'string' && (block.kind === 'read_link' || block.kind === 'deep_search') &&
        validAnthropicFetchResult(block.content);
    default: return false;
  }
}

function redactCredentials(message: string, apiKey: string, accountToken: string): string {
  let safeMessage = message;
  if (apiKey) {
    safeMessage = safeMessage.split(apiKey).join('••••');
  }
  if (accountToken) {
    safeMessage = safeMessage.split(accountToken).join('••••');
  }
  return safeMessage.slice(0, 240);
}

function resolveAnthropicEndpoint(baseUrl: string): string {
  let endpoint: url.URL;
  try {
    endpoint = url.URL.parseURL(baseUrl.trim());
  } catch {
    throw new Error('请输入有效的服务器地址');
  }
  if ((endpoint.protocol !== 'https:' && endpoint.protocol !== 'http:') ||
    !endpoint.hostname || endpoint.username || endpoint.password || endpoint.hash) {
    throw new Error('请输入不含账号、密码或片段的 HTTP 或 HTTPS 地址');
  }
  if (endpoint.protocol !== 'https:') {
    throw new Error('Anthropic 兼容服务地址必须使用 HTTPS');
  }
  let path = endpoint.pathname.replace(/\/+$/, '');
  if (!path.endsWith('/anthropic/v1/messages')) {
    path = `${path.replace(/\/(?:anthropic\/v1|v1)$/i, '')}/anthropic/v1/messages`;
  }
  endpoint.pathname = path;
  return endpoint.href;
}

function resolveChatEndpoint(baseUrl: string, authenticated: boolean): string {
  let endpoint: url.URL;
  try {
    endpoint = url.URL.parseURL(baseUrl.trim());
  } catch {
    throw new Error('请输入有效的服务器地址');
  }
  if ((endpoint.protocol !== 'https:' && endpoint.protocol !== 'http:') ||
    !endpoint.hostname || endpoint.username || endpoint.password || endpoint.hash) {
    throw new Error('请输入不含账号、密码或片段的 HTTP 或 HTTPS 地址');
  }
  if (authenticated && endpoint.protocol !== 'https:') {
    throw new Error('使用 API 密钥时，服务器地址必须使用 HTTPS');
  }
  const path = endpoint.pathname.replace(/\/+$/, '');
  if (!path.endsWith('/chat/completions')) {
    endpoint.pathname = `${path || '/v1'}/chat/completions`;
  } else {
    endpoint.pathname = path;
  }
  return endpoint.href;
}

class ChatStream {
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  private readonly lineBreak: RegExp = /\r\n|\r|\n/g;
  private firstText: boolean = true;
  private pendingLine: string = '';
  private eventName: string = '';
  private dataLines: string[] = [];
  private readonly openBlocks = new Map<number, string>();
  private done: boolean = false;
  private hasReply: boolean = false;
  receivedContent: boolean = false;
  private outcome: NativeReplyOutcome = { stopReason: '', canPrefill: true, thinkingSignature: '' };
  private readonly onDelta: (content: string, reasoning: string) => void;
  private readonly protocol: 'openai' | 'anthropic';
  private readonly onAnthropicEvent?: (data: string) => void;

  constructor(onDelta: (content: string, reasoning: string) => void,
    protocol: 'openai' | 'anthropic' = 'openai', onAnthropicEvent?: (data: string) => void) {
    this.onAnthropicEvent = onAnthropicEvent;
    this.onDelta = onDelta;
    this.protocol = protocol;
  }

  push(bytes: ArrayBuffer): void {
    this.appendText(this.decoder.decodeToString(new Uint8Array(bytes), { stream: true }));
  }

  end(): NativeReplyOutcome {
    this.appendText(this.decoder.decodeToString(new Uint8Array(0), { stream: false }));
    if (this.pendingLine.endsWith('\r')) {
      this.readLine(this.pendingLine.slice(0, -1));
    }
    if (this.protocol === 'anthropic') {
      if (!this.done && !this.outcome.stopReason) {
        throw new Error('模型回复已中断');
      }
      return this.outcome;
    }
    if (!this.hasReply && !this.outcome.stopReason) {
      throw new Error('模型未返回可读取的回复，请检查服务器地址和模型名称');
    }
    return this.outcome;
  }

  currentOutcome(): NativeReplyOutcome {
    return this.outcome;
  }

  completed(): boolean {
    return this.done;
  }

  // Match the Web client's SSE framing, including a CRLF split across chunks.
  private appendText(text: string): void {
    if (this.firstText && text) {
      text = text.replace(/^\uFEFF/, '');
      this.firstText = false;
    }
    this.pendingLine += text;
    let lineStart = 0;
    this.lineBreak.lastIndex = 0;
    let match = this.lineBreak.exec(this.pendingLine);
    while (match && !this.done) {
      if (match[0] === '\r' && this.lineBreak.lastIndex === this.pendingLine.length) {
        break;
      }
      this.readLine(this.pendingLine.slice(lineStart, match.index));
      lineStart = this.lineBreak.lastIndex;
      match = this.lineBreak.exec(this.pendingLine);
    }
    this.pendingLine = this.done ? '' : this.pendingLine.slice(lineStart);
  }

  private readLine(line: string): void {
    if (!line) {
      const lines = this.dataLines;
      const eventName = this.eventName;
      this.dataLines = [];
      this.eventName = '';
      if (lines.length) {
        this.dispatch(lines.join('\n'), eventName);
      }
      return;
    }
    const colon = line.indexOf(':');
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? '' : line.slice(colon + 1);
    if (value.startsWith(' ')) {
      value = value.slice(1);
    }
    if (field === 'data') {
      this.dataLines.push(value);
    } else if (field === 'event') {
      this.eventName = value;
    }
  }

  private dispatch(data: string, eventName: string): void {
    if (this.protocol === 'anthropic') {
      this.dispatchAnthropic(data, eventName);
      return;
    }
    if (data.trim() === '[DONE]') {
      this.done = true;
      return;
    }
    let chunk: ChatChunk;
    try {
      chunk = JSON.parse(data) as ChatChunk;
    } catch {
      if (eventName === 'error') {
        throw new Error(data || '服务端报告了流式错误');
      }
      return;
    }
    if (!isRecord(chunk)) {
      return;
    }
    if (chunk.error || eventName === 'error') {
      const message = chunk.error?.message ?? chunk.message;
      throw new Error(typeof message === 'string' && message ? message : '服务端报告了流式错误');
    }
    const choice = chunk.choices?.[0];
    const finish = choice?.finish_reason;
    if (finish) {
      this.outcome.stopReason = finish === 'length' ? 'max_tokens' : finish === 'content_filter' ? 'refusal' :
        finish === 'tool_calls' || finish === 'function_call' ? 'tool_use' : 'end_turn';
    }
    const delta = choice?.delta;
    const content = typeof delta?.content === 'string' ? delta.content : '';
    const reasoningValue = delta?.reasoning_content ?? delta?.reasoning;
    const reasoning = typeof reasoningValue === 'string' ? reasoningValue : '';
    if (content || reasoning) {
      this.hasReply = true;
      this.receivedContent = true;
      this.onDelta(content, reasoning);
    }
  }

  private dispatchAnthropic(data: string, eventName: string): void {
    let event: AnthropicDeltaEvent;
    try {
      event = JSON.parse(data) as AnthropicDeltaEvent;
    } catch {
      if (eventName === 'error') throw new Error(data || '服务端报告了流式错误');
      return;
    }
    if (typeof event?.error?.message === 'string') {
      throw new Error(event.error.message || '服务端报告了流式错误');
    }
    if (eventName === 'error') {
      throw new Error(data || '服务端报告了流式错误');
    }
    if (!isRecord(event)) return;
    if (event.type === 'error') {
      throw new Error(typeof event.message === 'string' && event.message ? event.message : '服务端报告了流式错误');
    }
    if (event.type === 'message_stop') {
      this.onAnthropicEvent?.(data);
      this.done = true;
      this.openBlocks.clear();
      return;
    }
    const delta = event.delta;
    if (event.type === 'message_delta') {
      const reason = delta?.stop_reason;
      if (typeof reason === 'string' && ANTHROPIC_STOP_REASONS.has(reason)) {
        this.outcome.stopReason = reason;
        if ((reason === 'end_turn' || reason === 'max_tokens') && typeof delta?.title === 'string') {
          this.outcome.title = delta.title.trim();
        }
        this.onAnthropicEvent?.(data);
      }
      return;
    }
    if (event.type === 'message_start') {
      if (isRecord(event.message)) this.onAnthropicEvent?.(data);
      return;
    }
    const index = event.index ?? -1;
    if (!Number.isSafeInteger(index) || index < 0) return;
    switch (event.type) {
      case 'content_block_start': {
        const block = event.content_block;
        if (block && validAnthropicStart(block)) {
          this.openBlocks.set(index, block.type ?? '');
          this.startAnthropicBlock(block, data);
        }
        break;
      }
      case 'content_block_delta':
        if (delta) this.applyAnthropicDelta(index, delta, data);
        break;
      case 'content_block_stop':
        if (this.openBlocks.delete(index)) this.onAnthropicEvent?.(data);
        break;
    }
  }

  private startAnthropicBlock(block: AnthropicStartedBlock, data: string): void {
    this.receivedContent = true;
    this.onAnthropicEvent?.(data);
    if (block.type === 'text') {
      if (block.text) this.onDelta(block.text, '');
    } else if (block.type === 'thinking') {
      this.outcome.thinkingSignature = typeof block.signature === 'string' ? block.signature : '';
      if (block.thinking) this.onDelta('', block.thinking);
    } else {
      this.outcome.canPrefill = false;
    }
  }

  private applyAnthropicDelta(index: number, delta: AnthropicEventDelta, data: string): void {
    const kind = this.openBlocks.get(index);
    if (kind === 'text') {
      if (delta.type === 'text_delta' && typeof delta.text === 'string') {
        this.onAnthropicEvent?.(data);
        if (delta.text) this.onDelta(delta.text, '');
      } else if (delta.type === 'citations_delta' && delta.citation?.type === 'web_search_result_location' &&
        typeof delta.citation.url === 'string' &&
        nullableString(delta.citation.title)) {
        this.onAnthropicEvent?.(data);
      }
    } else if (kind === 'thinking') {
      if (delta.type === 'thinking_delta' && typeof delta.thinking === 'string') {
        this.onAnthropicEvent?.(data);
        if (delta.thinking) this.onDelta('', delta.thinking);
      } else if (delta.type === 'signature_delta' && typeof delta.signature === 'string') {
        this.outcome.thinkingSignature += delta.signature;
        this.onAnthropicEvent?.(data);
      }
    } else if (kind === 'server_tool_use' && delta.type === 'input_json_delta' && typeof delta.partial_json === 'string') {
      this.onAnthropicEvent?.(data);
    }
  }
}

function anthropicReadLinkReply(message: NativeChatMessage): AnthropicChatMessage {
  const blocks: AnthropicBlock[] = [];
  let offset = 0;
  for (const link of message.readLinks ?? []) {
    if (link.offset > offset) {
      const text: AnthropicContentBlock = { type: 'text', text: message.content.slice(offset, link.offset) };
      blocks.push(text);
    }
    const call: AnthropicReadLinkCall = {
      type: 'server_tool_use', id: link.id, name: 'deepseek_read_url', kind: 'read_link',
      input: { action: 'read_link', url: link.url },
    };
    const result: AnthropicReadLinkResult = {
      type: 'web_fetch_tool_result', tool_use_id: link.id, kind: 'read_link', signature: link.signature,
      content: {
        type: 'web_fetch_result', url: link.url, published_at: null,
        content: { type: 'document', title: link.title, source: { type: 'text', media_type: 'text/plain', data: '' } },
      },
    };
    blocks.push(call, result);
    offset = link.offset;
  }
  if (offset < message.content.length) {
    const text: AnthropicContentBlock = { type: 'text', text: message.content.slice(offset) };
    blocks.push(text);
  }
  return { role: 'assistant', content: blocks };
}

function anthropicMessage(message: NativeChatMessage): AnthropicChatMessage {
  if (message.role === 'assistant' && message.readLinks?.length) {
    return anthropicReadLinkReply(message);
  }
  if (!message.files?.length || message.role !== 'user') {
    return { role: message.role, content: message.content };
  }
  const blocks: AnthropicContentBlock[] = message.files.map<AnthropicContentBlock>(
    (file: NativeChatFileRef): AnthropicContentBlock => ({
      type: file.isImage ? 'image' : 'document', source: { type: 'file', file_id: file.serverId },
    }));
  if (message.content) {
    blocks.push({ type: 'text', text: message.content });
  }
  return { role: message.role, content: blocks };
}

export class NativeChatClient {
  private settleRequest?: (error?: Error | NativeModelError) => void;

  cancel(): void {
    this.settleRequest?.();
  }

  async send(config: NativeChatConfig, messages: NativeChatMessage[],
    onDelta: (content: string, reasoning: string) => void,
    onAnthropicEvent?: (data: string) => void): Promise<NativeReplyOutcome> {
    this.cancel();
    const apiKey = config.apiKey.trim();
    const accountToken = config.accountToken?.trim() ?? '';
    const protocol = accountToken ? 'anthropic' : (config.protocol ?? 'openai');
    const endpoint = accountToken
      ? `${DEEPSEEK_ACCOUNT_ORIGIN}/anthropic/v1/messages`
      : protocol === 'anthropic'
        ? resolveAnthropicEndpoint(config.baseUrl)
      : resolveChatEndpoint(config.baseUrl, !!apiKey);
    const model = (accountToken ? 'deepseek-flash' : config.model).trim();
    if (!model) {
      throw new Error('请输入模型名称');
    }
    if (!apiKey && !accountToken && !allowsKeylessNativeApi(config.baseUrl, protocol)) {
      throw new Error('请输入 API Key');
    }
    if (/[\r\n]/.test(apiKey)) {
      throw new Error('API 密钥中不能包含换行');
    }
    if (accountToken.includes('\n') || accountToken.includes('\r')) {
      throw new Error('账号令牌中不能包含换行');
    }
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    };
    if (accountToken) {
      headers['x-dsh-auth-token'] = accountToken;
    } else if (apiKey) {
      if (protocol === 'anthropic') headers['x-api-key'] = apiKey;
      else headers['authorization'] = `Bearer ${apiKey}`;
    }
    let body: ChatRequestBody | AnthropicRequestBody;
    if (protocol === 'anthropic') {
      const tools: AnthropicTool[] = [
        { type: 'deepseek_read_url', name: 'deepseek_read_url' },
      ];
      if (config.search) {
        tools.push({ type: 'deepseek_web_search', name: 'deepseek_web_search' });
      }
      if (messages.some((message: NativeChatMessage): boolean => message.role === 'user' && !!message.files?.length)) {
        headers['anthropic-beta'] = 'files-api-2025-04-14';
      }
      const extended = usesExtendedNativeRequest(config, messages);
      const anthropicMessages = messages.map<AnthropicChatMessage>(anthropicMessage);
      const prefill = config.prefill;
      if (prefill) {
        const blocks: AnthropicContentBlock[] = [];
        if (config.thinking && prefill.reasoning && prefill.thinkingSignature) {
          blocks.push({ type: 'thinking', thinking: prefill.reasoning, signature: prefill.thinkingSignature });
        }
        if (prefill.text) {
          blocks.push({ type: 'text', text: prefill.text });
        }
        if (blocks.length) {
          anthropicMessages.push({ role: 'assistant', content: blocks });
        }
      }
      body = {
        model: model,
        system: config.system ?? DEFAULT_DEEPSEEK_SYSTEM,
        messages: anthropicMessages,
        stream: true,
        thinking: { type: config.thinking ? 'enabled' : 'disabled' },
        safety_check: { level: extended ? 'high' : 'low' },
        tools: extended ? tools : undefined,
        title: extended && config.requestTitle ? { enabled: true } : undefined,
      } as AnthropicRequestBody;
    } else {
      const textMessages = messages.filter((message: NativeChatMessage): boolean =>
        !!message.content && (message.role === 'user' || message.role === 'assistant'))
        .map<NativeChatMessage>((message: NativeChatMessage): NativeChatMessage => ({
          role: message.role, content: message.content,
        }));
      const system = config.system ?? DEFAULT_DEEPSEEK_SYSTEM;
      if (system.trim()) {
        textMessages.unshift({ role: 'system', content: system });
      }
      if (config.prefill?.text) {
        textMessages.push({ role: 'assistant', content: config.prefill.text });
      }
      body = { model: model, messages: textMessages, stream: true } as ChatRequestBody;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      usingCache: false,
      usingProxy: apiKey || accountToken ? undefined : false,
      maxRedirects: 0,
      connectTimeout: 15000,
      readTimeout: 300000,
    };
    const request = http.createHttp();
    return new Promise<NativeReplyOutcome>((resolve, reject) => {
      const settle = (error?: Error | NativeModelError): void => {
        if (this.settleRequest !== settle) {
          return;
        }
        this.settleRequest = undefined;
        try {
          request.destroy();
        } catch {
          // Destruction can race with the system closing the connection.
        }
        if (error) {
          reject(error);
        } else {
          resolve(stream.currentOutcome());
        }
      };
      const stream = new ChatStream((content: string, reasoning: string): void => {
        if (this.settleRequest === settle) {
          onDelta(content, reasoning);
        }
      }, protocol, onAnthropicEvent);
      const errorBody = new Uint8Array(MAX_ERROR_BODY_BYTES);
      let errorBodyLength = 0;
      let streamError: string = '';
      let responseHead: StreamResponseHead | undefined;
      let pendingChunks: ArrayBuffer[] = [];
      let pendingBytes = 0;
      let overflowed = false;
      const consume = (bytes: ArrayBuffer): void => {
        if (this.settleRequest !== settle || streamError || !responseHead?.stream ||
          (responseHead.status !== 0 && (responseHead.status < 200 || responseHead.status >= 300))) {
          return;
        }
        try {
          stream.push(bytes);
          if (stream.completed() && responseHead.status >= 200 && responseHead.status < 300) {
            settle();
          }
        } catch (error) {
          streamError = error instanceof Error ? error.message : '无法读取模型回复';
          if (responseHead.status >= 200 && responseHead.status < 300) {
            settle(new NativeModelError(streamError, responseHead.status, stream.receivedContent, apiKey, accountToken));
          }
        }
      };
      this.settleRequest = settle;
      try {
        request.on('headersReceive', (headers: Object): void => {
          if (this.settleRequest !== settle || !isRecord(headers)) return;
          const head = streamResponseHead(headers);
          if (head.interim) return;
          responseHead = head;
          if (head.stream && overflowed) {
            streamError = '无法读取模型回复';
          }
          for (const bytes of pendingChunks) consume(bytes);
          pendingChunks = [];
          pendingBytes = 0;
        });
        request.on('dataReceive', (bytes: ArrayBuffer): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          const copied = Math.min(MAX_ERROR_BODY_BYTES - errorBodyLength, bytes.byteLength);
          if (copied > 0) {
            errorBody.set(new Uint8Array(bytes, 0, copied), errorBodyLength);
            errorBodyLength += copied;
          }
          if (responseHead) {
            consume(bytes);
          } else if (!overflowed) {
            pendingBytes += bytes.byteLength;
            if (pendingBytes <= MAX_BYTES_AWAITING_HEADERS) {
              pendingChunks.push(bytes);
            } else {
              overflowed = true;
              pendingChunks = [];
            }
          }
        });
        request.requestInStream(endpoint, options).then((status: number): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          if (status < 200 || status >= 300) {
            const message = httpErrorMessage(errorBody.subarray(0, errorBodyLength), `服务端请求失败 (HTTP ${status})`);
            settle(new NativeModelError(message, status, false, apiKey, accountToken));
            return;
          }
          if (!responseHead?.stream) {
            const message = httpErrorMessage(errorBody.subarray(0, errorBodyLength), '服务器未返回流式回复');
            settle(new NativeModelError(message, status, false, apiKey, accountToken));
            return;
          }
          if (streamError) {
            settle(new NativeModelError(streamError, status, stream.receivedContent, apiKey, accountToken));
            return;
          }
          try {
            stream.end();
            settle();
          } catch (error) {
            const message = error instanceof Error ? error.message : '无法读取模型回复';
            settle(new NativeModelError(message, status, stream.receivedContent, apiKey, accountToken));
          }
        }, (error: BusinessError): void => {
          const message = streamError || `无法连接模型服务 (${error.code})`;
          settle(new NativeModelError(message, 0, stream.receivedContent, apiKey, accountToken));
        });
      } catch {
        settle(new Error('无法发起模型请求'));
      }
    });
  }
}
