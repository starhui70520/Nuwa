import { common } from '@kit.AbilityKit';
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
}

interface InlinePart {
  text: string;
  strong: boolean;
  code: boolean;
  target?: string;
}

@Component
export struct NativeMarkdown {
  @Prop content: string = '';

  private blocks(): MarkdownBlock[] {
    const lines: string[] = this.content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const result: MarkdownBlock[] = [];
    let paragraph: string[] = [];
    let codeLines: string[] = [];
    let inCode: boolean = false;

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
          result.push({ kind: 'code', text: codeLines.join('\n'), level: 0, ordered: false, marker: '' });
          codeLines = [];
          inCode = false;
        } else {
          flushParagraph();
          inCode = true;
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
      result.push({ kind: 'code', text: codeLines.join('\n'), level: 0, ordered: false, marker: '' });
    }
    flushParagraph();
    return result;
  }

  private inlineParts(value: string): InlinePart[] {
    const parts: InlinePart[] = [];
    let rest: string = value;
    while (rest.length > 0) {
      const boldAt: number = rest.indexOf('**');
      const codeAt: number = rest.indexOf('`');
      const linkAt: number = rest.indexOf('[');
      let next: number = rest.length;
      let kind: string = '';
      if (boldAt >= 0 && boldAt < next) { next = boldAt; kind = 'bold'; }
      if (codeAt >= 0 && codeAt < next) { next = codeAt; kind = 'code'; }
      if (linkAt >= 0 && linkAt < next) { next = linkAt; kind = 'link'; }
      if (next > 0) {
        parts.push({ text: rest.substring(0, next), strong: false, code: false });
        rest = rest.substring(next);
        continue;
      }

      if (kind === 'bold') {
        const end: number = rest.indexOf('**', 2);
        if (end > 2) {
          parts.push({ text: rest.substring(2, end), strong: true, code: false });
          rest = rest.substring(end + 2);
          continue;
        }
        parts.push({ text: '**', strong: false, code: false });
        rest = rest.substring(2);
      } else if (kind === 'code') {
        const end: number = rest.indexOf('`', 1);
        if (end > 1) {
          parts.push({ text: rest.substring(1, end), strong: false, code: true });
          rest = rest.substring(end + 1);
          continue;
        }
        parts.push({ text: '`', strong: false, code: false });
        rest = rest.substring(1);
      } else if (kind === 'link') {
        const labelEnd: number = rest.indexOf('](', 1);
        const urlEnd: number = labelEnd >= 0 ? rest.indexOf(')', labelEnd + 2) : -1;
        if (labelEnd > 1 && urlEnd > labelEnd + 2) {
          const label: string = rest.substring(1, labelEnd);
          const destination: string = rest.substring(labelEnd + 2, urlEnd);
          parts.push({ text: label, strong: false, code: false, target: destination });
          rest = rest.substring(urlEnd + 1);
          continue;
        }
        parts.push({ text: '[', strong: false, code: false });
        rest = rest.substring(1);
      } else {
        break;
      }
    }
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
          .fontColor(part.target ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
          .decoration({ type: part.target ? TextDecorationType.Underline : TextDecorationType.None })
          .backgroundColor(part.code ? $r('app.color.native_chat_field') : Color.Transparent)
          .onClick(() => { if (part.target) { void this.openLink(part.target); } })
      }, (part: InlinePart, index: number): string => `${index}:${part.text}:${part.target ?? ''}`)
    }
    .fontSize(size)
    .lineHeight(size * 1.55)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks(), (block: MarkdownBlock) => {
        if (block.kind === 'code') {
          Text(block.text)
            .fontFamily('monospace')
            .fontSize(13)
            .fontColor($r('app.color.native_chat_primary'))
            .lineHeight(20)
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor($r('app.color.native_chat_field'))
            .copyOption(CopyOptions.LocalDevice)
        } else if (block.kind === 'heading') {
          this.inlineText(`**${block.text}**`, block.level === 1 ? 24 : (block.level === 2 ? 21 : 18))
        } else if (block.kind === 'list') {
          Row({ space: 8 }) {
            Text(block.marker).fontSize(16).width(22).fontColor($r('app.color.native_chat_secondary'))
            this.inlineText(block.text, 16)
          }
          .width('100%')
          .padding({ left: block.level })
        } else {
          this.inlineText(block.text, 16)
        }
      }, (block: MarkdownBlock, index: number): string => `${block.kind}-${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
