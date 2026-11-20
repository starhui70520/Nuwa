import { prismMarkup } from './PrismGrammars.js'
import { light, dark } from './PrismStyles.js'

const MAX_RUNS = 8192
const MAX_DEPTH = 160
const ROOT_STYLE = { color: '', bold: 0, italic: 0, opacity: 1 }
const ROOT = { classes: new Set(), light: ROOT_STYLE, dark: ROOT_STYLE }

// Only the Prism-generated HTML is inspected. Actual displayed text comes from the original source.
function matches(selectors, stack) {
  let node = stack.length - 1
  for (let index = selectors.length - 1; index >= 0; index--) {
    const selector = selectors[index]
    const required = index === selectors.length - 1 || selectors[index + 1].immediate
    while (node >= 1 && !selector.classes.every(name => stack[node].classes.has(name))) {
      if (required) return false
      node--
    }
    if (node < 1) return false
    node--
  }
  return true
}

function resolveStyle(rules, stack, parent) {
  let color = parent.color
  let bold = parent.bold
  let italic = parent.italic
  let opacity = 1
  for (const { selectors, style } of rules) {
    if (!matches(selectors, stack)) continue
    if (style.color) color = style.color
    if (style.bold !== undefined) bold = style.bold < 0 ? parent.bold : style.bold
    if (style.italic !== undefined) italic = style.italic < 0 ? parent.italic : style.italic
    if (style.opacity !== undefined) opacity = style.opacity
  }
  return { color, bold, italic, opacity: opacity * parent.opacity }
}

function color(style, fallback) {
  if (style.opacity === 1) return style.color
  return '#' + Math.round(style.opacity * 255).toString(16).padStart(2, '0') + (style.color || fallback).slice(1)
}

function appendRun(runs, offset, length, context) {
  const lightColor = color(context.light, '#0F1115')
  const darkColor = color(context.dark, '#F9FAFB')
  const lightFlags = context.light.bold | context.light.italic << 1
  const darkFlags = context.dark.bold | context.dark.italic << 1
  const previous = runs[runs.length - 1]
  if (previous?.lightColor === lightColor && previous.darkColor === darkColor &&
    previous.lightFlags === lightFlags && previous.darkFlags === darkFlags) {
    previous.end = offset + length
  } else {
    runs.push({ end: offset + length, lightColor, darkColor, lightFlags, darkFlags })
  }
}

export function tokenizePrism(language, source) {
  const markup = prismMarkup(language, source)
  if (markup === undefined) return ''
  const stack = [ROOT]
  const runs = []
  let offset = 0
  let markupOffset = 0
  for (const token of markup.matchAll(/<\/span>|<span class="([^"]*)"(?: [\w-]+="[^"]*")*>|[^<]+/g)) {
    if (token.index !== markupOffset) return ''
    markupOffset += token[0].length
    if (token[1] !== undefined) {
      if (stack.length > MAX_DEPTH) return ''
      const parent = stack[stack.length - 1]
      const node = { classes: new Set(token[1].split(/\s+/)) }
      stack.push(node)
      node.light = resolveStyle(light, stack, parent.light)
      node.dark = resolveStyle(dark, stack, parent.dark)
    } else if (token[0] === '</span>') {
      if (stack.length === 1) return ''
      stack.pop()
    } else {
      const text = token[0].replace(/&lt;|&amp;/g, entity => entity === '&lt;' ? '<' : '&')
      const original = source.slice(offset, offset + text.length)
      // Prism encodes NBSP as an ordinary space. Keep the actual source code units.
      if (original.replace(/\u00a0/g, ' ') !== text) return ''
      appendRun(runs, offset, original.length, stack[stack.length - 1])
      if (runs.length > MAX_RUNS) return ''
      offset += original.length
    }
  }
  return offset === source.length && markupOffset === markup.length && stack.length === 1 ?
    JSON.stringify(runs) : ''
}
