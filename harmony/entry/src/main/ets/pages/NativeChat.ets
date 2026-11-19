import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { NativeChatClient, NativeChatConfig, NativeChatMessage } from '../native/NativeChatClient';
import { NativeChatStorage } from '../native/NativeChatStorage';
import {
  appendBranch, createConversation, createConversationMessage, deleteConversations, groupConversations,
  messageVersions, NativeConversation, NativeConversationGroup, NativeConversationMessage, NativeConversationState,
  renameConversation, selectConversation, selectMessageVersion, setConversationsPinned, toggleConversationPin,
  updateConversationMessage, upsertConversation, visibleMessages,
} from '../native/NativeConversation';
import { NativeMarkdown } from '../native/NativeMarkdown';
import { NativeSettings, NativeSettingsController } from '../native/NativeSettings';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';

interface NativeReply {
  sessionId: string;
  message: NativeConversationMessage;
  client: NativeChatClient;
  stopped: boolean;
}

@Entry
@Component
struct NativeChat {
  @State private history: NativeConversationState = { sessions: [], activeId: null };
  @State private settings: NativeSettings = {
    baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat', apiKey: '', protocol: 'openai',
    thinking: false, search: false, ttsMuted: true,
  };
  @State private draft: string = '';
  @State private loaded: boolean = false;
  @State private status: string = '';
  @State private drawerOpen: boolean = false;
  @State private drawerDrag: number = 0;
  @State private searchText: string = '';
  @State private selectedIds: string[] = [];
  @State private selecting: boolean = false;
  @State private settingsVisible: boolean = false;
  @State private renamingId: string = '';
  @State private editId: string = '';
  @State private renameText: string = '';
  @State private editText: string = '';
  @State private replies: NativeReply[] = [];
  @State private recognitionId: string = '';
  @State private readingId: string = '';
  @State private collapsedThoughts: string[] = [];
  @State private viewportWidth: number = 390;
  @State private viewportHeight: number = 820;

  private readonly storage = new NativeChatStorage();
  private readonly settingsStore = new NativeSettingsController();
  private readonly scroller = new Scroller();
  private readonly drafts: Map<string, string> = new Map();
  private visible: boolean = false;
  private scrollTimer: number = -1;
  private lastStreamSave: number = 0;
  private touchStart: number = 0;
  private titleTap: number = 0;
  private readonly recognition = new HarmonySpeechRecognition((id: string, state: string, text?: string, code?: string) => {
    if (id !== this.recognitionId) {
      return;
    }
    if (state === 'done' || state === 'error') {
      this.recognitionId = '';
    }
    if (state === 'done' && text) {
      this.draft = this.draft ? `${this.draft} ${text}` : text;
    } else if (state === 'error') {
      this.toast(code === 'permission-denied' ? '请允许 Nuwa 使用麦克风' : '系统语音识别暂不可用');
    }
  });
  private readonly speaker = new HarmonyTextToSpeech((id: string, state: string) => {
    if (id === this.readingId && state !== 'playing') {
      this.readingId = '';
      if (state === 'error' || state === 'unavailable') {
        this.toast('系统朗读暂不可用');
      }
    }
  });

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    void this.load();
  }

  onPageShow(): void {
    this.visible = true;
  }

  onPageHide(): void {
    if (this.replies.length) {
      void this.save();
    }
    this.visible = false;
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.onPageHide();
    this.replies.forEach((reply: NativeReply) => { reply.stopped = true; reply.client.cancel(); });
    this.stopVoice();
    this.speaker.destroy();
  }

  onBackPress(): boolean {
    if (this.settingsVisible) {
      this.settingsVisible = false;
    } else if (this.renamingId) {
      this.renamingId = '';
    } else if (this.selecting) {
      this.resetSelection();
    } else if (this.drawerOpen) {
      this.setDrawer(false);
    } else if (this.editId) {
      this.editId = '';
    } else {
      return false;
    }
    return true;
  }

  private host(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private async load(): Promise<void> {
    this.status = '';
    try {
      const context = this.host();
      this.history = await this.storage.loadConversations(context);
      try {
        this.settings = await this.settingsStore.load(context);
      } catch {
        this.toast('无法读取已保存的服务设置');
      }
      this.loaded = true;
      this.scrollToLatest();
    } catch {
      this.status = '无法读取本地会话';
    }
  }

  private async save(context: common.UIAbilityContext = this.host()): Promise<void> {
    try {
      await this.storage.saveConversations(context, this.historyWithPartialReplies());
    } catch {
      this.status = '本地会话保存失败，请重试';
    }
  }

  private async saveSettings(): Promise<void> {
    const settings: NativeSettings = {
      baseUrl: this.settings.baseUrl, apiKey: this.settings.apiKey, model: this.settings.model,
      protocol: this.settings.protocol, thinking: this.settings.thinking, search: this.settings.search,
      ttsMuted: this.settings.ttsMuted,
    };
    try {
      await this.settingsStore.save(this.host(), settings);
    } catch {
      this.toast('无法保存设置');
    }
  }

  private session(id: string | null = this.history.activeId): NativeConversation | undefined {
    return this.history.sessions.find((item: NativeConversation): boolean => item.id === id);
  }

  private reply(id: string | null = this.history.activeId): NativeReply | undefined {
    return this.replies.find((item: NativeReply): boolean => item.sessionId === id);
  }

  private messages(): NativeConversationMessage[] {
    const session = this.session();
    return session ? visibleMessages(session) : [];
  }

  private scrollToLatest(): void {
    if (this.scrollTimer < 0) {
      this.scrollTimer = setTimeout(() => {
        this.scrollTimer = -1;
        if (this.visible && this.history.activeId !== null) {
          this.scroller.scrollEdge(Edge.Bottom);
        }
      }, 0);
    }
  }

  private activate(id: string | null): void {
    if (this.history.activeId !== id) {
      this.drafts.set(this.history.activeId ?? '', this.draft);
      this.stopVoice();
      this.history = selectConversation(this.history, id);
      this.draft = this.drafts.get(id ?? '') ?? '';
      this.editId = '';
      this.titleTap = 0;
      this.status = '';
      this.scrollToLatest();
      void this.save();
    }
    this.setDrawer(false);
  }

  private setDrawer(open: boolean): void {
    if (open) {
      this.getUIContext().getFocusController().clearFocus();
    } else {
      this.searchText = '';
      this.resetSelection();
    }
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.drawerOpen = open;
      this.drawerDrag = 0;
    });
  }

  private resetSelection(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private toggleSelected(id: string): void {
    this.selectedIds = this.selectedIds.includes(id) ?
      this.selectedIds.filter((item: string): boolean => item !== id) : [...this.selectedIds, id];
  }

  private groups(): NativeConversationGroup[] {
    const query = this.searchText.trim().toLowerCase();
    return groupConversations(query ? this.history.sessions.filter((session: NativeConversation): boolean =>
      session.title.toLowerCase().includes(query) || session.messages.some((message: NativeConversationMessage): boolean =>
        message.content.toLowerCase().includes(query) || message.reasoning.toLowerCase().includes(query))) : this.history.sessions);
  }

  private async deleteSessions(ids: string[]): Promise<void> {
    if (!ids.length) {
      return;
    }
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: ids.length === 1 ? '删除对话' : `删除 ${ids.length} 个对话`, message: '删除后将无法恢复。',
        buttons: [{ text: '取消', color: '#61666B' }, { text: '删除', color: '#EC1313' }],
      });
      if (result.index !== 1) {
        return;
      }
      ids.forEach((id: string) => { this.cancelReply(id); this.drafts.delete(id); });
      const active = this.history.activeId;
      this.history = deleteConversations(this.history, ids);
      if (active !== this.history.activeId) {
        this.stopVoice();
        this.draft = this.drafts.get(this.history.activeId ?? '') ?? '';
      }
      this.resetSelection();
      await this.save();
    } catch {
      this.toast('删除对话失败，请重试');
    }
  }

  private allPinned(): boolean {
    return this.selectedIds.length > 0 && this.selectedIds.every((id: string): boolean => !!this.session(id)?.pinnedAt);
  }

  private cancelReply(id: string | null = this.history.activeId): void {
    const reply = this.reply(id);
    if (reply) {
      reply.stopped = true;
      reply.client.cancel();
    }
  }

  private startReply(session: NativeConversation, parentId: string | null,
    prompt?: NativeConversationMessage, clearDraft: boolean = false): void {
    if (!this.loaded || this.reply(session.id)) {
      return;
    }
    const config: NativeChatConfig = {
      baseUrl: this.settings.baseUrl.trim(), model: this.settings.model.trim(), apiKey: this.settings.apiKey.trim(),
      protocol: this.settings.protocol, thinking: this.settings.thinking, search: this.settings.search,
    };
    if (!config.baseUrl || !config.model || (!config.apiKey && config.baseUrl === 'https://api.deepseek.com')) {
      this.settingsVisible = true;
      return;
    }
    const message = createConversationMessage('assistant', '', '', Date.now(), 'pending', config.model);
    const next = appendBranch(session, parentId, prompt ? [prompt, message] : [message]);
    const reply: NativeReply = { sessionId: next.id, message, client: new NativeChatClient(), stopped: false };
    this.replies = [...this.replies, reply];
    if (clearDraft) {
      this.drafts.delete(this.history.activeId ?? '');
      this.draft = '';
    }
    this.history = upsertConversation(this.history, next, true);
    this.lastStreamSave = Date.now();
    this.status = '';
    this.getUIContext().getFocusController().clearFocus();
    this.scrollToLatest();
    void this.receive(this.host(), config, next, reply);
  }

  private streamMessage(reply: NativeReply, status: string): NativeConversationMessage {
    return {
      id: reply.message.id, role: 'assistant', createdAt: reply.message.createdAt,
      parentId: reply.message.parentId, content: reply.message.content, reasoning: reply.message.reasoning,
      model: reply.message.model, status,
    };
  }

  private historyWithPartialReplies(): NativeConversationState {
    let state = this.history;
    for (const reply of this.replies) {
      const session = state.sessions.find((item: NativeConversation): boolean => item.id === reply.sessionId);
      const pending = session?.messages.find((message: NativeConversationMessage): boolean => message.id === reply.message.id);
      if (session && pending?.status === 'pending' && (reply.message.content || reply.message.reasoning)) {
        state = upsertConversation(state, updateConversationMessage(session, this.streamMessage(reply, 'streaming')));
      }
    }
    return state;
  }

  private async receive(context: common.UIAbilityContext, config: NativeChatConfig,
    session: NativeConversation, reply: NativeReply): Promise<void> {
    void this.save(context);
    let error = false;
    try {
      const messages = visibleMessages(session).filter((item: NativeConversationMessage): boolean => !!item.content)
        .map<NativeChatMessage>((item: NativeConversationMessage): NativeChatMessage => ({ role: item.role, content: item.content }));
      await reply.client.send(config, messages, (content: string, reasoning: string) => {
        if (this.history.activeId === session.id && this.visible && this.scroller.isAtEnd()) {
          this.scrollToLatest();
        }
        reply.message.content += content;
        reply.message.reasoning += reasoning;
        this.replies = Array.from(this.replies);
        if (Date.now() - this.lastStreamSave > 1500) {
          this.lastStreamSave = Date.now();
          void this.save(context);
        }
      });
    } catch (cause) {
      error = true;
      if (this.history.activeId === session.id) {
        this.status = (cause as Error).message || '请求失败';
      }
    } finally {
      const current = this.session(session.id);
      if (current) {
        const message = this.streamMessage(reply, error ? 'error' : reply.stopped ? 'stopped' : 'done');
        this.history = upsertConversation(this.history, updateConversationMessage(current, message));
        void this.save(context);
        if (!error && !reply.stopped && !this.settings.ttsMuted && this.history.activeId === current.id && message.content) {
          this.readMessage(message);
        }
      }
      this.replies = this.replies.filter((item: NativeReply): boolean => item.sessionId !== reply.sessionId);
    }
  }

  private sendDraft(): void {
    const text = this.draft.trim();
    if (text) {
      const session = this.session() ?? createConversation();
      const thread = visibleMessages(session);
      this.startReply(session, thread.length ? thread[thread.length - 1].id : null,
        createConversationMessage('user', text, ''), true);
    }
  }

  private retry(message: NativeConversationMessage): void {
    const session = this.session();
    if (session) {
      this.startReply(session, message.parentId);
    }
  }

  private edit(message: NativeConversationMessage): void {
    const session = this.session();
    const text = this.editText.trim();
    if (session && text && !this.reply()) {
      this.editId = '';
      this.startReply(session, message.parentId, createConversationMessage('user', text, ''));
    }
  }

  private versions(message: NativeConversationMessage): NativeConversationMessage[] {
    const session = this.session();
    return session ? messageVersions(session, message.id) : [];
  }

  private version(message: NativeConversationMessage): number {
    return this.versions(message).findIndex((item: NativeConversationMessage): boolean => item.id === message.id);
  }

  private changeVersion(message: NativeConversationMessage, offset: number): void {
    const session = this.session();
    const sibling = this.versions(message)[this.version(message) + offset];
    if (session && sibling) {
      this.history = upsertConversation(this.history, selectMessageVersion(session, sibling.id));
      this.stopVoice();
      void this.save();
    }
  }

  private toggleRecognition(): void {
    if (this.recognitionId) {
      this.recognition.finish(this.recognitionId);
    } else {
      this.getUIContext().getFocusController().clearFocus();
      this.recognitionId = util.generateRandomUUID(true);
      this.recognition.start(this.recognitionId, this.host());
    }
  }

  private stopVoice(): void {
    this.recognitionId = '';
    this.recognition.cancel();
    this.readingId = '';
    this.speaker.stop();
  }

  private readMessage(message: NativeConversationMessage): void {
    const active = this.readingId === message.id;
    this.speaker.stop();
    this.readingId = active ? '' : message.id;
    if (this.readingId) {
      this.speaker.speak(message.id, message.content, 'zh-CN');
    }
  }

  private toggleSpeaker(): void {
    const muted = !!this.readingId || !this.settings.ttsMuted;
    this.readingId = '';
    this.speaker.stop();
    this.settings.ttsMuted = muted;
    void this.saveSettings();
    this.toast(muted ? '已静音朗读' : '已取消朗读静音');
  }

  private async copy(text: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.toast('已复制');
    } catch {
      this.toast('复制失败');
    }
  }

  private compact(): boolean {
    return this.viewportWidth <= 340;
  }

  private drawerWidth(): number {
    return Math.min(this.viewportWidth * 0.82, 310);
  }

  private drawerProgress(): number {
    return Math.max(0, Math.min(1, (this.drawerOpen ? 1 : 0) + this.drawerDrag / this.drawerWidth()));
  }

  @Builder
  private iconButton(icon: Resource, label: string, action: () => void, size: number = 34,
    iconSize: number = 20, color: ResourceColor = $r('app.color.native_chat_primary'),
    background: ResourceColor = Color.Transparent, enabled: boolean = true) {
    Button({ type: ButtonType.Circle }) {
      Image(icon).width(iconSize).height(iconSize).fillColor(color).draggable(false)
    }
    .width(size).height(size).padding(0).backgroundColor(background)
    .enabled(enabled).accessibilityText(label).onClick(action)
  }

  @Builder
  private header() {
    Row({ space: this.compact() ? 6 : 10 }) {
      Row() {
        this.iconButton($r('app.media.native_menu'), '展开侧边栏', () => { this.setDrawer(true); }, this.compact() ? 30 : 42)
      }
      .borderRadius(999).border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN).shadow({ radius: 10, color: '#10000000', offsetY: 2 })
      if (this.history.activeId !== null) {
        Text(this.session()?.title || '新对话').fontSize(this.compact() ? 13 : 14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary')).textAlign(TextAlign.Center)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .onClick(() => {
            const now = Date.now();
            if (now - this.titleTap < 400) {
              this.scroller.scrollEdge(Edge.Top);
              this.titleTap = 0;
            } else {
              this.titleTap = now;
            }
          })
      } else {
        Blank().layoutWeight(1)
      }
      Row({ space: 2 }) {
        this.iconButton(this.settings.ttsMuted && !this.readingId ? $r('app.media.native_muted') : $r('app.media.native_speaker'),
          '朗读静音', () => { this.toggleSpeaker(); }, this.compact() ? 26 : 34)
        this.iconButton($r('app.media.native_new_chat'), '开启新对话', () => { this.activate(null); }, this.compact() ? 26 : 34)
      }
      .height(this.compact() ? 30 : 42).padding({ left: 6, right: 6 })
      .borderRadius(999).border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN).shadow({ radius: 10, color: '#10000000', offsetY: 2 })
    }
    .width('100%').height(this.compact() ? 40 : 58)
    .padding({ left: this.compact() ? 8 : 16, right: this.compact() ? 8 : 16, top: 4 })
  }

  @Builder
  private welcome() {
    Column({ space: this.compact() ? 6 : 16 }) {
      Image($r('app.media.native_welcome_logo'))
        .width(this.compact() ? 34 : 52).height(this.compact() ? 34 : 52)
        .borderRadius(this.compact() ? 10 : 14).shadow({ radius: 14, color: '#14000000', offsetY: 4 })
        .draggable(false).accessibilityText('Nuwa')
      Text('你好，让我们开始聊天吧').fontSize(this.compact() ? 14 : 20).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.native_chat_primary'))
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  @Builder
  private togglePill(icon: Resource, label: string, active: boolean, change: () => void) {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 5 }) {
        Image(icon).width(14).height(14).fillColor(active ? $r('app.color.native_chat_blue_text') :
          $r('app.color.native_chat_primary')).draggable(false)
        if (this.viewportWidth >= 374 || !this.draft.trim() && this.viewportWidth >= 330) {
          Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(active ?
            $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
        }
      }
    }
    .height(34).padding({ left: 11, right: 11 }).backgroundColor(active ? $r('app.color.native_chat_selected') : Color.Transparent)
    .border({ width: 1, color: active ? Color.Transparent : $r('app.color.native_chat_stroke') })
    .accessibilityText(label).accessibilitySelected(active).onClick(change)
  }

  @Builder
  private voiceButton() {
    this.iconButton($r('app.media.native_voice'), this.recognitionId ? '结束录音' : '语音输入',
      () => { this.toggleRecognition(); }, 34, 22,
      this.recognitionId ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
  }

  @Builder
  private composer() {
    Column({ space: 2 }) {
      if (this.recognitionId) {
        Row({ space: 4 }) {
          ForEach([8, 13, 18, 13, 8], (bar: number) => {
            Rect().width(3).height(bar).radius(2).fill($r('app.color.native_chat_blue'))
          }, (_bar: number, index: number): string => index.toString())
        }
        .width('100%').height(this.viewportWidth < 440 ? 42 : 60).padding({ left: 16 }).accessibilityText('录音中')
      } else {
        TextArea({ text: this.draft, placeholder: '发消息或语音输入' })
          .width('100%').constraintSize({ minHeight: this.viewportWidth < 440 ? 42 : 60, maxHeight: 336 })
          .padding({ top: 12, bottom: 0, left: 16, right: 12 }).borderRadius(0)
          .fontSize(16).lineHeight(24).placeholderColor($r('app.color.native_chat_caption'))
          .fontColor($r('app.color.native_chat_primary')).caretColor($r('app.color.native_chat_blue_text'))
          .backgroundColor(Color.Transparent).enterKeyType(EnterKeyType.NEW_LINE).enabled(this.loaded)
          .onChange((value: string) => { this.draft = value; })

      }
      Row({ space: this.compact() ? 6 : 9 }) {
        this.togglePill($r('app.media.native_think'), '深度思考', this.settings.thinking, () => {
          this.settings.thinking = !this.settings.thinking;
          void this.saveSettings();
        })
        this.togglePill($r('app.media.native_web_search'), '智能搜索', this.settings.search, () => {
          this.settings.search = !this.settings.search;
          void this.saveSettings();
        })
        Blank().layoutWeight(1)
        if (this.reply()) {
          this.iconButton($r('app.media.native_stop'), '停止生成', () => { this.stopVoice(); this.cancelReply(); },
            34, 16, Color.White, $r('app.color.native_chat_blue'))
        } else if (this.draft.trim()) {
          this.voiceButton()
          this.iconButton($r('app.media.native_send'), '发送', () => { this.sendDraft(); },
            34, 16, Color.White, $r('app.color.native_chat_blue'), this.loaded && !this.recognitionId)
        } else {
          this.voiceButton()
        }
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .width('100%').borderRadius(24)
    .border({ width: 1, color: this.history.activeId === null ? $r('app.color.native_chat_glass_stroke') :
      $r('app.color.native_chat_stroke') })
    .backgroundColor(this.history.activeId === null ? $r('app.color.native_chat_glass') : $r('app.color.native_chat_surface'))
    .backgroundBlurStyle(this.history.activeId === null ? BlurStyle.COMPONENT_THIN : BlurStyle.NONE)
    .shadow({ radius: 12, offsetY: 4, color: '#0D000000' }).clip(true)
  }

  @Builder
  private branchControls(message: NativeConversationMessage) {
    if (this.versions(message).length > 1) {
      Row() {
        this.iconButton($r('app.media.native_chevron_left'), '上一个版本', () => { this.changeVersion(message, -1); },
          26, 14, $r('app.color.native_chat_secondary'), Color.Transparent, this.version(message) > 0)
        Text(`${this.version(message) + 1}/${this.versions(message).length}`)
          .fontSize(12).fontColor($r('app.color.native_chat_secondary'))
        this.iconButton($r('app.media.native_chevron_right'), '下一个版本', () => { this.changeVersion(message, 1); },
          26, 14, $r('app.color.native_chat_secondary'), Color.Transparent, this.version(message) + 1 < this.versions(message).length)
      }
    }
  }

  @Builder
  private userMessage(message: NativeConversationMessage, index: number) {
    Column({ space: 6 }) {
      if (message.id === this.editId) {
        Column() {
          TextArea({ text: this.editText }).width('100%').fontSize(16).height(88).backgroundColor(Color.Transparent)
            .onChange((value: string) => { this.editText = value; })
          Row({ space: 8 }) {
            Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.editId = ''; })
            Button('发送').enabled(!!this.editText.trim()).onClick(() => { this.edit(message); })
          }
          .width('100%').justifyContent(FlexAlign.End).padding(6)
        }
        .width('100%').borderRadius(22).border({ width: 1, color: $r('app.color.native_chat_blue') })
      } else {
        Text(message.content).fontSize(16).lineHeight(24).fontColor($r('app.color.native_chat_primary'))
          .constraintSize({ maxWidth: Math.max(140, Math.min(this.viewportWidth - 40, 752) - 68) })
          .padding({ left: 16, right: 16, top: 10, bottom: 10 }).borderRadius(22)
          .backgroundColor($r('app.color.native_chat_bubble')).copyOption(CopyOptions.LocalDevice)
        Row({ space: 4 }) {
          this.branchControls(message)
          this.iconButton($r('app.media.native_copy'), '复制', () => { void this.copy(message.content); },
            28, 16, $r('app.color.native_chat_secondary'))
          this.iconButton($r('app.media.native_edit'), '编辑', () => {
            this.editId = message.id;
            this.editText = message.content;
          }, 28, 16, $r('app.color.native_chat_secondary'), Color.Transparent, !this.reply())
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.End).padding({ top: index === 0 ? 34 : 0, bottom: 16 })
  }

  @Builder
  private replyContent(id: string, text: string, reasoning: string, thinking: boolean) {
    if (reasoning) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Image($r('app.media.native_think')).width(16).height(16).fillColor($r('app.color.native_chat_blue_text'))
          Text(thinking ? '正在思考' : '已思考').fontSize(15).fontColor($r('app.color.native_chat_secondary'))
          Image(this.collapsedThoughts.includes(id) ? $r('app.media.native_chevron_right') :
            $r('app.media.native_chevron_down')).width(14).height(14).fillColor($r('app.color.native_chat_secondary'))
        }
      }
      .height(34).padding(0).backgroundColor(Color.Transparent)
      .onClick(() => {
        this.collapsedThoughts = this.collapsedThoughts.includes(id) ?
          this.collapsedThoughts.filter((messageId: string): boolean => messageId !== id) : [...this.collapsedThoughts, id];
      })
      if (!this.collapsedThoughts.includes(id)) {
        Text(reasoning).fontSize(14).lineHeight(22).width('100%').fontColor($r('app.color.native_chat_secondary'))
          .padding({ left: 12 }).copyOption(CopyOptions.LocalDevice)
          .border({ width: { left: 2 }, color: $r('app.color.native_chat_stroke') })
      }
    }
    if (text) {
      NativeMarkdown({ content: text })
    }
  }

  @Builder
  private assistantMessage(message: NativeConversationMessage) {
    Column({ space: 7 }) {
      if (this.reply()?.message.id === message.id) {
        if (this.reply()?.message.content || this.reply()?.message.reasoning) {
          this.replyContent(message.id, this.reply()?.message.content ?? '', this.reply()?.message.reasoning ?? '',
            !this.reply()?.message.content)
        } else {
          Row({ space: 6 }) {
            ForEach([0.45, 0.7, 1], (opacity: number) => {
              Circle().width(6).height(6).fill($r('app.color.native_chat_caption')).opacity(opacity)
            }, (opacity: number): string => opacity.toString())
          }
          .height(34).accessibilityText('正在等待回复')
        }
      } else {
        this.replyContent(message.id, message.content, message.reasoning, false)
        if (message.status === 'error') {
          Text('回复失败，请重试').fontSize(14).fontColor($r('app.color.native_chat_error'))
        } else if (message.status === 'stopped') {
          Text('已停止生成').fontSize(13).fontColor($r('app.color.native_chat_secondary'))
        }
        Row({ space: 4 }) {
          if (message.content) {
            this.iconButton($r('app.media.native_copy'), '复制', () => { void this.copy(message.content); },
              28, 16, $r('app.color.native_chat_secondary'))
            this.iconButton($r('app.media.native_speaker'), this.readingId === message.id ? '停止朗读' : '朗读',
              () => { this.readMessage(message); }, 28, 16,
              this.readingId === message.id ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_secondary'))
          }
          this.iconButton($r('app.media.native_retry'), '重新生成', () => { this.retry(message); },
            28, 16, $r('app.color.native_chat_secondary'), Color.Transparent, !this.reply())
          this.branchControls(message)
        }
        .padding({ top: 6, bottom: 12 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
  }

  @Builder
  private settingsPage() {
    Scroll() {
      Column({ space: 12 }) {
        Text('设置').fontSize(22).fontWeight(FontWeight.Medium).width('100%')
        Text('API 地址').width('100%')
        TextInput({ text: this.settings.baseUrl, placeholder: 'https://api.deepseek.com' }).onChange((value: string) => {
          const key = this.settings.baseUrl.trim() === value.trim() ? this.settings.apiKey : '';
          this.settings.apiKey = key;
          this.settings.baseUrl = value;
        })
        Text('模型').width('100%')
        TextInput({ text: this.settings.model, placeholder: 'deepseek-chat' }).onChange((value: string) => {
          this.settings.model = value;
        })
        Text('API 格式').width('100%')
        Select([{ value: 'OpenAI' }, { value: 'Anthropic' }]).selected(this.settings.protocol === 'anthropic' ? 1 : 0)
          .value(this.settings.protocol === 'anthropic' ? 'Anthropic' : 'OpenAI').onSelect((index: number) => {
            const protocol = index === 1 ? 'anthropic' : 'openai';
            const key = protocol === this.settings.protocol ? this.settings.apiKey : '';
            this.settings.apiKey = key;
            this.settings.protocol = protocol;
          })
        Text('API 密钥').width('100%')
        TextInput({ text: this.settings.apiKey, placeholder: 'API 密钥' }).type(InputType.Password)
          .onChange((value: string) => { this.settings.apiKey = value; })
        Button('隐私政策', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(async (): Promise<void> => {
          try {
            await openNuwaPrivacyPolicy(this.host());
          } catch {
            this.toast('无法打开隐私政策');
          }
        })
        Button('原版 Nuwa', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
          this.settingsVisible = false;
          void this.getUIContext().getRouter().pushUrl({ url: 'pages/Index' }).catch(() => { this.toast('无法打开原版'); });
        })
        Button('完成').width('100%').onClick(async (): Promise<void> => {
          await this.saveSettings();
          this.settingsVisible = false;
        })
      }
      .width('100%').padding({ left: 24, right: 24, top: 20, bottom: 28 })
    }
  }

  @Builder
  private sessionMenu(session: NativeConversation) {
    Menu() {
      MenuItem({ content: '重命名' }).onClick(() => {
        this.renamingId = session.id;
        this.renameText = session.title;
      })
      MenuItem({ content: session.pinnedAt ? '取消置顶' : '置顶' }).onClick(() => {
        this.history = toggleConversationPin(this.history, session.id);
        void this.save();
      })
      MenuItem({ content: '删除' }).onClick(() => { void this.deleteSessions([session.id]); })
    }
  }

  @Builder
  private drawerItem(session: NativeConversation) {
    Row({ space: 8 }) {
      if (this.selecting) {
        Checkbox({ name: session.id }).select(this.selectedIds.includes(session.id))
          .width(20).height(20).onChange(() => { this.toggleSelected(session.id); })
      }
      Text(session.title || '新对话').fontSize(15).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.native_chat_primary'))
      if (!this.selecting) {
        Button('⋯', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(18).width(32).height(32).padding(0)
          .fontColor($r('app.color.native_chat_secondary')).accessibilityText('对话选项')
          .bindMenu(this.sessionMenu(session))
      }
    }
    .height(44).width('100%').padding({ left: 10, right: 4 }).borderRadius(10)
    .backgroundColor(session.id === this.history.activeId || this.selectedIds.includes(session.id) ?
      $r('app.color.native_chat_active_session') : Color.Transparent)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelected(session.id);
      } else {
        this.activate(session.id);
      }
    })
    .gesture(LongPressGesture({ duration: 450 }).onAction(() => {
      if (!this.selecting) {
        this.selecting = true;
        this.selectedIds = [session.id];
      }
    }))
  }

  @Builder
  private drawer() {
    Column() {
      if (this.selecting) {
        Row() {
          Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.resetSelection(); })
          Text(`已选择 ${this.selectedIds.length} 项`).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
            .textAlign(TextAlign.Center).fontColor($r('app.color.native_chat_primary'))
          Button('全选', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
            this.selectedIds = this.groups().flatMap<string>((group: NativeConversationGroup): string[] =>
              group.sessions.map<string>((session: NativeConversation): string => session.id));
          })
        }
        .width('100%').height(44)
      } else {
        Row({ space: 8 }) {
          Image($r('app.media.native_search')).height(16).width(16).fillColor($r('app.color.native_chat_secondary'))
          TextInput({ text: this.searchText, placeholder: '搜索对话内容...' }).fontSize(15).height(44).layoutWeight(1)
            .backgroundColor(Color.Transparent).padding(0).onChange((value: string) => { this.searchText = value; })
        }
        .width('100%').borderRadius(14).padding({ left: 14, right: 12 }).backgroundColor($r('app.color.native_chat_field'))
      }
      List({ space: 2 }) {
        if (this.history.sessions.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              Text('暂无对话').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
              Text('你与 Nuwa 的对话\n将展示在这里').textAlign(TextAlign.Center).fontSize(13)
                .fontColor($r('app.color.native_chat_secondary'))
              Button('开启新对话', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.activate(null); })
            }
            .width('100%').padding({ top: 28 })
          }
        } else if (!this.groups().length) {
          ListItem() {
            Text('未找到匹配的对话').fontSize(14).fontColor($r('app.color.native_chat_secondary')).padding(14)
          }
        }
        ForEach(this.groups(), (group: NativeConversationGroup) => {
          ListItemGroup() {
            ListItem() {
              Text(group.label).fontSize(13).width('100%').fontColor($r('app.color.native_chat_secondary'))
                .padding({ top: 8, left: 10, bottom: 3 })
            }
            ForEach(group.sessions, (session: NativeConversation) => {
              ListItem() {
                this.drawerItem(session)
              }
            }, (session: NativeConversation): string => `${session.id}:${session.title}:${session.pinnedAt ?? 0}`)
          }
        }, (group: NativeConversationGroup): string => group.key + group.sessions.map<string>(
          (session: NativeConversation): string => `${session.id}:${session.title}:${session.pinnedAt ?? 0}`).join('|'))
      }
      .layoutWeight(1).width('100%').padding({ top: 8 }).scrollBar(BarState.Off)
      if (this.selecting) {
        Row() {
          Button(this.allPinned() ? '取消置顶' : '置顶', { buttonStyle: ButtonStyleMode.TEXTUAL })
            .enabled(this.selectedIds.length > 0).layoutWeight(1).onClick(() => {
              this.history = setConversationsPinned(this.history, this.selectedIds, !this.allPinned());
              this.resetSelection();
              void this.save();
            })
          Button('删除', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.native_chat_error'))
            .enabled(this.selectedIds.length > 0).layoutWeight(1).onClick(() => { void this.deleteSessions(this.selectedIds); })
        }
        .height(52).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Image($r('app.media.native_welcome_logo')).width(31).height(31).borderRadius(10).draggable(false)
            Text('设置').fontSize(15).layoutWeight(1).fontColor($r('app.color.native_chat_primary'))
            Text('⋯').fontSize(18).fontColor($r('app.color.native_chat_secondary'))
          }
          .width('100%').padding({ left: 6, right: 6 })
        }
        .height(52).width('100%').padding(0).backgroundColor(Color.Transparent)
        .onClick(() => { this.setDrawer(false); this.settingsVisible = true; })
      }
    }
    .width(this.drawerWidth()).height('100%').padding({ left: 16, right: 10, top: 14, bottom: 8 })
  }

  @Builder
  private renameDialog() {
    Column({ space: 14 }) {
      Text('重命名对话').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ text: this.renameText, placeholder: '对话名称' }).maxLength(100)
        .onChange((title: string) => { this.renameText = title; })
      Row({ space: 8 }) {
        Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.renamingId = ''; })
        Button('保存').enabled(!!this.renameText.trim()).onClick(() => {
          this.history = renameConversation(this.history, this.renamingId, this.renameText.trim());
          this.renamingId = '';
          void this.save();
        })
      }
      .width('100%').justifyContent(FlexAlign.End)
    }
    .width('84%').constraintSize({ maxWidth: 420 }).padding(20).borderRadius(22)
    .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  }

  @Builder
  private chatPage() {
    Column() {
      if (this.viewportHeight > 180) {
        this.header()
      }
      if (!this.loaded) {
        Column({ space: 8 }) {
          if (this.status) {
            Text(this.status).fontColor($r('app.color.native_chat_secondary'))
            Button('重试').onClick(() => { void this.load(); })
          } else {
            LoadingProgress().width(28).height(28).color($r('app.color.native_chat_blue'))
          }
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.history.activeId === null) {
        this.welcome()
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.messages(), (message: NativeConversationMessage, index: number) => {
            ListItem() {
              if (message.role === 'user') {
                this.userMessage(message, index)
              } else {
                this.assistantMessage(message)
              }
            }
          }, (message: NativeConversationMessage): string => `${message.id}:${message.status ?? ''}`)
        }
        .width('100%').constraintSize({ maxWidth: 840 }).layoutWeight(1).scrollBar(BarState.Auto)
        .padding({ left: this.compact() ? 10 : 20, right: this.compact() ? 10 : 20, bottom: 16 })
      }
      if (this.loaded && this.status) {
        Text(this.status).fontSize(13).fontColor($r('app.color.native_chat_error'))
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }
      Column() { this.composer() }
      .width('100%').constraintSize({ maxWidth: 808 })
      .padding({ left: this.compact() ? 6 : 14, right: this.compact() ? 6 : 14, bottom: this.compact() ? 6 : 14 })
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
    .bindSheet($$this.settingsVisible, this.settingsPage(), { height: SheetSize.LARGE, blurStyle: BlurStyle.Thick })
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.drawerProgress() > 0) {
        this.drawer()
      }
      Stack() {
        this.chatPage()
        if (this.drawerProgress() > 0) {
          Column().width('100%').height('100%').backgroundColor(Color.Transparent)
            .onClick(() => { this.setDrawer(false); })
        }
      }
      .width('100%').height('100%').translate({ x: this.drawerProgress() * this.drawerWidth() })
      .scale({ x: 1 - this.drawerProgress() * 0.05, y: 1 - this.drawerProgress() * 0.05, centerX: '0%' })
      .borderRadius(this.drawerProgress() > 0 ? 24 : 0).clip(this.drawerProgress() > 0)
      if (this.renamingId) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.renamingId = ''; })
          this.renameDialog()
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_sidebar')).clip(true)
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Number(area.width);
      this.viewportHeight = Number(area.height);
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 14 })
        .onActionStart((event: GestureEvent) => { this.touchStart = event.fingerList[0]?.globalX ?? this.viewportWidth; })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.settingsVisible && !this.renamingId && (this.drawerOpen || this.touchStart < 160)) {
            this.drawerDrag = event.offsetX;
          }
        })
        .onActionEnd(() => {
          if (this.drawerDrag !== 0) {
            this.setDrawer(this.drawerProgress() > (this.drawerOpen ? 0.72 : 0.28));
          }
        })
        .onActionCancel(() => { this.drawerDrag = 0; })
    )
  }
}
