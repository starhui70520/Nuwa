import { nativeIconTint } from './NativeIconTint';

export const NATIVE_DOCUMENT_CARD_WIDTH = 240;
export const NATIVE_DOCUMENT_CARD_HEIGHT = 64;
export type NativeDocumentCardStatus = 'ready' | 'uploading' | 'failed';

const IMAGE_EXTENSIONS = ['JPG', 'JPEG', 'PNG', 'GIF', 'WEBP', 'BMP', 'SVG', 'HEIC', 'TIF', 'TIFF'];
const SPREADSHEET_EXTENSIONS = ['XLS', 'XLSX', 'CSV'];
const UNITS = ['KB', 'MB', 'GB'];

function documentExtension(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toUpperCase() : '';
}

function documentSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${UNITS[unit]}`;
}

function documentIcon(extension: string): Resource {
  if (extension === 'PDF') return $r('app.media.native_attachment_pdf');
  if (SPREADSHEET_EXTENSIONS.includes(extension)) return $r('app.media.native_attachment_spreadsheet');
  if (extension === 'PPT' || extension === 'PPTX') return $r('app.media.native_attachment_presentation');
  if (IMAGE_EXTENSIONS.includes(extension)) return $r('app.media.native_attachment_image');
  return $r('app.media.native_attachment_other');
}

@Component
export struct NativeDocumentCard {
  @Prop name: string = '';
  @Prop bytes: number = 0;
  @Prop status: NativeDocumentCardStatus = 'ready';
  @Prop detail: string = '';
  @Prop locale: string = '';
  @Prop fontScale: number = 1;
  @Prop editable: boolean = false;
  @Prop retryable: boolean = false;
  @Prop openable: boolean = false;
  onAction: () => void = (): void => {};

  private label(zh: string, en: string): string {
    return this.locale === 'en-US' ? en : zh;
  }

  private subtitle(): string {
    if (this.status === 'uploading') return this.label('上传中...', 'Uploading...');
    if (this.status === 'failed') return this.detail || this.label('上传失败', 'Upload failed');
    const extension = documentExtension(this.name);
    return (extension ? extension + ' ' : '') + documentSize(this.bytes);
  }

  private canRetry(): boolean {
    return this.status === 'failed' && this.retryable;
  }

  private showFailureColor(): boolean {
    return this.status === 'failed' && (this.editable || this.canRetry());
  }

  private description(): string {
    const subtitle = this.subtitle();
    return this.canRetry() ? this.label(subtitle + '，点击重试', subtitle + '. Click to retry') : subtitle;
  }

  @Builder
  private content() {
    Row({ space: 10 }) {
      Stack() {
        if (this.status === 'uploading') {
          LoadingProgress().width(16).height(16).color($r('app.color.native_chat_action'))
        } else if (this.canRetry()) {
          Image($r('app.media.native_retry')).width(18).height(18).draggable(false)
            .colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        } else {
          Image(documentIcon(documentExtension(this.name))).width(28).height(28).draggable(false)
        }
      }
      .width(28).height(28).accessibilityLevel('no')
      Column() {
        Text(this.name).width('100%').fontSize(14 * this.fontScale).lineHeight(22 * this.fontScale)
          .fontColor($r('app.color.native_chat_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle()).width('100%').fontSize(12 * this.fontScale).lineHeight(18 * this.fontScale)
          .fontColor(this.showFailureColor() ? $r('app.color.native_chat_error') : $r('app.color.native_chat_action'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width(NATIVE_DOCUMENT_CARD_WIDTH).height(NATIVE_DOCUMENT_CARD_HEIGHT)
    .padding({ left: 14, right: this.editable ? 24 : 12 }).borderRadius(16)
    .backgroundColor($r('app.color.native_chat_surface'))
    .border({ width: 1, color: this.showFailureColor() ? $r('app.color.native_chat_error') :
      $r('app.color.native_attachment_border') })
  }

  build() {
    if (this.canRetry() || (this.status === 'ready' && this.openable)) {
      Button({ type: ButtonType.Normal }) { this.content() }
      .width(NATIVE_DOCUMENT_CARD_WIDTH).height(NATIVE_DOCUMENT_CARD_HEIGHT)
      .padding(0).borderRadius(16).backgroundColor(Color.Transparent)
      .accessibilityText(this.name).accessibilityDescription(this.description())
      .onClick(() => { this.onAction(); })
    } else {
      this.content()
    }
  }
}
