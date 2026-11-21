import { pasteboard } from '@kit.BasicServicesKit';
import { nativeIconTint } from './NativeIconTint';
import { NATIVE_ICON_CLICK_EFFECT, triggerNativeHaptic } from './NativeImmersiveUI';

const COPY_FEEDBACK_MS = 1000;
const CODE_COPY_FEEDBACK_MS = 1500;

@Component
export struct NativeMessageCopyButton {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop locale: string = '';
  @Prop codeBlock: boolean = false;
  @Prop fontScale: number = 1;
  @State private copied: boolean = false;
  private writing: boolean = false;
  private writeId: number = 0;
  private feedbackTimer: number = -1;

  aboutToDisappear(): void {
    this.writeId++;
    this.writing = false;
    this.resetFeedback();
  }

  private onTextChanged(): void {
    if (this.codeBlock) this.resetFeedback();
  }

  private resetFeedback(): void {
    if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer);
    this.feedbackTimer = -1;
    this.copied = false;
  }

  private label(zh: string, en: string): string {
    return this.locale === 'en-US' ? en : zh;
  }

  private copyLabel(): string {
    return this.copied ? this.label('已复制', 'Copied') : this.label('复制', 'Copy');
  }

  private async copy(): Promise<void> {
    if (this.writing || (!this.codeBlock && (this.copied || !this.text))) return;
    const text = this.text;
    const writeId = ++this.writeId;
    this.writing = true;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      if (writeId !== this.writeId || (this.codeBlock && text !== this.text)) return;
      if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer);
      this.copied = true;
      triggerNativeHaptic('success');
      this.feedbackTimer = setTimeout((): void => {
        this.feedbackTimer = -1;
        this.copied = false;
      }, this.codeBlock ? CODE_COPY_FEEDBACK_MS : COPY_FEEDBACK_MS);
    } catch {
      if (writeId === this.writeId) {
        this.getUIContext().getPromptAction().showToast({ message: this.label('复制失败', 'Copy failed') });
      }
    } finally {
      if (writeId === this.writeId) this.writing = false;
    }
  }

  @Builder
  private copyIcon(size: number, color: Resource) {
    Image(this.copied ? $r('app.media.native_copy_done') : $r('app.media.native_copy'))
      .width(size).height(size).draggable(false).colorFilter(nativeIconTint(color)).accessibilityLevel('no')
  }

  build() {
    if (this.codeBlock) {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 3 }) {
          this.copyIcon(14, $r('app.color.native_chat_secondary'))
          Text(this.copyLabel()).fontSize(13 * this.fontScale).lineHeight(20 * this.fontScale)
            .fontColor($r('app.color.native_chat_secondary')).copyOption(CopyOptions.None)
        }
      }
      .height(28).padding({ left: 10, right: 10 }).borderRadius(8).backgroundColor(Color.Transparent)
      .accessibilityText(this.copyLabel())
      .onClick(() => { void this.copy(); })
    } else {
      Button({ type: ButtonType.Circle }) {
        this.copyIcon(16, $r('app.color.native_chat_action'))
      }
      .width(28).height(28).padding(0).backgroundColor(Color.Transparent)
      .clickEffect(NATIVE_ICON_CLICK_EFFECT)
      .accessibilityText(this.copyLabel())
      .onClick(() => { void this.copy(); })
    }
  }
}
