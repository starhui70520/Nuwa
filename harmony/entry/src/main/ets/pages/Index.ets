import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const PLATFORM_ORIGIN = 'https://platform.deepseek.com';
const CLIENT_VERSION = '0.2.2';

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

class HarmonyBridge {
  private onStartAuth: () => void;
  private onLogoutAuth: (token: string) => void;

  constructor(onStartAuth: () => void, onLogoutAuth: (token: string) => void) {
    this.onStartAuth = onStartAuth;
    this.onLogoutAuth = onLogoutAuth;
  }

  startPlatformAuth(): void {
    this.onStartAuth();
  }

  logoutPlatformAuth(token: string): void {
    this.onLogoutAuth(token);
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
  return {
    'x-client-bundle-id': '',
    'x-client-platform': 'web',
    'x-client-version': CLIENT_VERSION,
    'x-client-locale': 'zh_CN',
    'x-client-timezone-offset': String(offsetSeconds),
    'Content-Type': 'application/json',
  };
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private authController: webview.WebviewController = new webview.WebviewController();

  @State private authVisible: boolean = false;
  @State private authUrl: string = '';
  @State private authStatusText: string = '正在连接 DeepSeek 开放平台...';

  private pkceVerifier: string = '';
  private pkceState: string = '';
  private pkceRedirectUri: string = '';
  private pkceAuthorizeId: string = '';
  private authExchanging: boolean = false;
  private authCompleted: boolean = false;
  private cachedDeviceId: string = '';

  private harmonyBridge: HarmonyBridge = new HarmonyBridge(
    () => {
      void this.startPkceLogin();
    },
    (token: string) => {
      void this.logoutPlatformToken(token);
    }
  );

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

  onBackPress(): boolean {
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
        src: $rawfile('web/index.html'),
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
          methodList: ['startPlatformAuth', 'logoutPlatformAuth'],
          controller: this.controller,
        })

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
