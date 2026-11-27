import clsx from 'clsx'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { newChat, useChatStore } from '../../services/chat/store.js'
import type { Session } from '../../services/chat/types.js'
import { IconNativeMenu20, IconNewChatBubble20 } from '../base/icons.js'
import { openMobileSider } from '../sider/mobileSiderState.js'
import { getSessionPressureLevel, SessionSettingsModal } from './ContextStatus.js'
import styles from './MobileHeader.module.css'

const DOUBLE_TAP_WINDOW_MS = 260

/**
 * 移动端极简对称顶栏：
 * 左：侧边栏圆形按钮 | 中：纯净状态点标题/会话设置胶囊（单击进会话设置，双击回顶部） | 右：新建对话圆形按钮
 */
export const MobileHeader = ({
  session,
  streaming = false,
  title,
  onTitleDoubleTap,
}: {
  session?: Session
  streaming?: boolean
  title?: string
  onTitleDoubleTap?: () => void
}) => {
  const t = useTranslate()
  const [settingsOpen, setSettingsOpen] = useState(false)
  const singleTapTimerRef = useRef<number | null>(null)
  const compacting = useChatStore((state) => (session ? Boolean(state.compacting[session.id]) : false))

  useEffect(
    () => () => {
      if (singleTapTimerRef.current !== null) {
        window.clearTimeout(singleTapTimerRef.current)
      }
    },
    []
  )

  const pressureLevel = useMemo(
    () => (session ? getSessionPressureLevel(session) : null),
    [session]
  )

  const dotColorClass =
    pressureLevel === 'red'
      ? styles.dotRed
      : pressureLevel === 'orange'
        ? styles.dotOrange
        : pressureLevel === 'yellow'
          ? styles.dotYellow
          : pressureLevel === 'green'
            ? styles.dotGreen
            : undefined

  const pillLabel = title !== undefined ? title : '会话设置'

  const handlePillClick = () => {
    if (!onTitleDoubleTap) {
      setSettingsOpen(true)
      return
    }
    if (singleTapTimerRef.current !== null) {
      window.clearTimeout(singleTapTimerRef.current)
      singleTapTimerRef.current = null
      onTitleDoubleTap()
      return
    }
    singleTapTimerRef.current = window.setTimeout(() => {
      singleTapTimerRef.current = null
      setSettingsOpen(true)
    }, DOUBLE_TAP_WINDOW_MS)
  }

  return (
    <>
      <div className={styles.header}>
        <button
          type="button"
          className={styles.circleButton}
          aria-label={t('expandSiderbarButton')}
          onClick={openMobileSider}
        >
          <IconNativeMenu20 />
        </button>

        <div className={styles.centerSlot}>
          <button
            type="button"
            className={styles.titlePill}
            aria-label={pillLabel}
            onClick={handlePillClick}
          >
            {dotColorClass ? (
              <span
                className={clsx(
                  styles.statusDot,
                  dotColorClass,
                  compacting && styles.statusDotPulsing
                )}
                aria-hidden="true"
              />
            ) : null}
            <span className={styles.titleText}>{pillLabel}</span>
          </button>
        </div>

        <button
          type="button"
          className={styles.circleButton}
          aria-label={t('newChat')}
          onClick={() => {
            newChat()
          }}
        >
          <IconNewChatBubble20 />
        </button>
      </div>

      {settingsOpen ? (
        <SessionSettingsModal
          session={session}
          streaming={streaming}
          onClose={() => setSettingsOpen(false)}
        />
      ) : null}
    </>
  )
}
