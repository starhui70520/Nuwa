import { AbilityConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';

// 6GB 及以下物理内存（内核保留后 MemTotal 约 5.5-6.2GB）纳入低内存优化档位。
const LOW_TOTAL_MEM_KB: bigint = BigInt(6_500_000);
// HarmonyOS 5.0 / 早期 5.x（API 12-17）多为老架构或早期 RenderService，纳入轻量化渲染与节流档位。
const LOW_PERF_MAX_API: number = 17;

let cachedHardwareLowPerf: boolean | undefined = undefined;
let lowMemoryPressure: boolean = false;
const lowMemoryListeners = new Set<() => void>();

function detectHardwareLowPerf(): boolean {
  if (cachedHardwareLowPerf !== undefined) {
    return cachedHardwareLowPerf;
  }
  try {
    if (deviceInfo.sdkApiVersion <= LOW_PERF_MAX_API) {
      cachedHardwareLowPerf = true;
      return true;
    }
  } catch {
    // 无法读取 API 版本时继续尝试内存检测。
  }
  try {
    const info = hidebug.getSystemMemInfo();
    if (info && info.totalMem > BigInt(0) && info.totalMem <= LOW_TOTAL_MEM_KB) {
      cachedHardwareLowPerf = true;
      return true;
    }
  } catch {
    // 部分模拟器或受限环境可能不支持 getSystemMemInfo。
  }
  cachedHardwareLowPerf = false;
  return false;
}

/** 当前设备是否处于低性能 / 低内存档位（HarmonyOS 5-7 通用）。 */
export function isHarmonyLowPerfDevice(): boolean {
  return lowMemoryPressure || detectHardwareLowPerf();
}

/** 接收系统 UIAbility.onMemoryLevel 回调，触发全局缓存回收并在内存紧缺时降档。 */
export function notifyHarmonyMemoryLevel(level: AbilityConstant.MemoryLevel): void {
  if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW ||
    level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL) {
    lowMemoryPressure = true;
  }
  lowMemoryListeners.forEach((listener: () => void): void => {
    try {
      listener();
    } catch {
      // 单个缓存清理失败不影响其余清理器执行。
    }
  });
}

/** 订阅鸿蒙低内存告警事件，返回取消订阅函数。 */
export function onHarmonyLowMemory(listener: () => void): () => void {
  lowMemoryListeners.add(listener);
  return (): void => {
    lowMemoryListeners.delete(listener);
  };
}

/** 主动让出一个宏任务时间片，避免导入/归档/搜索长循环阻塞主线程帧调度。 */
export function yieldNativeTurn(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}
