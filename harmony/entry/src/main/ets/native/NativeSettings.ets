import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { defaultNativeLocale, NativeLocale, NativeUserLocation, restoreNativeLocation } from './NativeLocation';
import { HarmonySpeechEngine, HarmonySpeechVoice } from '../speech/HarmonySpeechOptions';

export type NativeApiProtocol = 'openai' | 'anthropic';
export type NativeAuthMode = 'api-key' | 'deepseek-account';
export type NativeTheme = 'system' | 'light' | 'dark';
export type NativeManualPreference = 'locale' | 'location';
export const NATIVE_CHAT_FONT_SIZES: number[] = [12, 14, 16, 18, 20, 22];

export interface NativeApiCredentialDraft {
  baseUrl: string;
  model: string;
  protocol: NativeApiProtocol;
}

/** User-configurable settings. API credentials are held separately in Asset Store Kit. */
export interface NativeSettings {
  baseUrl: string;
  apiKey: string;
  model: string;
  protocol: NativeApiProtocol;
  credentialDraft?: NativeApiCredentialDraft | null;
  authMode: NativeAuthMode;
  signedOut: boolean;
  locale: NativeLocale;
  location: NativeUserLocation | null;
  theme: NativeTheme;
  chatFontSize: number;
  attachmentBinding: string;
  thinking: boolean;
  search: boolean;
  ttsMuted: boolean;
  speechEngine: HarmonySpeechEngine;
  speechVoice: HarmonySpeechVoice;
  hapticFeedback: boolean;
  migrationPromptHandled: boolean;
  desktopSidebarCollapsed: boolean;
}

const PREFERENCES_NAME: string = 'nuwa_native_settings';
const API_KEY_ALIAS: string = 'nuwa_native_api_key';
const SECONDARY_API_KEY_ALIAS: string = 'nuwa_native_api_key_secondary';
const API_KEY_SLOT_PREFERENCE: string = 'apiKeySecondary';
const DEFAULT_BASE_URL: string = 'https://api.deepseek.com';
const DEFAULT_MODEL: string = 'deepseek-chat';
const CREDENTIAL_BINDING_TAG: asset.Tag = asset.Tag.DATA_LABEL_NORMAL_1;

interface StoredCredential {
  apiKey: string;
  binding: string;
}

let serializedWrites: Promise<void> = Promise.resolve();

const encode = (value: string): Uint8Array => {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(value);
};

const decode = (value: Uint8Array): string =>
  util.TextDecoder.create('utf-8').decodeToString(value);

const bindingFor = (baseUrl: string, protocol: NativeApiProtocol): string =>
  JSON.stringify({ baseUrl: baseUrl.trim(), protocol });

const parseCredentialDraft = (value: string): NativeApiCredentialDraft | null => {
  try {
    const draft = JSON.parse(value) as NativeApiCredentialDraft;
    return typeof draft.baseUrl === 'string' && typeof draft.model === 'string' &&
      (draft.protocol === 'openai' || draft.protocol === 'anthropic') ? draft : null;
  } catch {
    return null;
  }
};

const writeCredentialDraft = async (store: preferences.Preferences, draft: NativeApiCredentialDraft | null): Promise<void> => {
  await store.put('credentialDraft', draft ? JSON.stringify(draft) : '');
};

const keyAlias = (secondary: boolean): string => secondary ? SECONDARY_API_KEY_ALIAS : API_KEY_ALIAS;

const readCredential = async (secondary: boolean): Promise<StoredCredential | null> => {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, encode(keyAlias(secondary)));
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  let matches: Array<asset.AssetMap>;
  try {
    matches = await asset.query(query);
  } catch (error) {
    const code = (error as BusinessError).code;
    if (code === 24000002) {
      return null;
    }
    throw new Error((error as BusinessError).message ?? '无法读取安全凭据');
  }
  if (matches.length === 0) {
    return null;
  }
  const secret = matches[0].get(asset.Tag.SECRET);
  const binding = matches[0].get(CREDENTIAL_BINDING_TAG) ?? matches[0].get(asset.Tag.DATA_LABEL_CRITICAL_1);
  if (!(secret instanceof Uint8Array) || !(binding instanceof Uint8Array)) {
    return null;
  }
  return { apiKey: decode(secret), binding: decode(binding) };
};

const writeApiKey = async (apiKey: string, binding: string, secondary: boolean): Promise<void> => {
  const alias = encode(keyAlias(secondary));
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, alias);
  if (!apiKey) {
    try {
      await asset.remove(query);
    } catch (error) {
      if ((error as BusinessError).code !== 24000002) {
        throw new Error((error as BusinessError).message ?? '无法删除安全凭据');
      }
    }
    return;
  }

  const attributes: asset.AssetMap = new Map();
  attributes.set(asset.Tag.SECRET, encode(apiKey));
  attributes.set(CREDENTIAL_BINDING_TAG, encode(binding));
  try {
    await asset.update(query, attributes);
  } catch (error) {
    // A missing alias is the normal first-save path; adding stores it encrypted.
    if ((error as BusinessError).code !== 24000002) {
      throw new Error((error as BusinessError).message ?? '无法更新安全凭据');
    }
    attributes.set(asset.Tag.ALIAS, alias);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    await asset.add(attributes);
  }
};

const clearStoredApiKeys = async (): Promise<void> => {
  await writeApiKey('', '', false).catch(() => {});
  await writeApiKey('', '', true).catch(() => {});
};

/** Persists non-secret preferences using Preferences and the API key using encrypted Asset Store Kit. */
export class NativeSettingsController {
  async load(context: common.UIAbilityContext): Promise<NativeSettings> {
    await serializedWrites;
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const signedOut = await store.get('signedOut', false) === true;
    const secondary = await store.get(API_KEY_SLOT_PREFERENCE, false) === true;
    const credential = signedOut ? null : await readCredential(secondary);
    if (signedOut) await clearStoredApiKeys();
    const baseUrl = await store.get('baseUrl', DEFAULT_BASE_URL) as string;
    const model = await store.get('model', DEFAULT_MODEL) as string;
    const protocol = await store.get('protocol', 'openai') as string;
    const authMode = await store.get('authMode', 'api-key') as string;
    const locale = await store.get('locale', '') as string;
    const location = restoreNativeLocation(await store.get('location', 'null') as string);
    const theme = await store.get('theme', 'system') as string;
    const chatFontSize = await store.get('chatFontSize', 16) as number;
    const binding = await store.get('attachmentBinding', '') as string;
    const thinking = await store.get('thinking', false) as boolean;
    const search = await store.get('search', false) as boolean;
    const ttsMuted = await store.get('ttsMuted', true) as boolean;
    const speechEngine = await store.get('speechEngine', 'auto') as string;
    const speechVoice = await store.get('speechVoice', 'stella') as string;
    const hapticFeedback = await store.get('hapticFeedback', true) as boolean;
    const migrationPromptHandled = await store.get('migrationPromptHandled', false) as boolean;
    const desktopSidebarCollapsed = await store.get('desktopSidebarCollapsed', false) as boolean;
    const credentialDraft = signedOut ? null : parseCredentialDraft(await store.get('credentialDraft', '') as string);
    const resolvedProtocol: NativeApiProtocol = protocol === 'anthropic' ? 'anthropic' : 'openai';
    const apiKey = credential && credential.binding === bindingFor(baseUrl, resolvedProtocol)
      ? credential.apiKey : '';
    return {
      baseUrl,
      apiKey,
      model,
      protocol: resolvedProtocol,
      credentialDraft,
      authMode: authMode === 'deepseek-account' ? 'deepseek-account' : 'api-key',
      signedOut,
      locale: locale === 'zh-CN' || locale === 'en-US' ? locale : defaultNativeLocale(),
      location,
      theme: theme === 'dark' || theme === 'light' ? theme : 'system',
      chatFontSize: NATIVE_CHAT_FONT_SIZES.includes(chatFontSize) ? chatFontSize : 16,
      attachmentBinding: binding || util.generateRandomUUID(true),
      thinking,
      search,
      ttsMuted,
      speechEngine: speechEngine === 'native' || speechEngine === 'cloud' ? speechEngine : 'auto',
      speechVoice: speechVoice === 'tide' ? 'tide' : 'stella',
      hapticFeedback,
      migrationPromptHandled,
      desktopSidebarCollapsed,
    };
  }

  /** Commit the disconnected state before removing credentials from separate stores. */
  async markSignedOut(context: common.UIAbilityContext): Promise<void> {
    const operation = serializedWrites.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      try {
        await store.put('signedOut', true);
        await writeCredentialDraft(store, null);
        await store.flush();
      } catch (error) {
        await preferences.removePreferencesFromCache(context, PREFERENCES_NAME).catch(() => {});
        throw error as Error;
      }
      await clearStoredApiKeys();
    });
    serializedWrites = operation.catch(() => {});
    return operation;
  }

  async saveCredentialDraft(context: common.UIAbilityContext, draft: NativeApiCredentialDraft | null): Promise<void> {
    const operation = serializedWrites.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      await writeCredentialDraft(store, draft);
      await store.flush();
    });
    serializedWrites = operation.catch(() => {});
    return operation;
  }

  async save(context: common.UIAbilityContext, settings: NativeSettings,
    manualPreference?: NativeManualPreference | NativeManualPreference[], verifiedCredential: boolean = false): Promise<void> {
    const operation = serializedWrites.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const currentSecondary = await store.get(API_KEY_SLOT_PREFERENCE, false) === true;
      const credential = await readCredential(currentSecondary);
      const nextBinding = bindingFor(settings.baseUrl, settings.protocol);
      // Only verification can bind an unchanged key to new endpoint settings.
      const key = settings.signedOut ? '' : settings.apiKey;
      const replaceKey = key ? !credential || credential.apiKey !== key ||
        (verifiedCredential && credential.binding !== nextBinding) : credential !== null;
      const nextSecondary = replaceKey ? !currentSecondary : currentSecondary;
      // Keep the prior key usable until preferences persist the slot and its endpoint together.
      if (replaceKey) await writeApiKey(key, nextBinding, nextSecondary);
      try {
        const writes = [
          store.put(API_KEY_SLOT_PREFERENCE, nextSecondary),
          store.put('baseUrl', settings.baseUrl),
          store.put('model', settings.model),
          store.put('protocol', settings.protocol),
          store.put('authMode', settings.authMode),
          store.put('signedOut', settings.signedOut),
          store.put('theme', settings.theme),
          store.put('chatFontSize', settings.chatFontSize),
          store.put('attachmentBinding', settings.attachmentBinding),
          store.put('thinking', settings.thinking),
          store.put('search', settings.search),
          store.put('ttsMuted', settings.ttsMuted),
          store.put('speechEngine', settings.speechEngine),
          store.put('speechVoice', settings.speechVoice),
          store.put('hapticFeedback', settings.hapticFeedback),
          store.put('migrationPromptHandled', settings.migrationPromptHandled),
          store.put('desktopSidebarCollapsed', settings.desktopSidebarCollapsed),
        ];
        if (verifiedCredential || settings.signedOut) {
          writes.push(writeCredentialDraft(store, null));
        }
        // Changing other settings must preserve both system defaults and the saved location hierarchy.
        const manualPreferences: NativeManualPreference[] = manualPreference === undefined ? [] :
          Array.isArray(manualPreference) ? manualPreference : [manualPreference];
        if (manualPreferences.includes('locale')) {
          writes.push(store.put('locale', settings.locale));
        }
        if (manualPreferences.includes('location')) {
          writes.push(store.put('location', JSON.stringify(settings.location)));
        }
        await Promise.all(writes);
        await store.flush();
      } catch (error) {
        // A failed flush can leave a pending key. Keep both slots until a successful save.
        await preferences.removePreferencesFromCache(context, PREFERENCES_NAME).catch(() => {});
        throw error as Error;
      }
      if (!key && (replaceKey || verifiedCredential || settings.signedOut)) {
        await clearStoredApiKeys();
      } else if (replaceKey || verifiedCredential) {
        await writeApiKey('', '', !nextSecondary).catch(() => {});
      }
    });
    serializedWrites = operation.catch(() => {});
    return operation;
  }

  /** Detect even a stored credential whose endpoint binding no longer matches current preferences. */
  async hasStoredCredential(context: common.UIAbilityContext): Promise<boolean> {
    await serializedWrites;
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    if (await store.get('signedOut', false) === true) return false;
    const secondary = await store.get(API_KEY_SLOT_PREFERENCE, false) === true;
    return (await readCredential(secondary)) !== null;
  }
}
