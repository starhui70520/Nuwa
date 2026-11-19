import { NativeConversationMessage } from './NativeConversation';

export const CHAT_PAGE_SIZE = 40;

export interface NativeMessageRow {
  key: number;
  index: number;
  message: NativeConversationMessage;
}

export interface NativeMessageRange {
  start: number;
  end: number;
}

export function nativeMessageRange(total: number, count: number, fromTop: boolean): NativeMessageRange {
  return fromTop ? { start: 0, end: Math.min(total, count) } :
    { start: Math.max(0, total - count), end: total };
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

  update(path: NativeConversationMessage[], range: NativeMessageRange): void {
    const byId = new Map<string, NativeMessageRow>();
    for (const row of this.rows) byId.set(row.message.id, row);
    const next: NativeMessageRow[] = [];
    let unchangedPrefix = 0;
    for (let index = range.start; index < range.end; index++) {
      const message = path[index];
      const prior = byId.get(message.id);
      const row: NativeMessageRow = prior && prior.message === message && prior.index === index ? prior :
        { key: ++this.sequence, message, index };
      if (next.length === unchangedPrefix && row === this.rows[next.length]) unchangedPrefix++;
      next.push(row);
    }
    const previousCount = this.rows.length;
    if (unchangedPrefix === previousCount && previousCount === next.length) return;
    this.rows = next;
    if (unchangedPrefix === previousCount && next.length > previousCount) {
      const append: DataOperation = { type: DataOperationType.ADD, index: previousCount, count: next.length - previousCount };
      this.listeners.forEach((listener: DataChangeListener): void => listener.onDatasetChange([append]));
    } else {
      // Keep keys for the rows that remain current when a branch changes or older messages are prepended.
      this.listeners.forEach((listener: DataChangeListener): void => listener.onDataReloaded());
    }
  }
}
