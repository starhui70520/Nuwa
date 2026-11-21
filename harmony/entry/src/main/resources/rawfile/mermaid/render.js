(() => {
  'use strict'

  const diagram = document.getElementById('diagram')
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)')
  const sourceLimit = 50000
  const frontmatter = /^(?:[^\S\n]*\n)*([^\S\n]*)---[^\S\n]*\n([\s\S]*?)\n\1---[^\S\n]*(?:\n|$)/
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

  function titleFrontmatter(fields, indent) {
    let title
    try {
      const yaml = indent ? fields.split('\n')
        .map((line) => line.startsWith(indent) ? line.slice(indent.length) : line).join('\n') : fields
      title = window.NuwaMermaidYamlTitle(yaml)
    } catch {
      // A malformed title does not keep the rest of the diagram from rendering.
      return ''
    }
    if (!title) return ''
    const encoded = JSON.stringify(title).replace(/[<>%&\u0085\u2028\u2029]/g,
      (character) => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'))
    return '---\ntitle: ' + encoded + '\n---\n'
  }

  function prepareSource(source) {
    let title = ''
    let body = source.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n')
      .replace(frontmatter, (_header, indent, fields) => {
        title = titleFrontmatter(fields, indent)
        return ''
      })
      .replace(/%%\{[\s\S]*?\}%%/g, '')
      .replace(/%%\{[^\n]*/g, '')
      .replace(/<((?:img|image)\s+)/gi, '&lt;$1')
    // A stripped directive or header can leave more YAML at the start of the body.
    while (frontmatter.test(body)) body = body.replace(frontmatter, '')
    return title + body
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
        const input = new TextDecoder().decode(bytes)
        if (input.length > sourceLimit) throw new Error('Diagram is too large')
        const source = prepareSource(input)
        if (source.length > sourceLimit) throw new Error('Diagram is too large')
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
          maxTextSize: sourceLimit,
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
