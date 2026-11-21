import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { url } from '@kit.ArkTS';
import { NativeSettings, NativeSettingsController, NativeManualPreference } from './NativeSettings';
import { NativeLocale, NativeUserLocation, restoreNativeLocation } from './NativeLocation';
import { NativeDeepSeekAccount } from './NativeDeepSeekAccount';
import { loadNativeAccount, saveNativeAccount } from './NativeAccountStore';

const PREFERENCES_NAME: string = 'nuwa_native_settings';
const MIGRATION_MARKER: string = 'legacyWebViewPreferencesMigratedV1';

const legacyValue = (legacy: Record<string, string>, name: string): string | undefined => {
  const key = `chat-demo:${name}`;
  if (!Object.keys(legacy).includes(key)) return undefined;
  const value = legacy[key];
  return typeof value === 'string' ? value : undefined;
};

const legacyBoolean = (value: string | undefined): boolean | undefined =>
  value === 'true' ? true : value === 'false' ? false : undefined;

const safeEndpoint = (value: string | undefined): boolean => {
  if (!value) return false;
  try {
    const endpoint = url.URL.parseURL(value.trim());
    return !!endpoint.hostname && (endpoint.protocol === 'http:' || endpoint.protocol === 'https:') &&
      !endpoint.username && !endpoint.password && !endpoint.hash && value.indexOf('#') < 0;
  } catch (_error) {
    return false;
  }
};

/**
 * Import only the allowlisted v0.1.31 WebView preferences that are absent from native storage.
 * Run after WebView history/session migration has committed and before the first native settings reload.
 */
export async function migrateNativeLegacyPreferences(context: common.UIAbilityContext,
  legacy: Record<string, string>, settingsStore: NativeSettingsController): Promise<void> {
  const store = await preferences.getPreferences(context, PREFERENCES_NAME);
  if (await store.get(MIGRATION_MARKER, false) === true) return;
  if (Object.keys(legacy).length === 0) {
    await store.put(MIGRATION_MARKER, true);
    await store.flush();
    return;
  }

  const current = await settingsStore.load(context);
  const existingKey = await settingsStore.hasStoredCredential(context);
  const existingAccount = await loadNativeAccount();
  const protectApiBinding = existingKey || !!existingAccount || current.signedOut;
  const saved = async (key: string): Promise<boolean> => await store.has(key);
  const fields = new Set<NativeManualPreference>();
  const next: NativeSettings = {
    baseUrl: current.baseUrl,
    apiKey: current.apiKey,
    model: current.model,
    protocol: current.protocol,
    credentialDraft: current.credentialDraft,
    authMode: current.authMode,
    signedOut: current.signedOut,
    locale: current.locale,
    location: current.location,
    theme: current.theme,
    chatFontSize: current.chatFontSize,
    attachmentBinding: current.attachmentBinding,
    thinking: current.thinking,
    search: current.search,
    ttsMuted: current.ttsMuted,
    speechEngine: current.speechEngine,
    speechVoice: current.speechVoice,
    migrationPromptHandled: current.migrationPromptHandled,
    desktopSidebarCollapsed: current.desktopSidebarCollapsed,
  };

  if (!await saved('locale')) {
    const locale = legacyValue(legacy, 'locale');
    if (locale === 'zh-CN' || locale === 'en-US') {
      next.locale = locale as NativeLocale;
      fields.add('locale');
    }
  }
  if (!await saved('location')) {
    const raw = legacyValue(legacy, 'location');
    if (raw !== undefined) {
      const location = restoreNativeLocation(raw);
      if (location || raw === 'null') {
        next.location = location as NativeUserLocation | null;
        fields.add('location');
      }
    }
  }
  if (!await saved('theme')) {
    const theme = legacyValue(legacy, 'theme-preference');
    if (theme === 'system' || theme === 'light' || theme === 'dark') next.theme = theme;
  }
  if (!await saved('chatFontSize')) {
    const size = Number(legacyValue(legacy, 'chat-font-size'));
    if (Number.isInteger(size) && [12, 14, 16, 18, 20, 22].includes(size)) next.chatFontSize = size;
  }
  if (!await saved('thinking')) {
    const thinking = legacyBoolean(legacyValue(legacy, 'thinking'));
    if (thinking !== undefined) next.thinking = thinking;
  }
  if (!await saved('search')) {
    const search = legacyBoolean(legacyValue(legacy, 'search'));
    if (search !== undefined) next.search = search;
  }
  if (!await saved('ttsMuted')) {
    const muted = legacyBoolean(legacyValue(legacy, 'tts-muted'));
    if (muted !== undefined) next.ttsMuted = muted;
  }
  if (!await saved('speechVoice')) {
    const voice = legacyValue(legacy, 'tts-voice');
    if (voice === 'stella' || voice === 'tide') next.speechVoice = voice;
  }
  if (!await saved('speechEngine')) {
    const engine = legacyValue(legacy, 'speech-engine');
    if (engine === 'auto' || engine === 'native' || engine === 'cloud') next.speechEngine = engine;
  }
  if (!await saved('migrationPromptHandled')) {
    const handled = legacyBoolean(legacyValue(legacy, 'migration-prompt-handled'));
    if (handled !== undefined) next.migrationPromptHandled = handled;
  }
  if (!await saved('desktopSidebarCollapsed')) {
    const collapsed = legacyBoolean(legacyValue(legacy, 'sider-collapsed'));
    if (collapsed !== undefined) next.desktopSidebarCollapsed = collapsed;
  }

  const baseUrl = legacyValue(legacy, 'api-base-url');
  const protocol = legacyValue(legacy, 'api-protocol');
  const model = legacyValue(legacy, 'api-model');
  if (!protectApiBinding) {
    if (!await saved('baseUrl') && safeEndpoint(baseUrl)) next.baseUrl = baseUrl!.trim();
    if (!await saved('protocol') && (protocol === 'openai' || protocol === 'anthropic')) next.protocol = protocol;
    if (!await saved('model') && model !== undefined && model.trim().length > 0 && model.length <= 256) {
      next.model = model.trim();
    }
  }

  const legacyAuthMode = legacyValue(legacy, 'auth-mode');
  const legacyToken = legacyValue(legacy, 'dsh-token') ?? '';
  const legacyApiKey = legacyValue(legacy, 'api-key') ?? '';
  const importAccount = !protectApiBinding && !current.signedOut && !existingAccount &&
    legacyToken.trim().length > 0 && (legacyAuthMode === 'deepseek-account' || !legacyAuthMode);
  const importApiKey = !protectApiBinding && !current.signedOut && !existingAccount && !existingKey &&
    legacyApiKey.trim().length > 0 && (legacyAuthMode === 'api-key' || (!legacyAuthMode && legacyToken.trim().length === 0)) &&
    safeEndpoint(next.baseUrl) && next.baseUrl.trim().toLowerCase().startsWith('https://') &&
    !/[\r\n]/.test(legacyApiKey);

  if (importAccount) {
    const rawLabel = legacyValue(legacy, 'dsh-account-label') ?? '';
    const account: NativeDeepSeekAccount = {
      token: legacyToken,
      label: rawLabel.trim().length > 0 && rawLabel.length <= 80 ? rawLabel.trim() : 'DeepSeek API 账号',
    };
    await saveNativeAccount(account);
    next.authMode = 'deepseek-account';
    next.signedOut = false;
  } else if (importApiKey) {
    next.apiKey = legacyApiKey;
    next.authMode = 'api-key';
    next.signedOut = false;
  } else if (!protectApiBinding && !current.signedOut && !await saved('authMode')) {
    next.authMode = legacyAuthMode === 'deepseek-account' ? 'deepseek-account' : 'api-key';
  }

  const manualPreferences: NativeManualPreference[] = Array.from(fields);
  await settingsStore.save(context, next, manualPreferences);
  await store.put(MIGRATION_MARKER, true);
  await store.flush();
}
