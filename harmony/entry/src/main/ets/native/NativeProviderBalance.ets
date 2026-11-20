import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';

const DEFAULT_API_ORIGIN: string = 'https://api.deepseek.com';
const DEFAULT_RETRY_AFTER_MS: number = 15000;

export interface NativeDeepSeekBalance {
  currency: string;
  totalBalance: string;
  formatted: string;
  isAvailable: boolean;
}

type JsonRecord = Record<string, Object>;

interface NormalizedProviderBase {
  base: string;
  pathname: string;
  hostname: string;
}

interface BalanceCandidate {
  currency: string;
  total: string | number;
  numeric: number;
}

function isRecord(value: Object | null): boolean {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function asRecord(value: Object | null): JsonRecord | null {
  return isRecord(value) ? value as JsonRecord : null;
}

function finiteAmount(value: Object | null): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function buildBalance(currency: string, total: string | number, available: boolean): NativeDeepSeekBalance | null {
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
  return { currency: upperCurrency, totalBalance: amount, formatted: formatted, isAvailable: available };
}

function normalizeOrigin(baseUrl: string): NormalizedProviderBase | null {
  const trimmed = baseUrl.trim();
  const target = trimmed.length > 0 ? trimmed : DEFAULT_API_ORIGIN;
  try {
    const parsed = url.URL.parseURL(target);
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) {
      return null;
    }
    let pathname = parsed.pathname.replace(/\/+$/, '');
    pathname = pathname.replace(/\/(?:v1|anthropic\/v1)$/i, '');
    parsed.pathname = pathname.length > 0 ? pathname : '/';
    parsed.search = '';
    parsed.hash = '';
    return {
      base: parsed.href.replace(/\/+$/, ''),
      pathname: parsed.pathname.replace(/\/+$/, ''),
      hostname: parsed.hostname.toLowerCase(),
    };
  } catch {
    return null;
  }
}

function retryAfterMs(headers: Object): number {
  const fields = asRecord(headers);
  if (!fields) return DEFAULT_RETRY_AFTER_MS;
  for (const name of Object.keys(fields)) {
    if (name.toLowerCase() !== 'retry-after') continue;
    const raw = fields[name];
    const value = Array.isArray(raw) ? (raw as Object[])[0] : raw;
    if (typeof value !== 'string' && typeof value !== 'number') break;
    const retry = String(value).trim();
    const delay = /^\d+$/.test(retry) ? Number(retry) * 1000 : Date.parse(retry) - Date.now();
    if (Number.isFinite(delay)) return Math.max(1000, delay);
    break;
  }
  return DEFAULT_RETRY_AFTER_MS;
}

export class NativeBalanceRequest {
  private request?: http.HttpRequest;
  private cancelled: boolean = false;
  retryAfterMs: number = 0;

  async fetch(baseUrl: string, apiKey: string, accountToken: string, locale: string): Promise<NativeDeepSeekBalance | null> {
    const token = accountToken.trim();
    if (token) {
      if (/[\r\n]/.test(token)) return null;
      const header: Record<string, string> = {};
      header['x-dsh-auth-token'] = token;
      return parseDeepSeekBalance(await this.getJson(DEFAULT_API_ORIGIN, '/user/balance', header), locale);
    }
    return fetchNativeProviderBalance(this, baseUrl, apiKey, locale);
  }

  cancel(): void {
    this.cancelled = true;
    const request = this.request;
    this.request = undefined;
    if (request) this.release(request);
  }

  async getJson(origin: string, path: string, header: Record<string, string>): Promise<Object | null> {
    if (this.cancelled || this.retryAfterMs) return null;
    let request: http.HttpRequest | undefined;
    try {
      request = http.createHttp();
      this.request = request;
      const response = await request.request(`${origin}${path}`, {
        method: http.RequestMethod.GET,
        header: header,
        usingCache: false,
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
        maxRedirects: 0,
      });
      if (response.responseCode === 429) this.retryAfterMs = retryAfterMs(response.header);
      if (response.responseCode < 200 || response.responseCode >= 300) return null;
      const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      return JSON.parse(raw) as Object;
    } catch {
      return null;
    } finally {
      if (request && this.request === request) {
        this.request = undefined;
        this.release(request);
      }
    }
  }

  private release(request: http.HttpRequest): void {
    try {
      request.destroy();
    } catch {
      // The system can close a request while the page is cancelling it.
    }
  }
}

function parseDeepSeekBalance(value: Object | null, locale: string): NativeDeepSeekBalance | null {
  const payload = asRecord(value);
  if (!payload || !Array.isArray(payload.balance_infos)) {
    return null;
  }
  const candidates: BalanceCandidate[] = [];
  const infos = payload.balance_infos as Array<Object>;
  for (let index = 0; index < infos.length; index++) {
    const info = asRecord(infos[index]);
    if (!info || typeof info.currency !== 'string' ||
      (typeof info.total_balance !== 'string' && typeof info.total_balance !== 'number')) {
      continue;
    }
    const numeric = finiteAmount(info.total_balance);
    if (numeric !== null) {
      candidates.push({ currency: info.currency, total: info.total_balance as string | number, numeric: numeric });
    }
  }
  if (candidates.length === 0) {
    return null;
  }
  const positive: BalanceCandidate[] = [];
  for (let index = 0; index < candidates.length; index++) {
    if (candidates[index].numeric > 0) {
      positive.push(candidates[index]);
    }
  }
  const pool = positive.length > 0 ? positive : candidates;
  const preferred = locale.toLowerCase().startsWith('zh') ? 'CNY' : 'USD';
  let chosen = pool[0];
  for (let index = 0; index < pool.length; index++) {
    if (pool[index].currency.trim().toUpperCase() === preferred) {
      chosen = pool[index];
      break;
    }
  }
  const available = typeof payload.is_available === 'boolean' ? payload.is_available : chosen.numeric > 0;
  return buildBalance(chosen.currency, chosen.total, available);
}

function toYmd(timestamp: number): string {
  const date = new Date(timestamp);
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}

/**
 * Read a provider balance using the active API-key origin. Every request stays
 * on that HTTPS origin, disables redirects, and returns null for unsupported or
 * unavailable provider endpoints.
 */
async function fetchNativeProviderBalance(
  request: NativeBalanceRequest,
  baseUrl: string,
  apiKey: string,
  locale: string,
): Promise<NativeDeepSeekBalance | null> {
  const key = apiKey.trim();
  if (!key || /[\r\n]/.test(key)) {
    return null;
  }
  const normalized = normalizeOrigin(baseUrl);
  if (!normalized) {
    return null;
  }
  const base = normalized.base;
  const header: Record<string, string> = {};
  header['Authorization'] = `Bearer ${key}`;

  const deepSeek = await request.getJson(base, '/user/balance', header);
  const directBalance = parseDeepSeekBalance(deepSeek, locale);
  if (directBalance) {
    return directBalance;
  }

  if (normalized.hostname.includes('openrouter.ai')) {
    const creditsPath = normalized.pathname.endsWith('/api') ? '/v1/credits' : '/api/v1/credits';
    const payload = asRecord(await request.getJson(base, creditsPath, header));
    const data = payload && asRecord(payload.data) ? asRecord(payload.data) : payload;
    if (!data) {
      return null;
    }
    const credits = finiteAmount(data.total_credits);
    const usage = finiteAmount(data.total_usage);
    if (credits === null || usage === null) {
      return null;
    }
    const remaining = credits - usage;
    return buildBalance('USD', remaining, remaining > 0);
  }

  if (normalized.hostname.includes('siliconflow')) {
    const payload = asRecord(await request.getJson(base, '/v1/user/info', header));
    const data = payload && asRecord(payload.data) ? asRecord(payload.data) : payload;
    if (!data || (typeof data.totalBalance !== 'string' && typeof data.totalBalance !== 'number')) {
      return null;
    }
    const amount = finiteAmount(data.totalBalance);
    if (amount === null) {
      return null;
    }
    return buildBalance('CNY', data.totalBalance as string | number, amount > 0);
  }

  const subscription = asRecord(await request.getJson(base, '/v1/dashboard/billing/subscription', header));
  if (!subscription || typeof subscription.hard_limit_usd !== 'number' ||
    !Number.isFinite(subscription.hard_limit_usd) || subscription.hard_limit_usd <= 0 ||
    subscription.hard_limit_usd >= 10_000_000) {
    return null;
  }
  const now = Date.now();
  const startDate = toYmd(now - 99 * 86_400_000);
  const endDate = toYmd(now + 86_400_000);
  const usagePath = `/v1/dashboard/billing/usage?start_date=${startDate}&end_date=${endDate}`;
  const usage = asRecord(await request.getJson(base, usagePath, header));
  if (!usage || typeof usage.total_usage !== 'number' || !Number.isFinite(usage.total_usage)) {
    return null;
  }
  const remaining = subscription.hard_limit_usd - usage.total_usage / 100;
  return buildBalance('USD', remaining, remaining > 0);
}
