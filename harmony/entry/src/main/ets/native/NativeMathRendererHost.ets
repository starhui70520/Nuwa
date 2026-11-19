import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import {
  closeNativeMathJobs, completeNativeMathJob, NativeMathPicture, NativeMathPictureJob, nextNativeMathJob,
  subscribeNativeMathHost,
} from './NativeMathRenderQueue';

const MATH_ROOT = 'resource://rawfile/math/';
const MATH_PAGE = MATH_ROOT + 'index.html';
const HOST_TIMEOUT = 8000;
const FORMULA_TIMEOUT = 4000;

interface FormulaPoll {
  pending: boolean;
  picture: NativeMathPicture | null;
}

function scriptString(result: string): string {
  const text = result.trim();
  return text.startsWith('"') ? JSON.parse(text) as string : text;
}

function readPicture(result: string): FormulaPoll {
  const value = scriptString(result);
  if (value === 'pending') return { pending: true, picture: null };
  if (value === 'invalid') return { pending: false, picture: null };
  const picture = JSON.parse(value) as NativeMathPicture;
  if (!picture || typeof picture.png !== 'string' || picture.png.length > 260000 ||
    !/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(picture.png) ||
    !Number.isInteger(picture.width) || picture.width <= 0 || picture.width > 2800 ||
    !Number.isInteger(picture.height) || picture.height <= 0 || picture.height > 1000 ||
    !Number.isFinite(picture.depth) || picture.depth < 0 || picture.depth > picture.height) {
    return { pending: false, picture: null };
  }
  return { pending: false, picture };
}

@Component
export struct NativeMathRendererHost {
  @State private mounted: boolean = false;
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private unsubscribe?: () => void;
  private alive: boolean = false;
  private ready: boolean = false;
  private unavailable: boolean = false;
  private draining: boolean = false;
  private hostTimer: number = -1;

  aboutToAppear(): void {
    this.alive = true;
    this.unsubscribe = subscribeNativeMathHost(() => { this.wake(); });
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.ready = false;
    clearTimeout(this.hostTimer);
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private failHost(): void {
    if (!this.alive) return;
    clearTimeout(this.hostTimer);
    this.ready = false;
    this.unavailable = true;
    this.mounted = false;
    closeNativeMathJobs();
  }

  private wake(): void {
    if (!this.alive) return;
    if (this.unavailable) {
      closeNativeMathJobs();
      return;
    }
    if (!this.mounted) {
      this.mounted = true;
      this.hostTimer = setTimeout(() => { this.failHost(); }, HOST_TIMEOUT);
    } else if (this.ready && !this.draining) {
      void this.drain();
    }
  }

  private async render(job: NativeMathPictureJob): Promise<void> {
    this.hostTimer = setTimeout(() => { this.failHost(); }, FORMULA_TIMEOUT);
    try {
      const source = new util.TextEncoder().encodeInto(JSON.stringify(job.request));
      const payload = new util.Base64Helper().encodeToStringSync(source);
      const started = await this.controller.runJavaScript(
        'window.NuwaMath && window.NuwaMath.begin(' + JSON.stringify(payload) + ') ? 1 : 0');
      if (Number(scriptString(started)) !== 1) throw new Error('Math renderer unavailable');
      const deadline = Date.now() + FORMULA_TIMEOUT;
      while (this.alive && this.ready && Date.now() < deadline) {
        const result = await this.controller.runJavaScript('window.NuwaMath.take()');
        const next = readPicture(result);
        if (!next.pending) {
          completeNativeMathJob(job, next.picture, true);
          return;
        }
        await new Promise<void>((resolve): void => { setTimeout(() => { resolve(); }, 35); });
      }
      throw new Error('Math renderer timed out');
    } finally {
      clearTimeout(this.hostTimer);
    }
  }

  private async drain(): Promise<void> {
    this.draining = true;
    try {
      let job = nextNativeMathJob();
      while (job && this.alive && this.ready) {
        await this.render(job);
        job = nextNativeMathJob();
      }
    } catch {
      this.failHost();
    } finally {
      this.draining = false;
    }
  }

  private rejectResource(target: string): WebResourceResponse | null {
    if (target === MATH_PAGE || target === MATH_ROOT + 'render.js' || target === MATH_ROOT + 'fonts.js' ||
      target === MATH_ROOT + 'katex.min.js' || target === MATH_ROOT + 'mhchem.min.js' ||
      target.startsWith('data:font/woff2;base64,')) {
      return null;
    }
    const response = new WebResourceResponse();
    response.setResponseCode(403);
    response.setReasonMessage('Forbidden');
    response.setResponseMimeType('text/plain');
    response.setResponseData('');
    return response;
  }

  build() {
    Stack() {
      if (this.mounted) {
        Web({ src: MATH_PAGE, controller: this.controller, incognitoMode: true })
          .width(1).height(1)
          .backgroundColor(Color.Transparent)
          .focusable(false)
          .zoomAccess(false)
          .javaScriptAccess(true)
          .fileAccess(false)
          .domStorageAccess(false)
          .databaseAccess(false)
          .allowWindowOpenMethod(false)
          .blockNetwork(true)
          .onlineImageAccess(false)
          .imageAccess(false)
          .mixedMode(MixedMode.None)
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
            this.ready || event.data.getRequestUrl() !== MATH_PAGE)
          .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse | null =>
            this.rejectResource(event.request.getRequestUrl()))
          .onPageEnd((event: OnPageEndEvent) => {
            if (!this.alive || event.url !== MATH_PAGE || this.ready) return;
            clearTimeout(this.hostTimer);
            this.ready = true;
            this.wake();
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event.request.isMainFrame()) this.failHost();
          })
          .onRenderExited(() => { this.failHost(); })
      }
    }
    .width(1).height(1)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no-hide-descendants')
  }
}
