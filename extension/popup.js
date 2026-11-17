const statusEl = document.getElementById('status')
const fileInput = document.getElementById('fileInput')

chrome.storage.local.get(['lastStatus']).then(({ lastStatus }) => {
  if (lastStatus) {
    statusEl.textContent = lastStatus
  }
})

document.getElementById('openDs').addEventListener('click', () => {
  chrome.tabs.create({ url: 'https://chat.deepseek.com/' })
})

document.getElementById('openApp').addEventListener('click', () => {
  chrome.tabs.create({ url: 'http://localhost:8090/' })
})

document.getElementById('pickZip').addEventListener('click', () => {
  fileInput.click()
})

fileInput.addEventListener('change', async (event) => {
  const file = event.target.files?.[0]
  if (!file) {
    return
  }
  statusEl.textContent = `正在推送 ${file.name}...`
  const buffer = await file.arrayBuffer()
  const res = await chrome.runtime.sendMessage({
    type: 'PUSH_ZIP_BYTES',
    name: file.name,
    bytes: Array.from(new Uint8Array(buffer)),
  })
  statusEl.textContent = res?.ok ? `已推送 ${file.name} 到 Nuwa` : `推送失败：${res?.error}`
})
