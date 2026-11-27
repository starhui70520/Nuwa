import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { http } from '@kit.NetworkKit';
import { NativeLocale } from './NativeLocation';
import { NativeApiProtocol, NativeAuthMode } from './NativeSettings';

const FEEDBACK_URL = 'https://dl.rankchord.com/api/reports';
const LOG_STORE = 'nuwa_native_feedback';
const LOG_KEY = 'diagnostics_v1';
const MAX_LOGS = 150;

export type NativeFeedbackLogLevel = 'error' | 'warn' | 'info';

export interface NativeFeedbackLog {
  ts: string;
  level: NativeFeedbackLogLevel;
  source: string;
  message: string;
  detail?: string;
}

export interface NativeFeedbackIssue {
  zh: string;
  en: string;
}

export const NATIVE_FEEDBACK_ISSUES: NativeFeedbackIssue[] = [
  { zh: '页面白屏或闪退', en: 'Blank screen or crash' },
  { zh: '对话报错 / 无法回复', en: 'Chat error or missing reply' },
  { zh: '语音或朗读异常', en: 'Voice input or read-aloud' },
  { zh: '一键导入记录失败', en: 'One-click chat import failed' },
  { zh: '文件 / 图片上传失败', en: 'File or image upload failed' },
  { zh: '界面显示或排版异常', en: 'Display or layout issue' },
  { zh: '其他问题', en: 'Other issue' },
];

export interface NativeFeedbackEnvironment {
  appVersion: string;
  locale: NativeLocale;
  apiProtocol: NativeApiProtocol;
  authMode: NativeAuthMode;
  viewportWidth: number;
  viewportHeight: number;
}

export interface NativeFeedbackDevice {
  appVersion: string;
  platform: string;
  userAgent: string;
  language: string;
  screen: string;
  viewport: string;
  timezone: string;
  apiProtocol: NativeApiProtocol;
  authMode: NativeAuthMode;
}

interface NativeFeedbackSubmission {
  issueType: string;
  description: string;
  contact?: string;
  deviceInfo: NativeFeedbackDevice;
  logs: NativeFeedbackLog[];
}

interface NativeFeedbackResponse {
  code?: string;
  error?: string;
}

let logWrites: Promise<void> = Promise.resolve();

function redactLog(text: string, maxLength: number): string {
  const redacted = text.replace(/sk-[a-zA-Z0-9_-]{8,}/g, 'sk-***')
    .replace(/chd_[a-zA-Z0-9_-]{8,}/g, 'chd_***')
    .replace(/\b(Bearer|Basic)\s+[a-zA-Z0-9._~+\/-]{8,}=*/gi, '$1 ***')
    .replace(/\b(x-api-key|x-dsh-auth-token|authorization|apiKey|dshToken)["']?\s*[:=]\s*["']?[^\s"',}]+/gi, '$1: ***');
  return redacted.length > maxLength ? redacted.slice(0, maxLength) + '…' : redacted;
}

function sanitizeLog(log: NativeFeedbackLog): NativeFeedbackLog {
  return {
    ts: log.ts,
    level: log.level,
    source: redactLog(log.source, 80),
    message: redactLog(log.message, 800),
    detail: log.detail ? redactLog(log.detail, 2500) : undefined,
  };
}

async function readLogs(store: preferences.Preferences): Promise<NativeFeedbackLog[]> {
  const value = await store.get(LOG_KEY, '[]') as string;
  try {
    const logs = JSON.parse(value) as NativeFeedbackLog[];
    if (!Array.isArray(logs)) return [];
    return logs.filter((log: NativeFeedbackLog): boolean => !!log &&
      typeof log.ts === 'string' && typeof log.source === 'string' && typeof log.message === 'string' &&
      (log.detail === undefined || typeof log.detail === 'string') &&
      (log.level === 'error' || log.level === 'warn' || log.level === 'info')).slice(-MAX_LOGS).map(sanitizeLog);
  } catch {
    return [];
  }
}

/** Callers provide diagnostics for app operations without chat or account data. */
export function recordNativeFeedbackLog(context: common.UIAbilityContext, level: NativeFeedbackLogLevel,
  source: string, message: string, detail?: string): Promise<void> {
  const entry = sanitizeLog({ ts: new Date().toISOString(), level, source, message, detail });
  logWrites = logWrites.then(async (): Promise<void> => {
    const store = await preferences.getPreferences(context, LOG_STORE);
    const logs = await readLogs(store);
    logs.push(entry);
    await store.put(LOG_KEY, JSON.stringify(logs.slice(-MAX_LOGS)));
    await store.flush();
  }).catch(() => {});
  return logWrites;
}

export async function getNativeFeedbackLogs(context: common.UIAbilityContext): Promise<NativeFeedbackLog[]> {
  try {
    await logWrites;
    return await readLogs(await preferences.getPreferences(context, LOG_STORE));
  } catch {
    return [];
  }
}

export function collectNativeFeedbackDevice(env: NativeFeedbackEnvironment): NativeFeedbackDevice {
  let screen = 'unknown';
  let language: string = env.locale;
  let timezone = 'unknown';
  try {
    const primary = display.getDefaultDisplaySync();
    const density = primary.densityPixels || 1;
    screen = `${Math.round(primary.width / density)}x${Math.round(primary.height / density)}@${density.toFixed(2)}`;
  } catch {
    // Display information can be temporarily unavailable while the window changes.
  }
  try {
    language = i18n.System.getSystemLanguage() || env.locale;
    timezone = i18n.getTimeZone().getID() || 'unknown';
  } catch {
    // Report the app language and the device information already available.
  }
  const version = deviceInfo.osFullName || 'HarmonyOS';
  const model = deviceInfo.marketName || deviceInfo.productModel;
  return {
    appVersion: env.appVersion,
    platform: 'harmony',
    userAgent: model ? `Nuwa (${version}; ${model})` : `Nuwa (${version})`,
    language,
    screen,
    viewport: env.viewportWidth > 0 && env.viewportHeight > 0 ?
      `${Math.round(env.viewportWidth)}x${Math.round(env.viewportHeight)}` : 'unknown',
    timezone,
    apiProtocol: env.apiProtocol,
    authMode: env.authMode,
  };
}

export async function submitNativeFeedback(issueType: string, description: string, contact: string,
  device: NativeFeedbackDevice, logs: NativeFeedbackLog[], locale: NativeLocale): Promise<string> {
  const english = locale === 'en-US';
  const submission: NativeFeedbackSubmission = {
    issueType: issueType.trim().slice(0, 80),
    description: description.trim().slice(0, 4000),
    contact: contact.trim().slice(0, 120) || undefined,
    deviceInfo: device,
    logs: logs.slice(-MAX_LOGS).map(sanitizeLog),
  };
  if (!submission.description) {
    throw new Error(english ? 'Briefly describe the issue you encountered.' : '请简要描述您遇到的问题');
  }

  const request = http.createHttp();
  try {
    const response = await request.request(FEEDBACK_URL, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json', Accept: 'application/json' },
      extraData: JSON.stringify(submission),
      usingCache: false,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 20000,
      maxRedirects: 0,
    });
    let result: NativeFeedbackResponse = {};
    try {
      const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      result = (JSON.parse(raw) as NativeFeedbackResponse) ?? {};
    } catch {
      // A non-JSON error response can still provide a useful HTTP status.
    }
    const code = typeof result.code === 'string' ? result.code.trim() : '';
    if (response.responseCode >= 200 && response.responseCode < 300 && code) return code;
    const error = typeof result.error === 'string' ? result.error : '';
    throw new Error(error || (english ? `Report failed (HTTP ${response.responseCode})` :
      `上报失败（HTTP ${response.responseCode}）`));
  } finally {
    request.destroy();
  }
}
