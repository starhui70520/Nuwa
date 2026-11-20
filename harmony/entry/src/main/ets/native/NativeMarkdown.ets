import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { text } from '@kit.ArkGraphics2D';
import { url } from '@kit.ArkTS';
import { NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
import { NativeHighlightedCode } from './NativeHighlightedCode';
import { NativeLocale } from './NativeLocation';
import { NativeMathEquation } from './NativeMathEquation';
import {
  NativeMathPicture, NativeMathPictureRequest, nativeMathPictureKey, requestNativeMathPicture,
} from './NativeMathRenderQueue';
import { NativeMermaidPreview } from './NativeMermaidPreview';
import { NativeMathSpan, parseNativeMath } from './NativeMarkdownMath';
import { nativeMarkdownBlocks, NativeMarkdownBlock, NativeMarkdownPart } from './NativeMarkdownStructure';
import { NativeTheme } from './NativeSettings';

interface NativeRenderedFormula {
  key: string;
  picture: NativeMathPicture;
}

interface NativeCitationAnchor {
  paragraph: string;
  source: NativeChatSource;
  x: number;
  y: number;
  width: number;
  height: number;
}

@Component
export struct NativeMarkdown {
  @Prop @Watch('onContentChanged') content: string = '';
  @Prop @Watch('scheduleMathPictures') fontScale: number = 1;
  @Prop viewportWidth: number = 0;
  @Prop @Watch('scheduleMathPictures') muted: boolean = false;
  @Prop @Watch('scheduleMathPictures') disableLinks: boolean = false;
  @Prop @Watch('scheduleMathPictures') hasCitations: boolean = false;
  @Prop @Watch('scheduleMathPictures') citationSources: NativeChatSource[] = [];
  @Prop @Watch('dismissCitationPreview') citationHoverEnabled: boolean = false;
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop @Watch('scheduleMathPictures') theme: NativeTheme = 'system';
  @Prop @Watch('onContentChanged') loading: boolean = false;
  onCitation: (number: number) => void = () => {};
  @State private copiedCodeKey: string = '';
  @State private mermaidCodeBlocks: string[] = [];
  @State private mathPictures: NativeRenderedFormula[] = [];
  @State private contentWidth: number = 0;
  @State private citationAnchor: NativeCitationAnchor | undefined = undefined;
  @State private citationPreviewVisible: boolean = false;
  @State private visibleContent: string = '';
  private cachedSourceIndices: string | undefined = undefined;
  private cachedLinkMode: boolean = false;
  private cachedContent: string = '';
  private cachedBlocks: NativeMarkdownBlock[] = [];
  private nextStreamUpdate: number = 0;
  private streamTimer: number = -1;
  private codeCopyTimer: number = -1;
  private mathMounted: boolean = false;
  private mathTimer: number = -1;
  private mathGeneration: number = 0;
  private mathColor: string = '#0F1115';
  private mathDensity: number = 1;
  private mathFontRatio: number = 1;
  private citationControllers: Map<string, TextController> = new Map<string, TextController>();
  private citationTimer: number = -1;

  aboutToAppear(): void {
    // Chat List mounts only the displayed rows and its small render cache.
    this.mathMounted = true;
    this.visibleContent = this.content;
    this.scheduleMathPictures();
  }

  aboutToDisappear(): void {
    this.mathMounted = false;
    this.mathGeneration++;
    clearTimeout(this.mathTimer);
    clearTimeout(this.codeCopyTimer);
    clearTimeout(this.streamTimer);
    this.streamTimer = -1;
    this.dismissCitationPreview();
    this.citationControllers.clear();
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

  private headingLineHeight(level: number): number {
    if (this.muted) return 24;
    return level === 1 ? 34 : level === 2 ? 32 : level === 3 ? 30 : 28;
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

  private collectInlinePictures(entries: Map<string, NativeMathPictureRequest>, parts: NativeMarkdownPart[], size: number): void {
    for (const part of parts) {
      if (part.formula) {
        const request = this.mathRequest(part.formula, size, false, part.strong);
        entries.set(nativeMathPictureKey(request), request);
      }
    }
  }

  private collectMathRequests(entries: Map<string, NativeMathPictureRequest>, blocks: NativeMarkdownBlock[]): void {
    for (const block of blocks) {
      if (block.kind === 'math') {
        const request = this.mathRequest(block.text ?? '', this.bodySize(), true);
        entries.set(nativeMathPictureKey(request), request);
      } else if (block.rows) {
        for (let index = 0; index < block.rows.length; index++) {
          for (const cell of block.rows[index]) {
            this.collectInlinePictures(entries, cell, this.tableFontSize());
          }
        }
      } else if (block.parts) {
        const size = block.kind === 'heading' ? this.headingSize(block.level ?? 1) : this.bodySize();
        this.collectInlinePictures(entries, block.parts, size);
      }
      if (block.children) this.collectMathRequests(entries, block.children);
    }
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
    const requests = new Map<string, NativeMathPictureRequest>();
    this.collectMathRequests(requests, this.blocks());
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

  private inlineAccessibilityText(parts: NativeMarkdownPart[]): string {
    if (!this.mathPictures.length || !parts.some((part: NativeMarkdownPart): boolean => !!part.formula) ||
      parts.some((part: NativeMarkdownPart): boolean => !!part.target || part.citation !== undefined)) return '';
    return parts.map<string>((part: NativeMarkdownPart): string => part.formula ?? part.text).join('');
  }

  private label(chinese: string, english: string): string {
    return this.locale === 'en-US' ? english : chinese;
  }

  private isMermaid(block: NativeMarkdownBlock): boolean {
    return block.lang?.toLowerCase() === 'mermaid';
  }

  private renderKey(block: NativeMarkdownBlock, index: number): string {
    // Preserve the mounted WebView and its last valid graph as the source grows.
    return (block.hasDiagram ? 'diagram-' + block.kind : block.key) + ':' + index;
  }

  private currentBlock(original: NativeMarkdownBlock, path: string): NativeMarkdownBlock {
    if (!original.hasDiagram) return original;
    let children = this.blocks();
    let block = original;
    for (const index of path.split(':').slice(1)) {
      const next = children[Number(index)];
      if (!next) return original;
      block = next;
      children = next.children ?? [];
    }
    return block.kind === original.kind ? block : original;
  }

  private setMermaidMode(path: string, code: boolean): void {
    if (code && !this.mermaidCodeBlocks.includes(path)) {
      this.mermaidCodeBlocks = [...this.mermaidCodeBlocks, path];
    } else if (!code) {
      this.mermaidCodeBlocks = this.mermaidCodeBlocks.filter((item: string): boolean => item !== path);
    }
  }

  private blocks(): NativeMarkdownBlock[] {
    const content = this.loading ? this.visibleContent : this.content;
    const sources = this.hasCitations ? this.citationSources.map<number>((source: NativeChatSource): number => source.index) :
      undefined;
    const indexKey = sources?.join(',');
    if (content !== this.cachedContent || indexKey !== this.cachedSourceIndices ||
      this.disableLinks !== this.cachedLinkMode) {
      const started = Date.now();
      this.cachedContent = content;
      this.cachedSourceIndices = indexKey;
      this.cachedLinkMode = this.disableLinks;
      this.cachedBlocks = nativeMarkdownBlocks(content, sources, this.disableLinks);
      const finished = Date.now();
      this.nextStreamUpdate = finished + Math.min(2000, (finished - started) * 2);
    }
    return this.cachedBlocks;
  }

  private onContentChanged(): void {
    this.scheduleMathPictures();
    clearTimeout(this.streamTimer);
    this.streamTimer = -1;
    if (!this.mathMounted) return;
    const delay = this.loading ? this.nextStreamUpdate - Date.now() : 0;
    if (delay <= 0) {
      this.visibleContent = this.content;
    } else {
      this.streamTimer = setTimeout(() => {
        this.streamTimer = -1;
        this.visibleContent = this.content;
      }, delay);
    }
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
  private inlineText(paragraph: string, parts: NativeMarkdownPart[], size: number, maxWidth: number = 0,
    lineHeight?: number, fontWeight: number = 400) {
    if (this.previewCitations(parts)) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.paragraphText(paragraph, parts, size, maxWidth, lineHeight, fontWeight, this.citationController(paragraph))
        if (this.citationAnchor?.paragraph === paragraph) {
          Row() {}
            .position({ x: this.citationAnchor?.x ?? 0, y: this.citationAnchor?.y ?? 0 })
            .width(this.citationAnchor?.width ?? 0).height(this.citationAnchor?.height ?? 0)
            .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            .bindPopup(this.citationPreviewVisible, {
              builder: this.citationPreviewCard,
              placement: Placement.Bottom, targetSpace: 6, enableArrow: false, mask: false,
              autoCancel: false, focusable: false, popupColor: $r('app.color.native_chat_surface'),
              backgroundBlurStyle: BlurStyle.NONE,
            })
        }
      }
      .width('100%')
      .onAreaChange((oldArea: Area, area: Area) => {
        if (this.citationAnchor?.paragraph === paragraph &&
          (oldArea.width !== area.width || oldArea.height !== area.height)) {
          this.dismissCitationPreview();
        }
      })
    } else {
      this.paragraphText(paragraph, parts, size, maxWidth, lineHeight, fontWeight)
    }
  }

  @Builder
  private paragraphText(paragraph: string, parts: NativeMarkdownPart[], size: number, maxWidth: number,
    lineHeight: number | undefined, fontWeight: number, controller?: TextController) {
    Text(undefined, { controller: controller }) {
      ForEach(parts, (part: NativeMarkdownPart, index: number) => {
        if (part.citation !== undefined && controller) {
          Span(part.text).fontSize(9 * this.fontScale).fontWeight(FontWeight.Medium)
            .fontFamily('monospace').baselineOffset(LengthMetrics.fp(5 * this.fontScale))
            .fontColor($r('app.color.native_chat_citation_text'))
            .textBackgroundStyle({ color: $r('app.color.native_chat_citation_bg'), radius: 6 })
            .onClick(() => { this.activateCitation(part.citation ?? 0); })
            .onHover((inside: boolean, event: HoverEvent) => {
              this.hoverCitation(inside, event, paragraph, parts, index, size);
            })
        } else if (part.citation !== undefined) {
          Span(part.text).fontSize(9 * this.fontScale).fontWeight(FontWeight.Medium)
            .fontFamily('monospace').baselineOffset(LengthMetrics.fp(5 * this.fontScale))
            .fontColor($r('app.color.native_chat_citation_text'))
            .textBackgroundStyle({ color: $r('app.color.native_chat_citation_bg'), radius: 6 })
            .onClick(() => { this.activateCitation(part.citation ?? 0); })
        } else if (part.formula && this.mathPicture(part.formula, size, false, part.strong)) {
          ImageSpan(this.mathPicture(part.formula, size, false, part.strong)?.png ?? '')
            .width(this.inlineWidth(part.formula, size, part.strong, maxWidth))
            .height(this.inlineHeight(part.formula, size, part.strong, maxWidth))
            .objectFit(ImageFit.Contain)
            .verticalAlign(ImageSpanAlignment.BASELINE)
            .baselineOffset(LengthMetrics.vp(-this.inlineDepth(part.formula, size, part.strong, maxWidth)))
            .onClick(() => { if (part.target) { void this.openLink(part.target); } })
        } else if (part.math) {
          ForEach(part.math, (span: NativeMathSpan) => {
            Span(span.text)
              .fontFamily('serif')
              .fontSize(size * this.fontScale * span.scale)
              .baselineOffset(LengthMetrics.fp(size * this.fontScale * span.offset))
              .fontColor(part.target ? $r('app.color.native_chat_blue_text') : this.bodyColor())
              .fontStyle(span.italic || part.italic ? FontStyle.Italic : FontStyle.Normal)
              .fontWeight(span.bold || part.strong ? FontWeight.Bold : FontWeight.Regular)
              .onClick(() => { if (part.target) { void this.openLink(part.target); } })
          }, (_span: NativeMathSpan, index: number): string => index.toString())
        } else {
          Span(part.text)
            .fontWeight(part.strong ? Math.max(600, fontWeight) : fontWeight)
            .fontStyle(part.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(part.target ? $r('app.color.native_chat_blue_text') : this.bodyColor())
            .fontFamily(part.code ? 'monospace' : undefined)
            .fontSize((part.code ? (maxWidth ? 13 : size * 0.875) : size) * this.fontScale)
            .textBackgroundStyle({ color: part.code ? $r('app.color.native_chat_inline_code') : Color.Transparent,
              radius: part.code ? 6 : 0 })
            .onClick(() => { if (part.target) { void this.openLink(part.target); } })
        }
      }, (part: NativeMarkdownPart, index: number): string => `${index}:${part.text}:${part.target ?? ''}:${part.citation ?? 0}`)
    }
    .fontSize(size * this.fontScale)
    .lineHeight((lineHeight ?? size * (this.muted ? 24 / 14 : 1.75)) * this.fontScale)
    .width('100%')
    .accessibilityText(this.inlineAccessibilityText(parts))
    .copyOption(CopyOptions.LocalDevice)
  }

  private previewCitations(parts: NativeMarkdownPart[]): boolean {
    return this.citationHoverEnabled && this.hasCitations && deviceInfo.sdkApiVersion >= 15 &&
      parts.some((part: NativeMarkdownPart): boolean => part.citation !== undefined);
  }

  private citationController(paragraph: string): TextController {
    const existing = this.citationControllers.get(paragraph);
    if (existing) {
      return existing;
    }
    const controller = new TextController();
    this.citationControllers.set(paragraph, controller);
    return controller;
  }

  private renderedPartLength(part: NativeMarkdownPart, size: number): number {
    if (part.formula && this.mathPicture(part.formula, size, false, part.strong)) {
      return 1; // ImageSpan contributes one placeholder to the paragraph.
    }
    return part.math ? part.math.reduce((length: number, span: NativeMathSpan): number => length + span.text.length, 0) :
      part.text.length;
  }

  private hoverCitation(inside: boolean, event: HoverEvent, paragraph: string, parts: NativeMarkdownPart[],
    index: number, size: number): void {
    const controller = this.citationControllers.get(paragraph);
    if (!this.citationHoverEnabled || !controller) {
      return;
    }
    if (!inside) {
      this.scheduleCitationDismiss();
      return;
    }
    const part = parts[index];
    const source = this.citationSources.find((item: NativeChatSource): boolean => item.index === part?.citation);
    if (!source || !safeNativeSourceUrl(source.url)) {
      this.scheduleCitationDismiss();
      return;
    }
    let start = 0;
    for (let previous = 0; previous < index; previous++) {
      start += this.renderedPartLength(parts[previous], size);
    }
    try {
      const boxes = controller.getLayoutManager().getRectsForRange({ start: start, end: start + part.text.length },
        text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT);
      const ui = this.getUIContext();
      const x = ui.vp2px(event.x ?? -1);
      const y = ui.vp2px(event.y ?? -1);
      const box = boxes.find((candidate: TextBox): boolean =>
        x >= candidate.rect.left && x <= candidate.rect.right && y >= candidate.rect.top && y <= candidate.rect.bottom);
      const rect = (box ?? (boxes.length === 1 ? boxes[0] : undefined))?.rect;
      if (!rect || rect.right <= rect.left || rect.bottom <= rect.top) {
        return;
      }
      this.dismissCitationPreview();
      this.citationAnchor = {
        paragraph: paragraph, source: source, x: ui.px2vp(rect.left), y: ui.px2vp(rect.top),
        width: ui.px2vp(rect.right - rect.left), height: ui.px2vp(rect.bottom - rect.top),
      };
      this.citationTimer = setTimeout(() => { this.citationPreviewVisible = true; }, 300);
    } catch {
      // The paragraph can disappear or reflow during the hover event.
      this.dismissCitationPreview();
    }
  }

  private dismissCitationPreview(): void {
    clearTimeout(this.citationTimer);
    this.citationPreviewVisible = false;
    this.citationAnchor = undefined;
  }

  private scheduleCitationDismiss(): void {
    clearTimeout(this.citationTimer);
    this.citationTimer = setTimeout(() => { this.dismissCitationPreview(); }, 100);
  }

  private activateCitation(index: number): void {
    this.dismissCitationPreview();
    this.onCitation(index);
  }

  private citationSourceDate(value: string | null): string {
    if (!value) return '';
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? date.getFullYear().toString() + '/' +
      (date.getMonth() + 1).toString().padStart(2, '0') + '/' + date.getDate().toString().padStart(2, '0') : value;
  }

  @Builder
  private citationPreviewCard() {
    if (this.citationAnchor) {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Image(safeNativeSourceUrl(this.citationAnchor.source.siteIcon) || $r('app.media.native_web_search'))
              .alt($r('app.media.native_web_search')).width(16).height(16).borderRadius(4).draggable(false)
            Text(this.citationAnchor.source.siteName).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '62%' })
            if (this.citationAnchor.source.publishedAt) {
              Text(this.citationSourceDate(this.citationAnchor.source.publishedAt)).fontSize(12)
                .fontColor($r('app.color.native_chat_caption')).maxLines(1)
            }
          }
          Text(this.citationAnchor.source.title).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.citationAnchor.source.snippet) {
            Text(this.citationAnchor.source.snippet).fontSize(13).fontColor($r('app.color.native_chat_secondary'))
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start).width('100%')
      }
      .width(355).padding(16).borderRadius(12)
      .border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .onClick(() => { this.activateCitation(this.citationAnchor?.source.index ?? 0); })
      .onHover((inside: boolean) => {
        if (inside) {
          clearTimeout(this.citationTimer);
        } else {
          this.scheduleCitationDismiss();
        }
      })
    }
  }

  private async copyCode(text: string, key: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      );
      this.copiedCodeKey = key;
      clearTimeout(this.codeCopyTimer);
      this.codeCopyTimer = setTimeout(() => { this.copiedCodeKey = ''; }, 1500);
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: this.label('复制失败', 'Copy failed') });
    }
  }

  @Builder
  private mermaidModeButton(path: string, label: string, code: boolean) {
    Button(label, { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL })
      .height(28)
      .padding({ left: 9, right: 9 })
      .borderRadius(7)
      .fontSize(13)
      .fontColor($r('app.color.native_chat_primary'))
      .backgroundColor(this.mermaidCodeBlocks.includes(path) === code ?
        $r('app.color.native_chat_field') : Color.Transparent)
      .accessibilitySelected(this.mermaidCodeBlocks.includes(path) === code)
      .onClick(() => { this.setMermaidMode(path, code); })
  }

  @Builder
  private codeBlock(block: NativeMarkdownBlock, path: string) {
    Column() {
      Row() {
        if (this.isMermaid(block)) {
          Row({ space: 4 }) {
            this.mermaidModeButton(path, this.label('图表', 'Diagram'), false)
            this.mermaidModeButton(path, this.label('代码', 'Code'), true)
          }
          .accessibilityDescription(this.label('Mermaid 图表与代码切换', 'Toggle between Mermaid diagram and code'))
          Blank().layoutWeight(1)
        } else {
          Text(block.lang || 'text')
            .fontSize(12)
            .fontColor($r('app.color.native_chat_secondary'))
            .layoutWeight(1)
        }
        Button(this.copiedCodeKey === path + ':' + this.currentBlock(block, path).key ?
          this.label('已复制', 'Copied') : this.label('复制', 'Copy'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(28)
          .fontSize(13)
          .onClick(() => {
            const current = this.currentBlock(block, path);
            void this.copyCode(current.text ?? '', path + ':' + current.key);
          })
      }
      .width('100%')
      .padding(6)
      .backgroundColor($r('app.color.native_chat_sidebar'))
      if (this.isMermaid(block) && !this.mermaidCodeBlocks.includes(path)) {
        NativeMermaidPreview({ source: this.currentBlock(block, path).text ?? '', loading: this.loading,
          locale: this.locale, theme: this.theme })
      } else {
        NativeHighlightedCode({ language: block.lang || 'text', source: this.currentBlock(block, path).text ?? '',
          loading: this.loading, theme: this.theme, fontScale: this.fontScale })
      }
    }
    .width('100%')
    .borderRadius(12)
    .clip(true)
    .backgroundColor($r('app.color.native_chat_field'))
  }

  private blockGap(block: NativeMarkdownBlock, previous: NativeMarkdownBlock | undefined, insideList: boolean): number {
    if (!previous) return 0;
    if (block.kind === 'quote') return this.muted ? 12 : 16;
    if (insideList && block.kind === 'list') return this.muted ? 2 : 4;
    if (block.kind === 'heading' && !this.muted) return (block.level ?? 1) <= 3 ? 32 : 16;
    if (block.kind === 'list') return previous.kind === 'heading' && (previous.level ?? 1) >= 4 ? 8 : 16;
    return previous.kind === 'list' || previous.kind === 'heading' ? 16 : 10;
  }

  private tableFontSize(): number {
    return this.muted ? 14 : 15;
  }

  private tableTextWidth(cell: NativeMarkdownPart[], size: number, weight: number): number {
    const context = this.getUIContext();
    const measure = context.getMeasureUtils();
    let maximum = 0;
    let line = 0;
    for (const part of cell) {
      const segments = part.text.split(/\r\n|\n|\r/);
      for (let index = 0; index < segments.length; index++) {
        if (index) {
          maximum = Math.max(maximum, line);
          line = 0;
        }
        if (!segments[index]) continue;
        const formula = part.formula ? this.mathPicture(part.formula, size, false, part.strong) : null;
        if (formula) {
          line += formula.width;
        } else {
          line += context.px2vp(measure.measureText({
            textContent: segments[index],
            fontSize: (part.citation !== undefined ? 9 : part.code ? 13 : size) * this.fontScale,
            fontWeight: part.strong ? Math.max(600, weight) : weight,
            fontStyle: part.italic ? FontStyle.Italic : FontStyle.Normal,
          }));
        }
      }
    }
    return Math.max(maximum, line);
  }

  private tableWidths(rows: NativeMarkdownPart[][][]): number[] {
    const widths: number[] = [];
    const limit = Math.max(100, Math.min(320, (this.viewportWidth || this.contentWidth || 360) * 0.3));
    for (let row = 0; row < rows.length; row++) {
      for (let column = 0; column < rows[row].length; column++) {
        const measure = this.tableTextWidth(rows[row][column], this.tableFontSize(), row === 0 ? 500 : 400);
        widths[column] = Math.max(widths[column] ?? 100, Math.min(limit, Math.ceil(measure)));
      }
    }
    return widths;
  }

  @Builder
  private renderBlock(block: NativeMarkdownBlock, path: string) {
    if (block.kind === 'code') {
      this.codeBlock(block, path)
    } else if (block.kind === 'math') {
      if (this.mathPicture(block.text ?? '', this.bodySize(), true)) {
        this.displayedFormula(this.mathPicture(block.text ?? '', this.bodySize(), true)!, block.text ?? '')
      } else {
        NativeMathEquation({ expression: parseNativeMath(block.text ?? ''), source: block.text ?? '',
          formulaFontSize: (this.bodySize() + 1) * this.fontScale })
      }
    } else if (block.kind === 'heading') {
      this.inlineText(path, block.parts ?? [], this.headingSize(block.level ?? 1),
        0, this.headingLineHeight(block.level ?? 1), 700)
    } else if (block.kind === 'list') {
      Column({ space: this.muted ? 2 : 6 }) {
        ForEach(this.currentBlock(block, path).children ?? [], (item: NativeMarkdownBlock, index: number) => {
          Row({ space: 8 }) {
            Text(this.currentBlock(item, path + ':' + index).marker).fontSize(this.bodySize() * this.fontScale)
              .lineHeight(this.bodySize() * this.fontScale * (this.muted ? 24 / 14 : 1.75))
              .constraintSize({ minWidth: 10 })
              .fontColor($r('app.color.native_chat_secondary'))
            Column() {
              this.renderBlocks(this.currentBlock(item, path + ':' + index).children ?? [], path + ':' + index, true)
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%').alignItems(VerticalAlign.Top)
        }, (item: NativeMarkdownBlock, index: number): string => this.renderKey(item, index))
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    } else if (block.kind === 'hr') {
      Divider()
        .strokeWidth(1).color($r('app.color.native_chat_stroke'))
        .width('100%').margin({ top: 16, bottom: 16 })
    } else if (block.kind === 'quote') {
      Column() {
        this.renderBlocks(this.currentBlock(block, path).children ?? [], path)
      }
      .width('100%').alignItems(HorizontalAlign.Start).padding({ left: 14 })
      .border({ width: { left: 2 }, color: $r('app.color.native_chat_caption') })
    } else if (block.kind === 'table') {
      this.renderTable(block.rows ?? [], this.tableWidths(block.rows ?? []), path)
    } else {
      this.inlineText(path, block.parts ?? [], this.bodySize())
    }
  }

  @Builder
  private renderTable(rows: NativeMarkdownPart[][][], widths: number[], path: string) {
    Scroll() {
      Column() {
        ForEach(rows, (row: NativeMarkdownPart[][], rowIndex: number) => {
          Row() {
            ForEach(row, (cell: NativeMarkdownPart[], cellIndex: number) => {
              Column() {
                this.inlineText(path + ':' + rowIndex + ':' + cellIndex, cell,
                  this.tableFontSize(), widths[cellIndex], this.muted ? 24 : 25, rowIndex === 0 ? 500 : 400)
              }
              .width(widths[cellIndex] + (cellIndex === 0 ? 0 : 16) + (cellIndex === widths.length - 1 ? 0 : 16))
              .padding({ left: cellIndex === 0 ? 0 : 16, right: cellIndex === widths.length - 1 ? 0 : 16,
                top: 10, bottom: 10 })
            }, (_cell: NativeMarkdownPart[], cellIndex: number): string => cellIndex.toString())
          }
          .alignItems(VerticalAlign.Center)
          .border({ width: { bottom: 1 }, color: rowIndex === 0 ?
            $r('app.color.native_chat_table_header_border') : $r('app.color.native_chat_stroke') })
        }, (_row: NativeMarkdownPart[][], rowIndex: number): string => rowIndex.toString())
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').align(Alignment.Start)
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
  }

  @Builder
  private renderBlocks(blocks: NativeMarkdownBlock[], path: string, insideList: boolean = false) {
    ForEach(blocks, (block: NativeMarkdownBlock, index: number) => {
      Column() {
        this.renderBlock(block, path + ':' + index)
      }
      .width('100%').alignItems(HorizontalAlign.Start).margin({ top: this.blockGap(block, blocks[index - 1], insideList) })
    }, (block: NativeMarkdownBlock, index: number): string => this.renderKey(block, index))
  }

  build() {
    Column() {
      this.renderBlocks(this.blocks(), 'markdown')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (width > 0 && width !== this.contentWidth) this.contentWidth = width;
    })
  }
}
