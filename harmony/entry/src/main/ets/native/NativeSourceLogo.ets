import { NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
import { nativeIconTint } from './NativeIconTint';

@Component
export struct NativeSourceLogo {
  @Prop @Watch('updateIcon') iconUrl: string | null = null;
  @Prop diameter: number = 18;
  @State private source: string = '';
  @State private loadedUrl: string = '';
  @State private failedUrl: string = '';

  aboutToAppear(): void {
    this.updateIcon();
  }

  private updateIcon(): void {
    const source = safeNativeSourceUrl(this.iconUrl);
    if (this.source === source) return;
    this.source = source;
    this.loadedUrl = '';
    this.failedUrl = '';
  }

  private markLoaded(source: string): void {
    if (this.source === source) {
      this.loadedUrl = source;
      this.failedUrl = '';
    }
  }

  private markFailed(source: string): void {
    if (this.source === source) {
      this.loadedUrl = '';
      this.failedUrl = source;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      ForEach(this.source && this.failedUrl !== this.source ? [this.source] : [], (source: string) => {
        Image(source).width(this.diameter).height(this.diameter).objectFit(ImageFit.Cover).autoResize(true)
          .draggable(false).opacity(this.loadedUrl === source ? 1 : 0)
          .onComplete((): void => { this.markLoaded(source); })
          .onError((): void => { this.markFailed(source); })
      }, (source: string): string => source)
      if (!this.source || this.failedUrl === this.source) {
        Image($r('app.media.native_source_link')).width(this.diameter * 0.7).height(this.diameter * 0.7)
          .objectFit(ImageFit.Contain).colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
          .draggable(false)
      }
    }
    .width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2).clip(true)
    .backgroundColor($r('app.color.native_chat_citation_bg'))
    .accessibilityLevel('no-hide-descendants').hitTestBehavior(HitTestMode.None)
  }
}

@Component
export struct NativeSourceThumbnails {
  @Prop sources: NativeChatSource[] = [];
  @Prop borderTint: ResourceColor = $r('app.color.native_chat_bg');

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.sources.slice(0, 4), (source: NativeChatSource, index: number) => {
        Stack({ alignContent: Alignment.Center }) {
          NativeSourceLogo({ iconUrl: source.siteIcon, diameter: 16 })
          Row().width(16).height(16).borderRadius(8).border({ width: 1, color: this.borderTint })
            .hitTestBehavior(HitTestMode.None)
        }
        .width(16).height(16).position({ x: index * 12, y: 0 })
      }, (source: NativeChatSource, index: number): string => source.url + ':' + index.toString())
    }
    .width(this.sources.length ? Math.min(this.sources.length, 4) * 12 + 4 : 0).height(16)
    .accessibilityLevel('no-hide-descendants').hitTestBehavior(HitTestMode.None)
  }
}
