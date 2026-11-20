(() => {
  'use strict'

  const diagram = document.getElementById('diagram')
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)')
  let latest = 0
  let result = -1
  let queue = Promise.resolve()
  let lastInput
  let displayedSource = ''
  let displayedDark

  const clear = () => {
    diagram.replaceChildren()
    displayedSource = ''
    displayedDark = undefined
  }

  function safeSvg(svg) {
    // The renderer emits sanitized SVG in strict mode. Use an inert template before
    // mounting it, and keep the preview independent of links, media, and handlers.
    const template = document.createElement('template')
    template.innerHTML = svg
    const root = template.content.firstElementChild
    if (!root || root.localName !== 'svg' || root.namespaceURI !== 'http://www.w3.org/2000/svg') {
      throw new Error('Invalid diagram output')
    }
    for (const item of root.querySelectorAll('script, iframe, object, embed, img, image, audio, video, link, form')) {
      item.remove()
    }
    for (const item of [root, ...root.querySelectorAll('*')]) {
      for (const attribute of [...item.attributes]) {
        const name = attribute.localName.toLowerCase()
        if (name.startsWith('on') || name === 'src' || name === 'srcset' ||
            (name === 'href' && !attribute.value.startsWith('#'))) {
          item.removeAttributeNode(attribute)
        }
      }
    }
    return root
  }

  function prepareSource(source) {
    // Match Android's HTML image handling. Configuration remains under app control.
    return source.replace(/^\uFEFF/, '')
      .replace(/^\s*---[ \t]*\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, '')
      .replace(/%%\{[\s\S]*?\}%%/g, '')
      .replace(/<((?:img|image)\s+)/gi, '&lt;$1')
  }

  function draw(payload, theme, loading = false) {
    lastInput = { payload, theme, loading }
    const generation = ++latest
    result = -1
    queue = queue.catch(() => {}).then(async () => {
      if (generation !== latest) return
      try {
        if (payload.length > 267000 || !window.mermaid) throw new Error('Unavailable diagram renderer')
        const bytes = Uint8Array.from(atob(payload), (character) => character.charCodeAt(0))
        const source = prepareSource(new TextDecoder().decode(bytes))
        if (source.length > 50000) throw new Error('Diagram is too large')
        if (!source.trim()) {
          if (!loading) clear()
          result = loading ? (displayedSource ? 0 : -4) : -3
          return
        }
        const dark = theme === 'dark' || (theme === 'system' && systemDark.matches)
        window.mermaid.initialize({
          theme: dark ? 'dark' : 'default',
          fontFamily: 'trebuchet ms, verdana, arial, sans-serif',
          securityLevel: 'strict',
          startOnLoad: false,
          suppressErrorRendering: true,
          maxTextSize: 50000,
          maxEdges: 500,
          secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
            'suppressErrorRendering', 'dompurifyConfig', 'fontFamily', 'altFontFamily',
            'themeCSS', 'themeVariables'],
        })
        const render = async (input, suffix = '') => {
          const { svg } = await window.mermaid.render('nuwa-diagram-' + generation + suffix, input)
          if (generation !== latest) return
          diagram.replaceChildren(safeSvg(svg))
          displayedSource = input
          displayedDark = dark
          result = 0
        }
        try {
          await render(source)
        } catch (error) {
          if (generation !== latest) return
          if (!loading) throw error
          const trimmed = source.trimEnd()
          const lineEnd = Math.max(trimmed.lastIndexOf('\n'), trimmed.lastIndexOf('\r'))
          const prefix = trimmed.slice(0, Math.max(0, lineEnd))
          if (prefix && !(displayedDark === dark && displayedSource.startsWith(prefix))) {
            try {
              await render(prefix, '-prefix')
              return
            } catch {
              if (generation !== latest) return
            }
          }
          result = displayedSource ? 0 : -4
        }
      } catch {
        if (generation !== latest) return
        if (!loading) clear()
        result = loading ? (displayedSource ? 0 : -4) : -2
      }
    })
    return 0
  }

  systemDark.addEventListener('change', () => {
    if (lastInput?.theme === 'system') draw(lastInput.payload, lastInput.theme, lastInput.loading)
  })

  window.NuwaMermaid = Object.freeze({
    draw,
    status: () => result === 0 ? Math.ceil(diagram.getBoundingClientRect().height) : result,
  })
})()
