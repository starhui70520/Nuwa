import { create } from 'zustand'
import { hasActiveCredential } from '../../services/settings.js'

/** 设置弹窗初始入口：通用 / 账号管理 / 数据管理 */
export type SettingsSection = 'general' | 'account' | 'data'

/** 设置弹窗：侧边栏底部、没有可用凭据时的操作与 401 提示都可以打开 */
export const useSettingsDialog = create(() => ({
  open: false,
  section: 'general' as SettingsSection,
}))

export const openSettings = (section: SettingsSection) =>
  useSettingsDialog.setState({ open: true, section })

export const closeSettings = () => useSettingsDialog.setState({ open: false })

/** 没有可用凭据时打开设置并选中「账号管理」，返回是否已有可用凭据 */
export const ensureApiKey = () => {
  if (hasActiveCredential()) {
    return true
  }
  openSettings('account')
  return false
}
