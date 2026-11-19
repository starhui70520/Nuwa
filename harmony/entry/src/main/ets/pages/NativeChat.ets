import { nativeIconTint } from '../native/NativeIconTint';
import { common, ConfigurationConstant, wantConstant } from '@kit.AbilityKit';
import { KeyboardAvoidMode, LengthMetrics } from '@kit.ArkUI';
import { url, util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { filePreview } from '@kit.PreviewKit';
import {
  NativeChatClient, NativeChatConfig, NativeChatFileRef, NativeChatMessage, NativeModelError, NativeReplyOutcome,
  usesExtendedNativeRequest,
} from '../native/NativeChatClient';
import { loadNativeAccount, saveNativeAccount } from '../native/NativeAccountStore';
import { allowsKeylessNativeApi, NativeApiCredential, verifyNativeApiCredential } from '../native/NativeApiCredential';
import { NativeDataSettings } from '../native/NativeDataSettings';
import { NativeDeepSeekAccount, NativeDeepSeekAccountController, NativeDeepSeekBalance } from '../native/NativeDeepSeekAccount';
import { NativeOnboarding, NativeOnboardingView } from '../native/NativeOnboarding';
import { NativeAttachment, NativeChatAttachments } from '../native/NativeChatAttachments';
import { hydrateImportedAttachment, importedAttachmentPreview, NativeChatBackup, mergeChatBackup } from '../native/NativeChatBackup';
import { NativeChatCitation, NativeChatSource, NativeChatSources } from '../native/NativeChatSources';
import { NativeSourcesPanel } from '../native/NativeSourcesPanel';
import { NativeToolTimeline, NativeToolTimelineStep, NativeToolTimelineView } from '../native/NativeToolTimeline';
import { NativeToolTimelinePanel } from '../native/NativeToolTimelinePanel';
import { NativeChatStorage } from '../native/NativeChatStorage';
import {
  appendBranch, createConversation, createConversationMessage, deleteConversations, groupConversations,
  messageVersions, NativeConversation, NativeConversationGroup, NativeConversationMessage, NativeConversationState,
  renameConversation, selectConversation, selectMessageVersion, setConversationsPinned, toggleConversationPin,
  updateConversationMessage, upsertConversation, visibleMessages,
} from '../native/NativeConversation';
import { NativeMarkdown } from '../native/NativeMarkdown';
import { NativeMathRendererHost } from '../native/NativeMathRendererHost';
import { NativeDraftStorage, NativeStoredDraft } from '../native/NativeDraftStorage';
import { CHAT_PAGE_SIZE, nativeMessageRange, NativeMessageList, NativeMessageRange, NativeMessageRow } from '../native/NativeMessageList';
import { NativeMigrationPrompt } from '../native/NativeMigrationPrompt';
import { describeNativeReplyFailure, nativeRefusalText, NativeReplyNotice } from '../native/NativeReplyNotice';
import { isOfficialNativeReadLinkRoute, NativeReadLink, NativeReadLinkCollector, useNativeReadLink } from '../native/NativeReadLinks';
import {
  createNativeLatestReminder, defaultNativeLocale, nativeCityOptions, NativeLocationOption,
  nativeProvinceOptions, nativeRegionOptions, NativeUserLocation, usesChineseLocationPicker,
} from '../native/NativeLocation';
import { NativeSettings, NativeSettingsController, NATIVE_CHAT_FONT_SIZES } from '../native/NativeSettings';
import { fetchNativeProviderBalance } from '../native/NativeProviderBalance';
import {
  checkNativeUpdate, fetchNativeReleaseHistory, getNativeCurrentVersion, isUpdateSnoozed, NativeReleaseHistoryItem,
  NativeUpdateCheck, NativeUpdatePreferences, NativeUpdateSchedule, UPDATE_POLL_MS, UPDATE_RESUME_MS,
} from '../native/NativeUpdates';
import { importNativeShareLink, nativeShareTemplate } from '../native/NativeShareImport';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';
import { HarmonySpeechOptions } from '../speech/HarmonySpeechOptions';

interface NativeReply {
  sessionId: string;
  message: NativeConversationMessage;
  client: NativeChatClient;
  stopped: boolean;
  uploadingIds: string[];
  attachmentBinding: string;
  resumeRetry?: () => void;
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

const EMPTY_TIMELINE: NativeToolTimelineView = { steps: [], answer: '', answerOffset: 0 };

@Entry
@Component
struct NativeChat {
  @State @Watch('syncMessageList') private history: NativeConversationState = { sessions: [], activeId: null };
  @State private earlierCount: number = 0;
  @State private laterCount: number = 0;
  @State private settings: NativeSettings = {
    baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat', apiKey: '', protocol: 'openai', authMode: 'api-key',
    theme: 'system', chatFontSize: 16, attachmentBinding: '', thinking: false, search: false, ttsMuted: true,
    speechEngine: 'auto', speechVoice: 'stella', migrationPromptHandled: false,
    desktopSidebarCollapsed: false,
    locale: defaultNativeLocale(), location: null,
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
  @State private migrationPromptVisible: boolean = false;
  @State private transcribing: boolean = false;
  @State private compactToolsOpen: boolean = false;
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
  @State private sourcesVisible: boolean = false;
  @State private panelSources: NativeChatSource[] = [];
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
  private readonly draftStorage = new NativeDraftStorage();
  private readonly draftHistoryWrites = new Map<string, string>();
  private readonly removedDraftFiles = new Map<string, NativeAttachment>();
  private draftStorageReady: boolean = false;
  private draftSaving: boolean = false;
  private draftDirty: boolean = false;
  private draftSaveTimer: number = -1;
  private readonly settingsStore = new NativeSettingsController();
  private readonly updateSchedule = new NativeUpdateSchedule();
  private updatePreferences: NativeUpdatePreferences = { checkAt: 0, dismissedAt: 0, dismissedVersion: '' };
  private pendingUpdate: NativeUpdateCheck | null = null;
  private updateTimer: number = -1;
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
  private readonly messageList = new NativeMessageList();
  private messagePath: NativeConversationMessage[] = [];
  private visibleSession?: NativeConversation;
  private messageRange: NativeMessageRange = { start: 0, end: 0 };
  private messageLimit: number = CHAT_PAGE_SIZE;
  private rangeFromTop: boolean = false;
  private firstVisibleRow: number = 0;
  private listViewportHeight: number = 0;
  private followLatest: boolean = true;
  private anchorTimer: number = -1;
  private readonly drafts: Map<string, NativeDraft> = new Map();
  private visible: boolean = false;
  private scrollTimer: number = -1;
  private lastStreamSave: number = 0;
  private streamFrame: number = -1;
  private touchStart: number = 0;
  private titleTap: number = 0;
  private readonly recognition = new HarmonySpeechRecognition((id: string, state: string, text?: string, code?: string) => {
    if (id !== this.recognitionId) {
      return;
    }
    if (state === 'transcribing') {
      this.transcribing = true;
    } else if (state === 'done' || state === 'error' || state === 'cancelled') {
      this.transcribing = false;
      this.recognitionId = '';
    }
    if (state === 'done' && text) {
      this.updateDraftText(this.draft ? `${this.draft} ${text}` : text);
    } else if (state === 'error') {
      this.toast(this.speechError(code, true));
    }
  });
  private readonly speaker = new HarmonyTextToSpeech((id: string, state: string, code?: string) => {
    if (id === this.readingId && state !== 'playing') {
      this.readingId = '';
      if (state === 'error' || state === 'unavailable') {
        this.toast(this.speechError(code, false));
      }
    }
  });

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    void this.load();
    void getNativeCurrentVersion().then((version: string) => { this.appVersion = version; }).catch(() => {});
    void this.startUpdateChecks();
  }

  onPageShow(): void {
    this.visible = true;
    if (this.replies.length) this.replies = Array.from(this.replies);
    if (this.loaded) {
      void this.refreshBalance();
    }
    if (this.updateTimer >= 0) {
      void this.resumeUpdateChecks();
    }
    if (this.migrationInProgress) {
      this.migrationInProgress = false;
      void this.storage.loadConversations(this.host()).then((history: NativeConversationState) => {
        this.history = history;
      }).catch(() => { this.toast(this.label('无法读取导入的对话', "Unable to load imported chats")); });
    }
  }

  onPageHide(): void {
    if (this.replies.length && !this.deletingSessions) {
      void this.save();
    }
    if (this.draftSaveTimer >= 0) {
      clearTimeout(this.draftSaveTimer);
      this.draftSaveTimer = -1;
    }
    if (this.draftDirty) void this.persistDrafts();
    this.visible = false;
    if (this.streamFrame >= 0) {
      clearTimeout(this.streamFrame);
      this.streamFrame = -1;
    }
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    if (this.anchorTimer >= 0) {
      clearTimeout(this.anchorTimer);
      this.anchorTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.onPageHide();
    this.replies.forEach((reply: NativeReply) => { this.cancelReply(reply.sessionId); });
    this.stopVoice();
    this.speaker.destroy();
    this.accountController.cancel();
    if (this.updateTimer >= 0) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }

  onBackPress(): boolean {
    if (this.imagePreview) {
      this.imagePreview = '';
    } else if (this.authorizing) {
      this.cancelAuthorization();
    } else if (this.sourcesVisible) {
      this.sourcesVisible = false;
    } else if (this.shareImportVisible) {
      this.closeShareImport();
    } else if (this.migrationPromptVisible) {
      if (!this.backupBusy) this.dismissMigrationPrompt();
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
        if (this.account && !this.settings.apiKey &&
          !allowsKeylessNativeApi(this.settings.baseUrl, this.settings.protocol)) {
          this.settings.authMode = 'deepseek-account';
        }
        void this.refreshBalance();
      } catch {
        this.toast(this.label('无法读取已保存的服务设置', 'Unable to load the saved API configuration'));
      }
      await this.loadDrafts(context);
      this.loaded = true;
      this.applyTheme();
      this.scrollToLatest();
    } catch {
      this.status = this.label('无法读取本地会话', "Unable to load local chats");
    }
  }

  private async save(context: common.UIAbilityContext = this.host(), checkpoint: boolean = false): Promise<void> {
    try {
      let snapshot = this.historyWithPartialReplies();
      if (checkpoint) {
        const dirty = this.replies.map<string>((reply: NativeReply): string => reply.sessionId);
        try {
          await this.storage.saveConversations(context, snapshot, dirty);
        } catch {
          snapshot = this.historyWithPartialReplies();
          await this.storage.saveConversations(context, snapshot);
        }
      } else {
        await this.storage.saveConversations(context, snapshot);
      }
      this.acknowledgeSentDrafts(snapshot);
    } catch {
      this.status = this.label('本地会话保存失败，请重试', "Unable to save chats locally. Please try again.");
    }
  }

  private paintLiveReplies(): void {
    if (!this.visible || this.streamFrame >= 0) return;
    this.streamFrame = setTimeout(() => {
      this.streamFrame = -1;
      this.replies = Array.from(this.replies);
      if (this.reply() && this.followLatest && this.laterCount === 0) this.scrollToLatest();
    }, 16);
  }

  private acknowledgeSentDrafts(snapshot: NativeConversationState): void {
    if (!this.draftHistoryWrites.size) return;
    this.draftHistoryWrites.forEach((sessionId: string, replyId: string): void => {
      const session = snapshot.sessions.find((item: NativeConversation): boolean => item.id === sessionId);
      if (session?.messages.some((message: NativeConversationMessage): boolean => message.id === replyId)) {
        this.draftHistoryWrites.delete(replyId);
      }
    });
    if (!this.draftHistoryWrites.size && this.draftDirty) void this.persistDrafts();
  }

  private settingsSnapshot(): NativeSettings {
    return {
      baseUrl: this.settings.baseUrl, apiKey: this.settings.apiKey, model: this.settings.model,
      protocol: this.settings.protocol, thinking: this.settings.thinking, search: this.settings.search,
      ttsMuted: this.settings.ttsMuted, authMode: this.settings.authMode,
      speechEngine: this.settings.speechEngine, speechVoice: this.settings.speechVoice,
      migrationPromptHandled: this.settings.migrationPromptHandled,
      desktopSidebarCollapsed: this.settings.desktopSidebarCollapsed,
      theme: this.settings.theme, chatFontSize: this.settings.chatFontSize,
      attachmentBinding: this.settings.attachmentBinding,
      locale: this.settings.locale, location: this.settings.location,
    };
  }

  private label(chinese: string, english: string): string {
    return this.settings.locale === 'en-US' ? english : chinese;
  }

  private historyGroupLabel(group: NativeConversationGroup): string {
    if (this.settings.locale === 'en-US') {
      switch (group.key) {
        case 'pinned': return 'Pinned';
        case 'today': return 'Today';
        case 'yesterday': return 'Yesterday';
        case 'week': return '7 Days';
        case 'month': return '30 Days';
      }
    }
    return group.label;
  }

  private async saveSettings(manualPreference?: 'locale' | 'location'): Promise<void> {
    try {
      await this.settingsStore.save(this.host(), this.settingsSnapshot(), manualPreference);
    } catch {
      this.toast(this.label('无法保存设置', "Unable to save settings"));
    }
  }

  private applyTheme(): void {
    const mode = this.settings.theme === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      this.settings.theme === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      this.host().getApplicationContext().setColorMode(mode);
    } catch {
      this.toast(this.label('无法应用外观设置', "Unable to apply theme"));
    }
  }

  private accountToken(): string {
    return this.settings.authMode === 'deepseek-account' ? this.account?.token ?? '' : '';
  }

  private authenticated(): boolean {
    return !!this.settings.apiKey || !!this.accountToken() || (!!this.settings.model.trim() &&
      allowsKeylessNativeApi(this.settings.baseUrl, this.settings.protocol));
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
    const locale = this.settings.locale === 'en-US' ? 'en_US' : 'zh_CN';
    const balance = token ? await this.accountController.fetchBalance(token, locale) :
      await fetchNativeProviderBalance(this.settings.baseUrl, key, locale);
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
    if (settings.apiKey) {
      this.offerMigrationPrompt();
    }
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
    if (this.settingsVerifying || !this.canVerifySettings()) {
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

  private canVerifySettings(): boolean {
    return !!this.settingsBase.trim() && !!this.settingsModel.trim() &&
      (!!this.settingsKey.trim() || allowsKeylessNativeApi(this.settingsBase, this.settingsProtocol));
  }

  private async startAuthorization(): Promise<void> {
    if (this.authorizing) {
      return;
    }
    this.authorizing = true;
    this.authorizationUrl = '';
    this.authorizationStatus = this.label('正在连接 DeepSeek 开放平台…', 'Connecting to DeepSeek Platform…');
    const attempt = ++this.authAttempt;
    try {
      const challenge = await this.accountController.startLogin(this.host(),
        this.settings.locale === 'en-US' ? 'en_US' : 'zh_CN');
      if (attempt === this.authAttempt) {
        this.authorizationStatus = this.label('请登录并授权 Nuwa 使用你的 DeepSeek API 账号', "Sign in to authorize Nuwa to use your DeepSeek API account");
        this.authorizationUrl = challenge.authorizeUrl;
      }
    } catch (error) {
      if (attempt === this.authAttempt) {
        this.cancelAuthorization();
      this.toast((error as Error).message || this.label('无法连接 DeepSeek 开放平台', 'Unable to connect to DeepSeek Platform'));
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
    this.authorizationStatus = this.label('正在确认授权…', "Completing authorization…");
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
      this.offerMigrationPrompt();
      void this.refreshBalance();
    } catch (error) {
      if (attempt === this.authAttempt) {
        this.cancelAuthorization();
        this.toast((error as Error).message || this.label('DeepSeek 授权失败', "DeepSeek authorization failed"));
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
      this.toast(this.label('无法保存设置', "Unable to save settings"));
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
      this.toast(this.label('退出登录失败，请重试', "Couldn't sign out. Please try again."));
    }
  }

  private async openLink(target: string): Promise<void> {
    try {
      await this.host().openLink(target, { appLinkingOnly: false });
    } catch {
      this.toast(this.label('无法打开链接', "Unable to open link"));
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
    return session === this.visibleSession ? this.messagePath : session ? visibleMessages(session) : [];
  }

  private syncMessageList(): void {
    const session = this.session();
    if (session === this.visibleSession) return;
    if (session?.id !== this.visibleSession?.id) {
      this.messageLimit = CHAT_PAGE_SIZE;
      this.rangeFromTop = false;
      this.firstVisibleRow = 0;
      this.followLatest = true;
    }
    this.visibleSession = session;
    this.messagePath = session ? visibleMessages(session) : [];
    this.updateMessageWindow();
  }

  private updateMessageWindow(): void {
    const range = nativeMessageRange(this.messagePath.length, this.messageLimit, this.rangeFromTop);
    this.messageRange = range;
    this.earlierCount = range.start;
    this.laterCount = this.messagePath.length - range.end;
    this.messageList.update(this.messagePath, range);
  }

  private nearListEnd(): boolean {
    if (this.laterCount > 0) return false;
    if (this.scroller.isAtEnd()) return true;
    const index = this.messageList.totalCount() - 1 + Number(this.earlierCount > 0);
    if (index < 0 || this.listViewportHeight <= 0) return index < 0;
    const frame = this.scroller.getItemRect(index);
    return frame.height > 0 && frame.y + frame.height - this.listViewportHeight < 40;
  }

  private restoreListPosition(index: number, top: number): void {
    if (this.anchorTimer >= 0) clearTimeout(this.anchorTimer);
    const sessionId = this.history.activeId;
    this.anchorTimer = setTimeout(() => {
      this.anchorTimer = -1;
      if (sessionId === this.history.activeId && this.visible) {
        this.scroller.scrollToIndex(index, false, ScrollAlign.START, { extraOffset: LengthMetrics.vp(-top) });
      }
    }, 0);
  }

  private loadMoreMessages(earlier: boolean): void {
    if ((earlier ? this.earlierCount : this.laterCount) <= 0) return;
    const header = Number(this.earlierCount > 0);
    const row = Math.max(header, this.firstVisibleRow);
    const top = this.scroller.getItemRect(row).y;
    const messageIndex = this.messageRange.start + row - header;
    this.followLatest = false;
    this.messageLimit += CHAT_PAGE_SIZE;
    this.updateMessageWindow();
    this.restoreListPosition(messageIndex - this.messageRange.start + Number(this.earlierCount > 0), top);
  }

  private jumpToNewestMessages(): void {
    if (this.rangeFromTop) {
      this.rangeFromTop = false;
      this.messageLimit = CHAT_PAGE_SIZE;
      this.updateMessageWindow();
    }
    this.followLatest = true;
    this.scrollToLatest();
  }

  private titlePressed(): void {
    const now = Date.now();
    if (now - this.titleTap <= 400) {
      this.titleTap = 0;
      this.followLatest = false;
      this.rangeFromTop = true;
      this.messageLimit = CHAT_PAGE_SIZE;
      this.updateMessageWindow();
      this.restoreListPosition(0, 0);
    } else {
      this.titleTap = now;
    }
  }

  private observeMessageScroll(offset: number, state: ScrollState): void {
    if (this.nearListEnd()) this.followLatest = true;
    if (state === ScrollState.Idle) return;
    if (offset < 0) {
      this.followLatest = false;
      if (this.earlierCount > 0 && this.firstVisibleRow <= 2) this.loadMoreMessages(true);
    } else if (offset > 0 && this.laterCount > 0) {
      const footer = this.scroller.getItemRect(this.messageList.totalCount());
      if (footer.height > 0 && footer.y < this.listViewportHeight + 240) this.loadMoreMessages(false);
    }
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
      this.rememberCurrentDraft();
      this.stopVoice();
      this.sourcesVisible = false;
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
      (session.title || this.label('新对话', 'New chat')).toLowerCase().includes(query) ||
      session.messages.some((message: NativeConversationMessage): boolean =>
        message.content.toLowerCase().includes(query) || message.reasoning.toLowerCase().includes(query))) : this.history.sessions);
  }

  private async deleteSessions(ids: string[], deleteAll: boolean = false): Promise<void> {
    if (!ids.length || this.backupBusy) {
      return;
    }
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: deleteAll ? this.label('删除所有对话', 'Delete all chats') : ids.length === 1 ?
          this.label('删除对话', 'Delete chat') : this.label(`删除 ${ids.length} 个对话`, `Delete ${ids.length} chats`),
        message: deleteAll ? this.label('本地保存的附件及未发送的草稿也将被删除。', 'Local attachments and unsent drafts will also be deleted.') :
          this.label('删除后将无法恢复。', 'Deleted chats can’t be recovered.'),
        buttons: [{ text: this.label('取消', "Cancel"), color: '#61666B' }, { text: this.label('删除', "Delete"), color: '#EC1313' }],
      });
      if (result.index === 1 && !this.backupBusy) {
        await this.removeConversations(ids, deleteAll);
      }
    } catch {
      this.toast(this.label('删除对话失败，请重试', "Unable to delete chats. Please try again."));
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
      this.draftHistoryWrites.forEach((sessionId: string, replyId: string): void => {
        if (deleted.has(sessionId)) this.draftHistoryWrites.delete(replyId);
      });
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
          this.removedDraftFiles.set(file.id, file);
        }
      }
      this.draftDirty = true;
      await this.save(context);
      await this.persistDrafts();
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
      reply.resumeRetry?.();
    }
  }

  private restoreDraft(id: string): void {
    const draft = this.drafts.get(id);
    this.draft = draft?.text ?? '';
    this.draftFiles = draft?.files ?? [];
  }

  private rememberCurrentDraft(): void {
    const key = this.history.activeId ?? '';
    if (this.draft || this.draftFiles.length) {
      this.drafts.set(key, { text: this.draft, files: this.draftFiles });
    } else {
      this.drafts.delete(key);
    }
  }

  private async loadDrafts(context: common.UIAbilityContext): Promise<void> {
    if (this.draftStorageReady) return;
    try {
      const items = await this.draftStorage.load(context);
      for (const item of items) {
        if (item.sessionId !== null && !this.session(item.sessionId)) continue;
        const files = item.files.map<NativeDraftAttachment>((file: NativeAttachment): NativeDraftAttachment => {
          const ready = !!file.serverId && file.serverBinding === this.settings.attachmentBinding;
          return { item: file, state: ready ? 'ready' : 'failed',
            error: ready ? '' : this.label('请重试上传', 'Retry this upload') };
        });
        this.drafts.set(item.sessionId ?? '', { text: item.text, files });
      }
      this.restoreDraft(this.history.activeId ?? '');
      this.draftStorageReady = true;
    } catch {
      this.toast(this.label('无法读取已保存的草稿', 'Unable to read saved drafts'));
    }
  }

  private updateDraftText(value: string): void {
    if (value === this.draft) return;
    this.draft = value;
    this.scheduleDraftSave();
  }

  private scheduleDraftSave(immediate: boolean = false): void {
    this.draftDirty = true;
    if (this.draftSaveTimer >= 0) clearTimeout(this.draftSaveTimer);
    if (immediate) {
      this.draftSaveTimer = -1;
      void this.persistDrafts();
      return;
    }
    this.draftSaveTimer = setTimeout(() => {
      this.draftSaveTimer = -1;
      void this.persistDrafts();
    }, 250);
  }

  private async persistDrafts(): Promise<void> {
    if (!this.draftStorageReady || this.draftSaving || !this.draftDirty || this.draftHistoryWrites.size > 0) return;
    this.rememberCurrentDraft();
    const rows: NativeStoredDraft[] = [];
    this.drafts.forEach((draft: NativeDraft, id: string): void => {
      if ((id === '' || this.session(id)) && (draft.text || draft.files.length)) {
        rows.push({ sessionId: id || null, text: draft.text,
          files: draft.files.map<NativeAttachment>((file: NativeDraftAttachment): NativeAttachment => file.item) });
      }
    });
    const removed = Array.from(this.removedDraftFiles.values());
    const context = this.host();
    this.draftSaving = true;
    this.draftDirty = false;
    let saved = false;
    try {
      await this.draftStorage.save(context, rows);
      saved = true;
      for (const item of removed) {
        this.removedDraftFiles.delete(item.id);
        await this.attachments.remove(context, item).catch(() => {});
      }
    } catch {
      this.draftDirty = true;
      this.toast(this.label('草稿保存失败，请重试', 'Unable to save drafts. Please try again.'));
    } finally {
      this.draftSaving = false;
      if (saved && this.draftDirty) void this.persistDrafts();
    }
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
    this.scheduleDraftSave(true);
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
      this.toast(this.label('当前服务不支持附件，请配置 Anthropic 接口', "Configure an Anthropic API endpoint to send attachments"));
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
      this.toast((error as Error).message || this.label('添加附件失败', "Unable to add attachments"));
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
      this.replaceDraftFile(draftId, item, 'failed', (error as Error).message || this.label('上传失败', "Upload failed"));
    }
  }

  private replaceDraftFile(draftId: string, item: NativeAttachment, state: 'uploading' | 'ready' | 'failed', error: string): void {
    this.updateDraftItems(draftId, this.draftItems(draftId).map((existing: NativeDraftAttachment): NativeDraftAttachment =>
      existing.item.id === item.id ? { item, state, error } : existing));
  }

  private removeDraftFile(item: NativeAttachment): void {
    const id = this.history.activeId ?? '';
    this.updateDraftItems(id, this.draftItems(id).filter((file: NativeDraftAttachment): boolean => file.item.id !== item.id));
    this.removedDraftFiles.set(item.id, item);
    this.scheduleDraftSave(true);
  }

  private canSendDraft(): boolean {
    return (!this.draftFiles.length || !!this.accountToken() || this.settings.protocol === 'anthropic') && !this.recognitionId && !this.backupBusy && (!!this.draft.trim() || this.draftFiles.length > 0) &&
      this.draftFiles.every((file: NativeDraftAttachment): boolean => file.state === 'ready');
  }

  private async prepareMessages(context: common.UIAbilityContext, session: NativeConversation, config: NativeChatConfig,
    reply: NativeReply, rejectedImages: Set<string>): Promise<NativeChatMessage[]> {
    const messages: NativeChatMessage[] = [];
    const path = visibleMessages(session);
    const prompt = path[path.length - 2];
    let previousReminder: string | undefined;
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
          if (file.serverId && !rejectedImages.has(file.serverId)) {
            files.push({ serverId: file.serverId, isImage: file.isImage });
          }
        }
      }
      if (message.content || files.length) {
        const reminder = message.id === prompt?.id ? reply.message.latestReminder : next?.latestReminder;
        if (message.role === 'user' && reminder && reminder !== previousReminder &&
          (config.accountToken || config.protocol === 'anthropic')) {
          messages.push({ role: 'latest_reminder', content: reminder });
          previousReminder = reminder;
        }
        const readLinks = message.role === 'assistant' && (config.accountToken || config.protocol === 'anthropic') ?
          message.readLinks?.filter((link: NativeReadLink): boolean =>
            useNativeReadLink(link, reply.attachmentBinding, config.baseUrl, !!config.accountToken)) : undefined;
        messages.push({ role: message.role, content: message.content, files, readLinks });
      }
    }
    return messages;
  }

  private usableContextReply(message: NativeConversationMessage | undefined): boolean {
    return !!message && message.role === 'assistant' && !!message.content && message.stopReason !== 'refusal' &&
      (message.status === 'done' || message.status === 'stopped');
  }

  private startReply(session: NativeConversation, parentId: string | null,
    prompt?: NativeConversationMessage, clearDraft: boolean = false): void {
    if (!this.loaded || this.backupBusy || this.reply(session.id)) {
      return;
    }
    const config = this.requestConfig();
    if (!config.accountToken && (!config.baseUrl || !config.model ||
      (!config.apiKey && !allowsKeylessNativeApi(config.baseUrl, this.settings.protocol)))) {
      this.openSettings('account');
      return;
    }
    const message = createConversationMessage('assistant', '', '', Date.now(), 'pending',
      config.accountToken ? 'deepseek-flash' : config.model);
    message.thinking = config.thinking;
    message.search = config.search;
    message.canPrefill = true;
    config.requestTitle = !session.title;
    const next = appendBranch(session, parentId, prompt ? [prompt, message] : [message], Date.now(), false);
    const reply: NativeReply = {
      sessionId: next.id, message, client: new NativeChatClient(), stopped: false, uploadingIds: [],
      attachmentBinding: this.settings.attachmentBinding,
    };
    this.replies = [...this.replies, reply];
    if (clearDraft) {
      void this.persistDrafts();
      this.draftHistoryWrites.set(message.id, next.id);
      const draftId = this.history.activeId ?? '';
      this.drafts.delete(draftId);
      this.draft = '';
      this.draftFiles = [];
      this.draftDirty = true;
    }
    this.history = upsertConversation(this.history, next, true);
    this.lastStreamSave = Date.now();
    this.status = '';
    this.compactToolsOpen = false;
    if (!this.wide()) {
      this.getUIContext().getFocusController().clearFocus();
    } else if (clearDraft) {
      setTimeout(() => {
        if (this.visible && this.history.activeId === next.id) {
          this.getUIContext().getFocusController().requestFocus('nuwa-composer');
        }
      }, 0);
    }
    this.jumpToNewestMessages();
    void this.receive(this.host(), config, next, reply);
  }

  private streamMessage(reply: NativeReply, status: string): NativeConversationMessage {
    return {
      id: reply.message.id, role: 'assistant', createdAt: reply.message.createdAt,
      parentId: reply.message.parentId, content: reply.message.content, reasoning: reply.message.reasoning,
      model: reply.message.model, status,
      failure: reply.message.failure,
      stopReason: reply.message.stopReason, canPrefill: reply.message.canPrefill,
      thinking: reply.message.thinking, search: reply.message.search, thinkingSignature: reply.message.thinkingSignature,
      latestReminder: reply.message.latestReminder,
      sources: reply.message.sources, citations: reply.message.citations, toolTimeline: reply.message.toolTimeline,
      readLinks: reply.message.readLinks,
    };
  }

  private historyWithPartialReplies(): NativeConversationState {
    let state = this.history;
    for (const reply of this.replies) {
      const session = state.sessions.find((item: NativeConversation): boolean => item.id === reply.sessionId);
      const pending = session?.messages.find((message: NativeConversationMessage): boolean => message.id === reply.message.id);
      if (session && pending?.status === 'pending' &&
        (reply.message.content || reply.message.reasoning || reply.message.latestReminder)) {
        state = upsertConversation(state, updateConversationMessage(session, this.streamMessage(reply, 'streaming')));
      }
    }
    return state;
  }

  private invalidateReplyFiles(session: NativeConversation, sent: NativeChatMessage[], error: NativeModelError,
    binding: string): boolean {
    const sentIds = new Set<string>();
    for (const message of sent) {
      for (const file of message.files ?? []) {
        if (!error.fileIds.length || error.fileIds.includes(file.serverId)) {
          sentIds.add(file.serverId);
        }
      }
    }
    let invalidated = false;
    const current = this.session(session.id);
    for (const snapshot of [session, current]) {
      for (const message of snapshot?.messages ?? []) {
        for (const file of message.files ?? []) {
          if (file.local && file.serverId && file.serverBinding === binding && sentIds.has(file.serverId)) {
            file.serverId = null;
            file.serverBinding = undefined;
            invalidated = true;
          }
        }
      }
    }
    return invalidated;
  }

  private waitForFileRetry(reply: NativeReply, attempt: number): Promise<void> {
    return new Promise<void>((resolve): void => {
      const finish = (): void => {
        clearTimeout(timer);
        reply.resumeRetry = undefined;
        resolve();
      };
      const timer = setTimeout(finish, 1000 * 2 ** attempt);
      reply.resumeRetry = finish;
    });
  }

  private async requestReply(context: common.UIAbilityContext, config: NativeChatConfig,
    session: NativeConversation, reply: NativeReply): Promise<NativeReplyOutcome | undefined> {
    const rejectedImages = new Set<string>();
    let fileRetries = 0;
    while (!reply.stopped) {
      let messages: NativeChatMessage[];
      try {
        messages = await this.prepareMessages(context, session, config, reply, rejectedImages);
      } catch (cause) {
        const detail = cause instanceof Error ? cause.message : '';
        if (!reply.stopped) {
          reply.message.failure = { kind: 'upload', detail: detail.slice(0, 512) };
        }
        throw new Error(detail);
      }
      if (reply.stopped) return undefined;
      const sources = new NativeChatSources();
      const timeline = new NativeToolTimeline();
      const readLinks = new NativeReadLinkCollector(isOfficialNativeReadLinkRoute(config.baseUrl, !!config.accountToken) ?
        undefined : reply.attachmentBinding);
      const prefix = reply.message.content;
      const prefixTimeline = reply.message.toolTimeline;
      let hasTimeline = false;
      const sourceOffset = reply.message.content.length;
      try {
        return await reply.client.send(config, messages, (content: string, reasoning: string): void => {
          reply.message.content += content;
          reply.message.reasoning += reasoning;
          this.paintLiveReplies();
          if (!this.deletingSessions && Date.now() - this.lastStreamSave > 1500) {
            this.lastStreamSave = Date.now();
            void this.save(context, true);
          }
        }, (event: string): void => {
          const readLink = readLinks.apply(event, reply.message.content.length);
          if (readLink) {
            reply.message.readLinks = [...(reply.message.readLinks ?? []), readLink]
              .sort((left: NativeReadLink, right: NativeReadLink): number => left.offset - right.offset);
          }
          const changed = timeline.apply(event);
          if (changed) {
            hasTimeline = true;
            reply.message.toolTimeline = this.mergeReplyTimeline(prefix, prefixTimeline, timeline.snapshot());
          }
          if (sources.apply(event)) {
            reply.message.sources = sources.snapshot();
            reply.message.citations = sources.citationSnapshot().map<NativeChatCitation>(
              (citation: NativeChatCitation): NativeChatCitation => ({
                offset: citation.offset + sourceOffset, sourceIndex: citation.sourceIndex,
              }));
            this.paintLiveReplies();
          } else if (changed) {
            this.paintLiveReplies();
          }
        });
      } catch (cause) {
        if (!(cause instanceof NativeModelError)) {
          throw new Error(cause instanceof Error ? cause.message : '');
        }
        if (cause.receivedContent || reply.stopped) {
          throw cause;
        }
        if (cause.inputLimit && usesExtendedNativeRequest(config, messages)) {
          config.omitExtended = true;
          continue;
        }
        if (cause.imageMessageIndex >= 0 && cause.imageMessageIndex < messages.length) {
          const target = messages[cause.imageMessageIndex];
          const image = target.files?.[cause.imageBlockIndex];
          if (target.role === 'user' && image?.isImage) {
            if (cause.imageMessageIndex === messages.length - 1) {
              reply.message.failure = { kind: 'unsupported-image', detail: '' };
              throw cause;
            }
            if (rejectedImages.size < 10) {
              rejectedImages.add(image.serverId);
              continue;
            }
          }
        }
        if (cause.invalidFile && fileRetries < 2 &&
          this.invalidateReplyFiles(session, messages, cause, reply.attachmentBinding)) {
          void this.save(context);
          await this.waitForFileRetry(reply, fileRetries++);
          continue;
        }
        throw cause;
      } finally {
        if (hasTimeline) {
          reply.message.toolTimeline = this.mergeReplyTimeline(prefix, prefixTimeline, timeline.snapshot(false));
        }
      }
    }
    return undefined;
  }

  private mergeReplyTimeline(prefix: string, previous: NativeToolTimelineView | undefined,
    current: NativeToolTimelineView): NativeToolTimelineView | undefined {
    if (!current.steps.length) return previous;
    const steps = previous?.steps.slice() ?? [];
    if (prefix) {
      const offset = previous?.answerOffset ?? 0;
      const text = prefix.slice(offset);
      if (text.trim()) {
        steps.push({ type: 'text', key: `prefill-${offset}-${prefix.length}`, text, startOffset: offset });
      }
    }
    for (const step of current.steps) {
      const adjusted: NativeToolTimelineStep = {
        type: step.type, key: `${prefix.length}-${step.key}`, kind: step.kind, status: step.status,
        queries: step.queries, resultUrls: step.resultUrls, pages: step.pages, patterns: step.patterns, text: step.text,
        startOffset: step.startOffset === undefined ? undefined : prefix.length + step.startOffset,
        active: step.active,
      };
      steps.push(adjusted);
    }
    return {
      steps, answer: '', answerOffset: prefix.length + current.answerOffset,
      thinkingSeconds: (previous?.thinkingSeconds ?? 0) + (current.thinkingSeconds ?? 0),
    };
  }

  private async receive(context: common.UIAbilityContext, config: NativeChatConfig,
    session: NativeConversation, reply: NativeReply): Promise<void> {
    void this.save(context);
    let error = false;
    try {
      if (!config.prefill && (config.accountToken || config.protocol === 'anthropic')) {
        reply.message.latestReminder = createNativeLatestReminder(this.settings.locale, this.settings.location);
        void this.save(context);
      }
      const outcome = await this.requestReply(context, config, session, reply);
      if (outcome) {
        reply.message.stopReason = outcome.stopReason;
        reply.message.canPrefill = outcome.canPrefill;
        reply.message.thinkingSignature = outcome.thinkingSignature || reply.message.thinkingSignature;
        if (outcome.stopReason === 'refusal') {
          reply.message.content = '';
          reply.message.reasoning = '';
          reply.message.thinkingSignature = undefined;
          reply.message.citations = undefined;
          reply.message.toolTimeline = undefined;
          reply.message.readLinks = undefined;
        }
        if (outcome.title && config.requestTitle && !this.session(session.id)?.title && !reply.stopped) {
          this.history = renameConversation(this.history, session.id, outcome.title);
        }
      }
    } catch (cause) {
      error = !reply.stopped;
      if (error && !reply.message.failure) {
        const status = cause instanceof NativeModelError ? cause.status : undefined;
        reply.message.failure = {
          kind: status === 0 ? 'network' : 'response',
          detail: ((cause as Error).message || '').slice(0, 512),
          status: status && status >= 100 && status <= 599 ? status : undefined,
        };
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

  private canContinue(message: NativeConversationMessage): boolean {
    const path = this.messages();
    return path[path.length - 1]?.id === message.id && path[path.length - 2]?.role === 'user' &&
      message.canPrefill === true && !message.sources?.length && message.stopReason !== 'refusal' && message.stopReason !== 'tool_use' &&
      (message.status === 'stopped' || (message.status === 'done' && message.stopReason === 'max_tokens'));
  }

  private continueReply(message: NativeConversationMessage): void {
    const session = this.session();
    if (!session || this.backupBusy || this.reply(session.id) || !this.canContinue(message)) {
      return;
    }
    const config = this.requestConfig();
    config.model = message.model || config.model;
    config.thinking = message.thinking ?? config.thinking;
    config.search = message.search ?? config.search;
    config.requestTitle = !session.title;
    config.prefill = {
      text: message.content, reasoning: message.reasoning, thinkingSignature: message.thinkingSignature ?? '',
    };
    const reply: NativeReply = {
      sessionId: session.id, message, client: new NativeChatClient(), stopped: false, uploadingIds: [],
      attachmentBinding: this.settings.attachmentBinding,
    };
    const pending = this.streamMessage(reply, 'pending');
    pending.stopReason = undefined;
    const next = updateConversationMessage(session, pending, Date.now());
    const current = next.messages.find((item: NativeConversationMessage): boolean => item.id === pending.id);
    if (!current) {
      return;
    }
    reply.message = current;
    this.stopVoice();
    this.status = '';
    this.history = upsertConversation(this.history, next);
    this.replies = [...this.replies, reply];
    this.lastStreamSave = Date.now();
    this.jumpToNewestMessages();
    void this.receive(this.host(), config, next, reply);
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
    if (session && sibling && !this.reply(session.id)) {
      const pathIndex = this.messagePath.findIndex((item: NativeConversationMessage): boolean => item.id === message.id);
      const listIndex = pathIndex - this.messageRange.start + Number(this.earlierCount > 0);
      const keepPosition = pathIndex >= this.messageRange.start && pathIndex < this.messageRange.end;
      const top = keepPosition ? this.scroller.getItemRect(listIndex).y : 0;
      this.followLatest = false;
      this.sourcesVisible = false;
      this.history = upsertConversation(this.history, selectMessageVersion(session, sibling.id));
      if (keepPosition && pathIndex >= this.messageRange.start && pathIndex < this.messageRange.end) {
        this.restoreListPosition(pathIndex - this.messageRange.start + Number(this.earlierCount > 0), top);
      }
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
      this.recognition.start(this.recognitionId, this.host(), this.speechOptions());
    }
  }

  private stopVoice(): void {
    this.recognitionId = '';
    this.transcribing = false;
    this.recognition.cancel();
    this.readingId = '';
    this.speaker.stop();
  }

  private readMessage(message: NativeConversationMessage): void {
    const active = this.readingId === message.id;
    this.speaker.stop();
    this.readingId = active ? '' : message.id;
    if (this.readingId) {
      this.speaker.speak(message.id, message.content, this.settings.locale, this.speechOptions());
    }
  }

  private speechOptions(): HarmonySpeechOptions {
    return {
      engine: this.settings.speechEngine, voice: this.settings.speechVoice,
      apiKey: this.settings.apiKey, baseUrl: this.settings.baseUrl,
      accountActive: !!this.accountToken(), locale: this.settings.locale,
    };
  }

  private speechError(code: string | undefined, recognition: boolean): string {
    switch (code) {
      case 'permission-denied': return this.label('请允许 Nuwa 使用麦克风', 'Allow Nuwa to use the microphone');
      case 'key-required': return this.label('云端语音需要可用的 API Key', 'Cloud speech requires a supported API Key');
      case 'unauthorized': return this.label('API Key 无效或已被删除，请更换后重试', 'The API Key is invalid. Replace it and try again.');
      case 'quota': return this.label('账户余额不足，请充值后重试', 'Insufficient account balance. Top up and try again.');
      case 'rate-limited': return this.label('请求过于频繁，请稍后再试', 'Too many requests. Try again later.');
      case 'network': return this.label('网络异常，请检查你的网络状况', 'Check your network connection and try again.');
      default: return recognition ? this.label('语音识别暂不可用', 'Speech recognition is unavailable') :
        this.label('朗读暂不可用', 'Read-aloud is unavailable');
    }
  }

  private toggleSpeaker(): void {
    const muted = !!this.readingId || !this.settings.ttsMuted;
    this.readingId = '';
    this.speaker.stop();
    this.settings.ttsMuted = muted;
    void this.saveSettings();
    this.toast(muted ? this.label('已静音朗读', "Read-aloud muted") : this.label('已取消朗读静音', "Read-aloud unmuted"));
  }

  private async copy(text: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.toast(this.label('已复制', "Copied"));
    } catch {
      this.toast(this.label('复制失败', "Copy failed"));
    }
  }

  private compact(): boolean {
    return this.viewportWidth <= 340;
  }

  private wide(): boolean {
    return this.viewportWidth >= 768;
  }

  private desktopSourcesWidth(): number {
    return Math.min(390, this.viewportWidth / 2 - 64);
  }

  private setDesktopSidebar(collapsed: boolean): void {
    this.settings.desktopSidebarCollapsed = collapsed;
    if (collapsed) {
      this.resetSelection();
      this.getUIContext().getFocusController().clearFocus();
    }
    void this.saveSettings();
  }

  private drawerWidth(): number {
    return Math.min(this.viewportWidth * 0.82, 310);
  }

  private drawerProgress(): number {
    return this.wide() ? 0 : Math.max(0, Math.min(1, (this.drawerOpen ? 1 : 0) + this.drawerDrag / this.drawerWidth()));
  }

  @Builder
  private iconButton(icon: Resource, label: string, action: () => void, size: number = 34,
    iconSize: number = 20, color: ResourceColor = $r('app.color.native_chat_primary'),
    background: ResourceColor = Color.Transparent, enabled: () => boolean = () => true) {
    Button({ type: ButtonType.Circle }) {
      Image(icon).width(iconSize).height(iconSize).colorFilter(nativeIconTint(color)).draggable(false)
    }
    .width(size).height(size).padding(0).backgroundColor(background)
    .enabled(enabled()).accessibilityText(label).onClick(action)
  }

  @Builder
  private desktopHeader() {
    Row({ space: 8 }) {
      if (this.settings.desktopSidebarCollapsed) {
        Row({ space: 4 }) {
          this.iconButton($r('app.media.native_menu'), this.label('展开侧边栏', 'Open sidebar'),
            () => { this.setDesktopSidebar(false); }, 38)
          this.iconButton($r('app.media.native_new_chat'), this.label('开启新对话', 'New chat'),
            () => { this.activate(null); }, 38)
        }
        .width(105).padding({ left: 10 })
      }
      if (this.history.activeId !== null) {
        Text(this.session()?.title || this.label('新对话', 'New chat'))
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 480 })
          .padding({ left: 12, right: 12, top: 8, bottom: 8 }).onClick(() => { this.titlePressed(); })
      }
    }
    .width('100%').height(60).padding({ left: 18, right: 18, top: 12 })
  }

  @Builder
  private header() {
    Row({ space: this.compact() ? 6 : 10 }) {
      Row() {
        this.iconButton($r('app.media.native_menu'), this.label('展开侧边栏', "Open sidebar"), () => { this.setDrawer(true); }, this.compact() ? 30 : 42)
      }
      .borderRadius(999).border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN).shadow({ radius: 10, color: '#10000000', offsetY: 2 })
      if (this.history.activeId !== null) {
        Text(this.session()?.title || this.label('新对话', "New chat")).fontSize(this.compact() ? 13 : 14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary')).textAlign(TextAlign.Center)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .onClick(() => { this.titlePressed(); })
      } else {
        Blank().layoutWeight(1)
      }
      Row({ space: 2 }) {
        this.iconButton(this.settings.ttsMuted && !this.readingId ? $r('app.media.native_muted') : $r('app.media.native_speaker'),
        this.label('朗读静音', 'Mute read-aloud'), () => { this.toggleSpeaker(); }, this.compact() ? 26 : 34)
        this.iconButton($r('app.media.native_new_chat'), this.label('开启新对话', "New chat"), () => { this.activate(null); }, this.compact() ? 26 : 34)
      }
      .height(this.compact() ? 30 : 42).padding({ left: 6, right: 6 })
      .borderRadius(999).border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN).shadow({ radius: 10, color: '#10000000', offsetY: 2 })
    }
    .width('100%').height(this.compact() ? 40 : 58)
    .padding({ left: this.compact() ? 8 : 16, right: this.compact() ? 8 : 16, top: 4 })
  }

  @Builder
  private welcome(flex: boolean = true) {
    Column({ space: this.compact() ? 6 : 16 }) {
      Image($r('app.media.native_welcome_logo'))
        .width(this.compact() ? 34 : this.wide() && this.viewportHeight <= 500 ? 42 : 52)
        .height(this.compact() ? 34 : this.wide() && this.viewportHeight <= 500 ? 42 : 52)
        .borderRadius(this.compact() ? 10 : 14).shadow({ radius: 14, color: '#14000000', offsetY: 4 })
        .draggable(false).accessibilityText('Nuwa')
        Text(this.label('你好，让我们开始聊天吧', "Hi, let's start chatting"))
          .fontSize(this.compact() ? 14 : this.wide() && this.viewportHeight <= 500 ? 18 : 20)
          .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.native_chat_primary'))
    }
    .width('100%').layoutWeight(flex ? 1 : 0).justifyContent(FlexAlign.Center)
  }

  @Builder
  private togglePill(icon: Resource, label: () => string, active: () => boolean, change: () => void) {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 5 }) {
        Image(icon).width(14).height(14).colorFilter(nativeIconTint(active() ? $r('app.color.native_chat_blue_text') :
          $r('app.color.native_chat_primary'))).draggable(false)
        if (this.viewportWidth >= 400 || (!this.draft.trim() && !this.draftFiles.length && this.viewportWidth >= 350)) {
          Text(label()).fontSize(13).fontWeight(FontWeight.Medium).fontColor(active() ?
            $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
        }
      }
    }
    .height(34).padding({ left: 11, right: 11 }).backgroundColor(active() ? $r('app.color.native_chat_selected') : Color.Transparent)
    .border({ width: 1, color: active() ? Color.Transparent : $r('app.color.native_chat_stroke') })
    .accessibilityText(label()).accessibilitySelected(active()).onClick(change)
  }

  @Builder
  private voiceButton() {
    this.iconButton($r('app.media.native_voice'), this.recognitionId ? this.label('结束录音', "Finish recording") : this.label('语音输入', "Voice input"),
      () => { this.toggleRecognition(); }, 34, 22,
      this.recognitionId ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
  }

  private attachmentPreview(item: NativeAttachment): string {
    if (!item.isImage) {
      return '';
    }
    if (!item.local) {
      const session = this.session();
      return session ? importedAttachmentPreview(session, item, this.host()) : '';
    }
    try {
      return this.attachments.previewUri(this.host(), item);
    } catch {
      return '';
    }
  }

  private attachmentSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private async openAttachment(item: NativeAttachment): Promise<void> {
    const image = this.attachmentPreview(item);
    if (image) {
      this.imagePreview = image;
      return;
    }
    const context = this.host();
    const uri = this.attachments.previewUri(context, item);
    if (!uri) {
      this.toast(this.label('本机没有该附件原件', 'The original attachment is unavailable on this device.'));
      return;
    }
    try {
      if (canIUse('SystemCapability.FileManagement.FilePreview.Core') && await filePreview.canPreview(context, uri)) {
        await filePreview.openPreview(context, { uri, title: item.name, mimeType: item.mimeType });
        return;
      }
    } catch {
      // Some devices defer document viewing to a dedicated installed app.
    }
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData', uri, type: item.mimeType,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
        parameters: { 'ohos.ability.params.showDefaultPicker': true },
      });
    } catch {
      this.toast(this.label('无法打开此附件', 'Unable to open this attachment.'));
    }
  }

  private messageImageSize(message: NativeConversationMessage): number {
    return message.files?.some((item: NativeAttachment): boolean => !item.isImage) ? 64 : 120;
  }

  @Builder
  private addAttachmentButton() {
    this.iconButton($r('app.media.native_add'), this.label('上传附件', "Upload attachment"), () => { void this.pickFiles(); },
      34, 22, $r('app.color.native_chat_primary'), Color.Transparent, () => !this.pickingFiles && !this.backupBusy)
  }

  @Builder
  private attachmentTile(item: NativeAttachment, size: number) {
    if (this.attachmentPreview(item)) {
      Image(this.attachmentPreview(item)).width(size).height(size).objectFit(ImageFit.Cover)
        .borderRadius(12).draggable(false).accessibilityText(item.name)
        .onClick(() => { void this.openAttachment(item); })
    } else {
      Row({ space: 8 }) {
        Image($r('app.media.native_file')).width(20).height(20).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        Column({ space: 3 }) {
          Text(item.name).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(12)
            .fontColor($r('app.color.native_chat_primary'))
          Text(this.attachmentSize(item.size)).fontSize(11).fontColor($r('app.color.native_chat_secondary'))
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width(148).height(62).padding({ left: 10, right: 10 }).borderRadius(12)
      .backgroundColor($r('app.color.native_chat_field')).accessibilityText(item.name)
      .onClick(() => { void this.openAttachment(item); })
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
                .backgroundColor('#55000000').borderRadius(12).accessibilityText(this.label('正在上传', "Uploading"))
              } else if (file.state === 'failed') {
                Column({ space: 2 }) {
                  this.iconButton($r('app.media.native_retry'), this.label('重试上传', "Retry upload"), () => {
                    void this.uploadDraftFile(this.history.activeId ?? '', file.item);
                  }, 24, 16, Color.White)
                  Text(this.label('上传失败', "Upload failed")).fontSize(10).fontColor(Color.White).maxLines(1)
                }
                .width('100%').height('100%').justifyContent(FlexAlign.Center)
                .backgroundColor('#88000000').border({ width: 1, color: $r('app.color.native_chat_error') }).borderRadius(12)
                .accessibilityDescription(file.error)
              }
              Row() {
                this.iconButton($r('app.media.native_close'), this.label('移除附件', "Remove attachment"), () => { this.removeDraftFile(file.item); },
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
  private composerField(inline: boolean) {
    Column() {
      if (this.recognitionId) {
        Row({ space: 4 }) {
          if (this.transcribing) {
            Text(this.label('正在转写…', 'Transcribing…')).fontSize(14).fontColor($r('app.color.native_chat_secondary'))
          } else {
            ForEach([8, 13, 18, 13, 8], (bar: number) => {
              Rect().width(3).height(bar).radius(2).fill($r('app.color.native_chat_blue'))
            }, (_bar: number, index: number): string => index.toString())
          }
        }
        .width('100%').height(inline || this.viewportWidth < 440 ? 42 : 60).padding({ left: inline ? 6 : 16 })
        .accessibilityText(this.transcribing ? this.label('正在转写…', 'Transcribing…') : this.label('录音中', 'Recording'))
      } else {
          TextArea({ text: this.draft, placeholder: this.label('发消息或语音输入', 'Message or voice input') })
          .width('100%').constraintSize({ minHeight: inline || this.viewportWidth < 440 ? 42 : 60,
            maxHeight: inline ? 110 : 336 })
          .padding({ top: inline ? 10 : 12, bottom: 0, left: inline ? 4 : 16, right: inline ? 4 : 12 })
          .borderRadius(0).fontSize(inline ? 14 : 16).lineHeight(inline ? 20 : 24)
          .placeholderColor($r('app.color.native_chat_caption'))
          .fontColor($r('app.color.native_chat_primary')).caretColor($r('app.color.native_chat_blue_text'))
          .backgroundColor(Color.Transparent).enterKeyType(EnterKeyType.NEW_LINE)
          .enabled(this.loaded && !this.backupBusy).id('nuwa-composer').defaultFocus(this.wide())
          .onFocus(() => { this.compactToolsOpen = false; })
          .onChange((value: string) => { this.updateDraftText(value); })
      }
    }
    .width(inline ? undefined : '100%').layoutWeight(inline ? 1 : 0)
  }

  @Builder
  private composerToggles() {
    this.togglePill($r('app.media.native_think'), () => this.label('深度思考', 'DeepThink'), () => this.settings.thinking, () => {
      this.settings.thinking = !this.settings.thinking;
      void this.saveSettings();
    })
    this.togglePill($r('app.media.native_web_search'), () => this.label('智能搜索', 'Search'), () => this.settings.search, () => {
      this.settings.search = !this.settings.search;
      void this.saveSettings();
    })
  }

  @Builder
  private composerAction() {
    if (this.reply()) {
      this.iconButton($r('app.media.native_stop'), this.label('停止生成', 'Stop generating'),
        () => { this.stopVoice(); this.cancelReply(); }, 34, 16, Color.White, $r('app.color.native_chat_blue'))
    } else if (this.draft.trim() || this.draftFiles.length) {
      this.iconButton($r('app.media.native_send'), this.label('发送', 'Send'), () => { this.sendDraft(); },
        34, 16, Color.White, $r('app.color.native_chat_blue'), () => this.loaded && this.canSendDraft())
    } else {
      this.voiceButton()
    }
  }

  @Builder
  private compactComposer() {
    if (this.compactToolsOpen) {
      Row({ space: 6 }) {
        this.composerToggles()
        this.iconButton($r('app.media.native_add'), this.label('上传附件', 'Upload attachment'), () => {
          this.compactToolsOpen = false;
          void this.pickFiles();
        }, 34, 22)
      }
      .width('100%').padding({ left: 8, right: 8, top: 8 })
    }
    Row({ space: 4 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Image($r('app.media.native_add')).width(22).height(22)
            .colorFilter(nativeIconTint($r('app.color.native_chat_primary')))
            .rotate({ angle: this.compactToolsOpen ? 45 : 0 })
        }
        .width(34).height(34).padding(0).accessibilityText(this.label('对话工具', 'Chat tools'))
        .onClick(() => { this.compactToolsOpen = !this.compactToolsOpen; })
        if (!this.compactToolsOpen && (this.settings.search || this.settings.thinking)) {
          Circle().width(6).height(6).fill($r('app.color.native_chat_blue')).margin({ top: 3, right: 3 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(34).height(34)
      this.composerField(true)
      this.composerAction()
    }
    .width('100%').padding({ left: 6, right: 7, bottom: 4 })
  }

  @Builder
  private composer() {
    Column({ space: 2 }) {
      this.draftAttachmentStrip()
      if (this.compact()) {
        this.compactComposer()
      } else {
        this.composerField(false)
        Row({ space: 9 }) {
          this.composerToggles()
          Blank().layoutWeight(1)
          Row({ space: 6 }) {
            if (!this.reply() && (this.draft.trim() || this.draftFiles.length)) this.voiceButton()
            this.addAttachmentButton()
            this.composerAction()
          }
        }
        .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
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
        this.iconButton($r('app.media.native_chevron_left'), this.label('上一个版本', "Previous version"), () => { this.changeVersion(message, -1); },
          26, 14, $r('app.color.native_chat_secondary'), Color.Transparent,
          () => !this.reply() && this.version(message) > 0)
        Text(`${this.version(message) + 1}/${this.versions(message).length}`)
          .fontSize(12).fontColor($r('app.color.native_chat_secondary'))
        this.iconButton($r('app.media.native_chevron_right'), this.label('下一个版本', "Next version"), () => { this.changeVersion(message, 1); },
          26, 14, $r('app.color.native_chat_secondary'), Color.Transparent,
          () => !this.reply() && this.version(message) + 1 < this.versions(message).length)
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
            Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.editId = ''; })
            Button(this.label('发送', "Send")).enabled(!!this.editText.trim() || !!message.files?.length).onClick(() => { this.edit(message); })
          }
          .width('100%').justifyContent(FlexAlign.End).padding(6)
        }
        .width('100%').borderRadius(22).border({ width: 1, color: $r('app.color.native_chat_blue') })
      } else {
        if (message.files?.length) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach(message.files, (file: NativeAttachment) => { this.attachmentTile(file, this.messageImageSize(message)) },
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
          this.iconButton($r('app.media.native_copy'), this.label('复制', "Copy"), () => { void this.copy(message.content); },
            28, 16, $r('app.color.native_chat_secondary'))
          this.iconButton($r('app.media.native_edit'), this.label('编辑', "Edit message"), () => {
            this.editId = message.id;
            this.editText = message.content;
          }, 28, 16, $r('app.color.native_chat_secondary'), Color.Transparent, () => !this.reply())
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.End).padding({ top: index === 0 ? 34 : 0, bottom: 16 })
  }

  private openSources(sources: NativeChatSource[]): void {
    if (sources.length) {
      this.panelSources = sources;
      this.sourcesVisible = true;
    }
  }

  @Builder
  private sourcesSummary(sources: NativeChatSource[]) {
    if (sources.length) {
      Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 6 }) {
          Image($r('app.media.native_web_search')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
          Text(this.label(`${sources.length} 个网页`, sources.length === 1 ? '1 web page' : `${sources.length} web pages`))
            .fontSize(13).fontColor($r('app.color.native_chat_secondary'))
          Image($r('app.media.native_chevron_right')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        }
      }
      .height(34).padding({ left: 12, right: 10 }).backgroundColor($r('app.color.native_chat_field'))
      .onClick(() => { this.openSources(sources); })
    }
  }

  private withCitationMarkers(text: string, citations: NativeChatCitation[], start: number = 0): string {
    const ordered = citations.filter((citation: NativeChatCitation): boolean => citation.offset >= start)
      .sort((left: NativeChatCitation, right: NativeChatCitation): number =>
      left.offset - right.offset || left.sourceIndex - right.sourceIndex);
    let result = '';
    let cursor = start;
    for (const citation of ordered) {
      const offset = Math.max(cursor, Math.min(text.length, citation.offset));
      result += `${text.slice(cursor, offset)}[citation:${citation.sourceIndex}]`;
      cursor = offset;
    }
    return result + text.slice(cursor);
  }

  @Builder
  private replyContent(message: () => NativeConversationMessage, thinking: () => boolean) {
    if (message().toolTimeline || (thinking() && !!message().thinking && !message().reasoning)) {
      NativeToolTimelinePanel({
        view: message().toolTimeline ?? EMPTY_TIMELINE, sources: message().sources ?? [],
        citations: message().citations ?? [], fontScale: this.settings.chatFontSize / 16, locale: this.settings.locale,
        streaming: message().status === 'pending' || message().status === 'streaming',
        thinking: message().thinking || undefined, stopped: message().status === 'stopped',
        hasResponse: message().content.length > (message().toolTimeline?.answerOffset ?? 0),
        onSources: (sources: NativeChatSource[]): void => { this.openSources(sources); },
      })
    } else if (message().reasoning) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Image($r('app.media.native_think')).width(16).height(16).colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
          Text(thinking() ? this.label('正在思考', 'Thinking') : this.label('已思考', 'Thought'))
            .fontSize(15).fontColor($r('app.color.native_chat_secondary'))
          Image(this.collapsedThoughts.includes(message().id) ? $r('app.media.native_chevron_right') :
            $r('app.media.native_chevron_down')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        }
      }
      .height(34).padding(0).backgroundColor(Color.Transparent)
      .onClick(() => {
        const id = message().id;
        this.collapsedThoughts = this.collapsedThoughts.includes(id) ?
          this.collapsedThoughts.filter((messageId: string): boolean => messageId !== id) : [...this.collapsedThoughts, id];
      })
      if (!this.collapsedThoughts.includes(message().id)) {
        Text(message().reasoning).fontSize(14).lineHeight(22).width('100%').fontColor($r('app.color.native_chat_secondary'))
          .padding({ left: 12 }).copyOption(CopyOptions.LocalDevice)
          .border({ width: { left: 2 }, color: $r('app.color.native_chat_stroke') })
      }
    }
    if (message().content.length > (message().toolTimeline?.answerOffset ?? 0)) {
      NativeMarkdown({
        content: this.withCitationMarkers(message().content, message().citations ?? [], message().toolTimeline?.answerOffset ?? 0),
        fontScale: this.settings.chatFontSize / 16, hasCitations: !!message().citations?.length,
        locale: this.settings.locale, theme: this.settings.theme,
        loading: message().status === 'pending' || message().status === 'streaming',
        onCitation: (index: number) => {
          const sources = message().sources ?? [];
          const source = sources.find((item: NativeChatSource): boolean => item.index === index);
          this.openSources(source ? [source] : sources);
        },
      })
    }
  }

  private replyNotice(message: NativeConversationMessage): NativeReplyNotice {
    if (message.failure) {
      return describeNativeReplyFailure(message.failure, this.settings.locale);
    }
    return { text: this.shareTemplate(message) || this.label('回复失败，请重试', 'Reply failed. Please try again.') };
  }

  private copyableReply(message: NativeConversationMessage): string {
    if (message.stopReason === 'refusal') {
      return this.shareTemplate(message) || nativeRefusalText(this.settings.locale);
    }
    return message.content || (message.status === 'error' ? this.replyNotice(message).text : this.shareTemplate(message));
  }

  @Builder
  private replyErrorNotice(message: NativeConversationMessage) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      Text(this.replyNotice(message).text).fontSize(14).fontColor($r('app.color.native_chat_error'))
      if (this.replyNotice(message).action === 'api-key') {
        Button(this.label('更换 API Key', 'Change API Key'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(13).onClick(() => { this.openSettings('account'); })
      } else if (this.replyNotice(message).action === 'top-up') {
        Button(this.label('前往充值', 'Top up'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(13).onClick(() => { void this.openLink('https://platform.deepseek.com/top_up'); })
      }
    }
    .width('100%')
  }

  @Builder
  private assistantMessage(message: NativeConversationMessage) {
    Column({ space: 7 }) {
      if (this.reply()?.message.id === message.id) {
        if (this.reply()?.message.content || this.reply()?.message.reasoning || this.reply()?.message.thinking ||
          this.reply()?.message.toolTimeline?.steps.length) {
          this.replyContent(() => this.reply()?.message ?? message, () => !this.reply()?.message.content)
        } else {
          Row({ space: 6 }) {
            ForEach([0.45, 0.7, 1], (opacity: number) => {
              Circle().width(6).height(6).fill($r('app.color.native_chat_caption')).opacity(opacity)
            }, (opacity: number): string => opacity.toString())
          }
          .height(34).accessibilityText(this.label('正在等待回复', "Waiting for reply"))
        }
      } else {
        if (message.stopReason === 'refusal') {
          NativeMarkdown({ content: this.copyableReply(message), fontScale: this.settings.chatFontSize / 16,
            locale: this.settings.locale, theme: this.settings.theme })
        } else {
          this.replyContent(() => message, () => false)
          if (message.status !== 'error' && this.shareTemplate(message)) {
            NativeMarkdown({ content: this.shareTemplate(message), fontScale: this.settings.chatFontSize / 16,
              locale: this.settings.locale, theme: this.settings.theme })
          }
          this.sourcesSummary(message.sources ?? [])
        }
        if (message.status === 'error' && message.stopReason !== 'refusal') {
          this.replyErrorNotice(message)
        } else if (message.status === 'stopped') {
          Text(this.label('已停止生成', "Generation stopped")).fontSize(13).fontColor($r('app.color.native_chat_secondary'))
        }
        Row({ space: 4 }) {
          if (this.copyableReply(message)) {
            this.iconButton($r('app.media.native_copy'), this.label('复制', "Copy"), () => { void this.copy(this.copyableReply(message)); },
              28, 16, $r('app.color.native_chat_secondary'))
          }
          if (message.content && message.stopReason !== 'refusal') {
            this.iconButton($r('app.media.native_speaker'), this.readingId === message.id ? this.label('停止朗读', "Stop read-aloud") : this.label('朗读', "Read aloud"),
              () => { this.readMessage(message); }, 28, 16,
              this.readingId === message.id ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_secondary'))
          }
          this.iconButton($r('app.media.native_retry'), this.label('重新生成', "Regenerate"), () => { this.retry(message); },
            28, 16, $r('app.color.native_chat_secondary'), Color.Transparent,
            () => !this.reply() && message.stopReason !== 'refusal')
          this.branchControls(message)
        }
        .padding({ top: 6, bottom: 12 })
        if (this.canContinue(message)) {
          Button(this.label('继续生成', "Continue"), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(13).border({ width: 1, color: $r('app.color.native_chat_stroke') })
            .enabled(!this.reply()).onClick(() => { this.continueReply(message); })
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
  }

  private openSettings(section: string = 'root'): void {
    this.settingsSection = section;
    this.settingsVisible = true;
  }

  private offerMigrationPrompt(): void {
    if (!this.settings.migrationPromptHandled) {
      this.settingsVisible = false;
      this.migrationPromptVisible = true;
    }
  }

  private dismissMigrationPrompt(): void {
    this.migrationPromptVisible = false;
    this.settings.migrationPromptHandled = true;
    void this.saveSettings();
  }

  private async importChatHistory(fromPrompt: boolean = false): Promise<void> {
    if (this.backupBusy || this.replies.length > 0) {
      this.toast(this.label('请在回复结束后导入', 'Import is available after the reply finishes'));
      return;
    }
    this.backupBusy = true;
    try {
      const context = this.host();
      const sessions = await this.backup.importFromPicker(context, () => {
        if (fromPrompt) this.dismissMigrationPrompt();
      });
      if (sessions) {
        const merged = mergeChatBackup(this.history, sessions);
        await this.storage.saveConversations(context, merged.history);
        this.history = merged.history;
        const count = merged.importedCount;
        this.toast(count ? this.label(`已导入 ${count} 个对话`, count === 1 ? 'Imported 1 chat' : `Imported ${count} chats`) :
          this.label('没有新增对话', 'No new chats to import'));
      }
    } catch (error) {
      this.toast((error as Error).message || this.label('文件导入失败', "Unable to import file"));
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
      if (await this.backup.exportToPicker(this.host(), this.historyWithPartialReplies().sessions, this.settings.locale)) {
        this.toast(this.label('已导出历史对话', "Chat history exported"));
      }
    } catch (error) {
      this.toast((error as Error).message || this.label('导出失败', "Export failed"));
    } finally {
      this.backupBusy = false;
    }
  }

  private async openHistoryMigration(): Promise<void> {
    if (this.backupBusy || this.replies.length > 0) {
      this.toast(this.label('请在回复结束后迁移', 'Migration is available after the reply finishes'));
      return;
    }
    this.settingsVisible = false;
    this.migrationInProgress = true;
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/Index', params: { migrate: true } });
    } catch {
      this.migrationInProgress = false;
      this.toast(this.label('无法打开历史迁移', "Unable to open chat migration"));
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
      this.shareImportError = this.label('请在回复结束后导入', 'Import is available after the reply finishes');
      return;
    }
    this.backupBusy = true;
    this.shareImportError = '';
    try {
      const imported = await importNativeShareLink(this.shareInput);
      const context = this.host();
      const next = upsertConversation(this.history, imported, true);
      await this.storage.saveConversations(context, next);
      this.rememberCurrentDraft();
      this.history = next;
      this.restoreDraft(imported.id);
      this.shareImportVisible = false;
      this.shareInput = '';
      this.scrollToLatest();
      this.toast(this.label('已导入 1 个对话', "Imported 1 chat"));
    } catch (error) {
      this.shareImportError = (error as Error).message || this.label('该分享链接无法导入', "Unable to import this share link");
    } finally {
      this.backupBusy = false;
    }
  }

  @Builder
  private shareImportDialog() {
    Column({ space: 14 }) {
      Text(this.label('通过 DeepSeek 分享链接导入', "Import from a DeepSeek share link")).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        .fontColor($r('app.color.native_chat_primary'))
      TextArea({ text: this.shareInput, placeholder: this.label(
        '粘贴分享链接或包含链接的完整分享文案，例如：https://chat.deepseek.com/share/...',
        'Paste a link or text containing a link, such as https://chat.deepseek.com/share/…') })
        .height(96).width('100%').fontSize(14).enabled(!this.backupBusy).maxLength(4096).borderRadius(14)
        .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
        .onChange((text: string) => { this.shareInput = text; this.shareImportError = ''; })
      if (this.shareImportError) {
        Text(this.shareImportError).width('100%').fontColor($r('app.color.native_chat_error')).fontSize(13)
      }
      Row({ space: 8 }) {
        Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL }).enabled(!this.backupBusy)
          .onClick(() => { this.closeShareImport(); })
        Button(this.backupBusy ? this.label('导入中…', "Importing…") : this.label('确认导入', "Import")).enabled(!this.backupBusy && !!this.shareInput.trim())
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

  private async startUpdateChecks(): Promise<void> {
    try {
      this.updatePreferences = await this.updateSchedule.load(this.host());
    } catch {
      // Update checks remain available if the schedule could not be restored.
    }
    if (this.updateTimer < 0) {
      this.updateTimer = setInterval(() => {
        if (this.visible) {
          void this.checkUpdate(true, false);
        }
      }, UPDATE_POLL_MS);
      await this.checkUpdate(true);
    }
  }

  private async resumeUpdateChecks(): Promise<void> {
    if (this.pendingUpdate && !this.checkingUpdate && !this.authorizing && !this.backupBusy &&
      !isUpdateSnoozed(this.pendingUpdate, this.updatePreferences, Date.now())) {
      const update = this.pendingUpdate;
      this.checkingUpdate = true;
      try {
        await this.presentUpdate(update);
      } catch {
        // The visible page can change before the update dialog opens.
      } finally {
        this.checkingUpdate = false;
      }
    }
    if (Date.now() - this.updatePreferences.checkAt >= UPDATE_RESUME_MS) {
      await this.checkUpdate(true);
    }
  }

  private async presentUpdate(update: NativeUpdateCheck): Promise<void> {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: this.label(`发现新版本 v${update.latestVersion}`, `Version ${update.latestVersion} is available`),
      message: `${this.label('当前版本', 'Current version')} v${update.currentVersion}\n\n${update.notes ||
        this.label('包含体验优化与问题修复。', 'Includes improvements and bug fixes.')}`,
      buttons: [{ text: this.label('暂不更新', "Not now"), color: '#61666B' }, { text: this.label('前往下载', "Download"), color: '#3964FE' }],
    });
    if (result.index === 1) {
      await this.openLink(update.appGalleryUrl ?? update.downloadUrl ?? update.releaseUrl);
    } else {
      this.updatePreferences.dismissedVersion = update.latestVersion;
      this.updatePreferences.dismissedAt = Date.now();
      void this.updateSchedule.dismissed(this.host(), update.latestVersion, this.updatePreferences.dismissedAt).catch(() => {});
    }
  }

  private async checkUpdate(silent: boolean = false, prompt: boolean = true): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const update = await checkNativeUpdate();
      this.updatePreferences.checkAt = Date.now();
      void this.updateSchedule.checked(this.host(), this.updatePreferences.checkAt).catch(() => {});
      this.pendingUpdate = update.hasUpdate ? update : null;
      if (!update.hasUpdate) {
        if (!silent) {
          this.toast(this.label('当前已是最新版本', "You're using the latest version"));
        }
        return;
      }
      if (!silent || (prompt && this.visible && !this.authorizing && !this.backupBusy &&
        !isUpdateSnoozed(update, this.updatePreferences, Date.now()))) {
        await this.presentUpdate(update);
      }
    } catch {
      if (!silent) {
        this.toast(this.label('检查更新失败，请稍后重试', "Unable to check for updates. Please try again later."));
      }
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
      Text(this.label('加载更新日志失败，请稍后重试', "Unable to load release notes. Please try again later.")).width('100%').fontColor($r('app.color.native_chat_secondary'))
      Button(this.label('重试', "Retry"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { void this.loadReleaseNotes(); })
    } else if (!this.releaseNotes.length) {
      Text(this.label('暂无历史版本记录', "No release history")).width('100%').fontColor($r('app.color.native_chat_secondary'))
    } else {
      ForEach(this.releaseNotes, (release: NativeReleaseHistoryItem) => {
        Column({ space: 10 }) {
          Row() {
            Text(`v${release.version}`).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.native_chat_primary')).layoutWeight(1)
            Text(release.createdAt.slice(0, 10)).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
          }
          .width('100%')
          Text(release.changelog || this.label('包含体验优化与问题修复。', 'Includes improvements and bug fixes.'))
            .width('100%').fontSize(14).lineHeight(22)
            .fontColor($r('app.color.native_chat_secondary')).copyOption(CopyOptions.LocalDevice)
        }
        .width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.native_chat_surface'))
      }, (release: NativeReleaseHistoryItem): string => release.id)
    }
  }

  private settingsTitle(): string {
    switch (this.settingsSection) {
      case 'account': return this.label('账号管理', "Account management");
      case 'key': return this.label('更换 API Key', "Change API Key");
      case 'data': return this.label('数据管理', "Data management");
      case 'notes': return this.label('更新日志', "Release notes");
      default: return this.label('设置', "Settings");
    }
  }

  @Builder
  private configInput(value: () => string, placeholder: () => string, inputType: InputType, change: (value: string) => void) {
    TextInput({ text: value(), placeholder: placeholder() }).width('100%').height(46).type(inputType).fontSize(14)
      .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
      .placeholderColor($r('app.color.native_chat_caption')).onChange(change)
  }

  @Builder
  private settingsLabel(title: () => string) {
    Text(title()).width('100%').fontSize(12).fontColor($r('app.color.native_chat_secondary')).padding({ left: 9, bottom: 4 })
  }

  @Builder
  private settingsRow(title: () => string, value: () => string, click: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Text(title()).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        if (value()) {
          Text(value()).fontSize(13).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '45%' }).fontColor($r('app.color.native_chat_secondary'))
        }
        Image($r('app.media.native_chevron_right')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
      }
      .width('100%').padding({ left: 15, right: 12 })
    }
    .height(48).width('100%').padding(0).borderRadius(0).backgroundColor(Color.Transparent).onClick(click)
  }

  private setLocation(location: NativeUserLocation | null): void {
    this.settings.location = location;
    void this.saveSettings('location');
  }

  @Builder
  private locationSelect(options: () => NativeLocationOption[], current: () => string, placeholder: () => string,
    onSelect: (code: string) => void) {
    Select(options().length > 0 ?
      options().map<SelectOption>((option: NativeLocationOption): SelectOption => ({ value: option.name })) :
      [{ value: placeholder() }])
      .selected(options().findIndex((option: NativeLocationOption): boolean => option.code === current()))
      .value(options().find((option: NativeLocationOption): boolean => option.code === current())?.name ?? placeholder())
      .enabled(options().length > 0)
      .accessibilityText(placeholder())
      .onSelect((index: number) => { onSelect(options()[index]?.code ?? ''); })
  }

  @Builder
  private locationRows() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.label('位置', 'Location')).layoutWeight(1).fontSize(15)
          .fontColor($r('app.color.native_chat_primary'))
        if (this.settings.location) {
          Button(this.label('清除', 'Clear'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(13).onClick(() => { this.setLocation(null); })
        }
      }
      .width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
        if (usesChineseLocationPicker()) {
          this.locationSelect(nativeProvinceOptions, () => this.settings.location?.province ?? '',
            () => this.label('选择省份或地区', 'Select province or region'), (province: string): void => {
              if (province) this.setLocation({ region: 'CN', province });
            })
          this.locationSelect(() => nativeCityOptions(this.settings.location?.province ?? ''),
            () => this.settings.location?.city ?? '', () => this.label('选择城市', 'Select city'), (city: string): void => {
              const province = this.settings.location?.province;
              if (province && city) this.setLocation({ region: 'CN', province, city });
            })
        } else {
          this.locationSelect(() => nativeRegionOptions(this.settings.locale), () => this.settings.location?.region ?? '',
            () => this.label('选择国家或地区', 'Select country or region'), (region: string): void => {
              if (region) this.setLocation({ region });
            })
        }
      }
      Text(this.label('用于让回答参考你选择的位置。', 'Replies can use the location you select.'))
        .width('100%').fontSize(12).fontColor($r('app.color.native_chat_secondary'))
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12, left: 15, right: 12 })
  }

  @Builder
  private settingsRoot() {
    this.settingsLabel(() => this.label('账户', 'Account'))
    Column() {
      this.settingsRow(() => this.label('账号管理', 'Account management'), () =>
        this.accountToken() ? this.account?.label ?? this.label('DeepSeek API 账号', 'DeepSeek API account') : this.settings.model,
        () => { this.settingsSection = 'account'; void this.refreshBalance(); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(() => this.label('API 余额', 'API balance'), () => this.balance?.formatted ?? this.label('前往充值', 'Top up'),
        () => { void this.openLink('https://platform.deepseek.com/top_up'); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(() => this.label('数据管理', 'Data management'),
        () => this.label(`${this.history.sessions.length} 条对话`,
          this.history.sessions.length === 1 ? '1 chat' : `${this.history.sessions.length} chats`),
        () => { this.settingsSection = 'data'; })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel(() => this.label('应用', 'App'))
    Column() {
      Row() {
        Text(this.label('外观', "Theme")).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: this.label('系统', "System") }, { value: this.label('浅色', "Light") }, { value: this.label('深色', "Dark") }])
          .selected(this.settings.theme === 'dark' ? 2 : this.settings.theme === 'light' ? 1 : 0)
          .value(this.settings.theme === 'dark' ? this.label('深色', "Dark") : this.settings.theme === 'light' ? this.label('浅色', "Light") : this.label('系统', "System"))
          .onSelect((index: number) => {
            this.settings.theme = index === 2 ? 'dark' : index === 1 ? 'light' : 'system';
            this.applyTheme();
            void this.saveSettings();
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      Row() {
        Text(this.label('字体大小', "Font size")).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '12px' }, { value: '14px' }, { value: this.label('16px（默认）', "16px (default)") },
          { value: '18px' }, { value: '20px' }, { value: '22px' }])
          .selected(NATIVE_CHAT_FONT_SIZES.indexOf(this.settings.chatFontSize))
          .value(this.settings.chatFontSize === 16 ? this.label('16px（默认）', "16px (default)") : `${this.settings.chatFontSize}px`)
          .onSelect((index: number) => {
            this.settings.chatFontSize = NATIVE_CHAT_FONT_SIZES[index] ?? 16;
            void this.saveSettings();
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      Row() {
        Text(this.label('语言', 'Language')).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '简体中文' }, { value: 'English' }])
          .selected(this.settings.locale === 'en-US' ? 1 : 0)
          .value(this.settings.locale === 'en-US' ? 'English' : '简体中文')
          .onSelect((index: number) => {
            this.settings.locale = index === 1 ? 'en-US' : 'zh-CN';
            this.balanceFetchedAt = 0;
            void this.refreshBalance();
            void this.saveSettings('locale');
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.locationRows()
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel(() => this.label('语音', 'Speech'))
    Column() {
      Row() {
        Text(this.label('语音引擎', 'Speech engine')).layoutWeight(1).fontSize(15)
          .fontColor($r('app.color.native_chat_primary'))
        Select([{ value: this.label('自动', 'Auto') }, { value: this.label('设备原生', 'On-device') },
          { value: this.label('云端', 'Cloud') }])
          .selected(this.settings.speechEngine === 'native' ? 1 : this.settings.speechEngine === 'cloud' ? 2 : 0)
          .value(this.settings.speechEngine === 'native' ? this.label('设备原生', 'On-device') :
            this.settings.speechEngine === 'cloud' ? this.label('云端', 'Cloud') : this.label('自动', 'Auto'))
          .onSelect((index: number) => {
            this.stopVoice();
            this.settings.speechEngine = index === 1 ? 'native' : index === 2 ? 'cloud' : 'auto';
            void this.saveSettings();
          })
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      if (this.settings.speechEngine !== 'native') {
        Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
        Row() {
          Text(this.label('朗读音色', 'Read-aloud voice')).layoutWeight(1).fontSize(15)
            .fontColor($r('app.color.native_chat_primary'))
          Select([{ value: this.label('海星（女声）', 'Stella (female)') },
            { value: this.label('暗潮（男声）', 'Tide (male)') }])
            .selected(this.settings.speechVoice === 'tide' ? 1 : 0)
            .value(this.settings.speechVoice === 'tide' ?
              this.label('暗潮（男声）', 'Tide (male)') : this.label('海星（女声）', 'Stella (female)'))
            .onSelect((index: number) => {
              this.settings.speechVoice = index === 1 ? 'tide' : 'stella';
              void this.saveSettings();
            })
        }
        .width('100%').height(48).padding({ left: 15, right: 12 })
      }
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    Text(this.settings.speechEngine === 'native' ?
      this.label('语音输入与回答朗读由鸿蒙系统语音服务处理', 'HarmonyOS speech services handle voice input and read-aloud.') :
      this.settings.speechEngine === 'cloud' ?
        this.label('云端语音会将录音或朗读文本发送给配置的语音服务。', 'Cloud speech sends recordings or read-aloud text to the configured speech service.') :
        this.label('优先使用鸿蒙系统语音，可用时回退至配置的云端语音服务。',
          'Uses HarmonyOS speech first, with your configured cloud speech service as a fallback.'))
      .width('100%').fontSize(12)
      .fontColor($r('app.color.native_chat_secondary')).padding({ left: 9 })
    this.settingsLabel(() => this.label('关于', 'About'))
    Column() {
      Row() {
        Text(this.label('当前版本', "Current version")).layoutWeight(1).fontSize(15).fontColor($r('app.color.native_chat_primary'))
        Text(this.appVersion).fontSize(13).fontColor($r('app.color.native_chat_secondary'))
      }
      .width('100%').height(48).padding({ left: 15, right: 12 })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(() => this.checkingUpdate ? this.label('检查中...', 'Checking…') : this.label('检查更新', 'Check for updates'),
        () => '', () => { void this.checkUpdate(); })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(() => this.label('隐私政策', 'Privacy policy'), () => '', () => {
        void openNuwaPrivacyPolicy(this.host()).catch(() => {
          this.toast(this.label('无法打开隐私政策', 'Unable to open the privacy policy'));
        });
      })
      Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
      this.settingsRow(() => this.label('更新日志', 'Release notes'), () => '',
        () => { this.settingsSection = 'notes'; void this.loadReleaseNotes(); })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private accountSettings() {
    this.settingsLabel(() => this.label('DeepSeek API 账号', 'DeepSeek API account'))
    Column() {
      if (this.account) {
        Text(this.accountToken() ? this.label(`当前生效：${this.account.label}`, `Active: ${this.account.label}`) :
          this.label(`已登录：${this.account.label}`, `Signed in: ${this.account.label}`))
          .width('100%').fontSize(14).padding(14).fontColor($r('app.color.native_chat_secondary'))
        if (!this.accountToken()) {
          this.settingsRow(() => this.label('切换为此账号', 'Use this account'), () => '', () => { void this.enableAccount(); })
        }
        this.settingsRow(() => this.label('退出登录', 'Sign out'), () => '', () => { void this.logoutAccount(); })
      } else {
        Text(this.label('通过 DeepSeek 开放平台授权登录，免手动复制 API Key', 'Sign in with DeepSeek Platform to authorize API access'))
          .width('100%').fontSize(14).padding(14).fontColor($r('app.color.native_chat_secondary'))
        this.settingsRow(() => this.label('账号登录', 'Sign in'), () => '',
          () => { this.settingsVisible = false; void this.startAuthorization(); })
      }
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel(() => 'API Key')
    Column() {
      this.settingsRow(() => this.settings.apiKey ? this.label('更换 API Key', 'Change API Key') :
        this.label('配置第三方兼容 API', 'Configure 3rd-Party API'), () => this.settings.model,
        () => { this.openCredentialForm(); })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private keySettings() {
    this.settingsLabel(() => this.label('接口协议', 'API Protocol'))
    Select([{ value: this.label('OpenAI 兼容', "OpenAI Compatible") }, { value: this.label('Anthropic 兼容', "Anthropic Compatible") }])
      .selected(this.settingsProtocol === 'anthropic' ? 1 : 0)
      .value(this.settingsProtocol === 'anthropic' ? this.label('Anthropic 兼容', "Anthropic Compatible") : this.label('OpenAI 兼容', "OpenAI Compatible"))
      .onSelect((index: number) => { this.settingsProtocol = index === 1 ? 'anthropic' : 'openai'; })
    this.settingsLabel(() => this.label('API 地址 (Base URL)', 'API Base URL'))
    this.configInput(() => this.settingsBase, () => this.label('例如 https://api.deepseek.com', 'e.g. https://api.deepseek.com'), InputType.Normal,
      (value: string) => { this.settingsBase = value; })
    this.settingsLabel(() => this.label('模型名称', 'Model Name'))
    this.configInput(() => this.settingsModel, () => this.label('例如 deepseek-chat', 'e.g. deepseek-chat'), InputType.Normal,
      (value: string) => { this.settingsModel = value; })
    this.settingsLabel(() => 'API Key')
    this.configInput(() => this.settingsKey, () => allowsKeylessNativeApi(this.settingsBase, this.settingsProtocol) ?
      this.label('局域网服务可留空', 'Optional for local services') : this.label('请输入 API Key', 'Enter API Key'), InputType.Password,
      (value: string) => { this.settingsKey = value; })
    if (this.settingsError) {
      Text(this.settingsError).width('100%').fontSize(13).fontColor($r('app.color.native_chat_error'))
    }
    Button(this.settingsVerifying ? this.label('正在验证...', 'Verifying…') : this.label('验证并继续', 'Verify & Continue'))
      .width('100%')
      .backgroundColor($r('app.color.native_chat_blue')).enabled(!this.settingsVerifying && this.canVerifySettings())
      .onClick(() => { void this.verifySettingsKey(); })
  }

  @Builder
  private settingsPage() {
    Column() {
      Row() {
        if (this.settingsSection === 'root') {
          Blank().width(38)
        } else {
          this.iconButton($r('app.media.native_chevron_left'), this.label('返回', "Back"), () => {
            this.settingsSection = this.settingsSection === 'key' ? 'account' : 'root';
          }, 38, 18)
        }
        Text(this.settingsTitle()).layoutWeight(1).textAlign(TextAlign.Center).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary'))
        Button('×', { buttonStyle: ButtonStyleMode.TEXTUAL }).width(38).height(36).padding(0).fontSize(23)
          .fontColor($r('app.color.native_chat_secondary')).accessibilityText(this.label('关闭', "Close"))
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
              busy: this.backupBusy, sessionCount: this.history.sessions.length, locale: this.settings.locale,
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
        Button(this.label('关闭', "Close"), { buttonStyle: ButtonStyleMode.TEXTUAL }).enabled(!this.storingAccount)
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
      MenuItem({ content: this.label('重命名', "Rename") }).onClick(() => {
        this.renamingId = session.id;
        this.renameText = session.title;
      })
      MenuItem({ content: session.pinnedAt ? this.label('取消置顶', "Unpin") : this.label('置顶', "Pin") }).onClick(() => {
        this.history = toggleConversationPin(this.history, session.id);
        void this.save();
      })
      MenuItem({ content: this.label('删除', "Delete") }).onClick(() => { void this.deleteSessions([session.id]); })
    }
  }

  @Builder
  private drawerItem(session: NativeConversation) {
    Row({ space: 8 }) {
      if (this.selecting) {
        Checkbox({ name: session.id }).select(this.selectedIds.includes(session.id))
          .width(20).height(20).onChange(() => { this.toggleSelected(session.id); })
      }
      Text(session.title || this.label('新对话', "New chat")).fontSize(15).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.native_chat_primary'))
      if (!this.selecting) {
        Button('⋯', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(18).width(32).height(32).padding(0)
          .fontColor($r('app.color.native_chat_secondary')).accessibilityText(this.label('对话选项', "Chat options"))
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
  private drawer(desktop: boolean = false) {
    Column() {
      if (desktop && !this.selecting) {
        Row({ space: 9 }) {
          Image($r('app.media.native_welcome_logo')).width(28).height(28).borderRadius(8).draggable(false)
          Text('Nuwa').fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
            .fontColor($r('app.color.native_chat_primary'))
          this.iconButton($r('app.media.native_menu'), this.label('收起侧边栏', 'Close sidebar'),
            () => { this.setDesktopSidebar(true); }, 34)
        }
        .width('100%').height(42).padding({ left: 6 }).margin({ bottom: 10 })
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 10 }) {
            Image($r('app.media.native_new_chat')).width(17).height(17)
              .colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
            Text(this.label('开启新对话', 'New chat')).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.native_chat_blue_text'))
          }
        }
        .width('100%').height(40).margin({ bottom: 8 }).backgroundColor($r('app.color.native_chat_selected'))
        .onClick(() => { this.activate(null); })
      }
      if (this.selecting) {
        Row() {
          Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.resetSelection(); })
          Text(this.label(`已选择 ${this.selectedIds.length} 项`, `${this.selectedIds.length} selected`))
            .fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
            .textAlign(TextAlign.Center).fontColor($r('app.color.native_chat_primary'))
          Button(this.label('全选', "Select all"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => {
            this.selectedIds = this.groups().flatMap<string>((group: NativeConversationGroup): string[] =>
              group.sessions.map<string>((session: NativeConversation): string => session.id));
          })
        }
        .width('100%').height(44)
      } else {
        Row({ space: 8 }) {
          Image($r('app.media.native_search')).height(16).width(16).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
          TextInput({ text: this.searchText, placeholder: this.label('搜索对话内容...', "Search chats…") }).fontSize(15).height(44).layoutWeight(1)
            .backgroundColor(Color.Transparent).padding(0).onChange((value: string) => { this.searchText = value; })
        }
        .width('100%').borderRadius(14).padding({ left: 14, right: 12 }).backgroundColor($r('app.color.native_chat_field'))
      }
      List({ space: 2 }) {
        if (this.history.sessions.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              Text(this.label('暂无对话', "No chats yet")).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
              Text(this.label('你与 Nuwa 的对话\n将展示在这里', 'Your chats with Nuwa will appear here'))
                .textAlign(TextAlign.Center).fontSize(13)
                .fontColor($r('app.color.native_chat_secondary'))
              Button(this.label('开启新对话', "New chat"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.activate(null); })
            }
            .width('100%').padding({ top: 28 })
          }
        } else if (!this.groups().length) {
          ListItem() {
            Text(this.label('未找到匹配的对话', "No matching chats")).fontSize(14).fontColor($r('app.color.native_chat_secondary')).padding(14)
          }
        }
        ForEach(this.groups(), (group: NativeConversationGroup) => {
          ListItemGroup() {
            ListItem() {
              Text(this.historyGroupLabel(group)).fontSize(13).width('100%')
                .fontColor($r('app.color.native_chat_secondary'))
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
          Button(this.allPinned() ? this.label('取消置顶', "Unpin") : this.label('置顶', "Pin"), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .enabled(this.selectedIds.length > 0).layoutWeight(1).onClick(() => {
              this.history = setConversationsPinned(this.history, this.selectedIds, !this.allPinned());
              this.resetSelection();
              void this.save();
            })
          Button(this.label('删除', "Delete"), { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.native_chat_error'))
            .enabled(this.selectedIds.length > 0).layoutWeight(1).onClick(() => { void this.deleteSessions(this.selectedIds); })
        }
        .height(52).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Image($r('app.media.native_welcome_logo')).width(31).height(31).borderRadius(10).draggable(false)
            Text(this.accountToken() ? this.account?.label ?? this.label('DeepSeek API 账号', "DeepSeek API account") : this.label('设置', "Settings"))
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
    .width(desktop ? 261 : this.drawerWidth()).height('100%').padding({ left: 16, right: 10, top: 14, bottom: 8 })
  }

  @Builder
  private renameDialog() {
    Column({ space: 14 }) {
      Text(this.label('重命名对话', "Rename chat")).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
        TextInput({ text: this.renameText, placeholder: this.label('对话名称', 'Chat title') }).maxLength(100)
        .onChange((title: string) => { this.renameText = title; })
      Row({ space: 8 }) {
        Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL }).onClick(() => { this.renamingId = ''; })
        Button(this.label('保存', "Save")).enabled(!!this.renameText.trim()).onClick(() => {
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
  private messagePager(earlier: boolean) {
    Row({ space: 8 }) {
      Button(earlier ? this.label(`加载更早消息（还有 ${this.earlierCount} 条）`,
        `Load earlier messages (${this.earlierCount} more)`) :
        this.label(`加载后续消息（还有 ${this.laterCount} 条）`, `Load later messages (${this.laterCount} more)`),
        { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
        .height(32).fontSize(12).border({ width: 1, color: $r('app.color.native_chat_stroke') })
        .fontColor($r('app.color.native_chat_secondary')).onClick(() => { this.loadMoreMessages(earlier); })
      if (!earlier) {
        Button(this.label('回到底部', 'Back to bottom'), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(12).border({ width: 1, color: $r('app.color.native_chat_blue') })
          .fontColor($r('app.color.native_chat_blue_text')).onClick(() => { this.jumpToNewestMessages(); })
      }
    }
    .width('100%').justifyContent(FlexAlign.Center).padding({ top: 16, bottom: 8 })
  }

  @Builder
  private composerContainer() {
    Column() { this.composer() }
    .width('100%').constraintSize({ maxWidth: this.wide() ? (this.viewportWidth >= 1024 ? 808 : 680) : 808 })
    .padding({
      left: this.wide() ? 16 : this.compact() ? 6 : 14,
      right: this.wide() ? 16 : this.compact() ? 6 : 14,
      bottom: this.wide() && this.viewportHeight <= 500 ? 16 : this.compact() ? 6 : 14,
    })
  }

  private centeredComposer(): boolean {
    return this.wide() && this.loaded && this.history.activeId === null;
  }

  @Builder
  private chatPage() {
    Column() {
      if (this.wide() && (this.history.activeId !== null || this.settings.desktopSidebarCollapsed)) {
        this.desktopHeader()
      } else if (!this.wide() && this.viewportHeight > 180) {
        this.header()
      }
      if (!this.loaded) {
        Column({ space: 8 }) {
          if (this.status) {
            Text(this.status).fontColor($r('app.color.native_chat_secondary'))
            Button(this.label('重试', "Retry")).onClick(() => { void this.load(); })
          } else {
            LoadingProgress().width(28).height(28).color($r('app.color.native_chat_blue'))
          }
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.history.activeId === null) {
        if (this.centeredComposer()) {
          Column({ space: this.viewportHeight <= 500 ? 18 : 26 }) {
            this.welcome(false)
            this.composerContainer()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          this.welcome()
        }
      } else {
        List({ scroller: this.scroller }) {
          if (this.earlierCount > 0) {
            ListItem() { this.messagePager(true) }
          }
          LazyForEach(this.messageList, (row: NativeMessageRow) => {
            ListItem() {
              if (row.message.role === 'user') {
                this.userMessage(row.message, row.index)
              } else {
                this.assistantMessage(row.message)
              }
            }
          }, (row: NativeMessageRow): string => row.key.toString())
          if (this.laterCount > 0) {
            ListItem() { this.messagePager(false) }
          }
        }
        .width('100%').constraintSize({ maxWidth: this.wide() ? (this.viewportWidth >= 1024 ? 792 : 680) : 840 })
        .layoutWeight(1).scrollBar(BarState.Auto)
        .cachedCount(4).onScrollIndex((start: number) => { this.firstVisibleRow = start; })
        .onScroll((offset: number, state: ScrollState) => { this.observeMessageScroll(offset, state); })
        .onAreaChange((_old: Area, area: Area) => {
          const height = Number(area.height);
          if (height !== this.listViewportHeight) {
            this.listViewportHeight = height;
            if (this.followLatest && this.laterCount === 0) this.scrollToLatest();
          }
        })
        .padding({ left: this.compact() ? 10 : 20, right: this.compact() ? 10 : 20, bottom: 16 })
      }
      if (this.loaded && this.status) {
        Text(this.status).fontSize(13).fontColor($r('app.color.native_chat_error'))
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }
      if (!this.centeredComposer()) {
        this.composerContainer()
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
    .bindSheet($$this.settingsVisible, this.settingsPage(),
      { height: SheetSize.LARGE, blurStyle: BlurStyle.Thick, showClose: false })
  }

  @Builder
  private sourcesSheet() {
    NativeSourcesPanel({
      sources: this.panelSources, title: this.label('搜索结果', 'Search results'), locale: this.settings.locale,
      onClose: () => { this.sourcesVisible = false; },
    })
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.drawerProgress() > 0) {
        this.drawer()
      }
      Row() {
        if (this.wide() && this.loaded && this.authenticated() && !this.settings.desktopSidebarCollapsed) {
          this.drawer(true)
        }
        Stack() {
          if (this.loaded && !this.authenticated()) {
            NativeOnboarding({
              locale: this.settings.locale,
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
        .height('100%').layoutWeight(1)
        if (this.wide() && this.sourcesVisible) {
          Column() { this.sourcesSheet() }
          .width(this.desktopSourcesWidth()).height('100%')
          .backgroundColor($r('app.color.native_chat_bg'))
          .border({ width: { left: 1 }, color: $r('app.color.native_chat_stroke') })
        }
      }
      .width('100%').height('100%').translate({ x: this.drawerProgress() * this.drawerWidth() })
      .scale({ x: 1 - this.drawerProgress() * 0.05, y: 1 - this.drawerProgress() * 0.05, centerX: '0%' })
      .borderRadius(this.drawerProgress() > 0 ? 24 : 0).clip(this.drawerProgress() > 0)
      NativeMathRendererHost()
      if (!this.wide() && this.sourcesVisible) {
        Column() { this.sourcesSheet() }
        .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
      }
      if (this.authorizing) {
        this.authorizationPage()
      }
      if (this.imagePreview) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(this.imagePreview).width('100%').height('100%').objectFit(ImageFit.Contain)
            .backgroundColor(Color.Black).onClick(() => { this.imagePreview = ''; })
          Row() {
            this.iconButton($r('app.media.native_close'), this.label('关闭图片', "Close image"), () => { this.imagePreview = ''; },
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
      if (this.migrationPromptVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {
            if (!this.backupBusy) this.dismissMigrationPrompt();
          })
          NativeMigrationPrompt({
            locale: this.settings.locale, compact: this.compact() || this.viewportHeight < 500, importing: this.backupBusy,
            onMigrate: () => { this.dismissMigrationPrompt(); void this.openHistoryMigration(); },
            onImport: () => { void this.importChatHistory(true); },
            onDismiss: () => { this.dismissMigrationPrompt(); },
          })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_sidebar')).clip(true)
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Number(area.width);
      this.viewportHeight = Number(area.height);
      if (this.wide() && (this.drawerOpen || this.drawerDrag !== 0)) {
        this.drawerOpen = false;
        this.drawerDrag = 0;
      }
    })
    .parallelGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 14 })
        .onActionStart((event: GestureEvent) => { this.touchStart = event.fingerList[0]?.globalX ?? this.viewportWidth; })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.wide() && this.authenticated() && !this.settingsVisible && !this.renamingId && !this.authorizing &&
            !this.imagePreview && !this.shareImportVisible && !this.sourcesVisible && !this.migrationPromptVisible &&
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
