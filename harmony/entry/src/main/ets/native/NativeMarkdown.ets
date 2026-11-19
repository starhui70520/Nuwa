import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';

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
  checked?: boolean;
  source?: string;
}

interface InlinePart {
  text: string;
  strong: boolean;
  code: boolean;
  italic: boolean;
  strike: boolean;
  image?: boolean;
  source?: string;
  target?: string;
  citation?: number;
}

interface CodePart {
  text: string;
  kind: string;
}

@Component
export struct NativeMarkdown {
  @Prop content: string = '';
  @Prop fontScale: number = 1;
  @Prop hasCitations: boolean = false;
  onCitation: (number: number) => void = () => {};
  @State private copiedCodeKey: string = '';
  private cachedCitationMode: boolean = false;
  private cachedContent: string = '\u0000';
  private cachedBlocks: MarkdownBlock[] = [];
  private inlineCache: Map<string, InlinePart[]> = new Map<string, InlinePart[]>();
  private codeCache: Map<string, CodePart[]> = new Map<string, CodePart[]>();

  private codeCopyKey(text: string, index: number): string {
    return `${index}:${text}`;
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
          result.push({ kind: 'code', text: codeLines.join('\n'), level: 0, ordered: false, marker: '', lang: codeLanguage });
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

      if (/^(?:-{3,}|_{3,}|\*{3,})\s*$/.test(trimmed)) {
        flushParagraph();
        result.push({ kind: 'hr', text: '', level: 0, ordered: false, marker: '' });
        continue;
      }

      const imageMatch: RegExpMatchArray | null = trimmed.match(/^!\[([^\]]*)\]\((https:\/\/[^\s)]+)(?:\s+"[^"]*")?\)$/);
      if (imageMatch) {
        const safeSource = this.safeImageSource(imageMatch[2]);
        if (safeSource) {
          flushParagraph();
          result.push({ kind: 'image', text: imageMatch[1], source: safeSource, level: 0, ordered: false, marker: '' });
          continue;
        }
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

  private safeImageSource(target: string): string | null {
    try {
      const parsed = url.URL.parseURL(target);
      if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) {
        return null;
      }
      return parsed.href;
    } catch {
      return null;
    }
  }

  private inlineParts(value: string): InlinePart[] {
    if (this.cachedCitationMode !== this.hasCitations) {
      this.cachedCitationMode = this.hasCitations;
      this.inlineCache.clear();
    }
    const cached: InlinePart[] | undefined = this.inlineCache.get(value);
    if (cached) {
      return cached;
    }
    const parts: InlinePart[] = [];
    let rest: string = value;
    while (rest.length > 0) {
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
      if (next > 0) {
        parts.push({ text: rest.substring(0, next), strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(next);
        continue;
      }

      if (kind === 'bold') {
        const end: number = rest.indexOf('**', 2);
        if (end > 2) {
          parts.push({ text: rest.substring(2, end), strong: true, code: false, italic: false, strike: false });
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
        const labelEnd: number = rest.indexOf('](', 2);
        const urlEnd: number = labelEnd >= 0 ? rest.indexOf(')', labelEnd + 2) : -1;
        if (labelEnd > 1 && urlEnd > labelEnd + 2) {
          const label: string = rest.substring(2, labelEnd);
          const source: string | null = this.safeImageSource(rest.substring(labelEnd + 2, urlEnd));
          parts.push({ text: label, strong: false, code: false, italic: false, strike: false,
            image: source !== null, source: source ?? undefined });
          rest = rest.substring(urlEnd + 1);
          continue;
        }
        parts.push({ text: '!', strong: false, code: false, italic: false, strike: false });
        rest = rest.substring(1);
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
          const destination: string = rest.substring(labelEnd + 2, urlEnd);
          parts.push({ text: label, strong: false, code: false, italic: false, strike: false, target: destination });
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
        const end: number = rest.indexOf(delimiter, 1);
        if (end > 1) {
          parts.push({ text: rest.substring(1, end), strong: false, code: false, italic: true, strike: false });
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
  private inlineText(value: string, size: number) {
    Text() {
      ForEach(this.inlineParts(value), (part: InlinePart) => {
        if (part.image && part.source) {
          ImageSpan(part.source)
            .width(72)
            .height(72)
            .objectFit(ImageFit.Contain)
            .verticalAlign(ImageSpanAlignment.CENTER)
        } else if (part.citation !== undefined) {
          Span(part.text).fontSize(11 * this.fontScale).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_blue_text')).backgroundColor($r('app.color.native_chat_field'))
            .onClick(() => { this.onCitation(part.citation ?? 0); })
        } else {
          Span(part.text)
            .fontWeight(part.strong ? FontWeight.Bold : FontWeight.Regular)
            .fontStyle(part.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(part.target ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
            .decoration({ type: part.target ? TextDecorationType.Underline : (part.strike ? TextDecorationType.LineThrough : TextDecorationType.None) })
            .backgroundColor(part.code ? $r('app.color.native_chat_field') : Color.Transparent)
            .onClick(() => { if (part.target) { void this.openLink(part.target); } })
        }
      }, (part: InlinePart, index: number): string => `${index}:${part.text}:${part.target ?? ''}:${part.citation ?? 0}`)
    }
    .fontSize(size * this.fontScale)
    .lineHeight(size * this.fontScale * 1.75)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
  }

  private async copyCode(text: string, key: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      );
      this.copiedCodeKey = key;
      this.getUIContext().getPromptAction().showToast({ message: '已复制' });
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    }
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks(), (block: MarkdownBlock, index: number) => {
        if (block.kind === 'code') {
          Column() {
            Row() {
              Text(block.lang || 'text')
                .fontSize(12)
                .fontColor($r('app.color.native_chat_secondary'))
                .layoutWeight(1)
              Button(this.copiedCodeKey === this.codeCopyKey(block.text, index) ? '已复制' : '复制', { buttonStyle: ButtonStyleMode.TEXTUAL })
                .height(28)
                .fontSize(13)
                .onClick(() => { void this.copyCode(block.text, this.codeCopyKey(block.text, index)); })
            }
            .width('100%')
            .padding(6)
            .backgroundColor($r('app.color.native_chat_sidebar'))
            Text() {
              ForEach(this.codeParts(block.lang || 'text', block.text), (part: CodePart) => {
                Span(part.text).fontColor(this.codeColor(part.kind))
              }, (part: CodePart, partIndex: number): string => `${partIndex}:${part.kind}:${part.text.length}`)
            }
              .fontFamily('monospace')
              .fontSize(13 * this.fontScale)
              .fontColor($r('app.color.native_chat_primary'))
              .lineHeight(22 * this.fontScale)
              .width('100%')
              .padding(16)
              .copyOption(CopyOptions.LocalDevice)
          }
            .width('100%')
            .borderRadius(12)
            .clip(true)
            .backgroundColor($r('app.color.native_chat_field'))
        } else if (block.kind === 'heading') {
          this.inlineText(`**${block.text}**`, block.level === 1 ? 24 : (block.level === 2 ? 22 : (block.level === 3 ? 20 : 16)))
        } else if (block.kind === 'list') {
          Row({ space: 8 }) {
            Text(block.marker).fontSize(16).width(22).fontColor($r('app.color.native_chat_secondary'))
            this.inlineText(block.text, 16)
          }
          .width('100%')
          .padding({ left: block.level, top: 3, bottom: 3 })
        } else if (block.kind === 'hr') {
          Row() {}
            .width('100%')
            .height(1)
            .margin({ top: 8, bottom: 8 })
            .backgroundColor($r('app.color.native_chat_stroke'))
        } else if (block.kind === 'image' && block.source) {
          Column() {
            Image(block.source)
              .width('100%')
              .height(220)
              .objectFit(ImageFit.Contain)
              .draggable(false)
            if (block.text.length > 0) {
              Text(block.text)
                .fontSize(12 * this.fontScale)
                .fontColor($r('app.color.native_chat_secondary'))
                .width('100%')
            }
          }
          .width('100%')
          .padding(8)
          .backgroundColor($r('app.color.native_chat_field'))
          .borderRadius(10)
        } else if (block.kind === 'quote') {
          Row({ space: 14 }) {
            Text('│').fontSize(16).fontColor($r('app.color.native_chat_caption'))
            this.inlineText(block.text, 16)
          }
          .width('100%')
        } else if (block.kind === 'table') {
          Scroll() {
            Column({ space: 0 }) {
              ForEach(block.rows ?? [], (row: string[], rowIndex: number) => {
                Row({ space: 0 }) {
                  ForEach(row, (cell: string, cellIndex: number) => {
                    Column() {
                      this.inlineText(rowIndex === 0 && cell.length > 0 ? `**${cell}**` : cell, rowIndex === 0 ? 14 : 13)
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
          this.inlineText(block.text, 16)
        }
      }, (block: MarkdownBlock, index: number): string => `${block.kind}-${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
