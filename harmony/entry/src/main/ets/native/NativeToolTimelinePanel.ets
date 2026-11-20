import { common } from '@kit.AbilityKit';
import { NativeChatCitation, NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
import { nativeIconTint } from './NativeIconTint';
import { NativeLocale } from './NativeLocation';
import { NativeMarkdown } from './NativeMarkdown';
import {
  nativeDeepSearchKind, nativeImageSearchKind, NativeTimelinePage, NativeTimelinePattern,
  NativeToolTimelineStep, NativeToolTimelineView,
} from './NativeToolTimeline';

@Component
export struct NativeToolTimelinePanel {
  @Prop view: NativeToolTimelineView = { steps: [], answer: '', answerOffset: 0 };
  @Prop sources: NativeChatSource[] = [];
  @Prop citations: NativeChatCitation[] = [];
  @Prop @Watch('updateTicker') streaming: boolean = false;
  @Prop thinking: boolean | undefined = undefined;
  @Prop stopped: boolean = false;
  @Prop hasResponse: boolean | undefined = undefined;
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop fontScale: number = 1;
  @Prop rtl: boolean = false;
  @Prop textOffset: number = 0;
  @Prop messageId: string = '';
  @Prop activeSourceEntry: string = '';
  @Prop citationHoverEnabled: boolean = false;
  onSources: (entry: string, sources: NativeChatSource[]) => void =
    (_entry: string, _sources: NativeChatSource[]) => {};
  @State private expanded: boolean = true;
  @State private tick: number = 0;
  private ticker: number = -1;

  aboutToAppear(): void {
    this.updateTicker();
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

  private stopTicker(): void {
    if (this.ticker !== -1) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  private updateTicker(): void {
    if (this.streaming && this.ticker === -1) {
      this.ticker = setInterval((): void => { this.tick++; }, 2_000);
    } else if (!this.streaming) {
      this.stopTicker();
      this.tick = 0;
    }
  }

  private text(chinese: string, english: string): string {
    return this.locale === 'zh-CN' ? chinese : english;
  }

  private hasThinking(): boolean {
    return this.thinking ?? this.view.steps.some((step: NativeToolTimelineStep): boolean => step.type === 'thinking');
  }

  private heading(): string {
    if (this.hasResponse ?? !!this.view.answer) {
      const count = this.view.thinkingSeconds;
      return count === undefined ? this.text('深度思考', 'Deep thinking') :
        this.text('已思考（用时 ' + count.toString() + ' 秒）',
          'Thought for ' + count.toString() + (count === 1 ? ' second' : ' seconds'));
    }
    if (!this.streaming) {
      return this.text('已停止', 'Stopped');
    }
    const last = this.view.steps[this.view.steps.length - 1];
    if (last?.type === 'search' && last.status === 'wip') {
      return nativeImageSearchKind(last.kind) ? this.text('图像搜索中...', 'Searching by image...') :
        this.text('正在搜索', 'Searching the web');
    }
    if ((last?.type === 'open' && last.pages?.some((page: NativeTimelinePage): boolean => page.status === 'wip')) ||
      (last?.type === 'find' && last.patterns?.some((item: NativeTimelinePattern): boolean => item.status === 'wip'))) {
      return this.text('正在浏览网页', 'Browsing the web');
    }
    if (last?.type === 'read_link') {
      return this.text('正在阅读', 'Reading');
    }
    return this.text('正在思考', 'Thinking');
  }

  private searchLabel(step: NativeToolTimelineStep): string {
    const queries = step.queries ?? [];
    const count = step.resultUrls?.length ?? 0;
    if (step.status === 'wip') {
      if (queries.length > 0) {
        return this.text('搜索 ', 'Searching for ') + queries[this.tick % queries.length];
      }
      return nativeImageSearchKind(step.kind) ? this.text('图像搜索中...', 'Searching by image...') :
        this.text('搜索中...', 'Searching...');
    }
    if (step.status === 'failed') {
      return !this.streaming && this.stopped ? this.text('搜索已停止', 'Search stopped') :
        this.text('联网搜索暂不可用', 'Search currently unavailable');
    }
    if (count === 0) {
      return nativeDeepSearchKind(step.kind) ? this.text('未搜索到合适内容', 'No suitable results found') :
        this.text('未搜索到相关内容', 'No relevant results found');
    }
    const pages = count.toString() + (count === 1 ? ' web page' : ' web pages');
    return nativeDeepSearchKind(step.kind) ? this.text('搜索到 ' + count.toString() + ' 个网页', 'Found ' + pages) :
      this.text('已阅读 ' + count.toString() + ' 个网页', 'Read ' + pages);
  }

  private searchSources(addresses: string[]): NativeChatSource[] {
    const matches: NativeChatSource[] = [];
    for (const address of addresses) {
      const source = this.sources.find((item: NativeChatSource): boolean => item.url === address);
      if (source && !matches.some((item: NativeChatSource): boolean => item.index === source.index)) {
        matches.push(source);
      }
    }
    return matches;
  }

  private sourceEntry(step: NativeToolTimelineStep): string {
    return this.messageId + ':' + step.type + ':' + step.key;
  }

  private showSources(step: NativeToolTimelineStep, addresses: string[]): void {
    const matches = this.searchSources(addresses);
    if (matches.length > 0) {
      this.onSources(this.sourceEntry(step), matches);
    }
  }

  private async openLink(value: string): Promise<void> {
    const target = safeNativeSourceUrl(value);
    if (!target) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(target, { appLinkingOnly: false });
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: this.text('无法打开链接', 'Unable to open the link') });
    }
  }

  private openCitation(index: number): void {
    const source = this.sources.find((item: NativeChatSource): boolean => item.index === index);
    if (source) {
      void this.openLink(source.url);
    }
  }

  private sourceText(step: NativeToolTimelineStep): string {
    const body = step.text ?? '';
    const first = (step.startOffset ?? 0) + this.textOffset;
    const sorted = this.citations.slice().sort((a: NativeChatCitation, b: NativeChatCitation): number =>
      a.offset - b.offset);
    let cursor = 0;
    let output = '';
    for (const citation of sorted) {
      const target = citation.offset - first;
      if (target < 0 || target > body.length) {
        continue;
      }
      output += body.slice(cursor, target) + '[citation:' + citation.sourceIndex.toString() + ']';
      cursor = target;
    }
    return output + body.slice(cursor);
  }

  private allPagesFailed(step: NativeToolTimelineStep): boolean {
    return step.pages?.every((page: NativeTimelinePage): boolean => page.status === 'failed') ?? true;
  }

  private allPatternsFailed(step: NativeToolTimelineStep): boolean {
    return step.patterns?.every((item: NativeTimelinePattern): boolean => item.status === 'failed') ?? true;
  }

  private openSummary(count: number): string {
    return this.text('浏览 ' + count.toString() + ' 个页面',
      'Read ' + count.toString() + (count === 1 ? ' page' : ' pages'));
  }

  @Builder
  private marker(step: NativeToolTimelineStep) {
    if (step.type === 'text' || step.type === 'thinking') {
      Circle().width(5).height(5).fill(step.active ? $r('app.color.native_chat_blue') :
        $r('app.color.native_chat_caption')).margin({ top: 10 })
    } else if (step.type === 'search') {
      Image($r('app.media.native_search')).width(15).height(15).margin({ top: 4 })
        .colorFilter(nativeIconTint(step.status === 'failed' ? $r('app.color.native_chat_caption') :
          $r('app.color.native_chat_secondary')))
    } else {
      Image($r('app.media.native_web_search')).width(15).height(15).margin({ top: 4 })
        .colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
    }
  }

  @Builder
  private searchRow(step: NativeToolTimelineStep) {
    if (step.status !== 'wip' && (step.resultUrls?.length ?? 0) > 0) {
      Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 5 }) {
          Text(this.searchLabel(step)).fontSize(13 * this.fontScale).fontColor($r('app.color.native_chat_secondary'))
            .maxLines(2).textAlign(TextAlign.Start)
          Image($r('app.media.native_chevron_right')).width(12).height(12)
            .colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
            .rotate({ angle: this.rtl ? 180 : 0 })
        }
      }
      .padding(0).height(24)
      .backgroundColor(this.activeSourceEntry === this.sourceEntry(step) ? $r('app.color.native_chat_selected') :
        Color.Transparent)
      .onClick((): void => { this.showSources(step, step.resultUrls ?? []); })
    } else {
      Text(this.searchLabel(step)).fontSize(13 * this.fontScale)
        .fontColor($r('app.color.native_chat_secondary')).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Start)
        .width('100%').padding({ top: 3 })
    }
  }

  @Builder
  private pageLink(page: NativeTimelinePage) {
    Text((page.title || this.text('网页', 'Web page')) + (page.status === 'failed' || !page.url ? '' : ' ↗'))
      .fontSize(13 * this.fontScale).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontColor(page.status === 'failed' ? $r('app.color.native_chat_caption') : $r('app.color.native_chat_secondary'))
      .decoration({
        type: page.status === 'failed' || !page.url ? TextDecorationType.None : TextDecorationType.Underline,
      })
      .constraintSize({ maxWidth: '100%' }).textAlign(TextAlign.Start)
      .accessibilityText(page.status === 'failed' ? (page.title + ' ' + this.text('浏览失败', 'Read failed')) : page.title)
      .onClick((): void => {
        if (page.status !== 'failed' && page.url) {
          void this.openLink(page.url);
        }
      })
  }

  @Builder
  private pageRow(step: NativeToolTimelineStep) {
    if (step.type === 'open' && this.allPagesFailed(step)) {
      Text(this.text('浏览页面失败', 'Read failed')).fontSize(13 * this.fontScale)
        .fontColor($r('app.color.native_chat_secondary')).padding({ top: 3 })
    } else {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(step.type === 'read_link' ? this.text('正在阅读', 'Reading') : this.openSummary(step.pages?.length ?? 0))
          .fontSize(13 * this.fontScale).fontColor($r('app.color.native_chat_secondary')).padding(3)
        ForEach((step.pages ?? []).slice(0, step.type === 'read_link' ? 256 : 5), (page: NativeTimelinePage) => {
          Row() { this.pageLink(page) }.padding(3)
        }, (page: NativeTimelinePage): string => JSON.stringify(page))
        if (step.type === 'open' && (step.pages?.length ?? 0) > 5) {
          Text(this.text('查看全部', 'View All')).fontSize(12 * this.fontScale)
            .fontColor($r('app.color.native_chat_secondary'))
            .backgroundColor(this.activeSourceEntry === this.sourceEntry(step) ? $r('app.color.native_chat_selected') :
              $r('app.color.native_chat_field'))
            .padding(4).borderRadius(6)
            .onClick((): void => {
              this.showSources(step, (step.pages ?? []).map((page: NativeTimelinePage): string => page.url));
            })
        }
      }
      .width('100%')
    }
  }

  @Builder
  private findRow(step: NativeToolTimelineStep) {
    if (this.allPatternsFailed(step)) {
      Text(this.text('查找失败', 'Find failed')).fontSize(13 * this.fontScale)
        .fontColor($r('app.color.native_chat_secondary')).padding({ top: 3 })
    } else {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(this.text('查找关键词', 'Find keyword')).fontSize(13 * this.fontScale)
          .fontColor($r('app.color.native_chat_secondary')).padding(3)
        ForEach(step.patterns ?? [], (item: NativeTimelinePattern) => {
          Text((item.status === 'done' ? '✓ ' : item.status === 'failed' ? '× ' : '') + item.pattern)
            .fontSize(12 * this.fontScale).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(item.status === 'failed' ? $r('app.color.native_chat_caption') : $r('app.color.native_chat_secondary'))
            .padding(4).margin(2).borderRadius(6).backgroundColor($r('app.color.native_chat_field'))
            .constraintSize({ maxWidth: '100%' })
            .accessibilityText(item.status === 'failed' ?
              (item.pattern + ' ' + this.text('未查找到相关内容', 'No related content found')) : item.pattern)
        }, (item: NativeTimelinePattern): string => item.id + item.status + item.pattern)
      }
      .width('100%')
    }
  }

  @Builder
  private stepRow(step: NativeToolTimelineStep) {
    Row({ space: 7 }) {
      Column() { this.marker(step) }.width(16).alignItems(HorizontalAlign.Center)
      Column() {
        if (step.type === 'search') {
          this.searchRow(step)
        } else if (step.type === 'open' || step.type === 'read_link') {
          this.pageRow(step)
        } else if (step.type === 'find') {
          this.findRow(step)
        } else if (step.type === 'text') {
          NativeMarkdown({
            content: this.sourceText(step), fontScale: this.fontScale * 0.85,
            locale: this.locale, citationSources: this.sources, citationHoverEnabled: this.citationHoverEnabled,
            hasCitations: this.citations.length > 0, onCitation: (index: number): void => { this.openCitation(index); },
          })
        } else if (step.type === 'thinking' && step.text) {
          NativeMarkdown({
            content: step.text, fontScale: this.fontScale, locale: this.locale, muted: true, disableLinks: true,
            loading: this.streaming && step.active === true,
          })
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').alignItems(VerticalAlign.Top)
  }

  build() {
    if (this.view.steps.length > 0 || (this.hasThinking() && this.streaming)) {
      Column({ space: 6 }) {
        if (this.hasThinking()) {
          Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
            Row({ space: 6 }) {
              Image($r('app.media.native_think')).width(15).height(15)
                .colorFilter(nativeIconTint(this.stopped ? $r('app.color.native_chat_caption') :
                  $r('app.color.native_chat_blue_text')))
              Text(this.heading()).fontSize(15 * this.fontScale).fontColor($r('app.color.native_chat_secondary'))
              Image(this.expanded ? $r('app.media.native_chevron_down') : $r('app.media.native_chevron_right'))
                .width(12).height(12).colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
                .rotate({ angle: this.rtl && !this.expanded ? 180 : 0 })
            }
          }
          .padding(0).height(30).onClick((): void => { this.expanded = !this.expanded; })
        }
        if (this.expanded || !this.hasThinking()) {
          ForEach(this.view.steps, (step: NativeToolTimelineStep) => {
            Column() { this.stepRow(step) }.width('100%')
          }, (step: NativeToolTimelineStep): string => JSON.stringify(step))
        }
      }
      .width('100%').direction(this.rtl ? Direction.Rtl : Direction.Auto).alignItems(HorizontalAlign.Start)
    }
  }
}
