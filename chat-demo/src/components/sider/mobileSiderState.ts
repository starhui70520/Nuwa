import { create } from 'zustand'

/** 移动端侧边栏抽屉：顶栏菜单按钮或右滑打开，左滑、点遮罩、切换会话或开启新对话后关闭 */
export const useMobileSider = create<{ open: boolean; dragProgress: number | null }>(() => ({
  open: false,
  dragProgress: null,
}))

export const openMobileSider = () => useMobileSider.setState({ open: true, dragProgress: null })

export const closeMobileSider = () => useMobileSider.setState({ open: false, dragProgress: null })

export const setMobileSiderDrag = (dragProgress: number | null) =>
  useMobileSider.setState({ dragProgress })
