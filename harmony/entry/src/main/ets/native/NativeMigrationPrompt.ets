import { NativeLocale } from './NativeLocation';

@Component
export struct NativeMigrationPrompt {
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop compact: boolean = false;
  @Prop importing: boolean = false;
  onMigrate: () => void = () => {};
  onImport: () => void = () => {};
  onDismiss: () => void = () => {};

  private label(chinese: string, english: string): string {
    return this.locale === 'en-US' ? english : chinese;
  }

  @Builder
  private secondaryButton(title: () => string, action: () => void) {
    Button(title(), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
      .width('100%').height(this.compact ? 36 : 42).enabled(!this.importing)
      .fontSize(14).fontColor($r('app.color.native_chat_primary'))
      .border({ width: 1, color: $r('app.color.native_chat_stroke') }).onClick(action)
  }

  build() {
    Column({ space: this.compact ? 8 : 12 }) {
      Row({ space: 6 }) {
        Text(this.label('是否从官方 DeepSeek 迁移历史对话？', 'Migrate chat history from DeepSeek?'))
          .layoutWeight(1).fontSize(this.compact ? 16 : 18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary'))
        Button('×', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .width(33).height(33).padding(0).fontSize(23).enabled(!this.importing)
          .fontColor($r('app.color.native_chat_secondary'))
          .accessibilityText(this.label('关闭', 'Close')).onClick(this.onDismiss)
      }
      .width('100%')
      Image($r('app.media.native_welcome_logo')).width(this.compact ? 36 : 52).height(this.compact ? 36 : 52)
        .borderRadius(this.compact ? 10 : 14).draggable(false).accessibilityText('Nuwa')
      Text(this.label(
        '将官方网页或 App 的历史会话增量合并到本机永久保存，不受 72 小时限制；也可稍后在设置中随时操作。',
        'Merge your official DeepSeek chats into local storage with no 72-hour limit. You can also do this later in Settings.'))
        .width('100%').fontSize(this.compact ? 12 : 13).lineHeight(this.compact ? 16 : 20).textAlign(TextAlign.Center)
        .fontColor($r('app.color.native_chat_secondary'))
      Column({ space: this.compact ? 6 : 10 }) {
        Button(this.label('一键迁移', 'One-Click Migrate'), { type: ButtonType.Capsule })
          .width('100%').height(this.compact ? 36 : 42).fontSize(14).enabled(!this.importing)
          .backgroundColor($r('app.color.native_chat_blue')).fontColor(Color.White).onClick(this.onMigrate)
        this.secondaryButton(() => this.importing ? this.label('正在导入…', 'Importing…') :
          this.label('上传 ZIP 导出包', 'Upload ZIP Archive'), this.onImport)
        this.secondaryButton(() => this.label('以后再说', 'Maybe Later'), this.onDismiss)
      }
      .width('100%')
    }
    .width('92%').constraintSize({ maxWidth: 400 }).padding(this.compact ? 12 : 18).borderRadius(24)
    .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .shadow({ radius: 22, color: '#26000000', offsetY: 9 })
  }
}
