import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';

export interface NativeChatFileRef {
  serverId: string;
  isImage: boolean;
}

export interface NativeChatMessage {
  role: string;
  content: string;
  files?: NativeChatFileRef[];
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
}

interface AnthropicEventError {
  message?: string;
}

interface AnthropicDeltaEvent {
  type?: string;
  delta?: AnthropicEventDelta;
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
  type: 'text' | 'image' | 'document';
  source?: AnthropicFileSource;
  text?: string;
}

interface AnthropicChatMessage {
  role: string;
  content: string | AnthropicContentBlock[];
}

interface AnthropicRequestBody {
  model: string;
  system: string;
  messages: AnthropicChatMessage[];
  stream: boolean;
  thinking: AnthropicThinking;
  safety_check: AnthropicSafetyCheck;
  tools?: AnthropicTool[];
}

const DEEPSEEK_ACCOUNT_ORIGIN: string = 'https://api.deepseek.com';
const DEFAULT_DEEPSEEK_SYSTEM: string = '该助手为DeepSeek，由深度求索公司创造。';

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
  private readonly onDelta: (content: string, reasoning: string) => void;
  private readonly protocol: 'openai' | 'anthropic';

  constructor(onDelta: (content: string, reasoning: string) => void,
    protocol: 'openai' | 'anthropic' = 'openai') {
    this.onDelta = onDelta;
    this.protocol = protocol;
  }

  push(bytes: ArrayBuffer): void {
    this.appendText(this.decoder.decodeToString(new Uint8Array(bytes), { stream: true }));
  }

  end(): void {
    this.appendText(this.decoder.decodeToString(new Uint8Array(0), { stream: false }));
    if (this.pendingLine.endsWith('\r')) {
      this.readLine(this.pendingLine.slice(0, -1));
    }
    if (!this.hasReply) {
      throw new Error('模型未返回可读取的回复，请检查服务器地址和模型名称');
    }
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
    const delta = chunk.choices?.[0]?.delta;
    const content = typeof delta?.content === 'string' ? delta.content : '';
    const reasoningValue = delta?.reasoning_content ?? delta?.reasoning;
    const reasoning = typeof reasoningValue === 'string' ? reasoningValue : '';
    if (content || reasoning) {
      this.hasReply = true;
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
    const content = delta?.type === 'text_delta' && typeof delta.text === 'string' ? delta.text : '';
    const reasoning = delta?.type === 'thinking_delta' && typeof delta.thinking === 'string' ? delta.thinking : '';
    if (content || reasoning) {
      this.hasReply = true;
      this.onDelta(content, reasoning);
    }
  }
}

function anthropicMessage(message: NativeChatMessage): AnthropicChatMessage {
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
  private settleRequest?: (error?: Error) => void;

  cancel(): void {
    this.settleRequest?.();
  }

  async send(config: NativeChatConfig, messages: NativeChatMessage[],
    onDelta: (content: string, reasoning: string) => void): Promise<void> {
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
      const withDocuments = messages.some((message: NativeChatMessage): boolean =>
        message.files?.some((file: NativeChatFileRef): boolean => !file.isImage) ?? false);
      const withImages = messages.some((message: NativeChatMessage): boolean =>
        message.files?.some((file: NativeChatFileRef): boolean => file.isImage) ?? false);
      if (withImages) {
        headers['anthropic-beta'] = 'files-api-2025-04-14';
      }
      const lastPrompt = messages.length ? messages[messages.length - 1].content : '';
      const omitExtended = withDocuments && !config.search && !/https?:\/\//i.test(lastPrompt);
      body = {
        model: model,
        system: config.system ?? DEFAULT_DEEPSEEK_SYSTEM,
        messages: messages.map<AnthropicChatMessage>(anthropicMessage),
        stream: true,
        thinking: { type: config.thinking ? 'enabled' : 'disabled' },
        safety_check: { level: omitExtended ? 'low' : 'high' },
        tools: omitExtended ? undefined : tools,
      } as AnthropicRequestBody;
    } else {
      const textMessages = messages.filter((message: NativeChatMessage): boolean => !!message.content)
        .map<NativeChatMessage>((message: NativeChatMessage): NativeChatMessage => ({
          role: message.role, content: message.content,
        }));
      body = { model: model, messages: textMessages, stream: true } as ChatRequestBody;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      usingCache: false,
      maxRedirects: 0,
      connectTimeout: 15000,
      readTimeout: 300000,
    };
    const request = http.createHttp();
    return new Promise<void>((resolve, reject) => {
      const settle = (error?: Error): void => {
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
          resolve();
        }
      };
      const stream = new ChatStream((content: string, reasoning: string): void => {
        if (this.settleRequest === settle) {
          onDelta(content, reasoning);
        }
      }, protocol);
      this.settleRequest = settle;
      try {
        request.on('dataReceive', (bytes: ArrayBuffer): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          try {
            stream.push(bytes);
          } catch (error) {
            const message = error instanceof Error ? error.message : '无法读取模型回复';
            settle(new Error(redactCredentials(message, apiKey, accountToken)));
          }
        });
        request.requestInStream(endpoint, options).then((status: number): void => {
          if (this.settleRequest !== settle) {
            return;
          }
          if (status < 200 || status >= 300) {
            settle(new Error(`服务端请求失败 (HTTP ${status})`));
            return;
          }
          try {
            stream.end();
            settle();
          } catch (error) {
            const message = error instanceof Error ? error.message : '无法读取模型回复';
            settle(new Error(redactCredentials(message, apiKey, accountToken)));
          }
        }, (error: BusinessError): void => {
          settle(new Error(`无法连接模型服务 (${error.code})`));
        });
      } catch {
        settle(new Error('无法发起模型请求'));
      }
    });
  }
}
