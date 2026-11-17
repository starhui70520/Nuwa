export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const idx = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** idx;
  return `${value.toFixed(idx === 0 ? 0 : 2)} ${units[idx]}`;
}

export function formatDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  });
}

export type DetectedOS = 'android' | 'harmony' | 'ios' | 'desktop';

export function detectClientOS(): DetectedOS {
  if (typeof navigator === 'undefined') return 'desktop';
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes('harmonyos') || ua.includes('openharmony') || ua.includes('arkweb')) {
    return 'harmony';
  }
  if (ua.includes('android')) {
    return 'android';
  }
  if (/iphone|ipad|ipod/.test(ua)) {
    return 'ios';
  }
  return 'desktop';
}

export function getPlatformLabel(platform: 'android' | 'harmony'): string {
  return platform === 'android' ? 'Android' : 'HarmonyOS';
}
