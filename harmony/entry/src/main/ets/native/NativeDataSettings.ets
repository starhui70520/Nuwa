/** Native equivalent of the tagged Android data-management settings page. */
@Component
export struct NativeDataSettings {
  @Prop busy: boolean = false;
  @Prop sessionCount: number = 0;

  onImport: () => void = () => {};
  onExport: () => void = () => {};
  onDeleteAll: () => void = () => {};
  onMigration: () => void = () => {};

  @Builder
  private actionButton(label: string, variant: string, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .height(36)
      .padding({ left: 14, right: 14 })
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(variant === 'primary' ? Color.White :
        (variant === 'danger' ? $r('app.color.native_chat_error') : $r('app.color.native_chat_primary')))
      .backgroundColor(variant === 'primary' ? $r('app.color.native_chat_blue') :
        (variant === 'danger' ? Color.Transparent : $r('app.color.native_chat_bg')))
      .border({ width: variant === 'primary' ? 0 : 1,
        color: variant === 'primary' ? $r('app.color.native_chat_blue') :
          (variant === 'danger' ? $r('app.color.native_chat_error') : $r('app.color.native_chat_stroke')) })
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.45)
      .onClick(action)
  }

  @Builder
  private settingRow(label: string, description: string, buttonLabel: string,
    variant: string, enabled: boolean, action: () => void) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(label)
          .fontSize(14)
          .lineHeight(22)
          .fontColor($r('app.color.native_chat_primary'))
        Text(description)
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.native_chat_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.actionButton(buttonLabel, variant, enabled, action)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .border({ width: { bottom: 1 }, color: $r('app.color.native_chat_stroke') })
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 0 }) {
        this.settingRow(
          '一键迁移 DeepSeek 历史',
          '登录官方网页端自动触发导出并合并到本机',
          this.busy ? '处理中…' : '一键导入',
          'primary',
          !this.busy,
          this.onMigration,
        )
        this.settingRow(
          '导入历史对话',
          '按会话 ID 增量合并导入，保留已有本地对话与附件，支持 DeepSeek 导出的 ZIP 文件。',
          this.busy ? '处理中…' : '↑ 上传',
          'outlined',
          !this.busy,
          this.onImport,
        )
        this.settingRow(
          '导出所有历史对话',
          '包含所有历史对话及本地图片原件；其他附件仅保留文件信息，不包含 API Key。',
          this.busy ? '处理中…' : '↓ 下载',
          'outlined',
          !this.busy && this.sessionCount > 0,
          this.onExport,
        )
      }
      .width('100%')
      .borderRadius(16)
      .clip(true)
      .backgroundColor($r('app.color.native_chat_surface'))

      Column({ space: 0 }) {
        this.settingRow(
          '删除所有对话',
          '删除后，所有对话都将被清空且无法找回。本地保存的附件及未发送的草稿也将被删除。',
          this.busy ? '处理中…' : '删除',
          'danger',
          !this.busy && this.sessionCount > 0,
          this.onDeleteAll,
        )
      }
      .width('100%')
      .borderRadius(16)
      .clip(true)
      .backgroundColor($r('app.color.native_chat_surface'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
