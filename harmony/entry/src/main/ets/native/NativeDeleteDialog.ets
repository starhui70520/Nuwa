import { NativeLocale } from './NativeLocation';

export type NativeDeleteMode = 'single' | 'batch' | 'all';

export interface NativeDeleteDialogModel {
  mode: NativeDeleteMode;
  count: number;
  locale: NativeLocale;
  fontScale: number;
  compact: boolean;
  width: number;
  maxHeight: number;
  busy: boolean;
}

@CustomDialog
export struct NativeDeleteDialog {
  controller?: CustomDialogController;
  @Link model: NativeDeleteDialogModel | null;
  onCancel: () => void = () => {};
  onConfirm: () => void = () => {};

  private label(chinese: string, english: string): string {
    return this.model?.locale === 'en-US' ? english : chinese;
  }

  private scaled(size: number): number {
    return size * (this.model?.fontScale ?? 1);
  }

  private title(): string {
    const model = this.model;
    if (!model) return '';
    if (model.mode === 'single') {
      return this.label('永久删除对话', 'Delete chat?');
    }
    if (model.mode === 'batch') {
      return this.label(`删除选中的 ${model.count} 个对话`, `Delete ${model.count} selected chats?`);
    }
    return this.label('删除后，所有对话都将被清空且无法找回',
      'Once deleted, all chats will be cleared and cannot be recovered.');
  }

  private description(): string {
    const model = this.model;
    if (!model) return '';
    if (model.mode === 'single') {
      return this.label('删除后，该对话及其中上传的文件将不可恢复。确认删除吗？',
        'This chat and its uploaded files will be permanently deleted and cannot be recovered. Delete this chat?');
    }
    if (model.mode === 'batch') {
      return this.label('删除后，选中的对话及其中上传的文件将不可恢复。确认删除吗？',
        'Selected chats and their uploaded files will be permanently deleted and cannot be recovered. Continue?');
    }
    return this.label('本地保存的附件及未发送的草稿也将被删除。',
      'Locally saved attachments and unsent drafts will also be deleted.');
  }

  private confirmLabel(): string {
    const model = this.model;
    if (model?.mode === 'all' && model.busy) {
      return this.label('删除中...', 'Deleting...');
    }
    return model?.mode === 'all' ? this.label('删除所有对话', 'Delete all chats') : this.label('删除', 'Delete');
  }

  build() {
    if (this.model) {
      Column({ space: this.model.compact ? 8 : 12 }) {
        Text(this.title()).width('100%')
          .fontSize(this.scaled(this.model.compact ? 14 : 16))
          .lineHeight(this.scaled(this.model.compact ? 20 : 24))
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))

        Text(this.description())
          .width('100%').fontSize(this.scaled(this.model.compact ? 13 : 14))
          .lineHeight(this.scaled(this.model.compact ? 18 : 22))
          .fontColor($r('app.color.native_chat_secondary')).textAlign(TextAlign.Start)

        Row({ space: 8 }) {
          Button(this.label('取消', 'Cancel'), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL })
            .defaultFocus(true).height(40).constraintSize({ minWidth: 72 }).padding({ left: 14, right: 14 })
            .fontSize(this.scaled(14)).fontWeight(FontWeight.Normal).enabled(!this.model.busy)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.native_chat_primary'))
            .border({ width: 1, color: $r('app.color.native_chat_stroke') }).onClick(this.onCancel)
          Button(this.confirmLabel(), { type: ButtonType.Capsule })
            .height(40).constraintSize({ minWidth: 72, maxWidth: '65%' }).padding({ left: 14, right: 14 })
            .fontSize(this.scaled(14)).fontWeight(FontWeight.Medium).enabled(!this.model.busy)
            .backgroundColor($r('app.color.native_chat_error')).fontColor(Color.White)
            .labelStyle({ maxLines: 2 }).onClick(this.onConfirm)
        }
        .width('100%').margin({ top: this.model.compact ? 4 : 8 }).justifyContent(FlexAlign.End)
      }
      .width(this.model.width).constraintSize({ maxWidth: 400, maxHeight: this.model.maxHeight })
      .padding({
        left: this.model.compact ? 14 : 24, right: this.model.compact ? 14 : 24,
        top: this.model.compact ? 12 : 22, bottom: this.model.compact ? 12 : 22,
      })
      .borderRadius(this.model.compact ? 16 : 24)
      .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .shadow({ radius: 22, color: '#26000000', offsetY: 9 })
    }
  }
}
