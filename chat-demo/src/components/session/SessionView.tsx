import clsx from 'clsx'
import { useCallback, useRef } from 'react'
import { useIsMobile } from '../../app/viewport.js'
import { useTranslate } from '../../i18n/index.js'
import type { Session } from '../../services/chat/types.js'
import { ChatInput } from '../chatInput/ChatInput.js'
import { MessageList } from '../messages/MessageList.js'
import { ContextStatus } from './ContextStatus.js'
import { MobileHeader } from './MobileHeader.js'
import styles from './SessionView.module.css'

const DOUBLE_TAP_MS = 400

/** 会话页：标题栏（移动端为顶栏）+ 消息列表，输入框吸底 */
export const SessionView = ({
  session,
  streaming,
  siderCollapsed,
}: {
  session: Session
  streaming: boolean
  siderCollapsed: boolean
}) => {
  const t = useTranslate()
  const isMobile = useIsMobile()
  const title = session.title || t('untitledChat')
  const scrollToTopRef = useRef<(() => void) | null>(null)
  const lastTitleTapRef = useRef(0)

  // 使用点击时间差统一兼容桌面端双击与移动端 WebView 双击（避免 touch-action 吞掉 dblclick）。
  const onTitleTap = useCallback(() => {
    const now = Date.now()
    if (now - lastTitleTapRef.current <= DOUBLE_TAP_MS) {
      lastTitleTapRef.current = 0
      scrollToTopRef.current?.()
      return
    }
    lastTitleTapRef.current = now
  }, [])

  const contextStatusNode = <ContextStatus session={session} streaming={streaming} />

  return (
    <div className={styles.view}>
      {isMobile ? (
        <MobileHeader title={title} onTitleTap={onTitleTap} statusSlot={contextStatusNode} />
      ) : (
        <div className={styles.header}>
          <div
            className={clsx(styles.title, siderCollapsed && styles.withCollapsedSider)}
            onClick={onTitleTap}
          >
            {title}
          </div>
          <div style={{ marginLeft: 'auto' }}>{contextStatusNode}</div>
        </div>
      )}
      <MessageList
        key={session.id}
        session={session}
        streaming={streaming}
        scrollToTopRef={scrollToTopRef}
        footer={
          <div className={styles.inputContainer}>
            <ChatInput sessionId={session.id} />
          </div>
        }
      />
    </div>
  )
}
