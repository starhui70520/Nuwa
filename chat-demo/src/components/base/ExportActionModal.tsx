import { useTranslate } from '../../i18n/index.js'
import type { ExportDestination } from '../../services/chat/backup.js'
import { Button } from './Button.js'
import styles from './ExportActionModal.module.css'
import { IconDownloadOutline16, IconUploadOutline14 } from './icons.js'
import { Modal } from './Modal.js'

/** 导出方式选择弹窗：1. 发送到其他软件（系统分享） 2. 保存到本机 */
export const ExportActionModal = ({
  title,
  busy = false,
  activeMode = null,
  onSelect,
  onClose,
}: {
  title: string
  busy?: boolean
  activeMode?: ExportDestination | null
  onSelect: (mode: ExportDestination) => void
  onClose: () => void
}) => {
  const t = useTranslate()

  return (
    <Modal
      title={title}
      className={styles.modal}
      onClose={() => {
        if (!busy) {
          onClose()
        }
      }}
      footer={
        <Button variant="outlined" size="m" disabled={busy} onClick={onClose}>
          {t('cancel')}
        </Button>
      }
    >
      <div className={styles.options}>
        <button
          type="button"
          className={styles.optionBtn}
          disabled={busy}
          onClick={() => onSelect('share')}
        >
          <span className={styles.optionIcon} aria-hidden="true">
            <IconUploadOutline14 />
          </span>
          <span className={styles.optionBody}>
            <span className={styles.optionTitle}>
              {busy && activeMode === 'share' ? t('exporting') : t('exportOptionShare')}
            </span>
            <span className={styles.optionDesc}>{t('exportOptionShareDesc')}</span>
          </span>
        </button>

        <button
          type="button"
          className={styles.optionBtn}
          disabled={busy}
          onClick={() => onSelect('save')}
        >
          <span className={styles.optionIcon} aria-hidden="true">
            <IconDownloadOutline16 />
          </span>
          <span className={styles.optionBody}>
            <span className={styles.optionTitle}>
              {busy && activeMode === 'save' ? t('exporting') : t('exportOptionSave')}
            </span>
            <span className={styles.optionDesc}>{t('exportOptionSaveDesc')}</span>
          </span>
        </button>
      </div>
    </Modal>
  )
}
