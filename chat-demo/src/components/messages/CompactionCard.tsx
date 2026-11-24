import clsx from 'clsx'
import { memo, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { deleteCompactionSpan, updateCompactionSummary } from '../../services/chat/store.js'
import type { CompactionSpan } from '../../services/chat/types.js'
import { showToast } from '../base/toastState.js'
import styles from './CompactionCard.module.css'

/**
 * 时间线内的轻量记忆折叠条：
 * 默认收起为单行提示，不打断阅读；点开后可查看、手动修订或无损撤销折叠。
 */
export const CompactionCard = memo(function CompactionCard({
  sessionId,
  span,
}: {
  sessionId: string
  span: CompactionSpan
}) {
  const t = useTranslate()
  const [expanded, setExpanded] = useState(false)
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(span.summary)

  const startEdit = () => {
    setDraft(span.summary)
    setEditing(true)
  }

  const saveEdit = () => {
    const trimmed = draft.trim()
    if (!trimmed) {
      return
    }
    updateCompactionSummary(sessionId, span.id, trimmed)
    setEditing(false)
    showToast({ key: 'compactMemorySavedToast' })
  }

  const restore = () => {
    deleteCompactionSpan(sessionId, span.id)
    showToast({ key: 'compactMemoryRestoredToast' })
  }

  return (
    <div className={styles.wrapper}>
      <div className={styles.dividerRow}>
        <span className={styles.line} aria-hidden />
        <button
          type="button"
          className={styles.pill}
          aria-expanded={expanded}
          onClick={() => {
            setExpanded((prev) => !prev)
            if (expanded) {
              setEditing(false)
            }
          }}
        >
          <span className={styles.title}>{span.title}</span>
          <span className={styles.meta}>
            · {t('compactMemorySavedTokens', { rounds: span.coveredRounds })}
          </span>
          {span.editedByUser ? (
            <span className={styles.badge}>{t('compactMemoryEditedBadge')}</span>
          ) : null}
          <span className={styles.actionHint}>
            {expanded ? t('compactMemoryCollapse') : t('compactMemoryExpand')}
          </span>
        </button>
        <span className={styles.line} aria-hidden />
      </div>

      {expanded ? (
        <div className={styles.panel}>
          {editing ? (
            <textarea
              className={styles.editor}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
            />
          ) : (
            <pre className={styles.summaryText}>{span.summary}</pre>
          )}
          <div className={styles.footer}>
            <span className={styles.hint}>{t('compactMemoryRestoreHint')}</span>
            <div className={styles.actions}>
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
                    onClick={saveEdit}
                  >
                    {t('compactMemorySave')}
                  </button>
                </>
              ) : (
                <>
                  <button
                    type="button"
                    className={clsx(styles.btn, styles.btnDanger)}
                    onClick={restore}
                  >
                    {t('compactMemoryRestore')}
                  </button>
                  <button type="button" className={styles.btn} onClick={startEdit}>
                    {t('compactMemoryEdit')}
                  </button>
                </>
              )}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  )
})
