import { NativeConversation, NativeConversationGroup, NativeConversationMessage } from './NativeConversation';
import { isHarmonyLowPerfDevice } from './NativeDevicePerf';
import { NativeToolTimelineStep } from './NativeToolTimeline';

export const SIDEBAR_HISTORY_PAGE_SIZE = 60;
const SEARCH_DELAY_MS = 140;
const LOW_PERF_SEARCH_DELAY_MS = 160;
const SEARCH_BATCH_SIZE = 32;
const LOW_PERF_SEARCH_BATCH_SIZE = 24;

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

export interface NativeSidebarSection {
  key: string;
  label: string;
  headerIndex: number;
  rows: NativeSidebarRow[];
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
        key: session.id + '\u001f' + session.title + '\u001f' + (session.pinnedAt ?? 0).toString(),
        groupKey: group.key, groupLabel: group.label,
        session: { id: session.id, title: session.title, pinnedAt: session.pinnedAt },
      });
      remaining--;
    }
  }
  return rows;
}

export function createSidebarSections(rows: NativeSidebarRow[]): NativeSidebarSection[] {
  const sections: NativeSidebarSection[] = [];
  let section: NativeSidebarSection | undefined;
  rows.forEach((row: NativeSidebarRow, index: number): void => {
    if (row.session) {
      section?.rows.push(row);
    } else {
      section = { key: row.groupKey, label: row.groupLabel, headerIndex: index, rows: [] };
      sections.push(section);
    }
  });
  return sections;
}

export function visibleSidebarRowIndex(sections: NativeSidebarSection[], sectionIndex: number,
  itemIndex: number = -1): number {
  const section = sections[sectionIndex];
  if (!section || itemIndex < -1 || itemIndex >= section.rows.length) return -1;
  return section.headerIndex + 1 + itemIndex;
}

export class NativeSidebarSearch {
  private timer: number = -1;
  private generation: number = 0;

  cancel(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    this.generation++;
  }

  schedule(sessions: NativeConversation[], query: string, complete: (matches: Set<string>) => void,
    loadBody?: (session: NativeConversation) => Promise<NativeConversation | undefined>,
    skipIds?: Set<string>,
    matchUnloadedBatch?: (ids: string[], query: string) => Promise<string[]>): void {
    this.cancel();
    if (!query) return;
    const generation = this.generation;
    const lowPerf = isHarmonyLowPerfDevice();
    const batchSize = lowPerf ? LOW_PERF_SEARCH_BATCH_SIZE : SEARCH_BATCH_SIZE;
    const delayMs = lowPerf ? LOW_PERF_SEARCH_DELAY_MS : SEARCH_DELAY_MS;
    const found = new Set<string>();
    let index = 0;
    const scan = async (): Promise<void> => {
      if (generation !== this.generation) return;
      this.timer = -1;
      const end = Math.min(index + batchSize, sessions.length);
      const unloadedIds: string[] = [];
      while (index < end) {
        if (generation !== this.generation) return;
        const session = sessions[index++];
        // 标题已命中的会话跳过磁盘快照读取与校验。
        if (skipIds?.has(session.id)) continue;
        const unloaded = session.unloaded === true;
        if (unloaded && matchUnloadedBatch) {
          unloadedIds.push(session.id);
        } else if (unloaded && loadBody) {
          let loaded: NativeConversation | undefined;
          try {
            loaded = await loadBody(session);
          } catch {
            // An unreadable snapshot must not prevent searching later conversations.
          }
          if (generation !== this.generation) return;
          if (loaded && matchesSidebarBody(loaded, query)) found.add(session.id);
        } else if (!unloaded && matchesSidebarBody(session, query)) {
          found.add(session.id);
        }
      }
      if (unloadedIds.length > 0 && matchUnloadedBatch) {
        try {
          const hits = await matchUnloadedBatch(unloadedIds, query);
          if (generation !== this.generation) return;
          for (let i = 0; i < hits.length; i++) {
            found.add(hits[i]);
          }
        } catch {
          // 批量检索异常不阻断其余批次。
        }
      }
      if (generation !== this.generation) return;
      if (index === sessions.length) {
        complete(found);
      } else {
        this.timer = setTimeout((): void => { void scan(); }, 0);
      }
    };
    this.timer = setTimeout((): void => { void scan(); }, delayMs);
  }
}
