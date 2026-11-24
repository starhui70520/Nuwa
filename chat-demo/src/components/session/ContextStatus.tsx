import clsx from 'clsx'
import { memo, useMemo, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { getVisibleMessages } from '../../services/chat/branches.js'
import {
  inspectContextStats,
  PROTECTED_TAIL_ROUNDS,
} from '../../services/chat/compaction.js'
import {
  compactSession,
  deleteCompactionSpan,
  stopCompaction,
  updateCompactionSummary,
  useChatStore,
} from '../../services/chat/store.js'
import type { CompactionSpan, Session } from '../../services/chat/types.js'
import { Modal } from '../base/Modal.js'
import { showToast } from '../base/toastState.js'
import { ensureApiKey } from '../settings/settingsDialogState.js'
import styles from './ContextStatus.module.css'

const formatTokens = (tokens: number): string => {
  if (tokens >= 1_000_000) {
    return `${(tokens / 1_000_000).toFixed(2)}M`
  }
  if (tokens >= 1000) {
    return `${(tokens / 1000).toFixed(1)}k`
  }
  return String(tokens)
}

const RING_RADIUS = 7.5
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS
/** 进度环与进度条对应的满载上下文刻度（DeepSeek 1M 窗口） */
const DISPLAY_CONTEXT_WINDOW_TOKENS = 1_000_000

const getPressureLevel = (pressure: number): 'green' | 'yellow' | 'orange' | 'red' => {
  if (pressure >= 0.9) {
    return 'red'
  }
  if (pressure >= 0.75) {
    return 'orange'
  }
  if (pressure >= 0.5) {
    return 'yellow'
  }
  return 'green'
}

const MemoryListItem = ({
  sessionId,
  span,
}: {
  sessionId: string
  span: CompactionSpan
}) => {
  const t = useTranslate()
  const [expanded, setExpanded] = useState(false)
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(span.summary)

  return (
    <div className={styles.memoryItem}>
      <button
        type="button"
        className={styles.memoryHeader}
        aria-expanded={expanded}
        onClick={() => {
          setExpanded((prev) => !prev)
          if (expanded) {
            setEditing(false)
          }
        }}
      >
        <span className={styles.memoryTitleWrap}>
          <span className={styles.memoryTitle}>{span.title}</span>
          {span.editedByUser ? (
            <span className={styles.editedDot} title={t('compactMemoryEditedBadge')} />
          ) : null}
        </span>
        <span className={styles.memoryMeta}>
          {expanded ? t('compactMemoryCollapse') : t('compactMemoryExpand')}
        </span>
      </button>

      {expanded ? (
        <div className={styles.memoryBody}>
          {span.keywords && span.keywords.length > 0 ? (
            <div className={styles.keywordsRow}>
              {span.keywords.map((kw) => (
                <span key={kw} className={styles.keywordChip}>
                  {kw}
                </span>
              ))}
            </div>
          ) : null}

          {editing ? (
            <textarea
              className={styles.editor}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
            />
          ) : (
            <pre className={styles.summaryText}>{span.summary}</pre>
          )}

          <div className={styles.itemActions}>
            {editing ? (
              <>
                <button
                  type="button"
                  className={styles.btn}
                  onClick={() => {
                    setEditing(false)
                    setDraft(span.summary)
                  }}
                >
                  {t('compactMemoryCancel')}
                </button>
                <button
                  type="button"
                  className={clsx(styles.btn, styles.btnPrimary)}
                  onClick={() => {
                    const cleaned = draft.trim()
                    if (!cleaned) {
                      return
                    }
                    updateCompactionSummary(sessionId, span.id, cleaned)
                    setEditing(false)
                    showToast({ key: 'compactMemorySavedToast' })
                  }}
                >
                  {t('compactMemorySave')}
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  className={clsx(styles.btn, styles.btnGhostDanger)}
                  onClick={() => {
                    deleteCompactionSpan(sessionId, span.id)
                    showToast({ key: 'compactMemoryRestoredToast' })
                  }}
                >
                  {t('compactMemoryRestore')}
                </button>
                <button
                  type="button"
                  className={styles.btn}
                  onClick={() => {
                    setDraft(span.summary)
                    setEditing(true)
                  }}
                >
                  {t('compactMemoryEdit')}
                </button>
              </>
            )}
          </div>
        </div>
      ) : null}
    </div>
  )
}

/**
 * 嵌在右上角胶囊内的极简四色环形进度按钮 + 点击展开的「上下文记忆」面板。
 */
export const ContextStatus = memo(function ContextStatus({
  session,
  streaming,
}: {
  session: Session
  streaming: boolean
}) {
  const t = useTranslate()
  const [open, setOpen] = useState(false)
  const compactProgress = useChatStore((state) => state.compacting[session.id])
  const compacting = Boolean(compactProgress)
  const importingHistory = useChatStore((state) => state.importingHistory)

  const stats = useMemo(() => {
    const visible = getVisibleMessages(session)
    const base = inspectContextStats(visible, session.compactions)
    const compactedRounds = base.activeCompactions.reduce(
      (sum, item) => sum + item.span.coveredRounds,
      0
    )
    const pressure = Math.min(1, base.effectiveTokens / DISPLAY_CONTEXT_WINDOW_TOKENS)
    return {
      ...base,
      compactedRounds,
      pressure,
    }
  }, [session])

  if (stats.totalRounds < 2 && stats.activeCompactions.length === 0 && !compacting) {
    return null
  }

  const level = getPressureLevel(stats.pressure)
  const ringLevelClass =
    level === 'red'
      ? styles.levelRed
      : level === 'orange'
        ? styles.levelOrange
        : level === 'yellow'
          ? styles.levelYellow
          : styles.levelGreen
  const barLevelClass =
    level === 'red'
      ? styles.barRed
      : level === 'orange'
        ? styles.barOrange
        : level === 'yellow'
          ? styles.barYellow
          : styles.barGreen

  const dashOffset = compacting
    ? RING_CIRCUMFERENCE * 0.65
    : RING_CIRCUMFERENCE * (1 - Math.max(0.08, stats.pressure))

  return (
    <>
      <button
        type="button"
        className={styles.trigger}
        aria-label={t('contextStatusModalTitle')}
        title={t('contextStatusCurrentTokens', { tokens: formatTokens(stats.effectiveTokens) })}
        onClick={() => setOpen(true)}
      >
        <svg
          width="20"
          height="20"
          viewBox="0 0 20 20"
          className={clsx(styles.ring, compacting && styles.ringSpinning)}
          aria-hidden
        >
          <circle
            cx="10"
            cy="10"
            r={RING_RADIUS}
            fill="none"
            strokeWidth="2.4"
            className={styles.ringTrack}
          />
          <circle
            cx="10"
            cy="10"
            r={RING_RADIUS}
            fill="none"
            strokeWidth="2.4"
            strokeDasharray={RING_CIRCUMFERENCE}
            strokeDashoffset={dashOffset}
            strokeLinecap="round"
            className={clsx(styles.ringFill, ringLevelClass)}
          />
        </svg>
      </button>

      {open ? (
        <Modal
          title={t('contextStatusModalTitle')}
          closable
          className={styles.modal}
          mainClassName={styles.modalMain}
          onClose={() => setOpen(false)}
          footer={
            <div className={styles.modalFooter}>
              <span className={styles.footerHint}>
                {compactProgress
                  ? compactProgress.total > 1
                    ? t('compactMemoryProgress', {
                        done: compactProgress.done,
                        total: compactProgress.total,
                      })
                    : t('compactMemoryRunning')
                  : stats.canManualCompact
                    ? t('contextStatusAutoHint')
                    : t('contextStatusUpToDate')}
              </span>
              {compacting ? (
                <button
                  type="button"
                  className={clsx(styles.btn, styles.btnGhostDanger)}
                  onClick={() => stopCompaction(session.id)}
                >
                  {t('compactMemoryStopButton')}
                </button>
              ) : (
                <button
                  type="button"
                  className={clsx(styles.btn, styles.btnPrimary)}
                  disabled={streaming || importingHistory || !stats.canManualCompact}
                  onClick={() => {
                    if (!ensureApiKey()) {
                      return
                    }
                    void compactSession(session.id, 'manual').then((ok) => {
                      showToast({ key: ok ? 'compactMemorySuccess' : 'compactMemoryEmpty' })
                    })
                  }}
                >
                  {t('compactMemoryNowButton')}
                </button>
              )}
            </div>
          }
        >
          <div className={styles.overview}>
            <div className={styles.tokenLine}>
              {t('contextStatusCurrentTokens', { tokens: formatTokens(stats.effectiveTokens) })}
            </div>
            <div className={styles.barTrack}>
              <div
                className={clsx(styles.barFill, barLevelClass)}
                style={{ width: `${Math.max(4, Math.round(stats.pressure * 100))}%` }}
              />
            </div>
            <div className={styles.subMeta}>
              {t('contextStatusBreakdown', {
                total: stats.totalRounds,
                compacted: stats.compactedRounds,
                tail: Math.min(stats.uncompactedCount, PROTECTED_TAIL_ROUNDS),
              })}
            </div>
          </div>

          <div className={styles.divider} />

          <div className={styles.sectionTitle}>
            {t('contextStatusMemoryListTitle', { count: stats.activeCompactions.length })}
          </div>

          {stats.activeCompactions.length === 0 ? (
            <div className={styles.emptyState}>{t('contextStatusMemoryEmpty')}</div>
          ) : (
            <div className={styles.memoryList}>
              {stats.activeCompactions.map(({ span }) => (
                <MemoryListItem key={span.id} sessionId={session.id} span={span} />
              ))}
            </div>
          )}
        </Modal>
      ) : null}
    </>
  )
})
