import { url } from '@kit.ArkTS';
import { safeNativeSourceUrl } from './NativeChatSources';

export interface NativeReadLink {
  id: string;
  url: string;
  title: string | null;
  signature: string;
  offset: number;
  // Live links follow the credential binding. Android imports have no binding and use DeepSeek only.
  binding?: string;
}

interface ReadLinkInput {
  action?: string;
  url?: string;
}

interface ReadLinkDocument {
  title?: string | null;
}

interface ReadLinkPayload {
  type?: string;
  url?: string;
  content?: ReadLinkDocument;
}

interface ReadLinkEventBlock {
  type?: string;
  kind?: string;
  id?: string;
  name?: string;
  input?: ReadLinkInput;
  tool_use_id?: string;
  signature?: string;
  content?: ReadLinkPayload;
}

interface ReadLinkEvent {
  type?: string;
  content_block?: ReadLinkEventBlock;
}

interface PendingReadLink {
  url: string;
  offset: number;
}

const MAX_SIGNATURE = 2 * 1024 * 1024;
const MAX_SIGNATURE_TOTAL = 8 * 1024 * 1024;
const MAX_LINKS = 64;
const MAX_FRAME = 4 * 1024 * 1024;

export function validNativeReadLinks(links: NativeReadLink[], textLength: number): boolean {
  if (!Array.isArray(links) || links.length > MAX_LINKS) return false;
  const ids = new Set<string>();
  let total = 0;
  let previousOffset = 0;
  for (const link of links) {
    if (!link || typeof link.id !== 'string' || !/^[\w-]{1,160}$/.test(link.id) || ids.has(link.id) ||
      typeof link.url !== 'string' || (link.url !== '' && !safeNativeSourceUrl(link.url)) ||
      (link.title !== null && (typeof link.title !== 'string' || link.title.length > 512)) ||
      typeof link.signature !== 'string' || link.signature.length > MAX_SIGNATURE || !link.signature.trim() ||
      !Number.isSafeInteger(link.offset) || link.offset < previousOffset || link.offset > textLength ||
      (link.binding !== undefined && (typeof link.binding !== 'string' || !link.binding || link.binding.length > 100))) {
      return false;
    }
    total += link.signature.length;
    if (total > MAX_SIGNATURE_TOTAL) return false;
    ids.add(link.id);
    previousOffset = link.offset;
  }
  return true;
}

export function useNativeReadLink(link: NativeReadLink, binding: string, baseUrl: string, account: boolean): boolean {
  return link.binding ? link.binding === binding : isOfficialNativeReadLinkRoute(baseUrl, account);
}

export function isOfficialNativeReadLinkRoute(baseUrl: string, account: boolean): boolean {
  if (account) return true;
  try {
    const endpoint = url.URL.parseURL(baseUrl);
    return endpoint.protocol === 'https:' && endpoint.hostname === 'api.deepseek.com' &&
      (!endpoint.port || endpoint.port === '443') && !endpoint.username && !endpoint.password;
  } catch {
    return false;
  }
}

export class NativeReadLinkCollector {
  private readonly pending: Map<string, PendingReadLink> = new Map();
  private readonly accepted: NativeReadLink[] = [];
  private readonly binding?: string;
  private totalSignatureLength: number = 0;

  constructor(binding?: string) {
    this.binding = binding;
  }

  apply(data: string, offset: number): NativeReadLink | undefined {
    if (!data || data.length > MAX_FRAME) return undefined;
    let event: ReadLinkEvent;
    try {
      event = JSON.parse(data) as ReadLinkEvent;
    } catch {
      return undefined;
    }
    const block = event?.content_block;
    if (event?.type !== 'content_block_start' || block?.kind !== 'read_link') return undefined;
    if (block.type === 'server_tool_use' && block.name === 'deepseek_read_url' &&
      typeof block.id === 'string' && /^[\w-]{1,160}$/.test(block.id) && block.input?.action === 'read_link' &&
      this.pending.size < MAX_LINKS) {
      this.pending.set(block.id, { url: safeNativeSourceUrl(block.input.url), offset });
      return undefined;
    }
    const id = block.tool_use_id;
    if (block.type !== 'web_fetch_tool_result' || typeof id !== 'string') return undefined;
    const call = this.pending.get(id);
    this.pending.delete(id);
    const signature = block.signature;
    if (!call || block.content?.type !== 'web_fetch_result' || typeof signature !== 'string' ||
      !signature.trim() || signature.length > MAX_SIGNATURE || this.totalSignatureLength + signature.length > MAX_SIGNATURE_TOTAL ||
      this.accepted.length >= MAX_LINKS || this.accepted.some((link: NativeReadLink): boolean => link.id === id)) {
      return undefined;
    }
    const title = block.content.content?.title;
    const link: NativeReadLink = {
      id, url: safeNativeSourceUrl(block.content.url) || call.url,
      title: typeof title === 'string' ? title.slice(0, 512) : null,
      signature, offset: call.offset, binding: this.binding,
    };
    this.accepted.push(link);
    this.totalSignatureLength += signature.length;
    return link;
  }
}
