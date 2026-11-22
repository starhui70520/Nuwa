import { AbilityConstant, common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { text } from '@kit.ArkGraphics2D';
import { deviceInfo } from '@kit.BasicServicesKit';
import { NativeCodeHighlightRun, nativeCodeHighlightKey, requestNativeCodeHighlight } from './NativeCodeHighlightQueue';
import { isHarmonyLowPerfDevice } from './NativeDevicePerf';
import { NativeTheme } from './NativeSettings';

const CODE_FONT = 'monospace';
const CODE_PADDING = 16;
const TAB_COLUMNS = 8;
const TAB_LAYOUT_LINES = 128;
const STREAMING_DEFER_CHARS_LOW = 1200;
const STREAMING_DEFER_CHARS_NORMAL = 6000;
const STREAMING_DEBOUNCE_LOW_MS = 220;
const STREAMING_DEBOUNCE_NORMAL_MS = 100;

const themeListeners = new Set<(dark: boolean) => void>();
let observingTheme = false;

function subscribeCodeTheme(context: common.UIAbilityContext | undefined, listener: (dark: boolean) => void): () => void {
  const dark = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  listener(context?.config.colorMode === dark);
  themeListeners.add(listener);
  if (context && !observingTheme) {
    try {
      context.getApplicationContext().on('environment', {
        onConfigurationUpdated: (configuration: Configuration): void => {
          if (configuration.colorMode !== undefined) {
            themeListeners.forEach((update: (dark: boolean) => void): void => {
              update(configuration.colorMode === dark);
            });
          }
        },
        onMemoryLevel: (_level: AbilityConstant.MemoryLevel): void => {},
      });
      observingTheme = true;
    } catch {
      // Explicit themes and the initial appearance can still be displayed.
    }
  }
  return (): void => { themeListeners.delete(listener); };
}

interface HighlightedSource {
  key: string;
  runs: NativeCodeHighlightRun[];
}

interface HighlightedSpan extends NativeCodeHighlightRun {
  text: string;
  spacing?: number;
  spanKey: string;
}

function fastTextHash(value: string): string {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash = Math.imul(hash ^ value.charCodeAt(i), 16777619);
  }
  return (hash >>> 0).toString(36);
}

interface CodeTabLayout {
  source: string;
  width: number;
  fontSize: number;
  spacing: Map<number, number>;
}

function measureCodeTabs(source: string, width: number, fontSize: number): Map<number, number> {
  const spacing = new Map<number, number>();
  const fonts = new text.FontCollection();
  const style: text.TextStyle = { fontFamilies: [CODE_FONT], fontSize };
  const spaceBuilder = new text.ParagraphBuilder({ textStyle: style }, fonts);
  spaceBuilder.addText(' X');
  const sample = spaceBuilder.build();
  sample.layoutSync(1024);
  const spaceBounds = sample.getRectsForRange({ start: 0, end: 1 },
    text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT)[0]?.rect;
  const space = spaceBounds ? spaceBounds.right - spaceBounds.left : 0;
  if (!(space > 0)) return spacing;

  const interval = space * TAB_COLUMNS;
  const paragraphStyle: text.ParagraphStyle = {
    textStyle: style,
    wordBreak: text.WordBreak.BREAK_ALL,
    // Nudge the measured stops so Graphic2D also advances at exact column boundaries.
    tab: { alignment: text.TextAlign.LEFT, location: interval - 0.25 },
  };

  let offset = source.indexOf('\t');
  while (offset >= 0) {
    const start = source.lastIndexOf('\n', offset - 1) + 1;
    let end = offset;
    // Limit each range lookup to a group of complete source lines.
    for (let line = 0; line < TAB_LAYOUT_LINES && end < source.length; line++) {
      const newline = source.indexOf('\n', end);
      end = newline < 0 ? source.length : newline + 1;
    }
    const builder = new text.ParagraphBuilder(paragraphStyle, fonts);
    builder.addText(source.slice(start, end));
    const paragraph = builder.build();
    paragraph.layoutSync(width);

    let row = Number.NEGATIVE_INFINITY;
    let correction = 0;
    for (; offset >= 0 && offset < end; offset = source.indexOf('\t', offset + 1)) {
      const rect = paragraph.getRectsForRange({ start: offset - start, end: offset - start + 1 },
        text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT)[0]?.rect;
      if (!rect) continue;
      if (rect.top !== row) {
        row = rect.top;
        correction = 0;
      }
      const left = rect.left + correction;
      const stop = (Math.floor((left + space / 2) / interval) + 1) * interval;
      spacing.set(offset, stop - left - space);
      correction = stop - rect.right;
    }
  }
  return spacing;
}

@Component
export struct NativeHighlightedCode {
  @Prop @Watch('schedule') language: string = 'text';
  @Prop @Watch('schedule') source: string = '';
  @Prop @Watch('schedule') loading: boolean = false;
  @Prop theme: NativeTheme = 'system';
  @Prop fontScale: number = 1;
  @State private systemDark: boolean = false;
  @State private highlight: HighlightedSource | undefined = undefined;
  @State private layoutWidth: number = 0;
  private tabs?: CodeTabLayout;
  private cachedSpansSource: string = '';
  private cachedSpansHighlight?: HighlightedSource;
  private cachedSpansSpacing?: Map<number, number>;
  private cachedSpans: HighlightedSpan[] = [];
  private mounted: boolean = false;
  private timer: number = -1;
  private unsubscribeTheme?: () => void;

  aboutToAppear(): void {
    this.mounted = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    this.unsubscribeTheme = subscribeCodeTheme(context, (dark: boolean): void => { this.systemDark = dark; });
    this.schedule();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    clearTimeout(this.timer);
    this.timer = -1;
    this.unsubscribeTheme?.();
    this.unsubscribeTheme = undefined;
  }

  private schedule(): void {
    if (!this.mounted) return;
    const lowPerf = isHarmonyLowPerfDevice();
    const deferLimit = lowPerf ? STREAMING_DEFER_CHARS_LOW : STREAMING_DEFER_CHARS_NORMAL;
    // 流式输出大代码块时延后语法高亮，结束瞬间再一次性着色，避免反复向 Worker 序列化整段代码。
    if (this.loading && this.source.length > deferLimit) {
      if (this.timer >= 0) {
        clearTimeout(this.timer);
        this.timer = -1;
      }
      return;
    }
    if (this.timer >= 0 && this.loading) return;
    clearTimeout(this.timer);
    const delay = this.loading ? (lowPerf ? STREAMING_DEBOUNCE_LOW_MS : STREAMING_DEBOUNCE_NORMAL_MS) : 0;
    this.timer = setTimeout((): void => {
      this.timer = -1;
      void this.highlightSource();
    }, delay);
  }

  private async highlightSource(): Promise<void> {
    const language = this.language;
    const source = this.source;
    const key = nativeCodeHighlightKey(language, source);
    if (this.highlight?.key === key) return;
    const runs = await requestNativeCodeHighlight(language, source);
    if (this.mounted && this.source === source && this.language === language && runs) {
      this.highlight = { key: key, runs: runs };
    }
  }

  private tabSpacing(): Map<number, number> | undefined {
    if (deviceInfo.sdkApiVersion < 18 || this.layoutWidth <= CODE_PADDING * 2 || !this.source.includes('\t')) {
      return undefined;
    }
    const context = this.getUIContext();
    const width = context.vp2px(this.layoutWidth - CODE_PADDING * 2);
    const fontSize = context.fp2px(13 * this.fontScale);
    if (this.tabs?.source === this.source && this.tabs.width === width && this.tabs.fontSize === fontSize) {
      return this.tabs.spacing;
    }
    let spacing: Map<number, number>;
    try {
      spacing = measureCodeTabs(this.source, width, fontSize);
    } catch {
      spacing = new Map<number, number>();
    }
    this.tabs = { source: this.source, width, fontSize, spacing };
    return spacing;
  }

  private appendSpan(spans: HighlightedSpan[], run: NativeCodeHighlightRun, start: number,
    end: number, spacing?: number): void {
    if (end <= start && this.source.length > 0) return;
    const piece = this.source.slice(start, end);
    const spanKey = spans.length.toString() + ':' + end.toString() + ':' + piece.length.toString() + ':' +
      fastTextHash(piece) + ':' + run.lightColor + ':' + run.darkColor + ':' +
      run.lightFlags.toString() + ':' + run.darkFlags.toString() + ':' + (spacing === undefined ? '' : spacing.toString());
    spans.push({ text: piece, end, lightColor: run.lightColor,
      darkColor: run.darkColor, lightFlags: run.lightFlags, darkFlags: run.darkFlags, spacing, spanKey });
  }

  private spans(): HighlightedSpan[] {
    const activeHighlight = this.highlight?.key === nativeCodeHighlightKey(this.language, this.source) ?
      this.highlight : undefined;
    const spacing = this.tabSpacing();
    if (this.cachedSpansSource === this.source && this.cachedSpansHighlight === activeHighlight &&
      this.cachedSpansSpacing === spacing && this.cachedSpans.length > 0) {
      return this.cachedSpans;
    }
    const runs: NativeCodeHighlightRun[] = activeHighlight ?
      activeHighlight.runs : [{ end: this.source.length, lightColor: '', darkColor: '', lightFlags: 0, darkFlags: 0 }];
    const spans: HighlightedSpan[] = [];
    let start = 0;
    let tab = spacing?.size ? this.source.indexOf('\t') : -1;
    for (const run of runs) {
      while (tab >= 0 && tab < run.end) {
        this.appendSpan(spans, run, start, tab);
        this.appendSpan(spans, run, tab, tab + 1, spacing?.get(tab));
        start = tab + 1;
        tab = this.source.indexOf('\t', start);
      }
      this.appendSpan(spans, run, start, run.end);
      start = run.end;
    }
    this.cachedSpansSource = this.source;
    this.cachedSpansHighlight = activeHighlight;
    this.cachedSpansSpacing = spacing;
    this.cachedSpans = spans;
    return spans;
  }

  private usesDarkColors(): boolean {
    return this.theme === 'dark' || (this.theme === 'system' && this.systemDark);
  }

  private color(span: HighlightedSpan): ResourceColor {
    return (this.usesDarkColors() ? span.darkColor : span.lightColor) || $r('app.color.native_chat_primary');
  }

  private flags(span: HighlightedSpan): number {
    return this.usesDarkColors() ? span.darkFlags : span.lightFlags;
  }

  build() {
    Text() {
      ForEach(this.spans(), (span: HighlightedSpan) => {
        Span(span.text).fontColor(this.color(span))
          .fontWeight((this.flags(span) & 1) ? FontWeight.Bold : FontWeight.Regular)
          .fontStyle((this.flags(span) & 2) ? FontStyle.Italic : FontStyle.Normal)
          .letterSpacing(span.spacing === undefined ? 0 : `${span.spacing}px`)
      }, (span: HighlightedSpan): string => span.spanKey)
    }
    .fontFamily(CODE_FONT)
    .fontSize(13 * this.fontScale)
    .fontColor($r('app.color.native_chat_primary'))
    .lineHeight(22 * this.fontScale)
    .wordBreak(WordBreak.BREAK_ALL)
    .width('100%')
    .padding(CODE_PADDING)
    .copyOption(CopyOptions.LocalDevice)
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (width > 0 && width !== this.layoutWidth) this.layoutWidth = width;
    })
  }
}
