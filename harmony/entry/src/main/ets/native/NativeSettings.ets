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

/** User-configurable settings. API credentials are held separately in Asset Store Kit. */
export interface NativeSettings {
  baseUrl: string;
  apiKey: string;
  model: string;
  protocol: NativeApiProtocol;
  authMode: NativeAuthMode;
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
  migrationPromptHandled: boolean;
}

const PREFERENCES_NAME: string = 'nuwa_native_settings';
const API_KEY_ALIAS: string = 'nuwa_native_api_key';
const DEFAULT_BASE_URL: string = 'https://api.deepseek.com';
const DEFAULT_MODEL: string = 'deepseek-chat';
const CREDENTIAL_BINDING_TAG: asset.Tag = asset.Tag.DATA_LABEL_CRITICAL_1;

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

const readCredential = async (): Promise<StoredCredential | null> => {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, encode(API_KEY_ALIAS));
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
  const binding = matches[0].get(CREDENTIAL_BINDING_TAG);
  if (!(secret instanceof Uint8Array) || !(binding instanceof Uint8Array)) {
    return null;
  }
  return { apiKey: decode(secret), binding: decode(binding) };
};

const writeApiKey = async (apiKey: string, binding: string): Promise<void> => {
  const alias = encode(API_KEY_ALIAS);
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

/** Persists non-secret preferences using Preferences and the API key using encrypted Asset Store Kit. */
export class NativeSettingsController {
  async load(context: common.UIAbilityContext): Promise<NativeSettings> {
    await serializedWrites;
    const store = await preferences.getPreferences(context, PREFERENCES_NAME);
    const credential = await readCredential();
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
    const migrationPromptHandled = await store.get('migrationPromptHandled', false) as boolean;
    const resolvedProtocol: NativeApiProtocol = protocol === 'anthropic' ? 'anthropic' : 'openai';
    const apiKey = credential && credential.binding === bindingFor(baseUrl, resolvedProtocol)
      ? credential.apiKey : '';
    return {
      baseUrl,
      apiKey,
      model,
      protocol: resolvedProtocol,
      authMode: authMode === 'deepseek-account' ? 'deepseek-account' : 'api-key',
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
      migrationPromptHandled,
    };
  }

  async save(context: common.UIAbilityContext, settings: NativeSettings,
    manualPreference?: NativeManualPreference): Promise<void> {
    const operation = serializedWrites.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const credential = await readCredential();
      const nextBinding = bindingFor(settings.baseUrl, settings.protocol);

      if (!settings.apiKey) {
        await writeApiKey('', '');
      } else if (!credential || credential.apiKey !== settings.apiKey) {
        await writeApiKey(settings.apiKey, nextBinding);
      }
      // If a caller changes endpoint/protocol while retaining the same key, keep
      // the old binding. load() will hide that credential until the user enters
      // a new key for the new endpoint.
      const writes = [
        store.put('baseUrl', settings.baseUrl),
        store.put('model', settings.model),
        store.put('protocol', settings.protocol),
        store.put('authMode', settings.authMode),
        store.put('theme', settings.theme),
        store.put('chatFontSize', settings.chatFontSize),
        store.put('attachmentBinding', settings.attachmentBinding),
        store.put('thinking', settings.thinking),
        store.put('search', settings.search),
        store.put('ttsMuted', settings.ttsMuted),
        store.put('speechEngine', settings.speechEngine),
        store.put('speechVoice', settings.speechVoice),
        store.put('migrationPromptHandled', settings.migrationPromptHandled),
      ];
      // Changing other settings must preserve both system defaults and the saved location hierarchy.
      if (manualPreference === 'locale') {
        writes.push(store.put('locale', settings.locale));
      } else if (manualPreference === 'location') {
        writes.push(store.put('location', JSON.stringify(settings.location)));
      }
      await Promise.all(writes);
      await store.flush();
    });
    serializedWrites = operation.catch(() => {});
    return operation;
  }
}
