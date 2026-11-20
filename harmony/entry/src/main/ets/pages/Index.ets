import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { url, util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';
import { commitChatBackup, NativeChatBackup } from '../native/NativeChatBackup';
import { NativeConversationState } from '../native/NativeConversation';
import { NativeChatStorage } from '../native/NativeChatStorage';
import { MAX_FILE_BACKUP_BYTES } from '../native/NativeBackupZip';
import {
  completeNativeMigrationDownload, consumePendingNativeMigration, discardIncompleteNativeMigration,
  discardPendingNativeMigration, hasPendingNativeMigration, NATIVE_MIGRATION_SIZE_ERROR, nativeMigrationDownloadPath,
} from '../native/NativePendingMigration';
import { buildNativeMigrationExportScript } from '../native/NativeMigrationStrategy';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';

interface MigrationRouteParams {
  migrate?: boolean;
  clearSession?: boolean;
  forceReExport?: boolean;
}

const CHAT_ORIGIN = 'https://chat.deepseek.com';
const CHAT_URL = CHAT_ORIGIN + '/';
const PLATFORM_ORIGIN = 'https://platform.deepseek.com';
const CLIENT_VERSION = '0.2.2';
const APP_WEB_URL = 'resource://rawfile/web/index.html';
const APP_BRIDGE_PERMISSION =
  '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"resource","host":"rawfile","port":"","path":""}]}}';
const MIGRATION_BRIDGE_PERMISSION =
  '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"https","host":"chat.deepseek.com","port":"","path":""}]}}';

interface PlatformIdProfile {
  name?: string;
}

interface PlatformUser {
  id_profile?: PlatformIdProfile;
  mobile?: string;
  mobile_number?: string;
  email?: string;
}

interface PlatformBizData {
  authorize_url?: string;
  authorize_id?: string;
  token?: string;
  user?: PlatformUser;
}

interface PlatformData {
  biz_code?: number;
  biz_msg?: string;
  biz_data?: PlatformBizData;
}

interface PlatformEnvelope {
  code?: number;
  data?: PlatformData;
}

interface SpeechEvent {
  id: string;
  state: string;
  text?: string;
  code?: string;
}

interface HarmonyBridgeHandlers {
  onStartAuth: () => void;
  onLogoutAuth: (token: string) => void;
  onOpenExport: () => void;
  onOpenPrivacyPolicy: () => void;
  getContext: () => common.UIAbilityContext;
  onSpeechEvent: (name: string, detail: SpeechEvent) => void;
}

class HarmonyBridge {
  private readonly handlers: HarmonyBridgeHandlers;
  private readonly recognizer: HarmonySpeechRecognition;
  private readonly speaker: HarmonyTextToSpeech;

  constructor(handlers: HarmonyBridgeHandlers) {
    this.handlers = handlers;
    this.recognizer = new HarmonySpeechRecognition((id: string, state: string, text?: string, code?: string) => {
      handlers.onSpeechEvent('nuwa:harmony-asr', { id, state, text, code });
    });
    this.speaker = new HarmonyTextToSpeech((id: string, state: string) => {
      handlers.onSpeechEvent('nuwa:harmony-tts', { id, state });
    });
  }

  startPlatformAuth(): void {
    this.handlers.onStartAuth();
  }

  logoutPlatformAuth(token: string): void {
    this.handlers.onLogoutAuth(token);
  }

  openExportBrowser(): void {
    this.handlers.onOpenExport();
  }

  openPrivacyPolicy(): void {
    this.handlers.onOpenPrivacyPolicy();
  }

  startSpeechRecognition(id: string, _locale: string): void {
    this.recognizer.start(id, this.handlers.getContext());
  }

  stopSpeechRecognition(id: string): void {
    this.recognizer.finish(id);
  }

  cancelSpeechRecognition(id: string): void {
    this.recognizer.cancel(id);
  }

  speakText(id: string, text: string, locale: string): void {
    this.speaker.speak(id, text, locale);
  }

  stopSpeaking(id: string): void {
    this.speaker.stop(id);
  }

  destroySpeech(): void {
    this.recognizer.cancel();
    this.speaker.destroy();
  }
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

function toBase64Url(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  const b64 = helper.encodeToStringSync(bytes);
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function randomBase64Url(byteCount: number): string {
  const rand = cryptoFramework.createRandom();
  const blob = rand.generateRandomSync(byteCount);
  return toBase64Url(blob.data);
}

async function sha256Base64Url(input: string): Promise<string> {
  const encoded = new Uint8Array(input.length);
  for (let i = 0; i < input.length; i++) {
    encoded[i] = input.charCodeAt(i) & 0xff;
  }
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: encoded });
  const digest = await md.digest();
  return toBase64Url(digest.data);
}

function extractQueryParam(url: string, key: string): string {
  const qIndex = url.indexOf('?');
  if (qIndex < 0) {
    return '';
  }
  const hashIndex = url.indexOf('#', qIndex);
  const query = hashIndex >= 0 ? url.slice(qIndex + 1, hashIndex) : url.slice(qIndex + 1);
  const pairs = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eqIndex = pairs[i].indexOf('=');
    const k = eqIndex >= 0 ? pairs[i].slice(0, eqIndex) : pairs[i];
    if (decodeURIComponent(k) === key) {
      const v = eqIndex >= 0 ? pairs[i].slice(eqIndex + 1) : '';
      return decodeURIComponent(v.replace(/\+/g, ' '));
    }
  }
  return '';
}

function extractUserLabel(user?: PlatformUser): string {
  if (!user) {
    return 'DeepSeek API 账号';
  }
  if (user.id_profile?.name && user.id_profile.name.trim().length > 0) {
    return user.id_profile.name.trim();
  }
  if (user.mobile && user.mobile.trim().length > 0) {
    return user.mobile.trim();
  }
  if (user.mobile_number && user.mobile_number.trim().length > 0) {
    return user.mobile_number.trim();
  }
  if (user.email && user.email.trim().length > 0) {
    return user.email.trim();
  }
  return 'DeepSeek API 账号';
}

function buildClientHeaders(): Record<string, string> {
  const offsetSeconds = -new Date().getTimezoneOffset() * 60;
  const headers: Record<string, string> = {};
  headers['User-Agent'] =
    'Mozilla/5.0 (Phone; OpenHarmony 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';
  headers['Accept'] = 'application/json, text/plain, */*';
  headers['Origin'] = PLATFORM_ORIGIN;
  headers['Referer'] = `${PLATFORM_ORIGIN}/`;
  headers['x-client-bundle-id'] = '';
  headers['x-client-platform'] = 'web';
  headers['x-client-version'] = CLIENT_VERSION;
  headers['x-client-locale'] = 'zh_CN';
  headers['x-client-timezone-offset'] = String(offsetSeconds);
  headers['Content-Type'] = 'application/json';
  return headers;
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private authController: webview.WebviewController = new webview.WebviewController();
  private migrationController: webview.WebviewController = new webview.WebviewController();
  private downloadDelegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();

  @State private authVisible: boolean = false;
  @State private authUrl: string = '';
  @State private authStatusText: string = '正在连接 DeepSeek 开放平台...';

  @State private nativeMigration: boolean = false;
  @State private importingMigration: boolean = false;
  @State private pendingMigrationAvailable: boolean = false;
  private readonly backup = new NativeChatBackup();
  private readonly conversationStorage = new NativeChatStorage();
  @State private migrationVisible: boolean = false;
  @State private migrationStatusText: string = '请登录 DeepSeek 账号并在「设置 → 数据管理」点击导出';

  private pkceVerifier: string = '';
  private pkceState: string = '';
  private pkceRedirectUri: string = '';
  private pkceAuthorizeId: string = '';
  private authExchanging: boolean = false;
  private authCompleted: boolean = false;
  private cachedDeviceId: string = '';
  private migrationSavePath: string = '';
  private migrationFileName: string = 'deepseek_data.zip';
  private nativeMigrationDownload?: webview.WebDownloadItem;
  private migrationAutoExportTriggered: boolean = false;
  private migrationForceReExport: boolean = false;
  private migrationClearSession: boolean = false;
  private migrationClearingSession: boolean = false;
  private migrationPollTimer: number = -1;

  private migrationExportBridge: MigrationExportBridge = new MigrationExportBridge(
    () => {
      if (this.migrationAutoExportTriggered || !this.migrationVisible || this.importingMigration ||
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
      if (!this.migrationVisible) {
        return;
      }
      this.migrationStatusText = '未定位到按钮，请手动点「设置 → 数据管理 → 导出/下载」';
    }
  );

  private harmonyBridge: HarmonyBridge = new HarmonyBridge({
    onStartAuth: () => {
      void this.startPkceLogin();
    },
    onLogoutAuth: (token: string) => {
      void this.logoutPlatformToken(token);
    },
    onOpenExport: () => {
      this.openMigrationOverlay();
    },
    onOpenPrivacyPolicy: () => {
      void this.openPrivacyPolicy();
    },
    getContext: () => this.getUIContext().getHostContext() as common.UIAbilityContext,
    onSpeechEvent: (name: string, detail: SpeechEvent) => {
      // A recognition result belongs only to Nuwa's bundled page.
      try {
        if (this.controller.getUrl().split(/[?#]/, 1)[0] === APP_WEB_URL) {
          const event = `new CustomEvent(${JSON.stringify(name)}, { detail: ${JSON.stringify(detail)} })`;
          const script = `if (location.href.split(/[?#]/, 1)[0] === ${JSON.stringify(APP_WEB_URL)}) ` +
            `{ window.dispatchEvent(${event}); }`;
          void this.controller.runJavaScript(script).catch(() => {});
        }
      } catch {
        // The WebView may have been disposed while the service was returning a result.
      }
    }
  });

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as MigrationRouteParams | undefined;
    if (params?.migrate) {
      this.nativeMigration = true;
      this.migrationForceReExport = params.forceReExport === true;
      this.migrationClearSession = params.clearSession === true;
      this.openMigrationOverlay();
    }
  }

  onPageShow(): void {
    if (this.nativeMigration) {
      void this.importNativeDownload();
    }
  }

  aboutToDisappear(): void {
    this.stopMigrationLoginPoll();
    this.cancelNativeMigrationDownload();
    this.harmonyBridge.destroySpeech();
    try {
      this.controller.deleteJavaScriptRegister('__NUWA_HARMONY__');
    } catch {
      // The WebView may already be detached.
    }
  }

  private async openPrivacyPolicy(): Promise<void> {
    const uiContext = this.getUIContext();
    try {
      const context = uiContext.getHostContext() as common.UIAbilityContext;
      await openNuwaPrivacyPolicy(context);
    } catch {
      uiContext.getPromptAction().showToast({ message: $r('app.string.privacy_policy_unavailable') });
    }
  }

  private getDeviceId(): string {
    if (!this.cachedDeviceId) {
      this.cachedDeviceId = util.generateRandomUUID(true);
    }
    return this.cachedDeviceId;
  }

  private async postPlatform(method: string, bodyJson: string): Promise<PlatformBizData> {
    const req = http.createHttp();
    try {
      const res = await req.request(`${PLATFORM_ORIGIN}/auth-api/v0/dsh/${method}`, {
        method: http.RequestMethod.POST,
        header: buildClientHeaders(),
        extraData: bodyJson,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (res.responseCode === 429) {
        throw new Error('操作过于频繁，请稍后再试 (HTTP 429)');
      }
      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`HTTP ${res.responseCode}`);
      }
      const raw = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const envelope = JSON.parse(raw) as PlatformEnvelope;
      if (envelope.code !== 0 || !envelope.data || envelope.data.biz_code !== 0 || !envelope.data.biz_data) {
        const msg = envelope.data?.biz_msg || `code=${envelope.code ?? -1}`;
        throw new Error(msg);
      }
      return envelope.data.biz_data;
    } finally {
      req.destroy();
    }
  }

  private async logoutPlatformToken(token: string): Promise<void> {
    if (!token) {
      return;
    }
    const req = http.createHttp();
    try {
      const headers = buildClientHeaders();
      headers['x-dsh-auth-token'] = token;
      await req.request(`${PLATFORM_ORIGIN}/auth-api/v0/users/logout`, {
        method: http.RequestMethod.POST,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 10000,
      });
    } catch {
      // 忽略远端吊销异常
    } finally {
      req.destroy();
    }
  }

  private async startPkceLogin(): Promise<void> {
    this.authVisible = true;
    this.authUrl = '';
    this.authStatusText = '正在连接 DeepSeek 开放平台...';
    this.authExchanging = false;
    this.authCompleted = false;

    try {
      this.pkceVerifier = randomBase64Url(32);
      this.pkceState = randomBase64Url(32);
      const challenge = await sha256Base64Url(this.pkceVerifier);
      const port = 30000 + (Math.floor(Math.random() * 25000));
      this.pkceRedirectUri = `http://127.0.0.1:${port}/oauth/callback`;

      const body = JSON.stringify({
        code_challenge: challenge,
        code_challenge_method: 'S256',
        state: this.pkceState,
        redirect_uri: this.pkceRedirectUri,
        locale: 'zh_CN',
        login_source: 'web',
      });

      const bizData = await this.postPlatform('auth_init', body);
      const targetUrl = bizData.authorize_url || '';
      this.pkceAuthorizeId = bizData.authorize_id || '';

      if (!targetUrl.startsWith(`${PLATFORM_ORIGIN}/dsh/authorize`)) {
        throw new Error('Unexpected authorize_url');
      }

      this.authStatusText = '请登录并授权 Nuwa 使用你的 DeepSeek API 账号';
      this.authUrl = targetUrl;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : JSON.stringify(err);
      hilog.error(0x0000, 'NuwaAuth', 'startPkceLogin failed: %{public}s', errMsg);
      this.authVisible = false;
      this.authUrl = '';
      const payload = JSON.stringify({ message: errMsg });
      this.controller.runJavaScript(
        `window.dispatchEvent(new CustomEvent('nuwa:harmony-auth-error',{detail:${payload}}));`
      );
    }
  }

  private handleAuthIntercept(url: string): boolean {
    if (!url || !this.pkceRedirectUri || !url.startsWith(this.pkceRedirectUri)) {
      return false;
    }
    if (this.authExchanging || this.authCompleted) {
      return true;
    }

    const receivedState = extractQueryParam(url, 'state');
    const code = extractQueryParam(url, 'code');
    if (!receivedState || receivedState !== this.pkceState || !code) {
      this.authStatusText = '授权回调校验失败，请关闭重试';
      return true;
    }

    this.authExchanging = true;
    this.authStatusText = '授权成功，正在获取账号令牌...';
    void this.exchangeCode(code);
    return true;
  }

  private async exchangeCode(code: string): Promise<void> {
    try {
      const body = JSON.stringify({
        code,
        code_verifier: this.pkceVerifier,
        redirect_uri: this.pkceRedirectUri,
        device_id: this.getDeviceId(),
        device_model: deviceInfo.marketName || 'HarmonyOS',
        os_version: deviceInfo.osFullName || 'HarmonyOS',
      });
      const bizData = await this.postPlatform('auth_exchange', body);
      const token = bizData.token || '';
      if (!token) {
        throw new Error('Missing token');
      }
      const accountLabel = extractUserLabel(bizData.user);
      this.authCompleted = true;
      this.authVisible = false;
      this.authUrl = '';
      const payload = JSON.stringify({ token, accountLabel });
      this.controller.runJavaScript(
        `window.dispatchEvent(new CustomEvent('nuwa:harmony-auth',{detail:${payload}}));`
      );
    } catch {
      this.authExchanging = false;
      this.authStatusText = '换取账号令牌失败，请关闭重试';
    }
  }

  private closeAuthOverlay(): void {
    const shouldCancel = !this.authCompleted && this.pkceAuthorizeId && this.pkceVerifier;
    const cancelId = this.pkceAuthorizeId;
    const cancelVerifier = this.pkceVerifier;
    this.authVisible = false;
    this.authUrl = '';
    this.pkceAuthorizeId = '';
    if (shouldCancel) {
      void this.postPlatform(
        'auth_cancel',
        JSON.stringify({ authorize_id: cancelId, code_verifier: cancelVerifier })
      ).catch(() => {});
    }
  }

  private openMigrationOverlay(): void {
    this.migrationAutoExportTriggered = false;
    this.migrationStatusText = this.migrationClearSession ? '正在切换账号…' :
      '请登录 DeepSeek 账号，登录成功后将自动辅助导出';
    this.migrationVisible = true;
    this.startMigrationLoginPoll();
  }

  private closeMigrationOverlay(): void {
    this.stopMigrationLoginPoll();
    this.migrationAutoExportTriggered = false;
    this.migrationVisible = false;
  }

  private startMigrationLoginPoll(): void {
    this.stopMigrationLoginPoll();
    this.migrationPollTimer = setInterval(() => {
      if (!this.migrationVisible || this.migrationAutoExportTriggered) {
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
    if (!this.migrationVisible || this.migrationAutoExportTriggered || this.importingMigration ||
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
    if (!this.migrationVisible || this.importingMigration || this.pendingMigrationAvailable ||
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
    if (this.migrationClearingSession || !this.migrationVisible) return;
    this.migrationClearingSession = true;
    try {
      if (new url.URL(this.migrationController.getUrl()).origin !== CHAT_ORIGIN) return;
      const script = "(function(){if(location.origin !== 'https://chat.deepseek.com') return;" +
        "clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportRunning = false;" +
        "sessionStorage.clear(); localStorage.clear();})();";
      await this.migrationController.runJavaScript(script);
      await webview.WebCookieManager.clearAllCookies();
      webview.WebStorage.deleteOrigin(CHAT_ORIGIN);
      if (!this.migrationVisible) return;
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
      if (this.nativeMigration) {
        this.startNativeMigrationDownload(item);
        return;
      }
      if (this.importingMigration) {
        item.cancel();
        return;
      }
      const suggested = item.getSuggestedFileName();
      this.migrationFileName = suggested && suggested.trim().length > 0 ? suggested.trim() : 'deepseek_data.zip';
      this.migrationSavePath = `${getContext(this).cacheDir}/pending_migration.zip`;
      try {
        if (fs.accessSync(this.migrationSavePath)) {
          fs.unlinkSync(this.migrationSavePath);
        }
      } catch {
        // 忽略不存在
      }
      this.migrationStatusText = '正在下载历史记录导出包...';
      item.start(this.migrationSavePath);
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
      if (this.nativeMigration) {
        if (!this.activeNativeMigrationDownload(item)) {
          return;
        }
        this.nativeMigrationDownload = undefined;
        this.clearNativePartialDownload();
      }
      this.migrationStatusText = '下载导出包失败，请重新点击下载';
    });

    this.downloadDelegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      if (this.nativeMigration) {
        if (this.activeNativeMigrationDownload(item)) {
          this.nativeMigrationDownload = undefined;
          void this.importNativeDownload(item.getReceivedBytes());
        }
        return;
      }
      try {
        const stat = fs.statSync(this.migrationSavePath);
        const buf = new ArrayBuffer(stat.size);
        const file = fs.openSync(this.migrationSavePath, fs.OpenMode.READ_ONLY);
        try {
          fs.readSync(file.fd, buf);
        } finally {
          fs.closeSync(file);
        }
        try {
          fs.unlinkSync(this.migrationSavePath);
        } catch {
          // 忽略清理失败
        }
        const b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
        this.closeMigrationOverlay();
        this.controller.runJavaScript(
          `window.__NUWA_IMPORT_BASE64__ && window.__NUWA_IMPORT_BASE64__(${JSON.stringify(b64)}, ${JSON.stringify(this.migrationFileName)});`
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        hilog.error(0x0000, 'NuwaMigration', 'Import failed: %{public}s', msg);
        this.migrationStatusText = '读取导出包失败，请重试';
      }
    });

    this.migrationController.setDownloadDelegate(this.downloadDelegate);
  }

  onBackPress(): boolean {
    if (this.importingMigration) {
      return true;
    }
    if (this.nativeMigration) {
      if (this.pendingMigrationAvailable) {
        return false;
      }
      if (this.migrationController.accessBackward()) {
        this.migrationController.backward();
        return true;
      }
      return false;
    }
    if (this.migrationVisible) {
      if (this.migrationController.accessBackward()) {
        this.migrationController.backward();
      } else {
        this.closeMigrationOverlay();
      }
      return true;
    }
    if (this.authVisible) {
      if (this.authUrl && this.authController.accessBackward()) {
        this.authController.backward();
      } else {
        this.closeAuthOverlay();
      }
      return true;
    }
    if (this.controller.accessBackward()) {
      this.controller.backward();
      return true;
    }
    return false;
  }

  build() {
    Stack() {
      if (!this.nativeMigration) {
        Web({
          src: APP_WEB_URL,
          controller: this.controller,
        })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .databaseAccess(true)
          .fileAccess(true)
          .mixedMode(MixedMode.Compatible)
          .darkMode(WebDarkMode.Auto)
          .javaScriptProxy({
            object: this.harmonyBridge,
            name: '__NUWA_HARMONY__',
            methodList: [
              'startPlatformAuth', 'logoutPlatformAuth', 'openExportBrowser', 'openPrivacyPolicy',
              'startSpeechRecognition', 'stopSpeechRecognition', 'cancelSpeechRecognition', 'speakText', 'stopSpeaking'
            ],
            permission: APP_BRIDGE_PERMISSION,
            controller: this.controller,
          })
          .onPageBegin(() => {
            this.harmonyBridge.destroySpeech();
          })

      }

      if (this.migrationVisible) {
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
                .onClick(() => {
                  if (this.nativeMigration) {
                    this.getUIContext().getRouter().back();
                  } else {
                    this.closeMigrationOverlay();
                  }
                })
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

      if (this.authVisible) {
        Column() {
          Row() {
            Text(this.authStatusText)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('关闭')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.closeAuthOverlay();
              })
          }
          .width('100%')
          .padding({ left: 14, right: 8, top: 10, bottom: 10 })
          .backgroundColor('#18181B')

          if (this.authUrl) {
            Web({
              src: this.authUrl,
              controller: this.authController,
            })
              .width('100%')
              .layoutWeight(1)
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .databaseAccess(true)
              .mixedMode(MixedMode.Compatible)
              .onLoadIntercept((event) => {
                return this.handleAuthIntercept(event.data.getRequestUrl());
              })
          } else {
            Column() {
              LoadingProgress()
                .width(36)
                .height(36)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#FFFFFF')
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
  }
}
