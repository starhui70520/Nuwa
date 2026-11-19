import clsx from 'clsx'
import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import {
  IconArrowUpBold16,
  IconGlobeLanguageOutline14,
  IconPlusCircleOutline22,
  IconStopFill16,
  IconThinkOutline14,
} from '../base/icons.js'
import { getActiveSecret, setSearch, setThinking, useSettings } from '../../services/settings.js'
import { isNativeAndroid, isNativeIos } from '../../services/nativeBridge.js'
import { useIsCompactWatch, useIsMobile } from '../../app/viewport.js'
import { sendMessage, stopReply, useChatStore } from '../../services/chat/store.js'
import {
  addDraftFiles,
  EMPTY_DRAFT,
  getDraft,
  prepareDraftMessage,
  removeDraftAttachment,
  retryDraftAttachment,
  setDraftText,
  useDrafts,
} from '../../services/chat/drafts.js'
import { stopReadAloud } from '../../services/speech/readAloud.js'
import { Tooltip } from '../base/Tooltip.js'
import { ensureApiKey } from '../settings/settingsDialogState.js'
import { DragMask, useFileDrop } from './DragMask.js'
import { showToast } from '../base/toastState.js'
import { ACCEPT, useUploads } from '../../services/attachments.js'
import { DraftAttachments } from './DraftAttachments.js'
import { useVoiceInput } from './useVoiceInput.js'
import { VoiceButton } from './VoiceButton.js'
import { Spectrum } from './Spectrum.js'
import { useTranslate } from '../../i18n/index.js'
import styles from './ChatInput.module.css'

/** 输入框：自适应高度的文本框 + 文件 + 深度思考与智能搜索开关 + 语音输入 + 发送 / 停止 */
export const ChatInput = memo(function ChatInput({ sessionId }: { sessionId: string | null }) {
  // 切换目标时释放录音、转写和 DOM 状态；文字与附件由草稿服务保留。
  return <Input key={sessionId === null ? 'new' : `session:${sessionId}`} sessionId={sessionId} />
})

const Input = ({ sessionId }: { sessionId: string | null }) => {
  const t = useTranslate()
  const draft = useDrafts((state) => state.drafts.get(sessionId) ?? EMPTY_DRAFT)
  const { text, attachments } = draft
  const setText = (value: string) => setDraftText(sessionId, value)
  const draftReady = useUploads((state) => prepareDraftMessage(draft, state.tasks) !== null)
  const streaming = useChatStore(
    (state) => sessionId !== null && Object.hasOwn(state.streaming, sessionId)
  )
  const thinking = useSettings((state) => state.thinking)
  const importingHistory = useChatStore((state) => state.importingHistory)
  const isMobile = useIsMobile()
  const isCompactWatch = useIsCompactWatch()
  const [watchToolsOpen, setWatchToolsOpen] = useState(false)
  const search = useSettings((state) => state.search)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const togglesRef = useRef<HTMLDivElement>(null)

  useLayoutEffect(() => {
    const toggles = togglesRef.current
    if (!toggles) {
      return
    }

    const updateLabels = () => {
      toggles.classList.remove(styles.collapsedToggles)
      toggles.classList.toggle(styles.collapsedToggles, toggles.scrollWidth > toggles.clientWidth)
    }

    updateLabels()
    const observer = new ResizeObserver(updateLabels)
    observer.observe(toggles)
    return () => observer.disconnect()
  }, [t])

  const acceptFiles = (files: File[]) => {
    if (files.length === 0 || useChatStore.getState().importingHistory || !ensureApiKey()) {
      return
    }
    const error = addDraftFiles(sessionId, files, getActiveSecret())
    if (error) {
      showToast(error)
    }
  }
  const retryFile = useCallback(
    (id: string) => {
      if (!useChatStore.getState().importingHistory && ensureApiKey()) {
        retryDraftAttachment(sessionId, id, getActiveSecret())
      }
    },
    [sessionId]
  )
  const removeFile = useCallback(
    (id: string) => {
      if (!useChatStore.getState().importingHistory) {
        removeDraftAttachment(sessionId, id)
      }
    },
    [sessionId]
  )
  const dragging = useFileDrop(acceptFiles)

  /** 转写结果插入到光标处，并把光标移到插入内容之后 */
  const voice = useVoiceInput((transcript) => {
    const textarea = textareaRef.current
    const current = getDraft(sessionId).text
    const start = textarea?.selectionStart ?? current.length
    const end = textarea?.selectionEnd ?? current.length
    setText(current.slice(0, start) + transcript + current.slice(end))
    requestAnimationFrame(() => {
      textarea?.focus({ preventScroll: true })
      textarea?.setSelectionRange(start + transcript.length, start + transcript.length)
    })
  })

  // 欢迎页导入后会话 ID 不变，不能依赖卸载取消语音；订阅开始事件也覆盖快速完成的导入。
  const cancelVoice = voice.cancel
  useEffect(
    () =>
      useChatStore.subscribe((state, previous) => {
        if (state.importingHistory && !previous.importingHistory) {
          cancelVoice()
        }
      }),
    [cancelVoice]
  )

  // 移动端录音时用频谱替代输入框内容
  const recording = voice.status === 'recording'

  // 排队、上传中或上传失败的附件都留在输入框，全部上传成功后才能发送
  const canSend = !importingHistory && !streaming && voice.status === 'idle' && draftReady

  const send = () => {
    if (
      useChatStore.getState().importingHistory ||
      voice.status !== 'idle' ||
      !prepareDraftMessage(getDraft(sessionId), useUploads.getState().tasks)
    ) {
      return
    }
    // 文本与上传完成态由提交动作读取最新快照，不使用上一次渲染的草稿。
    if (!ensureApiKey() || !sendMessage(sessionId)) {
      return
    }
    stopReadAloud()
    if (isMobile) {
      textareaRef.current?.blur()
    } else {
      textareaRef.current?.focus()
    }
  }

  const fileInputNode = (
    <input
      ref={fileInputRef}
      type="file"
      multiple
      hidden
      accept={ACCEPT}
      onChange={(event) => {
        acceptFiles(Array.from(event.target.files ?? []))
        event.target.value = ''
      }}
    />
  )

  const voiceButtonNode = (
    <VoiceButton
      status={voice.status}
      disabled={!voice.available}
      seconds={voice.seconds}
      onClick={() => {
        if (
          voice.status !== 'idle' ||
          (!useChatStore.getState().importingHistory && ensureApiKey())
        ) {
          void voice.toggle()
        }
      }}
    />
  )

  if (isCompactWatch) {
    const hasActiveTool = thinking || search
    return (
      <div
        className={clsx(
          styles.wrapper,
          sessionId === null ? styles.home : styles.session,
          styles.compactWatch
        )}
      >
        {fileInputNode}
        <DraftAttachments items={attachments} onRetry={retryFile} onRemove={removeFile} />
        {watchToolsOpen ? (
          <div className={styles.watchTools}>
            <button
              type="button"
              className={clsx(styles.toggle, thinking && styles.selected)}
              aria-label={t('thinkingSwitch')}
              aria-pressed={thinking}
              onClick={() => setThinking(!thinking)}
            >
              <IconThinkOutline14 />
            </button>
            <button
              type="button"
              className={clsx(styles.toggle, search && styles.selected)}
              aria-label={t('search')}
              aria-pressed={search}
              onClick={() => setSearch(!search)}
            >
              <IconGlobeLanguageOutline14 />
            </button>
            <button
              type="button"
              className={styles.actionCircle}
              aria-label={t('uploadFile')}
              disabled={importingHistory}
              onClick={() => {
                setWatchToolsOpen(false)
                if (ensureApiKey()) {
                  fileInputRef.current?.click()
                }
              }}
            >
              <IconPlusCircleOutline22 />
            </button>
          </div>
        ) : null}
        <div className={styles.watchBar}>
          <button
            type="button"
            className={clsx(
              styles.actionCircle,
              styles.watchPlusBtn,
              watchToolsOpen && styles.watchPlusOpen
            )}
            aria-label={t('uploadFile')}
            aria-expanded={watchToolsOpen}
            onClick={() => setWatchToolsOpen((open) => !open)}
          >
            <IconPlusCircleOutline22 />
            {hasActiveTool && !watchToolsOpen ? <span className={styles.watchDot} /> : null}
          </button>
          <div className={clsx(styles.textareaWrapper, styles.watchInputWrap)}>
            <textarea
              ref={textareaRef}
              className={clsx(styles.textarea, recording && styles.textareaHidden)}
              placeholder={t('chatInputPlaceholderChat')}
              rows={1}
              enterKeyHint="enter"
              autoFocus={false}
              disabled={importingHistory}
              value={text}
              onFocus={() => setWatchToolsOpen(false)}
              onChange={(event) => setText(event.target.value)}
              onKeyDown={(event) => {
                if (
                  !isMobile &&
                  !isCompactWatch &&
                  !isNativeAndroid() &&
                  !isNativeIos() &&
                  !window.matchMedia('(pointer: coarse)').matches &&
                  event.key === 'Enter' &&
                  !event.shiftKey &&
                  !event.nativeEvent.isComposing
                ) {
                  event.preventDefault()
                  send()
                }
              }}
            />
            {recording ? (
              <Spectrum getAnalyser={voice.getAnalyser} getLevel={voice.getLevel} />
            ) : null}
            <div className={styles.mirror} aria-hidden>
              {`${text}\n`}
            </div>
          </div>
          {streaming && sessionId ? (
            <button
              type="button"
              className={styles.sendButton}
              aria-label={t('chatInputStopButtonTooltip')}
              onClick={() => {
                stopReadAloud()
                stopReply(sessionId)
              }}
            >
              <IconStopFill16 />
            </button>
          ) : canSend ? (
            <button
              type="button"
              className={styles.sendButton}
              aria-label={t('send')}
              onClick={send}
            >
              <IconArrowUpBold16 />
            </button>
          ) : (
            voiceButtonNode
          )}
        </div>
        {dragging ? <DragMask /> : null}
      </div>
    )
  }

  return (
    <div
      className={clsx(styles.wrapper, sessionId === null ? styles.home : styles.session)}
      onClick={(event) => {
        if (event.target === event.currentTarget) {
          textareaRef.current?.focus({ preventScroll: true })
        }
      }}
    >
      <DraftAttachments items={attachments} onRetry={retryFile} onRemove={removeFile} />
      <div className={styles.textareaWrapper}>
        <textarea
          ref={textareaRef}
          className={clsx(styles.textarea, recording && isMobile && styles.textareaHidden)}
          placeholder={t('chatInputPlaceholderChat')}
          rows={2}
          enterKeyHint={
            isMobile ||
            isNativeAndroid() ||
            isNativeIos() ||
            (typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches)
              ? 'enter'
              : 'send'
          }
          // 移动端不自动聚焦，避免一打开就弹出键盘
          autoFocus={!isMobile}
          disabled={importingHistory}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onMouseDown={(event) => {
            // 首次点击时手动聚焦，避免 Safari 把整个页面滚到输入框位置。
            if (isMobile && event.button === 0 && document.activeElement !== event.currentTarget) {
              event.preventDefault()
              event.currentTarget.focus({ preventScroll: true })
            }
          }}
          onKeyDown={(event) => {
            const enterNewline =
              isMobile ||
              isNativeAndroid() ||
              isNativeIos() ||
              window.matchMedia('(pointer: coarse)').matches
            if (
              !enterNewline &&
              event.key === 'Enter' &&
              !event.shiftKey &&
              !event.nativeEvent.isComposing
            ) {
              event.preventDefault()
              send()
            }
          }}
          onPaste={(event) => {
            const files = Array.from(event.clipboardData.files)
            if (files.length > 0) {
              event.preventDefault()
              acceptFiles(files)
            }
          }}
        />
        {recording && isMobile ? (
          <Spectrum getAnalyser={voice.getAnalyser} getLevel={voice.getLevel} />
        ) : null}
        <div className={styles.mirror} aria-hidden>
          {`${text}\n`}
        </div>
      </div>
      <div className={styles.functionRow}>
        {/* 深度思考 / 智能搜索开关，tooltip 在按钮上方 */}
        <div ref={togglesRef} className={styles.toggles}>
          <Tooltip content={t('deactivatedThinkTooltip')}>
            <button
              type="button"
              className={clsx(styles.toggle, thinking && styles.selected)}
              aria-label={t('thinkingSwitch')}
              aria-pressed={thinking}
              onClick={() => setThinking(!thinking)}
            >
              <IconThinkOutline14 />
              <span className={styles.toggleLabel}>{t('thinkingSwitch')}</span>
            </button>
          </Tooltip>
          <Tooltip content={t('deactivatedSearchTooltip')}>
            <button
              type="button"
              className={clsx(styles.toggle, search && styles.selected)}
              aria-label={t('search')}
              aria-pressed={search}
              onClick={() => setSearch(!search)}
            >
              <IconGlobeLanguageOutline14 />
              <span className={styles.toggleLabel}>{t('search')}</span>
            </button>
          </Tooltip>
        </div>
        <div className={styles.right}>
          {fileInputNode}
          {(() => {
            const uploadButton = (
              <Tooltip content={t('uploadFile')}>
                <button
                  type="button"
                  className={styles.actionCircle}
                  aria-label={t('uploadFile')}
                  disabled={importingHistory}
                  onClick={() => {
                    if (ensureApiKey()) {
                      fileInputRef.current?.click()
                    }
                  }}
                >
                  <IconPlusCircleOutline22 />
                </button>
              </Tooltip>
            )
            if (streaming && sessionId) {
              return (
                <>
                  {uploadButton}
                  <button
                    type="button"
                    className={styles.sendButton}
                    aria-label={t('chatInputStopButtonTooltip')}
                    onClick={() => {
                      stopReadAloud()
                      stopReply(sessionId)
                    }}
                  >
                    <IconStopFill16 />
                  </button>
                </>
              )
            }
            if (!canSend && voice.status === 'idle') {
              return (
                <>
                  {uploadButton}
                  {voiceButtonNode}
                </>
              )
            }
            return (
              <>
                {voiceButtonNode}
                {uploadButton}
                <button
                  type="button"
                  className={clsx(styles.sendButton, !canSend && styles.disabled)}
                  aria-label={t('send')}
                  aria-disabled={!canSend}
                  onClick={send}
                >
                  <IconArrowUpBold16 />
                </button>
              </>
            )
          })()}
        </div>
      </div>
      {dragging ? <DragMask /> : null}
    </div>
  )
}
