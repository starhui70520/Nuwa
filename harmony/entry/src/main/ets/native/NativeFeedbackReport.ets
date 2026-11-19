import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  collectNativeFeedbackDevice, getNativeFeedbackLogs, NATIVE_FEEDBACK_ISSUES, NativeFeedbackDevice,
  NativeFeedbackIssue, NativeFeedbackLog, submitNativeFeedback,
} from './NativeFeedbackService';
import { NativeLocale } from './NativeLocation';
import { NativeApiProtocol, NativeAuthMode } from './NativeSettings';

interface NativeDiagnosticsPreview {
  deviceInfo: NativeFeedbackDevice;
  recentLogs: NativeFeedbackLog[];
}

@Component
export struct NativeFeedbackReport {
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop appVersion: string = '';
  @Prop apiProtocol: NativeApiProtocol = 'openai';
  @Prop authMode: NativeAuthMode = 'api-key';
  @Prop viewportWidth: number = 0;
  @Prop viewportHeight: number = 0;
  @State private issue: string = NATIVE_FEEDBACK_ISSUES[0].zh;
  @State private description: string = '';
  @State private contact: string = '';
  @State private includeLogs: boolean = true;
  @State private showPreview: boolean = false;
  @State private logs: NativeFeedbackLog[] = [];
  @State private submitting: boolean = false;
  @State private submitError: string = '';
  @State private reportCode: string = '';
  @State private copied: boolean = false;
  private copyTimer: number = -1;

  aboutToAppear(): void {
    void this.refreshLogs();
  }

  aboutToDisappear(): void {
    if (this.copyTimer >= 0) clearTimeout(this.copyTimer);
  }

  private host(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private label(chinese: string, english: string): string {
    return this.locale === 'en-US' ? english : chinese;
  }

  private device(): NativeFeedbackDevice {
    return collectNativeFeedbackDevice({
      appVersion: this.appVersion, locale: this.locale, apiProtocol: this.apiProtocol, authMode: this.authMode,
      viewportWidth: this.viewportWidth, viewportHeight: this.viewportHeight,
    });
  }

  private async refreshLogs(): Promise<void> {
    this.logs = await getNativeFeedbackLogs(this.host());
  }

  private preview(): string {
    const preview: NativeDiagnosticsPreview = {
      deviceInfo: this.device(),
      recentLogs: this.includeLogs ? this.logs.slice(-8) : [],
    };
    return JSON.stringify(preview, undefined, 2);
  }

  private async submit(): Promise<void> {
    if (this.submitting) return;
    const description = this.description.trim();
    if (!description) {
      this.submitError = this.label('请简要描述您遇到的问题', 'Briefly describe the issue you encountered.');
      return;
    }
    this.submitting = true;
    this.submitError = '';
    try {
      const logs = this.includeLogs ? await getNativeFeedbackLogs(this.host()) : [];
      this.reportCode = await submitNativeFeedback(this.issue, description, this.contact, this.device(), logs, this.locale);
      this.copied = false;
    } catch (error) {
      this.submitError = (error as Error).message || this.label('日志上报失败，请重试', 'Report failed. Please try again.');
    } finally {
      this.submitting = false;
    }
  }

  private async copyReportCode(): Promise<void> {
    if (!this.reportCode) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.reportCode);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copied = true;
      if (this.copyTimer >= 0) clearTimeout(this.copyTimer);
      this.copyTimer = setTimeout(() => {
        this.copied = false;
        this.copyTimer = -1;
      }, 2000);
    } catch {
      this.copied = false;
    }
  }

  @Builder
  private fieldLabel(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary')).width('100%')
  }

  @Builder
  private reportForm() {
    this.fieldLabel(this.label('遇到的问题', 'Type of issue'))
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
      ForEach(NATIVE_FEEDBACK_ISSUES, (option: NativeFeedbackIssue) => {
        Button(this.label(option.zh, option.en), { type: ButtonType.Capsule })
          .height(32).fontSize(12).padding({ left: 12, right: 12 })
          .fontColor(this.issue === option.zh ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
          .fontWeight(this.issue === option.zh ? FontWeight.Medium : FontWeight.Regular)
          .backgroundColor(this.issue === option.zh ? $r('app.color.native_chat_selected') : Color.Transparent)
          .border({ width: 1, color: this.issue === option.zh ?
            $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_stroke') })
          .enabled(!this.submitting)
          .onClick(() => { this.issue = option.zh; })
      }, (option: NativeFeedbackIssue): string => option.zh)
    }
    .width('100%')
    this.fieldLabel(this.label('问题描述 *', 'Issue description *'))
    TextArea({ text: this.description, placeholder: this.label(
      '请描述遇到的问题、出现前进行了什么操作，方便我们复现与定位…',
      'Describe the issue and the steps leading up to it…') })
      .width('100%').height(108).fontSize(13).lineHeight(20).maxLength(4000).borderRadius(12)
      .fontColor($r('app.color.native_chat_primary')).backgroundColor($r('app.color.native_chat_field'))
      .placeholderColor($r('app.color.native_chat_secondary')).enabled(!this.submitting)
      .onChange((value: string) => {
        this.description = value;
        this.submitError = '';
      })
    this.fieldLabel(this.label('联系方式（选填）', 'Contact details (optional)'))
    TextInput({ text: this.contact, placeholder: this.label(
      '微信号 / 邮箱，方便修复后通知您', 'WeChat ID or email for follow-up') })
      .width('100%').height(42).fontSize(13).maxLength(120).borderRadius(10)
      .fontColor($r('app.color.native_chat_primary')).backgroundColor($r('app.color.native_chat_field'))
      .placeholderColor($r('app.color.native_chat_secondary')).enabled(!this.submitting)
      .onChange((value: string) => { this.contact = value; })
    Row({ space: 6 }) {
      Checkbox({ name: 'feedback-logs' }).select(this.includeLogs).selectedColor($r('app.color.native_chat_blue'))
        .width(32).height(32)
        .accessibilityText(this.label('附带最近的错误日志', 'Include recent error logs')).enabled(!this.submitting)
        .onChange((selected: boolean) => { this.includeLogs = selected; })
      Text(this.label(`附带最近 ${this.logs.length} 条脱敏错误日志（不含 API Key）`,
        `Include ${this.logs.length} recent redacted error logs (API keys excluded)`))
        .layoutWeight(1).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
        .onClick(() => { if (!this.submitting) this.includeLogs = !this.includeLogs; })
    }
    .width('100%')
    Row({ space: 8 }) {
      Text(this.label('上报包含设备信息', 'Reports include device information'))
        .layoutWeight(1).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
      Button(this.showPreview ? this.label('收起预览', 'Hide preview') : this.label('预览附带信息', 'Preview diagnostics'),
        { buttonStyle: ButtonStyleMode.TEXTUAL })
        .fontSize(12).fontColor($r('app.color.native_chat_blue_text'))
        .onClick(() => {
          this.showPreview = !this.showPreview;
          if (this.showPreview) void this.refreshLogs();
        })
    }
    .width('100%')
    if (this.showPreview) {
      Scroll() {
        Text(this.preview()).width('100%').fontSize(11).lineHeight(16).fontFamily('monospace')
          .fontColor($r('app.color.native_chat_primary')).copyOption(CopyOptions.LocalDevice).padding(12)
      }
      .width('100%').height(160).borderRadius(10).backgroundColor($r('app.color.native_chat_field'))
    }
    if (this.submitError) {
      Text(this.submitError).width('100%').fontSize(12).fontColor($r('app.color.native_chat_error'))
    }
    Button(this.submitting ? this.label('正在提交…', 'Submitting…') : this.label('提交日志上报', 'Submit report'))
      .width('100%').backgroundColor($r('app.color.native_chat_blue')).enabled(!this.submitting)
      .onClick(() => { void this.submit(); })
  }

  @Builder
  private reportResult() {
    Text(this.label('日志上报成功', 'Report submitted')).fontSize(16).fontWeight(FontWeight.Medium)
      .width('100%').textAlign(TextAlign.Center).fontColor($r('app.color.native_chat_primary'))
    Text(this.label('请将下方记录码发给开发者，我们会根据记录码快速定位您遇到的问题。',
      'Send this report code to the developer so they can investigate the issue.'))
      .width('100%').textAlign(TextAlign.Center).fontSize(13).lineHeight(20).fontColor($r('app.color.native_chat_secondary'))
    Text(this.reportCode).width('100%').textAlign(TextAlign.Center).fontFamily('monospace').fontSize(22)
      .fontWeight(FontWeight.Bold).fontColor($r('app.color.native_chat_primary')).copyOption(CopyOptions.LocalDevice)
      .padding({ top: 14, bottom: 14, left: 16, right: 16 }).borderRadius(12)
      .backgroundColor($r('app.color.native_chat_field'))
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center,
      space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
      Button(this.copied ? this.label('已复制记录码', 'Code copied') : this.label('复制记录码', 'Copy report code'))
        .backgroundColor($r('app.color.native_chat_blue')).onClick(() => { void this.copyReportCode(); })
      Button(this.label('继续提交新反馈', 'Submit another report'), { buttonStyle: ButtonStyleMode.TEXTUAL })
        .fontColor($r('app.color.native_chat_blue_text')).onClick(() => {
          this.reportCode = '';
          this.description = '';
          this.submitError = '';
          void this.refreshLogs();
        })
    }
    .width('100%')
  }

  build() {
    Column({ space: 12 }) {
      if (this.reportCode) {
        this.reportResult()
      } else {
        this.reportForm()
      }
    }
    .alignItems(HorizontalAlign.Start).width('100%').padding(16).borderRadius(16)
    .backgroundColor($r('app.color.native_chat_surface'))
  }
}
