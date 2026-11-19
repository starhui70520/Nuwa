import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeDeepSeekAccount } from './NativeDeepSeekAccount';

const ACCOUNT_ALIAS = 'nuwa_native_deepseek_account';
const ASSET_NOT_FOUND = 24000002;
const FORMAT_TAG: asset.Tag = asset.Tag.DATA_LABEL_CRITICAL_1;
const MAX_SECRET_BYTES = 1024;
const encoder = new util.TextEncoder();
const decoder = util.TextDecoder.create('utf-8');

function queryAccount(): asset.AssetMap {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, encoder.encodeInto(ACCOUNT_ALIAS));
  return query;
}

export async function loadNativeAccount(): Promise<NativeDeepSeekAccount | null> {
  const query = queryAccount();
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const records = await asset.query(query);
    const secret = records[0]?.get(asset.Tag.SECRET);
    const format = records[0]?.get(FORMAT_TAG);
    if (secret instanceof Uint8Array && secret.length > 0) {
      const value = decoder.decodeToString(secret);
      if (format instanceof Uint8Array && decoder.decodeToString(format) === 'token') {
        return { token: value, label: 'DeepSeek API 账号' };
      }
      const account = JSON.parse(value) as NativeDeepSeekAccount;
      if (typeof account?.token === 'string' && account.token && typeof account.label === 'string') {
        return account;
      }
    }
    return null;
  } catch (error) {
    if ((error as BusinessError).code === ASSET_NOT_FOUND) {
      return null;
    }
    throw new Error('无法读取账号凭据');
  }
}

export async function saveNativeAccount(account: NativeDeepSeekAccount | null): Promise<void> {
  const query = queryAccount();
  if (!account) {
    try {
      await asset.remove(query);
    } catch (error) {
      if ((error as BusinessError).code !== ASSET_NOT_FOUND) {
        throw new Error('无法删除账号凭据');
      }
    }
    return;
  }
  const token = encoder.encodeInto(account.token);
  if (!token.length || token.length > MAX_SECRET_BYTES) {
    throw new Error('账号令牌长度超出系统安全存储限制');
  }
  const record = encoder.encodeInto(JSON.stringify(account));
  const tokenOnly = record.length > MAX_SECRET_BYTES;
  const attributes: asset.AssetMap = new Map();
  attributes.set(asset.Tag.SECRET, tokenOnly ? token : record);
  attributes.set(FORMAT_TAG, encoder.encodeInto(tokenOnly ? 'token' : 'record'));
  try {
    await asset.update(query, attributes);
  } catch (error) {
    if ((error as BusinessError).code !== ASSET_NOT_FOUND) {
      throw new Error('无法更新账号凭据');
    }
    attributes.set(asset.Tag.ALIAS, encoder.encodeInto(ACCOUNT_ALIAS));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    await asset.add(attributes);
  }
}
