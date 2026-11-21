import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { ensureBackupSpace, writeBackupFile } from './NativeBackupFiles';
import { MAX_FILE_BACKUP_BYTES, NativeBackupZipInput } from './NativeBackupZip';

const PAGE = 'resource://rawfile/web/index.html';
const SCRIPT = 'resource://rawfile/web/legacy-migration.js';
const STORE = 'nuwa_legacy_web_migration';
const CHUNK_BYTES = 256 * 1024;
const PAGE_TIMEOUT = 12000;
const PREPARE_TIMEOUT = 5 * 60 * 1000;
const CHUNK_TIMEOUT = 12000;

interface LegacyPin {
  id: string;
  pinnedAt: number;
}

interface LegacyStatus {
  state: string;
  size: number;
  settings: Record<string, string>;
  pins: LegacyPin[];
  documents: number;
}

interface LegacyChunk {
  state: string;
  offset: number;
  data: string;
}

export interface NativeLegacyDocument extends NativeBackupZipInput {
  id: string;
}

export interface NativeLegacyWebData {
  archivePath: string;
  settings: Record<string, string>;
  pins: LegacyPin[];
  documents: number;
  document: (index: number) => Promise<NativeLegacyDocument>;
}

export async function nativeLegacyWebMigrationDone(context: common.UIAbilityContext): Promise<boolean> {
  return (await (await preferences.getPreferences(context, STORE)).get('done', false)) === true;
}

export async function markNativeLegacyWebMigrationDone(context: common.UIAbilityContext): Promise<void> {
  const store = await preferences.getPreferences(context, STORE);
  await store.put('done', true);
  try {
    await store.flush();
  } catch (error) {
    // A failed flush must not suppress a retry within the same process.
    await store.delete('done').catch(() => {});
    throw error as Error;
  }
}

function scriptJson<T>(result: string): T {
  const text = result.trim();
  return JSON.parse(text.startsWith('"') ? JSON.parse(text) as string : text) as T;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve): void => { setTimeout(() => { resolve(); }, ms); });
}

function isMigrationResource(address: string): boolean {
  return address === PAGE || address === SCRIPT;
}

@Component
export struct NativeLegacyWebMigration {
  onImport: (data: NativeLegacyWebData) => Promise<void> = () => Promise.resolve();
  onComplete: (success: boolean) => void = () => {};
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private alive: boolean = false;
  private started: boolean = false;
  private finished: boolean = false;
  private pageTimeout: number = -1;

  aboutToAppear(): void {
    this.alive = true;
    this.pageTimeout = setTimeout((): void => { this.failPage(); }, PAGE_TIMEOUT);
  }

  aboutToDisappear(): void {
    clearTimeout(this.pageTimeout);
    this.alive = false;
    this.finish(false);
  }

  private finish(success: boolean): void {
    if (this.finished) return;
    this.finished = true;
    clearTimeout(this.pageTimeout);
    this.onComplete(success);
  }

  private failPage(): void {
    this.alive = false;
    if (!this.started) this.finish(false);
  }

  private async script(code: string): Promise<string> {
    if (!this.alive) throw new Error('Legacy storage reader closed');
    return this.controller.runJavaScript(code);
  }

  private async status(): Promise<LegacyStatus> {
    await this.script('window.nuwaLegacyMigration.prepare()');
    const deadline = Date.now() + PREPARE_TIMEOUT;
    while (Date.now() < deadline) {
      const status = scriptJson<LegacyStatus>(await this.script('window.nuwaLegacyMigration.status()'));
      if (status?.state === 'ready') {
        if (!Number.isSafeInteger(status.size) || status.size < 0 || status.size > MAX_FILE_BACKUP_BYTES ||
          !status.settings || !Array.isArray(status.pins) || !Number.isSafeInteger(status.documents) || status.documents < 0) {
          throw new Error('Invalid legacy archive metadata');
        }
        return status;
      }
      if (status?.state !== 'pending') throw new Error('Unable to read legacy storage');
      await delay(100);
    }
    throw new Error('Legacy archive preparation timed out');
  }

  private async readChunk(offset: number, length: number, document?: number): Promise<Uint8Array> {
    const index = document === undefined ? '' : ',' + document.toString();
    await this.script('window.nuwaLegacyMigration.read(' + offset.toString() + ',' + length.toString() + index + ')');
    const deadline = Date.now() + CHUNK_TIMEOUT;
    while (Date.now() < deadline) {
      const chunk = scriptJson<LegacyChunk>(await this.script('window.nuwaLegacyMigration.chunk()'));
      if (chunk?.state === 'ready') {
        if (chunk.offset !== offset || typeof chunk.data !== 'string' || chunk.data.length !== 4 * Math.ceil(length / 3)) {
          throw new Error('Invalid legacy storage chunk');
        }
        const bytes = new util.Base64Helper().decodeSync(chunk.data);
        if (bytes.length !== length) throw new Error('Incomplete legacy storage chunk');
        return bytes;
      }
      if (chunk?.state !== 'pending') throw new Error('Unable to transfer legacy storage');
      await delay(20);
    }
    throw new Error('Legacy transfer timed out');
  }

  private async document(index: number): Promise<NativeLegacyDocument> {
    const resource = scriptJson<NativeLegacyDocument>(await this.script(
      'window.nuwaLegacyMigration.document(' + index.toString() + ')'));
    if (typeof resource?.id !== 'string' || !resource.id || !Number.isSafeInteger(resource.size) || resource.size <= 0) {
      throw new Error('Invalid legacy document metadata');
    }
    return {
      id: resource.id, size: resource.size,
      read: async (offset: number, length: number): Promise<Uint8Array> => {
        if (length <= CHUNK_BYTES) return this.readChunk(offset, length, index);
        const output = new Uint8Array(length);
        for (let read = 0; read < length; read += CHUNK_BYTES) {
          const chunk = await this.readChunk(offset + read, Math.min(CHUNK_BYTES, length - read), index);
          output.set(chunk, read);
        }
        return output;
      },
    };
  }

  private async migrate(): Promise<void> {
    this.started = true;
    clearTimeout(this.pageTimeout);
    let temporary = '';
    let success = false;
    try {
      const status = await this.status();
      if (status.size > 0) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const directory = context.cacheDir || context.filesDir;
        await ensureBackupSpace(directory, status.size);
        temporary = directory + '/nuwa-legacy-' + util.generateRandomUUID(true) + '.zip';
        await writeBackupFile(temporary, true, async (write: (bytes: Uint8Array) => Promise<void>): Promise<void> => {
          for (let offset = 0; offset < status.size; offset += CHUNK_BYTES) {
            await write(await this.readChunk(offset, Math.min(CHUNK_BYTES, status.size - offset)));
          }
        });
      }
      if (!this.alive) return;
      await this.onImport({
        archivePath: temporary, settings: status.settings, pins: status.pins, documents: status.documents,
        document: (index: number): Promise<NativeLegacyDocument> => this.document(index),
      });
      success = true;
    } catch {
      // The WebView source is read-only. Leave it available for a later retry.
    } finally {
      if (temporary) await fileIo.unlink(temporary).catch(() => {});
      this.finish(success);
    }
  }

  private rejectResource(address: string): WebResourceResponse | null {
    if (isMigrationResource(address)) return null;
    const response = new WebResourceResponse();
    response.setResponseCode(403);
    response.setReasonMessage('Forbidden');
    response.setResponseMimeType('text/plain');
    response.setResponseData('');
    return response;
  }

  build() {
    Web({ src: PAGE, controller: this.controller })
      .width(1).height(1)
      .opacity(0)
      .focusable(false)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .databaseAccess(true)
      .fileAccess(false)
      .allowWindowOpenMethod(false)
      .blockNetwork(true)
      .onlineImageAccess(false)
      .imageAccess(false)
      .mixedMode(MixedMode.None)
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean => !isMigrationResource(event.data.getRequestUrl()))
      .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
        this.rejectResource(event.request.getRequestUrl()))
      .onPageEnd((event: OnPageEndEvent): void => {
        if (event.url === PAGE && this.alive && !this.started) void this.migrate();
      })
      .onErrorReceive((event: OnErrorReceiveEvent): void => {
        if (event.request.isMainFrame()) this.failPage();
      })
      .onRenderExited((): void => { this.failPage(); })
  }
}
