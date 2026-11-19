import { i18n, intl } from '@kit.LocalizationKit';
import { cityNames, nativeRegionNameOverride, provinceNames, regionCodes } from './NativeLocationData';

export type NativeLocale = 'zh-CN' | 'en-US';

export interface NativeUserLocation {
  region: string;
  province?: string;
  city?: string;
}

export interface NativeLocationOption {
  code: string;
  name: string;
}

const provinceOptions: NativeLocationOption[] = Object.keys(provinceNames).map<NativeLocationOption>(
  (code: string): NativeLocationOption => ({ code, name: provinceNames[code] }));
const regionSet = new Set<string>(regionCodes);
const regionOptions = new Map<NativeLocale, NativeLocationOption[]>();
const cityOptions = new Map<string, NativeLocationOption[]>();

export function usesChineseLocationPicker(): boolean {
  return i18n.System.getSystemLanguage().toLowerCase().startsWith('zh');
}

export function defaultNativeLocale(): NativeLocale {
  return usesChineseLocationPicker() ? 'zh-CN' : 'en-US';
}

function nativeRegionName(code: string, locale: NativeLocale): string {
  if (!regionSet.has(code)) {
    return '';
  }
  const override = nativeRegionNameOverride(code, locale);
  if (override) {
    return override;
  }
  try {
    return i18n.System.getDisplayCountry(code, locale, false) || code;
  } catch {
    return code;
  }
}

export function nativeProvinceOptions(): NativeLocationOption[] {
  return provinceOptions;
}

export function nativeCityOptions(province: string): NativeLocationOption[] {
  if (!provinceOptions.some((option: NativeLocationOption): boolean => option.code === province)) {
    return [];
  }
  const cached = cityOptions.get(province);
  if (cached) {
    return cached;
  }
  const cities: NativeLocationOption[] = Object.keys(cityNames)
    .filter((code: string): boolean => code.startsWith(province.slice(0, 2)))
    .map<NativeLocationOption>((code: string): NativeLocationOption => ({ code, name: cityNames[code] }));
  cityOptions.set(province, cities);
  return cities;
}

export function nativeRegionOptions(locale: NativeLocale): NativeLocationOption[] {
  const cached = regionOptions.get(locale);
  if (cached) {
    return cached;
  }
  const collator = new intl.Collator(locale);
  const options = regionCodes
    .map<NativeLocationOption>((code: string): NativeLocationOption => ({ code, name: nativeRegionName(code, locale) }))
    .sort((a: NativeLocationOption, b: NativeLocationOption): number => collator.compare(a.name, b.name));
  regionOptions.set(locale, options);
  return options;
}

export function nativeLocationName(location: NativeUserLocation | null, locale: NativeLocale): string {
  if (!location) {
    return '';
  }
  if (location.region === 'CN' && locale === 'zh-CN') {
    const province = location.province ?? '';
    const city = nativeCityOptions(province).find(
      (option: NativeLocationOption): boolean => option.code === location.city);
    return city?.name ?? provinceOptions.find(
      (option: NativeLocationOption): boolean => option.code === province)?.name ?? nativeRegionName('CN', locale);
  }
  return nativeRegionName(location.region, locale);
}

export function restoreNativeLocation(serialized: string): NativeUserLocation | null {
  let location: NativeUserLocation | null;
  try {
    location = JSON.parse(serialized) as NativeUserLocation | null;
  } catch {
    return null;
  }
  if (!location || !regionSet.has(location.region)) {
    return null;
  }
  const province = location.province;
  const city = location.city;
  if (location.region === 'CN' && (
    (province !== undefined && !provinceOptions.some(
      (option: NativeLocationOption): boolean => option.code === province)) ||
    (city !== undefined && !nativeCityOptions(province ?? '').some(
      (option: NativeLocationOption): boolean => option.code === city))
  )) {
    return null;
  }
  if (!usesChineseLocationPicker()) {
    return { region: location.region };
  }
  if (location.region !== 'CN' || !province) {
    return null;
  }
  return city ? { region: 'CN', province, city } : { region: 'CN', province };
}

export function createNativeLatestReminder(locale: NativeLocale, location: NativeUserLocation | null,
  now: Date = new Date()): string {
  const date = [
    String(now.getFullYear()).padStart(4, '0'),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
  ].join('-');
  const weekday = new intl.DateTimeFormat(locale, { weekday: 'long' }).format(now);
  // Match the five fields expected by DeepSeek's chat protocol.
  return [date, weekday, nativeLocationName(location, locale), 'Web', locale === 'zh-CN' ? '中文' : 'English'].join(',');
}
