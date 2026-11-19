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
}

interface AnthropicEventError {
  message?: string;
}

interface AnthropicStartedBlock {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
}

interface AnthropicDeltaEvent {
  type?: string;
  delta?: AnthropicEventDelta;
  content_block?: AnthropicStartedBlock;
  error?: AnthropicEventError;
  message?: string;
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

function httpErrorMessage(bytes: Uint8Array, status: number): string {
  try {
    const response = util.TextDecoder.create('utf-8').decodeToString(bytes);
    const body = JSON.parse(response) as ChatChunk;
    const message = body?.error?.message ?? body?.message;
    if (typeof message === 'string' && message.trim()) {
      return message;
    }
  } catch {
    // A gateway can send an HTML page instead of a structured API error.
  }
  return `服务端请求失败 (HTTP ${status})`;
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
  private pendingLine: string = '';
  private eventName: string = '';
  private dataLines: string[] = [];
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
    if (this.protocol === 'anthropic' && this.receivedContent && !this.done && !this.outcome.stopReason) {
      throw new Error('模型回复已中断');
    }
    if (!this.hasReply && !this.outcome.stopReason) {
      throw new Error('模型未返回可读取的回复，请检查服务器地址和模型名称');
    }
    return this.outcome;
  }

  currentOutcome(): NativeReplyOutcome {
    return this.outcome;
  }

  // Match the Web client's SSE framing, including a CRLF split across chunks.
  private appendText(text: string): void {
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
      const data = this.dataLines.join('\n');
      const eventName = this.eventName;
      this.dataLines = [];
      this.eventName = '';
      if (data) {
        this.dispatch(data, eventName);
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
    if (data.trim() === '[DONE]') {
      this.done = true;
      return;
    }
    if (this.protocol === 'anthropic') {
      this.onAnthropicEvent?.(data);
      this.dispatchAnthropic(data, eventName);
      return;
    }
    let chunk: ChatChunk;
    try {
      chunk = JSON.parse(data) as ChatChunk;
    } catch {
      if (eventName === 'error') {
        throw new Error('服务端报告了流式错误');
      }
      return;
    }
    if (!chunk || typeof chunk !== 'object') {
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
      if (eventName === 'error') throw new Error('服务端报告了流式错误');
      return;
    }
    if (event.type === 'error' || eventName === 'error') {
      throw new Error(event.error?.message ?? event.message ?? '服务端报告了流式错误');
    }
    if (event.type === 'message_stop') {
      this.done = true;
      return;
    }
    const delta = event.delta;
    const block = event.type === 'content_block_start' ? event.content_block : undefined;
    if (event.type === 'content_block_start') {
      this.receivedContent = true;
    }
    if (block && ['tool_use', 'server_tool_use', 'web_search_tool_result', 'web_fetch_tool_result'].includes(block.type ?? '')) {
      this.outcome.canPrefill = false;
    }
    if (event.type === 'message_delta' && delta?.stop_reason) {
      this.outcome.stopReason = delta.stop_reason;
      if ((delta.stop_reason === 'end_turn' || delta.stop_reason === 'max_tokens') && typeof delta.title === 'string') {
        this.outcome.title = delta.title.trim();
      }
    }
    if (block?.type === 'thinking') {
      this.outcome.thinkingSignature = block.signature ?? '';
    }
    if (delta?.type === 'signature_delta') {
      this.outcome.thinkingSignature += delta.signature ?? '';
    }
    const content = delta?.type === 'text_delta' && typeof delta.text === 'string' ? delta.text :
      block?.type === 'text' ? block.text ?? '' : '';
    const reasoning = delta?.type === 'thinking_delta' && typeof delta.thinking === 'string' ? delta.thinking :
      block?.type === 'thinking' ? block.thinking ?? '' : '';
    if (content || reasoning) {
      this.hasReply = true;
      this.onDelta(content, reasoning);
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
      const withImages = messages.some((message: NativeChatMessage): boolean =>
        message.files?.some((file: NativeChatFileRef): boolean => file.isImage) ?? false);
      if (withImages) {
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
      this.settleRequest = settle;
      try {
        request.on('dataReceive', (bytes: ArrayBuffer): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          const copied = Math.min(MAX_ERROR_BODY_BYTES - errorBodyLength, bytes.byteLength);
          if (copied > 0) {
            errorBody.set(new Uint8Array(bytes, 0, copied), errorBodyLength);
            errorBodyLength += copied;
          }
          if (streamError) {
            return;
          }
          try {
            stream.push(bytes);
          } catch (error) {
            streamError = error instanceof Error ? error.message : '无法读取模型回复';
          }
        });
        request.requestInStream(endpoint, options).then((status: number): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          if (status < 200 || status >= 300) {
            const message = streamError || httpErrorMessage(errorBody.subarray(0, errorBodyLength), status);
            settle(new NativeModelError(message, status, stream.receivedContent, apiKey, accountToken));
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
