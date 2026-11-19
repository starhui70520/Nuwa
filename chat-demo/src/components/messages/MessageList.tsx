import clsx from 'clsx'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useIsMobile } from '../../app/viewport.js'
import {
  buildMessageVersions,
  getVisibleMessages,
  type MessageVersions,
} from '../../services/chat/branches.js'
import { selectMessageVersion } from '../../services/chat/store.js'
import type { Session } from '../../services/chat/types.js'
import { closeSearchPanel } from '../search/searchPanelState.js'
import { AssistantMessage } from './AssistantMessage.js'
import { ScrollToBottomContext } from './scrollContext.js'
import { UserMessage } from './UserMessage.js'
import type { Message } from '../../services/chat/types.js'

/**
 * 会话共用可重试的附件上传失败入口，覆盖当前提问与历史消息中的附件。
 * 点击后按失败的回答重新补传附件并请求。
 */
const getUploadRetryId = (messages: Message[], streaming: boolean) => {
  const last = messages.at(-1)
  return !streaming &&
    last?.role === 'assistant' &&
    last.status === 'error' &&
    last.error?.kind === 'upload' &&
    last.error.retryable
    ? last.id
    : null
}
import styles from './MessageList.module.css'

/** 距底部小于该值时视为在底部，流式内容增长时跟随 */
const STICKY_THRESHOLD = 40
/** 超长对话分批渲染，避免数百条长文一次性挂载导致卡顿 */
const INITIAL_VISIBLE_COUNT = 40
const LOAD_MORE_STEP = 40
const LOAD_MORE_THRESHOLD = 260
const EMPTY_VERSIONS: MessageVersions = { ids: [], index: -1 }

export const MessageList = ({
  session,
  streaming,
  footer,
  scrollToTopRef,
}: {
  session: Session
  streaming: boolean
  footer: React.ReactNode
  scrollToTopRef?: React.MutableRefObject<(() => void) | null>
}) => {
  const isMobile = useIsMobile()
  const scrollRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const stickyRef = useRef(true)
  const scrollTopRef = useRef(0)
  const restoreScrollRef = useRef<{ messageId: string; top: number } | null>(null)
  const prependAnchorRef = useRef<{ prevHeight: number; prevTop: number } | null>(null)
  const jumpTopPendingRef = useRef(false)
  const jumpBottomPendingRef = useRef(false)
  const [visibleWindow, setVisibleWindow] = useState<{
    sessionId: string
    anchor: 'bottom' | 'top'
    count: number
  }>({
    sessionId: session.id,
    anchor: 'bottom',
    count: INITIAL_VISIBLE_COUNT,
  })
  const activeWindow =
    visibleWindow.sessionId === session.id
      ? visibleWindow
      : { sessionId: session.id, anchor: 'bottom' as const, count: INITIAL_VISIBLE_COUNT }

  const messages = useMemo(() => getVisibleMessages(session), [session])
  const startIndex =
    activeWindow.anchor === 'top' ? 0 : Math.max(0, messages.length - activeWindow.count)
  const endIndex =
    activeWindow.anchor === 'top'
      ? Math.min(messages.length, activeWindow.count)
      : messages.length
  const hiddenAboveCount = startIndex
  const hiddenBelowCount = Math.max(0, messages.length - endIndex)
  const hiddenBelowCountRef = useRef(hiddenBelowCount)
  hiddenBelowCountRef.current = hiddenBelowCount
  const visibleMessages = useMemo(
    () =>
      startIndex > 0 || endIndex < messages.length
        ? messages.slice(startIndex, endIndex)
        : messages,
    [messages, startIndex, endIndex]
  )
  const [previousVersions, setPreviousVersions] = useState(() =>
    buildMessageVersions(session, new Map())
  )
  const versions = useMemo(
    () => buildMessageVersions(session, previousVersions),
    [session, previousVersions]
  )
  if (versions !== previousVersions) {
    setPreviousVersions(versions)
  }
  const lastMessageId = messages.at(-1)?.id

  const loadOlderMessages = useCallback(() => {
    if (hiddenAboveCount <= 0) {
      return
    }
    const el = scrollRef.current
    if (el) {
      prependAnchorRef.current = { prevHeight: el.scrollHeight, prevTop: el.scrollTop }
    }
    stickyRef.current = false
    setVisibleWindow((prev) => ({
      sessionId: session.id,
      anchor: 'bottom',
      count:
        (prev.sessionId === session.id && prev.anchor === 'bottom'
          ? prev.count
          : INITIAL_VISIBLE_COUNT) + LOAD_MORE_STEP,
    }))
  }, [hiddenAboveCount, session.id])

  const loadNewerMessages = useCallback(() => {
    if (hiddenBelowCount <= 0) {
      return
    }
    stickyRef.current = false
    setVisibleWindow((prev) => ({
      sessionId: session.id,
      anchor: 'top',
      count:
        (prev.sessionId === session.id && prev.anchor === 'top'
          ? prev.count
          : INITIAL_VISIBLE_COUNT) + LOAD_MORE_STEP,
    }))
  }, [hiddenBelowCount, session.id])

  const jumpToLatest = useCallback(() => {
    prependAnchorRef.current = null
    jumpTopPendingRef.current = false
    jumpBottomPendingRef.current = true
    stickyRef.current = true
    setVisibleWindow({
      sessionId: session.id,
      anchor: 'bottom',
      count: INITIAL_VISIBLE_COUNT,
    })
    const el = scrollRef.current
    if (el && hiddenBelowCount === 0) {
      jumpBottomPendingRef.current = false
      el.scrollTop = el.scrollHeight
      scrollTopRef.current = el.scrollTop
    }
  }, [hiddenBelowCount, session.id])

  // 顶部增量加载更早消息后精确补偿 scrollTop；双击跳顶 / 一键回底在窗口切换完成后落位。
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) {
      return
    }
    if (jumpTopPendingRef.current) {
      jumpTopPendingRef.current = false
      prependAnchorRef.current = null
      el.scrollTop = 0
      scrollTopRef.current = 0
      return
    }
    if (jumpBottomPendingRef.current) {
      jumpBottomPendingRef.current = false
      prependAnchorRef.current = null
      el.scrollTop = el.scrollHeight
      scrollTopRef.current = el.scrollTop
      return
    }
    const anchor = prependAnchorRef.current
    if (!anchor) {
      return
    }
    prependAnchorRef.current = null
    const delta = el.scrollHeight - anchor.prevHeight
    el.scrollTop = anchor.prevTop + Math.max(0, delta)
    scrollTopRef.current = el.scrollTop
  }, [visibleMessages.length, activeWindow.anchor, startIndex, endIndex])

  const scrollToBottom = useCallback(() => {
    const el = scrollRef.current
    if (el && stickyRef.current && hiddenBelowCountRef.current === 0) {
      el.scrollTop = el.scrollHeight
      scrollTopRef.current = el.scrollTop
    }
  }, [])

  const scrollToTop = useCallback(() => {
    const el = scrollRef.current
    if (!el) {
      return
    }
    stickyRef.current = false
    prependAnchorRef.current = null
    if (hiddenAboveCount > 0) {
      // 超长会话直接切换窗口到第 1 条消息，毫秒级直达真正顶部且不一次性挂载全部 DOM。
      jumpTopPendingRef.current = true
      setVisibleWindow({
        sessionId: session.id,
        anchor: 'top',
        count: INITIAL_VISIBLE_COUNT,
      })
      return
    }
    scrollTopRef.current = 0
    if (typeof el.scrollTo === 'function') {
      el.scrollTo({ top: 0, behavior: 'smooth' })
    } else {
      el.scrollTop = 0
    }
  }, [hiddenAboveCount, session.id])

  useEffect(() => {
    if (!scrollToTopRef) {
      return
    }
    scrollToTopRef.current = scrollToTop
    return () => {
      scrollToTopRef.current = null
    }
  }, [scrollToTopRef, scrollToTop])

  // 内容、键盘和输入框高度变化时，继续遵循当前跟随状态。
  useLayoutEffect(() => {
    const content = contentRef.current
    const scroll = scrollRef.current
    if (!content || !scroll) {
      return
    }
    const observer = new ResizeObserver(scrollToBottom)
    observer.observe(content)
    observer.observe(scroll)
    return () => observer.disconnect()
  }, [isMobile, scrollToBottom])

  // 切换版本后将选择器留在原位置，避免回答长短变化导致操作区跳出视口。
  useLayoutEffect(() => {
    const anchor = restoreScrollRef.current
    const scroll = scrollRef.current
    if (anchor && scroll) {
      const switcher = scroll.querySelector<HTMLElement>(
        `[data-message-version="${CSS.escape(anchor.messageId)}"]`
      )
      if (switcher) {
        scroll.scrollTop += switcher.getBoundingClientRect().top - anchor.top
      }
      restoreScrollRef.current = null
      return
    }
    stickyRef.current = true
    setVisibleWindow((prev) =>
      prev.sessionId === session.id && prev.anchor === 'bottom'
        ? prev
        : { sessionId: session.id, anchor: 'bottom', count: INITIAL_VISIBLE_COUNT }
    )
    scrollToBottom()
  }, [session.id, lastMessageId, scrollToBottom])

  useEffect(closeSearchPanel, [session.id, lastMessageId])

  const selectVersion = useCallback(
    (messageId: string, anchorTop: number) => {
      if (streaming) {
        return
      }
      restoreScrollRef.current = { messageId, top: anchorTop }
      stickyRef.current = false
      closeSearchPanel()
      selectMessageVersion(session.id, messageId)
    },
    [session.id, streaming]
  )

  // 跨移动端断点时切换滚动层，并保持输入框及当前阅读位置。
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) {
      return
    }
    if (stickyRef.current) {
      scrollToBottom()
    } else {
      el.scrollTop = scrollTopRef.current
    }
    const onScroll = () => {
      const distanceToBottom = el.scrollHeight - el.scrollTop - el.clientHeight
      const nearBottom = distanceToBottom < STICKY_THRESHOLD
      // 仅在用户向上滚动时停止跟随底部，布局或内容增高时保持跟随状态。
      if (nearBottom && hiddenBelowCount === 0) {
        stickyRef.current = true
      } else if (el.scrollTop < scrollTopRef.current) {
        stickyRef.current = false
      }
      if (
        !stickyRef.current &&
        hiddenAboveCount > 0 &&
        el.scrollTop < LOAD_MORE_THRESHOLD &&
        el.scrollTop < scrollTopRef.current
      ) {
        loadOlderMessages()
      } else if (
        hiddenBelowCount > 0 &&
        distanceToBottom < LOAD_MORE_THRESHOLD &&
        el.scrollTop > scrollTopRef.current
      ) {
        loadNewerMessages()
      }
      scrollTopRef.current = el.scrollTop
    }
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => el.removeEventListener('scroll', onScroll)
  }, [isMobile, scrollToBottom, loadOlderMessages, loadNewerMessages, hiddenAboveCount, hiddenBelowCount])

  const lastIndex = messages.length - 1
  const uploadRetryId = getUploadRetryId(messages, streaming)
  return (
    <ScrollToBottomContext.Provider value={scrollToBottom}>
      <div ref={isMobile ? undefined : scrollRef} className={styles.container}>
        <div ref={isMobile ? scrollRef : undefined} className={styles.scroll}>
          <div ref={contentRef} className={styles.column}>
            {hiddenAboveCount > 0 ? (
              <div className={styles.loadMoreWrap}>
                <button
                  type="button"
                  className={styles.loadMoreButton}
                  onClick={loadOlderMessages}
                >
                  加载更早消息（还有 {hiddenAboveCount} 条）
                </button>
              </div>
            ) : null}
            {visibleMessages.map((message, offset) => {
              const index = startIndex + offset
              return message.role === 'user' ? (
                <UserMessage
                  key={message.id}
                  sessionId={session.id}
                  message={message}
                  retryUploadId={uploadRetryId}
                  isFirst={index === 0}
                  isLast={index === lastIndex || index === lastIndex - 1}
                  busy={streaming}
                  versions={versions.get(message.id) ?? EMPTY_VERSIONS}
                  onSelectVersion={selectVersion}
                />
              ) : (
                <AssistantMessage
                  key={message.id}
                  sessionId={session.id}
                  message={message}
                  isLast={index === lastIndex}
                  streaming={streaming && index === lastIndex}
                  busy={streaming}
                  versions={versions.get(message.id) ?? EMPTY_VERSIONS}
                  onSelectVersion={selectVersion}
                />
              )
            })}
            {hiddenBelowCount > 0 ? (
              <div className={styles.loadMoreWrap}>
                <button
                  type="button"
                  className={styles.loadMoreButton}
                  onClick={loadNewerMessages}
                >
                  加载后续消息（还有 {hiddenBelowCount} 条）
                </button>
                <button
                  type="button"
                  className={clsx(styles.loadMoreButton, styles.loadMorePrimary)}
                  onClick={jumpToLatest}
                >
                  回到底部
                </button>
              </div>
            ) : null}
          </div>
        </div>
        {footer}
      </div>
    </ScrollToBottomContext.Provider>
  )
}
