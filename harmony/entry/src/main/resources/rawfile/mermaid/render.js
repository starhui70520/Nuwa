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

  function titleScalar(value) {
    const singleQuoted = /^'((?:[^']|'')*)'(?:[ \t]+#.*)?$/.exec(value)
    if (singleQuoted) return singleQuoted[1].replace(/''/g, "'")
    const doubleQuoted = /^("(?:[^"\\]|\\.)*")(?:[ \t]+#.*)?$/.exec(value)
    if (doubleQuoted) {
      try {
        return JSON.parse(doubleQuoted[1])
      } catch {
        return ''
      }
    }
    if (/^["'!&*#|>{\[]/.test(value)) return ''
    return value.replace(/[ \t]+#.*$/, '').trimEnd()
  }

  function titleFrontmatter(fields) {
    // Only forward a title field. Mermaid still interprets the YAML block scalar's fold and chomp indicators.
    const field = /^(?:title|'title'|"title"):[ \t]+([^\r\n\u0085\u2028\u2029]*)$/m.exec(fields)
    const value = field?.[1].trim()
    if (!value) return ''
    const block = /^[|>](?:[1-9][+-]?|[+-][1-9]?)?(?=[ \t]*(?:#|$))/.exec(value)?.[0]
    if (block) {
      const lines = []
      for (const line of fields.slice(field.index + field[0].length).split(/\r?\n/).slice(1)) {
        if (line && !line.startsWith(' ')) break
        if (/[\r\u0000-\u0008\u000b\u000c\u000e-\u001f\u0085\u2028\u2029]/.test(line)) return ''
        lines.push(line.trim() ? line : '')
      }
      const first = lines.find((line) => line.length > 0)
      if (!first) return ''
      const indentation = Number(/[1-9]/.exec(block)?.[0] ?? first.match(/^ +/)[0].length)
      if (lines.some((line) => line && !line.startsWith(' '.repeat(indentation)))) return ''
      return '---\ntitle: ' + block + '\n' + lines.join('\n') + '\n---\n'
    }
    const title = titleScalar(value)
    if (!title) return ''
    const encoded = JSON.stringify(title).replace(/[<>%&\u0085\u2028\u2029]/g,
      (character) => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'))
    return '---\ntitle: ' + encoded + '\n---\n'
  }

  function prepareSource(source) {
    let title = ''
    const body = source.replace(/^\uFEFF/, '')
      .replace(/^\s*---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/, (_header, fields) => {
        title = titleFrontmatter(fields)
        return ''
      })
      .replace(/%%\{[\s\S]*?\}%%/g, '')
      .replace(/<((?:img|image)\s+)/gi, '&lt;$1')
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
