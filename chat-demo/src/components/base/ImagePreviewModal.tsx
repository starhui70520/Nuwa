import clsx from 'clsx'
import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { IconCloseOutline16 } from './icons.js'
import styles from './ImagePreviewModal.module.css'
import { registerModalBackHandler } from './Modal.js'

type AspectKind = 'normal' | 'tall' | 'wide'

/**
 * 全屏应用内图片预览器：
 * - 替代 <a target="_blank">，避免移动端 WebView 跳到 blob: 页面后无法退出、按返回键直接回桌面；
 * - 注册到全局弹窗返回栈（Android 物理返回/侧滑返回 & Esc 键均优先关闭预览）；
 * - 适配超长竖图与超宽横图的放大滚动查看。
 */
export const ImagePreviewModal = ({
  src,
  name,
  onClose,
}: {
  src: string
  name: string
  onClose: () => void
}) => {
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  const [zoomed, setZoomed] = useState(false)
  const [aspectKind, setAspectKind] = useState<AspectKind>('normal')

  useEffect(() => registerModalBackHandler(() => onCloseRef.current()), [])

  const imageClassName = !zoomed
    ? styles.imgFit
    : aspectKind === 'tall'
      ? styles.imgZoomedTall
      : aspectKind === 'wide'
        ? styles.imgZoomedWide
        : styles.imgZoomedNormal

  const stageClassName = clsx(
    styles.stage,
    zoomed && (aspectKind === 'tall' ? styles.stageZoomedTall : styles.stageZoomed)
  )

  return createPortal(
    <div className={styles.backdrop} role="dialog" aria-modal="true" aria-label={name}>
      <div className={styles.topBar}>
        <span className={styles.fileName}>{name}</span>
        <button
          type="button"
          className={styles.closeBtn}
          aria-label="关闭预览"
          onClick={onClose}
        >
          <IconCloseOutline16 />
        </button>
      </div>

      <div
        className={stageClassName}
        onClick={(event) => {
          if (event.target === event.currentTarget) {
            onClose()
          }
        }}
      >
        <img
          src={src}
          alt={name}
          className={imageClassName}
          onLoad={(event) => {
            const { naturalWidth, naturalHeight } = event.currentTarget
            if (naturalWidth > 0 && naturalHeight > 0) {
              if (naturalHeight > naturalWidth * 1.6) {
                setAspectKind('tall')
              } else if (naturalWidth > naturalHeight * 1.6) {
                setAspectKind('wide')
              } else {
                setAspectKind('normal')
              }
            }
          }}
          onClick={() => setZoomed((prev) => !prev)}
        />
      </div>

      <div className={styles.bottomBar}>
        <button
          type="button"
          className={styles.pillBtn}
          onClick={() => setZoomed((prev) => !prev)}
        >
          {zoomed ? '适应屏幕' : '放大查看'}
        </button>
        <button type="button" className={styles.pillBtn} onClick={onClose}>
          关闭
        </button>
      </div>
    </div>,
    document.body
  )
}
