import { safeNativeSourceUrl } from './NativeChatSources';

export type NativeToolStatus = 'wip' | 'done' | 'failed';

export interface NativeTimelinePage {
  id: string;
  url: string;
  title: string;
  status: NativeToolStatus;
}

export interface NativeTimelinePattern {
  id: string;
  pattern: string;
  status: NativeToolStatus;
}

export interface NativeToolTimelineStep {
  type: string;
  key: string;
  kind?: string;
  status?: NativeToolStatus;
  queries?: string[];
  resultUrls?: string[];
  pages?: NativeTimelinePage[];
  patterns?: NativeTimelinePattern[];
  text?: string;
  startOffset?: number;
  active?: boolean;
}

export interface NativeToolTimelineView {
  steps: NativeToolTimelineStep[];
  answer: string;
  answerOffset: number;
  thinkingSeconds?: number;
}

export interface NativeArchiveTimelineResult {
  url?: string | null;
  title?: string | null;
  signature?: string;
}

export interface NativeArchiveTimelineFragment {
  type: string;
  content?: string;
  elapsed_secs?: number | null;
  status?: string;
  queries?: string[];
  results?: NativeArchiveTimelineResult[];
  url?: string | null;
  title?: string | null;
  pattern?: string;
}

interface ToolInput {
  action: string;
  queries: string[];
  url: string;
  pattern: string;
}

interface ToolCall {
  id: string;
  kind: string;
  input?: ToolInput;
  pendingInput: string;
}

interface ToolResult {
  id: string;
  status: NativeToolStatus;
  urls: string[];
  url: string;
  title: string;
}

interface TimelineBlock {
  type: string;
  text: string;
  startedAt?: number;
  endedAt?: number;
  elapsedSeconds?: number;
  call?: ToolCall;
}

interface RawToolInput {
  action?: string;
  queries?: string[];
  url?: string;
  pattern?: string;
}

interface RawSearchItem {
  type?: string;
  url?: string;
  title?: string;
  snippet?: string | null;
  site_name?: string | null;
  site_icon?: string | null;
  page_age?: string | null;
  error_code?: string;
}

interface RawPageTitle {
  title?: string | null;
}

interface RawFetchResult {
  type?: string;
  url?: string;
  content?: RawPageTitle;
  published_at?: string | null;
  error_code?: string;
}

interface RawBlock {
  type?: string;
  id?: string;
  name?: string;
  kind?: string;
  input?: RawToolInput;
  tool_use_id?: string;
  content?: RawSearchItem[] | RawFetchResult;
  thinking?: string;
  text?: string;
}

interface RawDelta {
  type?: string;
  text?: string;
  thinking?: string;
  partial_json?: string;
}

interface RawEvent {
  type?: string;
  index?: number;
  content_block?: RawBlock;
  delta?: RawDelta;
}

const SEARCH_KINDS = ['search', 'deep_search', 'image_search', 'deep_image_search'];
const MAX_FRAME_CHARS = 4 * 1024 * 1024;
const MAX_TEXT_CHARS = 8 * 1024 * 1024;
const MAX_INPUT_CHARS = 24_576;
const MAX_BLOCKS = 4_096;
const MAX_ITEMS = 256;

export function nativeDeepSearchKind(kind?: string): boolean {
  return kind === 'deep_search' || kind === 'deep_image_search';
}

export function nativeImageSearchKind(kind?: string): boolean {
  return kind === 'image_search' || kind === 'deep_image_search';
}

function boundedId(value?: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 160;
}

function nullableString(value?: string | null): boolean {
  return value == null || typeof value === 'string';
}

function readInput(value?: RawToolInput): ToolInput | undefined {
  if (value?.action === 'search' && Array.isArray(value.queries) &&
    value.queries.every((query: string): boolean => typeof query === 'string')) {
    return {
      action: 'search', url: '', pattern: '',
      queries: value.queries.slice(0, MAX_ITEMS).map((query: string): string => query.slice(0, 1_600)),
    };
  }
  if ((value?.action === 'open_page' || value?.action === 'read_link') && typeof value.url === 'string') {
    return { action: value.action, url: safeNativeSourceUrl(value.url), queries: [], pattern: '' };
  }
  if (value?.action === 'find_in_page' && typeof value.url === 'string' && typeof value.pattern === 'string') {
    return {
      action: 'find_in_page', url: safeNativeSourceUrl(value.url), queries: [], pattern: value.pattern.slice(0, 1_600),
    };
  }
  return undefined;
}

function readCall(block: RawBlock): ToolCall | undefined {
  const id = block.id;
  if (!id || !boundedId(id) || !block.kind || (!SEARCH_KINDS.includes(block.kind) && block.kind !== 'read_link') ||
    (block.name !== 'deepseek_web_search' && block.name !== 'deepseek_read_url') ||
    !block.input || typeof block.input !== 'object' || Array.isArray(block.input)) {
    return undefined;
  }
  const input = readInput(block.input);
  if (!input && Object.keys(block.input).length !== 0) {
    return undefined;
  }
  return { id: id, kind: block.kind, input: input, pendingInput: '' };
}

function readResult(block: RawBlock): ToolResult | undefined {
  const id = block.tool_use_id;
  const content = block.content;
  if (!id || !boundedId(id) || !block.kind) {
    return undefined;
  }
  if (block.type === 'web_search_tool_result' && SEARCH_KINDS.includes(block.kind) && Array.isArray(content)) {
    const urls: string[] = [];
    let failed = false;
    for (const item of content as RawSearchItem[]) {
      if (item?.type === 'web_search_tool_result_error' && typeof item.error_code === 'string') {
        failed = true;
      } else if (urls.length < MAX_ITEMS && item?.type === 'web_search_result' && typeof item.title === 'string' &&
        nullableString(item.snippet) && nullableString(item.site_name) && nullableString(item.site_icon) &&
        nullableString(item.page_age)) {
        const url = safeNativeSourceUrl(item.url);
        if (url) {
          urls.push(url);
        }
      }
    }
    return { id: id, status: failed ? 'failed' : 'done', urls: urls, url: '', title: '' };
  }
  if (block.type === 'web_fetch_tool_result' && (block.kind === 'deep_search' || block.kind === 'read_link') &&
    content && !Array.isArray(content)) {
    const page = content as RawFetchResult;
    if (page.type === 'web_fetch_tool_result_error' && typeof page.error_code === 'string') {
      return { id: id, status: 'failed', urls: [], url: '', title: '' };
    }
    if (page.type === 'web_fetch_result' && typeof page.url === 'string' && page.content &&
      typeof page.content === 'object' && !Array.isArray(page.content) &&
      nullableString(page.content.title) && nullableString(page.published_at)) {
      return {
        id: id, status: 'done', urls: [], url: safeNativeSourceUrl(page.url),
        title: page.content.title?.slice(0, 320) ?? '',
      };
    }
  }
  return undefined;
}

function mergeStatus(first: NativeToolStatus | undefined, second: NativeToolStatus): NativeToolStatus {
  if (first === 'wip' || second === 'wip') {
    return 'wip';
  }
  return first === 'done' || second === 'done' ? 'done' : 'failed';
}

function appendSearch(step: NativeToolTimelineStep, queries: string[], urls: string[], status: NativeToolStatus): void {
  const priorQueries = step.queries ?? [];
  const priorUrls = step.resultUrls ?? [];
  step.queries = priorQueries.concat(queries.slice(0, MAX_ITEMS - priorQueries.length));
  const visible = urls.filter((url: string): boolean => !priorUrls.includes(url));
  step.resultUrls = priorUrls.concat(visible.slice(0, MAX_ITEMS - priorUrls.length));
  step.status = mergeStatus(step.status, status);
}

export class NativeToolTimeline {
  private readonly blocks: TimelineBlock[] = [];
  private readonly openBlocks = new Map<number, TimelineBlock>();
  private readonly results = new Map<string, ToolResult>();
  private textChars: number = 0;
  private completedAt?: number;
  private hasTimeline: boolean = false;

  apply(rawSseData: string, receivedAt: number = Date.now()): boolean {
    if (!rawSseData || rawSseData.length > MAX_FRAME_CHARS || this.completedAt !== undefined) {
      return false;
    }
    let event: RawEvent;
    try {
      event = JSON.parse(rawSseData) as RawEvent;
    } catch {
      return false;
    }
    if (event?.type === 'message_stop') {
      this.completedAt = receivedAt;
      this.openBlocks.clear();
      return this.hasTimeline;
    }
    const index = event?.index;
    if (index === undefined || !Number.isSafeInteger(index) || index < 0) {
      return false;
    }
    if (event.type === 'content_block_start') {
      this.openBlocks.delete(index);
      return event.content_block ? this.start(index, event.content_block, receivedAt) : false;
    }
    if (event.type === 'content_block_delta') {
      return event.delta ? this.delta(index, event.delta) : false;
    }
    if (event.type === 'content_block_stop') {
      const block = this.openBlocks.get(index);
      this.openBlocks.delete(index);
      if (block?.type === 'thinking') {
        block.endedAt = receivedAt;
        return !!block.text;
      }
    }
    return false;
  }

  private keepText(value: string): string {
    const text = value.slice(0, Math.max(0, MAX_TEXT_CHARS - this.textChars));
    this.textChars += text.length;
    return text;
  }

  private start(index: number, raw: RawBlock, receivedAt: number): boolean {
    if (this.blocks.length >= MAX_BLOCKS) {
      return false;
    }
    const block: TimelineBlock = { type: '', text: '', startedAt: receivedAt };
    if ((raw.type === 'text' && typeof raw.text === 'string') ||
      (raw.type === 'thinking' && typeof raw.thinking === 'string')) {
      block.type = raw.type;
      block.text = this.keepText(raw.type === 'text' ? (raw.text ?? '') : (raw.thinking ?? ''));
      if (block.type === 'thinking') {
        this.hasTimeline = true;
      }
    } else if (raw.type === 'server_tool_use') {
      const call = readCall(raw);
      if (!call) {
        return false;
      }
      block.type = 'tool';
      block.call = call;
      this.hasTimeline = this.hasTimeline || call.input !== undefined;
    } else {
      const result = readResult(raw);
      if (!result) {
        return false;
      }
      this.results.set(result.id, result);
      block.type = 'result';
    }
    this.blocks.push(block);
    if (block.type !== 'result') {
      this.openBlocks.set(index, block);
    }
    return this.hasTimeline;
  }

  private delta(index: number, event: RawDelta): boolean {
    const block = this.openBlocks.get(index);
    if (!block) {
      return false;
    }
    const tail = block.type === 'text' && event.type === 'text_delta' ? event.text :
      (block.type === 'thinking' && event.type === 'thinking_delta' ? event.thinking : undefined);
    if (typeof tail === 'string' && tail) {
      const text = this.keepText(tail);
      block.text += text;
      return !!text && this.hasTimeline;
    }
    const call = block.call;
    if (!call || call.input || event.type !== 'input_json_delta' || typeof event.partial_json !== 'string' ||
      call.pendingInput.length + event.partial_json.length > MAX_INPUT_CHARS) {
      return false;
    }
    call.pendingInput += event.partial_json;
    try {
      const candidate = JSON.parse(call.pendingInput) as RawToolInput;
      const input = readInput(candidate);
      if (input) {
        call.input = input;
        call.pendingInput = '';
        this.hasTimeline = true;
        return true;
      }
    } catch {
      // The server may split the tool input JSON across events.
    }
    return false;
  }

  snapshot(streaming: boolean = true, now: number = Date.now()): NativeToolTimelineView {
    return projectTimeline(this.blocks, this.results, streaming && this.completedAt === undefined,
      this.completedAt ?? now);
  }
}

function projectTimeline(blocks: TimelineBlock[], results: Map<string, ToolResult>, active: boolean,
  endTime: number): NativeToolTimelineView {
  const steps: NativeToolTimelineStep[] = [];
  const mergedSearch = new Map<string, NativeToolTimelineStep>();
  let mergedThinking: NativeToolTimelineStep | undefined;
  let pending: string[] = [];
  let textLength = 0;
  let pendingOffset = 0;
  let pendingIndex = 0;
  let thinkingTime = 0;
  let knownThinkingTime = true;
  const flush = (): void => {
    const text = pending.join('');
    if (text.trim()) {
      steps.push({ type: 'text', key: 'text-' + pendingIndex.toString(), text: text, startOffset: pendingOffset });
    }
    pending = [];
  };
  blocks.forEach((block: TimelineBlock, index: number): void => {
    if (block.type === 'template') {
      return;
    }
    if (block.type !== 'thinking') {
      mergedThinking = undefined;
    }
    if (block.type === 'text') {
      if (pending.length === 0) {
        pendingIndex = index;
        pendingOffset = textLength;
      }
      pending.push(block.text);
      textLength += block.text.length;
      return;
    }
    if (block.type === 'thinking') {
      if (mergedThinking || block.text) {
        if (!mergedThinking) {
          flush();
          mergedThinking = { type: 'thinking', key: 'thinking-' + index.toString(), text: '', active: false };
          steps.push(mergedThinking);
        }
        mergedThinking.text = (mergedThinking.text ?? '') + block.text;
        mergedThinking.active = active && block.startedAt !== undefined && block.endedAt === undefined;
        if (block.elapsedSeconds !== undefined) {
          thinkingTime += block.elapsedSeconds * 1_000;
        } else if (block.startedAt !== undefined) {
          thinkingTime += Math.max(0, (block.endedAt ?? endTime) - block.startedAt);
        } else {
          knownThinkingTime = false;
        }
      }
      return;
    }
    const call = block.call;
    const input = call?.input;
    if (!call || !input) {
      return;
    }
    const result = results.get(call.id);
    if (input.action === 'read_link' && !input.url && !result?.url) {
      return;
    }
    flush();
    const status: NativeToolStatus = result?.status ?? (active ? 'wip' : 'failed');
    const last = steps[steps.length - 1];
    if (input.action === 'search') {
      const target = nativeDeepSearchKind(call.kind) ?
        (last?.type === 'search' && last.kind === call.kind ? last : undefined) : mergedSearch.get(call.kind);
      if (target) {
        appendSearch(target, input.queries, result?.urls ?? [], status);
      } else {
        const step: NativeToolTimelineStep = {
          type: 'search', key: call.id, kind: call.kind, queries: input.queries.slice(),
          resultUrls: result?.urls.slice() ?? [], status: status,
        };
        steps.push(step);
        if (!nativeDeepSearchKind(call.kind)) {
          mergedSearch.set(call.kind, step);
        }
      }
      return;
    }
    if (input.action === 'find_in_page') {
      const item: NativeTimelinePattern = { id: call.id, pattern: input.pattern, status: status };
      if (last?.type === 'find') {
        last.patterns?.push(item);
      } else {
        steps.push({ type: 'find', key: call.id, patterns: [item] });
      }
      return;
    }
    if (input.action === 'read_link' && status !== 'wip') {
      return;
    }
    const page: NativeTimelinePage = {
      id: call.id, url: input.url || result?.url || '', title: result?.title || input.url, status: status,
    };
    if (page.title === '') {
      page.title = page.url;
    }
    const group = input.action === 'read_link' ? 'read_link' : 'open';
    if (last?.type === group) {
      last.pages?.push(page);
    } else {
      steps.push({ type: group, key: call.id, pages: [page] });
    }
  });
  return {
    steps: steps,
    answer: pending.join(''),
    answerOffset: pending.length > 0 ? pendingOffset : textLength,
    thinkingSeconds: knownThinkingTime && Number.isFinite(thinkingTime) ?
      Math.min(Number.MAX_SAFE_INTEGER, Math.max(1, Math.round(thinkingTime / 1_000))) : undefined,
  };
}

function appendArchiveTool(blocks: TimelineBlock[], results: Map<string, ToolResult>, id: string, kind: string,
  input: ToolInput, status: string | undefined, urls: string[] = [], title: string = ''): void {
  blocks.push({
    type: 'tool', text: '', call: { id: id, kind: kind, input: input, pendingInput: '' },
  });
  if (status !== 'WIP') {
    const successful = status === undefined || status === 'FINISHED';
    results.set(id, {
      id: id, status: successful ? 'done' : 'failed',
      urls: successful ? urls : [], url: successful ? input.url : '', title: successful ? title : '',
    });
    blocks.push({ type: 'result', text: '' });
  }
}

export function buildArchivedNativeTimeline(fragments: NativeArchiveTimelineFragment[], messageId: string = 'reply',
  refused: boolean = false): NativeToolTimelineView {
  const blocks: TimelineBlock[] = [];
  const results = new Map<string, ToolResult>();
  const searchKind = fragments.some((item: NativeArchiveTimelineFragment): boolean =>
    item?.type === 'TOOL_OPEN' || item?.type === 'TOOL_FIND') ? 'deep_search' : 'search';
  let textChars = 0;
  fragments.slice(0, MAX_BLOCKS).forEach((item: NativeArchiveTimelineFragment, index: number): void => {
    const id = 'history-' + messageId.slice(0, 120) + '-' + index.toString();
    switch (item?.type) {
      case 'TEMPLATE_RESPONSE':
        blocks.push({ type: 'template', text: '' });
        break;
      case 'RESPONSE':
      case 'THINK':
        if (!refused && typeof item.content === 'string') {
          const text = item.content.slice(0, Math.max(0, MAX_TEXT_CHARS - textChars));
          textChars += text.length;
          const elapsed = item.elapsed_secs;
          blocks.push({
            type: item.type === 'THINK' ? 'thinking' : 'text', text: text,
            elapsedSeconds: typeof elapsed === 'number' && Number.isFinite(elapsed) ? elapsed : undefined,
          });
        }
        break;
      case 'TOOL_SEARCH': {
        const queries = Array.isArray(item.queries) ? item.queries.slice(0, MAX_ITEMS)
          .filter((query: string): boolean => typeof query === 'string')
          .map((query: string): string => query.slice(0, 1_600)) : [];
        const urls = Array.isArray(item.results) ? item.results.slice(0, MAX_ITEMS)
          .map((row: NativeArchiveTimelineResult): string => safeNativeSourceUrl(row?.url))
          .filter((url: string): boolean => !!url) : [];
        appendArchiveTool(blocks, results, id, searchKind,
          { action: 'search', url: '', queries: queries, pattern: '' }, item.status, urls);
        break;
      }
      case 'TOOL_OPEN': {
        const url = safeNativeSourceUrl(item.url);
        if (url) {
          appendArchiveTool(blocks, results, id, 'deep_search',
            { action: 'open_page', url: url, queries: [], pattern: '' }, item.status ?? 'FAILED', [],
            typeof item.title === 'string' ? item.title.slice(0, 320) : '');
        }
        break;
      }
      case 'TOOL_FIND':
        appendArchiveTool(blocks, results, id, 'deep_search',
          {
            action: 'find_in_page', url: '', queries: [],
            pattern: typeof item.pattern === 'string' ? item.pattern.slice(0, 1_600) : '',
          }, item.status ?? 'FAILED');
        break;
      case 'READ_LINK':
        if (Array.isArray(item.results)) {
          item.results.slice(0, MAX_ITEMS).forEach((row: NativeArchiveTimelineResult, resultIndex: number): void => {
            const url = safeNativeSourceUrl(row?.url);
            if (url || (typeof row?.signature === 'string' && row.signature.trim())) {
              appendArchiveTool(blocks, results, id + '-' + resultIndex.toString(), 'read_link',
                { action: 'read_link', url: url, queries: [], pattern: '' }, 'FINISHED', [],
                typeof row.title === 'string' ? row.title.slice(0, 320) : '');
            }
          });
        }
        break;
      default:
        break;
    }
  });
  return projectTimeline(blocks, results, false, 0);
}

function validStatus(status?: NativeToolStatus): boolean {
  return status === 'wip' || status === 'done' || status === 'failed';
}

function validTimelineStep(step: NativeToolTimelineStep, answerOffset: number): boolean {
  if (!step || !boundedId(step.key)) {
    return false;
  }
  switch (step.type) {
    case 'search':
      return SEARCH_KINDS.includes(step.kind ?? '') && validStatus(step.status) &&
        Array.isArray(step.queries) && step.queries.length <= MAX_ITEMS &&
        step.queries.every((query: string): boolean => typeof query === 'string' && query.length <= 1_600) &&
        Array.isArray(step.resultUrls) && step.resultUrls.length <= MAX_ITEMS &&
        step.resultUrls.every((address: string): boolean => !!safeNativeSourceUrl(address));
    case 'open':
    case 'read_link':
      return Array.isArray(step.pages) && step.pages.length > 0 && step.pages.length <= MAX_BLOCKS &&
        step.pages.every((page: NativeTimelinePage): boolean => !!page && boundedId(page.id) &&
          typeof page.title === 'string' && page.title.length <= 4_096 &&
          (page.url === '' || !!safeNativeSourceUrl(page.url)) && validStatus(page.status));
    case 'find':
      return Array.isArray(step.patterns) && step.patterns.length > 0 && step.patterns.length <= MAX_BLOCKS &&
        step.patterns.every((pattern: NativeTimelinePattern): boolean => !!pattern && boundedId(pattern.id) &&
          typeof pattern.pattern === 'string' && pattern.pattern.length <= 1_600 && validStatus(pattern.status));
    case 'text':
      return typeof step.text === 'string' && step.startOffset !== undefined && Number.isSafeInteger(step.startOffset) &&
        step.startOffset >= 0 && step.startOffset + step.text.length <= answerOffset;
    case 'thinking':
      return typeof step.text === 'string' && step.text.length <= MAX_TEXT_CHARS &&
        (step.active === undefined || typeof step.active === 'boolean');
    default:
      return false;
  }
}

export function isValidNativeToolTimeline(value?: NativeToolTimelineView): boolean {
  if (!value || typeof value.answer !== 'string' || !Number.isSafeInteger(value.answerOffset) ||
    value.answerOffset < 0 || value.answerOffset + value.answer.length > MAX_TEXT_CHARS ||
    (value.thinkingSeconds !== undefined && (!Number.isSafeInteger(value.thinkingSeconds) || value.thinkingSeconds < 1)) ||
    !Array.isArray(value.steps) || value.steps.length > MAX_BLOCKS) {
    return false;
  }
  return value.steps.every((step: NativeToolTimelineStep): boolean => validTimelineStep(step, value.answerOffset));
}
