import clsx from 'clsx'
import { memo, useRef, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import {
  IconCheckMark12,
  IconEditOutline16,
  IconEllipsisOutline16,
  IconMultiSelectOutline16,
  IconPinOutline16,
  IconTrashOutline16,
} from '../base/icons.js'
import { renameSession, selectSession, togglePinSession } from '../../services/chat/store.js'
import type { SessionSummary } from '../../services/chat/types.js'
import { IconButton } from '../base/IconButton.js'
import { Menu } from '../base/Menu.js'
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
  const longPressTimerRef = useRef<number | null>(null)
  const longPressTriggeredRef = useRef(false)
  const touchStartRef = useRef<{ x: number; y: number } | null>(null)
  const displayTitle = session.title || t('untitledChat')

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
    </div>
  )
})
