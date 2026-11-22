import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { NativeApiProtocol } from './NativeSettings';

export interface NativeApiCredential {
  baseUrl: string;
  model: string;
  protocol: NativeApiProtocol;
  apiKey: string;
}

function isPrivateIpv4(host: string): boolean {
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  const octets: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) {
      return false;
    }
    const octet = Number(part);
    if (octet < 0 || octet > 255) {
      return false;
    }
    octets.push(octet);
  }
  return octets[0] === 10 || octets[0] === 127 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
}

function isLocalNativeHost(rawHost: string): boolean {
  let host = rawHost.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.slice(1, -1);
  }
  if (host.endsWith('.')) {
    host = host.slice(0, -1);
  }
  if (host === 'localhost' || isPrivateIpv4(host)) {
    return true;
  }
  if (host === '::1' || /^f[cd][0-9a-f]{2}:/.test(host)) {
    return true;
  }
  if (host.startsWith('::ffff:')) {
    const mapped = host.slice('::ffff:'.length);
    if (isPrivateIpv4(mapped)) {
      return true;
    }
    const groups = mapped.split(':');
    if (groups.length === 2 && groups.every((group: string): boolean => /^[0-9a-f]{1,4}$/.test(group))) {
      const high = Number.parseInt(groups[0], 16);
      const low = Number.parseInt(groups[1], 16);
      return isPrivateIpv4(`${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`);
    }
  }
  return false;
}

/** Keyless HTTP is limited to direct OpenAI-compatible calls to local/private hosts. */
export function allowsKeylessNativeApi(baseUrl: string, protocol: NativeApiProtocol): boolean {
  if (protocol !== 'openai') {
    return false;
  }
  let endpoint: url.URL;
  try {
    endpoint = url.URL.parseURL(baseUrl.trim());
  } catch {
    return false;
  }
  return endpoint.protocol === 'http:' && !!endpoint.hostname && !endpoint.username && !endpoint.password &&
    !endpoint.hash && baseUrl.indexOf('#') < 0 && isLocalNativeHost(endpoint.hostname);
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
    credential.baseUrl.indexOf('#') >= 0 ||
    (endpoint.protocol !== 'https:' && endpoint.protocol !== 'http:')) {
    throw new Error('请输入不含账号、密码或片段的 HTTP 或 HTTPS 地址');
  }
  const key = credential.apiKey.trim();
  if (!key && !allowsKeylessNativeApi(credential.baseUrl, credential.protocol)) {
    throw new Error('请输入 API Key；仅局域网 OpenAI 兼容地址可留空');
  }
  if (key && endpoint.protocol !== 'https:') {
    throw new Error('使用 API Key 时，地址必须为 HTTPS');
  }
  if (/[\r\n]/.test(key)) {
    throw new Error('API Key 中不能包含换行');
  }
  if (key && !/^[\x21-\x7e]+$/.test(key)) {
    throw new Error('API Key 包含无效字符（如中文、空格或全角符号），请仅粘贴纯英文与数字密钥');
  }
  if (!credential.model.trim()) {
    throw new Error('请输入模型名称');
  }

  const path = endpoint.pathname.replace(/\/+$/, '');
  if (credential.protocol === 'anthropic') {
    endpoint.pathname = `${path.replace(/\/(?:anthropic(?:\/v1(?:\/messages)?)?|v1)$/i, '')}/models`;
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
      usingProxy: key ? undefined : false,
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
