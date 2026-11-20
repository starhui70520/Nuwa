import { accessibility } from '@kit.AccessibilityKit';
import { nativeIconTint } from './NativeIconTint';

@Component
struct AnimatedRecordingIndicator {
  @Prop diameter: number = 26;
  @State private entered: boolean = false;

  build() {
    Stack() {
      Stack() {
        Circle().width(this.diameter).height(this.diameter).fill($r('app.color.native_chat_blue'))
          .scale({ x: this.entered ? 1.1 : 1, y: this.entered ? 1.1 : 1 })
          .animation({ duration: 900, delay: 150, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate })
      }
      .width(this.diameter).height(this.diameter)
      .opacity(this.entered ? 0.2 : 0)
      .scale({ x: this.entered ? 1 : 0.6, y: this.entered ? 1 : 0.6 })
      .animation({ duration: 150, curve: Curve.EaseOut })
      Circle().width(this.diameter - 4).height(this.diameter - 4).fill($r('app.color.native_chat_blue'))
        .opacity(this.entered ? 0.75 : 0)
        .scale({ x: this.entered ? 1 : 0.6, y: this.entered ? 1 : 0.6 })
        .animation({ duration: 200, delay: 140, curve: Curve.EaseOut })
      Image($r('app.media.native_mic_outline')).width(16).height(16)
        .colorFilter(nativeIconTint($r('app.color.native_chat_blue')))
        .opacity(this.entered ? 0 : 1)
        .animation({ duration: 120, delay: 140, curve: Curve.EaseOut })
      Image($r('app.media.native_mic_fill')).width(16).height(16).colorFilter(nativeIconTint(Color.White))
        .opacity(this.entered ? 1 : 0)
        .animation({ duration: 100, delay: 260, curve: Curve.EaseOut })
    }
    .width(this.diameter).height(this.diameter)
    .onAppear(() => { this.entered = true; })
  }
}

@Component
export struct NativeRecordingIndicator {
  @Prop diameter: number = 26;
  @State private reduceMotion: boolean = false;
  private readonly onMotionReductionChange = (enabled: boolean): void => { this.reduceMotion = enabled; };

  aboutToAppear(): void {
    try {
      this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
      accessibility.onAnimationReduceStateChange(this.onMotionReductionChange);
    } catch {
      // Earlier system versions do not expose the animation reduction preference.
    }
  }

  aboutToDisappear(): void {
    try {
      accessibility.offAnimationReduceStateChange(this.onMotionReductionChange);
    } catch {
      // Earlier system versions do not expose the animation reduction preference.
    }
  }

  build() {
    Stack() {
      if (this.reduceMotion) {
        Circle().width(this.diameter).height(this.diameter).fill($r('app.color.native_chat_blue')).opacity(0.2)
        Circle().width(this.diameter - 4).height(this.diameter - 4).fill($r('app.color.native_chat_blue')).opacity(0.75)
        Image($r('app.media.native_mic_fill')).width(16).height(16).colorFilter(nativeIconTint(Color.White))
      } else {
        AnimatedRecordingIndicator({ diameter: this.diameter })
      }
    }
    .width(this.diameter).height(this.diameter)
    .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
