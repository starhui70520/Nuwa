import { useTranslate } from '../../i18n/index.js'
import { useAppUpdateStore } from '../../services/appUpdate.js'
import { isNativeAndroid } from '../../services/nativeBridge.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import styles from './AppUpdateModal.module.css'

export const AppUpdateModal = () => {
  const t = useTranslate()
  const modalUpdate = useAppUpdateStore((state) => state.modalUpdate)
  const downloading = useAppUpdateStore((state) => state.downloading)
  const progress = useAppUpdateStore((state) => state.progress)
  const closeModal = useAppUpdateStore((state) => state.closeModal)
  const installUpdate = useAppUpdateStore((state) => state.installUpdate)

  if (!modalUpdate) {
    return null
  }

  const canDirectInstall = isNativeAndroid() && Boolean(modalUpdate.apkUrl)

  return (
    <Modal
      title={t('updateModalTitle', { version: modalUpdate.latestVersion })}
      className={styles.modal}
      closable={!downloading}
      onClose={closeModal}
    >
      <div className={styles.body}>
        <div className={styles.meta}>
          <div>{t('updateCurrentVersion', { version: modalUpdate.currentVersion })}</div>
          <div>{t('updateLatestVersion', { version: modalUpdate.latestVersion })}</div>
        </div>
        <div className={styles.notes}>{modalUpdate.notes || t('updateNoNotes')}</div>
        {downloading ? (
          <div className={styles.progressWrap}>
            <div className={styles.progressTrack}>
              <div className={styles.progressBar} style={{ width: `${progress}%` }} />
            </div>
            <div className={styles.progressText}>{t('updateDownloading', { progress })}</div>
          </div>
        ) : null}
        <div className={styles.actions}>
          <Button variant="outlined" disabled={downloading} onClick={closeModal}>
            {t('updateLater')}
          </Button>
          <Button
            variant="primary"
            disabled={downloading}
            onClick={() => void installUpdate()}
          >
            {downloading
              ? t('updateDownloading', { progress })
              : canDirectInstall
                ? t('updateNow')
                : t('updateOpenRelease')}
          </Button>
        </div>
      </div>
    </Modal>
  )
}
