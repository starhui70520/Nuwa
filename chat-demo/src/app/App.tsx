import clsx from 'clsx'
import { useEffect, useRef, useState } from 'react'
import { useTranslate } from '../i18n/index.js'
import { hasActiveCredential, useSettings } from '../services/settings.js'
import { useIsMobile, useMobileViewport, usePreventPageScroll } from './viewport.js'
import { bindMigrationBridge, runZipImport } from '../services/chat/migrationBridge.js'
import { maybeAutoBackupToIcloud } from '../services/chat/backup.js'
import {
  bindChatPersistence,
  initChat,
  retrySaveSessions,
  selectSession,
  useChatStore,
} from '../services/chat/store.js'
import { MigrationPromptModal } from '../components/onboarding/MigrationPromptModal.js'
import { OnboardingScreen } from '../components/onboarding/OnboardingScreen.js'
import { SearchPanel } from '../components/search/SearchPanel.js'
import { closeSearchPanel, useSearchPanel } from '../components/search/searchPanelState.js'
import { SessionView } from '../components/session/SessionView.js'
import { MobileHeader } from '../components/session/MobileHeader.js'
import { Welcome } from '../components/session/Welcome.js'
import { AppUpdateModal } from '../components/settings/AppUpdateModal.js'
import { SettingsDialog } from '../components/settings/SettingsDialog.js'
import { startAppUpdateWatcher } from '../services/appUpdate.js'
import { Toast } from '../components/base/Toast.js'
import { showToast } from '../components/base/toastState.js'
import { onUploadNotice } from '../services/attachments.js'
import { Button } from '../components/base/Button.js'
import { handleTopModalBack } from '../components/base/Modal.js'
import { stopReadAloud } from '../services/speech/readAloud.js'
import { CollapsedSider } from '../components/sider/CollapsedSider.js'
import {
  closeMobileSider,
  openMobileSider,
  setMobileSiderDrag,
  useMobileSider,
} from '../components/sider/mobileSiderState.js'
import { MobileSider, Sider } from '../components/sider/Sider.js'
import styles from './App.module.css'

export const App = () => {
  const t = useTranslate()
  const isMobile = useIsMobile()
  const locale = useSettings((state) => state.locale)
  const authenticated = useSettings((state) => hasActiveCredential(state))
  const showMigrationPrompt = useSettings((state) => state.showMigrationPrompt)
  // 移动端侧边栏以独立抽屉管理开合状态
  const siderCollapsed = useSettings((state) => state.siderCollapsed) && !isMobile
  const ready = useChatStore((state) => state.ready)
  const initError = useChatStore((state) => state.initError)
  const saveError = useChatStore((state) => Object.values(state.sessionSaveErrors).some(Boolean))
  const importingHistory = useChatStore((state) => state.importingHistory)
  const session = useChatStore((state) =>
    state.activeId !== null && Object.hasOwn(state.sessionCache, state.activeId)
      ? state.sessionCache[state.activeId]
      : undefined
  )
  const sessionLoadError = useChatStore((state) =>
    state.activeId === null ? false : state.sessionLoadErrors[state.activeId] === true
  )
  const frameRef = useMobileViewport(isMobile)
  const streaming = useChatStore((state) =>
    state.activeId === null ? false : Object.hasOwn(state.streaming, state.activeId)
  )
  const activeId = useChatStore((state) => state.activeId)
  const mobileSiderOpen = useMobileSider((state) => state.open)
  const mobileSiderDrag = useMobileSider((state) => state.dragProgress)
  const [zipDragging, setZipDragging] = useState(false)
  const dragDepth = useRef(0)

  // Android 返回键 / 系统侧滑返回：按层级优先关闭最上层弹窗/设置 → 收起侧边栏 → 关闭搜索面板
  useEffect(() => {
    const win = window as Window & { __NUWA_HANDLE_BACK__?: () => boolean }
    win.__NUWA_HANDLE_BACK__ = () => {
      if (handleTopModalBack()) {
        return true
      }
      if (useMobileSider.getState().open) {
        closeMobileSider()
        return true
      }
      if (useSearchPanel.getState().entry !== null) {
        closeSearchPanel()
        return true
      }
      return false
    }
    return () => {
      delete win.__NUWA_HANDLE_BACK__
    }
  }, [])

  // 移动端侧边栏跟手滑动：右滑划入展开，左滑划出收起
  useEffect(() => {
    if (!isMobile || !authenticated) {
      return
    }
    const frame = frameRef.current
    if (!frame) {
      return
    }
    const getDrawerWidth = () => Math.min(window.innerWidth * 0.82, 310)
    const isHorizontallyScrollable = (node: EventTarget | null) => {
      let el = node instanceof HTMLElement ? node : null
      while (el && el !== frame) {
        if (el.scrollWidth > el.clientWidth + 4) {
          const overflowX = getComputedStyle(el).overflowX
          if (overflowX === 'auto' || overflowX === 'scroll') {
            return true
          }
        }
        el = el.parentElement
      }
      return false
    }

    let startX = 0
    let startY = 0
    let startTime = 0
    let initialOpen = false
    let tracking = false
    let dragging = false
    let latestProgress = 0

    const onTouchStart = (event: TouchEvent) => {
      if (event.touches.length !== 1) {
        tracking = false
        return
      }
      // 有弹窗打开时不拦截侧边栏滑动
      if (document.querySelector('[role="dialog"]')) {
        tracking = false
        return
      }
      const touch = event.touches[0]
      initialOpen = useMobileSider.getState().open
      // 关闭态：避免抢占横向滚动代码块/表格，且避开极边缘（<12px）交给系统手势；支持屏幕左侧 12~160px 或非横向滚动区右滑
      if (!initialOpen && isHorizontallyScrollable(event.target)) {
        tracking = false
        return
      }
      startX = touch.clientX
      startY = touch.clientY
      startTime = Date.now()
      tracking = true
      dragging = false
      latestProgress = initialOpen ? 1 : 0
    }

    const onTouchMove = (event: TouchEvent) => {
      if (!tracking || event.touches.length !== 1) {
        return
      }
      const touch = event.touches[0]
      const dx = touch.clientX - startX
      const dy = touch.clientY - startY
      if (!dragging) {
        if (Math.abs(dx) < 12 && Math.abs(dy) < 12) {
          return
        }
        // 纵向滚动为主则放弃横向手势
        if (Math.abs(dx) <= Math.abs(dy) * 1.25) {
          tracking = false
          return
        }
        // 关闭态只认向右滑，打开态只认向左滑
        if ((!initialOpen && dx <= 0) || (initialOpen && dx >= 0)) {
          tracking = false
          return
        }
        dragging = true
      }
      const width = getDrawerWidth()
      latestProgress = initialOpen
        ? Math.max(0, Math.min(1, 1 + dx / width))
        : Math.max(0, Math.min(1, dx / width))
      setMobileSiderDrag(latestProgress)
      if (event.cancelable) {
        event.preventDefault()
      }
    }

    const onTouchEnd = () => {
      if (!dragging) {
        tracking = false
        return
      }
      const elapsed = Math.max(1, Date.now() - startTime)
      const deltaProgress = latestProgress - (initialOpen ? 1 : 0)
      const velocity = (deltaProgress * getDrawerWidth()) / elapsed
      tracking = false
      dragging = false
      if (initialOpen) {
        if (latestProgress < 0.72 || velocity < -0.4) {
          closeMobileSider()
        } else {
          openMobileSider()
        }
      } else if (latestProgress > 0.28 || velocity > 0.4) {
        openMobileSider()
      } else {
        closeMobileSider()
      }
    }

    frame.addEventListener('touchstart', onTouchStart, { passive: true })
    frame.addEventListener('touchmove', onTouchMove, { passive: false })
    frame.addEventListener('touchend', onTouchEnd, { passive: true })
    frame.addEventListener('touchcancel', onTouchEnd, { passive: true })
    return () => {
      frame.removeEventListener('touchstart', onTouchStart)
      frame.removeEventListener('touchmove', onTouchMove)
      frame.removeEventListener('touchend', onTouchEnd)
      frame.removeEventListener('touchcancel', onTouchEnd)
    }
  }, [isMobile, authenticated, frameRef])

  usePreventPageScroll(isMobile)

  useEffect(() => {
    document.documentElement.lang = locale
  }, [locale])

  // 文件数、存储空间达到上限时，附件上只显示「上传失败」，原因用 toast 说明
  useEffect(() => onUploadNotice(showToast), [])
  useEffect(bindChatPersistence, [])

  // 搜索结果面板只属于当前会话
  useEffect(closeSearchPanel, [activeId])
  // 切换会话时停止朗读
  useEffect(stopReadAloud, [activeId])
  // 移动端选中会话、切换布局后收起抽屉
  useEffect(closeMobileSider, [activeId, isMobile])

  useEffect(() => {
    void initChat()
  }, [])

  useEffect(bindMigrationBridge, [])
  useEffect(() => {
    const stopUpdateWatcher = startAppUpdateWatcher()
    void maybeAutoBackupToIcloud()
    return stopUpdateWatcher
  }, [])

  useEffect(() => {
    const isFileDrag = (event: DragEvent) =>
      Array.from(event.dataTransfer?.types ?? []).includes('Files')

    const onDragEnter = (event: DragEvent) => {
      if (!isFileDrag(event)) {
        return
      }
      event.preventDefault()
      dragDepth.current += 1
      setZipDragging(true)
    }

    const onDragOver = (event: DragEvent) => {
      if (isFileDrag(event)) {
        event.preventDefault()
      }
    }

    const onDragLeave = (event: DragEvent) => {
      if (!isFileDrag(event)) {
        return
      }
      dragDepth.current = Math.max(0, dragDepth.current - 1)
      if (dragDepth.current === 0) {
        setZipDragging(false)
      }
    }

    const onDrop = (event: DragEvent) => {
      if (!isFileDrag(event)) {
        return
      }
      dragDepth.current = 0
      setZipDragging(false)
      const files = Array.from(event.dataTransfer?.files ?? [])
      const zip = files.find((file) => file.name.toLowerCase().endsWith('.zip'))
      if (zip) {
        event.preventDefault()
        void runZipImport(zip).catch(() => {})
      }
    }

    window.addEventListener('dragenter', onDragEnter)
    window.addEventListener('dragover', onDragOver)
    window.addEventListener('dragleave', onDragLeave)
    window.addEventListener('drop', onDrop)
    return () => {
      window.removeEventListener('dragenter', onDragEnter)
      window.removeEventListener('dragover', onDragOver)
      window.removeEventListener('dragleave', onDragLeave)
      window.removeEventListener('drop', onDrop)
    }
  }, [])

  if (!authenticated) {
    return (
      <>
        <OnboardingScreen />
        <Toast />
      </>
    )
  }

  return (
    <>
      <div ref={frameRef} className={styles.frame}>
        {isMobile ? <MobileSider /> : siderCollapsed ? null : <Sider />}
        <main
          className={clsx(
            styles.main,
            isMobile && mobileSiderOpen && mobileSiderDrag === null && styles.mainPushed,
            isMobile && mobileSiderDrag !== null && styles.mainDragging
          )}
          style={
            isMobile && mobileSiderDrag !== null
              ? {
                  transform: `translateX(${mobileSiderDrag * Math.min(window.innerWidth * 0.82, 310)}px) scale(${1 - 0.05 * mobileSiderDrag})`,
                  borderRadius: `${24 * mobileSiderDrag}px`,
                }
              : undefined
          }
        >
          {isMobile && mobileSiderOpen ? (
            <div className={styles.pushedShield} onClick={closeMobileSider} />
          ) : null}
          {importingHistory ? (
            <div className={styles.importingBanner} role="status" aria-live="polite">
              <span>{t('importingHistoryBanner')}</span>
            </div>
          ) : null}
          {saveError ? (
            <div className={styles.saveError} role="alert">
              <span>{t('sessionSaveFailed')}</span>
              <Button
                variant="outlined"
                size="s"
                disabled={importingHistory}
                onClick={retrySaveSessions}
              >
                {t('retry')}
              </Button>
            </div>
          ) : null}
          <div className={styles.content}>
            {siderCollapsed ? <CollapsedSider /> : null}
            {!ready || (activeId !== null && !session) ? (
              <div className={styles.loadingView}>
                {isMobile ? <MobileHeader /> : null}
                <div className={styles.loadingState} role="status" aria-live="polite">
                  <span>
                    {(!ready ? initError : sessionLoadError)
                      ? t(!ready ? 'sessionListLoadFailed' : 'sessionLoadFailed')
                      : t('sessionLoading')}
                  </span>
                  {(!ready ? initError : sessionLoadError) ? (
                    <Button
                      variant="outlined"
                      size="m"
                      onClick={() => {
                        if (!ready) {
                          void initChat()
                        } else if (activeId !== null) {
                          selectSession(activeId)
                        }
                      }}
                    >
                      {t('retry')}
                    </Button>
                  ) : null}
                </div>
              </div>
            ) : session ? (
              <SessionView
                session={session}
                streaming={streaming}
                siderCollapsed={siderCollapsed}
              />
            ) : (
              <Welcome />
            )}
          </div>
        </main>
        <SearchPanel />
      </div>
      {showMigrationPrompt ? <MigrationPromptModal /> : null}
      <SettingsDialog />
      <AppUpdateModal />
      <Toast />
      {zipDragging ? (
        <div className={styles.dropOverlay}>
          <div className={styles.dropCard}>{t('migrationDropOverlay')}</div>
        </div>
      ) : null}
    </>
  )
}
