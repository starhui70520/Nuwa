import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { NativeLocale } from './NativeLocation';
import { safeNativeSourceUrl } from './NativeChatSources';

@Component
export struct NativeLinkBrowser {
  @Prop @Watch('targetChanged') target: string = '';
  controller: webview.WebviewController = new webview.WebviewController();
  @Prop locale: NativeLocale = 'zh-CN';
  onClose: () => void = () => {};
  onOpenExternal: (target: string) => void = (_target: string): void => {};

  @State private currentUrl: string = '';
  @State private pageTitle: string = '';
  @State private canNavigateBack: boolean = false;
  @State private failed: boolean = false;
  @State private loadProgress: number = 0;

  aboutToAppear(): void {
    this.currentUrl = safeNativeSourceUrl(this.target);
    this.failed = this.currentUrl.length === 0;
  }

  private targetChanged(): void {
    const next = safeNativeSourceUrl(this.target);
    this.currentUrl = next;
    this.pageTitle = '';
    this.canNavigateBack = false;
    this.failed = next.length === 0;
    this.loadProgress = 0;
  }

  private text(chinese: string, english: string): string {
    return this.locale === 'zh-CN' ? chinese : english;
  }

  private hostLabel(): string {
    const current = safeNativeSourceUrl(this.currentUrl || this.target);
    if (!current) return '';
    try {
      const parsed = url.URL.parseURL(current);
      return parsed.hostname.replace(/^www\./i, '');
    } catch {
      return current;
    }
  }

  private titleLabel(): string {
    if (this.failed && this.currentUrl) return this.text('页面加载失败', 'Page failed to load');
    const title = this.pageTitle.trim();
    return title || this.hostLabel() || this.text('无法打开网页', 'Unable to open page');
  }

  private goBack(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
      }
    } catch {
      // The web view may not yet be attached to its controller.
    }
  }

  private canGoBack(): boolean {
    try {
      return this.controller.accessBackward();
    } catch {
      return false;
    }
  }

  private updateNavigation(address: string): void {
    const target = safeNativeSourceUrl(address);
    if (target) this.currentUrl = target;
    this.canNavigateBack = this.canGoBack();
  }

  private beginNavigation(address: string): void {
    this.updateNavigation(address);
    this.pageTitle = '';
    this.failed = false;
    this.loadProgress = 0;
  }

  private retryPage(): void {
    try {
      this.controller.refresh();
    } catch {
      // The controller may be detached while the browser is closing.
    }
  }

  private activeAddress(): string {
    try {
      const address = safeNativeSourceUrl(this.controller.getUrl());
      if (address) return address;
    } catch {
      // The web view may not yet be attached to its controller.
    }
    return safeNativeSourceUrl(this.currentUrl || this.target);
  }

  @Builder
  private loadFailure() {
    Column({ space: 12 }) {
      Text(this.text('无法加载此网页', 'This page could not be loaded'))
        .fontSize(14).fontColor($r('app.color.native_chat_secondary'))
      if (this.currentUrl) {
        Button(this.text('重新加载', 'Reload'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .id('nuwa-link-browser-retry').fontSize(14).fontColor($r('app.color.native_chat_blue_text'))
          .onClick(() => { this.retryPage(); })
      }
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.native_chat_bg'))
  }

  private openInSystemBrowser(): void {
    const target = this.activeAddress();
    if (target) this.onOpenExternal(target);
  }

  private async shareCurrentLink(): Promise<void> {
    const target = this.activeAddress();
    if (!target) return;
    try {
      const sharedData = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
        content: target,
        title: this.titleLabel(),
        label: 'HYPERLINK'
      });
      const controller = new systemShare.ShareController(sharedData);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        anchor: 'nuwa-link-browser-share',
        previewMode: systemShare.SharePreviewMode.DEFAULT
      });
    } catch {
      this.getUIContext().getPromptAction().showToast({
        message: this.text('无法分享此链接', 'Unable to share this link')
      });
    }
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Button(this.text('关闭', 'Close'))
          .id('nuwa-link-browser-close')
          .fontSize(14)
          .fontColor($r('app.color.native_chat_primary'))
          .backgroundColor(Color.Transparent)
          .width(44).height(44).padding(0)
          .onClick(() => this.onClose())
        Column({ space: 2 }) {
          Text(this.titleLabel())
            .id('nuwa-link-browser-title')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.hostLabel())
            .fontSize(11)
            .fontColor($r('app.color.native_chat_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button('‹')
          .id('nuwa-link-browser-back')
          .fontSize(25)
          .fontColor($r('app.color.native_chat_primary'))
          .backgroundColor(Color.Transparent)
          .width(40).height(44).padding(0)
          .accessibilityText(this.text('上一个网页', 'Previous page'))
          .enabled(this.canNavigateBack)
          .onClick(() => this.goBack())
        Button(this.text('分享', 'Share'))
          .id('nuwa-link-browser-share')
          .fontSize(12)
          .fontColor($r('app.color.native_chat_primary'))
          .backgroundColor(Color.Transparent)
          .width(40).height(44).padding(0)
          .onClick(() => { void this.shareCurrentLink(); })
        Button(this.text('外部打开', 'Browser'))
          .id('nuwa-link-browser-external')
          .fontSize(12)
          .fontColor($r('app.color.native_chat_primary'))
          .backgroundColor(Color.Transparent)
          .width(64).height(44).padding(0)
          .accessibilityText(this.text('在浏览器中打开', 'Open in browser'))
          .onClick(() => this.openInSystemBrowser())
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.native_chat_surface'))

      Stack({ alignContent: Alignment.TopStart }) {
        Divider().color($r('app.color.native_chat_stroke')).strokeWidth(1)
        if (this.currentUrl && !this.failed && this.loadProgress < 100) {
          Progress({ value: this.loadProgress, total: 100, type: ProgressType.Linear })
            .id('nuwa-link-browser-progress').width('100%').height(2).style({ strokeWidth: 2 })
            .color($r('app.color.native_chat_blue')).backgroundColor($r('app.color.native_chat_stroke'))
            .accessibilityText(this.text('正在加载网页', 'Loading web page'))
        }
      }
      .width('100%').height(2)

      Stack() {
        if (this.currentUrl) {
          Web({ src: safeNativeSourceUrl(this.target), controller: this.controller, incognitoMode: true })
            .width('100%').height('100%')
            .backgroundColor($r('app.color.native_chat_bg'))
            .accessibilityLevel(this.failed ? 'no-hide-descendants' : 'auto')
            .javaScriptAccess(true)
            .fileAccess(false)
            .domStorageAccess(true)
            .databaseAccess(false)
            .allowWindowOpenMethod(false)
            .mixedMode(MixedMode.None)
            .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
              const requested = event.data.getRequestUrl();
              if (!event.data.isMainFrame() && (requested === 'about:blank' || requested === 'about:srcdoc')) return false;
              return safeNativeSourceUrl(requested).length === 0;
            })
            .onPageBegin((event: OnPageBeginEvent) => { this.beginNavigation(event.url); })
            .onProgressChange((event: OnProgressChangeEvent) => { this.loadProgress = event.newProgress; })
            .onTitleReceive((event: OnTitleReceiveEvent) => {
              this.pageTitle = event.isRealTitle === false ? '' : event.title.slice(0, 512);
            })
            .onRefreshAccessedHistory((event: OnRefreshAccessedHistoryEvent) => {
              if (event.isMainFrame === false) return;
              this.updateNavigation(event.url);
            })
            .onPageEnd((event: OnPageEndEvent) => {
              this.updateNavigation(event.url);
              this.loadProgress = 100;
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              if (event.request.isMainFrame()) {
                this.updateNavigation(event.request.getRequestUrl());
                this.failed = true;
                this.loadProgress = 100;
              }
            })
        }
        if (this.failed) this.loadFailure()
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.native_chat_bg'))
  }
}
