chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'DSAPP_IMPORT_ZIP' || !Array.isArray(message.bytes)) {
    return false
  }
  const payload = new Uint8Array(message.bytes).buffer
  window.postMessage(
    {
      type: 'dsapp:import-zip',
      payload,
      name: message.name || 'deepseek_data.zip',
    },
    window.location.origin
  )
  sendResponse({ ok: true })
  return false
})
