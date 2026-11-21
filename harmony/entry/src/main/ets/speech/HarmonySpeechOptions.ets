import { url } from '@kit.ArkTS';

export type HarmonySpeechEngine = 'auto' | 'native' | 'cloud';
export type HarmonySpeechVoice = 'stella' | 'tide';
export type HarmonySpeechError = 'permission-denied' | 'unavailable' | 'failed' | 'key-required' |
  'unauthorized' | 'quota' | 'rate-limited' | 'network';

export interface HarmonySpeechOptions {
  engine: HarmonySpeechEngine;
  voice: HarmonySpeechVoice;
  apiKey: string;
  baseUrl: string;
  accountActive: boolean;
  locale: string;
}

export interface HarmonySpeechRoute {
  baseUrl: string;
  key: string;
  allowWhisperFallback: boolean;
}

export function resolveHarmonySpeechRoute(options: HarmonySpeechOptions | undefined, synthesis: boolean): HarmonySpeechRoute | undefined {
  const key = options?.apiKey.trim() ?? '';
  if (!options || !key || /[\r\n]/.test(key)) {
    return undefined;
  }
  let endpoint: url.URL;
  try {
    endpoint = url.URL.parseURL(options.baseUrl.trim());
  } catch {
    return undefined;
  }
  if (endpoint.protocol !== 'https:' || !endpoint.hostname || endpoint.username || endpoint.password ||
    endpoint.search || endpoint.hash || /[?#]/.test(options.baseUrl)) {
    return undefined;
  }

  const path = endpoint.pathname.replace(/\/+$/, '')
    .replace(/\/(?:anthropic\/v1\/messages|anthropic\/v1|v1\/chat\/completions|v1)$/i, '')
    .replace(/\/chat\/completions$/i, '');
  const official = endpoint.hostname.toLowerCase() === 'api.deepseek.com' &&
    (!endpoint.port || endpoint.port === '443') && !path;
  if ((synthesis || options.accountActive) && !official) {
    return undefined;
  }
  return {
    baseUrl: endpoint.origin + path,
    key: key,
    allowWhisperFallback: !options.accountActive && !official,
  };
}

export function isCloudAsrAvailable(options: HarmonySpeechOptions | undefined): boolean {
  return resolveHarmonySpeechRoute(options, false) !== undefined;
}

export function isCloudTtsAvailable(options: HarmonySpeechOptions | undefined): boolean {
  return resolveHarmonySpeechRoute(options, true) !== undefined;
}

export function stripHarmonySpeechMarkdown(text: string): string {
  return text.replace(/```[\s\S]*?```|~~~[\s\S]*?~~~/g, ' ')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/\[citation:\d+\]/g, '')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/^\s{0,3}#{1,6}\s+/gm, '')
    .replace(/^\s{0,3}>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\d+\.\s+/gm, '')
    .replace(/[*_~]+/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}
