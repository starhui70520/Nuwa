import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { webview } from '@kit.ArkWeb';
import { url, util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';

const PLATFORM_ORIGIN = 'https://platform.deepseek.com';
const HOSTED_PRIVACY_POLICY_URL =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2086009982511225600';
const CLIENT_VERSION = '0.2.2';
const APP_WEB_URL = 'resource://rawfile/web/index.html';
const APP_BRIDGE_PERMISSION =
  '{"javascriptProxyPermission":{"urlPermissionList":[{"scheme":"resource","host":"rawfile","port":"","path":""}]}}';

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
  private migrationAutoExportTriggered: boolean = false;
  private migrationPollTimer: number = -1;

  private migrationExportBridge: MigrationExportBridge = new MigrationExportBridge(
    () => {
      if (this.migrationAutoExportTriggered || !this.migrationVisible) {
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

  aboutToDisappear(): void {
    this.harmonyBridge.destroySpeech();
    try {
      this.controller.deleteJavaScriptRegister('__NUWA_HARMONY__');
    } catch {
      // The WebView may already be detached.
    }
  }

  private async openPrivacyPolicy(): Promise<void> {
    let policyUrl = HOSTED_PRIVACY_POLICY_URL;
    try {
      const policy = privacyManager.getAppPrivacyMgmtInfo().privacyInfo.find(
        (link) => link.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK
      );
      if (policy?.url) {
        const managedUrl = url.URL.parseURL(policy.url);
        if (managedUrl.protocol === 'https:') {
          policyUrl = managedUrl.href;
        }
      }
    } catch {
      // Sideloaded builds can lack AppGallery privacy metadata.
    }

    const uiContext = this.getUIContext();
    try {
      const context = uiContext.getHostContext() as common.UIAbilityContext;
      await context.openLink(policyUrl, { appLinkingOnly: false });
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
    this.migrationStatusText = '请登录 DeepSeek 账号，登录成功后将自动辅助导出';
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
    if (!this.migrationVisible || this.migrationAutoExportTriggered) {
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
    if (!this.migrationVisible) {
      return;
    }
    if (manualTrigger) {
      this.migrationStatusText = '正在尝试自动点击导出，请稍候...';
    }
    const resetJs = manualTrigger
      ? "if (window.__dsappAutoExportTimer) { clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportTimer = null; } window.__dsappAutoExportRunning = false;"
      : "";
    const js = "(function(){"
      + resetJs
      + "if (window.__dsappAutoExportRunning) return;"
      + "window.__dsappAutoExportRunning = true;"
      + "var triggerClick = function(el) {"
      + "  if (!el) return false;"
      + "  var target = (el.closest && el.closest('button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], [tabindex=\"0\"], a')) || el;"
      + "  if (!target || typeof target.click !== 'function') return false;"
      + "  try { target.scrollIntoView({ block: 'nearest', inline: 'center' }); } catch (e) {}"
      + "  target.click();"
      + "  return true;"
      + "};"
      + "var findVisibleByText = function(patterns, excludeDanger) {"
      + "  var nodes = Array.from(document.querySelectorAll('button, [role=\"button\"], [role=\"menuitem\"], [role=\"tab\"], [tabindex=\"0\"], a, li, div, span'));"
      + "  var best = null;"
      + "  var bestLen = 999;"
      + "  var bestArea = 999999999;"
      + "  for (var i = 0; i < nodes.length; i++) {"
      + "    var el = nodes[i];"
      + "    var rect = el.getBoundingClientRect();"
      + "    if (rect.width <= 0 || rect.height <= 0) continue;"
      + "    var text = (el.innerText || '').trim();"
      + "    if (!text || text.length > 32) continue;"
      + "    if (excludeDanger && /^(删除|Delete)$/i.test(text)) continue;"
      + "    for (var j = 0; j < patterns.length; j++) {"
      + "      if (patterns[j].test(text)) {"
      + "        var area = rect.width * rect.height;"
      + "        if (text.length < bestLen || (text.length === bestLen && area < bestArea)) {"
      + "          best = el;"
      + "          bestLen = text.length;"
      + "          bestArea = area;"
      + "        }"
      + "        break;"
      + "      }"
      + "    }"
      + "  }"
      + "  return best;"
      + "};"
      + "var clickHamburger = function() {"
      + "  var els = Array.from(document.querySelectorAll('[tabindex=\"0\"], button, [role=\"button\"], div'));"
      + "  var best = null;"
      + "  var bestArea = 999999;"
      + "  for (var i = 0; i < els.length; i++) {"
      + "    var el = els[i];"
      + "    var r = el.getBoundingClientRect();"
      + "    if (r.width >= 20 && r.width <= 72 && r.height >= 20 && r.height <= 72 && r.left >= 0 && r.left < 80 && r.top >= 0 && r.top < 110 && el.querySelector('svg')) {"
      + "      var area = r.width * r.height;"
      + "      if (area < bestArea) { best = el; bestArea = area; }"
      + "    }"
      + "  }"
      + "  return triggerClick(best);"
      + "};"
      + "var clickProfileBar = function() {"
      + "  var els = Array.from(document.querySelectorAll('[tabindex=\"0\"], button, [role=\"button\"]'));"
      + "  for (var i = 0; i < els.length; i++) {"
      + "    var el = els[i];"
      + "    if (el.tagName === 'A') continue;"
      + "    var r = el.getBoundingClientRect();"
      + "    if (r.width >= 120 && r.width <= 340 && r.height >= 32 && r.height <= 80 && r.left >= 0 && r.left < 80 && r.bottom > window.innerHeight - 90) {"
      + "      return triggerClick(el);"
      + "    }"
      + "  }"
      + "  return false;"
      + "};"
      + "var ticks = 0;"
      + "var exportClicked = false;"
      + "var lastSection = '';"
      + "var lastAction = '';"
      + "var lastActionTick = -10;"
      + "var timer = setInterval(function() {"
      + "  try {"
      + "    ticks++;"
      + "    var maxTicks = exportClicked ? 260 : 30;"
      + "    if (ticks > maxTicks) {"
      + "      clearInterval(timer);"
      + "      window.__dsappAutoExportTimer = null;"
      + "      window.__dsappAutoExportRunning = false;"
      + "      window.HarmonyMigrationBridge && window.HarmonyMigrationBridge.onAutoExportTimeout();"
      + "      return;"
      + "    }"
      + "    var confirmBtn = findVisibleByText([/^(确认导出|确认|确定|Confirm)$/i], true);"
      + "    if (confirmBtn && triggerClick(confirmBtn)) {"
      + "      return;"
      + "    }"
      + "    if (lastSection === 'data' || findVisibleByText([/导出所有历史对话|Export all/i], true)) {"
      + "      var dlBtn = findVisibleByText([/^(下载|Download)$/i], true);"
      + "      if (dlBtn && triggerClick(dlBtn)) {"
      + "        clearInterval(timer);"
      + "        window.__dsappAutoExportTimer = null;"
      + "        window.__dsappAutoExportRunning = false;"
      + "        return;"
      + "      }"
      + "      if (!exportClicked) {"
      + "        var expBtn = findVisibleByText([/^(导出数据|导出|Export Data|Export)$/i], true);"
      + "        if (expBtn && triggerClick(expBtn)) {"
      + "          exportClicked = true;"
      + "          window.HarmonyMigrationBridge && window.HarmonyMigrationBridge.onWaitingExport();"
      + "          return;"
      + "        }"
      + "      }"
      + "      return;"
      + "    }"
      + "    if (findVisibleByText([/^(通用设置|账号管理|General|Account)$/i], true) || findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true)) {"
      + "      var dataTab = findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true);"
      + "      if (dataTab && triggerClick(dataTab)) {"
      + "        lastSection = 'data';"
      + "        return;"
      + "      }"
      + "    }"
      + "    var settingsItem = findVisibleByText([/^(系统设置|Settings)$/i], true);"
      + "    if (settingsItem && triggerClick(settingsItem)) {"
      + "      return;"
      + "    }"
      + "    if (findVisibleByText([/^(开启新对话|New chat)$/i], true)) {"
      + "      if (lastAction !== 'profile' || ticks - lastActionTick >= 3) {"
      + "        if (clickProfileBar()) {"
      + "          lastAction = 'profile';"
      + "          lastActionTick = ticks;"
      + "        }"
      + "      }"
      + "      return;"
      + "    }"
      + "    if (lastAction !== 'hamburger' || ticks - lastActionTick >= 3) {"
      + "      if (clickHamburger()) {"
      + "        lastAction = 'hamburger';"
      + "        lastActionTick = ticks;"
      + "      }"
      + "    }"
      + "  } catch (err) {}"
      + "}, 700);"
      + "window.__dsappAutoExportTimer = timer;"
      + "})();";
    try {
      this.migrationController.runJavaScript(js);
    } catch {
      // 忽略执行异常
    }
  }

  private setupMigrationDownloadDelegate(): void {
    this.downloadDelegate.onBeforeDownload((item: webview.WebDownloadItem) => {
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

    this.downloadDelegate.onDownloadFailed((_item: webview.WebDownloadItem) => {
      this.migrationStatusText = '下载导出包失败，请重新点击下载';
    });

    this.downloadDelegate.onDownloadFinish((_item: webview.WebDownloadItem) => {
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

      if (this.migrationVisible) {
        Column() {
          Row() {
            Text(this.migrationStatusText)
              .fontSize(12.5)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('自动导出')
              .fontSize(12.5)
              .fontColor('#FFFFFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.runMigrationAutoExportScript(true);
              })
            Button('关闭')
              .fontSize(12.5)
              .fontColor('#FFFFFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.closeMigrationOverlay();
              })
          }
          .width('100%')
          .padding({ left: 14, right: 8, top: 10, bottom: 10 })
          .backgroundColor('#1D4ED8')

          Web({
            src: 'https://chat.deepseek.com/',
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
            })
            .onControllerAttached(() => {
              this.setupMigrationDownloadDelegate();
            })
            .onPageEnd(() => {
              if (!this.migrationAutoExportTriggered) {
                this.checkMigrationLoginState();
              }
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
