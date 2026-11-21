import { LengthMetrics } from '@kit.ArkUI';
import { NativeApiProtocol } from './NativeSettings';
import { allowsKeylessNativeApi, NativeApiCredential, verifyNativeApiCredential } from './NativeApiCredential';
import { NATIVE_CARD_CLICK_EFFECT, triggerNativeHaptic } from './NativeImmersiveUI';
import { NativeLocale } from './NativeLocation';

export type NativeOnboardingView = 'home' | 'deepseek-key' | 'third-party';
const DEEPSEEK_BASE = 'https://api.deepseek.com';

export function nativeCredentialError(error: Error, locale: NativeLocale): string {
  const english = locale === 'en-US';
  const message = error.message ?? '';
  switch (message) {
    case 'API Key 无效，请检查后重试':
      return english ? 'Invalid API Key. Please check it and try again.' : message;
    case '网络异常，请检查你的网络状况':
      return english ? 'Network Error. Please check your network status.' : message;
    case '请输入有效的 API 地址':
      return english ? 'Verification failed: Enter a valid API Base URL.' : '校验失败：' + message;
    case '请输入不含账号、密码或片段的 HTTP 或 HTTPS 地址':
      return english ? 'Verification failed: Enter an HTTP or HTTPS address without credentials or a fragment.' : '校验失败：' + message;
    case '请输入 API Key；仅局域网 OpenAI 兼容地址可留空':
      return english ? 'Verification failed: Enter an API Key or use a local OpenAI-compatible endpoint.' : '校验失败：' + message;
    case '使用 API Key 时，地址必须为 HTTPS':
      return english ? 'Verification failed: An API Key requires an HTTPS address.' : '校验失败：' + message;
    case 'API Key 中不能包含换行':
      return english ? 'Verification failed: The API Key cannot contain line breaks.' : '校验失败：' + message;
    case '请输入模型名称':
      return english ? 'Verification failed: Enter a model name.' : '校验失败：' + message;
    default:
      return english ? 'Verification failed' + (message ? ': ' + message.replace(/^校验失败：/, '') : '.') :
        message.startsWith('校验失败：') ? message : '校验失败' + (message ? '：' + message : '，请重试');
  }
}

@Component
export struct NativeOnboarding {
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop compact: boolean = false;
  @Prop fontScale: number = 1;
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

  private text(chinese: string, english: string): string {
    return this.locale === 'zh-CN' ? chinese : english;
  }

  private fontSize(size: number, compactSize: number = size): number {
    // Match the web root's 13px compact base, then apply the selected chat scale.
    return (this.compact ? compactSize * 13 / 16 : size) * this.fontScale;
  }

  private keylessApiAllowed(): boolean {
    return this.view === 'third-party' && allowsKeylessNativeApi(this.baseUrl, this.protocol);
  }

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
    const canUseWithoutKey = this.view === 'third-party' &&
      allowsKeylessNativeApi(this.baseUrl.trim(), this.protocol) && !!this.model.trim();
    if (this.verifying || (!this.apiKey.trim() && !canUseWithoutKey)) {
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
      this.failure = nativeCredentialError(error as Error, this.locale);
    } finally {
      this.verifying = false;
    }
  }

  @Builder
  private action(label: () => string, primary: boolean, enabled: () => boolean, click: () => void) {
    Button(label(), { type: ButtonType.Capsule })
      .width('100%').height(this.compact ? 36 : 50).fontSize(this.fontSize(15, 13)).fontWeight(FontWeight.Medium)
      .fontColor(primary ? Color.White : $r('app.color.native_chat_primary'))
      .backgroundColor(primary ? $r('app.color.native_chat_blue') : $r('app.color.native_chat_bg'))
      .border({ width: 1, color: primary ? $r('app.color.native_chat_blue') : $r('app.color.native_chat_stroke') })
      .clickEffect(NATIVE_CARD_CLICK_EFFECT).hoverEffect(HoverEffect.Highlight)
      .enabled(enabled()).onClick(() => {
        triggerNativeHaptic('light');
        click();
      })
  }

  @Builder
  private field(label: () => string, value: () => string, hint: () => string, input: InputType,
    change: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label()).fontSize(this.fontSize(12)).lineHeight(16)
        .fontColor($r('app.color.native_chat_secondary')).padding({ left: 6 })
      TextInput({ text: value(), placeholder: hint() })
        .width('100%').height(this.compact ? 36 : 46).type(input).fontSize(this.fontSize(14)).borderRadius(999)
        .border({ width: 1, color: $r('app.color.native_chat_stroke') })
        .backgroundColor($r('app.color.native_chat_sidebar')).fontColor($r('app.color.native_chat_primary'))
        .placeholderColor($r('app.color.native_chat_caption'))
        .padding({ left: this.compact ? 12 : 16, right: this.compact ? 12 : 16 })
        .showPasswordIcon(false).enabled(!this.verifying).onChange(change)
        .enterKeyType(EnterKeyType.Done)
        .onSubmit(() => { if (input === InputType.Password) void this.connect(); })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private form() {
    Column({ space: this.compact ? 8 : 10 }) {
      if (this.view === 'third-party') {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(6) } }) {
          Text(this.text('接口协议', 'API Protocol')).fontSize(this.fontSize(12))
            .fontColor($r('app.color.native_chat_secondary'))
          Select([{ value: this.text('OpenAI 兼容', 'OpenAI Compatible') },
            { value: this.text('Anthropic 兼容', 'Anthropic Compatible') }])
            .font({ size: this.fontSize(14) })
            .optionFont({ size: this.fontSize(14) })
            .selectedOptionFont({ size: this.fontSize(14) })
            .selected(this.protocol === 'anthropic' ? 1 : 0)
            .value(this.protocol === 'anthropic' ? this.text('Anthropic 兼容', 'Anthropic Compatible') :
              this.text('OpenAI 兼容', 'OpenAI Compatible'))
            .onSelect((index: number) => { this.protocol = index === 1 ? 'anthropic' : 'openai'; })
        }
        .width('100%').padding({ left: 6 })
        this.field(() => this.text('API 地址 (Base URL)', 'API Base URL'), () => this.baseUrl,
          () => this.text('例如 https://api.deepseek.com 或 https://api.openai.com/v1',
            'e.g. https://api.deepseek.com or https://api.openai.com/v1'), InputType.URL,
          (value: string) => { this.baseUrl = value; })
        this.field(() => this.text('模型名称', 'Model Name'), () => this.model,
          () => this.text('例如 deepseek-chat、deepseek-reasoner、gpt-4o',
            'e.g. deepseek-chat, deepseek-reasoner, gpt-4o'), InputType.Normal,
          (value: string) => { this.model = value; })
      }
      this.field(() => this.keylessApiAllowed() ? this.text('API Key（可选）', 'API Key (optional)') : 'API Key',
        () => this.apiKey,
        () => this.keylessApiAllowed()
          ? this.text('局域网地址可不填 API Key', 'Optional for local network endpoints')
          : this.text('请输入 API Key', 'Enter API Key'),
        InputType.Password,
        (value: string) => { this.apiKey = value; })
      if (this.failure) {
        Text(this.failure).fontSize(this.fontSize(12)).fontColor($r('app.color.native_chat_error')).textAlign(TextAlign.Center)
      }
      this.action(() => this.verifying ? this.text('正在验证...', 'Verifying...') : this.text('验证并继续', 'Verify & Continue'), true,
        () => !this.verifying && (!!this.apiKey.trim() ||
          (this.keylessApiAllowed() && !!this.baseUrl.trim() && !!this.model.trim())), () => { void this.connect(); })
      if (this.view === 'deepseek-key') {
        Button(this.text('前往开放平台获取 API Key', 'Get API Key from DeepSeek Platform'),
          { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(this.fontSize(12)).fontColor($r('app.color.native_chat_blue_text')).onClick(this.onPlatformKeys)
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        if (this.view !== 'home') {
          Button(this.text('← 返回', '← Back'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .height(this.compact ? 24 : 36).fontSize(this.fontSize(14, 12))
            .padding({ left: this.compact ? 4 : 8, right: this.compact ? 4 : 8 })
            .fontColor($r('app.color.native_chat_action')).onClick(() => { this.switchView('home'); })
        }
        Blank().layoutWeight(1)
        Button(this.text('帮助', 'Help'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(this.compact ? 24 : 36).fontSize(this.fontSize(14, 12))
          .padding({ left: this.compact ? 4 : 8, right: this.compact ? 4 : 8 })
          .fontColor($r('app.color.native_chat_action')).onClick(this.onHelp)
      }
      .width('100%').height(this.compact ? 24 : 36)
      Scroll() {
        Column() {
          Column({ space: this.compact ? 6 : 14 }) {
            Image($r('app.media.native_welcome_logo')).width(this.compact ? 44 : 76).height(this.compact ? 44 : 76)
              .borderRadius(this.compact ? 12 : 20).shadow({ radius: 24, color: '#14000000', offsetY: 8 })
              .draggable(false).accessibilityText('Nuwa')
            Text('Nuwa').fontSize(this.fontSize(28, 18)).fontWeight(FontWeight.Bold).letterSpacing(0.4)
              .fontColor($r('app.color.native_chat_primary')).lineHeight(this.compact ? 22 : 34)
          }
          .width('100%').layoutWeight(this.compact ? 0 : 1).constraintSize({ minHeight: this.compact ? 90 : 160 })
          .justifyContent(FlexAlign.Center).padding({ top: this.compact ? 6 : 12, bottom: 12 })
          Column({ space: this.compact ? 8 : 12 }) {
            if (this.view === 'home') {
              this.action(() => this.text('DeepSeek API 账号登录', 'Sign in with DeepSeek API'), true, () => !this.busy, this.onAccount)
              this.action(() => this.text('使用 DeepSeek API Key', 'Use DeepSeek API Key'), false, () => !this.busy,
                () => { this.switchView('deepseek-key'); })
              this.action(() => this.text('配置第三方兼容 API', 'Configure 3rd-Party API'), false, () => !this.busy,
                () => { this.switchView('third-party'); })
            } else {
              this.form()
            }
            Text(this.text('凭据与历史对话仅保存在本地设备',
              'Credentials and chat history are stored locally on your device'))
              .width('100%').fontSize(this.fontSize(12, 11)).lineHeight(this.compact ? 14 : 18).textAlign(TextAlign.Center)
              .fontColor($r('app.color.native_chat_action')).padding({ top: this.compact ? 0 : 8 })
          }
          .width('100%').constraintSize({ maxWidth: 344 })
        }
        .width('100%').height(this.compact ? undefined : '100%')
      }
      .layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').padding({ top: this.compact ? 8 : 16,
      left: this.compact ? 12 : 24, right: this.compact ? 12 : 24, bottom: this.compact ? 16 : 24 })
    .backgroundColor($r('app.color.native_chat_bg'))
  }
}
