const DEFAULT_APP_URL = 'http://localhost:8090/'

const getAppUrl = async () => {
  const { appUrl } = await chrome.storage.local.get('appUrl')
  return appUrl || DEFAULT_APP_URL
}

const isDeepSeekExport = (filename = '') => {
  const base = filename.split(/[\\/]/).pop() || ''
  return /^deepseek_data.*\.zip$/i.test(base)
}

const openOrFocusAppTab = async (appUrl) => {
  const origin = new URL(appUrl).origin
  const tabs = await chrome.tabs.query({ url: `${origin}/*` })
  if (tabs.length > 0 && tabs[0].id) {
    await chrome.tabs.update(tabs[0].id, { active: true })
    return tabs[0].id
  }
  const created = await chrome.tabs.create({ url: appUrl })
  await new Promise((resolve) => {
    const listener = (tabId, info) => {
      if (tabId === created.id && info.status === 'complete') {
        chrome.tabs.onUpdated.removeListener(listener)
        resolve()
      }
    }
    chrome.tabs.onUpdated.addListener(listener)
  })
  return created.id
}

const pushBytesToApp = async (bytes, name) => {
  const appUrl = await getAppUrl()
  const tabId = await openOrFocusAppTab(appUrl)
  await chrome.tabs.sendMessage(tabId, {
    type: 'DSAPP_IMPORT_ZIP',
    name,
    bytes: Array.from(bytes),
  })
}

chrome.downloads.onChanged.addListener(async (delta) => {
  if (!delta.state || delta.state.current !== 'complete') {
    return
  }
  const [item] = await chrome.downloads.search({ id: delta.id })
  if (!item || !isDeepSeekExport(item.filename)) {
    return
  }

  const name = item.filename.split(/[\\/]/).pop() || 'deepseek_data.zip'
  await chrome.storage.local.set({
    lastExport: { id: item.id, name, filename: item.filename, time: Date.now() },
  })

  try {
    const fileUrl = item.filename.startsWith('file://')
      ? item.filename
      : `file:///${item.filename.replace(/\\/g, '/')}`
    const res = await fetch(fileUrl)
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`)
    }
    const buffer = await res.arrayBuffer()
    await pushBytesToApp(new Uint8Array(buffer), name)
    await chrome.storage.local.set({ lastStatus: `已自动推送 ${name} 到 Nuwa` })
  } catch {
    await chrome.storage.local.set({
      lastStatus:
        '检测到导出包，但浏览器未开启「允许访问文件网址」，请在扩展弹窗中手动选择或开启权限',
    })
  }
})

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'PUSH_ZIP_BYTES') {
    pushBytesToApp(new Uint8Array(message.bytes), message.name)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: String(err) }))
    return true
  }
  return false
})
