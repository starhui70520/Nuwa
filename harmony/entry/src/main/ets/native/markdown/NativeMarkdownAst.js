import { toMdAst } from './MarkdownAstBundle.js'

export function toNativeMarkdownAst(input, sourceIndices, disableLink) {
  const sources = sourceIndices?.map((index) => ({ index }))
  return toMdAst(input, { sources, disableLink })
}
