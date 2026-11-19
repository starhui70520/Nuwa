import { NativeConversation, NativeConversationGroup, NativeConversationMessage } from './NativeConversation';
import { NativeToolTimelineStep } from './NativeToolTimeline';

export const SIDEBAR_HISTORY_PAGE_SIZE = 60;
const SEARCH_DELAY_MS = 180;
const SEARCH_BATCH_SIZE = 16;

export interface NativeSidebarSession {
  id: string;
  title: string;
  pinnedAt?: number;
}

export interface NativeSidebarRow {
  key: string;
  groupKey: string;
  groupLabel: string;
  session?: NativeSidebarSession;
}

export function normalizeSidebarQuery(value: string): string {
  return value.trim().toLowerCase();
}

function matchesAssistantText(message: NativeConversationMessage, query: string): boolean {
  if (message.stopReason === 'refusal') return false;
  const timeline = message.toolTimeline;
  return message.content.slice(timeline?.answerOffset ?? 0).toLowerCase().includes(query) ||
    (timeline?.steps.some((step: NativeToolTimelineStep): boolean => step.type === 'text' &&
      (step.text ?? '').toLowerCase().includes(query)) ?? false);
}

export function matchesSidebarBody(session: NativeConversation, query: string): boolean {
  return session.messages.some((message: NativeConversationMessage): boolean => message.role === 'user' ?
    message.content.toLowerCase().includes(query) : matchesAssistantText(message, query));
}

export function filterSidebarGroups(groups: NativeConversationGroup[], query: string, untitled: string,
  bodyMatches: Set<string>): NativeConversationGroup[] {
  if (!query) return groups;
  const result: NativeConversationGroup[] = [];
  for (const group of groups) {
    const matched = group.sessions.filter((session: NativeConversation): boolean =>
      (session.title || untitled).toLowerCase().includes(query) || bodyMatches.has(session.id));
    if (matched.length > 0) result.push({ key: group.key, label: group.label, sessions: matched });
  }
  return result;
}

export function createSidebarRows(groups: NativeConversationGroup[], limit: number): NativeSidebarRow[] {
  const rows: NativeSidebarRow[] = [];
  let remaining = limit;
  for (const group of groups) {
    if (remaining <= 0) break;
    rows.push({ key: 'group:' + group.key, groupKey: group.key, groupLabel: group.label });
    for (const session of group.sessions.slice(0, remaining)) {
      rows.push({
        key: JSON.stringify([session.id, session.title, session.pinnedAt ?? 0]),
        groupKey: group.key, groupLabel: group.label,
        session: { id: session.id, title: session.title, pinnedAt: session.pinnedAt },
      });
      remaining--;
    }
  }
  return rows;
}

export class NativeSidebarSearch {
  private timer: number = -1;

  cancel(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }

  schedule(sessions: NativeConversation[], query: string, complete: (matches: Set<string>) => void): void {
    this.cancel();
    if (!query) return;
    const found = new Set<string>();
    let index = 0;
    const scan = (): void => {
      this.timer = -1;
      const end = Math.min(index + SEARCH_BATCH_SIZE, sessions.length);
      while (index < end) {
        const session = sessions[index++];
        if (matchesSidebarBody(session, query)) found.add(session.id);
      }
      if (index === sessions.length) {
        complete(found);
      } else {
        this.timer = setTimeout(scan, 0);
      }
    };
    this.timer = setTimeout(scan, SEARCH_DELAY_MS);
  }
}
