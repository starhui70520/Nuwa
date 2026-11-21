(() => {
  'use strict'

  if (!window.katex || !window.NuwaKaTeXStyles) return
  const styles = window.NuwaKaTeXStyles + '\n.katex-display{margin:0;text-align:left}.katex .katex-mathml{display:none}'
  const css = document.createElement('style')
  css.textContent = styles
  document.head.append(css)

  const svgNamespace = 'http://www.w3.org/2000/svg'
  const visualTags = new Set(['span', 'svg', 'path', 'line', 'rect', 'g'])
  const measure = document.createElement('div')
  measure.style.cssText = 'position:absolute;left:0;top:0;width:max-content;white-space:nowrap;visibility:hidden'
  document.body.append(measure)

  function markBaselines(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    const entries = []
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      if (text.data.trim() && text.parentElement.namespaceURI !== svgNamespace) entries.push({ text })
    }
    for (const entry of entries) {
      const marker = document.createElement('span')
      marker.style.cssText = 'display:inline-block;vertical-align:baseline;width:0;height:0'
      entry.text.after(marker)
      entry.marker = marker
    }
    return entries
  }

  function fillBox(context, color, x, y, width, height) {
    if (width <= 0 || height <= 0 || color === 'transparent' || color === 'rgba(0, 0, 0, 0)') return
    context.fillStyle = color
    context.fillRect(x, y, width, height)
  }

  function drawBoxes(context, elements) {
    for (const element of elements) {
      if (element.namespaceURI === svgNamespace) continue
      const style = getComputedStyle(element)
      const box = element.getBoundingClientRect()
      fillBox(context, style.backgroundColor, box.left, box.top, box.width, box.height)
      const top = parseFloat(style.borderTopWidth)
      const bottom = parseFloat(style.borderBottomWidth)
      const left = parseFloat(style.borderLeftWidth)
      const right = parseFloat(style.borderRightWidth)
      fillBox(context, style.borderTopColor, box.left, box.top, box.width, top)
      fillBox(context, style.borderBottomColor, box.left, box.bottom - bottom, box.width, bottom)
      fillBox(context, style.borderLeftColor, box.left, box.top, left, box.height)
      fillBox(context, style.borderRightColor, box.right - right, box.top, right, box.height)
    }
  }

  function drawGlyphs(context, entries) {
    const range = document.createRange()
    context.textBaseline = 'alphabetic'
    context.textAlign = 'left'
    for (const { text, marker } of entries) {
      const style = getComputedStyle(text.parentElement)
      range.selectNodeContents(text)
      const box = range.getBoundingClientRect()
      context.font = [style.fontStyle, style.fontWeight, style.fontSize, style.fontFamily].join(' ')
      context.direction = style.direction
      if ('letterSpacing' in context) context.letterSpacing = style.letterSpacing
      context.fillStyle = style.color
      context.fillText(text.data, box.left, marker.getBoundingClientRect().top)
    }
  }

  function drawVectors(context, root, bounds) {
    for (const svg of root.querySelectorAll('svg')) {
      const view = svg.getBoundingClientRect()
      context.save()
      context.beginPath()
      context.rect(view.left, view.top, view.width, view.height)
      context.clip()
      // KaTeX clips the tail of extensible radicals/arrows in a parent span.
      for (let parent = svg.parentElement; parent && parent !== root; parent = parent.parentElement) {
        const style = getComputedStyle(parent)
        const clipX = style.overflowX === 'hidden' || style.overflowX === 'clip'
        const clipY = style.overflowY === 'hidden' || style.overflowY === 'clip'
        if (!clipX && !clipY) continue
        const box = parent.getBoundingClientRect()
        context.beginPath()
        context.rect(clipX ? box.left : bounds.left, clipY ? box.top : bounds.top,
          clipX ? box.width : bounds.width, clipY ? box.height : bounds.height)
        context.clip()
      }
      for (const path of svg.querySelectorAll('path, line, rect')) {
        const mapping = path.getScreenCTM()
        if (!mapping) continue
        const style = getComputedStyle(path)
        const shape = path.localName === 'path' ? new Path2D(path.getAttribute('d')) : new Path2D()
        if (path.localName === 'line') {
          shape.moveTo(path.x1.baseVal.value, path.y1.baseVal.value)
          shape.lineTo(path.x2.baseVal.value, path.y2.baseVal.value)
        } else if (path.localName === 'rect') {
          shape.rect(path.x.baseVal.value, path.y.baseVal.value, path.width.baseVal.value, path.height.baseVal.value)
        }
        context.save()
        context.transform(mapping.a, mapping.b, mapping.c, mapping.d, mapping.e, mapping.f)
        if (style.fill !== 'none') {
          context.fillStyle = style.fill
          context.fill(shape, style.fillRule === 'evenodd' ? 'evenodd' : 'nonzero')
        }
        if (style.stroke !== 'none' && parseFloat(style.strokeWidth) > 0) {
          context.strokeStyle = style.stroke
          context.lineWidth = parseFloat(style.strokeWidth)
          context.stroke(shape)
        }
        context.restore()
      }
      context.restore()
    }
  }

  function rasterize(root, entries, bounds, width, height, padding, density) {
    // ArkWeb's SVG-image decoder can stall on foreignObject with embedded fonts.
    // Paint with browser-measured KaTeX layout and the already loaded fonts instead.
    const canvas = document.createElement('canvas')
    canvas.width = Math.ceil(width * density)
    canvas.height = Math.ceil(height * density)
    const context = canvas.getContext('2d')
    context.scale(canvas.width / width, canvas.height / height)
    context.translate(padding - bounds.left, padding - bounds.top)
    drawBoxes(context, root.querySelectorAll('*'))
    drawGlyphs(context, entries)
    drawVectors(context, root, bounds)
    return canvas.toDataURL('image/png')
  }

  function renderVisual(source, display) {
    const options = Object.assign(Object.create(null), {
      throwOnError: true, strict: false, displayMode: display, trust: false, output: 'html',
    })
    const template = document.createElement('template')
    template.innerHTML = window.katex.renderToString(source, options)
    const visual = template.content.querySelectorAll('*')
    if (visual.length > 5000) return null
    for (const element of visual) {
      if (!visualTags.has(element.localName)) {
        element.remove()
        continue
      }
      for (const attribute of [...element.attributes]) {
        const name = attribute.localName.toLowerCase()
        if (name === 'href' || name === 'src' || name === 'srcset' || name.startsWith('on') ||
            (name === 'style' && /url\s*\(|@import/i.test(attribute.value))) {
          element.removeAttributeNode(attribute)
        }
      }
    }
    return template.content
  }

  async function renderFormula(request) {
    if (typeof request.source !== 'string' || !request.source.trim() || request.source.length > 2048) return null
    const fontSize = Math.min(48, Math.max(8, Number(request.fontSize) || 16))
    const density = Math.min(3.5, Math.max(1, Number(request.density) || 1))
    const color = /^#[0-9A-Fa-f]{6}$/.test(request.color) ? request.color : '#0F1115'
    const formula = document.createElement('span')
    formula.style.cssText = 'display:inline-block;vertical-align:baseline;line-height:normal;white-space:nowrap'
    formula.style.color = color
    formula.style.fontSize = fontSize + 'px'
    formula.style.fontWeight = request.bold ? '700' : '400'
    const visual = renderVisual(request.source, request.display === true)
    if (!visual) return null
    formula.append(visual)
    const entries = markBaselines(formula)

    const baseline = document.createElement('span')
    baseline.style.cssText = 'display:inline-block;vertical-align:baseline;width:0;height:0'
    measure.replaceChildren(formula, baseline)
    try {
      // Measure after the exact KaTeX fonts have loaded.
      formula.getBoundingClientRect()
      await document.fonts.ready
      const bounds = formula.getBoundingClientRect()
      const padding = 2
      const width = Math.ceil(bounds.width + padding * 2)
      const height = Math.ceil(bounds.height + padding * 2)
      const depth = Math.min(height, Math.max(0, bounds.bottom - baseline.getBoundingClientRect().top + padding))
      if (width > 2800 || height > 1000 || width * height * density * density > 2_000_000) return null

      const png = rasterize(formula, entries, bounds, width, height, padding, density)
      return png.length <= 260000 ? { png, width, height, depth } : null
    } finally {
      measure.replaceChildren()
    }
  }

  let status
  let active = false
  window.NuwaMath = Object.freeze({
    begin(payload) {
      if (active || typeof payload !== 'string' || payload.length > 12000) return false
      let request
      try {
        const bytes = Uint8Array.from(atob(payload), (char) => char.charCodeAt(0))
        request = JSON.parse(new TextDecoder().decode(bytes))
      } catch {
        return false
      }
      active = true
      status = undefined
      renderFormula(request).then(
        (picture) => { status = picture; active = false },
        () => { status = null; active = false },
      )
      return true
    },
    take() {
      if (status === undefined) return 'pending'
      const picture = status
      status = undefined
      return picture ? JSON.stringify(picture) : 'invalid'
    },
  })
})()
