/** Native equivalent of the tagged Android data-management settings page. */
import { NativeLocale } from './NativeLocation';
import { NativeMigrationIntent } from './NativeMigrationStrategy';

@Component
export struct NativeDataSettings {
  @Prop fontScale: number = 1;
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop busy: boolean = false;
  @Prop sessionCount: number = 0;
  @Prop historyImportProgress: string = '';
  @Prop historyImportResult: string = '';
  @Prop historyImportFailed: boolean = false;

  onImport: () => void = () => {};
  onExport: () => void = () => {};
  onDeleteAll: () => void = () => {};
  onShareImport: () => void = () => {};
  onMigration: () => void = () => {};

  private text(chinese: string, english: string): string {
    return this.locale === 'zh-CN' ? chinese : english;
  }

  @Builder
  private actionButton(label: () => string, variant: string, enabled: () => boolean, action: () => void) {
    Button(label(), { type: ButtonType.Capsule })
      .height(36)
      .padding({ left: 14, right: 14 })
      .fontSize(14 * this.fontScale)
      .fontWeight(FontWeight.Medium)
      .fontColor(variant === 'primary' ? Color.White :
        (variant === 'danger' ? $r('app.color.native_chat_error') : $r('app.color.native_chat_primary')))
      .backgroundColor(variant === 'primary' ? $r('app.color.native_chat_blue') :
        (variant === 'danger' ? Color.Transparent : $r('app.color.native_chat_bg')))
      .border({ width: variant === 'primary' ? 0 : 1,
        color: variant === 'primary' ? $r('app.color.native_chat_blue') :
          (variant === 'danger' ? $r('app.color.native_chat_error') : $r('app.color.native_chat_stroke')) })
      .enabled(enabled())
      .opacity(enabled() ? 1 : 0.45)
      .onClick(action)
  }

  @Builder
  private settingRow(label: () => string, description: () => string, buttonLabel: () => string,
    variant: string, enabled: () => boolean, action: () => void, error: () => boolean = () => false) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(label())
          .fontSize(14 * this.fontScale)
          .lineHeight(22 * this.fontScale)
          .fontColor($r('app.color.native_chat_primary'))
        if (description()) {
          Text(description())
            .fontSize(12 * this.fontScale)
            .lineHeight(18 * this.fontScale)
            .fontColor(error() ? $r('app.color.native_chat_error') : $r('app.color.native_chat_secondary'))
            .maxLines(error() ? 8 : 3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
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
          () => this.text('一键迁移 DeepSeek 历史', 'One-Click DeepSeek Migration'),
          () => this.text('登录官方网页端自动触发导出并合并到本机',
            'Sign in to DeepSeek web to export and merge chats locally.'),
          () => this.busy ? this.text('处理中…', 'Working…') : this.text('一键导入', 'Import'),
          'primary',
          () => !this.busy,
          this.onMigration,
        )
        this.settingRow(
          () => this.text('通过链接导入', 'Import from link'),
          () => this.text('粘贴 DeepSeek 分享链接或官方数据导出 ZIP 下载链接，直接导入对话',
            'Paste a DeepSeek share link or official export ZIP download link to import chats directly.'),
          () => this.text('导入链接', 'Import link'),
          'outlined',
          () => !this.busy,
          this.onShareImport,
        )
        this.settingRow(
          () => this.text('导入历史对话', 'Import chat history'),
          () => this.historyImportProgress || this.historyImportResult ||
            this.text('按会话 ID 增量合并导入，保留已有本地对话与附件，支持 DeepSeek 导出的 ZIP 文件。',
            'Merge chats by session ID while keeping existing local chats and attachments. Supports DeepSeek ZIP exports.'),
          () => this.historyImportProgress ? this.text('导入中…', 'Importing…') : this.text('↑ 上传', '↑ Upload'),
          'outlined',
          () => !this.busy,
          this.onImport,
          () => this.historyImportFailed && !this.historyImportProgress,
        )
        this.settingRow(
          () => this.text('导出所有历史对话', 'Export all chat history'),
          () => this.text('包含所有历史对话及本地图片原件；其他附件仅保留文件信息，不包含 API Key。',
            'Includes all chats and locally stored images. Other attachments keep file details only. API keys are excluded.'),
          () => this.busy ? this.text('处理中…', 'Working…') : this.text('↓ 下载', '↓ Export'),
          'outlined',
          () => !this.busy && this.sessionCount > 0,
          this.onExport,
        )
      }
      .width('100%')
      .borderRadius(16)
      .clip(true)
      .backgroundColor($r('app.color.native_chat_surface'))

      Column({ space: 0 }) {
        this.settingRow(
          () => this.text('删除所有对话', 'Delete all chats'),
          () => '',
          () => this.text('删除', 'Delete'),
          'danger',
          () => !this.busy,
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

export interface NativeMigrationChoiceModel {
  locale: NativeLocale;
  fontScale: number;
  compact: boolean;
  width: number;
  maxHeight: number;
}

@CustomDialog
export struct NativeMigrationChoices {
  controller?: CustomDialogController;
  @Link model: NativeMigrationChoiceModel | null;
  onChoose: (intent: NativeMigrationIntent) => void = (_intent: NativeMigrationIntent) => {};

  private label(chinese: string, english: string): string {
    return this.model?.locale === 'en-US' ? english : chinese;
  }

  private scaled(size: number): number {
    return size * (this.model?.fontScale ?? 1);
  }

  @Builder
  private choice(title: string, primary: boolean, intent: NativeMigrationIntent) {
    Button({ type: ButtonType.Capsule }) {
      Text(title)
        .fontSize(this.scaled(14))
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .fontColor(primary ? Color.White : $r('app.color.native_chat_primary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 40 })
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(primary ? $r('app.color.native_chat_blue') : Color.Transparent)
    .border({ width: primary ? 0 : 1, color: $r('app.color.native_chat_stroke') })
    .onClick(() => { this.onChoose(intent); })
  }

  build() {
    if (this.model) {
      Scroll() {
        Column({ space: this.model.compact ? 8 : 12 }) {
          Text(this.label('选择导入方式', 'Choose Import Mode')).width('100%')
            .fontSize(this.scaled(this.model.compact ? 14 : 16))
            .lineHeight(this.scaled(this.model.compact ? 20 : 24))
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
          Text(this.label(
            '如果当前账号在 DeepSeek 又有新对话，请选择「重新导出并更新」；如需导入其他账号记录，请选择「切换其他账号」。',
            'Choose "Re-export & Update" if you have new chats in DeepSeek on this account, or switch to another DeepSeek account.'))
            .width('100%')
            .fontSize(this.scaled(this.model.compact ? 13 : 14))
            .lineHeight(this.scaled(this.model.compact ? 18 : 22))
            .fontColor($r('app.color.native_chat_secondary'))
          Column({ space: 8 }) {
            this.choice(this.label('重新导出并更新（当前账号）', 'Re-export & Update (Current Account)'), true,
              { clearSession: false, forceReExport: true })
            this.choice(this.label('直接下载上次导出（当前账号）', 'Download Previous Export (Current Account)'), false,
              { clearSession: false, forceReExport: false })
            this.choice(this.label('切换其他账号', 'Switch Account'), false,
              { clearSession: true, forceReExport: false })
          }
          .width('100%')
        }
        .width('100%')
        .padding({
          left: this.model.compact ? 14 : 24, right: this.model.compact ? 14 : 24,
          top: this.model.compact ? 12 : 22, bottom: this.model.compact ? 12 : 22,
        })
      }
      .width(this.model.width).constraintSize({ maxHeight: this.model.maxHeight })
      .scrollBar(BarState.Auto).borderRadius(this.model.compact ? 16 : 24)
      .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .shadow({ radius: 22, color: '#26000000', offsetY: 9 })
    }
  }
}
