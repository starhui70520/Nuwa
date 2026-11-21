import { common, Want } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { NativeChatBackup } from './NativeChatBackup';
import { NativeConversation, visibleMessages } from './NativeConversation';
import { ensureNativeDirectory } from './NativeFileSystem';
import { triggerNativeHaptic } from './NativeImmersiveUI';
import { NativeLocale } from './NativeLocation';

export const NUWA_INCOMING_SHARE_SEQ_KEY: string = 'nuwa_incoming_share_seq';
const SHARE_EXPORT_DIR: string = 'nuwa-share';
const KNOCK_INBOX_DIR: string = 'nuwa-knock-inbox';
const COLLAB_INBOX_DIR: string = 'nuwa-collab';
const SHARE_CLEANUP_AGE_MS: number = 60 * 60 * 1000;
const DEEPSEEK_SHARE_URL_PATTERN = /https?:\/\/(?:[a-z0-9-]+\.)*deepseek\.com\/(?:a\/chat\/s|share)\/[A-Za-z0-9_-]+/i;

export interface NativeIncomingSharePayload {
  text: string;
  uris: string[];
  archiveUri: string;
  shareLinkUrl: string;
  source: 'share' | 'open' | 'knock' | 'collaboration';
}

let pendingIncomingPayloads: NativeIncomingSharePayload[] = [];
let incomingSequence: number = 0;

export function publishIncomingSharePayload(payload: NativeIncomingSharePayload): void {
  if (!payload.text.trim() && payload.uris.length === 0 && !payload.archiveUri && !payload.shareLinkUrl) {
    return;
  }
  pendingIncomingPayloads.push(payload);
  incomingSequence++;
  AppStorage.setOrCreate<number>(NUWA_INCOMING_SHARE_SEQ_KEY, incomingSequence);
}

export function takePendingIncomingSharePayloads(): NativeIncomingSharePayload[] {
  if (pendingIncomingPayloads.length === 0) return [];
  const items = pendingIncomingPayloads;
  pendingIncomingPayloads = [];
  return items;
}

function isArchiveFileUri(uri: string): boolean {
  const lower = uri.split('?')[0].split('#')[0].toLowerCase();
  return lower.endsWith('.zip') || lower.endsWith('.nuwa');
}

function extractDeepSeekShareUrl(text: string): string {
  const match = DEEPSEEK_SHARE_URL_PATTERN.exec(text);
  return match ? match[0] : '';
}

function collectSharedRecords(data: systemShare.SharedData,
  source: 'share' | 'open' | 'knock' | 'collaboration'): NativeIncomingSharePayload | null {
  const texts: string[] = [];
  const uris: string[] = [];
  let archiveUri = '';
  for (const record of data.getRecords()) {
    if (record.uri) {
      if (!archiveUri && (isArchiveFileUri(record.uri) ||
        record.utd === uniformTypeDescriptor.UniformDataType.ZIP_ARCHIVE ||
        record.utd === 'com.rankchord.nuwa.session')) {
        archiveUri = record.uri;
      } else if (!uris.includes(record.uri)) {
        uris.push(record.uri);
      }
    }
    if (record.content && record.content.trim()) {
      const value = record.content.trim();
      if (!texts.includes(value)) {
        texts.push(value);
      }
    }
  }
  const combinedText = texts.join('\n').trim();
  const shareLinkUrl = extractDeepSeekShareUrl(combinedText);
  if (!combinedText && uris.length === 0 && !archiveUri && !shareLinkUrl) {
    return null;
  }
  return {
    text: combinedText,
    uris: uris,
    archiveUri: archiveUri,
    shareLinkUrl: shareLinkUrl,
    source: source,
  };
}

/** Parse incoming System Share (sendData) or Open-With (viewData) Want into a structured payload. */
export async function parseIncomingShareWant(want: Want): Promise<NativeIncomingSharePayload | null> {
  const action = want.action ?? '';
  const isSendData = action === 'ohos.want.action.sendData';
  const isViewData = action === 'ohos.want.action.viewData';
  if (!isSendData && !isViewData) {
    return null;
  }

  if (isSendData) {
    try {
      const sharedData = await systemShare.getSharedData(want);
      const parsed = collectSharedRecords(sharedData, 'share');
      if (parsed) return parsed;
    } catch {
      // Fall back to direct URI inspection below.
    }
  }

  const uris: string[] = [];
  let archiveUri = '';
  const appendUri = (candidate: string): void => {
    if (!candidate) return;
    if (!archiveUri && isArchiveFileUri(candidate)) {
      archiveUri = candidate;
    } else if (!uris.includes(candidate)) {
      uris.push(candidate);
    }
  };

  if (typeof want.uri === 'string' && want.uri) {
    appendUri(want.uri);
  }
  const params = want.parameters;
  if (params) {
    const stream: Object | undefined = params['ability.params.stream'];
    if (Array.isArray(stream)) {
      const items = stream as Array<Object>;
      for (const item of items) {
        if (typeof item === 'string') appendUri(item);
      }
    }
  }

  if (uris.length === 0 && !archiveUri) {
    return null;
  }
  return {
    text: '',
    uris: uris,
    archiveUri: archiveUri,
    shareLinkUrl: '',
    source: isViewData ? 'open' : 'share',
  };
}

function sanitizeShareFileName(title: string): string {
  const cleaned = title
    .replace(/[\\/:*?"<>|\u0000-\u001F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 42);
  return cleaned || 'Nuwa-Chat';
}

async function cleanupStaleShareExports(dir: string): Promise<void> {
  try {
    const now = Date.now();
    const names = await fileIo.listFile(dir);
    for (const name of names) {
      const path = dir + '/' + name;
      try {
        const stat = await fileIo.stat(path);
        if (now - stat.mtime * 1000 > SHARE_CLEANUP_AGE_MS) {
          await fileIo.unlink(path).catch(() => {});
        }
      } catch {
        // Ignore individual cleanup failures.
      }
    }
  } catch {
    // Directory may not exist yet.
  }
}

export async function buildSessionShareData(
  context: common.UIAbilityContext,
  backup: NativeChatBackup,
  session: NativeConversation,
  locale: NativeLocale
): Promise<systemShare.SharedData> {
  const baseDir = (context.cacheDir || context.filesDir) + '/' + SHARE_EXPORT_DIR;
  await ensureNativeDirectory(baseDir);
  void cleanupStaleShareExports(baseDir);

  const displayTitle = session.title.trim() || (locale === 'en-US' ? 'Nuwa Chat' : 'Nuwa 对话');
  const fileName = 'Nuwa-' + sanitizeShareFileName(displayTitle) + '-' + util.generateRandomUUID(true).slice(0, 8) + '.zip';
  const filePath = baseDir + '/' + fileName;
  await backup.exportSessionToPath(context, session, filePath, locale);

  const messageCount = visibleMessages(session).length;
  const description = locale === 'en-US'
    ? `Nuwa chat · ${messageCount} ${messageCount === 1 ? 'message' : 'messages'}`
    : `Nuwa 对话 · 共 ${messageCount} 条消息`;

  return new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.ZIP_ARCHIVE,
    uri: fileUri.getUriFromPath(filePath),
    title: displayTitle,
    description: description,
    label: 'FILE',
  });
}

/** Present HarmonyOS native System Share sheet (Huawei Share / WeChat / QQ / SuperHub / Save). */
export async function shareSessionWithSystemPanel(
  context: common.UIAbilityContext,
  backup: NativeChatBackup,
  session: NativeConversation,
  locale: NativeLocale
): Promise<void> {
  const data = await buildSessionShareData(context, backup, session, locale);
  const controller = new systemShare.ShareController(data);
  triggerNativeHaptic('light');
  await controller.show(context, {
    selectionMode: systemShare.SelectionMode.SINGLE,
    previewMode: systemShare.SharePreviewMode.DETAIL,
  });
}

export interface NativeProximityShareProvider {
  getContext: () => common.UIAbilityContext;
  getLocale: () => NativeLocale;
  getWindowId: () => number;
  prepareActiveSession: () => Promise<NativeConversation | null>;
  onSharedToast: (message: string) => void;
}

/**
 * Coordinates HarmonyOS-exclusive proximity & spatial sharing:
 * - Knock Share (碰一碰分享, API 12+)
 * - Gestures Share / Grab & Drop (隔空传送, API 20+)
 * - Sandbox Data Receive (碰一碰直传接收, API 20+)
 */
export class NativeProximityShareCoordinator {
  private readonly backup: NativeChatBackup;
  private readonly provider: NativeProximityShareProvider;
  private active: boolean = false;
  private gesturesRegistered: boolean = false;
  private receiveRegistered: boolean = false;
  private receiveCapability?: harmonyShare.RecvCapabilityRegistry;

  private readonly handleOutboundTarget = (target: harmonyShare.SharableTarget): void => {
    void this.shareToTarget(target);
  };

  private readonly handleInboundTarget = (target: harmonyShare.ReceivableTarget): void => {
    void this.receiveFromTarget(target);
  };

  constructor(backup: NativeChatBackup, provider: NativeProximityShareProvider) {
    this.backup = backup;
    this.provider = provider;
  }

  private async shareToTarget(target: harmonyShare.SharableTarget): Promise<void> {
    const locale = this.provider.getLocale();
    try {
      const session = await this.provider.prepareActiveSession();
      if (!session || visibleMessages(session).length === 0) {
        if (deviceInfo.sdkApiVersion >= 22) {
          await target.clarifyNonShare({
            message: locale === 'en-US'
              ? 'Open a conversation in Nuwa before tapping to share.'
              : '请先在 Nuwa 中打开一段对话，再碰一碰或隔空分享。',
          }).catch(() => {});
        } else if (deviceInfo.sdkApiVersion >= 15) {
          await target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch(() => {});
        }
        return;
      }
      const data = await buildSessionShareData(this.provider.getContext(), this.backup, session, locale);
      await target.share(data);
      triggerNativeHaptic('medium');
    } catch {
      if (deviceInfo.sdkApiVersion >= 15) {
        await target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch(() => {});
      }
    }
  }

  private async receiveFromTarget(target: harmonyShare.ReceivableTarget): Promise<void> {
    try {
      const context = this.provider.getContext();
      const dir = (context.cacheDir || context.filesDir) + '/' + KNOCK_INBOX_DIR + '/' + util.generateRandomUUID(true);
      await ensureNativeDirectory(dir);
      const locale = this.provider.getLocale();
      await target.receive(fileUri.getUriFromPath(dir), {
        onDataReceived: (sharedData: systemShare.SharedData): void => {
          const parsed = collectSharedRecords(sharedData, 'knock');
          if (parsed) {
            publishIncomingSharePayload(parsed);
            triggerNativeHaptic('medium');
          }
        },
        onResult: (code: harmonyShare.ShareResultCode): void => {
          if (code === harmonyShare.ShareResultCode.SHARE_SUCCESS) {
            this.provider.onSharedToast(locale === 'en-US' ? 'Received via Harmony Share' : '已通过碰一碰接收内容');
          }
        },
      });
    } catch {
      await target.reject(harmonyShare.ReceivableErrorCode.NO_RECEIVABLE_ERROR).catch(() => {});
    }
  }

  register(): void {
    if (this.active) return;
    this.active = true;
    try {
      harmonyShare.on('knockShare', this.handleOutboundTarget);
    } catch {
      // Simulator or device without NFC/HarmonyShare hardware.
    }
    if (deviceInfo.sdkApiVersion >= 20) {
      try {
        harmonyShare.on('gesturesShare', this.handleOutboundTarget);
        this.gesturesRegistered = true;
      } catch {
        this.gesturesRegistered = false;
      }
      const windowId = this.provider.getWindowId();
      if (windowId > 0) {
        try {
          const capability: harmonyShare.RecvCapabilityRegistry = {
            windowId: windowId,
            capabilities: [
              { utd: uniformTypeDescriptor.UniformDataType.ZIP_ARCHIVE, maxSupportedCount: 1 },
              { utd: 'com.rankchord.nuwa.session', maxSupportedCount: 1 },
              { utd: uniformTypeDescriptor.UniformDataType.IMAGE, maxSupportedCount: 20 },
              { utd: uniformTypeDescriptor.UniformDataType.FILE, maxSupportedCount: 10 },
            ],
          };
          harmonyShare.on('dataReceive', capability, this.handleInboundTarget);
          this.receiveCapability = capability;
          this.receiveRegistered = true;
        } catch {
          this.receiveRegistered = false;
          this.receiveCapability = undefined;
        }
      }
    }
  }

  unregister(): void {
    if (!this.active) return;
    this.active = false;
    try {
      harmonyShare.off('knockShare', this.handleOutboundTarget);
    } catch {
      // Ignore unregister errors.
    }
    if (this.gesturesRegistered) {
      this.gesturesRegistered = false;
      try {
        harmonyShare.off('gesturesShare', this.handleOutboundTarget);
      } catch {
        // Ignore unregister errors.
      }
    }
    if (this.receiveRegistered && this.receiveCapability) {
      this.receiveRegistered = false;
      const capability = this.receiveCapability;
      this.receiveCapability = undefined;
      try {
        harmonyShare.off('dataReceive', capability, this.handleInboundTarget);
      } catch {
        // Ignore unregister errors.
      }
    }
  }
}

function detectCollaborationExtension(bytes: Uint8Array, bufferType: string): string {
  if (bytes.length >= 4) {
    if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) return '.png';
    if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) return '.jpg';
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) return '.gif';
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
      return '.webp';
    }
    if (bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46) return '.pdf';
  }
  return bufferType.includes('pdf') ? '.pdf' : '.jpg';
}

/** Save a cross-device photo / scanned document buffer received from ServiceCollaborationKit to a local URI. */
export async function saveCollaborationBufferToUri(
  context: common.UIAbilityContext,
  bufferType: string,
  buffer: ArrayBuffer
): Promise<string> {
  if (!buffer || buffer.byteLength <= 0) {
    throw new Error('Empty collaboration media buffer');
  }
  const dir = (context.cacheDir || context.filesDir) + '/' + COLLAB_INBOX_DIR;
  await ensureNativeDirectory(dir);
  const bytes = new Uint8Array(buffer);
  const ext = detectCollaborationExtension(bytes, bufferType);
  const path = dir + '/collab-' + util.generateRandomUUID(true) + ext;
  const file = await fileIo.open(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    await fileIo.write(file.fd, buffer);
    await fileIo.fsync(file.fd);
  } finally {
    await fileIo.close(file);
  }
  return fileUri.getUriFromPath(path);
}
