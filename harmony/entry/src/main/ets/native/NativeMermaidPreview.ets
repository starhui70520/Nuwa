import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { NativeLocale } from './NativeLocation';
import { NativeTheme } from './NativeSettings';

const DIAGRAM_ROOT = 'resource://rawfile/mermaid/';
const DIAGRAM_PAGE = DIAGRAM_ROOT + 'index.html';
const MAX_DIAGRAM_SOURCE_LENGTH = 50000;
const RENDER_TIMEOUT_MS = 8000;

type PreviewPhase = 'loading' | 'ready' | 'empty' | 'failed';

@Component
export struct NativeMermaidPreview {
  @Prop @Watch('startPreview') source: string = '';
  @Prop @Watch('startPreview') theme: NativeTheme = 'system';
  @Prop locale: NativeLocale = 'zh-CN';

  @State private phase: PreviewPhase = 'loading';
  @State private previewHeight: number = 1;
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private pageReady: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private deadline: number = -1;
  private pollTimer: number = -1;
  private viewportWidth: number = 0;

  aboutToAppear(): void {
    this.active = true;
    this.startPreview();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.pageReady = false;
    this.generation++;
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.deadline >= 0) clearTimeout(this.deadline);
    if (this.pollTimer >= 0) clearTimeout(this.pollTimer);
    this.deadline = -1;
    this.pollTimer = -1;
  }

  private resolvePreview(phase: PreviewPhase): void {
    this.clearTimers();
    if (phase !== 'ready') {
      // A failed preview can be remounted from the code switch.
      this.pageReady = false;
      this.previewHeight = 1;
    }
    this.phase = phase;
  }

  private startPreview(): void {
    this.clearTimers();
    const generation = ++this.generation;
    if (!this.active) return;
    if (!this.source.trim()) {
      this.resolvePreview('empty');
      return;
    }
    if (this.source.length > MAX_DIAGRAM_SOURCE_LENGTH) {
      this.resolvePreview('failed');
      return;
    }
    if (this.phase !== 'ready') this.phase = 'loading';
    this.deadline = setTimeout(() => {
      if (this.generation === generation) {
        this.generation++;
        this.resolvePreview('failed');
      }
    }, RENDER_TIMEOUT_MS);
    if (this.pageReady) void this.submit(generation);
  }

  private async submit(generation: number): Promise<void> {
    try {
      const bytes = new util.TextEncoder().encodeInto(this.source);
      const encoded = new util.Base64Helper().encodeToStringSync(bytes);
      const call = 'window.NuwaMermaid ? window.NuwaMermaid.draw(' +
        JSON.stringify(encoded) + ',' + JSON.stringify(this.theme) + ') : -2';
      const response = Number(await this.controller.runJavaScript(call));
      if (!this.active || this.generation !== generation) return;
      if (response === 0) void this.poll(generation, true);
      else this.resolvePreview('failed');
    } catch {
      if (this.active && this.generation === generation) this.resolvePreview('failed');
    }
  }

  private async poll(generation: number, waiting: boolean): Promise<void> {
    try {
      const result = Number(await this.controller.runJavaScript(
        'window.NuwaMermaid ? window.NuwaMermaid.status() : -2'));
      if (!this.active || this.generation !== generation) return;
      if (Number.isFinite(result) && result > 0) {
        this.previewHeight = Math.max(40, Math.min(result + 2, 580));
        if (waiting) this.resolvePreview('ready');
      } else if (waiting && result === -1) {
        this.pollTimer = setTimeout(() => { void this.poll(generation, true); }, 75);
      } else if (waiting) {
        this.resolvePreview(result === -3 ? 'empty' : 'failed');
      }
    } catch {
      if (waiting && this.active && this.generation === generation) this.resolvePreview('failed');
    }
  }

  private rejectResource(target: string): WebResourceResponse | null {
    if (target === DIAGRAM_PAGE || target === DIAGRAM_ROOT + 'render.js' ||
      target === DIAGRAM_ROOT + 'mermaid.min.js') {
      return null;
    }
    const response = new WebResourceResponse();
    response.setResponseCode(403);
    response.setReasonMessage('Forbidden');
    response.setResponseMimeType('text/plain');
    response.setResponseData('');
    return response;
  }

  private statusLabel(): string {
    if (this.phase === 'empty') return this.locale === 'en-US' ? 'This diagram is empty.' : '图表为空';
    if (this.phase === 'failed') return this.locale === 'en-US' ? 'Mermaid rendering failed.' : '渲染失败';
    return this.locale === 'en-US' ? 'Rendering diagram...' : '图表生成中...';
  }

  build() {
    Column() {
      if (this.phase !== 'ready') {
        Text(this.statusLabel())
          .width('100%')
          .height(160)
          .textAlign(TextAlign.Center)
          .fontSize(14)
          .fontColor($r('app.color.native_chat_secondary'))
      }
      if (this.phase === 'loading' || this.phase === 'ready') {
        Web({ src: DIAGRAM_PAGE, controller: this.controller, incognitoMode: true })
          .width('100%')
          .height(this.previewHeight)
          .backgroundColor(Color.Transparent)
          .focusable(false)
          .zoomAccess(false)
          .javaScriptAccess(true)
          .fileAccess(false)
          .domStorageAccess(false)
          .databaseAccess(false)
          .allowWindowOpenMethod(false)
          .blockNetwork(true)
          .imageAccess(false)
          .onlineImageAccess(false)
          .mixedMode(MixedMode.None)
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
            this.pageReady || event.data.getRequestUrl() !== DIAGRAM_PAGE)
          .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
            this.rejectResource(event.request.getRequestUrl()))
          .onPageEnd((event: OnPageEndEvent) => {
            if (!this.active || event.url !== DIAGRAM_PAGE || this.pageReady) return;
            this.pageReady = true;
            this.startPreview();
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (this.active && event.request.isMainFrame()) this.resolvePreview('failed');
          })
          .onRenderExited(() => {
            if (this.active) this.resolvePreview('failed');
          })
          .onAreaChange((_old: Area, area: Area) => {
            const width = Number(area.width);
            if (width > 0 && width !== this.viewportWidth) {
              this.viewportWidth = width;
              if (this.phase === 'ready') void this.poll(this.generation, false);
            }
          })
      }
    }
    .width('100%')
  }
}
