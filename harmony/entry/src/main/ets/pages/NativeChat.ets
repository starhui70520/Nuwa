import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { NativeChatClient, NativeChatConfig, NativeChatMessage } from '../native/NativeChatClient';
import { NativeChatStorage, NativeStoredMessage } from '../native/NativeChatStorage';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';

@Entry
@Component
struct NativeChat {
  @State private messages: NativeStoredMessage[] = [];
  @State private draft: string = '';
  @State private baseUrl: string = 'https://api.deepseek.com';
  @State private model: string = 'deepseek-flash';
  @State private apiKey: string = '';
  @State private loaded: boolean = false;
  @State private sending: boolean = false;
  @State private reply: string = '';
  @State private reasoning: string = '';
  @State private status: string = '';
  @State private settingsVisible: boolean = false;
  @State private recognizing: boolean = false;
  @State private reading: boolean = false;

  private readonly client: NativeChatClient = new NativeChatClient();
  private readonly storage: NativeChatStorage = new NativeChatStorage();
  private readonly scroller: Scroller = new Scroller();
  private recognitionId: string = '';
  private visible: boolean = false;
  private scrollTimer: number = -1;
  private readonly recognition: HarmonySpeechRecognition = new HarmonySpeechRecognition(
    (id: string, state: string, text?: string, code?: string): void => {
      if (id !== this.recognitionId) {
        return;
      }
      if (state === 'done' || state === 'error') {
        this.recognitionId = '';
        this.recognizing = false;
      }
      if (state === 'done' && text) {
        this.draft = this.draft ? `${this.draft} ${text}` : text;
      }
      if (state === 'error') {
        this.status = code === 'permission-denied' ? '请允许 Nuwa 使用麦克风。' : '系统语音识别暂不可用。';
      }
    }
  );
  private readonly speaker: HarmonyTextToSpeech = new HarmonyTextToSpeech((_: string, state: string): void => {
    this.reading = state === 'playing';
    if (state === 'error' || state === 'unavailable') {
      this.status = '系统朗读暂不可用。';
    }
  });

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    void this.loadHistory();
  }

  onPageShow(): void {
    this.visible = true;
  }

  onPageHide(): void {
    this.visible = false;
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  private stopActivity(): void {
    this.client.cancel();
    this.recognitionId = '';
    this.recognizing = false;
    this.recognition.cancel();
    this.stopReading();
  }

  aboutToDisappear(): void {
    this.onPageHide();
    this.stopActivity();
    this.speaker.destroy();
  }

  private host(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async loadHistory(): Promise<void> {
    this.status = '';
    try {
      this.messages = await this.storage.load(this.host());
      this.loaded = true;
      this.scrollToLatest();
    } catch {
      this.status = '无法读取本地会话。';
    }
  }

  private scrollToLatest(): void {
    if (this.scrollTimer >= 0) {
      return;
    }
    this.scrollTimer = setTimeout((): void => {
      this.scrollTimer = -1;
      if (this.visible) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 0);
  }

  private async saveHistory(context: common.UIAbilityContext): Promise<void> {
    try {
      await this.storage.save(context, this.messages);
    } catch {
      this.status = '本地会话保存失败，请检查设备存储空间。';
    }
  }

  private async sendMessage(): Promise<void> {
    const content = this.draft.trim();
    if (!this.loaded || this.sending || !content) {
      return;
    }
    const config: NativeChatConfig = {
      baseUrl: this.baseUrl.trim(),
      model: this.model.trim(),
      apiKey: this.apiKey.trim(),
    };
    if (!config.baseUrl || !config.model) {
      this.settingsVisible = true;
      this.status = '请填写 API 地址和模型。';
      return;
    }
    this.status = '';
    const context = this.host();
    this.sending = true;
    this.draft = '';
    this.messages = [...this.messages, { role: 'user', content: content, reasoning: '' }];
    this.scrollToLatest();
    void this.saveHistory(context);

    try {
      const input = this.messages.filter((message: NativeStoredMessage): boolean => !!message.content)
        .map<NativeChatMessage>((message: NativeStoredMessage): NativeChatMessage => ({
          role: message.role,
          content: message.content,
        }));
      await this.client.send(config, input, (delta: string, reasoning: string): void => {
        if (this.visible && this.scroller.isAtEnd()) {
          this.scrollToLatest();
        }
        this.reply += delta;
        this.reasoning += reasoning;
      });
    } catch (error) {
      this.status = (error as Error).message || '请求失败。';
    } finally {
      if (this.reply || this.reasoning) {
        this.messages = [...this.messages, { role: 'assistant', content: this.reply, reasoning: this.reasoning }];
        void this.saveHistory(context);
      }
      this.reply = '';
      this.reasoning = '';
      this.sending = false;
    }
  }

  private toggleVoiceInput(): void {
    if (this.recognizing) {
      this.recognition.finish(this.recognitionId);
      return;
    }
    this.status = '';
    this.recognitionId = util.generateRandomUUID(true);
    this.recognizing = true;
    this.recognition.start(this.recognitionId, this.host());
  }

  private stopReading(): void {
    this.speaker.stop();
    this.reading = false;
  }

  private async openOriginal(): Promise<void> {
    try {
      this.stopActivity();
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Index' });
    } catch {
      this.status = '无法打开原版。';
    }
  }

  @Builder
  private messageBubble(role: string, content: string, reasoning: string) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(role === 'user' ? '你' : '助手')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (role === 'assistant' && content) {
          Button(this.reading ? '停止朗读' : '朗读', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .onClick(() => {
              if (this.reading) {
                this.stopReading();
              } else {
                this.reading = true;
                this.speaker.speak(util.generateRandomUUID(true), content, 'zh-CN');
              }
            })
        }
      }
      if (reasoning) {
        Text(`思考过程\n${reasoning}`).fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').copyOption(CopyOptions.LocalDevice)
      }
      if (content) {
        Text(content).fontSize(16).width('100%').copyOption(CopyOptions.LocalDevice)
      }
    }
    .bubbleStyle()
  }

  @Styles
  bubbleStyle() {
    .width('100%')
    .padding(14)
    .borderRadius(18)
    .backgroundColor($r('sys.color.comp_background_secondary'))
  }

  @Builder
  private streamingBubble() {
    Column({ space: 8 }) {
      Text('助手').fontWeight(FontWeight.Medium).width('100%')
      if (this.reasoning) {
        Text(`思考过程\n${this.reasoning}`).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
      }
      if (this.reply) {
        Text(this.reply).fontSize(16).width('100%')
      } else if (!this.reasoning) {
        Text('正在等待回复…').fontSize(16).width('100%')
      }
    }
    .bubbleStyle()
  }

  @Builder
  private settingsSheet() {
    Column({ space: 12 }) {
      Text('服务设置').fontSize(22).fontWeight(FontWeight.Bold)
      Text('API 地址').width('100%')
      TextInput({ text: this.baseUrl, placeholder: 'https://api.deepseek.com' })
        .onChange((value: string) => {
          if (this.baseUrl.trim() !== value.trim()) {
            this.apiKey = '';
          }
          this.baseUrl = value;
        })
      Text('模型').width('100%')
      TextInput({ text: this.model, placeholder: 'deepseek-flash' })
        .onChange((value: string) => { this.model = value; })
      Text('API 密钥，仅在当前运行期间保留').width('100%')
      TextInput({ text: this.apiKey, placeholder: 'API 密钥' })
        .type(InputType.Password)
        .onChange((value: string) => { this.apiKey = value; })
      Button('隐私政策', { buttonStyle: ButtonStyleMode.TEXTUAL })
        .onClick(async (): Promise<void> => {
          try {
            await openNuwaPrivacyPolicy(this.host());
          } catch {
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.privacy_policy_unavailable') });
          }
        })
      Button('完成').width('100%').onClick(() => { this.settingsVisible = false; })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('Nuwa').fontSize(24).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('原版', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { void this.openOriginal(); })
        Button('设置', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.settingsVisible = true; })
      }
      .width('100%')
      .padding({ left: 18, right: 12, top: 8, bottom: 8 })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .bindSheet($$this.settingsVisible, this.settingsSheet(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: true,
        blurStyle: BlurStyle.Thick,
      })

      List({ space: 10, scroller: this.scroller }) {
        if (!this.loaded && this.status) {
          ListItem() {
            Button('重试读取会话').onClick(() => { void this.loadHistory(); })
          }
        }
        if (this.loaded && this.messages.length === 0 && !this.sending) {
          ListItem() {
            Text('发一条消息开始对话').width('100%').textAlign(TextAlign.Center)
              .fontColor($r('sys.color.font_secondary')).padding(24)
          }
        }
        ForEach(this.messages, (message: NativeStoredMessage) => {
          ListItem() {
            this.messageBubble(message.role, message.content, message.reasoning)
          }
        }, (_message: NativeStoredMessage, index: number): string => index.toString())
        if (this.sending) {
          ListItem() {
            this.streamingBubble()
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.status) {
        Text(this.status).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 16, right: 16 })
      }
      Column({ space: 8 }) {
        TextArea({ text: this.draft, placeholder: '输入消息' })
          .height(76)
          .onChange((value: string) => { this.draft = value; })
        Row({ space: 8 }) {
          Button(this.recognizing ? '结束录音' : '语音输入', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .onClick(() => { this.toggleVoiceInput(); })
          Blank()
          if (this.sending) {
            Button('停止生成').onClick(() => { this.client.cancel(); })
          } else {
            Button('发送').enabled(this.loaded && !!this.draft.trim()).onClick(() => { void this.sendMessage(); })
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    }
    .width('100%')
    .constraintSize({ maxWidth: 820 })
    .height('100%')
  }
}
