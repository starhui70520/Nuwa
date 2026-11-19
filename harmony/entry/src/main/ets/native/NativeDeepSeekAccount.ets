import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { url, util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';

const PLATFORM_ORIGIN: string = 'https://platform.deepseek.com';
const API_ORIGIN: string = 'https://api.deepseek.com';
const CLIENT_VERSION: string = '0.2.2';
const DEVICE_PREFERENCES: string = 'nuwa_native_account';

export interface NativeDeepSeekAuthChallenge {
  authorizeUrl: string;
  redirectUri: string;
}

export interface NativeDeepSeekAccount {
  token: string;
  label: string;
}

export interface NativeDeepSeekBalance {
  currency: string;
  totalBalance: string;
  formatted: string;
  isAvailable: boolean;
}

interface PlatformUserProfile {
  name?: string;
}

interface PlatformUser {
  id_profile?: PlatformUserProfile;
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

interface AuthInitBody {
  code_challenge: string;
  code_challenge_method: string;
  state: string;
  redirect_uri: string;
  locale: string;
  login_source: string;
}

interface AuthExchangeBody {
  code: string;
  code_verifier: string;
  redirect_uri: string;
  device_id: string;
  device_model: string;
  os_version: string;
}

interface AuthCancelBody {
  authorize_id: string;
  code_verifier: string;
}

interface BalanceInfo {
  currency?: string;
  total_balance?: string | number;
}

interface BalancePayload {
  balance_infos?: BalanceInfo[];
  is_available?: boolean;
}

type AuthMethod = 'auth_init' | 'auth_exchange' | 'auth_cancel';

const toBase64Url = (bytes: Uint8Array): string => {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
};

const randomBase64Url = (byteCount: number): string => {
  const random = cryptoFramework.createRandom();
  const bytes = random.generateRandomSync(byteCount);
  return toBase64Url(bytes.data);
};

const sha256Base64Url = async (value: string): Promise<string> => {
  const encoded = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index++) {
    encoded[index] = value.charCodeAt(index) & 0xff;
  }
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: encoded });
  const result = await digest.digest();
  return toBase64Url(result.data);
};

const extractUserLabel = (user?: PlatformUser): string => {
  if (user?.id_profile?.name && user.id_profile.name.trim()) {
    return user.id_profile.name.trim();
  }
  if (user?.mobile && user.mobile.trim()) {
    return user.mobile.trim();
  }
  if (user?.mobile_number && user.mobile_number.trim()) {
    return user.mobile_number.trim();
  }
  if (user?.email && user.email.trim()) {
    return user.email.trim();
  }
  return 'DeepSeek API 账号';
};

const platformHeaders = (locale: string): Record<string, string> => {
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
  headers['x-client-locale'] = locale.toLowerCase().startsWith('zh') ? 'zh_CN' : 'en_US';
  headers['x-client-timezone-offset'] = String(offsetSeconds);
  headers['Content-Type'] = 'application/json';
  return headers;
};

const readQueryParameter = (target: string, name: string): string => {
  const queryStart = target.indexOf('?');
  if (queryStart < 0) {
    return '';
  }
  const hashStart = target.indexOf('#', queryStart);
  const query = hashStart >= 0 ? target.slice(queryStart + 1, hashStart) : target.slice(queryStart + 1);
  const pairs = query.split('&');
  for (let index = 0; index < pairs.length; index++) {
    const equals = pairs[index].indexOf('=');
    const key = equals >= 0 ? pairs[index].slice(0, equals) : pairs[index];
    if (decodeURIComponent(key) === name) {
      const rawValue = equals >= 0 ? pairs[index].slice(equals + 1) : '';
      return decodeURIComponent(rawValue.replace(/\+/g, ' '));
    }
  }
  return '';
};

const normalizedBalance = (currency: string, total: string | number, available: boolean): NativeDeepSeekBalance | null => {
  const numeric = typeof total === 'number' ? total : Number(total.trim());
  if (!Number.isFinite(numeric)) {
    return null;
  }
  let amount: string;
  if (typeof total === 'string' && /^-?\d+\.\d{2}$/.test(total.trim())) {
    amount = total.trim();
  } else if (numeric !== 0 && Math.abs(numeric) < 0.01) {
    amount = numeric.toFixed(4).replace(/0+$/, '').replace(/\.$/, '');
  } else {
    amount = numeric.toFixed(2);
  }
  const upperCurrency = currency.trim().toUpperCase();
  let formatted: string;
  if (upperCurrency === 'CNY' || upperCurrency === 'RMB') {
    formatted = `¥${amount}`;
  } else if (upperCurrency === 'USD') {
    formatted = `$${amount}`;
  } else if (upperCurrency === 'EUR') {
    formatted = `€${amount}`;
  } else {
    formatted = `${upperCurrency} ${amount}`;
  }
  return { currency: upperCurrency, totalBalance: amount, formatted, isAvailable: available };
};

/** Native PKCE account transport. UI owns the WebView and should load only authorizeUrl. */
export class NativeDeepSeekAccountController {
  private locale: string = 'zh_CN';
  private verifier: string = '';
  private state: string = '';
  private redirectUri: string = '';
  private authorizeId: string = '';
  private completed: boolean = false;
  private exchanging: boolean = false;
  private generation: number = 0;
  private activeRequest?: http.HttpRequest;
  private context?: common.UIAbilityContext;

  async startLogin(context: common.UIAbilityContext, locale: string): Promise<NativeDeepSeekAuthChallenge> {
    this.cancel();
    this.context = context;
    const attempt = ++this.generation;
    this.locale = locale.toLowerCase().startsWith('zh') ? 'zh_CN' : 'en_US';
    this.verifier = randomBase64Url(32);
    this.state = randomBase64Url(32);
    this.completed = false;
    this.exchanging = false;
    const port = 30000 + Math.floor(Math.random() * 25000);
    this.redirectUri = `http://127.0.0.1:${port}/oauth/callback`;
    const body: AuthInitBody = {
      code_challenge: await sha256Base64Url(this.verifier),
      code_challenge_method: 'S256',
      state: this.state,
      redirect_uri: this.redirectUri,
      locale: this.locale,
      login_source: 'web',
    };
    try {
      const result = await this.postPlatform('auth_init', JSON.stringify(body), attempt);
      if (attempt !== this.generation) {
        throw new Error('登录已取消');
      }
      const authorizeUrl = result.authorize_url ?? '';
      this.authorizeId = result.authorize_id ?? '';
      this.assertAuthorizeUrl(authorizeUrl);
      return { authorizeUrl, redirectUri: this.redirectUri };
    } catch (error) {
      if (attempt === this.generation) {
        this.clearFlow();
      }
      throw error instanceof Error ? error : new Error('DeepSeek 登录初始化失败');
    }
  }

  /** Call from WebView navigation interception; it never accepts external redirect origins. */
  isRedirect(target: string): boolean {
    if (!target || !this.redirectUri) {
      return false;
    }
    try {
      const targetUrl = url.URL.parseURL(target);
      const redirect = url.URL.parseURL(this.redirectUri);
      return targetUrl.protocol === 'http:' && targetUrl.hostname === '127.0.0.1' &&
        targetUrl.port === redirect.port && targetUrl.pathname === '/oauth/callback';
    } catch {
      return false;
    }
  }

  async handleRedirect(target: string): Promise<NativeDeepSeekAccount | null> {
    if (!this.isRedirect(target) || this.exchanging || this.completed) {
      return null;
    }
    const receivedState = readQueryParameter(target, 'state');
    const code = readQueryParameter(target, 'code');
    if (!code || !receivedState || receivedState !== this.state) {
      throw new Error('授权回调校验失败');
    }
    this.exchanging = true;
    const attempt = this.generation;
    const context = this.context;
    if (!context) {
      this.exchanging = false;
      throw new Error('登录上下文不可用');
    }
    const body: AuthExchangeBody = {
      code: code,
      code_verifier: this.verifier,
      redirect_uri: this.redirectUri,
      device_id: await this.getDeviceId(context),
      device_model: deviceInfo.marketName || 'HarmonyOS',
      os_version: deviceInfo.osFullName || 'HarmonyOS',
    };
    try {
      const result = await this.postPlatform('auth_exchange', JSON.stringify(body), attempt);
      if (attempt !== this.generation) {
        return null;
      }
      const token = result.token ?? '';
      if (!token) {
        throw new Error('DeepSeek 未返回账号令牌');
      }
      const account: NativeDeepSeekAccount = { token: token, label: extractUserLabel(result.user) };
      this.completed = true;
      this.clearFlow();
      return account;
    } catch (error) {
      if (attempt === this.generation) {
        this.exchanging = false;
      }
      throw error instanceof Error ? error : new Error('换取 DeepSeek 账号令牌失败');
    }
  }

  cancel(): void {
    this.generation++;
    const request = this.activeRequest;
    this.activeRequest = undefined;
    if (request) {
      try {
        request.destroy();
      } catch {
        // The request may have completed just before cancellation.
      }
    }
    const authorizeId = this.authorizeId;
    const verifier = this.verifier;
    const locale = this.locale;
    this.clearFlow();
    if (authorizeId && verifier) {
      const body: AuthCancelBody = { authorize_id: authorizeId, code_verifier: verifier };
      void this.postPlatform('auth_cancel', JSON.stringify(body), this.generation, false, locale).catch(() => {});
    }
  }

  async logout(token: string, locale: string): Promise<void> {
    if (!token) {
      return;
    }
    const request = http.createHttp();
    try {
      const headers = platformHeaders(locale);
      headers['x-dsh-auth-token'] = token;
      await request.request(`${PLATFORM_ORIGIN}/auth-api/v0/users/logout`, {
        method: http.RequestMethod.POST,
        header: headers,
        maxRedirects: 0,
        connectTimeout: 10000,
        readTimeout: 10000,
      });
    } catch {
      // Local logout should not depend on a remote revocation request succeeding.
    } finally {
      request.destroy();
    }
  }

  async fetchBalance(token: string, locale: string): Promise<NativeDeepSeekBalance | null> {
    if (!token) {
      return null;
    }
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = {};
      headers['x-dsh-auth-token'] = token;
      const response = await request.request(`${API_ORIGIN}/user/balance`, {
        method: http.RequestMethod.GET,
        header: headers,
        maxRedirects: 0,
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return null;
      }
      const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const payload = JSON.parse(raw) as BalancePayload;
      const infos = payload.balance_infos;
      if (!infos || infos.length === 0) {
        return null;
      }
      const candidates: BalanceInfo[] = [];
      for (let index = 0; index < infos.length; index++) {
        const item = infos[index];
        if (item.currency && (typeof item.total_balance === 'string' || typeof item.total_balance === 'number')) {
          candidates.push(item);
        }
      }
      if (candidates.length === 0) {
        return null;
      }
      let positive: BalanceInfo[] = [];
      for (let index = 0; index < candidates.length; index++) {
        const item = candidates[index];
        const total = item.total_balance as string | number;
        const numeric = typeof total === 'number' ? total : Number(total.trim());
        if (Number.isFinite(numeric) && numeric > 0) {
          positive.push(item);
        }
      }
      const selection = positive.length > 0 ? positive : candidates;
      const preferred = locale.toLowerCase().startsWith('zh') ? 'CNY' : 'USD';
      let selected = selection[0];
      for (let index = 0; index < selection.length; index++) {
        if (selection[index].currency?.trim().toUpperCase() === preferred) {
          selected = selection[index];
          break;
        }
      }
      if (!selected.currency || selected.total_balance === undefined) {
        return null;
      }
      const numeric = typeof selected.total_balance === 'number'
        ? selected.total_balance : Number(selected.total_balance.trim());
      const available = typeof payload.is_available === 'boolean' ? payload.is_available : numeric > 0;
      return normalizedBalance(selected.currency, selected.total_balance, available);
    } catch {
      return null;
    } finally {
      request.destroy();
    }
  }

  private async getDeviceId(context: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(context, DEVICE_PREFERENCES);
    const stored = await store.get('deviceId', '') as string;
    if (stored) {
      return stored;
    }
    const created = util.generateRandomUUID(true);
    await store.put('deviceId', created);
    await store.flush();
    return created;
  }

  private assertAuthorizeUrl(target: string): void {
    let parsed: url.URL;
    try {
      parsed = url.URL.parseURL(target);
    } catch {
      throw new Error('DeepSeek 返回的授权地址无效');
    }
    if (parsed.protocol !== 'https:' || parsed.hostname !== 'platform.deepseek.com' ||
      (parsed.pathname !== '/dsh/authorize' && !parsed.pathname.startsWith('/dsh/authorize/')) ||
      parsed.username || parsed.password) {
      throw new Error('DeepSeek 返回了不受信任的授权地址');
    }
  }

  private async postPlatform(method: AuthMethod, body: string, attempt: number,
    cancellable: boolean = true, locale: string = this.locale): Promise<PlatformBizData> {
    if (attempt !== this.generation) {
      throw new Error('登录已取消');
    }
    const request = http.createHttp();
    if (cancellable) {
      this.activeRequest = request;
    }
    try {
      const response = await request.request(`${PLATFORM_ORIGIN}/auth-api/v0/dsh/${method}`, {
        method: http.RequestMethod.POST,
        header: platformHeaders(locale),
        extraData: body,
        maxRedirects: 0,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (attempt !== this.generation) {
        throw new Error('登录已取消');
      }
      if (response.responseCode === 429) {
        throw new Error('操作过于频繁，请稍后再试 (HTTP 429)');
      }
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`DeepSeek 账号请求失败 (HTTP ${response.responseCode})`);
      }
      const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const envelope = JSON.parse(raw) as PlatformEnvelope;
      if (envelope.code !== 0 || !envelope.data || envelope.data.biz_code !== 0 || !envelope.data.biz_data) {
        throw new Error(envelope.data?.biz_msg || 'DeepSeek 账号请求失败');
      }
      return envelope.data.biz_data;
    } finally {
      if (this.activeRequest === request) {
        this.activeRequest = undefined;
      }
      request.destroy();
    }
  }

  private clearFlow(): void {
    this.verifier = '';
    this.state = '';
    this.redirectUri = '';
    this.authorizeId = '';
    this.exchanging = false;
  }
}
