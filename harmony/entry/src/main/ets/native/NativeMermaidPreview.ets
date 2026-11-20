import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { NativeLocale } from './NativeLocation';
import { NativeTheme } from './NativeSettings';

const DIAGRAM_ROOT = 'resource://rawfile/mermaid/';
const DIAGRAM_PAGE = DIAGRAM_ROOT + 'index.html';
const MAX_DIAGRAM_SOURCE_LENGTH = 50000;
const RENDER_TIMEOUT_MS = 8000;
const STREAM_RENDER_INTERVAL_MS = 100;

type PreviewPhase = 'loading' | 'ready' | 'empty' | 'failed';

interface PreviewRequest {
  source: string;
  theme: NativeTheme;
  loading: boolean;
}

@Component
export struct NativeMermaidPreview {
  @Prop @Watch('startPreview') source: string = '';
  @Prop @Watch('startPreview') theme: NativeTheme = 'system';
  @Prop @Watch('startPreview') loading: boolean = false;
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop fontScale: number = 1;

  @State private phase: PreviewPhase = 'loading';
  @State private previewHeight: number = 1;
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private pageReady: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private deadline: number = -1;
  private pollTimer: number = -1;
  private submitTimer: number = -1;
  private submitted?: PreviewRequest;
  private drawing: boolean = false;
  private viewportWidth: number = 0;

  aboutToAppear(): void {
    this.active = true;
    this.startPreview();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.pageReady = false;
    this.generation++;
    this.drawing = false;
    this.submitted = undefined;
    this.clearRenderTimers();
    this.clearSubmitTimer();
  }

  private clearRenderTimers(): void {
    if (this.deadline >= 0) clearTimeout(this.deadline);
    if (this.pollTimer >= 0) clearTimeout(this.pollTimer);
    this.deadline = -1;
    this.pollTimer = -1;
  }

  private clearSubmitTimer(): void {
    if (this.submitTimer >= 0) clearTimeout(this.submitTimer);
    this.submitTimer = -1;
  }

  private resolvePreview(phase: PreviewPhase): void {
    this.clearRenderTimers();
    this.drawing = false;
    if (phase === 'empty' || phase === 'failed') {
      // A failed preview can be remounted from the code switch.
      this.pageReady = false;
    }
    if (phase !== 'ready') {
      this.previewHeight = 1;
    }
    this.phase = phase;
    if (this.loading && this.submitted?.loading && phase !== 'failed') {
      this.scheduleSubmit(STREAM_RENDER_INTERVAL_MS);
    }
  }

  private startPreview(): void {
    if (!this.active) return;
    const submitted = this.submitted;
    const continuing = this.loading && submitted?.loading === true && submitted.theme === this.theme;
    // Text arriving during a draw belongs to the next snapshot. A final input or theme change supersedes it.
    if (continuing && this.drawing) return;
    if (!continuing) this.clearSubmitTimer();
    this.scheduleSubmit(0);
  }

  private scheduleSubmit(delay: number): void {
    if (this.submitTimer >= 0) return;
    this.submitTimer = setTimeout((): void => {
      this.submitTimer = -1;
      this.drawLatest();
    }, delay);
  }

  private drawLatest(): void {
    if (!this.active) return;
    const request: PreviewRequest = { source: this.source, theme: this.theme, loading: this.loading };
    const submitted = this.submitted;
    if (submitted && request.source === submitted.source && request.theme === submitted.theme &&
      request.loading === submitted.loading) return;
    if (!request.loading && !request.source.trim()) {
      this.submitted = request;
      this.generation++;
      this.resolvePreview('empty');
      return;
    }
    if (request.source.length > MAX_DIAGRAM_SOURCE_LENGTH) {
      if (!request.loading) {
        this.submitted = request;
        this.generation++;
        this.resolvePreview('failed');
      }
      return;
    }
    if (this.phase !== 'ready') this.phase = 'loading';
    if (!this.pageReady) {
      if (this.deadline < 0) {
        this.deadline = setTimeout((): void => {
          if (this.active && !this.pageReady) this.resolvePreview('failed');
        }, RENDER_TIMEOUT_MS);
      }
      return;
    }

    this.clearRenderTimers();
    this.submitted = request;
    this.drawing = true;
    const generation = ++this.generation;
    this.deadline = setTimeout(() => {
      if (this.isCurrent(generation)) {
        this.generation++;
        this.failDraw();
      }
    }, RENDER_TIMEOUT_MS);
    void this.submit(generation, request);
  }

  private isCurrent(generation: number): boolean {
    const submitted = this.submitted;
    return this.active && this.generation === generation && !!submitted && submitted.theme === this.theme &&
      submitted.loading === this.loading && (this.loading || submitted.source === this.source);
  }

  private failDraw(): void {
    this.resolvePreview(this.loading ? (this.phase === 'ready' ? 'ready' : 'loading') : 'failed');
  }

  private async submit(generation: number, request: PreviewRequest): Promise<void> {
    try {
      const bytes = new util.TextEncoder().encodeInto(request.source);
      const encoded = new util.Base64Helper().encodeToStringSync(bytes);
      const call = 'window.NuwaMermaid ? window.NuwaMermaid.draw(' +
        JSON.stringify(encoded) + ',' + JSON.stringify(request.theme) + ',' + request.loading.toString() + ') : -2';
      const response = Number(await this.controller.runJavaScript(call));
      if (!this.isCurrent(generation)) return;
      if (response === 0) void this.poll(generation, true);
      else this.failDraw();
    } catch {
      if (this.isCurrent(generation)) this.failDraw();
    }
  }

  private async poll(generation: number, waiting: boolean): Promise<void> {
    try {
      const result = Number(await this.controller.runJavaScript(
        'window.NuwaMermaid ? window.NuwaMermaid.status() : -2'));
      if (!this.isCurrent(generation)) return;
      if (Number.isFinite(result) && result > 0) {
        this.previewHeight = Math.max(40, Math.min(result + 2, 580));
        if (waiting) this.resolvePreview('ready');
      } else if (waiting && result === -1) {
        this.pollTimer = setTimeout(() => { void this.poll(generation, true); }, 75);
      } else if (waiting) {
        this.resolvePreview(result === -4 ? 'loading' : result === -3 ? 'empty' : 'failed');
      }
    } catch {
      if (waiting && this.isCurrent(generation)) this.failDraw();
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
          .fontSize(14 * this.fontScale)
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
            if (this.active && event.request.isMainFrame()) {
              this.generation++;
              this.resolvePreview('failed');
            }
          })
          .onRenderExited(() => {
            if (this.active) {
              this.generation++;
              this.resolvePreview('failed');
            }
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
