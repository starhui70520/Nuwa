import clsx from 'clsx'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useIsMobile } from '../../app/viewport.js'
import { useTranslate, type TranslationKey, type TranslationMessage } from '../../i18n/index.js'
import {
  fetchReleaseHistory,
  getCurrentAppVersion,
  getWebAppVersion,
  useAppUpdateStore,
  type ReleaseHistoryItem,
} from '../../services/appUpdate.js'
import {
  logoutDeepSeekAccount,
  PlatformAuthUnavailableError,
  startDeepSeekAccountLogin,
} from '../../services/api/dshAuth.js'
import {
  BackupError,
  clearHistory,
  exportHistory,
  importHistory,
  maybeAutoBackupToIcloud,
} from '../../services/chat/backup.js'
import { triggerOneClickMigration } from '../../services/chat/migrationBridge.js'
import { useChatStore } from '../../services/chat/store.js'
import { getRegionName, provinces, regionCodes } from '../../services/location.js'
import {
  CHAT_FONT_SIZES,
  DEFAULT_CHAT_FONT_SIZE,
  isChineseBrowser,
  isUsingDeepSeekAccount,
  setApiBaseUrl,
  setApiKey,
  setApiModel,
  setApiProtocol,
  setAuthMode,
  setChatFontSize,
  setIcloudAutoBackup,
  setLocale,
  setLocation,
  setSpeechEngine,
  setThemePreference,
  setTtsVoice,
  useSettings,
  type ApiProtocol,
  type ChatFontSize,
  type SpeechEngine,
  type ThemePreference,
} from '../../services/settings.js'
import { DeepSeekMigration, isNativeAndroid, isNativeIos } from '../../services/nativeBridge.js'
import { handleExternalAnchorClick } from '../../services/externalLink.js'
import { Button } from '../base/Button.js'
import {
  IconChevronLeftOutline18,
  IconChevronRightOutline14,
  IconCloseOutline16,
  IconDataOutline16,
  IconDocOutline18,
  IconDownloadOutline16,
  IconFontSizeOutline18,
  IconGlobeOutline18,
  IconInfoCircleOutline18,
  IconLogoutOutline18,
  IconSparkleOutline18,
  IconSunOutline18,
  IconUploadOutline14,
  IconUserOutline18,
  IconVolumeOutline18,
} from '../base/icons.js'
import { Modal } from '../base/Modal.js'
import { Select } from '../base/Select.js'
import { showToast } from '../base/toastState.js'
import { ApiKeyConfirm, ApiKeyField, useApiKeyEditor } from './ApiKeyField.js'
import styles from './Settings.module.css'
import { closeSettings, useSettingsDialog } from './settingsDialogState.js'

type SettingsPage = 'root' | 'account' | 'data' | 'changelog'

const DOCS_URL = 'https://api-docs.deepseek.com/zh-cn/'

/**
 * 原生 DeepSeek 风格设置面板：
 * - 根页面按「账户 / 应用 / 语音 / 关于 / 退出登录」分组卡片呈现；
 * - 点击「账号管理」「数据管理」进入子页，左上角提供返回按钮。
 */
export const SettingsDialog = () => {
  const open = useSettingsDialog((state) => state.open)
  return open ? <SettingsContent /> : null
}

const SettingsContent = () => {
  const t = useTranslate()
  const isMobile = useIsMobile()
  const initialSection = useSettingsDialog.getState().section
  const [page, setPage] = useState<SettingsPage>(() =>
    initialSection === 'general' ? 'root' : initialSection
  )
  const apiKeyEditor = useApiKeyEditor()
  const historyImport = useHistoryImport()
  const historyDelete = useHistoryDelete()
  const replacingHistory = useChatStore((state) => state.importingHistory)
  const sessionCount = useChatStore((state) => state.sessions.length)
  const isAccount = useSettings((state) => isUsingDeepSeekAccount(state))
  const dshAccountLabel = useSettings((state) => state.dshAccountLabel)
  const apiModel = useSettings((state) => state.apiModel)
  const historyBusy = historyImport.busy || historyDelete.busy || replacingHistory
  const [appVersion, setAppVersion] = useState(getWebAppVersion)
  const checkingUpdate = useAppUpdateStore((state) => state.checking)
  const checkForUpdates = useAppUpdateStore((state) => state.checkForUpdates)
  const harmonyBridge = typeof window === 'undefined' ? undefined : window.__NUWA_HARMONY__

  useEffect(() => {
    void getCurrentAppVersion().then(setAppVersion)
  }, [])

  const accountSummary = isAccount
    ? dshAccountLabel || t('dshAccountLabel')
    : apiModel.trim() || t('settingsApiKeyMode')

  const pageTitle =
    page === 'account'
      ? t('settingsAccountManage')
      : page === 'data'
        ? t('settingsDataManage')
        : page === 'changelog'
          ? t('settingsReleaseNotes')
          : t('settings')

  const onSignOutAll = () => {
    void logoutDeepSeekAccount()
    setApiKey(null)
    closeSettings()
  }

  return (
    <>
      <Modal
        title={pageTitle}
        hideHeader
        className={styles.dialog}
        mainClassName={styles.dialogMain}
        onClose={() => {
          if (!historyDelete.busy) {
            closeSettings()
          }
        }}
      >
        <div className={styles.sheetHeader}>
          {page === 'root' ? (
            <span className={styles.headerSpacer} />
          ) : (
            <button
              type="button"
              className={styles.headerButton}
              aria-label={t('dshBack')}
              onClick={() => setPage('root')}
            >
              <IconChevronLeftOutline18 />
            </button>
          )}
          <div className={styles.sheetTitle}>{pageTitle}</div>
          <button
            type="button"
            className={styles.headerButton}
            aria-label={t('close')}
            onClick={() => {
              if (!historyDelete.busy) {
                closeSettings()
              }
            }}
          >
            <IconCloseOutline16 />
          </button>
        </div>

        <div className={styles.content}>
          {page === 'root' ? (
            <>
              <div className={styles.groupTitle}>{t('settingsGroupAccount')}</div>
              <div className={styles.groupCard}>
                <button
                  type="button"
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  onClick={() => setPage('account')}
                >
                  <span className={styles.rowIcon}>
                    <IconUserOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsAccountManage')}</span>
                  <span className={styles.rowValue}>{accountSummary}</span>
                  <span className={styles.rowChevron}>
                    <IconChevronRightOutline14 />
                  </span>
                </button>
                <button
                  type="button"
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  onClick={() => setPage('data')}
                >
                  <span className={styles.rowIcon}>
                    <IconDataOutline16 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsDataManage')}</span>
                  <span className={styles.rowValue}>
                    {t('settingsSessionCount', { count: sessionCount })}
                  </span>
                  <span className={styles.rowChevron}>
                    <IconChevronRightOutline14 />
                  </span>
                </button>
              </div>

              <div className={styles.groupTitle}>{t('settingsGroupApp')}</div>
              <div className={styles.groupCard}>
                <div className={styles.groupRow}>
                  <span className={styles.rowIcon}>
                    <IconGlobeOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsLocalePreference')}</span>
                  <LocaleInlineSelect />
                </div>
                <div className={styles.groupRow}>
                  <span className={styles.rowIcon}>
                    <IconSunOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsAppearance')}</span>
                  <AppearanceInlineSelect />
                </div>
                <div className={styles.groupRow}>
                  <span className={styles.rowIcon}>
                    <IconFontSizeOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsFontSize')}</span>
                  <FontSizeInlineSelect />
                </div>
                <div className={clsx(styles.groupRow, styles.locationGroupRow)}>
                  <span className={styles.rowIcon}>
                    <IconSparkleOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsLocation')}</span>
                  <LocationInlineSelect />
                </div>
              </div>

              <div className={styles.groupTitle}>{t('settingsGroupVoice')}</div>
              <div className={styles.groupCard}>
                {harmonyBridge ? (
                  <div className={styles.groupRow}>
                    <span className={styles.rowIcon}>
                      <IconVolumeOutline18 />
                    </span>
                    <span className={styles.rowLabel}>{t('settingsSpeechEngine')}</span>
                    <span className={styles.rowValue}>{t('settingsSpeechEngineNative')}</span>
                  </div>
                ) : (
                  <>
                    <div className={styles.groupRow}>
                      <span className={styles.rowIcon}>
                        <IconVolumeOutline18 />
                      </span>
                      <span className={styles.rowLabel}>{t('settingsTtsVoice')}</span>
                      <TtsVoiceInlineSelect />
                    </div>
                    <SpeechEngineRow />
                    <AndroidSpeechServiceRow />
                  </>
                )}
              </div>
              <div className={styles.groupFooter}>
                {t(harmonyBridge ? 'settingsHarmonyVoiceHint' : 'settingsVoiceHint')}
              </div>

              <div className={styles.groupTitle}>{t('settingsGroupAbout')}</div>
              <div className={styles.groupCard}>
                <div className={styles.groupRow}>
                  <span className={styles.rowIcon}>
                    <IconInfoCircleOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsVersion')}</span>
                  <span className={styles.rowValue}>{appVersion}</span>
                </div>
                <button
                  type="button"
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  disabled={checkingUpdate}
                  onClick={() => void checkForUpdates()}
                >
                  <span className={styles.rowIcon}>
                    <IconDownloadOutline16 />
                  </span>
                  <span className={styles.rowLabel}>
                    {checkingUpdate ? t('settingsCheckingUpdate') : t('settingsCheckUpdate')}
                  </span>
                  <span className={styles.rowChevron}>
                    <IconChevronRightOutline14 />
                  </span>
                </button>
                <button
                  type="button"
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  onClick={() => setPage('changelog')}
                >
                  <span className={styles.rowIcon}>
                    <IconDocOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsReleaseNotes')}</span>
                  <span className={styles.rowChevron}>
                    <IconChevronRightOutline14 />
                  </span>
                </button>
                {harmonyBridge?.openPrivacyPolicy && (
                  <button
                    type="button"
                    className={clsx(styles.groupRow, styles.groupRowButton)}
                    onClick={() => harmonyBridge.openPrivacyPolicy?.()}
                  >
                    <span className={styles.rowIcon}>
                      <IconDocOutline18 />
                    </span>
                    <span className={styles.rowLabel}>{t('settingsPrivacyPolicy')}</span>
                    <span className={styles.rowChevron}>
                      <IconChevronRightOutline14 />
                    </span>
                  </button>
                )}
                <a
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  href={DOCS_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  onClick={(event) => handleExternalAnchorClick(event, DOCS_URL)}
                >
                  <span className={styles.rowIcon}>
                    <IconDocOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsDocs')}</span>
                  <span className={styles.rowChevron}>
                    <IconChevronRightOutline14 />
                  </span>
                </a>
              </div>

              <div className={clsx(styles.groupCard, styles.signOutCard)}>
                <button
                  type="button"
                  className={clsx(styles.groupRow, styles.groupRowButton)}
                  onClick={onSignOutAll}
                >
                  <span className={styles.rowIcon}>
                    <IconLogoutOutline18 />
                  </span>
                  <span className={styles.rowLabel}>{t('settingsSignOut')}</span>
                </button>
              </div>
            </>
          ) : page === 'account' ? (
            <>
              <div className={styles.groupCard}>
                <DeepSeekAccountSetting />
              </div>
              <div className={clsx(styles.groupCard, styles.cardGap)}>
                <ApiProviderSettings />
                <ApiKeyField editor={apiKeyEditor} />
              </div>
              {isMobile ? <ApiKeyConfirm editor={apiKeyEditor} /> : null}
            </>
          ) : page === 'changelog' ? (
            <ReleaseNotesPage />
          ) : (
            <>
              <div className={styles.groupCard}>
                <OneClickMigrateSetting disabled={historyBusy} />
                <ImportHistory historyImport={historyImport} disabled={historyBusy} />
                <ExportHistory disabled={historyBusy} />
                {isNativeIos() ? <IcloudAutoBackup disabled={historyBusy} /> : null}
              </div>
              <div className={clsx(styles.groupCard, styles.cardGap)}>
                <SettingCell
                  label={t('deleteAllSessions')}
                  status={null}
                  action={
                    <Button
                      variant="dangerOutlined"
                      size="m"
                      className={styles.cellButton}
                      disabled={historyBusy}
                      onClick={historyDelete.open}
                    >
                      {t('delete')}
                    </Button>
                  }
                />
              </div>
            </>
          )}
        </div>
      </Modal>
      {historyImport.file ? <ImportConfirm historyImport={historyImport} /> : null}
      {historyDelete.opened ? <DeleteAllConfirm historyDelete={historyDelete} /> : null}
    </>
  )
}

const formatReleaseDate = (iso: string) => {
  if (!iso) {
    return ''
  }
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleDateString()
}

/** 历史版本更新日志列表页（从官网发布接口读取） */
const ReleaseNotesPage = () => {
  const t = useTranslate()
  const [items, setItems] = useState<ReleaseHistoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    let active = true
    setLoading(true)
    setFailed(false)
    void fetchReleaseHistory()
      .then((list) => {
        if (active) {
          setItems(list)
        }
      })
      .catch(() => {
        if (active) {
          setFailed(true)
        }
      })
      .finally(() => {
        if (active) {
          setLoading(false)
        }
      })
    return () => {
      active = false
    }
  }, [reloadKey])

  if (loading) {
    return <div className={styles.releaseStatus}>{t('releaseNotesLoading')}</div>
  }

  if (failed) {
    return (
      <div className={styles.releaseStatus}>
        <div>{t('releaseNotesLoadFailed')}</div>
        <Button size="m" onClick={() => setReloadKey((n) => n + 1)}>
          {t('retry')}
        </Button>
      </div>
    )
  }

  if (items.length === 0) {
    return <div className={styles.releaseStatus}>{t('releaseNotesEmpty')}</div>
  }

  return (
    <div className={styles.releaseList}>
      {items.map((item) => (
        <div key={item.id} className={clsx(styles.groupCard, styles.releaseItem)}>
          <div className={styles.releaseHeader}>
            <span className={styles.releaseVersion}>v{item.version}</span>
            <span className={styles.releaseDate}>{formatReleaseDate(item.createdAt)}</span>
          </div>
          <p className={styles.releaseNotes}>{item.changelog || t('updateNoNotes')}</p>
        </div>
      ))}
    </div>
  )
}

/** 删除确认保留在设置之上；失败可重试，成功只关闭确认弹窗。 */
const DeleteAllConfirm = ({
  historyDelete,
}: {
  historyDelete: ReturnType<typeof useHistoryDelete>
}) => {
  const t = useTranslate()
  return (
    <Modal
      title={t('deleteAllSessionsModalTitle')}
      className={styles.deleteConfirm}
      onClose={historyDelete.cancel}
      footer={
        <div className={styles.deleteActions} aria-busy={historyDelete.busy}>
          <Button
            variant="outlined"
            autoFocus
            disabled={historyDelete.busy}
            onClick={historyDelete.cancel}
          >
            {t('cancel')}
          </Button>
          <Button
            variant="danger"
            disabled={historyDelete.busy}
            onClick={() => void historyDelete.confirm()}
          >
            {t(historyDelete.busy ? 'historyDeleting' : 'deleteAllSessions')}
          </Button>
        </div>
      }
    >
      {t('deleteAllSessionsModalDescription')}
    </Modal>
  )
}

const useHistoryDelete = () => {
  const [opened, setOpened] = useState(false)
  const [busy, setBusy] = useState(false)
  const deleting = useRef(false)

  const confirm = async () => {
    if (deleting.current) {
      return
    }
    deleting.current = true
    setBusy(true)
    try {
      await clearHistory()
      setOpened(false)
      showToast({ key: 'historyDeleted' })
    } catch {
      showToast({ key: 'historyDeleteFailed', type: 'error' })
    } finally {
      deleting.current = false
      setBusy(false)
    }
  }

  return {
    opened,
    busy,
    open: () => setOpened(true),
    cancel: () => {
      if (!deleting.current) {
        setOpened(false)
      }
    },
    confirm,
  }
}

const DeepSeekAccountSetting = () => {
  const t = useTranslate()
  const authMode = useSettings((state) => state.authMode)
  const dshToken = useSettings((state) => state.dshToken)
  const dshAccountLabel = useSettings((state) => state.dshAccountLabel)
  const [busy, setBusy] = useState(false)

  const onSignIn = async () => {
    if (busy) {
      return
    }
    setBusy(true)
    try {
      await startDeepSeekAccountLogin()
    } catch (error) {
      if (error instanceof PlatformAuthUnavailableError) {
        window.open('https://platform.deepseek.com/api_keys', '_blank', 'noopener,noreferrer')
        showToast({ key: 'onboardingWebFallbackHint' })
      } else {
        showToast({
          key: 'apiKeyVerificationFailed',
          params: { message: error instanceof Error ? error.message : String(error) },
          type: 'error',
        })
      }
    } finally {
      setBusy(false)
    }
  }

  const labelText = dshAccountLabel || t('dshAccountLabel')
  const description = dshToken
    ? authMode === 'deepseek-account'
      ? t('dshAccountActive', { name: labelText })
      : t('dshAccountInactive', { name: labelText })
    : t('dshAccountSignedOutDesc')

  return (
    <SettingCell
      label={t('dshAccountLabel')}
      description={description}
      status={null}
      action={
        dshToken ? (
          <div className={styles.actionGroup}>
            {authMode !== 'deepseek-account' ? (
              <Button
                variant="outlined"
                size="m"
                onClick={() => setAuthMode('deepseek-account')}
              >
                {t('dshAccountEnableButton')}
              </Button>
            ) : null}
            <Button
              variant="dangerOutlined"
              size="m"
              onClick={() => void logoutDeepSeekAccount()}
            >
              {t('dshAccountSignOutButton')}
            </Button>
          </div>
        ) : (
          <Button
            variant="primary"
            size="m"
            className={styles.cellButton}
            disabled={busy}
            onClick={() => void onSignIn()}
          >
            {t('dshAccountSignInButton')}
          </Button>
        )
      }
    />
  )
}

const OneClickMigrateSetting = ({ disabled }: { disabled: boolean }) => {
  const t = useTranslate()
  return (
    <SettingCell
      label={t('historyOneClickImportLabel')}
      description={t('historyOneClickImportDesc')}
      status={null}
      action={
        <Button
          variant="primary"
          size="m"
          className={styles.cellButton}
          disabled={disabled}
          onClick={() => {
            closeSettings()
            void triggerOneClickMigration().catch(() => {})
          }}
        >
          {t('historyOneClickImportBtn')}
        </Button>
      }
    />
  )
}

const ApiProviderSettings = () => {
  const t = useTranslate()
  const apiProtocol = useSettings((state) => state.apiProtocol)
  const apiBaseUrl = useSettings((state) => state.apiBaseUrl)
  const apiModel = useSettings((state) => state.apiModel)

  return (
    <>
      <SettingCell
        label={t('apiProtocolLabel')}
        status={null}
        action={
          <Select
            variant="inline"
            ariaLabel={t('apiProtocolLabel')}
            value={apiProtocol}
            options={[
              { value: 'openai', label: t('apiProtocolOpenAI') },
              { value: 'anthropic', label: t('apiProtocolAnthropic') },
            ]}
            onChange={(value) => setApiProtocol(value as ApiProtocol)}
          />
        }
      />
      <div className={styles.cell}>
        <div className={styles.apiKey}>
          <div className={styles.label}>{t('apiBaseUrlLabel')}</div>
          <div className={styles.apiKeyInput}>
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
      </div>
      <div className={styles.cell}>
        <div className={styles.apiKey}>
          <div className={styles.label}>{t('apiModelLabel')}</div>
          <div className={styles.apiKeyInput}>
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
      </div>
    </>
  )
}

const LocationInlineSelect = () => {
  const t = useTranslate()
  const locale = useSettings((state) => state.locale)
  const location = useSettings((state) => state.location)
  const province =
    location?.region === 'CN'
      ? provinces.find((item) => item.code === location.province)
      : undefined

  return (
    <div className={styles.inlineLocation}>
      {isChineseBrowser() ? (
        <>
          <Select
            variant="inline"
            ariaLabel={t('settingsLocationProvince')}
            className={styles.inlineSelectClamp}
            value={province?.code ?? ''}
            placeholder={t('settingsLocationProvince')}
            options={provinces.map((item) => ({ value: item.code, label: item.name }))}
            onChange={(value) => {
              if (value !== province?.code) {
                setLocation({ region: 'CN', province: value })
              }
            }}
          />
          <Select
            variant="inline"
            ariaLabel={t('settingsLocationCity')}
            className={styles.inlineSelectClamp}
            value={province ? (location?.city ?? '') : ''}
            disabled={!province?.cities.length}
            placeholder={t('settingsLocationCity')}
            options={
              province?.cities.map((item) => ({ value: item.code, label: item.name })) ?? []
            }
            onChange={(value) => {
              if (province) {
                setLocation({ region: 'CN', province: province.code, city: value })
              }
            }}
          />
        </>
      ) : (
        <Select
          variant="inline"
          ariaLabel={t('settingsLocationRegion')}
          className={styles.inlineSelectClamp}
          value={location?.region ?? ''}
          placeholder={t('settingsLocationRegion')}
          options={regionCodes
            .map((code) => ({ value: code, label: getRegionName(code, locale) }))
            .sort((a, b) => a.label.localeCompare(b.label, locale))}
          onChange={(value) => setLocation({ region: value })}
        />
      )}
    </div>
  )
}

const LocaleInlineSelect = () => {
  const t = useTranslate()
  const locale = useSettings((state) => state.locale)
  return (
    <Select
      variant="inline"
      ariaLabel={t('settingsLocalePreference')}
      value={locale}
      options={[
        { value: 'zh-CN', label: t('settingsLocaleZhCN'), lang: 'zh-CN' },
        { value: 'en-US', label: t('settingsLocaleEnUS'), lang: 'en' },
      ]}
      onChange={setLocale}
    />
  )
}

const AppearanceInlineSelect = () => {
  const t = useTranslate()
  const themePreference = useSettings((state) => state.themePreference)
  return (
    <Select
      variant="inline"
      ariaLabel={t('settingsAppearance')}
      value={themePreference}
      options={[
        { value: 'system', label: t('settingsAppearanceSystem') },
        { value: 'light', label: t('avatarMenuSettingsDialogThemeSelectLightOption') },
        { value: 'dark', label: t('avatarMenuSettingsDialogThemeSelectDarkOption') },
      ]}
      onChange={(value) => setThemePreference(value as ThemePreference)}
    />
  )
}

const FontSizeInlineSelect = () => {
  const t = useTranslate()
  const chatFontSize = useSettings((state) => state.chatFontSize)
  return (
    <Select
      variant="inline"
      ariaLabel={t('settingsFontSize')}
      value={String(chatFontSize)}
      options={CHAT_FONT_SIZES.map((size) => ({
        value: String(size),
        label:
          size === DEFAULT_CHAT_FONT_SIZE
            ? t('settingsFontSizeDefault', { size })
            : `${size}px`,
      }))}
      onChange={(value) => setChatFontSize(Number(value) as ChatFontSize)}
    />
  )
}

/** 语音引擎行：仅原生壳且已配置 API Key 时提供选择（无 Key 时固定走设备原生） */
const SpeechEngineRow = () => {
  const t = useTranslate()
  const hasApiKey = useSettings((state) => Boolean(state.apiKey))
  if ((!isNativeAndroid() && !isNativeIos()) || !hasApiKey) {
    return null
  }
  return (
    <div className={styles.groupRow}>
      <span className={styles.rowIcon}>
        <IconVolumeOutline18 />
      </span>
      <span className={styles.rowLabel}>{t('settingsSpeechEngine')}</span>
      <SpeechEngineInlineSelect />
    </div>
  )
}

/** 安卓系统语音服务探测与快捷设置跳转（HyperOS / ColorOS / OriginOS 等） */
const AndroidSpeechServiceRow = () => {
  const t = useTranslate()
  const [info, setInfo] = useState<{
    osLabel: string
    asrLabel: string
    ttsLabel: string
  } | null>(null)

  useEffect(() => {
    if (!isNativeAndroid()) {
      return
    }
    let cancelled = false
    void DeepSeekMigration.getSpeechEngineInfo()
      .then((res) => {
        if (!cancelled) {
          setInfo(res)
        }
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [])

  if (!isNativeAndroid()) {
    return null
  }

  const engineLabel = info ? info.asrLabel || info.ttsLabel : ''
  const valueText = info
    ? engineLabel
      ? `${engineLabel} · ${info.osLabel}`
      : t('settingsAndroidSpeechUnavailable')
    : ''

  return (
    <button
      type="button"
      className={clsx(styles.groupRow, styles.groupRowButton)}
      onClick={() => void DeepSeekMigration.openSystemTtsSettings().catch(() => {})}
    >
      <span className={styles.rowIcon}>
        <IconVolumeOutline18 />
      </span>
      <span className={styles.rowLabel}>{t('settingsAndroidSpeechService')}</span>
      {valueText ? <span className={styles.rowValue}>{valueText}</span> : null}
      <span className={styles.rowChevron}>
        <IconChevronRightOutline14 />
      </span>
    </button>
  )
}

/** 语音引擎：auto 有 API Key 时云端、否则设备原生；仅在原生壳且有 Key 时提供选择 */
const SpeechEngineInlineSelect = () => {
  const t = useTranslate()
  const speechEngine = useSettings((state) => state.speechEngine)
  return (
    <Select
      variant="inline"
      ariaLabel={t('settingsSpeechEngine')}
      value={speechEngine}
      options={[
        { value: 'auto', label: t('settingsSpeechEngineAuto') },
        { value: 'native', label: t('settingsSpeechEngineNative') },
        { value: 'cloud', label: t('settingsSpeechEngineCloud') },
      ]}
      onChange={(value) => setSpeechEngine(value as SpeechEngine)}
    />
  )
}

/** 朗读音色：stella（海星，女声）/ tide（暗潮，男声） */
const TtsVoiceInlineSelect = () => {
  const t = useTranslate()
  const ttsVoice = useSettings((state) => state.ttsVoice)
  return (
    <Select
      variant="inline"
      ariaLabel={t('settingsTtsVoice')}
      value={ttsVoice}
      options={[
        { value: 'stella', label: t('settingsTtsVoiceStella') },
        { value: 'tide', label: t('settingsTtsVoiceTide') },
      ]}
      onChange={setTtsVoice}
    />
  )
}

/** 覆盖导入的二次确认，叠在设置弹窗上 */
const ImportConfirm = ({
  historyImport,
}: {
  historyImport: ReturnType<typeof useHistoryImport>
}) => {
  const t = useTranslate()
  return (
    <Modal
      title={t('historyImportConfirmTitle')}
      className={styles.importConfirm}
      onClose={historyImport.cancel}
      footer={
        <>
          <Button variant="outlined" size="m" autoFocus onClick={historyImport.cancel}>
            {t('cancel')}
          </Button>
          <Button variant="dangerOutlined" size="m" onClick={() => void historyImport.confirm()}>
            {t('historyImportConfirm')}
          </Button>
        </>
      }
    >
      <div className={styles.importConfirmText}>{t('historyImportConfirmDescription')}</div>
    </Modal>
  )
}

/** `reason` 为失败原因的文案 key，展示时按当前语言翻译后填入 `message` 参数。 */
type Status = (TranslationMessage & { error?: boolean; reason?: TranslationKey }) | null

/** 导出失败附带原因：预期的错误用对应文案作原因，其他错误用错误信息。 */
const errorStatus = (key: TranslationKey, error: unknown): Status => ({
  key,
  ...(error instanceof BackupError
    ? { reason: error.key }
    : { params: { message: error instanceof Error ? error.message : String(error) } }),
  error: true,
})

const SettingCell = ({
  label,
  description,
  status,
  action,
  className,
}: {
  label: string
  description?: string
  status: Status
  action: ReactNode
  className?: string
}) => {
  const t = useTranslate()
  return (
    <div className={clsx(styles.cell, styles.row, className)}>
      <div className={styles.text}>
        <div className={styles.label}>{label}</div>
        {status || description ? (
          <div className={clsx(styles.description, status?.error && styles.error)}>
            {status
              ? t(status.key, status.reason ? { message: t(status.reason) } : status.params)
              : description}
          </div>
        ) : null}
      </div>
      {action}
    </div>
  )
}

/** 选文件后先提示合并；确认后才检查文件并执行导入，任何错误都提示导入失败。 */
const useHistoryImport = () => {
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<Status>(null)
  const importing = useRef(false)

  const confirm = async () => {
    if (!file || importing.current) {
      return
    }
    importing.current = true
    setFile(null)
    setBusy(true)
    setStatus(null)
    try {
      const count = await importHistory(file)
      setStatus({ key: count === 1 ? 'historyImportedOne' : 'historyImported', params: { count } })
    } catch {
      setStatus({ key: 'historyImportFailed', error: true })
    } finally {
      importing.current = false
      setBusy(false)
    }
  }

  return { file, busy, status, select: setFile, cancel: () => setFile(null), confirm }
}

/** 增量导入历史对话 */
const ImportHistory = ({
  historyImport,
  disabled,
}: {
  historyImport: ReturnType<typeof useHistoryImport>
  disabled: boolean
}) => {
  const t = useTranslate()
  const inputRef = useRef<HTMLInputElement>(null)

  return (
    <SettingCell
      label={t('historyImport')}
      description={t('historyImportDescription')}
      status={historyImport.status}
      action={
        <>
          <Button
            variant="outlined"
            size="m"
            className={clsx(styles.cellButton, styles.uploadButton)}
            disabled={disabled}
            onClick={() => inputRef.current?.click()}
          >
            <IconUploadOutline14 />
            {t('upload')}
          </Button>
          <input
            ref={inputRef}
            type="file"
            accept=".zip,application/zip,application/x-zip-compressed"
            hidden
            onChange={(event) => {
              const file = event.target.files?.[0]
              event.target.value = ''
              if (file) {
                historyImport.select(file)
              }
            }}
          />
        </>
      }
    />
  )
}

const blobToBase64 = async (blob: Blob): Promise<string> => {
  const buffer = await blob.arrayBuffer()
  const bytes = new Uint8Array(buffer)
  let binary = ''
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
}

/** 将全部会话及图片导出为 ZIP 文件并下载 */
const ExportHistory = ({ disabled }: { disabled: boolean }) => {
  const t = useTranslate()
  const empty = useChatStore((state) => state.sessions.length === 0)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<Status>(null)

  const onExport = async () => {
    setBusy(true)
    setStatus(null)
    try {
      const { name, blob } = await exportHistory()
      if (isNativeIos()) {
        // iOS：走原生文件面板，可保存到 iCloud Drive / 本地
        await DeepSeekMigration.saveFileToDocuments({
          name,
          data: await blobToBase64(blob),
        })
      } else {
        const url = URL.createObjectURL(blob)
        const link = document.createElement('a')
        link.href = url
        link.download = name
        link.click()
        setTimeout(() => URL.revokeObjectURL(url), 10_000)
      }
    } catch (error) {
      setStatus(errorStatus('historyExportFailed', error))
    } finally {
      setBusy(false)
    }
  }

  return (
    <SettingCell
      label={t('exportAllLabel')}
      description={isNativeIos() ? t('historyExportDescriptionIos') : t('historyExportDescription')}
      status={status}
      action={
        <Button
          variant="outlined"
          size="m"
          className={styles.cellButton}
          disabled={disabled || busy || empty}
          onClick={() => void onExport()}
        >
          <IconDownloadOutline16 />
          {isNativeIos() ? t('exportAllSaveToIcloud') : t('exportAllDownload')}
        </Button>
      }
    />
  )
}

/** iCloud 自动备份开关（iOS）：开启后每次进入应用把最新快照写入 ubiquity container */
const IcloudAutoBackup = ({ disabled }: { disabled: boolean }) => {
  const t = useTranslate()
  const enabled = useSettings((state) => state.icloudAutoBackup)
  const [available, setAvailable] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    void DeepSeekMigration.icloudStatus()
      .then((res) => setAvailable(res.available))
      .catch(() => setAvailable(false))
  }, [])

  const onToggle = async () => {
    if (!enabled && available === false) {
      showToast({ key: 'icloudBackupUnavailable' })
      return
    }
    setBusy(true)
    try {
      setIcloudAutoBackup(!enabled)
      if (!enabled) {
        void maybeAutoBackupToIcloud()
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <SettingCell
      label={t('icloudAutoBackup')}
      description={t('icloudAutoBackupDescription')}
      status={null}
      action={
        <Button
          variant="outlined"
          size="m"
          className={styles.cellButton}
          disabled={disabled || busy}
          onClick={() => void onToggle()}
        >
          {t(enabled ? 'icloudBackupOn' : 'icloudBackupOff')}
        </Button>
      }
    />
  )
}
