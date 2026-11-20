import { AbilityConstant, common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { NativeCodeHighlightRun, nativeCodeHighlightKey, requestNativeCodeHighlight } from './NativeCodeHighlightQueue';
import { NativeTheme } from './NativeSettings';

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
    if (!this.mounted || (this.timer >= 0 && this.loading)) return;
    clearTimeout(this.timer);
    this.timer = setTimeout((): void => {
      this.timer = -1;
      void this.highlightSource();
    }, this.loading ? 100 : 0);
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

  private spans(): HighlightedSpan[] {
    if (this.highlight?.key !== nativeCodeHighlightKey(this.language, this.source)) {
      return [{ text: this.source, end: this.source.length, lightColor: '', darkColor: '', lightFlags: 0, darkFlags: 0 }];
    }
    let start = 0;
    return this.highlight.runs.map((run: NativeCodeHighlightRun): HighlightedSpan => {
      const text = this.source.slice(start, run.end);
      start = run.end;
      return { text: text, end: run.end, lightColor: run.lightColor, darkColor: run.darkColor,
        lightFlags: run.lightFlags, darkFlags: run.darkFlags };
    });
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
      }, (span: HighlightedSpan): string =>
        span.end.toString() + ':' + span.lightColor + ':' + span.darkColor + ':' +
        span.lightFlags.toString() + ':' + span.darkFlags.toString() + ':' + span.text)
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
