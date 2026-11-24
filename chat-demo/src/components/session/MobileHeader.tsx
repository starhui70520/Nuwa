import type { ReactNode } from 'react'
import { useTranslate } from '../../i18n/index.js'
import { newChat } from '../../services/chat/store.js'
import { setTtsMuted, useSettings } from '../../services/settings.js'
import { stopReadAloud, useReadAloud } from '../../services/speech/readAloud.js'
import {
  IconNativeMenu20,
  IconNewChatBubble20,
  IconSpeakerMutedOutline20,
  IconSpeakerOutline20,
} from '../base/icons.js'
import { showToast } from '../base/toastState.js'
import { openMobileSider } from '../sider/mobileSiderState.js'
import styles from './MobileHeader.module.css'

/** 移动端顶栏：左上角悬浮圆形菜单按钮 + 中间标题 + 右上角朗读静音与新对话悬浮胶囊 */
export const MobileHeader = ({
  title,
  onTitleTap,
  statusSlot,
}: {
  title?: string
  onTitleTap?: () => void
  statusSlot?: ReactNode
}) => {
  const t = useTranslate()
  const reading = useReadAloud((state) => state.status !== 'idle')
  const ttsMuted = useSettings((state) => state.ttsMuted)
  const speakerActive = reading || !ttsMuted

  const onToggleSpeaker = () => {
    if (reading) {
      stopReadAloud()
      setTtsMuted(true)
      return
    }
    const next = !ttsMuted
    setTtsMuted(next)
    showToast({ key: next ? 'ttsMuteToggleOn' : 'ttsMuteToggleOff' })
  }

  return (
    <div className={styles.header}>
      <button
        type="button"
        className={styles.circleButton}
        aria-label={t('expandSiderbarButton')}
        onClick={openMobileSider}
      >
        <IconNativeMenu20 />
      </button>
      {title !== undefined ? (
        <div className={styles.title} onClick={onTitleTap}>
          {title}
        </div>
      ) : (
        <div className={styles.spacer} />
      )}
      <div className={styles.capsule}>
        {statusSlot}
        <button
          type="button"
          className={styles.capsuleAction}
          aria-label={
            reading ? t('ttsStop') : ttsMuted ? t('ttsMuteToggleOff') : t('ttsMuteToggleOn')
          }
          onClick={onToggleSpeaker}
        >
          {speakerActive ? <IconSpeakerOutline20 /> : <IconSpeakerMutedOutline20 />}
        </button>
        <button
          type="button"
          className={styles.capsuleAction}
          aria-label={t('newChat')}
          onClick={() => {
            newChat()
          }}
        >
          <IconNewChatBubble20 />
        </button>
      </div>
    </div>
  )
}
