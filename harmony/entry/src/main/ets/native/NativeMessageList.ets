import { NativeConversationMessage } from './NativeConversation';

export const CHAT_PAGE_SIZE = 40;

@Observed
export class NativeMessageRow {
  readonly key: number;
  readonly index: number;
  message: NativeConversationMessage;

  constructor(key: number, index: number, message: NativeConversationMessage) {
    this.key = key;
    this.index = index;
    this.message = message;
  }
}

export interface NativeMessageRange {
  start: number;
  end: number;
}

export function nativeMessageRange(total: number, count: number, fromTop: boolean): NativeMessageRange {
  return fromTop ? { start: 0, end: Math.min(total, count) } :
    { start: Math.max(0, total - count), end: total };
}

function isGeneratingReply(message: NativeConversationMessage): boolean {
  return message.role === 'assistant' && (message.status === 'pending' || message.status === 'streaming');
}

function isSettledReply(message: NativeConversationMessage): boolean {
  return message.role === 'assistant' &&
    (message.status === 'done' || message.status === 'error' || message.status === 'stopped');
}

export class NativeMessageList implements IDataSource {
  private rows: NativeMessageRow[] = [];
  private listeners: DataChangeListener[] = [];
  private sequence: number = 0;

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): NativeMessageRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }

  update(path: NativeConversationMessage[], range: NativeMessageRange, keepReplyView: boolean = true): void {
    const byId = new Map<string, NativeMessageRow>();
    for (const row of this.rows) byId.set(row.message.id, row);
    const next: NativeMessageRow[] = [];
    let unchangedPrefix = 0;
    for (let index = range.start; index < range.end; index++) {
      const message = path[index];
      const prior = byId.get(message.id);
      const replyTransition = prior && keepReplyView &&
        ((isGeneratingReply(prior.message) && isSettledReply(message)) ||
          (isSettledReply(prior.message) && isGeneratingReply(message)));
      let row: NativeMessageRow;
      if (prior && prior.index === index && (prior.message === message || replyTransition)) {
        row = prior;
        // Updating the observed row preserves Markdown state across continuation and completion.
        if (replyTransition) row.message = message;
      } else {
        row = new NativeMessageRow(++this.sequence, index, message);
      }
      if (next.length === unchangedPrefix && row === this.rows[next.length]) unchangedPrefix++;
      next.push(row);
    }
    const previousCount = this.rows.length;
    if (unchangedPrefix === previousCount && previousCount === next.length) return;
    this.rows = next;
    // LazyForEach requires one notification API for both appends and reloads.
    const operation: DataOperation = unchangedPrefix === previousCount && next.length > previousCount ?
      { type: DataOperationType.ADD, index: previousCount, count: next.length - previousCount } :
      { type: DataOperationType.RELOAD };
    this.listeners.forEach((listener: DataChangeListener): void => listener.onDatasetChange([operation]));
  }
}
