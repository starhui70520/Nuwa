import clsx from 'clsx'
import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  calculateReplyBilling,
  formatCny,
  formatUnitPrice,
  isBillingSupportedSettings,
  type ReplyBillingEstimate,
} from '../../services/chat/billing.js'
import type { AssistantMessage } from '../../services/chat/types.js'
import { useSettings } from '../../services/settings.js'
import { IconButton } from '../base/IconButton.js'
import { IconCoinsOutline16 } from '../base/icons.js'
import { registerModalBackHandler } from '../base/Modal.js'
import styles from './ReplyBillingModal.module.css'

const MINI_RADIUS = 5.5
const MINI_CIRCUMFERENCE = 2 * Math.PI * MINI_RADIUS

const formatInt = (value: number): string => value.toLocaleString('en-US')

const ReplyBillingDrawer = ({
  estimate,
  onClose,
}: {
  estimate: ReplyBillingEstimate
  onClose: () => void
}) => {
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  const dragStartYRef = useRef<number | null>(null)
  const [dragOffset, setDragOffset] = useState(0)

  useEffect(() => registerModalBackHandler(() => onCloseRef.current()), [])

  const periodLabel = estimate.period === 'peak' ? '高峰时段' : '空闲时段'
  const tierLabel = estimate.tier === 'pro' ? 'deepseek-v4-pro' : 'deepseek-v4.1-flash'
  const dashOffset =
    MINI_CIRCUMFERENCE * (1 - Math.min(1, Math.max(0.02, estimate.contextPercent / 100)))

  return createPortal(
    <div
      className={styles.overlay}
      role="dialog"
      aria-modal="true"
      aria-label="本轮消耗明细"
      onClick={(event) => {
        if (event.target === event.currentTarget) {
          onClose()
        }
      }}
    >
      <div
        className={clsx(styles.drawer, dragOffset > 0 && styles.drawerDragging)}
        style={dragOffset > 0 ? { transform: `translateY(${dragOffset}px)` } : undefined}
        onTouchStart={(event) => {
          if (event.touches.length === 1) {
            dragStartYRef.current = event.touches[0].clientY
          }
        }}
        onTouchMove={(event) => {
          if (dragStartYRef.current === null || event.touches.length !== 1) {
            return
          }
          const delta = event.touches[0].clientY - dragStartYRef.current
          if (delta > 0) {
            setDragOffset(delta)
          }
        }}
        onTouchEnd={() => {
          const offset = dragOffset
          dragStartYRef.current = null
          setDragOffset(0)
          if (offset > 72) {
            onClose()
          }
        }}
        onTouchCancel={() => {
          dragStartYRef.current = null
          setDragOffset(0)
        }}
      >
        <div className={styles.handleWrap} aria-hidden="true">
          <div className={styles.handle} />
        </div>

        <div className={styles.headerRow}>
          <div className={styles.titleGroup}>
            <span className={styles.titleIcon} aria-hidden="true">
              <IconCoinsOutline16 />
            </span>
            <span className={styles.titleText}>本轮消耗额度</span>
            {estimate.isFree ? <span className={styles.freeBadge}>免费</span> : null}
          </div>
          <div className={styles.totalAmount}>{formatCny(estimate.totalCost)} 元</div>
        </div>

        <div className={styles.subtitle}>
          按「{periodLabel}」价格估算 · {tierLabel}
        </div>

        <div className={styles.breakdownCard}>
          <div className={styles.section}>
            <div className={styles.sectionLeft}>
              <span className={styles.sectionTitle}>输入</span>
              <span className={styles.sectionSub}>缓存命中</span>
            </div>
            <div className={styles.sectionRight}>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>单价</span>
                <span className={styles.metricValue}>
                  {formatUnitPrice(estimate.rates.cacheHit)} 元 / 百万 tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>用量</span>
                <span className={styles.metricValue}>
                  {formatInt(estimate.cacheHitTokens)} tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>金额</span>
                <span className={styles.metricValue}>{formatCny(estimate.cacheHitCost)} 元</span>
              </div>
            </div>
          </div>

          <div className={styles.section}>
            <div className={styles.sectionLeft}>
              <span className={styles.sectionTitle}>输入</span>
              <span className={styles.sectionSub}>缓存未命中</span>
            </div>
            <div className={styles.sectionRight}>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>单价</span>
                <span className={styles.metricValue}>
                  {formatUnitPrice(estimate.rates.cacheMiss)} 元 / 百万 tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>用量</span>
                <span className={styles.metricValue}>
                  {formatInt(estimate.cacheMissTokens)} tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>金额</span>
                <span className={styles.metricValue}>{formatCny(estimate.cacheMissCost)} 元</span>
              </div>
            </div>
          </div>

          <div className={styles.section}>
            <div className={styles.sectionLeft}>
              <span className={styles.sectionTitle}>输出</span>
            </div>
            <div className={styles.sectionRight}>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>单价</span>
                <span className={styles.metricValue}>
                  {formatUnitPrice(estimate.rates.output)} 元 / 百万 tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>用量</span>
                <span className={styles.metricValue}>
                  {formatInt(estimate.outputTokens)} tokens
                </span>
              </div>
              <div className={styles.metricRow}>
                <span className={styles.metricLabel}>金额</span>
                <span className={styles.metricValue}>{formatCny(estimate.outputCost)} 元</span>
              </div>
            </div>
          </div>
        </div>

        <div className={styles.contextFooter}>
          <svg width="14" height="14" viewBox="0 0 14 14" className={styles.miniRing} aria-hidden>
            <circle
              cx="7"
              cy="7"
              r={MINI_RADIUS}
              fill="none"
              strokeWidth="1.6"
              className={styles.miniRingTrack}
            />
            <circle
              cx="7"
              cy="7"
              r={MINI_RADIUS}
              fill="none"
              strokeWidth="1.6"
              strokeDasharray={MINI_CIRCUMFERENCE}
              strokeDashoffset={dashOffset}
              strokeLinecap="round"
              className={styles.miniRingFill}
            />
          </svg>
          <span>截止到本轮，上下文已占用 {estimate.contextPercent}%</span>
        </div>
      </div>
    </div>,
    document.body
  )
}

/** 单条 AI 回复底部的「本轮消耗额度」按钮与底部抽屉明细 */
export const ReplyBillingButton = ({ message }: { message: AssistantMessage }) => {
  const [open, setOpen] = useState(false)
  const settings = useSettings()

  const supported = useMemo(() => {
    if (!message.usage) {
      return false
    }
    if (message.billingSource === 'rankai' || message.billingSource === 'deepseek') {
      return true
    }
    return isBillingSupportedSettings(settings)
  }, [message.usage, message.billingSource, settings])

  const estimate = useMemo(() => {
    if (!message.usage || !supported) {
      return null
    }
    // 仅明确通过 RankAI 免费额度生成的回复才显示「免费」，DeepSeek 账号/API 与历史消息均不显示
    const isFree = message.billingSource === 'rankai'
    return calculateReplyBilling({
      usage: message.usage,
      model: message.model,
      timestampMs: message.createdAt,
      isFree,
    })
  }, [message.usage, message.model, message.createdAt, message.billingSource, supported])

  if (!estimate) {
    return null
  }

  return (
    <>
      <IconButton
        icon={<IconCoinsOutline16 />}
        tooltip="本轮消耗明细"
        tooltipPlacement="bottom"
        onClick={() => setOpen(true)}
      />
      {open ? <ReplyBillingDrawer estimate={estimate} onClose={() => setOpen(false)} /> : null}
    </>
  )
}
