import type { MouseEvent } from 'react'
import { DeepSeekMigration, isNativeAndroid } from './nativeBridge.js'

const prewarmedSet = new Set<string>()

const isHttpUrl = (url: string | undefined): url is string =>
  Boolean(url && (url.startsWith('https://') || url.startsWith('http://')))

/** 在原生 Android 上优先使用 MiCT / Custom Tabs 应用内秒开外部链接 */
export const openExternalUrl = (url: string): void => {
  if (!isHttpUrl(url)) {
    return
  }
  if (isNativeAndroid()) {
    const dark = document.body.hasAttribute('data-ds-dark-theme')
    void DeepSeekMigration.openExternalUrl({ url, dark }).catch(() => {
      window.open(url, '_blank', 'noopener,noreferrer')
    })
    return
  }
  window.open(url, '_blank', 'noopener,noreferrer')
}

export const handleExternalAnchorClick = (
  event: MouseEvent<HTMLAnchorElement>,
  url: string | undefined
): void => {
  if (!isNativeAndroid() || !isHttpUrl(url)) {
    return
  }
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) {
    return
  }
  event.preventDefault()
  openExternalUrl(url)
}

/** 预热搜索引用等外部链接（Android 上调用 MiCT prepare / CustomTabs mayLaunchUrl） */
export const prewarmExternalUrls = (urls: readonly string[]): void => {
  if (!isNativeAndroid() || urls.length === 0) {
    return
  }
  const fresh: string[] = []
  for (const url of urls) {
    if (!isHttpUrl(url) || prewarmedSet.has(url)) {
      continue
    }
    if (prewarmedSet.size >= 80) {
      const oldest = prewarmedSet.values().next().value
      if (oldest) {
        prewarmedSet.delete(oldest)
      }
    }
    prewarmedSet.add(url)
    fresh.push(url)
    if (fresh.length >= 4) {
      break
    }
  }
  if (fresh.length > 0) {
    void DeepSeekMigration.prepareExternalUrls({ urls: fresh }).catch(() => {})
  }
}
