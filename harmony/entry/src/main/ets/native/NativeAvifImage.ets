import { systemDateTime } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import avif, { AvifAnimation } from 'libnuwa_avif.so';

const MAX_TIMER_MS = 2147483647;
const DEFAULT_FRAME_DURATION_MS = 100;

interface PreparedFrame {
  pixels: image.PixelMap;
  durationMs: number;
}

function playbackTime(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE);
}

function releasePixels(pixels: image.PixelMap | undefined): void {
  void pixels?.release().catch(() => {});
}

@Component
export struct NativeAvifImage {
  @Prop uri: string = '';
  @Prop @Watch('syncPlayback') originalPath: string = '';
  @Prop fit: ImageFit = ImageFit.Contain;
  @Prop @Watch('syncPlayback') active: boolean = true;
  @State private pixels: image.PixelMap | undefined = undefined;
  private mounted: boolean = false;
  private visible: boolean = false;
  private playbackPath: string = '';
  private generation: number = 0;
  private decoderSession: AvifAnimation | undefined;
  private timer: number = -1;
  private wake?: () => void;

  aboutToAppear(): void {
    this.mounted = true;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.visible = false;
    this.stopPlayback();
    releasePixels(this.pixels);
  }

  private syncPlayback(): void {
    const path = this.mounted && this.visible && this.active ? this.originalPath : '';
    if (path === this.playbackPath) return;
    this.stopPlayback();
    this.showFrame(undefined);
    this.playbackPath = path;
    if (path) void this.play(path, this.generation);
  }

  private stopPlayback(): void {
    this.playbackPath = '';
    this.generation++;
    clearTimeout(this.timer);
    this.timer = -1;
    const wake = this.wake;
    this.wake = undefined;
    wake?.();
    this.closeAnimation();
  }

  private closeAnimation(): void {
    const animation = this.decoderSession;
    this.decoderSession = undefined;
    if (animation) avif.closeAvifAnimation(animation);
  }

  private showFrame(pixels: image.PixelMap | undefined): void {
    const previous = this.pixels;
    this.pixels = pixels;
    releasePixels(previous);
  }

  private async waitUntil(deadline: number, generation: number): Promise<void> {
    let remaining = Math.ceil(deadline - playbackTime());
    while (remaining > 0 && generation === this.generation) {
      await new Promise<void>((resolve: () => void): void => {
        this.wake = resolve;
        this.timer = setTimeout(resolve, Math.min(remaining, MAX_TIMER_MS));
      });
      remaining = Math.ceil(deadline - playbackTime());
    }
    if (generation === this.generation) {
      this.wake = undefined;
      this.timer = -1;
    }
  }

  private async readFrame(animation: AvifAnimation, index: number, generation: number): Promise<PreparedFrame | undefined> {
    const frame = await avif.readAvifAnimationFrame(animation, index);
    if (!frame || generation !== this.generation) return undefined;
    const pixels = await image.createPixelMap(frame.rgba, {
      size: { width: frame.width, height: frame.height },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
    });
    const durationMs = Number.isFinite(frame.durationMs) && frame.durationMs >= 0 ?
      frame.durationMs : DEFAULT_FRAME_DURATION_MS;
    return { pixels: pixels, durationMs: durationMs };
  }

  private async play(path: string, generation: number): Promise<void> {
    let next: PreparedFrame | undefined;
    let completed = false;
    try {
      const animation = await avif.openAvifAnimation(path);
      if (!animation) return;
      if (generation !== this.generation || animation.frameCount < 2) {
        avif.closeAvifAnimation(animation);
        return;
      }
      this.decoderSession = animation;
      let index = 0;
      let remainingPlays = animation.playCount;
      let deadline = 0;
      while (generation === this.generation) {
        // Decode only the next frame while its predecessor is on screen.
        next = await this.readFrame(animation, index, generation);
        if (!next || generation !== this.generation) return;
        await this.waitUntil(deadline, generation);
        if (generation !== this.generation) return;
        this.showFrame(next.pixels);
        const now = playbackTime();
        const duration = next.durationMs;
        next = undefined;
        // Preserve the timeline across timer jitter. Rebase if decoding consumes a full display interval.
        const end = deadline + duration;
        deadline = deadline > 0 && end > now ? end : now + duration;
        index++;
        if (index < animation.frameCount) continue;
        if (remainingPlays === 1) {
          completed = true;
          return;
        }
        if (remainingPlays > 1) remainingPlays--;
        index = 0;
      }
    } catch {
      // An unsupported or damaged sequence can still use the supplied poster.
    } finally {
      releasePixels(next?.pixels);
      if (generation === this.generation) {
        this.closeAnimation();
        if (!completed) this.showFrame(undefined);
      }
    }
  }

  build() {
    Image(this.pixels ?? this.uri)
      .width('100%').height('100%').objectFit(this.fit).autoResize(true).draggable(false)
      .onVisibleAreaChange([0], (_isExpanding: boolean, ratio: number): void => {
        this.visible = ratio > 0;
        this.syncPlayback();
      })
  }
}
