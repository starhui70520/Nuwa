/**
 * 设备性能档位与低内存事件管理（覆盖 Android 7 / 旧版 WebView 到最新旗舰机型）。
 * 低性能设备主动降低并发缓存、流式重绘频率、大代码块实时高亮与重型视觉特效，
 * 避免低内存机型在导入大备份或长对话流式生成时卡顿、掉帧或 OOM。
 */

type PerfTier = 'low' | 'normal'

const LOW_WEBVIEW_MAX_MAJOR = 114
const LOW_RAM_GB_THRESHOLD = 4
const LOW_CORES_THRESHOLD = 4

let cachedUaLowPerf: boolean | null = null
let lowMemoryFlag = false

const detectUaAndHardwareLowPerf = (): boolean => {
  if (cachedUaLowPerf !== null) {
    return cachedUaLowPerf
  }
  if (typeof navigator === 'undefined') {
    cachedUaLowPerf = false
    return false
  }
  const nav = navigator as Navigator & { deviceMemory?: number }
  if (typeof nav.deviceMemory === 'number' && nav.deviceMemory > 0 && nav.deviceMemory <= LOW_RAM_GB_THRESHOLD) {
    cachedUaLowPerf = true
    return true
  }
  if (typeof nav.hardwareConcurrency === 'number' && nav.hardwareConcurrency > 0 && nav.hardwareConcurrency <= LOW_CORES_THRESHOLD) {
    cachedUaLowPerf = true
    return true
  }
  const ua = nav.userAgent || ''
  if (/Android\s+([5-9]|10)\b/i.test(ua)) {
    cachedUaLowPerf = true
    return true
  }
  const chromeMatch = /Chrome\/(\d+)\./.exec(ua)
  if (chromeMatch) {
    const major = Number.parseInt(chromeMatch[1], 10)
    if (Number.isFinite(major) && major > 0 && major <= LOW_WEBVIEW_MAX_MAJOR) {
      cachedUaLowPerf = true
      return true
    }
  }
  cachedUaLowPerf = false
  return false
}

const syncBodyPerfAttr = () => {
  if (typeof document === 'undefined' || !document.body) {
    return
  }
  if (detectUaAndHardwareLowPerf() || lowMemoryFlag) {
    if (!document.body.hasAttribute('data-perf-tier')) {
      document.body.setAttribute('data-perf-tier', 'low')
    }
    if (!document.body.hasAttribute('data-low-webview')) {
      document.body.setAttribute('data-low-webview', 'true')
    }
  }
}

if (typeof window !== 'undefined') {
  if (typeof document !== 'undefined') {
    if (document.body) {
      syncBodyPerfAttr()
    } else {
      document.addEventListener('DOMContentLoaded', syncBodyPerfAttr, { once: true })
    }
  }
  window.addEventListener('dsapp:low-memory', (event) => {
    const detail = (event as CustomEvent<{ foreground?: boolean }>).detail
    if (detail?.foreground !== false) {
      lowMemoryFlag = true
      if (typeof document !== 'undefined' && document.body) {
        document.body.setAttribute('data-perf-tier', 'low')
        document.body.setAttribute('data-low-webview', 'true')
      }
    }
  })
}

/** 当前是否处于低性能 / 低内存档位（动态读取原生注入的 body 属性与运行时内存信号）。 */
export const isLowPerfDevice = (): boolean => {
  if (lowMemoryFlag) {
    return true
  }
  if (typeof document !== 'undefined' && document.body) {
    if (
      document.body.getAttribute('data-perf-tier') === 'low' ||
      document.body.getAttribute('data-low-webview') === 'true'
    ) {
      return true
    }
  }
  return detectUaAndHardwareLowPerf()
}

export const getPerfTier = (): PerfTier => (isLowPerfDevice() ? 'low' : 'normal')

/** 监听原生层低内存告警（Android onTrimMemory 等），用于及时释放内存缓存。 */
export const onLowMemory = (listener: () => void): (() => void) => {
  if (typeof window === 'undefined') {
    return () => {}
  }
  window.addEventListener('dsapp:low-memory', listener)
  return () => window.removeEventListener('dsapp:low-memory', listener)
}

/** 主动让出主线程一个宏任务片，避免导入/搜索等长循环阻塞点击与滚动。 */
export const yieldToMain = (): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, 0)
  })
