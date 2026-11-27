import type { MessageUsage } from '../api/types.js'
import { isUsingDeepSeekAccount, isUsingRankAIFree, useSettings } from '../settings.js'

type SettingsState = ReturnType<typeof useSettings.getState>

export type BillingPeriod = 'peak' | 'off-peak'
export type BillingTier = 'flash' | 'pro'

export type TierPriceRates = {
  cacheHit: number
  cacheMiss: number
  output: number
}

/**
 * DeepSeek 官方价格表（元 / 百万 tokens）：
 * - flash: deepseek-flash / deepseek-v4.1-flash（及默认档）
 * - pro:   deepseek-v4-pro
 * 空闲时段价格为高峰时段价格的一半。
 */
const PEAK_RATES: Record<BillingTier, TierPriceRates> = {
  flash: {
    cacheHit: 0.04,
    cacheMiss: 2,
    output: 8,
  },
  pro: {
    cacheHit: 0.3,
    cacheMiss: 9,
    output: 27,
  },
}

const OFF_PEAK_RATES: Record<BillingTier, TierPriceRates> = {
  flash: {
    cacheHit: 0.02,
    cacheMiss: 1,
    output: 4,
  },
  pro: {
    cacheHit: 0.15,
    cacheMiss: 4.5,
    output: 13.5,
  },
}

/** 上下文窗口上限（1M tokens） */
const CONTEXT_WINDOW_TOKENS = 1_000_000

/**
 * 预留中国法定节假日/调休工作日日历服务接口：
 * 后续接入日历服务后调用 setChinaCalendarResolver 即可实时生效。
 * 返回 'holiday' 表示法定节假日（全天空闲），'workday' 表示调休补班日（按工作日计算），null 表示走默认周末规则。
 */
export type ChinaCalendarResolver = (beijingDateKey: string) => 'holiday' | 'workday' | null

let calendarResolver: ChinaCalendarResolver | null = null

export const setChinaCalendarResolver = (resolver: ChinaCalendarResolver | null): void => {
  calendarResolver = resolver
}

/**
 * 按北京时间（UTC+8）判定指定时间戳属于高峰时段还是空闲时段：
 * 周一至周五（不含中国法定节假日）9:00-12:00、14:00-18:00 为高峰时段；
 * 其余时段（含周末及中国法定节假日全天）均为空闲时段。
 */
export const getBillingPeriod = (timestampMs: number): BillingPeriod => {
  const bj = new Date(timestampMs + 8 * 60 * 60 * 1000)
  const year = bj.getUTCFullYear()
  const month = String(bj.getUTCMonth() + 1).padStart(2, '0')
  const dayOfMonth = String(bj.getUTCDate()).padStart(2, '0')
  const dateKey = `${year}-${month}-${dayOfMonth}`

  const calendarDay = calendarResolver?.(dateKey) ?? null
  if (calendarDay === 'holiday') {
    return 'off-peak'
  }

  const weekday = bj.getUTCDay() // 0 = Sun, 6 = Sat
  const isWeekend = weekday === 0 || weekday === 6
  if (isWeekend && calendarDay !== 'workday') {
    return 'off-peak'
  }

  const hour = bj.getUTCHours()
  const isPeakHour = (hour >= 9 && hour < 12) || (hour >= 14 && hour < 18)
  return isPeakHour ? 'peak' : 'off-peak'
}

/** 根据模型名匹配价格档位：包含 pro 走 deepseek-v4-pro，其余走 deepseek-flash / deepseek-v4.1-flash */
export const resolveBillingTier = (model: string | null | undefined): BillingTier => {
  const normalized = (model ?? '').trim().toLowerCase()
  if (normalized.includes('pro')) {
    return 'pro'
  }
  return 'flash'
}

/** 当前设置是否属于支持计费估算的渠道（DeepSeek 账号 / DeepSeek 官方 API / RankAI 免费额度） */
export const isBillingSupportedSettings = (settings: SettingsState): boolean => {
  if (isUsingDeepSeekAccount(settings) || isUsingRankAIFree(settings)) {
    return true
  }
  const baseUrl = settings.apiBaseUrl.trim().toLowerCase()
  return !baseUrl || baseUrl.includes('deepseek.com')
}

/** 格式化人民币金额（去掉多余尾随 0，最多保留 8 位小数，如 0.01247408 / 0.000778 / 0） */
export const formatCny = (amount: number): string => {
  if (!Number.isFinite(amount) || amount <= 0) {
    return '0'
  }
  return amount.toFixed(8).replace(/\.?0+$/, '')
}

/** 格式化单价（如 0.02 / 0.3 / 1 / 4.5 / 27） */
export const formatUnitPrice = (price: number): string =>
  Number.isInteger(price) ? String(price) : String(price)

export type ReplyBillingEstimate = {
  tier: BillingTier
  period: BillingPeriod
  isFree: boolean
  rates: TierPriceRates
  cacheHitTokens: number
  cacheMissTokens: number
  outputTokens: number
  cacheHitCost: number
  cacheMissCost: number
  outputCost: number
  totalCost: number
  totalContextTokens: number
  contextPercent: number
}

export const calculateReplyBilling = ({
  usage,
  model,
  timestampMs,
  isFree,
}: {
  usage: MessageUsage
  model: string | null | undefined
  timestampMs: number
  isFree: boolean
}): ReplyBillingEstimate => {
  const tier = resolveBillingTier(model)
  const period = getBillingPeriod(timestampMs)
  const rates = period === 'peak' ? PEAK_RATES[tier] : OFF_PEAK_RATES[tier]

  const cacheHitTokens = Math.max(0, usage.cache_read_input_tokens || 0)
  const cacheMissTokens = Math.max(
    0,
    (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0)
  )
  const outputTokens = Math.max(0, usage.output_tokens || 0)

  const cacheHitCost = (cacheHitTokens / 1_000_000) * rates.cacheHit
  const cacheMissCost = (cacheMissTokens / 1_000_000) * rates.cacheMiss
  const outputCost = (outputTokens / 1_000_000) * rates.output
  const totalCost = cacheHitCost + cacheMissCost + outputCost

  const totalContextTokens = cacheHitTokens + cacheMissTokens + outputTokens
  const contextPercent = Math.min(100, Math.round((totalContextTokens / CONTEXT_WINDOW_TOKENS) * 100))

  return {
    tier,
    period,
    isFree,
    rates,
    cacheHitTokens,
    cacheMissTokens,
    outputTokens,
    cacheHitCost,
    cacheMissCost,
    outputCost,
    totalCost,
    totalContextTokens,
    contextPercent,
  }
}
