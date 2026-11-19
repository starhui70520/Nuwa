import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { NativeDeepSeekBalance } from './NativeDeepSeekAccount';

const DEFAULT_API_ORIGIN: string = 'https://api.deepseek.com';

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

async function getJson(origin: string, path: string, apiKey: string): Promise<Object | null> {
  const request = http.createHttp();
  try {
    const response = await request.request(`${origin}${path}`, {
      method: http.RequestMethod.GET,
      header: { Authorization: `Bearer ${apiKey}` },
      usingCache: false,
      connectTimeout: 10000,
      readTimeout: 10000,
      expectDataType: http.HttpDataType.STRING,
      maxRedirects: 0,
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      return null;
    }
    const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
    return JSON.parse(raw) as Object;
  } catch {
    return null;
  } finally {
    request.destroy();
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
export async function fetchNativeProviderBalance(
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

  const deepSeek = await getJson(base, '/user/balance', key);
  const directBalance = parseDeepSeekBalance(deepSeek, locale);
  if (directBalance) {
    return directBalance;
  }

  if (normalized.hostname.includes('openrouter.ai')) {
    const creditsPath = normalized.pathname.endsWith('/api') ? '/v1/credits' : '/api/v1/credits';
    const payload = asRecord(await getJson(base, creditsPath, key));
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
    const payload = asRecord(await getJson(base, '/v1/user/info', key));
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

  const subscription = asRecord(await getJson(base, '/v1/dashboard/billing/subscription', key));
  if (!subscription || typeof subscription.hard_limit_usd !== 'number' ||
    !Number.isFinite(subscription.hard_limit_usd) || subscription.hard_limit_usd <= 0 ||
    subscription.hard_limit_usd >= 10_000_000) {
    return null;
  }
  const now = Date.now();
  const startDate = toYmd(now - 99 * 86_400_000);
  const endDate = toYmd(now + 86_400_000);
  const usagePath = `/v1/dashboard/billing/usage?start_date=${startDate}&end_date=${endDate}`;
  const usage = asRecord(await getJson(base, usagePath, key));
  if (!usage || typeof usage.total_usage !== 'number' || !Number.isFinite(usage.total_usage)) {
    return null;
  }
  const remaining = subscription.hard_limit_usd - usage.total_usage / 100;
  return buildBalance('USD', remaining, remaining > 0);
}
