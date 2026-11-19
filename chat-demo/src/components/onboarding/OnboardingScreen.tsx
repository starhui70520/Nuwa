import clsx from 'clsx'
import { useState } from 'react'
import logoUrl from '../../assets/logo.png'
import { useTranslate } from '../../i18n/index.js'
import {
  PlatformAuthUnavailableError,
  startDeepSeekAccountLogin,
} from '../../services/api/dshAuth.js'
import { isLegacyWebView } from '../../services/nativeBridge.js'
import {
  setApiBaseUrl,
  setApiModel,
  setApiProtocol,
  useSettings,
  type ApiProtocol,
} from '../../services/settings.js'
import { Select } from '../base/Select.js'
import { showToast } from '../base/toastState.js'
import { useApiKeyForm } from '../settings/useApiKeyForm.js'
import styles from './OnboardingScreen.module.css'

type OnboardingView = 'home' | 'deepseek-key' | 'third-party'

const DOCS_URL = 'https://api-docs.deepseek.com/zh-cn/'
const PLATFORM_KEYS_URL = 'https://platform.deepseek.com/api_keys'

export const OnboardingScreen = () => {
  const t = useTranslate()
  const [view, setView] = useState<OnboardingView>('home')
  const [authorizing, setAuthorizing] = useState(false)
  const apiProtocol = useSettings((state) => state.apiProtocol)
  const apiBaseUrl = useSettings((state) => state.apiBaseUrl)
  const apiModel = useSettings((state) => state.apiModel)
  const form = useApiKeyForm()
  const legacyWebView = isLegacyWebView()

  const enterDeepSeekKeyView = () => {
    setApiProtocol('anthropic')
    setApiBaseUrl('https://api.deepseek.com')
    setApiModel('deepseek-flash')
    setView('deepseek-key')
  }

  const onDeepSeekAccountClick = async () => {
    if (authorizing) {
      return
    }
    setAuthorizing(true)
    try {
      await startDeepSeekAccountLogin()
    } catch (error) {
      if (error instanceof PlatformAuthUnavailableError) {
        window.open(PLATFORM_KEYS_URL, '_blank', 'noopener,noreferrer')
        enterDeepSeekKeyView()
        showToast({ key: 'onboardingWebFallbackHint' })
      } else {
        showToast({
          key: 'apiKeyVerificationFailed',
          params: { message: error instanceof Error ? error.message : String(error) },
          type: 'error',
        })
      }
    } finally {
      setAuthorizing(false)
    }
  }

  return (
    <div className={styles.screen}>
      <div className={styles.topBar}>
        {view === 'home' ? (
          <span />
        ) : (
          <button type="button" className={styles.topAction} onClick={() => setView('home')}>
            ← {t('dshBack')}
          </button>
        )}
        <a
          className={styles.topAction}
          href={DOCS_URL}
          target="_blank"
          rel="noopener noreferrer"
        >
          {t('dshHelp')}
        </a>
      </div>

      <div className={styles.hero}>
        <img src={logoUrl} alt="Nuwa" className={styles.heroLogo} />
        <div className={styles.heroTitle}>{t('appName')}</div>
      </div>

      <div className={styles.bottom}>
        {view === 'home' ? (
          <>
            {!legacyWebView ? (
              <button
                type="button"
                className={clsx(styles.pillButton, styles.pillPrimary)}
                disabled={authorizing}
                onClick={() => void onDeepSeekAccountClick()}
              >
                {t('onboardingLoginDeepSeekAccount')}
              </button>
            ) : null}
            <button
              type="button"
              className={clsx(styles.pillButton, legacyWebView && styles.pillPrimary)}
              onClick={enterDeepSeekKeyView}
            >
              {t('onboardingUseDeepSeekKey')}
            </button>
            <button
              type="button"
              className={styles.pillButton}
              onClick={() => setView('third-party')}
            >
              {t('onboardingUseThirdParty')}
            </button>
          </>
        ) : (
          <div className={styles.formGroup}>
            {view === 'third-party' ? (
              <>
                <div className={styles.rowBetween}>
                  <span className={styles.fieldLabel}>{t('apiProtocolLabel')}</span>
                  <Select
                    ariaLabel={t('apiProtocolLabel')}
                    value={apiProtocol}
                    options={[
                      { value: 'openai', label: t('apiProtocolOpenAI') },
                      { value: 'anthropic', label: t('apiProtocolAnthropic') },
                    ]}
                    onChange={(value) => setApiProtocol(value as ApiProtocol)}
                  />
                </div>
                <div className={styles.field}>
                  <div className={styles.fieldLabel}>{t('apiBaseUrlLabel')}</div>
                  <div className={styles.inputPill}>
                    <input
                      type="url"
                      placeholder={t('apiBaseUrlPlaceholder')}
                      autoComplete="off"
                      spellCheck={false}
                      value={apiBaseUrl}
                      onChange={(event) => setApiBaseUrl(event.target.value)}
                    />
                  </div>
                </div>
                <div className={styles.field}>
                  <div className={styles.fieldLabel}>{t('apiModelLabel')}</div>
                  <div className={styles.inputPill}>
                    <input
                      type="text"
                      placeholder={t('apiModelPlaceholder')}
                      autoComplete="off"
                      spellCheck={false}
                      value={apiModel}
                      onChange={(event) => setApiModel(event.target.value)}
                    />
                  </div>
                </div>
              </>
            ) : null}

            <div className={styles.field}>
              <div className={styles.fieldLabel}>API Key</div>
              <div className={styles.inputPill}>
                <input
                  type="password"
                  placeholder={t('apiKeyPlaceholder')}
                  autoComplete="off"
                  spellCheck={false}
                  value={form.value}
                  onChange={(event) => form.setValue(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                      void form.submit()
                    }
                  }}
                />
              </div>
            </div>

            {form.error ? <div className={styles.errorText}>{form.error}</div> : null}

            <button
              type="button"
              className={clsx(styles.pillButton, styles.pillPrimary)}
              disabled={form.verifying || !form.value.trim()}
              onClick={() => void form.submit()}
            >
              {form.verifying ? t('apiKeyVerifying') : t('onboardingVerifyAndContinue')}
            </button>

            {view === 'deepseek-key' ? (
              <a
                className={styles.helperLink}
                href={PLATFORM_KEYS_URL}
                target="_blank"
                rel="noopener noreferrer"
              >
                {t('onboardingGetKeyLink')}
              </a>
            ) : null}
          </div>
        )}
        <div className={styles.footerNote}>{t('onboardingFooterNote')}</div>
      </div>
    </div>
  )
}
