import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';

export interface NativeChatMessage {
  role: string;
  content: string;
}

export interface NativeChatConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
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

  constructor(onDelta: (content: string, reasoning: string) => void) {
    this.onDelta = onDelta;
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
    const endpoint = resolveChatEndpoint(config.baseUrl, !!apiKey);
    const model = config.model.trim();
    if (!model) {
      throw new Error('请输入模型名称');
    }
    if (/[\r\n]/.test(apiKey)) {
      throw new Error('API 密钥中不能包含换行');
    }
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    };
    if (apiKey) {
      headers['authorization'] = `Bearer ${apiKey}`;
    }
    const body: ChatRequestBody = { model, messages, stream: true };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      usingCache: false,
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
      });
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
            const safeMessage = apiKey ? message.split(apiKey).join('••••') : message;
            settle(new Error(safeMessage.slice(0, 240)));
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
            const safeMessage = apiKey ? message.split(apiKey).join('••••') : message;
            settle(new Error(safeMessage.slice(0, 240)));
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
