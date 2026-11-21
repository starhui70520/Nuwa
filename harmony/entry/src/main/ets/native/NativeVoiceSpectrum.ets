const BAR_WIDTH = 2;
const BAR_GAP = 3;
const MIN_HEIGHT = 5;
const MAX_HEIGHT = 36;
const MAX_BARS = 60;
const REFRESH_MS = 40;

@Component
export struct NativeVoiceSpectrum {
  @Prop level: number = 0;
  private readonly canvas = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private readonly heights = new Float32Array(MAX_BARS);
  private readonly targets = new Float32Array(MAX_BARS);
  private widthVp: number = 0;
  private timer: number = -1;
  private ready: boolean = false;

  aboutToAppear(): void {
    this.timer = setInterval(() => { this.draw(); }, REFRESH_MS);
  }

  aboutToDisappear(): void {
    clearInterval(this.timer);
    this.timer = -1;
    this.ready = false;
  }

  private draw(): void {
    if (!this.ready) return;
    const count = Math.min(MAX_BARS, Math.floor((this.widthVp + BAR_GAP) / (BAR_WIDTH + BAR_GAP)));
    this.canvas.clearRect(0, 0, this.widthVp, MAX_HEIGHT);
    if (count < 1) return;
    const level = Math.min(1, Math.max(0, this.level));
    const time = Date.now();
    const barsWidth = count * (BAR_WIDTH + BAR_GAP) - BAR_GAP;
    const start = (this.widthVp - barsWidth + BAR_WIDTH) / 2;
    const centerY = MAX_HEIGHT / 2;
    this.canvas.lineWidth = BAR_WIDTH;
    this.canvas.strokeStyle = '#679EFE';
    this.canvas.lineCap = 'round';
    this.canvas.beginPath();
    for (let index = 0; index < count; index++) {
      const centerWeight = 0.45 + 0.55 * Math.sin(Math.PI * index / Math.max(1, count - 1));
      const ripple = 0.75 + 0.25 * Math.sin(time / 90 + index * 0.45);
      this.targets[index] = level * centerWeight * ripple;
    }
    for (let index = 0; index < count; index++) {
      const before = this.targets[Math.max(0, index - 1)];
      const after = this.targets[Math.min(count - 1, index + 1)];
      const target = (before + 2 * this.targets[index] + after) / 4;
      const current = this.heights[index];
      this.heights[index] = current + (target - current) * (target > current ? 0.8 : 0.35);
      const halfHeight = (MIN_HEIGHT + (MAX_HEIGHT - MIN_HEIGHT) * this.heights[index] - BAR_WIDTH) / 2;
      const x = start + index * (BAR_WIDTH + BAR_GAP);
      this.canvas.moveTo(x, centerY - halfHeight);
      this.canvas.lineTo(x, centerY + halfHeight);
    }
    this.canvas.stroke();
  }

  build() {
    Canvas(this.canvas)
      .width('100%').height(MAX_HEIGHT).opacity(0.7)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onReady(() => {
        this.ready = true;
        this.draw();
      })
      .onAreaChange((_previous: Area, current: Area) => {
        this.widthVp = Number(current.width);
        this.draw();
      })
  }
}
