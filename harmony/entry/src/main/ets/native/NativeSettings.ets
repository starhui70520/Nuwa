import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export type NativeApiProtocol = 'openai' | 'anthropic';

/** User-configurable settings. API credentials are held separately in Asset Store Kit. */
export interface NativeSettings {
  baseUrl: string;
  apiKey: string;
  model: string;
  protocol: NativeApiProtocol;
  thinking: boolean;
  search: boolean;
  ttsMuted: boolean;
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
    const thinking = await store.get('thinking', false) as boolean;
    const search = await store.get('search', false) as boolean;
    const ttsMuted = await store.get('ttsMuted', true) as boolean;
    const resolvedProtocol: NativeApiProtocol = protocol === 'anthropic' ? 'anthropic' : 'openai';
    const apiKey = credential && credential.binding === bindingFor(baseUrl, resolvedProtocol)
      ? credential.apiKey : '';
    return {
      baseUrl,
      apiKey,
      model,
      protocol: resolvedProtocol,
      thinking,
      search,
      ttsMuted,
    };
  }

  async save(context: common.UIAbilityContext, settings: NativeSettings): Promise<void> {
    const operation = serializedWrites.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, PREFERENCES_NAME);
      const credential = await readCredential();
      const nextBinding = bindingFor(settings.baseUrl, settings.protocol);

      if (!settings.apiKey) {
        await writeApiKey('', '');
      } else if (!credential || credential.apiKey !== settings.apiKey || credential.binding === nextBinding) {
        await writeApiKey(settings.apiKey, nextBinding);
      }
      // If a caller changes endpoint/protocol while retaining the same key, keep
      // the old binding. load() will hide that credential until the user enters
      // a new key for the new endpoint.
      await Promise.all([
        store.put('baseUrl', settings.baseUrl),
        store.put('model', settings.model),
        store.put('protocol', settings.protocol),
        store.put('thinking', settings.thinking),
        store.put('search', settings.search),
        store.put('ttsMuted', settings.ttsMuted),
      ]);
      await store.flush();
    });
    serializedWrites = operation.catch(() => {});
    return operation;
  }
}
