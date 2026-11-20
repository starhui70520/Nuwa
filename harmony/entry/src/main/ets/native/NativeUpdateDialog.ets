import { NativeLocale } from './NativeLocation';
import { NativeUpdateCheck } from './NativeUpdates';

export interface NativeUpdateDialogModel {
  update: NativeUpdateCheck;
  locale: NativeLocale;
  fontScale: number;
  compact: boolean;
  width: number;
  maxHeight: number;
}

@CustomDialog
export struct NativeUpdateDialog {
  controller?: CustomDialogController;
  @Link model: NativeUpdateDialogModel | null;
  onLater: () => void = () => {};
  onDownload: () => void = () => {};

  private label(chinese: string, english: string): string {
    return this.model?.locale === 'en-US' ? english : chinese;
  }

  private scaled(size: number): number {
    return size * (this.model?.fontScale ?? 1);
  }

  build() {
    if (this.model) {
      Column({ space: this.model.compact ? 8 : 12 }) {
        Row({ space: 6 }) {
          Text(this.label(`发现新版本 v${this.model.update.latestVersion}`,
            `New version v${this.model.update.latestVersion} available`))
            .layoutWeight(1).fontSize(this.scaled(this.model.compact ? 14 : 16)).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_primary')).maxLines(2)
          Button('×', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .width(34).height(34).padding(0).fontSize(23)
            .fontColor($r('app.color.native_chat_secondary'))
            .accessibilityText(this.label('关闭', 'Close')).onClick(this.onLater)
        }
        .width('100%')

        Column({ space: 4 }) {
          Text(this.label(`当前版本：v${this.model.update.currentVersion}`,
            `Current version: v${this.model.update.currentVersion}`))
            .fontSize(this.scaled(13)).lineHeight(20).fontColor($r('app.color.native_chat_secondary'))
          Text(this.label(`最新版本：v${this.model.update.latestVersion}`,
            `Latest version: v${this.model.update.latestVersion}`))
            .fontSize(this.scaled(13)).lineHeight(20).fontColor($r('app.color.native_chat_secondary'))
        }
        .width('100%').alignItems(HorizontalAlign.Start)

        Scroll() {
          Column({ space: 8 }) {
            Text(this.model.update.notes || this.label('包含体验优化与问题修复。', 'Includes improvements and bug fixes.'))
              .width('100%').fontSize(this.scaled(13)).lineHeight(20)
              .fontColor($r('app.color.native_chat_primary')).textAlign(TextAlign.Start)

            if (this.model.update.appGalleryNote) {
              Text(this.model.update.appGalleryNote)
                .width('100%').fontSize(this.scaled(12)).lineHeight(this.scaled(18))
                .fontColor($r('app.color.native_chat_secondary')).textAlign(TextAlign.Start)
            }
          }
          .width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        }
        .width('100%').constraintSize({ maxHeight: 180 }).scrollBar(BarState.Auto)
        .borderRadius(10).backgroundColor($r('app.color.native_chat_field'))
        .flexShrink(1)

        Row({ space: 10 }) {
          Button(this.label('暂不更新', 'Later'), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL })
            .height(40).constraintSize({ minWidth: 72 }).padding({ left: 14, right: 14 })
            .fontSize(this.scaled(14)).fontWeight(FontWeight.Normal)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.native_chat_primary'))
            .border({ width: 1, color: $r('app.color.native_chat_stroke') }).onClick(this.onLater)
          Button(this.model.update.appGalleryUrl ? this.label('前往 AppGallery', 'Open AppGallery') :
            this.label('前往下载', 'Open download'), { type: ButtonType.Capsule })
            .height(40).constraintSize({ minWidth: 72, maxWidth: '65%' }).padding({ left: 14, right: 14 })
            .fontSize(this.scaled(14)).fontWeight(FontWeight.Medium)
            .labelStyle({ maxLines: 2 })
            .backgroundColor($r('app.color.native_chat_blue')).fontColor(Color.White).onClick(this.onDownload)
        }
        .width('100%').margin({ top: 4 }).justifyContent(FlexAlign.End)
      }
      .width(this.model.width).constraintSize({ maxWidth: 400, maxHeight: this.model.maxHeight })
      .padding({
        left: this.model.compact ? 14 : 24, right: this.model.compact ? 14 : 24,
        top: this.model.compact ? 12 : 22, bottom: this.model.compact ? 12 : 22,
      }).borderRadius(this.model.compact ? 16 : 24)
      .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .shadow({ radius: 22, color: '#26000000', offsetY: 9 })
    }
  }
}
