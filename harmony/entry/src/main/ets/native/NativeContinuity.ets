import { AbilityConstant, common, Want, wantConstant } from '@kit.AbilityKit';
import { distributedDataObject } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { NativeAttachment } from './NativeChatAttachments';
import { NativeConversation, NativeConversationMessage } from './NativeConversation';

export const NUWA_CONTINUATION_SEQ_KEY: string = 'nuwa_continuation_seq';
const CONTINUATION_VERSION: number = 1;
const MAX_INLINE_SESSION_BYTES: number = 55 * 1024;
const MAX_CONTINUATION_DRAFT_CHARS: number = 16_000;
const DDO_RESTORE_TIMEOUT_MS: number = 4000;

export interface NativeContinuationSnapshot {
  authenticated: boolean;
  activeSessionId: string | null;
  session: NativeConversation | null;
  draftText: string;
  thinking: boolean;
  search: boolean;
}

export interface NativeContinuationRestore {
  activeSessionId: string | null;
  session: NativeConversation | null;
  draftText: string;
  thinking: boolean;
  search: boolean;
}

class DistributedContinuationRecord {
  version: number = CONTINUATION_VERSION;
  activeSessionId: string = '';
  sessionJson: string = '';
  draftText: string = '';
  thinking: boolean = false;
  search: boolean = false;
}

let currentSnapshot: NativeContinuationSnapshot = {
  authenticated: false,
  activeSessionId: null,
  session: null,
  draftText: '',
  thinking: false,
  search: false,
};

let lastContinueState: boolean | undefined = undefined;
let pendingContinuationRestore: NativeContinuationRestore | null = null;
let continuationSequence: number = 0;
let activeDistributedSource: distributedDataObject.DataObject | undefined = undefined;

/** Keep the live continuation snapshot updated as the user switches chats or types drafts. */
export function updateNativeContinuationSnapshot(
  context: common.UIAbilityContext,
  snapshot: NativeContinuationSnapshot
): void {
  currentSnapshot = snapshot;
  const continuable = snapshot.authenticated &&
    ((snapshot.session !== null && snapshot.session.messages.length > 0 && !snapshot.session.unloaded && !snapshot.session.unreadable) ||
      snapshot.draftText.trim().length > 0);
  if (lastContinueState === continuable) return;
  lastContinueState = continuable;
  try {
    void context.setMissionContinueState(
      continuable ? AbilityConstant.ContinueState.ACTIVE : AbilityConstant.ContinueState.INACTIVE
    ).catch(() => {});
  } catch {
    // Ignore on platforms where mission continuation is unavailable.
  }
}

export function takePendingNativeContinuation(): NativeContinuationRestore | null {
  const item = pendingContinuationRestore;
  pendingContinuationRestore = null;
  return item;
}

function publishContinuationRestore(restore: NativeContinuationRestore): void {
  pendingContinuationRestore = restore;
  continuationSequence++;
  AppStorage.setOrCreate<number>(NUWA_CONTINUATION_SEQ_KEY, continuationSequence);
}

function sanitizeAttachmentForTransfer(item: NativeAttachment): NativeAttachment {
  return {
    id: item.id,
    archiveId: item.archiveId,
    name: item.name,
    size: item.size,
    isImage: item.isImage,
    mimeType: item.mimeType,
    purpose: item.purpose,
    createdAt: item.createdAt,
    serverId: null,
    local: false,
  };
}

function sanitizeMessageForTransfer(message: NativeConversationMessage): NativeConversationMessage {
  return {
    id: message.id,
    role: message.role,
    content: message.content,
    reasoning: message.reasoning,
    createdAt: message.createdAt,
    parentId: message.parentId,
    selectedChildId: message.selectedChildId,
    status: message.status === 'streaming' ? 'stopped' : message.status,
    failure: message.failure,
    model: message.model,
    stopReason: message.stopReason,
    canPrefill: message.canPrefill,
    prefillBlocks: message.prefillBlocks,
    thinking: message.thinking,
    search: message.search,
    thinkingSignature: message.thinkingSignature,
    latestReminder: message.latestReminder,
    sources: message.sources,
    toolTimeline: message.toolTimeline,
    readLinks: message.readLinks,
    citations: message.citations,
    files: message.files?.map<NativeAttachment>((file: NativeAttachment): NativeAttachment =>
      sanitizeAttachmentForTransfer(file)),
  };
}

function sanitizeSessionForTransfer(session: NativeConversation): NativeConversation {
  return {
    id: session.id,
    title: session.title,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    pinnedAt: session.pinnedAt,
    rootMessageId: session.rootMessageId,
    messages: session.messages.map<NativeConversationMessage>((msg: NativeConversationMessage): NativeConversationMessage =>
      sanitizeMessageForTransfer(msg)),
  };
}

function utf8ByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}

function parseContinuedSession(raw: string): NativeConversation | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as NativeConversation;
    if (!parsed || typeof parsed.id !== 'string' || !parsed.id || !Array.isArray(parsed.messages)) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

/**
 * Called from EntryAbility.onContinue(wantParam) on the source HarmonyOS device.
 * Packs active conversation + unsent draft + DeepThink/Search toggles (never secrets/API keys).
 * Automatically upgrades large conversations (> 55 KB) to DistributedDataObject.
 */
export async function prepareNativeContinuation(
  context: common.UIAbilityContext,
  wantParam: Record<string, Object>
): Promise<AbilityConstant.OnContinueResult> {
  if (!currentSnapshot.authenticated) {
    return AbilityConstant.OnContinueResult.REJECT;
  }
  const draftText = currentSnapshot.draftText.slice(0, MAX_CONTINUATION_DRAFT_CHARS);
  const transferSession = currentSnapshot.session && !currentSnapshot.session.unloaded &&
    !currentSnapshot.session.unreadable && currentSnapshot.session.messages.length > 0
    ? sanitizeSessionForTransfer(currentSnapshot.session)
    : null;
  if (!transferSession && !draftText.trim()) {
    return AbilityConstant.OnContinueResult.REJECT;
  }

  wantParam[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
  wantParam['nuwaContinueVersion'] = CONTINUATION_VERSION;
  wantParam['nuwaContinueSessionId'] = transferSession?.id ?? currentSnapshot.activeSessionId ?? '';
  wantParam['nuwaContinueDraft'] = draftText;
  wantParam['nuwaContinueThinking'] = currentSnapshot.thinking;
  wantParam['nuwaContinueSearch'] = currentSnapshot.search;

  const sessionJson = transferSession ? JSON.stringify(transferSession) : '';
  if (!sessionJson) {
    return AbilityConstant.OnContinueResult.AGREE;
  }

  if (utf8ByteLength(sessionJson) <= MAX_INLINE_SESSION_BYTES) {
    wantParam['nuwaContinueSessionJson'] = sessionJson;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  // Upgrade large conversation snapshots to HarmonyOS DistributedDataObject.
  try {
    if (activeDistributedSource) {
      await activeDistributedSource.setSessionId('').catch(() => {});
      activeDistributedSource = undefined;
    }
    const record = new DistributedContinuationRecord();
    record.version = CONTINUATION_VERSION;
    record.activeSessionId = transferSession?.id ?? '';
    record.sessionJson = sessionJson;
    record.draftText = draftText;
    record.thinking = currentSnapshot.thinking;
    record.search = currentSnapshot.search;

    const dataObject = distributedDataObject.create(context, record);
    const dataSessionId = distributedDataObject.genSessionId();
    await dataObject.setSessionId(dataSessionId);
    const targetDevice = typeof wantParam['targetDevice'] === 'string' && (wantParam['targetDevice'] as string).length > 0
      ? wantParam['targetDevice'] as string
      : 'local';
    await dataObject.save(targetDevice);
    activeDistributedSource = dataObject;
    wantParam['nuwaContinueDataSessionId'] = dataSessionId;
    return AbilityConstant.OnContinueResult.AGREE;
  } catch {
    // Graceful fallback: still continue activeSessionId + draft text even if DDO save is unavailable.
    return AbilityConstant.OnContinueResult.AGREE;
  }
}

async function readDistributedContinuation(
  context: common.UIAbilityContext,
  dataSessionId: string
): Promise<DistributedContinuationRecord | null> {
  const record = new DistributedContinuationRecord();
  const dataObject = distributedDataObject.create(context, record);
  try {
    const readCurrent = (): DistributedContinuationRecord | null => {
      const candidate = dataObject as object as DistributedContinuationRecord;
      if (typeof candidate.sessionJson === 'string' && candidate.sessionJson.length > 0) {
        return {
          version: candidate.version,
          activeSessionId: candidate.activeSessionId ?? '',
          sessionJson: candidate.sessionJson,
          draftText: candidate.draftText ?? '',
          thinking: candidate.thinking === true,
          search: candidate.search === true,
        };
      }
      return null;
    };

    const restored = await new Promise<DistributedContinuationRecord | null>((resolve): void => {
      let settled = false;
      const done = (value: DistributedContinuationRecord | null): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try {
          dataObject.off('status');
          dataObject.off('change');
        } catch {
          // Ignore listener cleanup errors.
        }
        resolve(value);
      };
      const timer = setTimeout((): void => { done(readCurrent()); }, DDO_RESTORE_TIMEOUT_MS);
      const check = (): void => {
        const current = readCurrent();
        if (current) done(current);
      };
      try {
        dataObject.on('status', (_sid: string, _networkId: string, status: string): void => {
          if (status === 'restored' || status === 'online') check();
        });
        dataObject.on('change', (): void => { check(); });
      } catch {
        // Proceed with setSessionId check.
      }
      void dataObject.setSessionId(dataSessionId).then((): void => {
        check();
      }).catch((): void => {
        done(null);
      });
    });
    return restored;
  } finally {
    await dataObject.setSessionId('').catch(() => {});
  }
}

/** Called from EntryAbility.onCreate / onNewWant when launchReason === CONTINUATION. */
export async function restoreNativeContinuationFromWant(
  context: common.UIAbilityContext,
  want: Want
): Promise<void> {
  const params = want.parameters;
  if (!params) return;
  const version = params['nuwaContinueVersion'];
  if (typeof version !== 'number' || version !== CONTINUATION_VERSION) return;

  const activeIdRaw = typeof params['nuwaContinueSessionId'] === 'string'
    ? (params['nuwaContinueSessionId'] as string)
    : '';
  let draftText = typeof params['nuwaContinueDraft'] === 'string'
    ? (params['nuwaContinueDraft'] as string)
    : '';
  let thinking = params['nuwaContinueThinking'] === true;
  let search = params['nuwaContinueSearch'] === true;
  let session: NativeConversation | null = null;

  const inlineJson = typeof params['nuwaContinueSessionJson'] === 'string'
    ? (params['nuwaContinueSessionJson'] as string)
    : '';
  if (inlineJson) {
    session = parseContinuedSession(inlineJson);
  } else {
    const dataSessionId = typeof params['nuwaContinueDataSessionId'] === 'string'
      ? (params['nuwaContinueDataSessionId'] as string)
      : '';
    if (dataSessionId) {
      const distributed = await readDistributedContinuation(context, dataSessionId).catch(() => null);
      if (distributed) {
        session = parseContinuedSession(distributed.sessionJson);
        if (!draftText && distributed.draftText) draftText = distributed.draftText;
        thinking = distributed.thinking;
        search = distributed.search;
      }
    }
  }

  publishContinuationRestore({
    activeSessionId: session?.id ?? (activeIdRaw || null),
    session: session,
    draftText: draftText,
    thinking: thinking,
    search: search,
  });
}
