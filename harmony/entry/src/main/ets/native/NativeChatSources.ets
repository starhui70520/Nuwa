import { url } from '@kit.ArkTS';

export interface NativeChatSource {
  index: number;
  url: string;
  title: string;
  siteName: string;
  snippet: string | null;
  publishedAt: string | null;
  siteIcon: string | null;
  searchResult: boolean;
}

export interface NativeChatCitation {
  offset: number;
  sourceIndex: number;
}

interface RawCitation {
  type?: string;
  url?: string;
  title?: string | null;
}

interface RawSearchItem {
  type?: string;
  url?: string;
  title?: string;
  snippet?: string | null;
  site_name?: string | null;
  site_icon?: string | null;
  page_age?: string | null;
}

interface RawPageTitle {
  title?: string | null;
}

interface RawWebPage {
  type?: string;
  url?: string;
  published_at?: string | null;
  content?: RawPageTitle;
}

interface RawToolInput {
  action?: string;
  queries?: string[];
  url?: string;
  pattern?: string;
}

interface RawBlock {
  type?: string;
  text?: string;
  citations?: RawCitation[];
  id?: string;
  kind?: string;
  name?: string;
  input?: RawToolInput;
  tool_use_id?: string;
  content?: RawSearchItem[] | RawWebPage;
}

interface RawDelta {
  type?: string;
  text?: string;
  citation?: RawCitation;
}

interface RawEvent {
  type?: string;
  index?: number;
  content_block?: RawBlock;
  delta?: RawDelta;
}

interface SourceSeed {
  url: string;
  title: string;
  host: string;
  siteName: string;
  snippet: string | null;
  publishedAt: string | null;
  siteIcon: string | null;
}

interface ToolResults {
  kind: string;
  searchResult: boolean;
  seeds: SourceSeed[];
}

interface CitationText {
  order: number;
  length: number;
  lastContentEnd: number;
  seeds: Map<string, SourceSeed>;
}

interface SourcesView {
  sources: NativeChatSource[];
  citations: NativeChatCitation[];
}

const MAX_EVENT_LENGTH = 4 * 1024 * 1024;
const MAX_SOURCES = 256;
const MAX_TOOL_BLOCKS = 1_024;
const MAX_TEXT_BLOCKS = 4_096;
const SEARCH_KINDS = ['search', 'deep_search', 'image_search', 'deep_image_search'];

function parseSourceUrl(value?: string | null): url.URL | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const candidate = value.trim();
  if (candidate.length > 4_096 || !/^https?:\/\//i.test(candidate) || /[\u0000-\u001f\u007f\\]/.test(candidate)) {
    return undefined;
  }
  try {
    const parsed = url.URL.parseURL(candidate);
    if ((parsed.protocol === 'https:' || parsed.protocol === 'http:') && parsed.hostname &&
      !parsed.username && !parsed.password) {
      return parsed;
    }
  } catch {
    // Invalid source addresses are omitted.
  }
  return undefined;
}

export function safeNativeSourceUrl(value?: string | null): string {
  return parseSourceUrl(value) && typeof value === 'string' ? value.trim() : '';
}

function clean(value: string | null | undefined, limit: number): string {
  return typeof value === 'string' ? value.trim().slice(0, limit) : '';
}

function nullableString(value?: string | null): boolean {
  return value === undefined || value === null || typeof value === 'string';
}

function sourceSeed(value?: string, title?: string | null, publishedAt?: string | null,
  metadata?: RawSearchItem): SourceSeed | undefined {
  const parsed = parseSourceUrl(value);
  if (!parsed || typeof value !== 'string') {
    return undefined;
  }
  const address = value.trim();
  const host = parsed.hostname.replace(/^www\./i, '');
  return {
    url: address,
    title: clean(title, 320) || address,
    host: host,
    siteName: clean(metadata?.site_name, 120) || host,
    snippet: clean(metadata?.snippet, 1_600) || null,
    publishedAt: clean(publishedAt, 120) || null,
    siteIcon: safeNativeSourceUrl(metadata?.site_icon) || null,
  };
}

function citationSeed(citation?: RawCitation): SourceSeed | undefined {
  return citation?.type === 'web_search_result_location' && nullableString(citation.title) ?
    sourceSeed(citation.url, citation.title) : undefined;
}

function validToolId(id?: string): boolean {
  return typeof id === 'string' && id.length > 0 && id.length <= 160;
}

function toolUse(block: RawBlock): boolean {
  if (!validToolId(block.id) || (block.name !== 'deepseek_web_search' && block.name !== 'deepseek_read_url') ||
    (!SEARCH_KINDS.includes(block.kind ?? '') && block.kind !== 'read_link') || !block.input) {
    return false;
  }
  switch (block.input.action) {
    case 'search':
      return Array.isArray(block.input.queries) &&
        block.input.queries.every((query: string): boolean => typeof query === 'string');
    case 'open_page':
    case 'read_link':
      return typeof block.input.url === 'string';
    case 'find_in_page':
      return typeof block.input.url === 'string' && typeof block.input.pattern === 'string';
    default:
      return false;
  }
}

function toolResult(block: RawBlock): ToolResults | undefined {
  const kind = block.kind;
  if (!kind || !validToolId(block.tool_use_id)) {
    return undefined;
  }
  const content = block.content;
  if (block.type === 'web_search_tool_result' && SEARCH_KINDS.includes(kind) && Array.isArray(content)) {
    const seeds: SourceSeed[] = [];
    for (const item of (content as RawSearchItem[])) {
      if (item?.type !== 'web_search_result' || typeof item.title !== 'string' || !nullableString(item.site_name) ||
        !nullableString(item.site_icon) || !nullableString(item.snippet) || !nullableString(item.page_age)) {
        continue;
      }
      const seed = sourceSeed(item.url, item.title, item.page_age, item);
      if (seed) {
        seeds.push(seed);
        if (seeds.length >= MAX_SOURCES) {
          break;
        }
      }
    }
    return { kind: kind, searchResult: true, seeds: seeds };
  }
  if (block.type === 'web_fetch_tool_result' && (kind === 'deep_search' || kind === 'read_link') &&
    content && !Array.isArray(content)) {
    const page = content as RawWebPage;
    const seed = page.type === 'web_fetch_result' && page.content && nullableString(page.content.title) &&
      nullableString(page.published_at) ? sourceSeed(page.url, page.content.title, page.published_at) : undefined;
    return { kind: kind, searchResult: false, seeds: seed && kind === 'deep_search' ? [seed] : [] };
  }
  return undefined;
}

function indexOfEvent(index?: number): number | undefined {
  return index !== undefined && Number.isSafeInteger(index) && index >= 0 ? index : undefined;
}

function appendText(block: CitationText, content: string): void {
  const trimmed = content.trimEnd().length;
  if (trimmed > 0) {
    block.lastContentEnd = block.length + trimmed;
  }
  block.length += content.length;
}

function setCitation(block: CitationText, citation: SourceSeed): boolean {
  const previous = block.seeds.get(citation.url);
  if (previous && (previous.title !== previous.url || previous.title === citation.title)) {
    return false;
  }
  if (!previous && block.seeds.size >= MAX_SOURCES) {
    return false;
  }
  block.seeds.set(citation.url, citation);
  return true;
}

function register(sources: NativeChatSource[], byUrl: Map<string, NativeChatSource>, seed: SourceSeed,
  searchResult: boolean): number {
  const known = byUrl.get(seed.url);
  if (known) {
    if (known.title === known.url) {
      known.title = seed.title;
    }
    if (known.siteName === seed.host) {
      known.siteName = seed.siteName;
    }
    known.snippet = known.snippet ?? seed.snippet;
    known.publishedAt = known.publishedAt ?? seed.publishedAt;
    known.siteIcon = known.siteIcon ?? seed.siteIcon;
    known.searchResult = known.searchResult || searchResult;
    return known.index;
  }
  if (sources.length >= MAX_SOURCES) {
    return 0;
  }
  const source: NativeChatSource = {
    index: sources.length + 1,
    url: seed.url,
    title: seed.title,
    siteName: seed.siteName,
    snippet: seed.snippet,
    publishedAt: seed.publishedAt,
    siteIcon: seed.siteIcon,
    searchResult: searchResult,
  };
  sources.push(source);
  byUrl.set(source.url, source);
  return source.index;
}

function sameSource(source: NativeChatSource, other: NativeChatSource): boolean {
  return source.index === other.index && source.url === other.url && source.title === other.title &&
    source.siteName === other.siteName && source.snippet === other.snippet && source.publishedAt === other.publishedAt &&
    source.siteIcon === other.siteIcon && source.searchResult === other.searchResult;
}

function sameView(a: SourcesView, b: SourcesView): boolean {
  return a.sources.length === b.sources.length && a.citations.length === b.citations.length &&
    a.sources.every((source: NativeChatSource, index: number): boolean => sameSource(source, b.sources[index])) &&
    a.citations.every((citation: NativeChatCitation, index: number): boolean =>
      citation.offset === b.citations[index].offset && citation.sourceIndex === b.citations[index].sourceIndex);
}

export class NativeChatSources {
  private readonly calls = new Map<string, string>();
  private readonly results = new Map<string, ToolResults>();
  private readonly texts: CitationText[] = [];
  private readonly openText = new Map<number, CitationText>();
  private lastCitedBlock: number = -1;
  private view: SourcesView = { sources: [], citations: [] };

  apply(rawSseData: string): boolean {
    if (!rawSseData || rawSseData.length > MAX_EVENT_LENGTH) {
      return false;
    }
    let event: RawEvent;
    try {
      event = JSON.parse(rawSseData) as RawEvent;
    } catch {
      return false;
    }
    const index = indexOfEvent(event?.index);
    if (index === undefined) {
      return false;
    }
    switch (event.type) {
      case 'content_block_start':
        this.openText.delete(index);
        return event.content_block ? this.start(index, event.content_block) : false;
      case 'content_block_delta':
        return event.delta ? this.delta(index, event.delta) : false;
      case 'content_block_stop':
        this.openText.delete(index);
        return false;
      default:
        return false;
    }
  }

  snapshot(): NativeChatSource[] {
    return this.view.sources.map((source: NativeChatSource): NativeChatSource => ({
      index: source.index,
      url: source.url,
      title: source.title,
      siteName: source.siteName,
      snippet: source.snippet,
      publishedAt: source.publishedAt,
      siteIcon: source.siteIcon,
      searchResult: source.searchResult,
    }));
  }

  citationSnapshot(): NativeChatCitation[] {
    return this.view.citations.map((item: NativeChatCitation): NativeChatCitation => ({
      offset: item.offset,
      sourceIndex: item.sourceIndex,
    }));
  }

  private start(index: number, block: RawBlock): boolean {
    if (block.type === 'text') {
      return this.startText(index, block);
    }
    if (block.type === 'server_tool_use' && block.id && block.kind && toolUse(block) &&
      (this.calls.has(block.id) || this.calls.size < MAX_TOOL_BLOCKS)) {
      this.calls.set(block.id, block.kind);
      return this.results.has(block.id) && this.publish();
    }
    if (block.tool_use_id && (this.results.has(block.tool_use_id) || this.results.size < MAX_TOOL_BLOCKS)) {
      const result = toolResult(block);
      if (result) {
        this.results.set(block.tool_use_id, result);
        return this.calls.has(block.tool_use_id) && this.publish();
      }
    }
    return false;
  }

  private startText(index: number, event: RawBlock): boolean {
    if (typeof event.text !== 'string' || this.texts.length >= MAX_TEXT_BLOCKS) {
      return false;
    }
    const block: CitationText = {
      order: this.texts.length, length: 0, lastContentEnd: 0, seeds: new Map<string, SourceSeed>(),
    };
    appendText(block, event.text);
    this.texts.push(block);
    this.openText.set(index, block);
    if (Array.isArray(event.citations)) {
      for (const item of event.citations) {
        const citation = citationSeed(item);
        if (citation) {
          setCitation(block, citation);
        }
      }
    }
    if (block.seeds.size === 0) {
      return false;
    }
    this.lastCitedBlock = block.order;
    return this.publish();
  }

  private delta(index: number, event: RawDelta): boolean {
    const block = this.openText.get(index);
    if (!block) {
      return false;
    }
    if (event.type === 'text_delta' && typeof event.text === 'string' && event.text) {
      appendText(block, event.text);
      return block.order <= this.lastCitedBlock && this.publish();
    }
    if (event.type === 'citations_delta') {
      const citation = citationSeed(event.citation);
      if (citation && setCitation(block, citation)) {
        this.lastCitedBlock = Math.max(this.lastCitedBlock, block.order);
        return this.publish();
      }
    }
    return false;
  }

  private publish(): boolean {
    const sources: NativeChatSource[] = [];
    const citations: NativeChatCitation[] = [];
    const byUrl = new Map<string, NativeChatSource>();
    // Android assigns tool-result indices in call order before assigning citation-only indices.
    this.calls.forEach((kind: string, id: string): void => {
      const result = this.results.get(id);
      if (result && result.kind === kind) {
        for (const seed of result.seeds) {
          register(sources, byUrl, seed, result.searchResult);
        }
      }
    });
    let textOffset = 0;
    for (const text of this.texts) {
      text.seeds.forEach((seed: SourceSeed): void => {
        const index = register(sources, byUrl, seed, false);
        if (index > 0) {
          citations.push({ offset: textOffset + text.lastContentEnd, sourceIndex: index });
        }
      });
      textOffset += text.length;
    }
    const next: SourcesView = { sources: sources, citations: citations };
    if (sameView(next, this.view)) {
      return false;
    }
    this.view = next;
    return true;
  }
}
