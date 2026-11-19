import { util } from '@kit.ArkTS';
import { NativeAttachment } from './NativeChatAttachments';

export interface NativeStoredMessage {
  role: string;
  content: string;
  reasoning: string;
}

export interface NativeConversationMessage extends NativeStoredMessage {
  id: string;
  createdAt: number;
  parentId: string | null;
  selectedChildId?: string;
  status?: string;
  model?: string;
  files?: NativeAttachment[];
}

export interface NativeConversation {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  pinnedAt?: number;
  // The selected root and child links identify the visible path through all versions.
  rootMessageId: string | null;
  messages: NativeConversationMessage[];
  // Imported fragments and original image bytes are retained for portable exports.
  archiveJson?: string;
}

export interface NativeConversationState {
  sessions: NativeConversation[];
  activeId: string | null;
}

export interface NativeConversationGroup {
  key: string;
  label: string;
  sessions: NativeConversation[];
}

const DAY_MS = 86_400_000;
const TITLE_LENGTH = 36;

export function createConversation(now: number = Date.now()): NativeConversation {
  return {
    id: util.generateRandomUUID(true),
    title: '',
    createdAt: now,
    updatedAt: now,
    rootMessageId: null,
    messages: [],
  };
}

export function createConversationMessage(role: string, content: string, reasoning: string,
  now: number = Date.now(), status?: string, model?: string): NativeConversationMessage {
  return {
    id: util.generateRandomUUID(true),
    role: role,
    content: content,
    reasoning: reasoning,
    createdAt: now,
    parentId: null,
    status: status,
    model: model,
  };
}

function copyConversation(session: NativeConversation): NativeConversation {
  return {
    id: session.id,
    title: session.title,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    pinnedAt: session.pinnedAt,
    rootMessageId: session.rootMessageId,
    messages: session.messages,
    archiveJson: session.archiveJson,
  };
}

function copyMessage(message: NativeConversationMessage): NativeConversationMessage {
  return {
    id: message.id,
    role: message.role,
    content: message.content,
    reasoning: message.reasoning,
    createdAt: message.createdAt,
    parentId: message.parentId,
    selectedChildId: message.selectedChildId,
    status: message.status,
    model: message.model,
    files: message.files,
  };
}

export function visibleMessages(session: NativeConversation): NativeConversationMessage[] {
  const byId = new Map<string, NativeConversationMessage>();
  for (const message of session.messages) {
    byId.set(message.id, message);
  }
  const path: NativeConversationMessage[] = [];
  let id: string | null = session.rootMessageId;
  while (id !== null) {
    const message = byId.get(id);
    if (!message) {
      break;
    }
    path.push(message);
    byId.delete(id);
    id = message.selectedChildId ?? null;
  }
  return path;
}

function conversationTitle(messages: NativeConversationMessage[]): string {
  const prompt = messages.find((message: NativeConversationMessage): boolean =>
    message.role === 'user' && !!message.content.trim());
  const title = prompt?.content.trim().replace(/\s+/g, ' ') ?? '';
  const characters = Array.from(title);
  return characters.length > TITLE_LENGTH ? `${characters.slice(0, TITLE_LENGTH).join('')}…` : title;
}

export function appendBranch(session: NativeConversation, parentId: string | null,
  messages: NativeConversationMessage[], now: number = Date.now()): NativeConversation {
  if (messages.length === 0) {
    return session;
  }
  if (parentId !== null && !session.messages.some((message: NativeConversationMessage): boolean =>
    message.id === parentId)) {
    throw new Error('Conversation branch parent is missing');
  }
  const next = copyConversation(session);
  next.updatedAt = now;
  next.title = session.title || conversationTitle(messages);
  const firstId = messages[0].id;
  // Select the new path while preserving the previous versions and their descendants.
  if (parentId === null) {
    next.rootMessageId = firstId;
  }
  const previous = session.messages.map((message: NativeConversationMessage): NativeConversationMessage => {
    if (message.id !== parentId) {
      return message;
    }
    const parent = copyMessage(message);
    parent.selectedChildId = firstId;
    return parent;
  });
  const added = messages.map((message: NativeConversationMessage, index: number): NativeConversationMessage => {
    const node = copyMessage(message);
    node.parentId = index === 0 ? parentId : messages[index - 1].id;
    node.selectedChildId = messages[index + 1]?.id;
    return node;
  });
  next.messages = [...previous, ...added];
  return next;
}

export function messageVersions(session: NativeConversation, messageId: string): NativeConversationMessage[] {
  const message = session.messages.find((item: NativeConversationMessage): boolean => item.id === messageId);
  return message ? session.messages.filter((item: NativeConversationMessage): boolean =>
    item.parentId === message.parentId) : [];
}

export function selectMessageVersion(session: NativeConversation, messageId: string): NativeConversation {
  const message = session.messages.find((item: NativeConversationMessage): boolean => item.id === messageId);
  if (!message || !visibleMessages(session).some((item: NativeConversationMessage): boolean =>
    item.parentId === message.parentId && item.id !== messageId)) {
    return session;
  }
  const next = copyConversation(session);
  if (message.parentId === null) {
    next.rootMessageId = messageId;
    return next;
  }
  next.messages = session.messages.map((item: NativeConversationMessage): NativeConversationMessage => {
    if (item.id !== message.parentId) {
      return item;
    }
    const parent = copyMessage(item);
    parent.selectedChildId = messageId;
    return parent;
  });
  return next;
}

export function updateConversationMessage(session: NativeConversation, message: NativeConversationMessage,
  updatedAt: number = session.updatedAt): NativeConversation {
  const index = session.messages.findIndex((item: NativeConversationMessage): boolean => item.id === message.id);
  if (index < 0) {
    return session;
  }
  const previous = session.messages[index];
  const updated = copyMessage(previous);
  updated.content = message.content;
  updated.reasoning = message.reasoning;
  updated.status = message.status;
  updated.model = message.model;
  updated.files = message.files ?? previous.files;
  const next = copyConversation(session);
  next.updatedAt = updatedAt;
  next.messages = session.messages.slice();
  next.messages[index] = updated;
  return next;
}

export function selectConversation(state: NativeConversationState, id: string | null): NativeConversationState {
  if (id === state.activeId || (id !== null && !state.sessions.some((session: NativeConversation): boolean =>
    session.id === id))) {
    return state;
  }
  return { sessions: state.sessions, activeId: id };
}

export function upsertConversation(state: NativeConversationState, session: NativeConversation,
  activate: boolean = false): NativeConversationState {
  const index = state.sessions.findIndex((item: NativeConversation): boolean => item.id === session.id);
  const sessions = state.sessions.slice();
  if (index < 0) {
    sessions.unshift(session);
  } else {
    sessions[index] = session;
  }
  return { sessions: sessions, activeId: activate ? session.id : state.activeId };
}

export function renameConversation(state: NativeConversationState, id: string, title: string): NativeConversationState {
  const session = state.sessions.find((item: NativeConversation): boolean => item.id === id);
  const trimmedTitle = title.trim();
  if (!session || !trimmedTitle || session.title === trimmedTitle) {
    return state;
  }
  const next = copyConversation(session);
  next.title = trimmedTitle;
  return upsertConversation(state, next);
}

export function setConversationsPinned(state: NativeConversationState, ids: string[], pinned: boolean,
  now: number = Date.now()): NativeConversationState {
  const positions = new Map<string, number>();
  ids.forEach((id: string, index: number): void => { positions.set(id, ids.length - index - 1); });
  const sessions = state.sessions.map((session: NativeConversation): NativeConversation => {
    const position = positions.get(session.id);
    if (position === undefined) {
      return session;
    }
    const next = copyConversation(session);
    next.pinnedAt = pinned ? now + position : undefined;
    return next;
  });
  return { sessions: sessions, activeId: state.activeId };
}

export function toggleConversationPin(state: NativeConversationState, id: string,
  now: number = Date.now()): NativeConversationState {
  const session = state.sessions.find((item: NativeConversation): boolean => item.id === id);
  return session ? setConversationsPinned(state, [id], !session.pinnedAt, now) : state;
}

export function deleteConversations(state: NativeConversationState, ids: string[]): NativeConversationState {
  const deleted = new Set<string>(ids);
  const sessions = state.sessions.filter((session: NativeConversation): boolean => !deleted.has(session.id));
  const activeId = state.activeId !== null && deleted.has(state.activeId) ? null : state.activeId;
  return { sessions: sessions, activeId: activeId };
}

function calendarDay(date: Date): number {
  return Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / DAY_MS;
}

export function groupConversations(sessions: NativeConversation[], now: number = Date.now()): NativeConversationGroup[] {
  const ordered = sessions.slice().sort((a: NativeConversation, b: NativeConversation): number =>
    (b.pinnedAt ?? 0) - (a.pinnedAt ?? 0) || b.updatedAt - a.updatedAt);
  const groups: NativeConversationGroup[] = [];
  const today = calendarDay(new Date(now));
  for (const session of ordered) {
    const date = new Date(session.updatedAt);
    const days = today - calendarDay(date);
    let key: string;
    let label: string;
    if (session.pinnedAt) {
      key = 'pinned';
      label = '置顶';
    } else if (days <= 0) {
      key = 'today';
      label = '今天';
    } else if (days === 1) {
      key = 'yesterday';
      label = '昨天';
    } else if (days < 7) {
      key = 'week';
      label = '7 天内';
    } else if (days < 30) {
      key = 'month';
      label = '30 天内';
    } else {
      key = `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}`;
      label = key;
    }
    const last = groups[groups.length - 1];
    if (last?.key === key) {
      last.sessions.push(session);
    } else {
      groups.push({ key: key, label: label, sessions: [session] });
    }
  }
  return groups;
}
