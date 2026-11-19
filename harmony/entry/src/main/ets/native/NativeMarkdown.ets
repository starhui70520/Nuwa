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
}

interface InlinePart {
  text: string;
  strong: boolean;
  code: boolean;
  italic: boolean;
  strike: boolean;
  target?: string;
}

@Component
export struct NativeMarkdown {
  @Prop content: string = '';
  @Prop fontScale: number = 1;
  @State private copiedCodeKey: string = '';
  private cachedContent: string = '\u0000';
  private cachedBlocks: MarkdownBlock[] = [];
  private inlineCache: Map<string, InlinePart[]> = new Map<string, InlinePart[]>();

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
        const marker: string = ordered ? `${numberMatch?.[1]}.` : '•';
        const indent: number = Math.min(32, Math.floor(prefix.length / 2) * 14);
        result.push({
          kind: 'list',
          text: line.substring(prefix.length),
          level: indent,
          ordered: ordered,
          marker: marker,
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

  private inlineParts(value: string): InlinePart[] {
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
      } else if (kind === 'link') {
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

  @Builder
  private inlineText(value: string, size: number) {
    Text() {
      ForEach(this.inlineParts(value), (part: InlinePart) => {
        Span(part.text)
          .fontWeight(part.strong ? FontWeight.Bold : FontWeight.Regular)
          .fontStyle(part.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(part.target ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
          .decoration({ type: part.target ? TextDecorationType.Underline : (part.strike ? TextDecorationType.LineThrough : TextDecorationType.None) })
          .backgroundColor(part.code ? $r('app.color.native_chat_field') : Color.Transparent)
          .onClick(() => { if (part.target) { void this.openLink(part.target); } })
      }, (part: InlinePart, index: number): string => `${index}:${part.text}:${part.target ?? ''}`)
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
            Text(block.text)
              .fontFamily('monospace')
              .fontSize(13 * this.fontScale)
              .fontColor($r('app.color.native_chat_primary'))
              .lineHeight(22)
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
