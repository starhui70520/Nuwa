import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { NativeApiProtocol } from './NativeSettings';

export interface NativeApiCredential {
  baseUrl: string;
  model: string;
  protocol: NativeApiProtocol;
  apiKey: string;
}

/** Validate using the same read-only model endpoint and gateway exceptions as Android. */
export async function verifyNativeApiCredential(credential: NativeApiCredential): Promise<void> {
  let endpoint: url.URL;
  try {
    endpoint = url.URL.parseURL(credential.baseUrl.trim());
  } catch {
    throw new Error('请输入有效的 API 地址');
  }
  if (!endpoint.hostname || endpoint.username || endpoint.password || endpoint.hash ||
    (endpoint.protocol !== 'https:' && endpoint.protocol !== 'http:')) {
    throw new Error('请输入不含账号、密码或片段的 HTTP 或 HTTPS 地址');
  }
  const key = credential.apiKey.trim();
  if (key && endpoint.protocol !== 'https:') {
    throw new Error('使用 API Key 时，地址必须为 HTTPS');
  }
  if (/[\r\n]/.test(key)) {
    throw new Error('API Key 中不能包含换行');
  }
  if (!credential.model.trim()) {
    throw new Error('请输入模型名称');
  }

  const path = endpoint.pathname.replace(/\/+$/, '');
  if (credential.protocol === 'anthropic') {
    endpoint.pathname = `${path.replace(/\/(?:anthropic\/v1(?:\/messages)?|v1)$/i, '')}/models`;
  } else {
    endpoint.pathname = `${path.replace(/\/chat\/completions$/, '') || '/v1'}/models`;
  }
  const headers: Record<string, string> = {};
  if (key) {
    headers['authorization'] = `Bearer ${key}`;
  }
  const request = http.createHttp();
  let status: number;
  try {
    const response = await request.request(endpoint.href, {
      method: http.RequestMethod.GET,
      header: headers,
      usingCache: false,
      maxRedirects: 0,
      connectTimeout: 10000,
      readTimeout: 15000,
    });
    status = response.responseCode;
  } catch {
    throw new Error('网络异常，请检查你的网络状况');
  } finally {
    request.destroy();
  }
  if (status === 401 || status === 403) {
    throw new Error('API Key 无效，请检查后重试');
  }
  if (credential.protocol === 'openai' && (status === 404 || status === 405)) {
    return;
  }
  if (status < 200 || status >= 300) {
    throw new Error(`校验失败：HTTP ${status}`);
  }
}
