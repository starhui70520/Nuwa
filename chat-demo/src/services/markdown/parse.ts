import type { Node as MdAstNode, Nodes, Parent, RootContent, Root, Text } from 'mdast'
import { findAndReplace } from 'mdast-util-find-and-replace'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { mathFromMarkdown } from 'mdast-util-math'
import { gfm } from 'micromark-extension-gfm'
import { math } from 'micromark-extension-llm-math'
import type { Source } from '../chat/view.js'

/** 正文里的 [citation:N]，已换成对应来源 */
export interface CitationNode extends MdAstNode {
  type: 'citation'
  source: Source
}

declare module 'mdast' {
  interface RootContentMap {
    citation: CitationNode
  }

  interface PhrasingContentMap {
    citation: CitationNode
  }
}

const text = (value: string): Text => ({ type: 'text', value })

// 扩展表不含运行时状态，模块级复用避免每次解析都重新构造语法表。
const MARKDOWN_OPTIONS = {
  extensions: [
    // codeIndented 语法导致有前导空格的列表无法正常渲染
    { ...gfm(), disable: { null: ['codeIndented'] } },
    math({ singleDollarTextMath: true }),
  ],
  mdastExtensions: [gfmFromMarkdown(), mathFromMarkdown()],
}

const CITATION_MARKER = '[citation:'
const MAX_CACHEABLE_INPUT_CHARS = 24_000
const MAX_AST_CACHE_ENTRIES = 48
const MAX_AST_CACHE_CHARS = 180_000

const astCache = new Map<string, { ast: Root; chars: number }>()
let astCacheChars = 0

/** 释放 Markdown AST 缓存（内存紧张时调用） */
export function clearMdAstCache(): void {
  astCache.clear()
  astCacheChars = 0
}

const getCachedAst = (key: string): Root | undefined => {
  const entry = astCache.get(key)
  if (!entry) {
    return undefined
  }
  astCache.delete(key)
  astCache.set(key, entry)
  return entry.ast
}

const setCachedAst = (key: string, ast: Root, chars: number): void => {
  const existing = astCache.get(key)
  if (existing) {
    astCacheChars -= existing.chars
    astCache.delete(key)
  }
  astCache.set(key, { ast, chars })
  astCacheChars += chars
  while (astCache.size > MAX_AST_CACHE_ENTRIES || astCacheChars > MAX_AST_CACHE_CHARS) {
    const oldest = astCache.keys().next()
    if (oldest.done) {
      break
    }
    const removed = astCache.get(oldest.value)
    if (removed) {
      astCacheChars -= removed.chars
    }
    astCache.delete(oldest.value)
  }
}

const rawSlice = (node: Nodes, input: string): string =>
  input.slice(node.position?.start.offset, node.position?.end.offset)

// 原地/写时复制简化子节点，绝大多数无展开节点时零额外数组分配。
const simplifyChildren = (parent: Parent, input: string, disableLink: boolean): void => {
  const children = parent.children as RootContent[]
  let next: RootContent[] | null = null
  for (let i = 0; i < children.length; i++) {
    const child = children[i]
    if ('children' in child) {
      simplifyChildren(child as Parent, input, disableLink)
    }
    switch (child.type) {
      case 'link': {
        if (disableLink) {
          if (!next) {
            next = children.slice(0, i)
          }
          const inner = child.children as RootContent[]
          for (let j = 0; j < inner.length; j++) {
            next.push(inner[j])
          }
        } else if (next) {
          next.push(child)
        }
        break
      }
      case 'delete': {
        // 解析器保证首尾定界符等长
        const rawText = rawSlice(child, input)
        let tildeCount = 0
        while (tildeCount < rawText.length && rawText.charCodeAt(tildeCount) === 0x7e) {
          tildeCount++
        }
        const delimiter = tildeCount > 0 ? rawText.slice(0, tildeCount) : ''
        if (!next) {
          next = children.slice(0, i)
        }
        next.push(text(delimiter) as unknown as RootContent)
        const inner = child.children as RootContent[]
        for (let j = 0; j < inner.length; j++) {
          next.push(inner[j])
        }
        next.push(text(delimiter) as unknown as RootContent)
        break
      }
      case 'footnoteReference':
      case 'imageReference':
      case 'linkReference': {
        const replacement = text(rawSlice(child, input)) as unknown as RootContent
        if (next) {
          next.push(replacement)
        } else {
          children[i] = replacement
        }
        break
      }
      case 'footnoteDefinition':
      case 'definition': {
        const replacement: RootContent = {
          type: 'paragraph',
          children: [text(rawSlice(child, input))],
        }
        if (next) {
          next.push(replacement)
        } else {
          children[i] = replacement
        }
        break
      }
      default:
        if (next) {
          next.push(child)
        }
        break
    }
  }
  if (next) {
    parent.children = next
  }
}

/**
 * 解析正文，并把渲染器不单独处理的节点提前换掉，渲染时无需再读原文：
 * - 传入 sources 时，[citation:N] 换成角标节点，找不到来源的直接去掉
 * - disableLink 时链接只保留文字
 * - 删除线保留原样的 ~ 定界符，脚注、引用式链接与定义显示原文
 */
export function toMdAst(
  input: string,
  { sources, disableLink }: { sources: Source[] | undefined; disableLink: boolean }
): Root {
  const hasCitation = sources !== undefined && input.includes(CITATION_MARKER)
  const cacheable = !hasCitation && input.length <= MAX_CACHEABLE_INPUT_CHARS
  const cacheKey = cacheable ? `${disableLink ? '1' : '0'}:${input}` : ''
  if (cacheable) {
    const cached = getCachedAst(cacheKey)
    if (cached) {
      return cached
    }
  }
  const ast = fromMarkdown(input, MARKDOWN_OPTIONS)
  if (hasCitation) {
    const sourcesByIndex = new Map<number, Source>()
    for (let i = 0; i < sources.length; i++) {
      sourcesByIndex.set(sources[i].index, sources[i])
    }
    findAndReplace(
      ast,
      [
        /\[citation:(\d+)\]/g,
        (_: string, index: string): CitationNode | '' => {
          const source = sourcesByIndex.get(Number(index))
          return source ? { type: 'citation', source } : ''
        },
      ],
      { ignore: ['linkReference'] }
    )
  }
  simplifyChildren(ast, input, disableLink)
  if (cacheable) {
    setCachedAst(cacheKey, ast, input.length)
  }
  return ast
}
