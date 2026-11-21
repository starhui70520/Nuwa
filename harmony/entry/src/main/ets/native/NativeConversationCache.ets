import { NativeConversation } from './NativeConversation';

const CONVERSATION_CACHE_LIMIT = 5;

export class NativeConversationCache {
  private readonly saved = new WeakSet<NativeConversation>();
  private readonly access = new Map<string, number>();
  private sequence: number = 0;

  touch(id: string): void {
    this.access.set(id, ++this.sequence);
  }

  forget(id: string): void {
    this.access.delete(id);
  }

  confirm(sessions: NativeConversation[], written?: Set<string>): void {
    for (const session of sessions) {
      if (!session.unloaded && !session.unreadable && (!written || written.has(session.id))) {
        this.saved.add(session);
      }
    }
  }

  evictable(sessions: NativeConversation[], protectedIds: Set<string>): string[] {
    const loaded = sessions.filter((session: NativeConversation): boolean => !session.unloaded && !session.unreadable);
    const excess = loaded.length - CONVERSATION_CACHE_LIMIT;
    if (excess <= 0) return [];
    // A saved revision can be discarded once it has no remaining in-flight users.
    return loaded.filter((session: NativeConversation): boolean =>
      this.saved.has(session) && !protectedIds.has(session.id))
      .sort((left: NativeConversation, right: NativeConversation): number =>
        (this.access.get(left.id) ?? 0) - (this.access.get(right.id) ?? 0))
      .slice(0, excess).map<string>((session: NativeConversation): string => session.id);
  }
}
