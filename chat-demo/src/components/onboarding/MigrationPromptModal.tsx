import { useRef } from 'react'
import logoUrl from '../../assets/logo.png'
import { useTranslate } from '../../i18n/index.js'
import { runZipImport, triggerOneClickMigration } from '../../services/chat/migrationBridge.js'
import { dismissMigrationPrompt } from '../../services/settings.js'
import { Button } from '../base/Button.js'
import { Modal } from '../base/Modal.js'
import styles from './MigrationPromptModal.module.css'

export const MigrationPromptModal = () => {
  const t = useTranslate()
  const fileRef = useRef<HTMLInputElement>(null)

  return (
    <Modal title={t('migrationPromptTitle')} className={styles.modal} onClose={dismissMigrationPrompt}>
      <div className={styles.body}>
        <img src={logoUrl} alt="Nuwa" className={styles.logo} />
        <div className={styles.description}>{t('migrationPromptDescription')}</div>
        <div className={styles.actions}>
          <Button
            variant="primary"
            block
            onClick={() => {
              dismissMigrationPrompt()
              void triggerOneClickMigration().catch(() => {})
            }}
          >
            {t('migrationPromptOneClick')}
          </Button>
          <Button variant="outlined" block onClick={() => fileRef.current?.click()}>
            {t('migrationPromptUploadZip')}
          </Button>
          <Button variant="outlined" block onClick={dismissMigrationPrompt}>
            {t('migrationPromptLater')}
          </Button>
        </div>
        <input
          ref={fileRef}
          type="file"
          accept=".zip,application/zip,application/x-zip-compressed"
          hidden
          onChange={(event) => {
            const file = event.target.files?.[0]
            event.target.value = ''
            if (file) {
              dismissMigrationPrompt()
              void runZipImport(file).catch(() => {})
            }
          }}
        />
      </div>
    </Modal>
  )
}
