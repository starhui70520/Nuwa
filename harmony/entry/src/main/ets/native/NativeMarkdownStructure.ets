import { url } from '@kit.ArkTS';
import { NativeMarkdownAstNode, toNativeMarkdownAst } from './markdown/NativeMarkdownAst';
import { NativeMathSpan, nativeMathSpans, parseNativeMath } from './NativeMarkdownMath';

export interface NativeMarkdownPart {
  text: string;
  strong: boolean;
  italic: boolean;
  code?: boolean;
  target?: string;
  citation?: number;
  math?: NativeMathSpan[];
  formula?: string;
}

export interface NativeMarkdownBlock {
  kind: string;
  key: string;
  text?: string;
  level?: number;
  marker?: string;
  children?: NativeMarkdownBlock[];
  parts?: NativeMarkdownPart[];
  rows?: NativeMarkdownPart[][][];
  lang?: string;
  hasDiagram?: boolean;
}

function linkTarget(value: string): string | undefined {
  if (!value || value.startsWith('#') || value.startsWith('mailto:')) return undefined;
  try {
    const address = /^[a-z]+:\/\//i.test(value) ? value : 'https://' + value;
    const parsed = url.URL.parseURL(address);
    if ((parsed.protocol === 'https:' || parsed.protocol === 'http:') && parsed.hostname &&
      !parsed.username && !parsed.password) {
      return parsed.href;
    }
  } catch {
    // An invalid URL may still have a readable link label.
  }
  return undefined;
}

function appendInline(parts: NativeMarkdownPart[], nodes: NativeMarkdownAstNode[], strong: boolean,
  italic: boolean, target?: string): void {
  for (const node of nodes) {
    const value = node.value ?? '';
    switch (node.type) {
      case 'strong':
      case 'emphasis':
        appendInline(parts, node.children ?? [], strong || node.type === 'strong',
          italic || node.type === 'emphasis', target);
        break;
      case 'link':
        appendInline(parts, node.children ?? [], strong, italic, linkTarget(node.url ?? ''));
        break;
      case 'image': {
        const imageUrl = linkTarget(node.url ?? '');
        if (imageUrl) parts.push({ text: imageUrl, target: imageUrl, strong, italic });
        break;
      }
      case 'citation': {
        const index = node.source?.index;
        if (index !== undefined) parts.push({ text: index.toString(), citation: index, strong, italic });
        break;
      }
      case 'inlineMath': {
        const expression = parseNativeMath(value);
        parts.push({ text: value, formula: value, math: expression ? nativeMathSpans(expression) : undefined,
          target, strong, italic });
        break;
      }
      case 'html':
        parts.push({ text: /^<br\s*\/?>$/i.test(value) ? '\n' : value, strong, italic, target });
        break;
      case 'break':
        parts.push({ text: '\n', strong, italic, target });
        break;
      case 'text':
      case 'inlineCode':
        parts.push({ text: value, strong, italic, code: node.type === 'inlineCode', target });
        break;
    }
  }
}

function inlineParts(nodes: NativeMarkdownAstNode[], strong: boolean = false): NativeMarkdownPart[] {
  const parts: NativeMarkdownPart[] = [];
  appendInline(parts, nodes, strong, false);
  return parts;
}

function tableRows(node: NativeMarkdownAstNode): NativeMarkdownPart[][][] {
  const rows = node.children ?? [];
  const columns = rows[0]?.children?.length ?? 0;
  return rows.map<NativeMarkdownPart[][]>((row: NativeMarkdownAstNode): NativeMarkdownPart[][] => {
    const cells = row.children ?? [];
    const projected: NativeMarkdownPart[][] = [];
    for (let cell = 0; cell < Math.max(columns, cells.length); cell++) {
      projected.push(inlineParts(cells[cell]?.children ?? []));
    }
    return projected;
  });
}

function blockHash(hash: number, value: string): number {
  for (let index = 0; index < value.length; index++) {
    hash = Math.imul(hash ^ value.charCodeAt(index), 16777619);
  }
  return hash;
}

function partsHash(hash: number, parts: NativeMarkdownPart[]): number {
  for (const part of parts) {
    hash = blockHash(hash, [
      part.text, part.target ?? '', part.formula ?? '', String(part.citation ?? ''),
      part.strong ? 'strong' : '', part.italic ? 'italic' : '', part.code ? 'code' : '',
    ].join('\u0000'));
  }
  return hash;
}

function withKey(block: NativeMarkdownBlock): NativeMarkdownBlock {
  let hash = blockHash(2166136261, [
    block.kind, block.marker ?? '', block.lang ?? '', block.text ?? '',
    (block.level ?? 0).toString(),
  ].join('\u0000'));
  if (block.parts) hash = partsHash(hash, block.parts);
  for (const row of block.rows ?? []) {
    hash = blockHash(hash, '\u0001');
    for (const cell of row) hash = partsHash(blockHash(hash, '\u0002'), cell);
  }
  for (const child of block.children ?? []) hash = blockHash(hash, child.key);
  block.key = (hash >>> 0).toString(36);
  block.hasDiagram = block.lang?.toLowerCase() === 'mermaid' ||
    block.children?.some((child: NativeMarkdownBlock): boolean => child.hasDiagram === true);
  return block;
}

function orderedTaskMark(blocks: NativeMarkdownBlock[], complete: boolean): void {
  const mark: NativeMarkdownPart = { text: complete ? '☑  ' : '□  ', strong: false, italic: false };
  const first = blocks[0];
  if (first?.kind === 'paragraph') {
    first.parts = [mark, ...(first.parts ?? [])];
    withKey(first);
  } else {
    blocks.unshift(withKey({ kind: 'paragraph', key: '', parts: [mark] }));
  }
}

function projectBlocks(nodes: NativeMarkdownAstNode[], listDepth: number = 0): NativeMarkdownBlock[] {
  const blocks: NativeMarkdownBlock[] = [];
  for (const node of nodes) {
    const children = node.children ?? [];
    let block: NativeMarkdownBlock | undefined;
    switch (node.type) {
      case 'heading':
        if (children.length) {
          block = { kind: 'heading', key: '', level: node.depth ?? 1, parts: inlineParts(children, true) };
        }
        break;
      case 'paragraph':
        block = { kind: 'paragraph', key: '', parts: inlineParts(children) };
        break;
      case 'html':
        block = { kind: 'paragraph', key: '', parts: inlineParts([node]) };
        break;
      case 'blockquote':
        block = { kind: 'quote', key: '', children: projectBlocks(children, listDepth) };
        break;
      case 'list': {
        const start = node.start ?? 1;
        const bullet = listDepth === 0 ? '•' : listDepth === 1 ? '◦' : '▪';
        block = {
          kind: 'list', key: '', children: children.map<NativeMarkdownBlock>((item: NativeMarkdownAstNode,
            index: number): NativeMarkdownBlock => {
            const marker = typeof item.checked === 'boolean' && !node.ordered ? (item.checked ? '☑' : '□') :
              node.ordered ? (start + index).toString() + '.' : bullet;
            const itemBlocks = projectBlocks(item.children ?? [], listDepth + 1);
            if (node.ordered && typeof item.checked === 'boolean') orderedTaskMark(itemBlocks, item.checked);
            return withKey({ kind: 'item', key: '', marker, children: itemBlocks });
          }),
        };
        break;
      }
      case 'table':
        block = { kind: 'table', key: '', rows: tableRows(node) };
        break;
      case 'thematicBreak':
        block = { kind: 'hr', key: '' };
        break;
      case 'code':
        block = { kind: 'code', key: '', text: node.value ?? '', lang: node.lang ?? 'text' };
        break;
      case 'math':
        block = { kind: 'math', key: '', text: node.value ?? '' };
        break;
    }
    if (block) blocks.push(withKey(block));
  }
  return blocks;
}

export function nativeMarkdownBlocks(input: string, sourceIndices: number[] | undefined,
  disableLink: boolean): NativeMarkdownBlock[] {
  if (!input) return [];
  try {
    const ast = toNativeMarkdownAst(input, sourceIndices, disableLink);
    return projectBlocks(ast.children ?? []);
  } catch {
    return [withKey({ kind: 'paragraph', key: '', parts: [{ text: input, strong: false, italic: false }] })];
  }
}
