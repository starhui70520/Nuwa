import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
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
  private readonly downloadDelegate = new webview.WebDownloadDelegate();
  private readonly backup = new NativeChatBackup();
  private readonly conversationStorage = new NativeChatStorage();
  @State private importingMigration: boolean = false;
  @State private pendingMigrationAvailable: boolean = false;
  @State private migrationStatusText: string = '';
  private pageActive: boolean = false;
  private nativeMigrationDownload?: webview.WebDownloadItem;
  private migrationAutoExportTriggered: boolean = false;
  private migrationForceReExport: boolean = false;
  private migrationClearSession: boolean = false;
  private migrationClearingSession: boolean = false;
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

  private onMigrationPageEnd(): void {
    if (this.importingMigration || this.pendingMigrationAvailable) return;
    if (this.migrationClearSession) {
      void this.clearMigrationSession();
    } else {
      this.checkMigrationLoginState();
    }
  }

  private switchMigrationAccount(): void {
    if (this.importingMigration || this.pendingMigrationAvailable || this.migrationClearingSession) return;
    this.cancelNativeMigrationDownload();
    this.migrationForceReExport = false;
    this.migrationAutoExportTriggered = false;
    this.migrationClearSession = true;
    this.migrationStatusText = '正在切换账号…';
    this.startMigrationLoginPoll();
    try {
      if (new url.URL(this.migrationController.getUrl()).origin === CHAT_ORIGIN) {
        void this.clearMigrationSession();
      } else {
        this.migrationController.loadUrl(CHAT_URL);
      }
    } catch {
      this.migrationStatusText = '未能打开 DeepSeek 网页，请重试';
    }
  }

  private async clearMigrationSession(): Promise<void> {
    if (this.migrationClearingSession || !this.pageActive) return;
    this.migrationClearingSession = true;
    try {
      if (new url.URL(this.migrationController.getUrl()).origin !== CHAT_ORIGIN) return;
      const script = "(function(){if(location.origin !== 'https://chat.deepseek.com') return;" +
        "clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportRunning = false;" +
        "sessionStorage.clear(); localStorage.clear();})();";
      await this.migrationController.runJavaScript(script);
      await webview.WebCookieManager.clearAllCookies();
      webview.WebStorage.deleteOrigin(CHAT_ORIGIN);
      if (!this.pageActive) return;
      this.migrationClearSession = false;
      this.migrationStatusText = '请登录要导入的 DeepSeek 账号';
      this.migrationController.loadUrl(CHAT_URL);
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
    if (!download) {
      return;
    }
    this.nativeMigrationDownload = undefined;
    try {
      download.cancel();
    } catch {
      // The WebView can already have canceled when it detached.
    }
    this.clearNativePartialDownload();
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
    return this.nativeMigrationDownload?.getGuid() === item.getGuid();
  }

  private setupMigrationDownloadDelegate(): void {
    this.downloadDelegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      this.startNativeMigrationDownload(item);
    });

    this.downloadDelegate.onDownloadUpdated((item: webview.WebDownloadItem) => {
      if (this.activeNativeMigrationDownload(item)) {
        this.nativeMigrationDownload = item;
        if (item.getReceivedBytes() > MAX_FILE_BACKUP_BYTES) {
          this.cancelNativeMigrationDownload();
          this.migrationStatusText = NATIVE_MIGRATION_SIZE_ERROR;
        }
      }
    });

    this.downloadDelegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      if (!this.activeNativeMigrationDownload(item)) return;
      this.nativeMigrationDownload = undefined;
      this.clearNativePartialDownload();
      this.migrationStatusText = '下载导出包失败，请重新点击下载';
    });

    this.downloadDelegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      if (!this.activeNativeMigrationDownload(item)) return;
      this.nativeMigrationDownload = undefined;
      void this.importNativeDownload(item.getReceivedBytes());
    });

    this.migrationController.setDownloadDelegate(this.downloadDelegate);
  }

  onBackPress(): boolean {
    if (this.importingMigration) return true;
    if (this.pendingMigrationAvailable || !this.migrationController.accessBackward()) return false;
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

      Web({
        src: CHAT_URL,
        controller: this.migrationController,
      })
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
        .onControllerAttached(() => {
          this.setupMigrationDownloadDelegate();
        })
        .onPageEnd(() => {
          this.onMigrationPageEnd();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
