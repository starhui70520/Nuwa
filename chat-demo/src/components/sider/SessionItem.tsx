import clsx from 'clsx'
import { memo, useRef, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import {
  IconCheckMark12,
  IconDownloadOutline16,
  IconEditOutline16,
  IconEllipsisOutline16,
  IconMultiSelectOutline16,
  IconPinOutline16,
  IconTrashOutline16,
} from '../base/icons.js'
import {
  exportSession,
  saveExportArchive,
  type ExportDestination,
} from '../../services/chat/backup.js'
import { renameSession, selectSession, togglePinSession } from '../../services/chat/store.js'
import type { SessionSummary } from '../../services/chat/types.js'
import { ExportActionModal } from '../base/ExportActionModal.js'
import { IconButton } from '../base/IconButton.js'
import { Menu } from '../base/Menu.js'
import { showToast } from '../base/toastState.js'
import { closeMobileSider } from './mobileSiderState.js'
import styles from './SessionItem.module.css'

export const SessionItem = memo(function SessionItem({
  session,
  active,
  selectMode = false,
  selected = false,
  onToggleSelect,
  onEnterSelect,
  onDelete,
}: {
  session: SessionSummary
  active: boolean
  selectMode?: boolean
  selected?: boolean
  onToggleSelect?: () => void
  onEnterSelect?: () => void
  onDelete: () => void
}) {
  const t = useTranslate()
  const [editing, setEditing] = useState(false)
  const [exportModalOpen, setExportModalOpen] = useState(false)
  const [exportMode, setExportMode] = useState<ExportDestination | null>(null)
  const exportingRef = useRef(false)
  const longPressTimerRef = useRef<number | null>(null)
  const longPressTriggeredRef = useRef(false)
  const touchStartRef = useRef<{ x: number; y: number } | null>(null)
  const displayTitle = session.title || t('untitledChat')

  const handleExport = (mode: ExportDestination) => {
    if (exportingRef.current) {
      return
    }
    exportingRef.current = true
    setExportMode(mode)
    void (async () => {
      try {
        const { name, blob } = await exportSession(session.id)
        const res = await saveExportArchive(name, blob, mode)
        setExportModalOpen(false)
        if (res.savedPath) {
          showToast({ key: 'historyExportSaved', params: { path: res.savedPath } })
        } else if (mode === 'save') {
          showToast({ key: 'sessionExported' })
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        showToast({ key: 'historyExportFailed', params: { message }, type: 'error' })
      } finally {
        exportingRef.current = false
        setExportMode(null)
      }
    })()
  }

  const clearLongPress = () => {
    if (longPressTimerRef.current !== null) {
      window.clearTimeout(longPressTimerRef.current)
      longPressTimerRef.current = null
    }
    touchStartRef.current = null
  }

  if (editing && !selectMode) {
    const finish = (title: string) => {
      setEditing(false)
      if (title.trim() && title.trim() !== displayTitle) {
        renameSession(session.id, title.trim())
      }
    }
    return (
      <input
        className={styles.renameInput}
        defaultValue={displayTitle}
        autoFocus
        onFocus={(event) => event.target.select()}
        onBlur={(event) => finish(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
            finish(event.currentTarget.value)
          } else if (event.key === 'Escape') {
            setEditing(false)
          }
        }}
      />
    )
  }

  return (
    <div
      className={clsx(styles.item, !selectMode && active && styles.active)}
      onTouchStart={(event) => {
        if (selectMode || !onEnterSelect || event.touches.length !== 1) {
          return
        }
        const touch = event.touches[0]
        touchStartRef.current = { x: touch.clientX, y: touch.clientY }
        longPressTriggeredRef.current = false
        longPressTimerRef.current = window.setTimeout(() => {
          longPressTimerRef.current = null
          longPressTriggeredRef.current = true
          onEnterSelect()
        }, 450)
      }}
      onTouchMove={(event) => {
        if (!touchStartRef.current || event.touches.length !== 1) {
          clearLongPress()
          return
        }
        const touch = event.touches[0]
        if (
          Math.abs(touch.clientX - touchStartRef.current.x) > 10 ||
          Math.abs(touch.clientY - touchStartRef.current.y) > 10
        ) {
          clearLongPress()
        }
      }}
      onTouchEnd={clearLongPress}
      onTouchCancel={clearLongPress}
      onClick={() => {
        if (longPressTriggeredRef.current) {
          longPressTriggeredRef.current = false
          return
        }
        if (selectMode) {
          onToggleSelect?.()
          return
        }
        selectSession(session.id)
        closeMobileSider()
      }}
    >
      {selectMode ? (
        <span className={clsx(styles.checkbox, selected && styles.checkboxChecked)} aria-hidden="true">
          {selected ? <IconCheckMark12 /> : null}
        </span>
      ) : null}
      {session.pinnedAt ? (
        <span className={styles.pinBadge} aria-hidden="true">
          <IconPinOutline16 />
        </span>
      ) : null}
      <div className={styles.title}>{displayTitle}</div>
      {!selectMode ? (
        <div className={styles.action} onClick={(event) => event.stopPropagation()}>
          <Menu
            options={[
              {
                key: 'pin',
                label: session.pinnedAt
                  ? t('sessionItemMenuUnpinOption')
                  : t('sessionItemMenuPinOption'),
                icon: <IconPinOutline16 />,
                onSelect: () => togglePinSession(session.id),
              },
              ...(onEnterSelect
                ? [
                    {
                      key: 'select',
                      label: t('sessionItemMenuSelectOption'),
                      icon: <IconMultiSelectOutline16 />,
                      onSelect: onEnterSelect,
                    },
                  ]
                : []),
              {
                key: 'rename',
                label: t('sessionItemMenuRenameOption'),
                icon: <IconEditOutline16 />,
                onSelect: () => setEditing(true),
              },
              {
                key: 'export',
                label: t('sessionItemMenuExportOption'),
                icon: <IconDownloadOutline16 />,
                onSelect: () => setExportModalOpen(true),
              },
              {
                key: 'delete',
                label: t('delete'),
                icon: <IconTrashOutline16 />,
                danger: true,
                onSelect: onDelete,
              },
            ]}
          >
            {({ toggle }) => (
              <IconButton icon={<IconEllipsisOutline16 />} aria-label={t('more')} onClick={toggle} />
            )}
          </Menu>
        </div>
      ) : null}
      {exportModalOpen ? (
        <ExportActionModal
          title={t('sessionItemMenuExportOption')}
          busy={exportMode !== null}
          activeMode={exportMode}
          onSelect={handleExport}
          onClose={() => setExportModalOpen(false)}
        />
      ) : null}
    </div>
  )
})
