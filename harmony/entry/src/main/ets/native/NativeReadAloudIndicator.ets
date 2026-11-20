import { accessibility } from '@kit.AccessibilityKit';

const BARS: number[] = [0, 1, 2, 3];
const STATIC_PLAYING_HEIGHTS: number[] = [7, 14, 4, 10];
const PLAYING_PHASE_OFFSETS_MS: number[] = [0, 1200, 800, 400];
const LOADING_PERIOD_MS = 1500;
const PLAYING_PERIOD_MS = 1600;
const SETTLE_MS = 150;
const REDRAW_MS = 40;
const LOADING_ALPHA: number[][] = [
  [0.4, 0.38, 0.325, 0.25, 0.174, 0.109, 0.061, 0.031, 0.014, 0.006, 0.002, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0.014, 0.031, 0.061, 0.109, 0.174, 0.25, 0.325, 0.38, 0.4, 0.38, 0.325, 0.25, 0.174, 0.109, 0.061, 0.031, 0.014, 0.006, 0.002, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0.002, 0.006, 0.014, 0.031, 0.061, 0.109, 0.174, 0.25, 0.325, 0.38, 0.4, 0.38, 0.325, 0.25, 0.174, 0.109, 0.061, 0.031, 0.014],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.002, 0.006, 0.014, 0.031, 0.061, 0.109, 0.174, 0.25, 0.325, 0.38, 0.4],
];

@Component
export struct NativeReadAloudIndicator {
  @Prop @Watch('modeChanged') mode: 'loading' | 'playing' = 'loading';
  @State private heights: number[] = [4, 4, 4, 4];
  @State private highlights: number[] = [0, 0, 0, 0];
  private timer: number = -1;
  private startedAt: number = 0;
  private modeStartedAt: number = 0;
  private reduceMotion: boolean = false;
  private readonly onMotionReductionChange = (enabled: boolean): void => {
    this.reduceMotion = enabled;
    this.updateTimer();
    this.updateBars();
  };

  aboutToAppear(): void {
    this.startedAt = Date.now();
    this.modeStartedAt = this.startedAt;
    try {
      this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange(this.onMotionReductionChange);
    } catch {
      // These system animation settings are unavailable on older Harmony versions.
    }
    this.updateTimer();
    this.updateBars();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    try {
      accessibility.offAnimationReduceStateChange(this.onMotionReductionChange);
    } catch {
      // The listener API is absent on older Harmony versions.
    }
  }

  private modeChanged(): void {
    this.modeStartedAt = Date.now();
    this.updateBars();
  }

  private updateTimer(): void {
    if (this.reduceMotion) {
      if (this.timer >= 0) clearInterval(this.timer);
      this.timer = -1;
    } else if (this.timer < 0) {
      this.timer = setInterval(() => { this.updateBars(); }, REDRAW_MS);
    }
  }

  private loadingAlpha(index: number, time: number): number {
    const samples = LOADING_ALPHA[index];
    const sample = (Math.max(0, time) % LOADING_PERIOD_MS) / LOADING_PERIOD_MS * (samples.length - 1);
    const left = Math.floor(sample);
    return samples[left] + (samples[left + 1] - samples[left]) * (sample - left);
  }

  private ease(progress: number, x1: number, x2: number, y1: number): number {
    let t = progress;
    for (let count = 0; count < 5; count++) {
      const inverse = 1 - t;
      const x = 3 * inverse * inverse * t * x1 + 3 * inverse * t * t * x2 + t * t * t;
      const derivative = 3 * inverse * inverse * x1 + 6 * inverse * t * (x2 - x1) + 3 * t * t * (1 - x2);
      if (derivative > 0.0001) t = Math.max(0, Math.min(1, t - (x - progress) / derivative));
    }
    const inverse = 1 - t;
    return 3 * inverse * inverse * t * y1 + 3 * inverse * t * t + t * t * t;
  }

  private playingHeight(index: number, time: number): number {
    const phase = ((Math.max(0, time) + PLAYING_PHASE_OFFSETS_MS[index]) % PLAYING_PERIOD_MS) / PLAYING_PERIOD_MS;
    const leg = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    return 14 - 10 * this.ease(leg, 0.42, 0.58, 0);
  }

  private updateBars(): void {
    const now = Date.now();
    if (this.mode === 'loading') {
      this.heights = [4, 4, 4, 4];
      this.highlights = this.reduceMotion ? [0, 0, 0, 0] :
        BARS.map((index: number): number => this.loadingAlpha(index, now - this.modeStartedAt));
    } else if (this.reduceMotion) {
      this.heights = STATIC_PLAYING_HEIGHTS;
    } else {
      const elapsed = Math.max(0, Math.min(1, (now - this.modeStartedAt) / SETTLE_MS));
      const scale = (4 + 10 * this.ease(elapsed, 0.22, 0.36, 1)) / 14;
      this.heights = BARS.map((index: number): number => this.playingHeight(index, now - this.startedAt) * scale);
    }
  }

  build() {
    Row({ space: 2 }) {
      ForEach(BARS, (index: number) => {
        Stack({ alignContent: Alignment.Center }) {
          Row().width(2).height(this.heights[index]).borderRadius(1)
            .backgroundColor(this.mode === 'loading' ? $r('app.color.native_read_aloud_loading') :
              $r('app.color.native_read_aloud_playing'))
          if (this.mode === 'loading') {
            Row().width(2).height(this.heights[index]).borderRadius(1)
              .backgroundColor(Color.Black).opacity(this.highlights[index])
          }
        }
        .width(2).height(16)
      }, (index: number): string => index.toString())
    }
    .id('nuwa-reading-indicator').width(16).height(16).justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
  }
}
