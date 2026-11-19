import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { KeyboardAvoidMode, LengthMetrics } from '@kit.ArkUI';
import { url, util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { NativeChatClient, NativeChatConfig, NativeChatFileRef, NativeChatMessage } from '../native/NativeChatClient';
import { loadNativeAccount, saveNativeAccount } from '../native/NativeAccountStore';
import { NativeApiCredential, verifyNativeApiCredential } from '../native/NativeApiCredential';
import { NativeDataSettings } from '../native/NativeDataSettings';
import { NativeDeepSeekAccount, NativeDeepSeekAccountController, NativeDeepSeekBalance } from '../native/NativeDeepSeekAccount';
import { NativeOnboarding, NativeOnboardingView } from '../native/NativeOnboarding';
import { NativeAttachment, NativeChatAttachments } from '../native/NativeChatAttachments';
import { hydrateImportedAttachment, importedAttachmentPreview, NativeChatBackup, mergeChatBackup } from '../native/NativeChatBackup';
import { NativeChatStorage } from '../native/NativeChatStorage';
import {
  appendBranch, createConversation, createConversationMessage, deleteConversations, groupConversations,
  messageVersions, NativeConversation, NativeConversationGroup, NativeConversationMessage, NativeConversationState,
  renameConversation, selectConversation, selectMessageVersion, setConversationsPinned, toggleConversationPin,
  updateConversationMessage, upsertConversation, visibleMessages,
} from '../native/NativeConversation';
import { NativeMarkdown } from '../native/NativeMarkdown';
import { NativeSettings, NativeSettingsController, NATIVE_CHAT_FONT_SIZES } from '../native/NativeSettings';
import { fetchNativeProviderBalance } from '../native/NativeProviderBalance';
import { checkNativeUpdate, fetchNativeReleaseHistory, getNativeCurrentVersion, NativeReleaseHistoryItem } from '../native/NativeUpdates';
import { importNativeShareLink, nativeShareTemplate } from '../native/NativeShareImport';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';

interface NativeReply {
  sessionId: string;
  message: NativeConversationMessage;
  client: NativeChatClient;
  stopped: boolean;
  uploadingIds: string[];
  attachmentBinding: string;
}

interface NativeDraftAttachment {
  item: NativeAttachment;
  state: 'uploading' | 'ready' | 'failed';
  error: string;
}

interface NativeDraft {
  text: string;
  files: NativeDraftAttachment[];
}

@Entry
@Component
struct NativeChat {
  @State private history: NativeConversationState = { sessions: [], activeId: null };
  @State private settings: NativeSettings = {
    baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat', apiKey: '', protocol: 'openai', authMode: 'api-key',
    theme: 'system', chatFontSize: 16, attachmentBinding: '', thinking: false, search: false, ttsMuted: true,
  };
  @State private draft: string = '';
  @State private draftFiles: NativeDraftAttachment[] = [];
  @State private pickingFiles: boolean = false;
  @State private imagePreview: string = '';
  @State private loaded: boolean = false;
  @State private status: string = '';
  @State private drawerOpen: boolean = false;
  @State private drawerDrag: number = 0;
  @State private searchText: string = '';
  @State private selectedIds: string[] = [];
  @State private selecting: boolean = false;
  @State private settingsVisible: boolean = false;
  @State private onboardingView: NativeOnboardingView = 'home';
  @State private account: NativeDeepSeekAccount | null = null;
  @State private balance: NativeDeepSeekBalance | null = null;
  @State private authorizing: boolean = false;
  @State private storingAccount: boolean = false;
  @State private authorizationUrl: string = '';
  @State private authorizationStatus: string = '';
  @State private settingsSection: string = 'root';
  @State private settingsKey: string = '';
  @State private settingsBase: string = '';
  @State private settingsModel: string = '';
  @State private settingsProtocol: 'openai' | 'anthropic' = 'openai';
  @State private settingsVerifying: boolean = false;
  @State private settingsError: string = '';
  @State private backupBusy: boolean = false;
  @State private shareImportVisible: boolean = false;
  @State private appVersion: string = '';
  @State private checkingUpdate: boolean = false;
  @State private releaseNotes: NativeReleaseHistoryItem[] = [];
  @State private notesLoading: boolean = false;
  @State private notesError: boolean = false;
  @State private shareInput: string = '';
  @State private shareImportError: string = '';
  private deletingSessions: boolean = false;
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
  private readonly attachments = new NativeChatAttachments();
  private readonly backup = new NativeChatBackup();
  private readonly accountController = new NativeDeepSeekAccountController();
  private readonly authBrowser = new webview.WebviewController();
  private authAttempt: number = 0;
  private balanceRequest: number = 0;
  private balanceFetchedAt: number = 0;
  private balanceBinding: string = '';
  private migrationInProgress: boolean = false;
  private readonly scroller = new Scroller();
  private readonly drafts: Map<string, NativeDraft> = new Map();
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
    void getNativeCurrentVersion().then((version: string) => { this.appVersion = version; }).catch(() => {});
  }

  onPageShow(): void {
    this.visible = true;
    if (this.loaded) {
      void this.refreshBalance();
    }
    if (this.migrationInProgress) {
      this.migrationInProgress = false;
      void this.storage.loadConversations(this.host()).then((history: NativeConversationState) => {
        this.history = history;
      }).catch(() => { this.toast('无法读取导入的对话'); });
    }
  }

  onPageHide(): void {
    if (this.replies.length && !this.deletingSessions) {
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
    this.replies.forEach((reply: NativeReply) => { this.cancelReply(reply.sessionId); });
    this.stopVoice();
    this.speaker.destroy();
    this.accountController.cancel();
  }

  onBackPress(): boolean {
    if (this.imagePreview) {
      this.imagePreview = '';
    } else if (this.authorizing) {
      this.cancelAuthorization();
    } else if (this.shareImportVisible) {
      this.closeShareImport();
    } else if (this.settingsVisible) {
      if (this.settingsSection === 'root') {
        this.settingsVisible = false;
      } else {
        this.settingsSection = 'root';
      }
    } else if (this.renamingId) {
      this.renamingId = '';
    } else if (this.selecting) {
      this.resetSelection();
    } else if (this.drawerOpen) {
      this.setDrawer(false);
    } else if (this.editId) {
      this.editId = '';
    } else if (!this.authenticated() && this.onboardingView !== 'home') {
      this.onboardingView = 'home';
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
        this.account = await loadNativeAccount();
        if (this.account && !this.settings.apiKey) {
          this.settings.authMode = 'deepseek-account';
        }
        void this.refreshBalance();
      } catch {
        this.toast('无法读取已保存的服务设置');
      }
      this.loaded = true;
      this.applyTheme();
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

  private settingsSnapshot(): NativeSettings {
    return {
      baseUrl: this.settings.baseUrl, apiKey: this.settings.apiKey, model: this.settings.model,
      protocol: this.settings.protocol, thinking: this.settings.thinking, search: this.settings.search,
      ttsMuted: this.settings.ttsMuted, authMode: this.settings.authMode,
      theme: this.settings.theme, chatFontSize: this.settings.chatFontSize,
      attachmentBinding: this.settings.attachmentBinding,
    };
  }

  private async saveSettings(): Promise<void> {
    try {
      await this.settingsStore.save(this.host(), this.settingsSnapshot());
    } catch {
      this.toast('无法保存设置');
    }
  }

  private applyTheme(): void {
    const mode = this.settings.theme === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      this.settings.theme === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      this.host().getApplicationContext().setColorMode(mode);
    } catch {
      this.toast('无法应用外观设置');
    }
  }

  private accountToken(): string {
    return this.settings.authMode === 'deepseek-account' ? this.account?.token ?? '' : '';
  }

  private authenticated(): boolean {
    return !!this.settings.apiKey || !!this.accountToken();
  }

  private async refreshBalance(): Promise<void> {
    const token = this.accountToken();
    const key = this.settings.apiKey;
    const binding = this.settings.attachmentBinding;
    if (binding !== this.balanceBinding || (!token && !key)) {
      this.balance = null;
      this.balanceFetchedAt = 0;
      this.balanceBinding = binding;
    }
    if ((!token && !key) || Date.now() - this.balanceFetchedAt < 15000) {
      return;
    }
    this.balanceFetchedAt = Date.now();
    const request = ++this.balanceRequest;
    const balance = token ? await this.accountController.fetchBalance(token, 'zh_CN') :
      await fetchNativeProviderBalance(this.settings.baseUrl, key, 'zh_CN');
    if (this.settings.attachmentBinding === binding && request === this.balanceRequest && balance) {
      this.balance = balance;
    }
  }

  private async connectKey(credential: NativeApiCredential): Promise<void> {
    const settings = this.settingsSnapshot();
    settings.apiKey = credential.apiKey;
    settings.baseUrl = credential.baseUrl;
    settings.model = credential.model;
    settings.protocol = credential.protocol;
    settings.authMode = 'api-key';
    settings.attachmentBinding = util.generateRandomUUID(true);
    await this.settingsStore.save(this.host(), settings);
    this.settings = settings;
    this.onboardingView = 'home';
    void this.refreshBalance();
  }

  private openCredentialForm(): void {
    this.settingsKey = '';
    this.settingsBase = this.settings.baseUrl;
    this.settingsModel = this.settings.model;
    this.settingsProtocol = this.settings.protocol;
    this.settingsError = '';
    this.settingsSection = 'key';
  }

  private async verifySettingsKey(): Promise<void> {
    if (this.settingsVerifying || !this.settingsKey.trim()) {
      return;
    }
    const credential: NativeApiCredential = {
      apiKey: this.settingsKey.trim(), baseUrl: this.settingsBase.trim(),
      model: this.settingsModel.trim(), protocol: this.settingsProtocol,
    };
    this.settingsVerifying = true;
    this.settingsError = '';
    try {
      await verifyNativeApiCredential(credential);
      await this.connectKey(credential);
      this.settingsKey = '';
      this.settingsSection = 'account';
    } catch (error) {
      this.settingsError = (error as Error).message;
    } finally {
      this.settingsVerifying = false;
    }
  }

  private async startAuthorization(): Promise<void> {
    if (this.authorizing) {
      return;
    }
    this.authorizing = true;
    this.authorizationUrl = '';
    this.authorizationStatus = '正在连接 DeepSeek 开放平台…';
    const attempt = ++this.authAttempt;
    try {
      const challenge = await this.accountController.startLogin(this.host(), 'zh_CN');
      if (attempt === this.authAttempt) {
        this.authorizationStatus = '请登录并授权 Nuwa 使用你的 DeepSeek API 账号';
        this.authorizationUrl = challenge.authorizeUrl;
      }
    } catch (error) {
      if (attempt === this.authAttempt) {
        this.cancelAuthorization();
        this.toast((error as Error).message || '无法连接 DeepSeek 开放平台');
      }
    }
  }

  private cancelAuthorization(): void {
    if (this.storingAccount) {
      return;
    }
    this.authAttempt++;
    this.accountController.cancel();
    this.authorizationUrl = '';
    this.authorizing = false;
  }

  private interceptAuthorization(target: string): boolean {
    if (this.accountController.isRedirect(target)) {
      void this.consumeAuthorization(target, this.authAttempt);
      return true;
    }
    try {
      const location = url.URL.parseURL(target);
      return location.protocol !== 'https:' || location.hostname !== 'platform.deepseek.com' ||
        !!location.username || !!location.password || (!!location.port && location.port !== '443');
    } catch {
      return true;
    }
  }

  private async consumeAuthorization(target: string, attempt: number): Promise<void> {
    this.authorizationStatus = '正在确认授权…';
    try {
      const account = await this.accountController.handleRedirect(target);
      if (!account || attempt !== this.authAttempt) {
        return;
      }
      this.storingAccount = true;
      try {
        await saveNativeAccount(account);
      } finally {
        this.storingAccount = false;
      }
      const settings = this.settingsSnapshot();
      settings.authMode = 'deepseek-account';
      settings.attachmentBinding = util.generateRandomUUID(true);
      this.account = account;
      this.settings = settings;
      this.onboardingView = 'home';
      this.cancelAuthorization();
      void this.saveSettings();
      void this.refreshBalance();
    } catch (error) {
      if (attempt === this.authAttempt) {
        this.cancelAuthorization();
        this.toast((error as Error).message || 'DeepSeek 授权失败');
      }
    }
  }

  private async enableAccount(): Promise<void> {
    if (!this.account) {
      return;
    }
    const settings = this.settingsSnapshot();
    settings.authMode = 'deepseek-account';
    settings.attachmentBinding = util.generateRandomUUID(true);
    try {
      await this.settingsStore.save(this.host(), settings);
      this.settings = settings;
      void this.refreshBalance();
    } catch {
      this.toast('无法保存设置');
    }
  }

  private async logoutAccount(): Promise<void> {
    const account = this.account;
    try {
      await saveNativeAccount(null);
      this.account = null;
      this.balance = null;
      this.settings.authMode = 'api-key';
      this.settings.attachmentBinding = util.generateRandomUUID(true);
      await this.saveSettings();
      if (!this.authenticated()) {
        this.settingsVisible = false;
      }
      void this.accountController.logout(account?.token ?? '', 'zh_CN');
    } catch {
      this.toast('退出登录失败，请重试');
    }
  }

  private async openLink(target: string): Promise<void> {
    try {
      await this.host().openLink(target, { appLinkingOnly: false });
    } catch {
      this.toast('无法打开链接');
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
    if (this.backupBusy) {
      return;
    }
    if (this.history.activeId !== id) {
      this.drafts.set(this.history.activeId ?? '', { text: this.draft, files: this.draftFiles });
      this.stopVoice();
      this.history = selectConversation(this.history, id);
      this.restoreDraft(id ?? '');
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

  private async deleteSessions(ids: string[], deleteAll: boolean = false): Promise<void> {
    if (!ids.length || this.backupBusy) {
      return;
    }
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: deleteAll ? '删除所有对话' : ids.length === 1 ? '删除对话' : `删除 ${ids.length} 个对话`,
        message: deleteAll ? '本地保存的附件及未发送的草稿也将被删除。' : '删除后将无法恢复。',
        buttons: [{ text: '取消', color: '#61666B' }, { text: '删除', color: '#EC1313' }],
      });
      if (result.index === 1 && !this.backupBusy) {
        await this.removeConversations(ids, deleteAll);
      }
    } catch {
      this.toast('删除对话失败，请重试');
    }
  }

  private async removeConversations(ids: string[], deleteAll: boolean): Promise<void> {
    this.backupBusy = true;
    this.deletingSessions = true;
    try {
      const context = this.host();
      const previous = this.history;
      const active = previous.activeId;
      const deleted = new Set<string>(ids);
      const candidates = new Map<string, NativeAttachment>();
      const retained = new Set<string>();
      for (const session of previous.sessions) {
        for (const message of session.messages) {
          for (const file of message.files ?? []) {
            if (deleted.has(session.id)) {
              candidates.set(file.id, file);
            } else {
              retained.add(file.id);
            }
          }
        }
      }
      const draftIds = new Set<string>(Array.from(this.drafts.keys()));
      draftIds.add(active ?? '');
      for (const id of draftIds) {
        for (const file of this.draftItems(id)) {
          if (deleteAll || deleted.has(id)) {
            candidates.set(file.item.id, file.item);
          } else {
            retained.add(file.item.id);
          }
        }
      }
      for (const id of ids) {
        this.cancelReply(id);
      }
      const next = deleteConversations(this.historyWithPartialReplies(), ids);
      await this.storage.saveConversations(context, next);
      this.history = deleteConversations(this.history, ids);
      await this.save(context);
      for (const id of draftIds) {
        if (deleteAll || deleted.has(id)) {
          this.drafts.delete(id);
        }
      }
      if (active !== next.activeId || deleteAll) {
        this.stopVoice();
        this.restoreDraft(next.activeId ?? '');
      }
      this.resetSelection();
      for (const file of candidates.values()) {
        if (file.local && !retained.has(file.id)) {
          await this.attachments.remove(context, file).catch(() => {});
        }
      }
    } finally {
      this.backupBusy = false;
      this.deletingSessions = false;
    }
  }

  private allPinned(): boolean {
    return this.selectedIds.length > 0 && this.selectedIds.every((id: string): boolean => !!this.session(id)?.pinnedAt);
  }

  private cancelReply(id: string | null = this.history.activeId): void {
    const reply = this.reply(id);
    if (reply) {
      reply.stopped = true;
      reply.uploadingIds.forEach((fileId: string) => { this.attachments.cancelUpload(fileId); });
      reply.client.cancel();
    }
  }

  private restoreDraft(id: string): void {
    const draft = this.drafts.get(id);
    this.draft = draft?.text ?? '';
    this.draftFiles = draft?.files ?? [];
  }

  private draftItems(id: string): NativeDraftAttachment[] {
    return (this.history.activeId ?? '') === id ? this.draftFiles : this.drafts.get(id)?.files ?? [];
  }

  private updateDraftItems(id: string, items: NativeDraftAttachment[]): void {
    if ((this.history.activeId ?? '') === id) {
      this.draftFiles = items;
    } else if (this.drafts.has(id) || id === '' || this.session(id)) {
      this.drafts.set(id, { text: this.drafts.get(id)?.text ?? '', files: items });
    }
  }

  private requestConfig(): NativeChatConfig {
    return {
      baseUrl: this.settings.baseUrl.trim(), model: this.settings.model.trim(), apiKey: this.settings.apiKey.trim(),
      protocol: this.settings.protocol, thinking: this.settings.thinking, search: this.settings.search,
      accountToken: this.accountToken(),
    };
  }

  private async pickFiles(): Promise<void> {
    if (this.pickingFiles || this.backupBusy) {
      return;
    }
    const config = this.requestConfig();
    if (!config.accountToken && config.protocol !== 'anthropic') {
      this.toast('当前服务不支持附件，请配置 Anthropic 接口');
      return;
    }
    const id = this.history.activeId ?? '';
    const context = this.host();
    this.pickingFiles = true;
    try {
      const items = await this.attachments.pick(context, this.draftItems(id).length);
      if (!this.authenticated() || (id && !this.session(id))) {
        items.forEach((file: NativeAttachment) => { void this.attachments.remove(context, file).catch(() => {}); });
        return;
      }
      const drafts = items.map<NativeDraftAttachment>((item: NativeAttachment): NativeDraftAttachment => ({
        item, state: 'uploading', error: '',
      }));
      this.updateDraftItems(id, [...this.draftItems(id), ...drafts]);
      drafts.forEach((file: NativeDraftAttachment) => { void this.uploadDraftFile(id, file.item); });
    } catch (error) {
      this.toast((error as Error).message || '添加附件失败');
    } finally {
      this.pickingFiles = false;
    }
  }

  private async uploadDraftFile(draftId: string, item: NativeAttachment): Promise<void> {
    const config = this.requestConfig();
    const binding = this.settings.attachmentBinding;
    this.replaceDraftFile(draftId, item, 'uploading', '');
    try {
      item.serverId = await this.attachments.upload(this.host(), config, item);
      item.serverBinding = binding;
      this.replaceDraftFile(draftId, item, 'ready', '');
    } catch (error) {
      this.replaceDraftFile(draftId, item, 'failed', (error as Error).message || '上传失败');
    }
  }

  private replaceDraftFile(draftId: string, item: NativeAttachment, state: 'uploading' | 'ready' | 'failed', error: string): void {
    this.updateDraftItems(draftId, this.draftItems(draftId).map((existing: NativeDraftAttachment): NativeDraftAttachment =>
      existing.item.id === item.id ? { item, state, error } : existing));
  }

  private removeDraftFile(item: NativeAttachment): void {
    const id = this.history.activeId ?? '';
    this.updateDraftItems(id, this.draftItems(id).filter((file: NativeDraftAttachment): boolean => file.item.id !== item.id));
    void this.attachments.remove(this.host(), item).catch(() => { this.toast('删除本地附件失败'); });
  }

  private canSendDraft(): boolean {
    return (!this.draftFiles.length || !!this.accountToken() || this.settings.protocol === 'anthropic') && !this.recognitionId && !this.backupBusy && (!!this.draft.trim() || this.draftFiles.length > 0) &&
      this.draftFiles.every((file: NativeDraftAttachment): boolean => file.state === 'ready');
  }

  private async prepareMessages(context: common.UIAbilityContext, session: NativeConversation, config: NativeChatConfig,
    reply: NativeReply): Promise<NativeChatMessage[]> {
    const messages: NativeChatMessage[] = [];
    const path = visibleMessages(session);
    const prompt = path[path.length - 2];
    for (let index = 0; index < path.length - 1; index++) {
      const message = path[index];
      const previous = path[index - 1];
      const next = path[index + 1];
      if (message.role === 'user' && message.id !== prompt?.id && !this.usableContextReply(next)) {
        continue;
      }
      if (message.role === 'assistant' && (!this.usableContextReply(message) || previous?.role !== 'user' ||
        messages[messages.length - 1]?.role !== 'user')) {
        continue;
      }
      const files: NativeChatFileRef[] = [];
      if (config.accountToken || config.protocol === 'anthropic') {
        const attachments = message.files?.slice() ?? [];
        for (let index = 0; index < attachments.length; index++) {
          if (reply.stopped) {
            return [];
          }
          let file = attachments[index];
          if (!file.local) {
            const hydrated = await hydrateImportedAttachment(context, session, file);
            if (!hydrated) {
              continue;
            }
            const current = this.session(session.id);
            if (!current || reply.stopped) {
              await this.attachments.remove(context, hydrated).catch(() => {});
              return [];
            }
            file = hydrated;
            attachments[index] = file;
            message.files = attachments;
            this.history = upsertConversation(this.history, updateConversationMessage(current, message));
          }
          if (file.serverBinding !== reply.attachmentBinding || !file.serverId) {
            reply.uploadingIds.push(file.id);
            try {
              file.serverId = await this.attachments.upload(context, config, file);
              file.serverBinding = reply.attachmentBinding;
            } finally {
              reply.uploadingIds = reply.uploadingIds.filter((id: string): boolean => id !== file.id);
            }
          }
          if (file.serverId) {
            files.push({ serverId: file.serverId, isImage: file.isImage });
          }
        }
      }
      if (message.content || files.length) {
        messages.push({ role: message.role, content: message.content, files });
      }
    }
    return messages;
  }

  private usableContextReply(message: NativeConversationMessage | undefined): boolean {
    return !!message && message.role === 'assistant' && !!message.content &&
      (message.status === 'done' || message.status === 'stopped');
  }

  private startReply(session: NativeConversation, parentId: string | null,
    prompt?: NativeConversationMessage, clearDraft: boolean = false): void {
    if (!this.loaded || this.backupBusy || this.reply(session.id)) {
      return;
    }
    const config = this.requestConfig();
    if (!config.accountToken && (!config.baseUrl || !config.model || !config.apiKey)) {
      this.openSettings('account');
      return;
    }
    const message = createConversationMessage('assistant', '', '', Date.now(), 'pending', config.accountToken ? 'deepseek-flash' : config.model);
    const next = appendBranch(session, parentId, prompt ? [prompt, message] : [message]);
    const reply: NativeReply = {
      sessionId: next.id, message, client: new NativeChatClient(), stopped: false, uploadingIds: [],
      attachmentBinding: this.settings.attachmentBinding,
    };
    this.replies = [...this.replies, reply];
    if (clearDraft) {
      const draftId = this.history.activeId ?? '';
      this.drafts.delete(draftId);
      this.draft = '';
      this.draftFiles = [];
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
      const messages = await this.prepareMessages(context, session, config, reply);
      if (reply.stopped) {
        return;
      }
      await reply.client.send(config, messages, (content: string, reasoning: string) => {
        if (this.history.activeId === session.id && this.visible && this.scroller.isAtEnd()) {
          this.scrollToLatest();
        }
        reply.message.content += content;
        reply.message.reasoning += reasoning;
        this.replies = Array.from(this.replies);
        if (!this.deletingSessions && Date.now() - this.lastStreamSave > 1500) {
          this.lastStreamSave = Date.now();
          void this.save(context);
        }
      });
    } catch (cause) {
      error = !reply.stopped;
      if (error && this.history.activeId === session.id) {
        this.status = (cause as Error).message || '请求失败';
      }
    } finally {
      const current = this.session(session.id);
      if (current) {
        const message = this.streamMessage(reply, error ? 'error' : reply.stopped ? 'stopped' : 'done');
        this.history = upsertConversation(this.history, updateConversationMessage(current, message));
        if (!this.deletingSessions) {
          void this.save(context);
        }
        if (!error && !reply.stopped && !this.settings.ttsMuted && this.history.activeId === current.id && message.content) {
          this.readMessage(message);
        }
      }
      this.replies = this.replies.filter((item: NativeReply): boolean => item.sessionId !== reply.sessionId);
      if (!error && reply.attachmentBinding === this.settings.attachmentBinding) {
        setTimeout(() => { void this.refreshBalance(); }, 2500);
      }
    }
  }

  private sendDraft(): void {
    const text = this.draft.trim();
    if (!this.canSendDraft()) {
      return;
    }
    const session = this.session() ?? createConversation();
    const thread = visibleMessages(session);
    const message = createConversationMessage('user', text, '');
    message.files = this.draftFiles.map<NativeAttachment>((file: NativeDraftAttachment): NativeAttachment => file.item);
    this.startReply(session, thread.length ? thread[thread.length - 1].id : null, message, true);
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
    if (session && (text || message.files?.length) && !this.reply()) {
      this.editId = '';
      const edited = createConversationMessage('user', text, '');
      edited.files = message.files;
      this.startReply(session, message.parentId, edited);
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
        if (this.viewportWidth >= 400 || (!this.draft.trim() && !this.draftFiles.length && this.viewportWidth >= 360)) {
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

  private attachmentPreview(item: NativeAttachment): string {
    if (!item.isImage) {
      return '';
    }
    if (!item.local) {
      const session = this.session();
      return session ? importedAttachmentPreview(session, item) : '';
    }
    try {
      return this.attachments.previewUri(this.host(), item);
    } catch {
      return '';
    }
  }

  @Builder
  private addAttachmentButton() {
    this.iconButton($r('app.media.native_add'), '上传附件', () => { void this.pickFiles(); },
      34, 22, $r('app.color.native_chat_primary'), Color.Transparent, !this.pickingFiles && !this.backupBusy)
  }

  @Builder
  private attachmentTile(item: NativeAttachment, size: number) {
    if (this.attachmentPreview(item)) {
      Image(this.attachmentPreview(item)).width(size).height(size).objectFit(ImageFit.Cover)
        .borderRadius(12).draggable(false).accessibilityText(item.name)
        .onClick(() => { this.imagePreview = this.attachmentPreview(item); })
    } else {
      Row({ space: 8 }) {
        Image($r('app.media.native_file')).width(20).height(20).fillColor($r('app.color.native_chat_secondary'))
        Text(item.name).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(12)
          .fontColor($r('app.color.native_chat_primary')).layoutWeight(1)
      }
      .width(148).height(size).padding({ left: 10, right: 10 }).borderRadius(12)
      .backgroundColor($r('app.color.native_chat_field')).accessibilityText(item.name)
    }
  }

  @Builder
  private draftAttachmentStrip() {
    if (this.draftFiles.length) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.draftFiles, (file: NativeDraftAttachment) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              this.attachmentTile(file.item, 62)
              if (file.state === 'uploading') {
                Row() { LoadingProgress().width(20).height(20).color(Color.White) }
                .width('100%').height('100%').justifyContent(FlexAlign.Center)
                .backgroundColor('#55000000').borderRadius(12).accessibilityText('正在上传')
              } else if (file.state === 'failed') {
                Column({ space: 2 }) {
                  this.iconButton($r('app.media.native_retry'), '重试上传', () => {
                    void this.uploadDraftFile(this.history.activeId ?? '', file.item);
                  }, 24, 16, Color.White)
                  Text('上传失败').fontSize(10).fontColor(Color.White).maxLines(1)
                }
                .width('100%').height('100%').justifyContent(FlexAlign.Center)
                .backgroundColor('#88000000').border({ width: 1, color: $r('app.color.native_chat_error') }).borderRadius(12)
                .accessibilityDescription(file.error)
              }
              Row() {
                this.iconButton($r('app.media.native_close'), '移除附件', () => { this.removeDraftFile(file.item); },
                  18, 12, Color.White, '#990F1115')
              }
              .margin({ top: 3, right: 3 })
            }
            .width(this.attachmentPreview(file.item) ? 62 : 148).height(62)
          }, (file: NativeDraftAttachment): string => `${file.item.id}:${file.state}`)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal).width('100%').height(64).scrollBar(BarState.Off)
      .margin({ top: 10 })
    }
  }

  @Builder
  private composer() {
    Column({ space: 2 }) {
      this.draftAttachmentStrip()
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
        Row({ space: this.compact() ? 4 : 6 }) {
          if (this.reply()) {
            this.addAttachmentButton()
            this.iconButton($r('app.media.native_stop'), '停止生成', () => { this.stopVoice(); this.cancelReply(); },
              34, 16, Color.White, $r('app.color.native_chat_blue'))
          } else if (this.draft.trim() || this.draftFiles.length) {
            this.voiceButton()
            this.addAttachmentButton()
            this.iconButton($r('app.media.native_send'), '发送', () => { this.sendDraft(); },
              34, 16, Color.White, $r('app.color.native_chat_blue'), this.loaded && this.canSendDraft())
          } else {
            this.addAttachmentButton()
            this.voiceButton()
          }
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
            Button('发送').enabled(!!this.editText.trim() || !!message.files?.length).onClick(() => { this.edit(message); })
          }
          .width('100%').justifyContent(FlexAlign.End).padding(6)
        }
        .width('100%').borderRadius(22).border({ width: 1, color: $r('app.color.native_chat_blue') })
      } else {
        if (message.files?.length) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach(message.files, (file: NativeAttachment) => { this.attachmentTile(file, 68) },
              (file: NativeAttachment): string => file.id)
          }
          .width('100%')
        }
        if (message.content) {
          Text(message.content).fontSize(this.settings.chatFontSize).lineHeight(this.settings.chatFontSize * 1.5).fontColor($r('app.color.native_chat_primary'))
          .constraintSize({ maxWidth: Math.max(140, Math.min(this.viewportWidth - 40, 752) - 68) })
          .padding({ left: 16, right: 16, top: 10, bottom: 10 }).borderRadius(22)
            .backgroundColor($r('app.color.native_chat_bubble')).copyOption(CopyOptions.LocalDevice)
        }
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
      NativeMarkdown({ content: text, fontScale: this.settings.chatFontSize / 16 })
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
        if (this.shareTemplate(message)) {
          NativeMarkdown({ content: this.shareTemplate(message), fontScale: this.settings.chatFontSize / 16 })
        }
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

  private openSettings(section: string = 'root'): void {
    this.settingsSection = section;
    this.settingsVisible = true;
  }

  private async importChatHistory(): Promise<void> {
    if (this.backupBusy || this.replies.length > 0) {
      this.toast('请在回复结束后导入');
      return;
    }
    this.backupBusy = true;
    try {
      const context = this.host();
      const sessions = await this.backup.importFromPicker(context);
      if (sessions) {
        const merged = mergeChatBackup(this.history, sessions);
        await this.storage.saveConversations(context, merged.history);
        this.history = merged.history;
        this.toast(merged.importedCount ? `已导入 ${merged.importedCount} 个对话` : '没有新增对话');
      }
    } catch (error) {
      this.toast((error as Error).message || '文件导入失败');
    } finally {
      this.backupBusy = false;
    }
  }

  private async exportChatHistory(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    try {
      if (await this.backup.exportToPicker(this.host(), this.historyWithPartialReplies().sessions)) {
        this.toast('已导出历史对话');
      }
    } catch (error) {
      this.toast((error as Error).message || '导出失败');
    } finally {
      this.backupBusy = false;
    }
  }

  private async openHistoryMigration(): Promise<void> {
    if (this.backupBusy || this.replies.length > 0) {
      this.toast('请在回复结束后迁移');
      return;
    }
    this.settingsVisible = false;
    this.migrationInProgress = true;
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Index', params: { migrate: true } });
    } catch {
      this.migrationInProgress = false;
      this.toast('无法打开历史迁移');
    }
  }

  private openShareImport(): void {
    if (this.backupBusy) {
      return;
    }
    this.shareInput = '';
    this.shareImportError = '';
    this.settingsVisible = false;
    this.shareImportVisible = true;
  }

  private closeShareImport(): void {
    if (!this.backupBusy) {
      this.shareImportVisible = false;
      this.openSettings('data');
    }
  }

  private async acceptShareImport(): Promise<void> {
    if (!this.shareInput.trim() || this.backupBusy) {
      return;
    }
    if (this.replies.length > 0) {
      this.shareImportError = '请在回复结束后导入';
      return;
    }
    this.backupBusy = true;
    this.shareImportError = '';
    try {
      const imported = await importNativeShareLink(this.shareInput);
      const context = this.host();
      const next = upsertConversation(this.history, imported, true);
      await this.storage.saveConversations(context, next);
      this.drafts.set(this.history.activeId ?? '', { text: this.draft, files: this.draftFiles });
      this.history = next;
      this.restoreDraft(imported.id);
      this.shareImportVisible = false;
      this.shareInput = '';
      this.scrollToLatest();
      this.toast('已导入 1 个对话');
    } catch (error) {
      this.shareImportError = (error as Error).message || '该分享链接无法导入';
    } finally {
      this.backupBusy = false;
    }
  }

  @Builder
  private shareImportDialog() {
    Column({ space: 14 }) {
      Text('通过 DeepSeek 分享链接导入').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        .fontColor($r('app.color.native_chat_primary'))
      TextArea({ text: this.shareInput, placeholder: '粘贴分享链接或包含链接的完整分享文案，例如：https://chat.deepseek.com/share/...' })
        .height(96).width('100%').fontSize(14).enabled(!this.backupBusy).maxLength(4096).borderRadius(14)
        .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
        .onChange((text: string) => { this.shareInput = text; this.shareImportError = ''; })
      if (this.shareImportError) {
        Text(this.shareImportError).width('100%').fontColor($r('app.color.native_chat_error')).fontSize(13)
      }
      Row({ space: 8 }) {
        Button('取消', { buttonStyle: ButtonStyleMode.TEXTUAL }).enabled(!this.backupBusy)
          .onClick(() => { this.closeShareImport(); })
        Button(this.backupBusy ? '导入中…' : '确认导入').enabled(!this.backupBusy && !!this.shareInput.trim())
          .backgroundColor($r('app.color.native_chat_blue')).onClick(() => { void this.acceptShareImport(); })
      }
      .width('100%').justifyContent(FlexAlign.End)
    }
    .width('86%').constraintSize({ maxWidth: 440 }).padding(20).borderRadius(22)
    .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  }

  private shareTemplate(message: NativeConversationMessage): string {
    const session = this.session();
    return session ? nativeShareTemplate(session, message.id) : '';
  }

  private async checkUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const update = await checkNativeUpdate();
      if (!update.hasUpdate) {
        this.toast('当前已是最新版本');
        return;
      }
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: `发现新版本 v${update.latestVersion}`,
        message: `当前版本：v${update.currentVersion}\n\n${update.notes || '包含体验优化与问题修复。'}`,
        buttons: [{ text: '暂不更新', color: '#61666B' }, { text: '前往下载', color: '#3964FE' }],
      });
      if (result.index === 1) {
        await this.openLink(update.appGalleryUrl ?? update.downloadUrl ?? update.releaseUrl);
      }
    } catch {
      this.toast('检查更新失败，请稍后重试');
    } finally {
      this.checkingUpdate = false;
    }
  }

  private async loadReleaseNotes(): Promise<void> {
    if (this.notesLoading) {
      return;
    }
    this.notesLoading = true;
    this.notesError = false;
    try {
      this.releaseNotes = await fetchNativeReleaseHistory();
    } catch {
      this.notesError = true;
    } finally {
      this.notesLoading = false;
    }
  }

  @Builder
  private releaseNotesPage() {
    if (this.notesLoading) {
      LoadingProgress().width(26).height(26).color($r('app.color.native_chat_blue'))
    } else if (this.notesError) {
      Text('加载更新日志失败，请稍后重试').width('100%').fontColor($r('app.color.native_chat_secondary'))
      Button('重试', { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { void this.loadReleaseNotes(); })
    } else if (!this.releaseNotes.length) {
      Text('暂无历史版本记录').width('100%').fontColor($r('app.color.native_chat_secondary'))
    } else {
      ForEach(this.releaseNotes, (release: NativeReleaseHistoryItem) => {
        Column({ space: 10 }) {
          Row() {
            Text(`v${release.version}`).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.native_chat_primary')).layoutWeight(1)
            Text(release.createdAt.slice(0, 10)).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
          }
          .width('100%')
          Text(release.changelog || '包含体验优化与问题修复。').width('100%').fontSize(14).lineHeight(22)
            .fontColor($r('app.color.native_chat_secondary')).copyOption(CopyOptions.LocalDevice)
        }
        .width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.native_chat_surface'))
      }, (release: NativeReleaseHistoryItem): string => release.id)
    }
  }

  private settingsTitle(): string {
    switch (this.settingsSection) {
      case 'account': return '账号管理';
      case 'key': return '更换 API Key';
      case 'data': return '数据管理';
      case 'notes': return '更新日志';
      default: return '设置';
    }
  }

  @Builder
  private configInput(value: string, placeholder: string, inputType: InputType, change: (value: string) => void) {
    TextInput({ text: value, placeholder: placeholder }).width('100%').height(46).type(inputType).fontSize(14)
      .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
      .placeholderColor($r('app.color.native_chat_caption')).onChange(change)
  }

  @Builder
  private settingsLabel(title: string) {
    Text(title).width('100%').fontSize(12).fontColor($r('app.color.native_chat_secondary')).padding({ left: 9, bottom: 4 })
  }

  @Builder
  private settingsRow(title: string, value: string, click: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Text(title).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        if (value) {
          Text(value).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '45%' }).fontColor($r('app.color.native_chat_secondary'))
        }
        Image($r('app.media.native_chevron_right')).width(14).height(14).fillColor($r('app.color.native_chat_caption'))
      }
      .width('100%').padding({ left: 15, right: 12 })
    }
    .height(48).width('100%').padding(0).borderRadius(0).backgroundColor(Color.Transparent).onClick(click)
  }

  @Builder
  private settingsRoot() {
    this.settingsLabel('账户')
    Column() {
      this.settingsRow('账号管理', this.accountToken() ? this.account?.label ?? 'DeepSeek API 账号' : this.settings.model,
        () => { this.settingsSection = 'account'; void this.refreshBalance(); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow('API 余额', this.balance?.formatted ?? '前往充值',
        () => { void this.openLink('https://platform.deepseek.com/top_up'); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow('数据管理', `${this.history.sessions.length} 条对话`, () => { this.settingsSection = 'data'; })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel('应用')
    Column() {
      Row() {
        Text('外观').layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '系统' }, { value: '浅色' }, { value: '深色' }])
          .selected(this.settings.theme === 'dark' ? 2 : this.settings.theme === 'light' ? 1 : 0)
          .value(this.settings.theme === 'dark' ? '深色' : this.settings.theme === 'light' ? '浅色' : '系统')
          .onSelect((index: number) => {
            this.settings.theme = index === 2 ? 'dark' : index === 1 ? 'light' : 'system';
            this.applyTheme();
            void this.saveSettings();
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      Row() {
        Text('字体大小').layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '12px' }, { value: '14px' }, { value: '16px（默认）' },
          { value: '18px' }, { value: '20px' }, { value: '22px' }])
          .selected(NATIVE_CHAT_FONT_SIZES.indexOf(this.settings.chatFontSize))
          .value(this.settings.chatFontSize === 16 ? '16px（默认）' : `${this.settings.chatFontSize}px`)
          .onSelect((index: number) => {
            this.settings.chatFontSize = NATIVE_CHAT_FONT_SIZES[index] ?? 16;
            void this.saveSettings();
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel('语音')
    Row() {
      Text('语音引擎').layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
      Text('设备原生').fontSize(13).fontColor($r('app.color.native_chat_secondary'))
    }
    .width('100%').height(48).padding({ left: 15, right: 12 }).borderRadius(16)
    .backgroundColor($r('app.color.native_chat_surface'))
    Text('语音输入与回答朗读由鸿蒙系统语音服务处理').width('100%').fontSize(12)
      .fontColor($r('app.color.native_chat_secondary')).padding({ left: 9 })
    this.settingsLabel('关于')
    Column() {
      Row() {
        Text('当前版本').layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Text(this.appVersion).fontSize(13).fontColor($r('app.color.native_chat_secondary'))
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(this.checkingUpdate ? '检查中...' : '检查更新', '', () => { void this.checkUpdate(); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow('隐私政策', '', () => { void openNuwaPrivacyPolicy(this.host()).catch(() => { this.toast('无法打开隐私政策'); }); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow('更新日志', '', () => { this.settingsSection = 'notes'; void this.loadReleaseNotes(); })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private accountSettings() {
    this.settingsLabel('DeepSeek API 账号')
    Column() {
      if (this.account) {
        Text(this.accountToken() ? `当前生效：${this.account.label}` : `已登录：${this.account.label}`)
          .width('100%').fontSize(14).padding(14).fontColor($r('app.color.native_chat_secondary'))
        if (!this.accountToken()) {
          this.settingsRow('切换为此账号', '', () => { void this.enableAccount(); })
        }
        this.settingsRow('退出登录', '', () => { void this.logoutAccount(); })
      } else {
        Text('通过 DeepSeek 开放平台授权登录，免手动复制 API Key')
          .width('100%').fontSize(14).padding(14).fontColor($r('app.color.native_chat_secondary'))
        this.settingsRow('账号登录', '', () => { this.settingsVisible = false; void this.startAuthorization(); })
      }
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel('API Key')
    Column() {
      this.settingsRow(this.settings.apiKey ? '更换 API Key' : '配置第三方兼容 API', this.settings.model,
        () => { this.openCredentialForm(); })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private keySettings() {
    this.settingsLabel('接口协议')
    Select([{ value: 'OpenAI 兼容' }, { value: 'Anthropic 兼容' }])
      .selected(this.settingsProtocol === 'anthropic' ? 1 : 0)
      .value(this.settingsProtocol === 'anthropic' ? 'Anthropic 兼容' : 'OpenAI 兼容')
      .onSelect((index: number) => { this.settingsProtocol = index === 1 ? 'anthropic' : 'openai'; })
    this.settingsLabel('API 地址 (Base URL)')
    this.configInput(this.settingsBase, '例如 https://api.deepseek.com', InputType.Normal,
      (value: string) => { this.settingsBase = value; })
    this.settingsLabel('模型名称')
    this.configInput(this.settingsModel, '例如 deepseek-chat', InputType.Normal,
      (value: string) => { this.settingsModel = value; })
    this.settingsLabel('API Key')
    this.configInput(this.settingsKey, '请输入 API Key', InputType.Password,
      (value: string) => { this.settingsKey = value; })
    if (this.settingsError) {
      Text(this.settingsError).width('100%').fontSize(13).fontColor($r('app.color.native_chat_error'))
    }
    Button(this.settingsVerifying ? '正在验证...' : '验证并继续').width('100%')
      .backgroundColor($r('app.color.native_chat_blue')).enabled(!this.settingsVerifying && !!this.settingsKey.trim())
      .onClick(() => { void this.verifySettingsKey(); })
  }

  @Builder
  private settingsPage() {
    Column() {
      Row() {
        if (this.settingsSection === 'root') {
          Blank().width(38)
        } else {
          this.iconButton($r('app.media.native_chevron_left'), '返回', () => {
            this.settingsSection = this.settingsSection === 'key' ? 'account' : 'root';
          }, 38, 18)
        }
        Text(this.settingsTitle()).layoutWeight(1).textAlign(TextAlign.Center).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary'))
        Button('×', { buttonStyle: ButtonStyleMode.TEXTUAL }).width(38).height(36).padding(0).fontSize(23)
          .fontColor($r('app.color.native_chat_secondary')).accessibilityText('关闭')
          .onClick(() => { this.settingsKey = ''; this.settingsVisible = false; })
      }
      .width('100%').height(50).padding({ left: 12, right: 12 })
      Scroll() {
        Column({ space: 10 }) {
          if (this.settingsSection === 'account') {
            this.accountSettings()
          } else if (this.settingsSection === 'key') {
            this.keySettings()
          } else if (this.settingsSection === 'data') {
            NativeDataSettings({
              busy: this.backupBusy, sessionCount: this.history.sessions.length,
              onMigration: () => { void this.openHistoryMigration(); },
              onShareImport: () => { this.openShareImport(); },
              onImport: () => { void this.importChatHistory(); },
              onExport: () => { void this.exportChatHistory(); },
              onDeleteAll: () => { void this.deleteSessions(this.history.sessions.map<string>(
                (session: NativeConversation): string => session.id), true); },
            })
          } else if (this.settingsSection === 'notes') {
            this.releaseNotesPage()
          } else {
            this.settingsRoot()
          }
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 28 }).alignItems(HorizontalAlign.Start)
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_sidebar'))
  }

  @Builder
  private authorizationPage() {
    Column() {
      Row({ space: 8 }) {
        Text(this.authorizationStatus).fontSize(13).fontColor($r('app.color.native_chat_secondary')).layoutWeight(1)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('关闭', { buttonStyle: ButtonStyleMode.TEXTUAL }).enabled(!this.storingAccount)
          .onClick(() => { this.cancelAuthorization(); })
      }
      .width('100%').padding({ left: 14, right: 8, top: 6, bottom: 6 })
      if (this.authorizationUrl) {
        Web({ src: this.authorizationUrl, controller: this.authBrowser }).width('100%').layoutWeight(1)
          .mixedMode(MixedMode.None).javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
          .onLoadIntercept((event) => { return this.interceptAuthorization(event.data.getRequestUrl()); })
      } else {
        Column() { LoadingProgress().width(30).height(30) }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
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
            Text(this.accountToken() ? this.account?.label ?? 'DeepSeek API 账号' : '设置')
              .fontSize(15).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('app.color.native_chat_primary'))
            if (this.balance) {
              Text(this.balance.formatted).fontSize(12).fontColor($r('app.color.native_chat_blue_text'))
                .onClick(() => { void this.openLink('https://platform.deepseek.com/top_up'); })
            }
            Text('⋯').fontSize(18).fontColor($r('app.color.native_chat_secondary'))
          }
          .width('100%').padding({ left: 6, right: 6 })
        }
        .height(52).width('100%').padding(0).backgroundColor(Color.Transparent)
        .onClick(() => { this.setDrawer(false); this.openSettings(); })
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
        if (this.loaded && !this.authenticated()) {
          NativeOnboarding({
            compact: this.compact(), busy: this.authorizing, view: this.$onboardingView,
            initialUrl: this.settings.baseUrl, initialModel: this.settings.model, initialProtocol: this.settings.protocol,
            onAccount: () => { void this.startAuthorization(); },
            onConnect: (credential: NativeApiCredential): Promise<void> => this.connectKey(credential),
            onHelp: () => { void this.openLink('https://api-docs.deepseek.com/zh-cn/'); },
            onPlatformKeys: () => { void this.openLink('https://platform.deepseek.com/api_keys'); },
          })
        } else {
          this.chatPage()
        }
        if (this.drawerProgress() > 0) {
          Column().width('100%').height('100%').backgroundColor(Color.Transparent)
            .onClick(() => { this.setDrawer(false); })
        }
      }
      .width('100%').height('100%').translate({ x: this.drawerProgress() * this.drawerWidth() })
      .scale({ x: 1 - this.drawerProgress() * 0.05, y: 1 - this.drawerProgress() * 0.05, centerX: '0%' })
      .borderRadius(this.drawerProgress() > 0 ? 24 : 0).clip(this.drawerProgress() > 0)
      if (this.authorizing) {
        this.authorizationPage()
      }
      if (this.imagePreview) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(this.imagePreview).width('100%').height('100%').objectFit(ImageFit.Contain)
            .backgroundColor(Color.Black).onClick(() => { this.imagePreview = ''; })
          Row() {
            this.iconButton($r('app.media.native_close'), '关闭图片', () => { this.imagePreview = ''; },
              42, 22, Color.White, '#660F1115')
          }
          .padding(12)
        }
        .width('100%').height('100%')
      }
      if (this.shareImportVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => { this.closeShareImport(); })
          this.shareImportDialog()
        }
        .width('100%').height('100%')
      }
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
          if (this.authenticated() && !this.settingsVisible && !this.renamingId && !this.authorizing && !this.imagePreview && !this.shareImportVisible &&
            (this.drawerOpen || this.touchStart < 160)) {
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
