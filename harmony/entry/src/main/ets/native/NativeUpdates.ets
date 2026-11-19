import { preferences } from '@kit.ArkData';
import { bundleManager, common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';

const STORE_NAME = 'nuwa_native_updates';
export const UPDATE_POLL_MS: number = 30 * 60 * 1000;
export const UPDATE_RESUME_MS: number = 10 * 60 * 1000;
const UPDATE_SNOOZE_MS = 6 * 60 * 60 * 1000;

const PORTAL_BASE_URL: string = 'https://dl.rankchord.com';
const PORTAL_RELEASES_URL: string = 'https://dl.rankchord.com/api/releases';

interface PortalReleaseItem {
  id?: string;
  platform?: string;
  version?: string;
  versionCode?: number;
  changelog?: string;
  createdAt?: string;
  published?: boolean;
}

interface PortalHarmonyConfig {
  status?: string;
  url?: string;
  note?: string;
}

interface PortalLatest {
  harmony?: PortalReleaseItem | null;
}

interface PortalReleasesResponse {
  latest?: PortalLatest;
  releases?: PortalReleaseItem[];
  harmony?: PortalHarmonyConfig;
}

export interface NativeReleaseHistoryItem {
  id: string;
  version: string;
  versionCode: number;
  changelog: string;
  createdAt: string;
}

export interface NativeUpdateCheck {
  currentVersion: string;
  currentVersionCode: number;
  latestVersion: string;
  latestVersionCode: number;
  hasUpdate: boolean;
  notes: string;
  releaseUrl: string;
  downloadUrl: string | null;
  appGalleryUrl: string | null;
  appGalleryNote: string;
}

interface NativeBundleVersion {
  versionName: string;
  versionCode: number;
}

function isRecord(value: Object | null): boolean {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function normalizeVersion(value: string): string {
  return value.trim().replace(/^v/i, '');
}

function compareVersions(left: string, right: string): number {
  const leftParts = normalizeVersion(left).split(/[^0-9]+/).filter((part: string): boolean => part.length > 0);
  const rightParts = normalizeVersion(right).split(/[^0-9]+/).filter((part: string): boolean => part.length > 0);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index++) {
    const leftValue = index < leftParts.length ? Number.parseInt(leftParts[index], 10) : 0;
    const rightValue = index < rightParts.length ? Number.parseInt(rightParts[index], 10) : 0;
    if (leftValue > rightValue) {
      return 1;
    }
    if (leftValue < rightValue) {
      return -1;
    }
  }
  return 0;
}

async function getBundleVersion(): Promise<NativeBundleVersion> {
  const info = await bundleManager.getBundleInfoForSelf(
    bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
  );
  return { versionName: info.versionName, versionCode: info.versionCode };
}

export async function getNativeCurrentVersion(): Promise<string> {
  const info = await getBundleVersion();
  const version = info.versionName.trim();
  if (!version) {
    throw new Error('无法读取应用版本号');
  }
  return version;
}

async function fetchPortalReleases(): Promise<PortalReleasesResponse> {
  const request = http.createHttp();
  try {
    const response = await request.request(PORTAL_RELEASES_URL, {
      method: http.RequestMethod.GET,
      header: { Accept: 'application/json' },
      usingCache: false,
      connectTimeout: 10000,
      readTimeout: 15000,
      expectDataType: http.HttpDataType.STRING,
      maxRedirects: 0,
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(`发布服务请求失败 (HTTP ${response.responseCode})`);
    }
    const raw = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
    const parsed = JSON.parse(raw) as Object;
    if (!isRecord(parsed)) {
      throw new Error('发布服务返回的数据无效');
    }
    return parsed as PortalReleasesResponse;
  } finally {
    request.destroy();
  }
}

function isPublishedHarmony(release: PortalReleaseItem | null | undefined): boolean {
  return !!release && release.platform === 'harmony' && release.published !== false &&
    typeof release.version === 'string' && release.version.trim().length > 0;
}

function latestHarmony(data: PortalReleasesResponse): PortalReleaseItem | null {
  const latest = data.latest?.harmony;
  if (isPublishedHarmony(latest)) {
    return latest ?? null;
  }
  const releases = data.releases ?? [];
  for (let index = 0; index < releases.length; index++) {
    if (isPublishedHarmony(releases[index])) {
      return releases[index];
    }
  }
  return null;
}

function appGalleryLink(config: PortalHarmonyConfig | undefined): string | null {
  if (!config || config.status !== 'appgallery' || typeof config.url !== 'string') {
    return null;
  }
  try {
    const parsed = url.URL.parseURL(config.url.trim());
    const host = parsed.hostname.toLowerCase();
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      (host !== 'appgallery.huawei.com' && host !== 'appgallery.cloud.huawei.com')) {
      return null;
    }
    return parsed.href;
  } catch {
    return null;
  }
}

export async function fetchNativeReleaseHistory(): Promise<NativeReleaseHistoryItem[]> {
  const data = await fetchPortalReleases();
  const releases = data.releases ?? [];
  const result: NativeReleaseHistoryItem[] = [];
  for (let index = 0; index < releases.length; index++) {
    const item = releases[index];
    if (!isPublishedHarmony(item)) {
      continue;
    }
    result.push({
      id: item.id || `${item.version}-${index}`,
      version: normalizeVersion(item.version || ''),
      versionCode: typeof item.versionCode === 'number' && Number.isFinite(item.versionCode) ? item.versionCode : 0,
      changelog: (item.changelog || '').trim(),
      createdAt: item.createdAt || '',
    });
  }
  return result;
}

export async function checkNativeUpdate(): Promise<NativeUpdateCheck> {
  const bundle = await getBundleVersion();
  const data = await fetchPortalReleases();
  const currentVersion = normalizeVersion(bundle.versionName);
  const latest = latestHarmony(data);
  const appGallery = data.harmony;
  const storeUrl = appGalleryLink(appGallery);
  const storeNote = storeUrl ? (appGallery?.note || '').trim() : '';
  if (!latest) {
    return {
      currentVersion: currentVersion,
      currentVersionCode: bundle.versionCode,
      latestVersion: currentVersion,
      latestVersionCode: bundle.versionCode,
      hasUpdate: false,
      notes: '',
      releaseUrl: PORTAL_BASE_URL,
      downloadUrl: null,
      appGalleryUrl: storeUrl,
      appGalleryNote: storeNote,
    };
  }
  const latestVersion = normalizeVersion(latest.version || currentVersion);
  const latestVersionCode = typeof latest.versionCode === 'number' && Number.isFinite(latest.versionCode)
    ? latest.versionCode : 0;
  const hasUpdate = latestVersionCode > 0 && bundle.versionCode > 0
    ? latestVersionCode > bundle.versionCode
    : compareVersions(latestVersion, currentVersion) > 0;
  const downloadUrl = hasUpdate && latest.id
    ? `${PORTAL_RELEASES_URL}/${encodeURIComponent(latest.id)}/download`
    : null;
  return {
    currentVersion: currentVersion,
    currentVersionCode: bundle.versionCode,
    latestVersion: latestVersion,
    latestVersionCode: latestVersionCode,
    hasUpdate: hasUpdate,
    notes: (latest.changelog || '').trim(),
    releaseUrl: PORTAL_BASE_URL,
    downloadUrl: downloadUrl,
    appGalleryUrl: storeUrl,
    appGalleryNote: storeNote,
  };
}

export interface NativeUpdatePreferences {
  checkAt: number;
  dismissedAt: number;
  dismissedVersion: string;
}

export class NativeUpdateSchedule {
  async load(context: common.UIAbilityContext): Promise<NativeUpdatePreferences> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    return {
      checkAt: await store.get('checkAt', 0) as number,
      dismissedAt: await store.get('dismissedAt', 0) as number,
      dismissedVersion: await store.get('dismissedVersion', '') as string,
    };
  }

  async checked(context: common.UIAbilityContext, checkAt: number): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.put('checkAt', checkAt);
    await store.flush();
  }

  async dismissed(context: common.UIAbilityContext, version: string, at: number): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.put('dismissedVersion', version);
    await store.put('dismissedAt', at);
    await store.flush();
  }
}

export function isUpdateSnoozed(update: NativeUpdateCheck, state: NativeUpdatePreferences, now: number): boolean {
  return state.dismissedVersion === update.latestVersion && now - state.dismissedAt < UPDATE_SNOOZE_MS;
}
