import clsx from 'clsx'
import { useEffect, useId, useRef, type CSSProperties, type ReactNode, type Ref } from 'react'
import { createPortal } from 'react-dom'
import { useTranslate } from '../../i18n/index.js'
import { IconCloseOutline16 } from './icons.js'
import { IconButton } from './IconButton.js'
import styles from './Modal.module.css'

/** 当前打开的弹窗，后打开的在末尾；叠放时 Esc / 系统返回键只作用于最上层 */
const openModals: { token: object; onBack: () => void }[] = []

/** 供 Android 物理返回键/侧滑返回调用：消费最上层弹窗返回 true，无弹窗返回 false */
export const handleTopModalBack = (): boolean => {
  const top = openModals.at(-1)
  if (!top) {
    return false
  }
  top.onBack()
  return true
}

/** 遮罩 + 居中卡片，Esc / 点遮罩关闭 */
export const Modal = ({
  title,
  children,
  footer,
  closable = false,
  hideHeader = false,
  className,
  overlayClassName,
  overlayStyle,
  contentStyle,
  contentRef,
  mainClassName,
  onClose,
  onBack,
}: {
  title: ReactNode
  children?: ReactNode
  footer?: ReactNode
  /** 标题栏右侧显示关闭按钮 */
  closable?: boolean
  /** 隐藏默认标题栏，由调用方自定义头部 */
  hideHeader?: boolean
  className?: string
  overlayClassName?: string
  overlayStyle?: CSSProperties
  contentStyle?: CSSProperties
  contentRef?: Ref<HTMLDivElement>
  /** 内容区的 class */
  mainClassName?: string
  onClose: () => void
  /** Esc / 手机返回键回调；不传时默认调用 onClose */
  onBack?: () => void
}) => {
  const t = useTranslate()
  const titleId = useId()
  const onBackRef = useRef(onBack ?? onClose)
  onBackRef.current = onBack ?? onClose
  useEffect(() => {
    const entry = { token: {}, onBack: () => onBackRef.current() }
    openModals.push(entry)
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && openModals.at(-1) === entry) {
        onBackRef.current()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      const idx = openModals.indexOf(entry)
      if (idx >= 0) {
        openModals.splice(idx, 1)
      }
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [])

  return createPortal(
    <div
      className={clsx(styles.overlay, overlayClassName)}
      style={overlayStyle}
      onMouseDown={(event) => event.target === event.currentTarget && onClose()}
    >
      <div
        ref={contentRef}
        className={clsx(styles.content, className)}
        style={contentStyle}
        role="dialog"
        aria-modal="true"
        aria-labelledby={hideHeader ? undefined : titleId}
        aria-label={hideHeader && typeof title === 'string' ? title : undefined}
      >
        {hideHeader ? null : (
          <div className={styles.header}>
            <div id={titleId} className={styles.title}>
              {title}
            </div>
            {closable ? (
              <IconButton
                className={styles.close}
                tone="primary"
                icon={<IconCloseOutline16 />}
                aria-label={t('close')}
                onClick={onClose}
              />
            ) : null}
          </div>
        )}
        {children ? <div className={clsx(styles.main, mainClassName)}>{children}</div> : null}
        {footer ? <div className={styles.footer}>{footer}</div> : null}
      </div>
    </div>,
    document.body
  )
}
