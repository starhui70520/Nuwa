import clsx from 'clsx'
import { useEffect, useMemo, useRef, useState } from 'react'
import { isLowPerfDevice } from '../../app/devicePerf.js'
import logoUrl from '../../assets/logo.png'
import { useTranslate } from '../../i18n/index.js'
import { refreshBalance, useBalance } from '../../services/api/balance.js'
import { openExternalUrl } from '../../services/externalLink.js'
import { searchSessionIdsByContent } from '../../services/chat/db.js'
import { groupSessions } from '../../services/chat/sessionGroups.js'
import { newChat, removeSession, setSessionsPinned, useChatStore } from '../../services/chat/store.js'
import type { SessionSummary } from '../../services/chat/types.js'
import { isUsingDeepSeekAccount, setSiderCollapsed, useSettings } from '../../services/settings.js'
import { Button } from '../base/Button.js'
import { IconButton } from '../base/IconButton.js'
import {
  IconCloseFill14,
  IconCloseOutline16,
  IconEllipsisOutline16,
  IconPanelLeftOutline16,
  IconPinOutline16,
  IconSearchOutline16,
  IconTrashOutline16,
  NewChatIcon,
} from '../base/icons.js'
import { Modal } from '../base/Modal.js'
import { showToast } from '../base/toastState.js'
import { openSettings } from '../settings/settingsDialogState.js'
import { closeMobileSider, useMobileSider } from './mobileSiderState.js'
import { SessionItem } from './SessionItem.js'
import styles from './Sider.module.css'

const getSiderBatchSize = () => (isLowPerfDevice() ? 30 : 60)

/** 展开的侧边栏：搜索框 / 会话列表 / 底部账号入口 */
export const Sider = ({ mobile = false }: { mobile?: boolean }) => {
  const t = useTranslate()
  const sessions = useChatStore((state) => state.sessions)
  const activeId = useChatStore((state) => state.activeId)
  const isAccount = useSettings((state) => isUsingDeepSeekAccount(state))
  const dshAccountLabel = useSettings((state) => state.dshAccountLabel)
  const apiModel = useSettings((state) => state.apiModel)
  const balance = useBalance((state) => state.balance)
  const mobileOpen = useMobileSider((state) => state.open)
  const [now, setNow] = useState(Date.now)
  const [query, setQuery] = useState('')
  const [contentSearch, setContentSearch] = useState<{
    keyword: string
    ids: Set<string>
  } | null>(null)
  const [deleting, setDeleting] = useState<SessionSummary | null>(null)
  const [deletePending, setDeletePending] = useState(false)
  const [selectMode, setSelectMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set())
  const [batchDeleting, setBatchDeleting] = useState(false)
  const [renderLimit, setRenderLimit] = useState(getSiderBatchSize)
  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions

  const normalizedQuery = query.trim().toLowerCase()

  useEffect(() => {
    setRenderLimit(getSiderBatchSize())
  }, [normalizedQuery])

  useEffect(() => {
    if (!normalizedQuery) {
      return
    }
    const controller = new AbortController()
    const debounceMs = isLowPerfDevice() ? 200 : 180
    const timer = setTimeout(() => {
      const titleMatched = new Set<string>()
      const untitled = t('untitledChat').toLowerCase()
      const currentSessions = sessionsRef.current
      for (let i = 0; i < currentSessions.length; i++) {
        const s = currentSessions[i]
        const title = s.title ? s.title.toLowerCase() : untitled
        if (title.includes(normalizedQuery)) {
          titleMatched.add(s.id)
        }
      }
      void searchSessionIdsByContent(normalizedQuery, controller.signal, titleMatched)
        .then((ids) => {
          if (!controller.signal.aborted) {
            setContentSearch({ keyword: normalizedQuery, ids })
          }
        })
        .catch(() => {
          // 检索中断时保留当前标题匹配结果
        })
    }, debounceMs)
    return () => {
      clearTimeout(timer)
      controller.abort()
    }
  }, [normalizedQuery, t])

  const filteredSessions = useMemo(() => {
    if (!normalizedQuery) {
      return sessions
    }
    const contentIds =
      contentSearch && contentSearch.keyword === normalizedQuery ? contentSearch.ids : null
    return sessions.filter((session) => {
      const title = (session.title || t('untitledChat')).toLowerCase()
      return title.includes(normalizedQuery) || Boolean(contentIds?.has(session.id))
    })
  }, [sessions, normalizedQuery, contentSearch, t])

  const visibleSessions = useMemo(
    () =>
      filteredSessions.length > renderLimit
        ? filteredSessions.slice(0, renderLimit)
        : filteredSessions,
    [filteredSessions, renderLimit]
  )

  const groups = useMemo(() => groupSessions(visibleSessions, now, t), [visibleSessions, now, t])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>
    const refresh = () => {
      clearTimeout(timer)
      const time = Date.now()
      setNow(time)
      const midnight = new Date(time).setHours(24, 0, 0, 0)
      timer = setTimeout(refresh, midnight - time)
    }
    const onVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        refresh()
        void refreshBalance()
      }
    }
    const onFocus = () => {
      refresh()
      void refreshBalance()
    }
    refresh()
    void refreshBalance()
    document.addEventListener('visibilitychange', onVisibilityChange)
    window.addEventListener('focus', onFocus)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('visibilitychange', onVisibilityChange)
      window.removeEventListener('focus', onFocus)
    }
  }, [])

  useEffect(() => {
    if (!mobile || mobileOpen) {
      void refreshBalance()
    }
    if (mobile && !mobileOpen) {
      setSelectMode(false)
      setSelectedIds(new Set())
      setRenderLimit(getSiderBatchSize())
    }
  }, [mobile, mobileOpen])

  const validSelectedIds = useMemo(() => {
    if (!selectMode || selectedIds.size === 0) {
      return []
    }
    const existing = new Set(sessions.map((session) => session.id))
    return Array.from(selectedIds).filter((id) => existing.has(id))
  }, [selectMode, selectedIds, sessions])

  const allSelectedPinned = useMemo(() => {
    if (validSelectedIds.length === 0) {
      return false
    }
    const byId = new Map(sessions.map((session) => [session.id, session]))
    return validSelectedIds.every((id) => Boolean(byId.get(id)?.pinnedAt))
  }, [validSelectedIds, sessions])

  const enterSelectMode = (initialId: string) => {
    setSelectMode(true)
    setSelectedIds(new Set([initialId]))
  }

  const exitSelectMode = () => {
    setSelectMode(false)
    setSelectedIds(new Set())
  }

  const toggleSelectedId = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }

  const onBatchPin = () => {
    if (validSelectedIds.length === 0) {
      return
    }
    setSessionsPinned(validSelectedIds, !allSelectedPinned)
    exitSelectMode()
  }

  const profileName = isAccount
    ? dshAccountLabel || t('dshAccountLabel')
    : apiModel.trim() || t('appName')

  return (
    <div className={clsx(styles.sider, mobile && styles.mobile)}>
      {selectMode ? (
        <div className={styles.selectHeader}>
          <div className={styles.selectTitle}>
            {t('siderSelectedCount', { count: validSelectedIds.length })}
          </div>
          <button
            type="button"
            className={styles.selectClose}
            aria-label={t('close')}
            onClick={exitSelectMode}
          >
            <IconCloseOutline16 />
          </button>
        </div>
      ) : (
        <>
          {!mobile ? (
            <>
              <div className={styles.top}>
                <div className={styles.brand}>
                  <img src={logoUrl} alt="" className={styles.brandLogo} />
                  <div className={styles.appName}>{t('appName')}</div>
                </div>
                <IconButton
                  size="m"
                  icon={<IconPanelLeftOutline16 />}
                  tooltip={t('collapseSiderbarButton')}
                  tooltipPlacement="bottom"
                  onClick={() => setSiderCollapsed(true)}
                />
              </div>
              <button
                type="button"
                className={styles.newChat}
                onClick={() => {
                  newChat()
                  closeMobileSider()
                }}
              >
                <span className={styles.newChatIcon}>
                  <NewChatIcon />
                </span>
                {t('newChat')}
              </button>
            </>
          ) : null}

          <div className={styles.searchWrap}>
            <span className={styles.searchIcon}>
              <IconSearchOutline16 />
            </span>
            <input
              type="search"
              className={styles.searchInput}
              placeholder={t('siderSearchPlaceholder')}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            {query ? (
              <button
                type="button"
                className={styles.searchClear}
                aria-label={t('close')}
                onClick={() => setQuery('')}
              >
                <IconCloseFill14 />
              </button>
            ) : null}
          </div>
        </>
      )}

      <div
        className={styles.listWrap}
        onScroll={(event) => {
          if (renderLimit >= filteredSessions.length) {
            return
          }
          const el = event.currentTarget
          if (el.scrollHeight - el.scrollTop - el.clientHeight < 320) {
            const step = getSiderBatchSize()
            setRenderLimit((prev) => Math.min(filteredSessions.length, prev + step))
          }
        }}
      >
        {sessions.length === 0 ? (
          <div className={styles.emptyState}>
            <div className={styles.emptyTitle}>{t('siderEmptyTitle')}</div>
            <div className={styles.emptySubtitle}>{t('siderEmptySubtitle')}</div>
            <button
              type="button"
              className={styles.emptyAction}
              onClick={() => {
                newChat({ silentIfAlreadyNew: mobile })
                closeMobileSider()
              }}
            >
              {t('newChat')}
            </button>
          </div>
        ) : filteredSessions.length === 0 ? (
          <div className={styles.emptySearch}>{t('siderSearchEmpty')}</div>
        ) : (
          <div className={styles.list}>
            {groups.map((group) => (
              <div key={group.key} className={styles.section}>
                <div className={styles.sectionHeader}>{group.label}</div>
                {group.sessions.map((session) => (
                  <SessionItem
                    key={session.id}
                    session={session}
                    active={session.id === activeId}
                    selectMode={selectMode}
                    selected={selectedIds.has(session.id)}
                    onToggleSelect={() => toggleSelectedId(session.id)}
                    onEnterSelect={() => enterSelectMode(session.id)}
                    onDelete={() => setDeleting(session)}
                  />
                ))}
              </div>
            ))}
          </div>
        )}
      </div>

      <div className={styles.bottom}>
        {selectMode ? (
          <div className={styles.selectBar}>
            <button
              type="button"
              className={styles.selectAction}
              disabled={validSelectedIds.length === 0}
              onClick={onBatchPin}
            >
              <IconPinOutline16 />
              <span>
                {allSelectedPinned
                  ? t('sessionItemMenuUnpinOption')
                  : t('sessionItemMenuPinOption')}
              </span>
            </button>
            <span className={styles.selectDivider} aria-hidden="true" />
            <button
              type="button"
              className={clsx(styles.selectAction, styles.selectActionDanger)}
              disabled={validSelectedIds.length === 0}
              onClick={() => setBatchDeleting(true)}
            >
              <IconTrashOutline16 />
              <span>{t('delete')}</span>
            </button>
          </div>
        ) : (
          <button type="button" className={styles.settings} onClick={() => openSettings('general')}>
            <img src={logoUrl} alt="" className={styles.profileAvatar} />
            <span className={styles.profileMain}>
              <span className={styles.settingsLabel}>{profileName}</span>
              {balance ? (
                <span
                  role="button"
                  tabIndex={0}
                  className={clsx(
                    styles.profileBalance,
                    (!balance.isAvailable || Number(balance.totalBalance) <= 0) &&
                      styles.profileBalanceLow
                  )}
                  title={t('accountBalanceTooltip', { amount: balance.formatted })}
                  onClick={(event) => {
                    event.stopPropagation()
                    openExternalUrl('https://platform.deepseek.com/top_up')
                  }}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault()
                      event.stopPropagation()
                      openExternalUrl('https://platform.deepseek.com/top_up')
                    }
                  }}
                >
                  {balance.formatted}
                </span>
              ) : null}
            </span>
            <span className={styles.profileMore}>
              <IconEllipsisOutline16 />
            </span>
          </button>
        )}
      </div>

      {batchDeleting ? (
        <Modal
          title={t('deleteBatchSessionsTitle', { count: validSelectedIds.length })}
          onClose={() => {
            if (!deletePending) {
              setBatchDeleting(false)
            }
          }}
          footer={
            <>
              <Button
                variant="outlined"
                disabled={deletePending}
                onClick={() => setBatchDeleting(false)}
              >
                {t('cancel')}
              </Button>
              <Button
                variant="danger"
                disabled={deletePending}
                onClick={async () => {
                  setDeletePending(true)
                  try {
                    let anyFailed = false
                    for (const id of validSelectedIds) {
                      const ok = await removeSession(id)
                      if (!ok) {
                        anyFailed = true
                      }
                    }
                    setBatchDeleting(false)
                    exitSelectMode()
                    if (anyFailed) {
                      showToast({ key: 'sessionDeleteFailed', type: 'error' })
                    }
                  } finally {
                    setDeletePending(false)
                  }
                }}
              >
                {t('delete')}
              </Button>
            </>
          }
        >
          {t('deleteBatchSessionsDescription')}
        </Modal>
      ) : null}

      {deleting ? (
        <Modal
          title={t('deleteSessionModalContentTitle')}
          onClose={() => {
            if (!deletePending) {
              setDeleting(null)
            }
          }}
          footer={
            <>
              <Button variant="outlined" disabled={deletePending} onClick={() => setDeleting(null)}>
                {t('cancel')}
              </Button>
              <Button
                variant="danger"
                disabled={deletePending}
                onClick={async () => {
                  setDeletePending(true)
                  try {
                    if (await removeSession(deleting.id)) {
                      setDeleting(null)
                    } else {
                      showToast({ key: 'sessionDeleteFailed', type: 'error' })
                    }
                  } finally {
                    setDeletePending(false)
                  }
                }}
              >
                {t('delete')}
              </Button>
            </>
          }
        >
          {t('deleteSessionWithFilesDescription')}
        </Modal>
      ) : null}
    </div>
  )
}

/** 移动端推拉式抽屉：位于主卡片层下方，支持点击开关与手指跟手划入/划出 */
export const MobileSider = () => {
  const open = useMobileSider((state) => state.open)
  const dragProgress = useMobileSider((state) => state.dragProgress)
  const dragging = dragProgress !== null
  const style = dragging
    ? {
        opacity: dragProgress,
        visibility: 'visible' as const,
        transform: `translateX(${(dragProgress - 1) * 24}px)`,
        transition: 'none',
      }
    : undefined
  return (
    <div
      className={clsx(styles.drawer, open && styles.drawerOpen)}
      style={style}
      aria-hidden={!open && !dragging}
    >
      <Sider mobile />
    </div>
  )
}
