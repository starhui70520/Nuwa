import { pasteboard } from '@kit.BasicServicesKit';
import { nativeIconTint } from './NativeIconTint';

const COPY_FEEDBACK_MS = 1000;

// Match the check icon used by the original message action.
const CHECK_PATH = 'M15.0498 3.92579L8.49512 12.3818C8.25774 12.6881 8.04517 12.9645 7.84668 13.1689' +
  'C7.63957 13.3823 7.38732 13.5841 7.04492 13.6719C6.86373 13.7183 6.6757 13.7346 6.48926 13.7197' +
  'C6.13666 13.6915 5.8528 13.5355 5.6123 13.3604C5.38201 13.1926 5.12573 12.9567 4.83984 12.6953' +
  'L1.03125 9.21289L1.96875 8.1875L5.77734 11.6699C6.08684 11.9529 6.27773 12.1249 6.43066 12.2363' +
  'C6.50183 12.2882 6.54699 12.3135 6.57324 12.3252C6.58525 12.3305 6.59269 12.3322 6.5957 12.333' +
  'C6.59802 12.3336 6.59961 12.334 6.59961 12.334C6.63317 12.3367 6.66758 12.3335 6.7002 12.3252' +
  'C6.7002 12.3252 6.70211 12.3251 6.7041 12.3242C6.70698 12.3229 6.71348 12.319 6.72461 12.3115' +
  'C6.74849 12.2956 6.78843 12.2642 6.84961 12.2012C6.98138 12.0654 7.13957 11.8628 7.39648 11.5313' +
  'L13.9502 3.07422L15.0498 3.92579Z';

@Component
export struct NativeMessageCopyButton {
  @Prop text: string = '';
  @Prop locale: string = '';
  @State private copied: boolean = false;
  private writing: boolean = false;
  private writeId: number = 0;
  private feedbackTimer: number = -1;

  aboutToDisappear(): void {
    this.writeId++;
    this.writing = false;
    if (this.feedbackTimer >= 0) clearTimeout(this.feedbackTimer);
    this.feedbackTimer = -1;
    this.copied = false;
  }

  private label(zh: string, en: string): string {
    return this.locale === 'en-US' ? en : zh;
  }

  private async copy(): Promise<void> {
    if (this.copied || this.writing || !this.text) return;
    const writeId = ++this.writeId;
    this.writing = true;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.text));
      if (writeId !== this.writeId) return;
      this.copied = true;
      this.feedbackTimer = setTimeout((): void => {
        this.feedbackTimer = -1;
        this.copied = false;
      }, COPY_FEEDBACK_MS);
    } catch {
      if (writeId === this.writeId) {
        this.getUIContext().getPromptAction().showToast({ message: this.label('复制失败', 'Copy failed') });
      }
    } finally {
      if (writeId === this.writeId) this.writing = false;
    }
  }

  build() {
    Button({ type: ButtonType.Circle }) {
      if (this.copied) {
        Shape() {
          Path({ commands: CHECK_PATH }).fill($r('app.color.native_chat_action'))
        }.width(16).height(16).viewPort({ width: '16px', height: '16px' })
      } else {
        Image($r('app.media.native_copy')).width(16).height(16).draggable(false)
          .colorFilter(nativeIconTint($r('app.color.native_chat_action')))
      }
    }
    .width(28).height(28).padding(0).backgroundColor(Color.Transparent)
    .accessibilityText(this.copied ? this.label('已复制', 'Copied') : this.label('复制', 'Copy'))
    .onClick(() => { void this.copy(); })
  }
}
