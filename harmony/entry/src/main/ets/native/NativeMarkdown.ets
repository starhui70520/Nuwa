import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';
import { NativeLocale } from './NativeLocation';
import { NativeMathEquation } from './NativeMathEquation';
import {
  NativeMathPicture, NativeMathPictureRequest, nativeMathPictureKey, requestNativeMathPicture,
} from './NativeMathRenderQueue';
import { NativeMermaidPreview } from './NativeMermaidPreview';
import {
  findNativeDisplayMath, findNativeInlineMath, NativeMathMatch, NativeMathNode, NativeMathSpan, nativeMathSpans,
  parseNativeMath,
} from './NativeMarkdownMath';
import { NativeTheme } from './NativeSettings';

/**
 * Small native Markdown renderer for the Harmony chat surface.
 * Supports paragraphs, headings, emphasis, inline code, fenced code, links,
 * and ordered/unordered lists. Unknown syntax stays readable as plain text.
 */

interface MarkdownBlock {
  kind: string;
  text: string;
  level: number;
  ordered: boolean;
  marker: string;
  rows?: string[][];
  lang?: string;
  closed?: boolean;
  checked?: boolean;
  math?: NativeMathNode;
}

interface InlinePart {
  text: string;
  strong: boolean;
  code: boolean;
  italic: boolean;
  strike: boolean;
  target?: string;
  citation?: number;
  math?: NativeMathSpan[];
  formula?: string;
}

interface CodePart {
  text: string;
  kind: string;
}

interface NativeRenderedFormula {
  key: string;
  picture: NativeMathPicture;
}

@Component
export struct NativeMarkdown {
  @Prop @Watch('scheduleMathPictures') content: string = '';
  @Prop @Watch('scheduleMathPictures') fontScale: number = 1;
  @Prop @Watch('scheduleMathPictures') muted: boolean = false;
  @Prop @Watch('scheduleMathPictures') disableLinks: boolean = false;
  @Prop hasCitations: boolean = false;
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop @Watch('scheduleMathPictures') theme: NativeTheme = 'system';
  @Prop @Watch('scheduleMathPictures') loading: boolean = false;
  onCitation: (number: number) => void = () => {};
  @State private copiedCodeKey: string = '';
  @State private mermaidCodeIndices: number[] = [];
  @State private mathPictures: NativeRenderedFormula[] = [];
  @State private contentWidth: number = 0;
  private cachedCitationMode: boolean = false;
  private cachedLinkMode: boolean = false;
  private cachedContent: string = '\u0000';
  private cachedBlocks: MarkdownBlock[] = [];
  private inlineCache: Map<string, InlinePart[]> = new Map<string, InlinePart[]>();
  private codeCache: Map<string, CodePart[]> = new Map<string, CodePart[]>();
  private mathMounted: boolean = false;
  private mathTimer: number = -1;
  private mathGeneration: number = 0;
  private mathColor: string = '#0F1115';
  private mathDensity: number = 1;
  private mathFontRatio: number = 1;

  aboutToAppear(): void {
    // Chat List mounts only the displayed rows and its small render cache.
    this.mathMounted = true;
    this.scheduleMathPictures();
  }

  aboutToDisappear(): void {
    this.mathMounted = false;
    this.mathGeneration++;
    clearTimeout(this.mathTimer);
  }

  private bodySize(): number {
    return this.muted ? 14 : 16;
  }

  private bodyColor(): Resource {
    return this.muted ? $r('app.color.native_chat_secondary') : $r('app.color.native_chat_primary');
  }

  private headingSize(level: number): number {
    if (this.muted) return this.bodySize();
    return level === 1 ? 24 : level === 2 ? 22 : level === 3 ? 20 : 16;
  }

  private prepareMathPresentation(): void {
    const context = this.getUIContext();
    const density = context.vp2px(1);
    this.mathDensity = Math.round(Math.min(3.5, Math.max(1, density)) * 100) / 100;
    this.mathFontRatio = context.fp2px(16) / context.vp2px(16);
    if (this.theme === 'dark' || this.theme === 'light') {
      this.mathColor = this.muted ? (this.theme === 'dark' ? '#CFD3D6' : '#61666B') :
        (this.theme === 'dark' ? '#F9FAFB' : '#0F1115');
      return;
    }
    const fallback = this.muted ? 0x61666B : 0x0F1115;
    try {
      const color = context.getHostContext()?.resourceManager.getColorSync(this.bodyColor().id);
      this.mathColor = '#' + ((color ?? fallback) & 0xFFFFFF).toString(16).padStart(6, '0');
    } catch {
      this.mathColor = '#' + fallback.toString(16).padStart(6, '0');
    }
  }

  private mathRequest(source: string, size: number, display: boolean, bold: boolean = false): NativeMathPictureRequest {
    return {
      source, fontSize: Math.round(size * this.fontScale * this.mathFontRatio * 100) / 100,
      display, color: this.mathColor, density: this.mathDensity, bold,
    };
  }

  private collectInlinePictures(entries: Map<string, NativeMathPictureRequest>, text: string, size: number): void {
    for (const part of this.inlineParts(text)) {
      if (part.formula) {
        const request = this.mathRequest(part.formula, size, false, part.strong);
        entries.set(nativeMathPictureKey(request), request);
      }
    }
  }

  private mathRequests(): Map<string, NativeMathPictureRequest> {
    const entries = new Map<string, NativeMathPictureRequest>();
    for (const block of this.blocks()) {
      if (block.kind === 'math') {
        const request = this.mathRequest(block.text, this.bodySize(), true);
        entries.set(nativeMathPictureKey(request), request);
      } else if (block.kind === 'heading') {
        this.collectInlinePictures(entries, '**' + block.text + '**', this.headingSize(block.level));
      } else if (block.kind === 'table') {
        const rows = block.rows ?? [];
        for (let index = 0; index < rows.length; index++) {
          for (const cell of rows[index]) {
            this.collectInlinePictures(entries, index === 0 && cell ? '**' + cell + '**' : cell,
              this.muted || index === 0 ? 14 : 13);
          }
        }
      } else if (block.kind === 'paragraph' || block.kind === 'list' || block.kind === 'quote') {
        this.collectInlinePictures(entries, block.text, this.bodySize());
      }
    }
    return entries;
  }

  private scheduleMathPictures(): void {
    const generation = ++this.mathGeneration;
    clearTimeout(this.mathTimer);
    if (!this.mathMounted || this.loading) {
      if (this.mathPictures.length) this.mathPictures = [];
      return;
    }
    this.mathTimer = setTimeout(() => { this.prepareMathPictures(generation); }, 40);
  }

  private prepareMathPictures(generation: number): void {
    if (this.mathGeneration !== generation || this.loading || !this.mathMounted) return;
    this.prepareMathPresentation();
    const requests = this.mathRequests();
    this.mathPictures = this.mathPictures.filter((item: NativeRenderedFormula): boolean => requests.has(item.key));
    let count = 0;
    for (const key of requests.keys()) {
      if (count++ >= 48) break;
      const request = requests.get(key);
      if (request && !this.mathPictures.some((item: NativeRenderedFormula): boolean => item.key === key)) {
        void requestNativeMathPicture(request).then((picture: NativeMathPicture | null): void => {
          if (picture && this.mathMounted && this.mathGeneration === generation) {
            const received: NativeRenderedFormula = { key, picture };
            this.mathPictures = [...this.mathPictures, received];
          }
        });
      }
    }
  }

  private mathPicture(source: string, size: number, display: boolean, bold: boolean = false): NativeMathPicture | null {
    if (!this.mathPictures.length) return null;
    const key = nativeMathPictureKey(this.mathRequest(source, size, display, bold));
    return this.mathPictures.find((item: NativeRenderedFormula): boolean => item.key === key)?.picture ?? null;
  }

  private inlinePictureScale(picture: NativeMathPicture, maxWidth: number): number {
    const available = maxWidth > 0 ? maxWidth : this.contentWidth || 320;
    return Math.min(1, available / picture.width);
  }

  private inlineWidth(source: string, size: number, bold: boolean, maxWidth: number): number {
    const picture = this.mathPicture(source, size, false, bold);
    return picture ? picture.width * this.inlinePictureScale(picture, maxWidth) : 0;
  }

  private inlineHeight(source: string, size: number, bold: boolean, maxWidth: number): number {
    const picture = this.mathPicture(source, size, false, bold);
    return picture ? picture.height * this.inlinePictureScale(picture, maxWidth) : 0;
  }

  private inlineDepth(source: string, size: number, bold: boolean, maxWidth: number): number {
    const picture = this.mathPicture(source, size, false, bold);
    return picture ? picture.depth * this.inlinePictureScale(picture, maxWidth) : 0;
  }

  private inlineAccessibilityText(value: string): string {
    const parts = this.inlineParts(value);
    if (!this.mathPictures.length || !parts.some((part: InlinePart): boolean => !!part.formula) ||
      parts.some((part: InlinePart): boolean => !!part.target || !!part.citation)) return '';
    return parts.map<string>((part: InlinePart): string => part.formula ?? part.text).join('');
  }

  private codeCopyKey(text: string, index: number): string {
    return `${index}:${text}`;
  }

  private label(chinese: string, english: string): string {
    return this.locale === 'en-US' ? english : chinese;
  }

  private isMermaid(block: MarkdownBlock): boolean {
    return block.kind === 'code' && block.lang?.toLowerCase() === 'mermaid';
  }

  private blockKey(block: MarkdownBlock, index: number): string {
    const id = block.kind + '-' + index;
    if (!this.isMermaid(block)) return id;
    if (this.loading && !block.closed && !this.mermaidCodeIndices.includes(index)) return id + '-loading';
    return id + '-' + block.text;
  }

  private setMermaidMode(index: number, code: boolean): void {
    if (code && !this.mermaidCodeIndices.includes(index)) {
      this.mermaidCodeIndices = [...this.mermaidCodeIndices, index];
    } else if (!code) {
      this.mermaidCodeIndices = this.mermaidCodeIndices.filter((item: number): boolean => item !== index);
    }
  }

  private blocks(): MarkdownBlock[] {
    if (this.content === this.cachedContent) {
      return this.cachedBlocks;
    }
    const lines: string[] = this.content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const result: MarkdownBlock[] = [];
    let paragraph: string[] = [];
    let codeLines: string[] = [];
    let inCode: boolean = false;
    let codeLanguage: string = 'text';

    const flushParagraph = (): void => {
      if (paragraph.length > 0) {
        result.push({ kind: 'paragraph', text: paragraph.join('\n'), level: 0, ordered: false, marker: '' });
        paragraph = [];
      }
    };

    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        if (inCode) {
          result.push({
            kind: 'code', text: codeLines.join('\n'), level: 0, ordered: false, marker: '',
            lang: codeLanguage, closed: true,
          });
          codeLines = [];
          inCode = false;
        } else {
          flushParagraph();
          inCode = true;
          codeLanguage = trimmed.substring(3).trim().split(/\s+/)[0] || 'text';
        }
        continue;
      }
      if (inCode) {
        codeLines.push(line);
        continue;
      }
      if (trimmed.length === 0) {
        flushParagraph();
        continue;
      }

      const equation = findNativeDisplayMath(lines, i);
      if (equation) {
        flushParagraph();
        result.push({
          kind: 'math', text: equation.formula, math: parseNativeMath(equation.formula) ?? undefined,
          level: 0, ordered: false, marker: '',
        });
        i = equation.end - 1;
        continue;
      }

      if (/^(?:-{3,}|_{3,}|\*{3,})\s*$/.test(trimmed)) {
        flushParagraph();
        result.push({ kind: 'hr', text: '', level: 0, ordered: false, marker: '' });
        continue;
      }

      if (trimmed.startsWith('>')) {
        flushParagraph();
        const quoted: string = trimmed.replace(/^>\s?/, '');
        const previous: MarkdownBlock | undefined = result.length > 0 ? result[result.length - 1] : undefined;
        if (previous && previous.kind === 'quote') {
          previous.text = `${previous.text}\n${quoted}`;
        } else {
          result.push({ kind: 'quote', text: quoted, level: 0, ordered: false, marker: '' });
        }
        continue;
      }

      if (i + 1 < lines.length && trimmed.indexOf('|') >= 0 && this.isTableSeparator(lines[i + 1])) {
        flushParagraph();
        const rows: string[][] = [this.tableCells(line)];
        i += 2;
        while (i < lines.length && lines[i].trim().length > 0 && lines[i].indexOf('|') >= 0) {
          const row: string[] = this.tableCells(lines[i]);
          while (row.length < rows[0].length) {
            row.push('');
          }
          rows.push(row.slice(0, rows[0].length));
          i++;
        }
        i--;
        result.push({ kind: 'table', text: '', level: 0, ordered: false, marker: '', rows: rows });
        continue;
      }

      let headingLevel: number = 0;
      while (headingLevel < 6 && trimmed.charAt(headingLevel) === '#') {
        headingLevel++;
      }
      if (headingLevel > 0 && trimmed.charAt(headingLevel) === ' ') {
        flushParagraph();
        result.push({ kind: 'heading', text: trimmed.substring(headingLevel + 1), level: headingLevel, ordered: false, marker: '' });
        continue;
      }

      const bulletPrefix: string = line.match(/^\s*[-*+]\s+/)?.[0] ?? '';
      const numberMatch: RegExpMatchArray | null = line.match(/^\s*(\d+)[.)]\s+/);
      if (bulletPrefix.length > 0 || numberMatch !== null) {
        flushParagraph();
        const prefix: string = bulletPrefix.length > 0 ? bulletPrefix : (numberMatch?.[0] ?? '');
        const ordered: boolean = numberMatch !== null;
        const taskMatch: RegExpMatchArray | null = line.substring(prefix.length).match(/^\[([ xX])\]\s+/);
        const marker: string = taskMatch ? (taskMatch[1].toLowerCase() === 'x' ? '☑' : '□') :
          (ordered ? `${numberMatch?.[1]}.` : '•');
        const indent: number = Math.min(32, Math.floor(prefix.length / 2) * 14);
        result.push({
          kind: 'list',
          text: line.substring(prefix.length + (taskMatch ? taskMatch[0].length : 0)),
          level: indent,
          ordered: ordered,
          marker: marker,
          checked: taskMatch ? taskMatch[1].toLowerCase() === 'x' : undefined,
        });
        continue;
      }
      paragraph.push(line);
    }

    if (inCode) {
      result.push({ kind: 'code', text: codeLines.join('\n'), level: 0, ordered: false, marker: '', lang: codeLanguage });
    }
    flushParagraph();
    this.cachedContent = this.content;
    this.cachedBlocks = result;
    return result;
  }

  private tableCells(line: string): string[] {
    const source: string = line.trim();
    const start: number = source.startsWith('|') ? 1 : 0;
    const end: number = source.endsWith('|') ? source.length - 1 : source.length;
    const cells: string[] = [];
    let cell: string = '';
    for (let i: number = start; i < end; i++) {
      const char: string = source.charAt(i);
      if (char === '\\' && i + 1 < end && source.charAt(i + 1) === '|') {
        cell += '|';
        i++;
      } else if (char === '|') {
        cells.push(cell.trim());
        cell = '';
      } else {
        cell += char;
      }
    }
    cells.push(cell.trim());
    return cells;
  }

  private isTableSeparator(line: string): boolean {
    const cells: string[] = this.tableCells(line);
    return cells.length > 0 && cells.every((cell: string): boolean => /^:?-{3,}:?$/.test(cell));
  }

  private imageLinkTarget(target: string): string | undefined {
    try {
      const address = /^[a-z][a-z\d+.-]*:\/\//i.test(target) ? target : 'https://' + target;
      const parsed = url.URL.parseURL(address);
      if ((parsed.protocol === 'https:' || parsed.protocol === 'http:') &&
        parsed.hostname && !parsed.username && !parsed.password) {
        return parsed.href;
      }
    } catch {
      return undefined;
    }
    return undefined;
  }

  private mathPart(value: string, match: NativeMathMatch, strong: boolean, italic: boolean): InlinePart {
    const math = parseNativeMath(match.formula);
    return {
      text: math ? match.formula : value.slice(match.start, match.end),
      strong, italic, code: false, strike: false, math: math ? nativeMathSpans(math) : undefined,
      formula: match.formula,
    };
  }

  private addEmphasis(parts: InlinePart[], value: string, strong: boolean, italic: boolean): void {
    if (this.disableLinks && value.includes('[')) {
      for (const part of this.inlineParts(value)) {
        parts.push({
          text: part.text, strong: strong || part.strong, italic: italic || part.italic,
          code: part.code, strike: part.strike, target: part.target, citation: part.citation,
          math: part.math, formula: part.formula,
        });
      }
      return;
    }
    let offset = 0;
    let match = findNativeInlineMath(value);
    while (match) {
      if (match.start > offset) {
        parts.push({ text: value.slice(offset, match.start), strong, italic, code: false, strike: false });
      }
      parts.push(this.mathPart(value, match, strong, italic));
      offset = match.end;
      match = findNativeInlineMath(value, offset);
    }
    if (offset < value.length) {
      parts.push({ text: value.slice(offset), strong, italic, code: false, strike: false });
    }
  }

  private emphasisEnd(value: string, delimiter: string): number {
    let end = value.indexOf(delimiter, delimiter.length);
    let match = findNativeInlineMath(value, delimiter.length);
    while (match && end >= 0 && match.start < end) {
      if (match.end > end) end = value.indexOf(delimiter, match.end);
      match = findNativeInlineMath(value, match.end);
    }
    return end;
  }

  private inlineParts(value: string): InlinePart[] {
    if (this.cachedCitationMode !== this.hasCitations || this.cachedLinkMode !== this.disableLinks) {
      this.cachedCitationMode = this.hasCitations;
      this.cachedLinkMode = this.disableLinks;
      this.inlineCache.clear();
    }
    const cached: InlinePart[] | undefined = this.inlineCache.get(value);
    if (cached) {
      return cached;
    }
    const parts: InlinePart[] = [];
    let rest: string = value;
    let formula = findNativeInlineMath(value);
    while (rest.length > 0) {
      const offset = value.length - rest.length;
      if (formula && formula.start < offset) formula = findNativeInlineMath(value, offset);
      const boldAt: number = rest.indexOf('**');
      const codeAt: number = rest.indexOf('`');
      const linkAt: number = rest.indexOf('[');
      const imageAt: number = rest.indexOf('![');
      const strikeAt: number = rest.indexOf('~~');
      let italicAt: number = rest.indexOf('*');
      const underscoreAt: number = rest.indexOf('_');
      if (italicAt >= 0 && rest.substring(italicAt, italicAt + 2) === '**') {
        italicAt = rest.indexOf('*', italicAt + 2);
      }
      if (underscoreAt >= 0 && (italicAt < 0 || underscoreAt < italicAt)) {
        italicAt = underscoreAt;
      }
      let next: number = rest.length;
      let kind: string = '';
      if (boldAt >= 0 && boldAt < next) { next = boldAt; kind = 'bold'; }
      if (codeAt >= 0 && codeAt < next) { next = codeAt; kind = 'code'; }
      if (imageAt >= 0 && imageAt < next) { next = imageAt; kind = 'image'; }
      if (linkAt >= 0 && linkAt < next) { next = linkAt; kind = 'link'; }
      if (strikeAt >= 0 && strikeAt < next) { next = strikeAt; kind = 'strike'; }
      if (italicAt >= 0 && italicAt < next) { next = italicAt; kind = 'italic'; }
      if (formula && formula.start - offset < next) { next = formula.start - offset; kind = 'math'; }
      if (next > 0) {
        parts.push({ text: rest.substring(0, next), strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(next);
        continue;
      }

      if (kind === 'math' && formula) {
        parts.push(this.mathPart(value, formula, false, false));
        rest = value.slice(formula.end);
        formula = findNativeInlineMath(value, formula.end);
      } else if (kind === 'bold') {
        const end: number = this.emphasisEnd(rest, '**');
        if (end > 2) {
          this.addEmphasis(parts, rest.substring(2, end), true, false);
          rest = rest.substring(end + 2);
          continue;
        }
        parts.push({ text: '**', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(2);
      } else if (kind === 'code') {
        const end: number = rest.indexOf('`', 1);
        if (end > 1) {
          parts.push({ text: rest.substring(1, end), strong: false, code: true, italic: false, strike: false });
          rest = rest.substring(end + 1);
          continue;
        }
        parts.push({ text: '`', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(1);
      } else if (kind === 'image') {
        const label = rest.match(/^!\[([^\]\n]*)\]\(/);
        const destination = label ? rest.slice(label[0].length).match(
          /^[ \t]*(?:<([^<>\n]+)>|((?:[^\s()<>]|\([^\s()]*\))+))(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?[ \t]*\)/) : null;
        if (label && destination) {
          const target = this.imageLinkTarget(destination[1] ?? destination[2]);
          parts.push({ text: target ?? label[1], strong: false, code: false, italic: false, strike: false, target });
          rest = rest.slice(label[0].length + destination[0].length);
          continue;
        }
        parts.push({ text: '![', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(2);
      } else if (kind === 'link') {
        if (this.hasCitations) {
          const marker = rest.match(/^\[citation:([1-9][0-9]{0,2})\]/);
          if (marker) {
            parts.push({ text: marker[1], citation: Number(marker[1]), strong: true, code: false,
              italic: false, strike: false });
            rest = rest.substring(marker[0].length);
            continue;
          }
        }
        const labelEnd: number = rest.indexOf('](', 1);
        const urlEnd: number = labelEnd >= 0 ? rest.indexOf(')', labelEnd + 2) : -1;
        if (labelEnd > 1 && urlEnd > labelEnd + 2) {
          const label: string = rest.substring(1, labelEnd);
          if (this.disableLinks) {
            for (const part of this.inlineParts(label)) {
              parts.push(part);
            }
          } else {
            parts.push({ text: label, strong: false, code: false, italic: false, strike: false,
              target: rest.substring(labelEnd + 2, urlEnd) });
          }
          rest = rest.substring(urlEnd + 1);
          continue;
        }
        parts.push({ text: '[', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(1);
      } else if (kind === 'strike') {
        const end: number = rest.indexOf('~~', 2);
        if (end > 2) {
          parts.push({ text: rest.substring(2, end), strong: false, code: false, italic: false, strike: true });
          rest = rest.substring(end + 2);
          continue;
        }
        parts.push({ text: '~~', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(2);
      } else if (kind === 'italic') {
        const delimiter: string = rest.charAt(0);
        const end: number = this.emphasisEnd(rest, delimiter);
        if (end > 1) {
          this.addEmphasis(parts, rest.substring(1, end), false, true);
          rest = rest.substring(end + 1);
          continue;
        }
        parts.push({ text: delimiter, strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(1);
      } else {
        break;
      }
    }
    if (this.inlineCache.size > 256) {
      this.inlineCache.clear();
    }
    this.inlineCache.set(value, parts);
    return parts;
  }

  private async openLink(target: string): Promise<void> {
    try {
      const link = url.URL.parseURL(target);
      if ((link.protocol === 'https:' || link.protocol === 'http:') && !link.username && !link.password) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.openLink(link.href, { appLinkingOnly: false });
      }
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
    }
  }

  private pushCodePart(parts: CodePart[], text: string, kind: string): void {
    if (!text) {
      return;
    }
    const previous = parts.length > 0 ? parts[parts.length - 1] : undefined;
    if (previous && previous.kind === kind) {
      previous.text += text;
    } else {
      parts.push({ text: text, kind: kind });
    }
  }

  private codeParts(language: string, value: string): CodePart[] {
    const cacheKey = `${language.toLowerCase()}\n${value}`;
    const cached = this.codeCache.get(cacheKey);
    if (cached) {
      return cached;
    }
    const aliases: Map<string, string> = new Map<string, string>([
      ['js', 'javascript'], ['ts', 'typescript'], ['tsx', 'typescript'], ['py', 'python'],
      ['sh', 'bash'], ['shell', 'bash'], ['zsh', 'bash'], ['yml', 'yaml'], ['rs', 'rust'],
      ['kt', 'kotlin'], ['golang', 'go'], ['c++', 'cpp'], ['c#', 'csharp'],
    ]);
    const rawLanguage = language.toLowerCase();
    const normalized = aliases.get(rawLanguage) ?? rawLanguage;
    const supported = ['javascript', 'typescript', 'jsx', 'python', 'bash', 'json', 'java', 'kotlin',
      'c', 'cpp', 'csharp', 'go', 'rust', 'swift', 'sql', 'yaml', 'toml', 'ini', 'ruby', 'php',
      'css', 'scss', 'html', 'xml', 'docker', 'dockerfile', 'powershell', 'diff', 'markdown'];
    const parts: CodePart[] = [];
    if (supported.indexOf(normalized) < 0) {
      parts.push({ text: value, kind: 'plain' });
      this.codeCache.set(cacheKey, parts);
      return parts;
    }
    const keywords = normalized === 'python'
      ? 'and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield'
      : normalized === 'bash'
        ? 'case do done elif else esac fi for function if in select then time until while coproc'
        : normalized === 'json'
          ? 'true false null'
          : normalized === 'sql'
            ? 'select from where insert into values update set delete create table alter drop join left right inner outer on as group by order limit offset null true false and or not count sum'
            : 'abstract as async await break case catch class const continue default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of package private protected public return static super switch this throw true try typeof undefined var void while with yield';
    const keywordSet: Set<string> = new Set<string>(keywords.split(' '));
    const constants: Set<string> = new Set<string>(['true', 'false', 'null', 'undefined', 'True', 'False', 'None', 'NaN', 'Infinity']);
    const hashCommentLanguages = ['python', 'bash', 'yaml', 'toml', 'ini', 'ruby', 'powershell', 'docker', 'dockerfile', 'makefile'];
    let index = 0;
    let inBlockComment = false;
    while (index < value.length) {
      if (inBlockComment) {
        const close = value.indexOf('*/', index);
        if (close < 0) {
          this.pushCodePart(parts, value.substring(index), 'comment');
          index = value.length;
        } else {
          this.pushCodePart(parts, value.substring(index, close + 2), 'comment');
          index = close + 2;
          inBlockComment = false;
        }
        continue;
      }
      if (value.substring(index, index + 2) === '/*') {
        const close = value.indexOf('*/', index + 2);
        if (close < 0) {
          this.pushCodePart(parts, value.substring(index), 'comment');
          index = value.length;
        } else {
          this.pushCodePart(parts, value.substring(index, close + 2), 'comment');
          index = close + 2;
        }
        continue;
      }
      const char = value.charAt(index);
      if (value.substring(index, index + 2) === '//') {
        let end = value.indexOf('\n', index);
        if (end < 0) { end = value.length; }
        this.pushCodePart(parts, value.substring(index, end), 'comment');
        index = end;
        continue;
      }
      if (char === '#' && hashCommentLanguages.indexOf(normalized) >= 0) {
        let end = value.indexOf('\n', index);
        if (end < 0) { end = value.length; }
        this.pushCodePart(parts, value.substring(index, end), 'comment');
        index = end;
        continue;
      }
      if ((char === '"' || char === '\'' || char === '`') && normalized !== 'markdown') {
        const quote = char;
        let end = index + 1;
        while (end < value.length) {
          if (value.charAt(end) === '\\') {
            end += 2;
            continue;
          }
          if (value.charAt(end) === quote) {
            end++;
            break;
          }
          end++;
        }
        this.pushCodePart(parts, value.substring(index, end), 'string');
        index = end;
        continue;
      }
      if (/[0-9]/.test(char)) {
        let end = index + 1;
        while (end < value.length && /[A-Za-z0-9_.]/.test(value.charAt(end))) { end++; }
        this.pushCodePart(parts, value.substring(index, end), 'number');
        index = end;
        continue;
      }
      const identifier = value.substring(index).match(/^[A-Za-z_$][A-Za-z0-9_$]*/);
      if (identifier) {
        const word = identifier[0];
        const end = index + word.length;
        const nextChar = value.substring(end).match(/^\s*(.)/)?.[1] ?? '';
        const kind = constants.has(word) ? 'constant' : (keywordSet.has(word) ? 'keyword' :
          (nextChar === '(' ? 'function' : 'plain'));
        this.pushCodePart(parts, word, kind);
        index = end;
        continue;
      }
      this.pushCodePart(parts, char, 'plain');
      index++;
    }
    if (this.codeCache.size > 64) {
      this.codeCache.clear();
    }
    this.codeCache.set(cacheKey, parts);
    return parts;
  }

  private codeColor(kind: string) {
    if (kind === 'comment') {
      return $r('app.color.native_chat_secondary');
    }
    if (kind === 'keyword' || kind === 'function') {
      return $r('app.color.native_chat_blue_text');
    }
    if (kind === 'string') {
      return '#32824A';
    }
    if (kind === 'number' || kind === 'constant') {
      return '#A56700';
    }
    return $r('app.color.native_chat_primary');
  }

  @Builder
  private displayedFormula(picture: NativeMathPicture, source: string) {
    Scroll() {
      Image(picture.png)
        .width(picture.width)
        .height(picture.height)
        .objectFit(ImageFit.Contain)
        .accessibilityText(source)
        .draggable(false)
    }
    .width('100%')
    .align(Alignment.Center)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .padding(4)
  }

  @Builder
  private inlineText(value: string, size: number, maxWidth: number = 0) {
    Text() {
      ForEach(this.inlineParts(value), (part: InlinePart) => {
        if (part.citation !== undefined) {
          Span(part.text).fontSize(11 * this.fontScale).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_blue_text')).backgroundColor($r('app.color.native_chat_field'))
            .onClick(() => { this.onCitation(part.citation ?? 0); })
        } else if (part.formula && this.mathPicture(part.formula, size, false, part.strong)) {
          ImageSpan(this.mathPicture(part.formula, size, false, part.strong)?.png ?? '')
            .width(this.inlineWidth(part.formula, size, part.strong, maxWidth))
            .height(this.inlineHeight(part.formula, size, part.strong, maxWidth))
            .objectFit(ImageFit.Contain)
            .verticalAlign(ImageSpanAlignment.BASELINE)
            .baselineOffset(LengthMetrics.vp(-this.inlineDepth(part.formula, size, part.strong, maxWidth)))
        } else if (part.math) {
          ForEach(part.math, (span: NativeMathSpan) => {
            Span(span.text)
              .fontFamily('serif')
              .fontSize(size * this.fontScale * span.scale)
              .baselineOffset(LengthMetrics.fp(size * this.fontScale * span.offset))
              .fontColor(this.bodyColor())
              .fontStyle(span.italic || part.italic ? FontStyle.Italic : FontStyle.Normal)
              .fontWeight(span.bold || part.strong ? FontWeight.Bold : FontWeight.Regular)
          }, (_span: NativeMathSpan, index: number): string => index.toString())
        } else {
          Span(part.text)
            .fontWeight(part.strong ? FontWeight.Bold : FontWeight.Regular)
            .fontStyle(part.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(part.target ? $r('app.color.native_chat_blue_text') : this.bodyColor())
            .decoration({ type: part.target ? TextDecorationType.Underline : (part.strike ? TextDecorationType.LineThrough : TextDecorationType.None) })
            .backgroundColor(part.code ? $r('app.color.native_chat_field') : Color.Transparent)
            .onClick(() => { if (part.target) { void this.openLink(part.target); } })
        }
      }, (part: InlinePart, index: number): string => `${index}:${part.text}:${part.target ?? ''}:${part.citation ?? 0}`)
    }
    .fontSize(size * this.fontScale)
    .lineHeight(size * this.fontScale * (this.muted ? 24 / 14 : 1.75))
    .width('100%')
    .accessibilityText(this.inlineAccessibilityText(value))
    .copyOption(CopyOptions.LocalDevice)
  }

  private async copyCode(text: string, key: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      );
      this.copiedCodeKey = key;
      this.getUIContext().getPromptAction().showToast({ message: this.label('已复制', 'Copied') });
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: this.label('复制失败', 'Copy failed') });
    }
  }

  @Builder
  private mermaidModeButton(index: number, label: string, code: boolean) {
    Button(label, { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(28)
      .padding({ left: 9, right: 9 })
      .borderRadius(7)
      .fontSize(13)
      .fontColor($r('app.color.native_chat_primary'))
      .backgroundColor(this.mermaidCodeIndices.includes(index) === code ?
        $r('app.color.native_chat_field') : Color.Transparent)
      .accessibilitySelected(this.mermaidCodeIndices.includes(index) === code)
      .onClick(() => { this.setMermaidMode(index, code); })
  }

  @Builder
  private codeBlock(block: MarkdownBlock, index: number) {
    Column() {
      Row() {
        if (this.isMermaid(block)) {
          Row({ space: 4 }) {
            this.mermaidModeButton(index, this.label('图表', 'Diagram'), false)
            this.mermaidModeButton(index, this.label('代码', 'Code'), true)
          }
          .accessibilityDescription(this.label('Mermaid 图表与代码切换', 'Toggle between Mermaid diagram and code'))
          Blank().layoutWeight(1)
        } else {
          Text(block.lang || 'text')
            .fontSize(12)
            .fontColor($r('app.color.native_chat_secondary'))
            .layoutWeight(1)
        }
        Button(this.copiedCodeKey === this.codeCopyKey(block.text, index) ?
          this.label('已复制', 'Copied') : this.label('复制', 'Copy'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(28)
          .fontSize(13)
          .onClick(() => { void this.copyCode(block.text, this.codeCopyKey(block.text, index)); })
      }
      .width('100%')
      .padding(6)
      .backgroundColor($r('app.color.native_chat_sidebar'))
      if (this.isMermaid(block) && !this.mermaidCodeIndices.includes(index)) {
        if (this.loading && !block.closed) {
          Text(this.label('图表生成中...', 'Rendering diagram...'))
            .width('100%').height(160).textAlign(TextAlign.Center)
            .fontSize(14).fontColor($r('app.color.native_chat_secondary'))
        } else {
          NativeMermaidPreview({ source: block.text, locale: this.locale, theme: this.theme })
        }
      } else {
        Text() {
          ForEach(this.codeParts(block.lang || 'text', block.text), (part: CodePart) => {
            Span(part.text).fontColor(this.codeColor(part.kind))
          }, (part: CodePart, partIndex: number): string => partIndex + ':' + part.kind + ':' + part.text.length)
        }
        .fontFamily('monospace')
        .fontSize(13 * this.fontScale)
        .fontColor($r('app.color.native_chat_primary'))
        .lineHeight(22 * this.fontScale)
        .width('100%')
        .padding(16)
        .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .borderRadius(12)
    .clip(true)
    .backgroundColor($r('app.color.native_chat_field'))
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks(), (block: MarkdownBlock, index: number) => {
        if (block.kind === 'code') {
          this.codeBlock(block, index)
        } else if (block.kind === 'math') {
          if (this.mathPicture(block.text, this.bodySize(), true)) {
            this.displayedFormula(this.mathPicture(block.text, this.bodySize(), true)!, block.text)
          } else {
            NativeMathEquation({ expression: block.math ?? null, source: block.text,
              formulaFontSize: (this.bodySize() + 1) * this.fontScale })
          }
        } else if (block.kind === 'heading') {
          this.inlineText(`**${block.text}**`, this.headingSize(block.level))
        } else if (block.kind === 'list') {
          Row({ space: 8 }) {
            Text(block.marker).fontSize(this.muted ? this.bodySize() * this.fontScale : 16).width(22)
              .fontColor($r('app.color.native_chat_secondary'))
            this.inlineText(block.text, this.bodySize())
          }
          .width('100%')
          .padding({ left: block.level, top: 3, bottom: 3 })
        } else if (block.kind === 'hr') {
          Row() {}
            .width('100%')
            .height(1)
            .margin({ top: 8, bottom: 8 })
            .backgroundColor($r('app.color.native_chat_stroke'))
        } else if (block.kind === 'quote') {
          Row({ space: 14 }) {
            Text('│').fontSize(16).fontColor($r('app.color.native_chat_caption'))
            this.inlineText(block.text, this.bodySize())
          }
          .width('100%')
        } else if (block.kind === 'table') {
          Scroll() {
            Column({ space: 0 }) {
              ForEach(block.rows ?? [], (row: string[], rowIndex: number) => {
                Row({ space: 0 }) {
                  ForEach(row, (cell: string, cellIndex: number) => {
                    Column() {
                      this.inlineText(rowIndex === 0 && cell.length > 0 ? `**${cell}**` : cell,
                        this.muted || rowIndex === 0 ? 14 : 13, 104)
                    }
                    .width(128)
                    .padding({ left: cellIndex === 0 ? 0 : 12, right: 12, top: 10, bottom: 10 })
                    .border({ width: { bottom: 1 }, color: $r('app.color.native_chat_stroke'), radius: 0 })
                    .backgroundColor(rowIndex === 0 ? $r('app.color.native_chat_sidebar') : Color.Transparent)
                  }, (cell: string, cellIndex: number): string => `${rowIndex}-${cellIndex}`)
                }
              }, (row: string[], rowIndex: number): string => `table-row-${rowIndex}`)
            }
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        } else {
          this.inlineText(block.text, this.bodySize())
        }
      }, (block: MarkdownBlock, index: number): string => this.blockKey(block, index))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (width > 0 && width !== this.contentWidth) this.contentWidth = width;
    })
  }
}
