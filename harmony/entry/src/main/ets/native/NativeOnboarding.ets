import { NativeApiProtocol } from './NativeSettings';
import { NativeApiCredential, verifyNativeApiCredential } from './NativeApiCredential';

export type NativeOnboardingView = 'home' | 'deepseek-key' | 'third-party';
const DEEPSEEK_BASE = 'https://api.deepseek.com';

@Component
export struct NativeOnboarding {
  @Prop compact: boolean = false;
  @Prop busy: boolean = false;
  @Prop initialUrl: string = DEEPSEEK_BASE;
  @Prop initialModel: string = 'deepseek-chat';
  @Prop initialProtocol: NativeApiProtocol = 'openai';
  @Link view: NativeOnboardingView;
  @State private baseUrl: string = '';
  @State private model: string = '';
  @State private apiKey: string = '';
  @State private protocol: NativeApiProtocol = 'openai';
  @State private verifying: boolean = false;
  @State private failure: string = '';
  onAccount: () => void = () => {};
  onConnect: (credential: NativeApiCredential) => Promise<void> = async () => {};
  onHelp: () => void = () => {};
  onPlatformKeys: () => void = () => {};

  aboutToAppear(): void {
    this.baseUrl = this.initialUrl;
    this.model = this.initialModel;
    this.protocol = this.initialProtocol;
  }

  private switchView(view: NativeOnboardingView): void {
    if (this.verifying) {
      return;
    }
    this.failure = '';
    this.apiKey = '';
    this.view = view;
  }

  private async connect(): Promise<void> {
    if (this.verifying || !this.apiKey.trim()) {
      return;
    }
    const credential: NativeApiCredential = this.view === 'deepseek-key' ? {
      baseUrl: DEEPSEEK_BASE, model: 'deepseek-flash', protocol: 'anthropic', apiKey: this.apiKey.trim(),
    } : {
      baseUrl: this.baseUrl.trim(), model: this.model.trim(), protocol: this.protocol, apiKey: this.apiKey.trim(),
    };
    this.verifying = true;
    this.failure = '';
    try {
      await verifyNativeApiCredential(credential);
      await this.onConnect(credential);
      this.apiKey = '';
    } catch (error) {
      this.failure = (error as Error).message || '校验失败，请重试';
    } finally {
      this.verifying = false;
    }
  }

  @Builder
  private action(label: string, primary: boolean, enabled: boolean, click: () => void) {
    Button(label, { type: ButtonType.Capsule })
      .width('100%').height(this.compact ? 37 : 50).fontSize(this.compact ? 13 : 15).fontWeight(FontWeight.Medium)
      .fontColor(primary ? Color.White : $r('app.color.native_chat_primary'))
      .backgroundColor(primary ? $r('app.color.native_chat_blue') : $r('app.color.native_chat_bg'))
      .border({ width: 1, color: primary ? $r('app.color.native_chat_blue') : $r('app.color.native_chat_stroke') })
      .enabled(enabled).onClick(click)
  }

  @Builder
  private field(label: string, value: string, hint: string, input: InputType, change: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label).fontSize(12).fontColor($r('app.color.native_chat_secondary')).padding({ left: 6 })
      TextInput({ text: value, placeholder: hint })
        .width('100%').height(this.compact ? 34 : 46).type(input).fontSize(14).borderRadius(999)
        .border({ width: 1, color: $r('app.color.native_chat_stroke') })
        .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
        .placeholderColor($r('app.color.native_chat_caption')).padding({ left: 16, right: 16 })
        .enabled(!this.verifying).onChange(change)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private form() {
    Column({ space: this.compact ? 7 : 10 }) {
      if (this.view === 'third-party') {
        Row() {
          Text('接口协议').fontSize(12).fontColor($r('app.color.native_chat_secondary')).layoutWeight(1)
          Select([{ value: 'OpenAI 兼容' }, { value: 'Anthropic 兼容' }])
            .selected(this.protocol === 'anthropic' ? 1 : 0)
            .value(this.protocol === 'anthropic' ? 'Anthropic 兼容' : 'OpenAI 兼容')
            .onSelect((index: number) => { this.protocol = index === 1 ? 'anthropic' : 'openai'; })
        }
        .width('100%').padding({ left: 6 })
        this.field('API 地址 (Base URL)', this.baseUrl, '例如 https://api.deepseek.com', InputType.Normal,
          (value: string) => { this.baseUrl = value; })
        this.field('模型名称', this.model, '例如 deepseek-chat、gpt-4o', InputType.Normal,
          (value: string) => { this.model = value; })
      }
      this.field('API Key', this.apiKey, '请输入 API Key', InputType.Password, (value: string) => { this.apiKey = value; })
      if (this.failure) {
        Text(this.failure).fontSize(12).fontColor($r('app.color.native_chat_error')).textAlign(TextAlign.Center)
      }
      this.action(this.verifying ? '正在验证...' : '验证并继续', true,
        !this.verifying && !!this.apiKey.trim(), () => { void this.connect(); })
      if (this.view === 'deepseek-key') {
        Button('前往开放平台获取 API Key', { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(12).fontColor($r('app.color.native_chat_blue_text')).onClick(this.onPlatformKeys)
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        if (this.view !== 'home') {
          Button('← 返回', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(14)
            .fontColor($r('app.color.native_chat_secondary')).onClick(() => { this.switchView('home'); })
        }
        Blank().layoutWeight(1)
        Button('帮助', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(14)
          .fontColor($r('app.color.native_chat_secondary')).onClick(this.onHelp)
      }
      .width('100%').height(this.compact ? 28 : 36)
      Scroll() {
        Column() {
          Column({ space: this.compact ? 8 : 14 }) {
            Image($r('app.media.native_welcome_logo')).width(this.compact ? 44 : 76).height(this.compact ? 44 : 76)
              .borderRadius(this.compact ? 12 : 20).shadow({ radius: 24, color: '#14000000', offsetY: 8 })
              .draggable(false).accessibilityText('Nuwa')
            Text('Nuwa').fontSize(this.compact ? 22 : 28).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.native_chat_primary')).lineHeight(this.compact ? 28 : 34)
          }
          .width('100%').layoutWeight(1).constraintSize({ minHeight: this.compact ? 84 : 160 })
          .justifyContent(FlexAlign.Center).padding({ top: 12, bottom: 12 })
          Column({ space: this.compact ? 8 : 12 }) {
            if (this.view === 'home') {
              this.action('DeepSeek API 账号登录', true, !this.busy, this.onAccount)
              this.action('使用 DeepSeek API Key', false, !this.busy, () => { this.switchView('deepseek-key'); })
              this.action('配置第三方兼容 API', false, !this.busy, () => { this.switchView('third-party'); })
            } else {
              this.form()
            }
            Text('凭据与历史对话仅保存在本地设备').fontSize(12).lineHeight(18).textAlign(TextAlign.Center)
              .fontColor($r('app.color.native_chat_secondary')).padding({ top: 8 })
          }
          .width('100%').constraintSize({ maxWidth: 344 })
        }
        .width('100%').height('100%')
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }
    .width('100%').height('100%').padding({ top: 16, left: this.compact ? 12 : 24, right: this.compact ? 12 : 24, bottom: 24 })
    .backgroundColor($r('app.color.native_chat_bg'))
  }
}
