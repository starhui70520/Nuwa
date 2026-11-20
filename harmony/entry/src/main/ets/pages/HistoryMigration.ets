import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { commitChatBackup, NativeChatBackup } from '../native/NativeChatBackup';
import { NativeConversationState } from '../native/NativeConversation';
import { NativeChatStorage } from '../native/NativeChatStorage';
import { MAX_FILE_BACKUP_BYTES } from '../native/NativeBackupZip';
import {
  completeNativeMigrationDownload, consumePendingNativeMigration, discardIncompleteNativeMigration,
  discardPendingNativeMigration, hasPendingNativeMigration, NATIVE_MIGRATION_SIZE_ERROR, nativeMigrationDownloadPath,
} from '../native/NativePendingMigration';
import { buildNativeMigrationExportScript } from '../native/NativeMigrationStrategy';

interface MigrationRouteParams {
  clearSession?: boolean;
  forceReExport?: boolean;
}

const CHAT_ORIGIN = 'https://chat.deepseek.com';
const CHAT_URL = CHAT_ORIGIN + '/';
const MIGRATION_BRIDGE_PERMISSION =
  '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"https","host":"chat.deepseek.com","port":"","path":""}]}}';
const MIGRATION_DOWNLOAD_RETRY_DELAYS: number[] = [1000, 2000];

interface MigrationDownloadProgress {
  update: (item: webview.WebDownloadItem) => void;
  fail: (item: webview.WebDownloadItem) => void;
  finish: (item: webview.WebDownloadItem) => void;
}

let migrationResumeDelegate: webview.WebDownloadDelegate | undefined;
let activeMigrationResumeProgress: MigrationDownloadProgress | undefined;

function registerMigrationResumeProgress(progress: MigrationDownloadProgress): void {
  // ArkWeb keeps the process-wide manager delegate from its first registration.
  if (!migrationResumeDelegate) {
    const delegate = new webview.WebDownloadDelegate();
    delegate.onDownloadUpdated((item) => { activeMigrationResumeProgress?.update(item); });
    delegate.onDownloadFailed((item) => { activeMigrationResumeProgress?.fail(item); });
    delegate.onDownloadFinish((item) => { activeMigrationResumeProgress?.finish(item); });
    webview.WebDownloadManager.setDownloadDelegate(delegate);
    migrationResumeDelegate = delegate;
  }
  activeMigrationResumeProgress = progress;
}

class MigrationExportBridge {
  private onLoginDetected: () => void;
  private onWaitingExportCb: () => void;
  private onTimeoutCb: () => void;

  constructor(onLoginDetected: () => void, onWaitingExportCb: () => void, onTimeoutCb: () => void) {
    this.onLoginDetected = onLoginDetected;
    this.onWaitingExportCb = onWaitingExportCb;
    this.onTimeoutCb = onTimeoutCb;
  }

  onLoggedIn(): void {
    this.onLoginDetected();
  }

  onStep(_msg: string): void {
  }

  onWaitingExport(): void {
    this.onWaitingExportCb();
  }

  onAutoExportTimeout(): void {
    this.onTimeoutCb();
  }
}

@Entry
@Component
struct HistoryMigration {
  private readonly migrationController = new webview.WebviewController();
  private readonly migrationPreparationController = new webview.WebviewController();
  private readonly downloadDelegate = new webview.WebDownloadDelegate();
  private readonly backup = new NativeChatBackup();
  private readonly conversationStorage = new NativeChatStorage();
  @State private importingMigration: boolean = false;
  @State private pendingMigrationAvailable: boolean = false;
  @State private migrationStatusText: string = '';
  @State private migrationPreparing: boolean = false;
  private pageActive: boolean = false;
  private nativeMigrationDownload?: webview.WebDownloadItem;
  private readonly migrationDownloadProgress: MigrationDownloadProgress = {
    update: (item) => { this.updateNativeMigrationDownload(item); },
    fail: (item) => { this.onNativeMigrationDownloadFailed(item); },
    finish: (item) => { this.finishNativeMigrationDownload(item); },
  };
  private migrationDownloadRetryCount: number = 0;
  private migrationDownloadRetryTimer: number = -1;
  private migrationAutoExportTriggered: boolean = false;
  private migrationForceReExport: boolean = false;
  private migrationClearSession: boolean = false;
  private migrationClearingSession: boolean = false;
  private migrationResetHistory: boolean = false;
  private migrationPollTimer: number = -1;

  private migrationExportBridge: MigrationExportBridge = new MigrationExportBridge(
    () => {
      if (this.migrationAutoExportTriggered || !this.pageActive || this.importingMigration ||
        this.pendingMigrationAvailable ||
        this.migrationClearSession || this.migrationClearingSession) {
        return;
      }
      this.migrationAutoExportTriggered = true;
      this.migrationStatusText = '已检测到登录，正在自动打开设置并导出...';
      this.runMigrationAutoExportScript(false);
    },
    () => {
      this.migrationStatusText = '已触发官方导出，正在等待生成导出包（约需 1-3 分钟，生成后将自动下载）...';
    },
    () => {
      if (!this.pageActive) {
        return;
      }
      this.migrationStatusText = '未定位到按钮，请手动点「设置 → 数据管理 → 导出/下载」';
    }
  );

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as MigrationRouteParams | undefined;
    this.migrationForceReExport = params?.forceReExport === true;
    this.migrationClearSession = params?.clearSession === true;
    this.migrationPreparing = this.migrationClearSession;
    this.pageActive = true;
    this.migrationStatusText = this.migrationClearSession ? '正在切换账号…' :
      '请登录 DeepSeek 账号，登录成功后将自动辅助导出';
    this.startMigrationLoginPoll();
  }

  onPageShow(): void {
    void this.importNativeDownload();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.stopMigrationLoginPoll();
    this.cancelNativeMigrationDownload();
  }

  private startMigrationLoginPoll(): void {
    this.stopMigrationLoginPoll();
    this.migrationPollTimer = setInterval(() => {
      if (!this.pageActive || this.migrationAutoExportTriggered) {
        this.stopMigrationLoginPoll();
        return;
      }
      this.checkMigrationLoginState();
    }, 1500);
  }

  private stopMigrationLoginPoll(): void {
    if (this.migrationPollTimer >= 0) {
      clearInterval(this.migrationPollTimer);
      this.migrationPollTimer = -1;
    }
  }

  private checkMigrationLoginState(): void {
    if (!this.pageActive || this.migrationAutoExportTriggered || this.importingMigration ||
      this.pendingMigrationAvailable ||
      this.migrationClearSession || this.migrationClearingSession) {
      return;
    }
    const js = "(function(){"
      + "if (location.hostname !== 'chat.deepseek.com') return;"
      + "var p = location.pathname || '';"
      + "if (p.indexOf('sign_in') >= 0 || p.indexOf('login') >= 0) return;"
      + "var hasInput = !!document.querySelector('textarea');"
      + "var hasPassInput = !!document.querySelector('input[type=\"password\"]');"
      + "if (hasInput && !hasPassInput && window.HarmonyMigrationBridge) {"
      + "  window.HarmonyMigrationBridge.onLoggedIn();"
      + "}"
      + "})();";
    try {
      this.migrationController.runJavaScript(js);
    } catch {
      // 忽略页面未就绪时的调用异常
    }
  }

  private runMigrationAutoExportScript(manualTrigger: boolean): void {
    if (!this.pageActive || this.importingMigration || this.pendingMigrationAvailable ||
      this.migrationClearSession || this.migrationClearingSession) {
      return;
    }
    if (manualTrigger) {
      this.migrationStatusText = '正在尝试自动点击导出，请稍候...';
    }
    const js = buildNativeMigrationExportScript(manualTrigger, this.migrationForceReExport);
    try {
      this.migrationController.runJavaScript(js);
    } catch {
      // 忽略执行异常
    }
  }

  private onMigrationPageEnd(address: string): void {
    if (!this.pageActive || address === 'about:blank' || this.importingMigration || this.pendingMigrationAvailable ||
      this.migrationClearSession || this.migrationClearingSession) return;
    if (this.migrationResetHistory) {
      this.migrationResetHistory = false;
      this.migrationController.clearHistory();
    }
    this.checkMigrationLoginState();
  }

  private switchMigrationAccount(): void {
    if (this.importingMigration || this.pendingMigrationAvailable || this.migrationClearingSession) return;
    this.cancelNativeMigrationDownload();
    this.migrationForceReExport = false;
    this.migrationAutoExportTriggered = false;
    this.migrationClearSession = true;
    this.migrationStatusText = '正在切换账号…';
    this.startMigrationLoginPoll();
    void this.clearMigrationSession();
  }

  private async clearMigrationSession(): Promise<void> {
    if (this.migrationClearingSession || !this.pageActive) return;
    this.migrationClearingSession = true;
    try {
      const controller = this.migrationPreparing ? this.migrationPreparationController : this.migrationController;
      const address = controller.getUrl();
      if (address === CHAT_ORIGIN || address.startsWith(CHAT_URL)) {
        const script = "(function(){if(location.origin !== " + JSON.stringify(CHAT_ORIGIN) + ") return;" +
          "clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportRunning = false;" +
          "sessionStorage.clear(); localStorage.clear();})();";
        await controller.runJavaScript(script);
      }
      controller.removeCache(true);
      await webview.WebCookieManager.clearAllCookies();
      webview.WebStorage.deleteOrigin(CHAT_ORIGIN);
      if (!this.pageActive) return;
      this.migrationStatusText = '请登录要导入的 DeepSeek 账号';
      if (this.migrationPreparing) {
        this.migrationPreparing = false;
      } else {
        this.migrationResetHistory = true;
        controller.loadUrl(CHAT_URL);
      }
      this.migrationClearSession = false;
    } catch {
      this.migrationStatusText = '未能切换账号，请重试';
    } finally {
      this.migrationClearingSession = false;
    }
  }

  private clearNativePartialDownload(): void {
    try {
      discardIncompleteNativeMigration(this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch {
      // A subsequent download can retry cleanup.
    }
  }

  private cancelNativeMigrationDownload(): void {
    const download = this.nativeMigrationDownload;
    this.nativeMigrationDownload = undefined;
    this.resetNativeMigrationRetry();
    if (!download) {
      return;
    }
    try {
      download.cancel();
    } catch {
      // The WebView can already have canceled when it detached.
    }
    this.clearNativePartialDownload();
  }

  private resetNativeMigrationRetry(): void {
    if (this.migrationDownloadRetryTimer >= 0) {
      clearTimeout(this.migrationDownloadRetryTimer);
      this.migrationDownloadRetryTimer = -1;
    }
    this.migrationDownloadRetryCount = 0;
    if (activeMigrationResumeProgress === this.migrationDownloadProgress) {
      activeMigrationResumeProgress = undefined;
    }
  }

  private failNativeMigrationDownload(): void {
    this.cancelNativeMigrationDownload();
    this.migrationStatusText = '下载导出包失败，请重新点击下载';
  }

  private retryNativeMigrationDownload(item: webview.WebDownloadItem): boolean {
    if (this.migrationDownloadRetryTimer >= 0) return true;
    if (this.migrationDownloadRetryCount >= MIGRATION_DOWNLOAD_RETRY_DELAYS.length ||
      item.getState() !== webview.WebDownloadState.INTERRUPTED) return false;
    const error = item.getLastErrorCode();
    if (error !== webview.WebDownloadErrorCode.NETWORK_FAILED &&
      error !== webview.WebDownloadErrorCode.NETWORK_TIMEOUT &&
      error !== webview.WebDownloadErrorCode.NETWORK_DISCONNECTED &&
      error !== webview.WebDownloadErrorCode.NETWORK_SERVER_DOWN &&
      error !== webview.WebDownloadErrorCode.SERVER_UNREACHABLE &&
      error !== webview.WebDownloadErrorCode.SERVER_CONTENT_LENGTH_MISMATCH) return false;

    let serialized: Uint8Array;
    try {
      serialized = item.serialize();
    } catch {
      return false;
    }
    if (!serialized.length) return false;
    const delay = MIGRATION_DOWNLOAD_RETRY_DELAYS[this.migrationDownloadRetryCount++];
    this.nativeMigrationDownload = item;
    this.migrationStatusText = '连接中断，正在重试下载导出包…';
    this.migrationDownloadRetryTimer = setTimeout(() => {
      this.migrationDownloadRetryTimer = -1;
      if (!this.activeNativeMigrationDownload(item)) return;
      try {
        const resumed = webview.WebDownloadItem.deserialize(serialized);
        if (!resumed.getGuid()) {
          this.failNativeMigrationDownload();
          return;
        }
        registerMigrationResumeProgress(this.migrationDownloadProgress);
        this.nativeMigrationDownload = resumed;
        webview.WebDownloadManager.resumeDownload(resumed);
      } catch {
        this.failNativeMigrationDownload();
      }
    }, delay);
    return true;
  }

  private discardPendingMigration(): void {
    try {
      discardPendingNativeMigration(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.pendingMigrationAvailable = false;
      this.migrationAutoExportTriggered = false;
      this.migrationStatusText = '已放弃此次导出包，可以重新导出';
    } catch (error) {
      this.migrationStatusText = (error as Error).message || '无法放弃导出包';
    }
  }

  private async importNativeDownload(receivedBytes?: number): Promise<void> {
    if (this.importingMigration || this.nativeMigrationDownload) {
      return;
    }
    const ui = this.getUIContext();
    const context = ui.getHostContext() as common.UIAbilityContext;
    if (receivedBytes === undefined && !hasPendingNativeMigration(context)) {
      return;
    }
    this.importingMigration = true;
    this.migrationAutoExportTriggered = true;
    this.stopMigrationLoginPoll();
    this.migrationStatusText = '正在导入并合并历史对话，请稍候…';
    try {
      if (receivedBytes !== undefined) {
        await completeNativeMigrationDownload(context, receivedBytes);
      }
      this.pendingMigrationAvailable = true;
      const importedCount = await consumePendingNativeMigration(context, async (path: string): Promise<number> => {
        const sessions = await this.backup.importFromUri(path, context);
        const history = await this.conversationStorage.loadConversations(context);
        const merged = await commitChatBackup(context, history, sessions,
          (state: NativeConversationState): Promise<void> => this.conversationStorage.saveConversations(context, state));
        return merged.importedCount;
      });
      this.pendingMigrationAvailable = hasPendingNativeMigration(context);
      if (importedCount !== null) {
        ui.getPromptAction().showToast({ message: importedCount ? `已导入 ${importedCount} 个对话` : '没有新增对话' });
        ui.getRouter().back();
      }
    } catch (error) {
      this.migrationStatusText = (error as Error).message || '读取导出包失败，请重试';
      this.pendingMigrationAvailable = hasPendingNativeMigration(context);
      this.clearNativePartialDownload();
    } finally {
      this.importingMigration = false;
    }
  }

  private startNativeMigrationDownload(item: webview.WebDownloadItem): void {
    if (!this.pageActive) {
      item.cancel();
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.importingMigration || this.nativeMigrationDownload || this.migrationClearSession ||
      this.migrationClearingSession || hasPendingNativeMigration(context)) {
      item.cancel();
      return;
    }
    if (item.getTotalBytes() > MAX_FILE_BACKUP_BYTES) {
      item.cancel();
      this.migrationStatusText = NATIVE_MIGRATION_SIZE_ERROR;
      return;
    }
    try {
      discardIncompleteNativeMigration(context);
      this.nativeMigrationDownload = item;
      this.migrationStatusText = '正在下载历史记录导出包...';
      item.start(nativeMigrationDownloadPath(context));
    } catch (error) {
      this.cancelNativeMigrationDownload();
      this.migrationStatusText = (error as Error).message || '无法下载导出包，请重试';
    }
  }

  private activeNativeMigrationDownload(item: webview.WebDownloadItem): boolean {
    return this.pageActive && this.nativeMigrationDownload?.getGuid() === item.getGuid();
  }

  private updateNativeMigrationDownload(item: webview.WebDownloadItem): void {
    if (!this.activeNativeMigrationDownload(item)) return;
    this.nativeMigrationDownload = item;
    if (item.getReceivedBytes() > MAX_FILE_BACKUP_BYTES) {
      this.cancelNativeMigrationDownload();
      this.migrationStatusText = NATIVE_MIGRATION_SIZE_ERROR;
    }
  }

  private onNativeMigrationDownloadFailed(item: webview.WebDownloadItem): void {
    if (!this.activeNativeMigrationDownload(item)) return;
    if (item.getReceivedBytes() > MAX_FILE_BACKUP_BYTES) {
      this.cancelNativeMigrationDownload();
      this.migrationStatusText = NATIVE_MIGRATION_SIZE_ERROR;
    } else if (!this.retryNativeMigrationDownload(item)) {
      this.failNativeMigrationDownload();
    }
  }

  private finishNativeMigrationDownload(item: webview.WebDownloadItem): void {
    if (!this.activeNativeMigrationDownload(item)) return;
    this.nativeMigrationDownload = undefined;
    this.resetNativeMigrationRetry();
    void this.importNativeDownload(item.getReceivedBytes());
  }

  private setupMigrationDownloadDelegate(): void {
    this.downloadDelegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      this.startNativeMigrationDownload(item);
    });
    this.downloadDelegate.onDownloadUpdated(this.migrationDownloadProgress.update);
    this.downloadDelegate.onDownloadFailed(this.migrationDownloadProgress.fail);
    this.downloadDelegate.onDownloadFinish(this.migrationDownloadProgress.finish);
    this.migrationController.setDownloadDelegate(this.downloadDelegate);
  }

  onBackPress(): boolean {
    if (this.importingMigration) return true;
    if (this.migrationPreparing || this.pendingMigrationAvailable || !this.migrationController.accessBackward()) return false;
    this.migrationController.backward();
    return true;
  }

  build() {
    Column() {
      Column() {
        Text(this.migrationStatusText)
          .fontSize(12.5)
          .fontColor('#FFFFFF')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Button(this.pendingMigrationAvailable ? '重试导入' : '自动导出')
            .fontSize(12.5)
            .fontColor('#FFFFFF')
            .backgroundColor(Color.Transparent)
            .enabled(!this.importingMigration)
            .onClick(() => {
              if (this.pendingMigrationAvailable) {
                void this.importNativeDownload();
              } else {
                this.runMigrationAutoExportScript(true);
              }
            })
          if (this.pendingMigrationAvailable) {
            Button('放弃导出包')
              .fontSize(12.5)
              .fontColor('#FFFFFF')
              .backgroundColor(Color.Transparent)
              .enabled(!this.importingMigration)
              .onClick(() => { this.discardPendingMigration(); })
          } else {
            Button('切换账号')
              .fontSize(12.5)
              .fontColor('#FFFFFF')
              .backgroundColor(Color.Transparent)
              .enabled(!this.importingMigration)
              .onClick(() => { this.switchMigrationAccount(); })
          }
          Button('关闭')
            .fontSize(12.5)
            .fontColor('#FFFFFF')
            .backgroundColor(Color.Transparent)
            .enabled(!this.importingMigration)
            .onClick(() => { this.getUIContext().getRouter().back(); })
        }
        .width('100%').justifyContent(FlexAlign.End)
      }
      .width('100%')
      .padding({ left: 14, right: 8, top: 10, bottom: 10 })
      .backgroundColor('#1D4ED8')

      if (this.migrationPreparing) {
        Web({ src: 'about:blank', controller: this.migrationPreparationController })
          .width('100%').layoutWeight(1)
          .onControllerAttached(() => { void this.clearMigrationSession(); })
      } else {
        Web({ src: CHAT_URL, controller: this.migrationController })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .databaseAccess(true)
          .mixedMode(MixedMode.Compatible)
          .javaScriptProxy({
            object: this.migrationExportBridge,
            name: 'HarmonyMigrationBridge',
            methodList: ['onLoggedIn', 'onStep', 'onWaitingExport', 'onAutoExportTimeout'],
            controller: this.migrationController,
            permission: MIGRATION_BRIDGE_PERMISSION,
          })
          .onControllerAttached(() => { this.setupMigrationDownloadDelegate(); })
          .onPageEnd((event: OnPageEndEvent) => { this.onMigrationPageEnd(event.url); })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
