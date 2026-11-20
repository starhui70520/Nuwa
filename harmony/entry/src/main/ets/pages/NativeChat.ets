import { nativeIconTint } from '../native/NativeIconTint';
import { NativeMessageCopyButton } from '../native/NativeMessageCopyButton';
import { common, ConfigurationConstant, wantConstant } from '@kit.AbilityKit';
import { KeyboardAvoidMode, LengthMetrics } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { url, util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { webview } from '@kit.ArkWeb';
import { filePreview } from '@kit.PreviewKit';
import {
  NativeChatClient, NativeChatConfig, NativeChatFileRef, NativeChatMessage, NativeModelError, NativeReplyOutcome,
  usesExtendedNativeRequest,
} from '../native/NativeChatClient';
import { loadNativeAccount, saveNativeAccount } from '../native/NativeAccountStore';
import { allowsKeylessNativeApi, NativeApiCredential, verifyNativeApiCredential } from '../native/NativeApiCredential';
import { NativeDataSettings, NativeMigrationChoiceModel, NativeMigrationChoices } from '../native/NativeDataSettings';
import { NativeSpeechSettings } from '../native/NativeSpeechSettings';
import { NativeFeedbackReport } from '../native/NativeFeedbackReport';
import { recordNativeFeedbackLog } from '../native/NativeFeedbackService';
import { NativeDeepSeekAccount, NativeDeepSeekAccountController,
  NativeDeepSeekExchangeError } from '../native/NativeDeepSeekAccount';
import { NativeOAuthLoopbackServer } from '../native/NativeOAuthLoopbackServer';
import { nativeCredentialError, NativeOnboarding, NativeOnboardingView } from '../native/NativeOnboarding';
import { NativeAttachment, NativeAttachmentQuota, NativeAttachmentUploadError, NativeChatAttachments } from '../native/NativeChatAttachments';
import {
  hasNativeClipboardAttachments, NativeClipboardAttachments, readNativeAttachmentClipboard, releaseNativeAttachmentClipboard,
} from '../native/NativeAttachmentClipboard';
import {
  hasNativeAttachmentDropType, hasNativeBackupDropType, NATIVE_ATTACHMENT_DROP_TYPES, NATIVE_COMPOSER_DROP_TYPES,
  nativeBackupDropUri, readNativeAttachmentDrop,
} from '../native/NativeAttachmentDrop';
import {
  commitChatBackup, hydrateImportedAttachment, importedAttachmentOriginalUri, importedAttachmentPreview,
  NativeChatBackup, nativeArchivedReplyTemplate, NATIVE_BACKUP_UNREADABLE_CONVERSATION,
} from '../native/NativeChatBackup';
import { isBackupSpaceError } from '../native/NativeBackupFiles';
import {
  NativeChatCitation, NativeChatSource, NativeChatSources, nativeSearchResults, safeNativeSourceUrl,
} from '../native/NativeChatSources';
import { NativeSourcesPanel } from '../native/NativeSourcesPanel';
import { NativeVoiceSpectrum } from '../native/NativeVoiceSpectrum';
import { NativeToolTimeline, NativeToolTimelineStep, NativeToolTimelineView } from '../native/NativeToolTimeline';
import { NativeToolTimelinePanel } from '../native/NativeToolTimelinePanel';
import { NativeChatStorage } from '../native/NativeChatStorage';
import {
  appendBranch, createConversation, createConversationMessage, deleteConversations, groupConversations,
  messageVersions, NativeConversation, NativeConversationGroup, NativeConversationMessage, NativeConversationState,
  renameConversation, replaceConversationAttachment, selectConversation, selectMessageVersion,
  setConversationsPinned, toggleConversationPin,
  updateConversationMessage, upsertConversation, visibleMessages,
} from '../native/NativeConversation';
import { NativeMarkdown } from '../native/NativeMarkdown';
import { NativeMathRendererHost } from '../native/NativeMathRendererHost';
import { NativeDraftStorage, NativeStoredDraft } from '../native/NativeDraftStorage';
import { CHAT_PAGE_SIZE, nativeMessageRange, NativeMessageList, NativeMessageRange, NativeMessageRow } from '../native/NativeMessageList';
import { nativeBranchControlsId, nativeBranchControlsTop, NativeBranchScrollAnchor } from '../native/NativeBranchScrollAnchor';
import { NativeMigrationPrompt } from '../native/NativeMigrationPrompt';
import { NativeMigrationIntent } from '../native/NativeMigrationStrategy';
import { hasPendingNativeMigration } from '../native/NativePendingMigration';
import {
  describeNativeReplyFailure, nativeRefusalText, NativeFailedUpload, NativeReplyNotice,
} from '../native/NativeReplyNotice';
import { nativeReplyPrefillBlocks, NativePrefillBlock } from '../native/NativeReplyPrefill';
import { isOfficialNativeReadLinkRoute, NativeReadLink, NativeReadLinkCollector, useNativeReadLink } from '../native/NativeReadLinks';
import {
  createNativeLatestReminder, defaultNativeLocale, nativeCityOptions, NativeLocationOption,
  nativeProvinceOptions, nativeRegionOptions, NativeUserLocation, usesChineseLocationPicker,
} from '../native/NativeLocation';
import { NativeSettings, NativeSettingsController, NATIVE_CHAT_FONT_SIZES } from '../native/NativeSettings';
import {
  createSidebarRows, createSidebarSections, filterSidebarGroups, NativeSidebarRow, NativeSidebarSearch,
  NativeSidebarSection, NativeSidebarSession, normalizeSidebarQuery, SIDEBAR_HISTORY_PAGE_SIZE, visibleSidebarRowIndex,
} from '../native/NativeSidebarHistory';
import { NativeBalanceRequest, NativeBalanceStore, NativeDeepSeekBalance } from '../native/NativeProviderBalance';
import {
  checkNativeUpdate, fetchNativeReleaseHistory, getNativeCurrentVersion, isUpdateSnoozed, NativeReleaseHistoryItem,
  NativeUpdateCheck, NativeUpdatePreferences, NativeUpdateSchedule, UPDATE_POLL_MS, UPDATE_RESUME_MS,
} from '../native/NativeUpdates';
import { NativeUpdateDialog, NativeUpdateDialogModel } from '../native/NativeUpdateDialog';
import { NativeDeleteDialog, NativeDeleteDialogModel, NativeDeleteMode } from '../native/NativeDeleteDialog';
import { importNativeShareLink } from '../native/NativeShareImport';
import { openNuwaPrivacyPolicy } from '../native/PrivacyPolicy';
import { HarmonySpeechRecognition } from '../speech/HarmonySpeechRecognition';
import { HarmonyTextToSpeech } from '../speech/HarmonyTextToSpeech';
import {
  HarmonySpeechEngine, HarmonySpeechOptions, HarmonySpeechVoice, isCloudAsrAvailable, isCloudTtsAvailable,
} from '../speech/HarmonySpeechOptions';

interface NativeReply {
  sessionId: string;
  message: NativeConversationMessage;
  client: NativeChatClient;
  stopped: boolean;
  uploadingIds: string[];
  attachmentBinding: string;
  uploadQuotaShown?: boolean;
  stopPreparing?: () => void;
  resumeRetry?: () => void;
  completion?: Promise<void>;
}

interface NativePreparedReplyFile {
  file?: NativeChatFileRef;
  failure?: NativeFailedUpload;
}

interface NativeDraftAttachment {
  item: NativeAttachment;
  state: 'uploading' | 'ready' | 'failed';
  error: string;
  retryable?: boolean;
}

interface NativeDraft {
  text: string;
  files: NativeDraftAttachment[];
}

interface NativeSidebarScrollPosition {
  query: string;
  offset: number;
  sessionId: string;
  rowIndex: number;
}

const EMPTY_TIMELINE: NativeToolTimelineView = { steps: [], answer: '', answerOffset: 0 };
const MIGRATION_PREFERENCES = 'nuwa_native_migration';
const MIGRATION_USED_KEY = 'one_click_used';
const DEEPSEEK_DOCS_URL = 'https://api-docs.deepseek.com/zh-cn/';
const DELETE_FILE_DOCS_URL = 'https://api-docs.deepseek.com/api/delete-file';
const HISTORY_SAVE_RETRY_DELAYS = [1000, 2500];

@Component
struct NativeAssistantMessageRow {
  @ObjectLink row: NativeMessageRow;
  @BuilderParam content: (message: () => NativeConversationMessage, index: number) => void;

  build() {
    this.content(() => this.row.message, this.row.index)
  }
}

@Entry
@Component
struct NativeChat {
  @State @Watch('syncHistoryViews') private history: NativeConversationState = { sessions: [], activeId: null };
  @State private earlierCount: number = 0;
  @State private laterCount: number = 0;
  @State private visibleMessageCount: number = 0;
  @State private messageActionsId: string = '';
  @State private hoveredMessageId: string = '';
  @State private settings: NativeSettings = {
    baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat', apiKey: '', protocol: 'openai', authMode: 'api-key',
    signedOut: false,
    theme: 'system', chatFontSize: 16, attachmentBinding: '', thinking: false, search: false, ttsMuted: true,
    speechEngine: 'auto', speechVoice: 'stella', migrationPromptHandled: false,
    desktopSidebarCollapsed: false,
    locale: defaultNativeLocale(), location: null,
  };
  @State private draft: string = '';
  @State private draftFiles: NativeDraftAttachment[] = [];
  @State private uploadQuotaText: string = '';
  @State private attachmentIntakeDraftId: string | null = null;
  @State private fileDropHint: 'attachment' | 'history' | null = null;
  @State private imagePreview: string = '';
  @State private loaded: boolean = false;
  @State private retryingConversationIds: string[] = [];
  @State private status: string = '';
  @State private historySaveError: boolean = false;
  @State private drawerOpen: boolean = false;
  @State private drawerDrag: number = 0;
  @State private searchText: string = '';
  @State private sidebarRows: NativeSidebarRow[] = [];
  @State private sidebarSections: NativeSidebarSection[] = [];
  @State private selectedIds: string[] = [];
  @State private selecting: boolean = false;
  @State private settingsVisible: boolean = false;
  private readonly settingsScroll = new Scroller();
  private settingsDragStartedAt: number = 0;
  @State private migrationPromptVisible: boolean = false;
  @State private migrationChoice: NativeMigrationChoiceModel | null = null;
  private readonly migrationChoiceController = new CustomDialogController({
    builder: NativeMigrationChoices({
      model: this.$migrationChoice,
      onChoose: (intent: NativeMigrationIntent): void => { void this.openHistoryMigration(intent); },
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    maskColor: '#5C000000',
    autoCancel: true,
    onWillDismiss: (action: DismissDialogAction): void => {
      this.closeMigrationChoice(false);
      action.dismiss();
    },
  });
  @State private voiceInputPhase: 'idle' | 'starting' | 'recording' | 'transcribing' = 'idle';
  @State private recordingSeconds: number = 0;
  @State private voiceLevel: number = 0;
  @State private composerToggleWidth: number = 0;
  @State private compactToolsOpen: boolean = false;
  @State private onboardingView: NativeOnboardingView = 'home';
  @State private account: NativeDeepSeekAccount | null = null;
  @State private balance: NativeDeepSeekBalance | null = null;
  @State private authorizing: boolean = false;
  private authorizationReturnToAccount: boolean = false;
  private authorizationSuccessPending: boolean = false;
  @State private storingAccount: boolean = false;
  @State private authorizationUrl: string = '';
  @State private authorizationInBrowser: boolean = false;
  @State private authorizationStatus: string = '';
  @State private authorizationRetry: boolean = false;
  @State private authAttempt: number = 0;
  @State private settingsSection: string = 'root';
  @State private settingsKey: string = '';
  @State private settingsKeyEditing: boolean = false;
  @State private settingsBase: string = '';
  @State private settingsModel: string = '';
  @State private settingsProtocol: 'openai' | 'anthropic' = 'openai';
  @State private settingsVerifying: boolean = false;
  @State private signingOut: boolean = false;
  @State private settingsError: string = '';
  @State private backupBusy: boolean = false;
  @State private historyImportProgress: string = '';
  @State private historyImportResult: string = '';
  @State private historyImportFailed: boolean = false;
  @State private shareImportVisible: boolean = false;
  @State private sourcePanelEntry: string = '';
  @State private panelSources: NativeChatSource[] = [];
  @State private appVersion: string = '';
  @State private checkingUpdate: boolean = false;
  @State private releaseNotes: NativeReleaseHistoryItem[] = [];
  @State private notesLoading: boolean = false;
  @State private notesError: boolean = false;
  @State private shareInput: string = '';
  @State private shareImportError: string = '';
  private committingHistoryImport: boolean = false;
  private deletingSessions: boolean = false;
  private deletingSessionIds = new Set<string>();
  private deleteSessionIds: string[] = [];
  @State private deleteNotice: NativeDeleteDialogModel | null = null;
  private readonly deleteNoticeController = new CustomDialogController({
    builder: NativeDeleteDialog({
      model: this.$deleteNotice,
      onCancel: () => { if (!this.deleteNotice?.busy) this.closeDeleteNotice(); },
      onConfirm: () => { void this.confirmDeleteSessions(); },
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    maskColor: '#5C000000',
    autoCancel: true,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (this.deleteNotice?.busy) return;
      this.closeDeleteNotice(false);
      action.dismiss();
    },
  });
  @State private renamingId: string = '';
  @State private editId: string = '';
  @State private renameText: string = '';
  @State private editText: string = '';
  private editorComposing: boolean = false;
  private editorFocusPending: string = '';
  private readonly messageEditor = new TextAreaController();
  private readonly composerEditor = new TextAreaController();
  private composerSelection: TextRange = {};
  @State private replies: NativeReply[] = [];
  private readonly stoppedUploadReplies = new Map<NativeChatClient, NativeReply>();
  @State private recognitionId: string = '';
  @State private readingId: string = '';
  @State private collapsedThoughts: string[] = [];
  @State private viewportWidth: number = 390;
  @State private viewportHeight: number = 820;

  private readonly storage = new NativeChatStorage();
  private historySaveSequence: number = 0;
  private historyFullSaveSequence: number = 0;
  private historyFailedSaveSequence: number = 0;
  private historySaveRetryAttempt: number = 0;
  private historySaveRetryTimer: number = -1;
  private readonly draftStorage = new NativeDraftStorage();
  private readonly draftHistoryWrites = new Map<string, string>();
  private readonly removedDraftFiles = new Map<string, NativeAttachment>();
  private draftStorageReady: boolean = false;
  private draftSaving: boolean = false;
  private draftDirty: boolean = false;
  private draftSaveTimer: number = -1;
  private uploadQuotaTimer: number = -1;
  private readonly settingsStore = new NativeSettingsController();
  private readonly updateSchedule = new NativeUpdateSchedule();
  private updatePreferences: NativeUpdatePreferences = { checkAt: 0, dismissedAt: 0, dismissedVersion: '' };
  private pendingUpdate: NativeUpdateCheck | null = null;
  @State private updateNotice: NativeUpdateDialogModel | null = null;
  private readonly updateNoticeController = new CustomDialogController({
    builder: NativeUpdateDialog({
      model: this.$updateNotice,
      onLater: () => { this.closeUpdateNotice(true); },
      onDownload: () => { this.openUpdateDestination(); },
    }),
    customStyle: true,
    alignment: DialogAlignment.Center,
    autoCancel: true,
    maskColor: '#5C000000',
    cancel: () => { this.closeUpdateNotice(true, false); },
  });
  private updateTimer: number = -1;
  private readonly attachments = new NativeChatAttachments();
  private readonly backup = new NativeChatBackup();
  private readonly accountController = new NativeDeepSeekAccountController();
  private authBrowser = new webview.WebviewController();
  private recordingTimer: number = -1;
  private readonly authorizationLoopback = new NativeOAuthLoopbackServer();
  private readonly balanceStore = new NativeBalanceStore();
  private balanceRequest?: NativeBalanceRequest;
  private balanceFetchedAt: number = 0;
  private balanceBinding: string = '';
  private balanceLocale: string = '';
  private balanceRateLimitedUntil: number = 0;
  private balanceRefreshTimer: number = -1;
  private balanceRefreshEnabled: boolean = true;
  @State private migrationInProgress: boolean = false;
  private migrationNavigationStarted: boolean = false;
  private migrationPageWasHidden: boolean = false;
  @State private reloadingMigratedHistory: boolean = false;
  @State private migrationReloadFailed: boolean = false;
  private migrationUsed: boolean = false;
  private coldMigrationChecked: boolean = false;
  private readonly scroller = new Scroller();
  private readonly sidebarScroller = new ListScroller();
  private readonly sidebarSearch = new NativeSidebarSearch();
  private sidebarDrawerReady: boolean = false;
  private sidebarDrawerFirst?: VisibleListContentInfo;
  private sidebarDrawerPosition?: NativeSidebarScrollPosition;
  private sidebarSessions?: NativeConversation[];
  private sidebarGroups: NativeConversationGroup[] = [];
  private filteredSidebarGroups: NativeConversationGroup[] = [];
  private sidebarMatches: Set<string> = new Set<string>();
  private sidebarQuery: string = '';
  private sidebarLimit: number = SIDEBAR_HISTORY_PAGE_SIZE;
  private sidebarResultCount: number = 0;
  private sidebarDateTimer: number = -1;
  private readonly messageList = new NativeMessageList();
  private readonly branchScrollAnchor = new NativeBranchScrollAnchor();
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
  private rejectedImageBinding: string = '';
  private rejectedHistoryImages: Set<string> = new Set();
  private streamFrame: number = -1;
  private touchStart: number = 0;
  private titleTap: number = 0;
  private readonly recognition = new HarmonySpeechRecognition((id: string, state: string, text?: string, code?: string) => {
    if (id !== this.recognitionId) {
      return;
    }
    if (state === 'started') {
      this.voiceInputPhase = 'recording';
      this.startRecordingClock();
    } else if (state === 'limit') {
      this.toast(this.label('已达到单次录音时长上限', 'Maximum recording length reached'));
    } else if (state === 'transcribing') {
      this.voiceInputPhase = 'transcribing';
      this.stopRecordingClock();
    } else if (state === 'done' || state === 'error' || state === 'cancelled') {
      this.voiceInputPhase = 'idle';
      this.stopRecordingClock();
      this.recognitionId = '';
    }
    if (state === 'done') {
      const result = text?.trim() ?? '';
      if (result) {
        this.insertComposerText(result, this.composerSelection, true);
      } else {
        this.toast(this.label('未识别到语音内容', 'No speech detected'));
      }
    } else if (state === 'error') {
      void recordNativeFeedbackLog(this.host(), 'warn', 'speech', 'Voice input unavailable', code);
      this.toast(this.speechError(code, true));
    }
  }, (id: string, level: number) => {
    if (id === this.recognitionId && this.voiceInputPhase === 'recording' && !this.wide()) {
      this.voiceLevel = level;
    }
  });
  private readonly speaker = new HarmonyTextToSpeech((id: string, state: string, code?: string) => {
    if (id === this.readingId && state !== 'playing') {
      this.readingId = '';
      if (state === 'error' || state === 'unavailable') {
        void recordNativeFeedbackLog(this.host(), 'warn', 'speech', 'Read-aloud unavailable', code);
        this.toast(this.speechError(code, false));
      }
    }
  });

  aboutToAppear(): void {
    this.balanceRefreshEnabled = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    void this.load();
    void getNativeCurrentVersion().then((version: string) => { this.appVersion = version; }).catch(() => {});
    void this.startUpdateChecks();
  }

  onPageShow(): void {
    this.visible = true;
    this.showPendingAuthorizationSuccess();
    this.refreshSidebarHistory();
    this.scheduleSidebarDateRefresh();
    if (this.replies.length) this.replies = Array.from(this.replies);
    if (this.loaded) {
      void this.refreshBalance();
    }
    if (this.updateTimer >= 0) {
      void this.resumeUpdateChecks();
    }
    if (this.migrationInProgress) {
      if (this.migrationPageWasHidden) void this.reloadMigratedHistory();
    } else {
      this.retryHistorySave();
    }
  }

  private async reloadMigratedHistory(): Promise<void> {
    if (this.reloadingMigratedHistory) return;
    this.reloadingMigratedHistory = true;
    let reloaded = false;
    try {
      const history = await this.storage.loadConversations(this.host());
      if (history.activeId !== this.history.activeId) {
        this.rememberCurrentDraft();
        this.stopVoice();
        this.closeMessageEditor();
        this.history = history;
        this.restoreDraft(history.activeId ?? '');
      } else {
        this.history = history;
      }
      reloaded = true;
    } catch {
      this.cancelHistorySaveRetry();
      this.migrationReloadFailed = true;
      this.toast(this.label('无法读取导入的对话', "Unable to load imported chats"));
    } finally {
      this.reloadingMigratedHistory = false;
      if (reloaded) {
        this.migrationReloadFailed = false;
        this.migrationPageWasHidden = false;
        this.migrationNavigationStarted = false;
        this.migrationInProgress = false;
        this.restoreAuthorizationSettings();
        this.retryHistorySave();
      }
    }
  }

  onPageHide(): void {
    if (this.migrationNavigationStarted && !this.migrationPageWasHidden) {
      this.migrationPageWasHidden = true;
      this.cancelAllReplies();
    }
    this.branchScrollAnchor.cancel();
    this.fileDropHint = null;
    this.clearUploadQuota();
    this.sidebarSearch.cancel();
    this.visible = false;
    clearTimeout(this.sidebarDateTimer);
    this.sidebarDateTimer = -1;
    this.cancelHistorySaveRetry();
    if ((this.replies.length || this.hasPendingHistorySave()) && !this.backupBusy && !this.migrationInProgress) {
      void this.save();
    }
    if (this.draftSaveTimer >= 0) {
      clearTimeout(this.draftSaveTimer);
      this.draftSaveTimer = -1;
    }
    if (this.draftDirty) void this.persistDrafts();
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
    this.closeDeleteNotice();
    this.closeUpdateNotice(false);
    this.closeMigrationChoice();
    this.balanceRefreshEnabled = false;
    this.resetBalance();
    this.cancelAllReplies();
    this.stopVoice();
    this.speaker.destroy();
    this.closeAuthorization();
    this.authorizationReturnToAccount = false;
    this.authorizationSuccessPending = false;
    if (this.updateTimer >= 0) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }

  onBackPress(): boolean {
    if (this.signingOut) return true;
    if (this.deleteNotice) {
      if (!this.deleteNotice.busy) this.closeDeleteNotice();
    } else if (this.updateNotice) {
      this.closeUpdateNotice(true);
    } else if (this.imagePreview) {
      this.imagePreview = '';
    } else if (this.authorizing) {
      this.cancelAuthorization();
    } else if (this.sourcePanelEntry) {
      this.closeSources();
    } else if (this.shareImportVisible) {
      this.closeShareImport();
    } else if (this.migrationChoice) {
      this.closeMigrationChoice();
    } else if (this.migrationPromptVisible) {
      if (!this.backupBusy) this.dismissMigrationPrompt();
    } else if (this.settingsVisible) {
      if (this.settingsSection === 'root') this.closeSettings();
      else this.returnToSettings();
    } else if (this.renamingId) {
      this.cancelSidebarRename(this.renamingId);
    } else if (this.selecting) {
      this.resetSelection();
    } else if (this.drawerOpen) {
      this.setDrawer(false);
    } else if (this.editId) {
      this.closeMessageEditor();
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
    this.clearUploadQuota();
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private showUploadQuota(quota: NativeAttachmentQuota): void {
    this.clearUploadQuota();
    this.uploadQuotaText = quota.kind === 'count' ?
      this.label(`已上传文件数达到上限（${quota.limit} 个），可 `, `Uploaded file limit reached (${quota.limit} files). `) :
      this.label(`已上传文件占用空间达到上限（${quota.limit}GB），可 `,
        `Uploaded file storage limit reached (${quota.limit} GB). `);
    this.uploadQuotaTimer = setTimeout(() => { this.clearUploadQuota(); }, 5000);
  }

  private clearUploadQuota(): void {
    if (this.uploadQuotaTimer >= 0) {
      clearTimeout(this.uploadQuotaTimer);
      this.uploadQuotaTimer = -1;
    }
    if (this.uploadQuotaText) this.uploadQuotaText = '';
  }

  private async load(): Promise<void> {
    this.status = '';
    try {
      const context = this.host();
      this.history = await this.storage.loadConversations(context);
      try {
        this.settings = await this.settingsStore.load(context);
        if (this.updateNotice) this.presentUpdate(this.updateNotice.update);
        if (this.settings.signedOut) {
          this.account = null;
          void this.balanceStore.clear(context);
          await saveNativeAccount(null).catch(() => {});
        } else {
          this.account = await loadNativeAccount();
        }
        if (this.account && !this.settings.apiKey &&
          !allowsKeylessNativeApi(this.settings.baseUrl, this.settings.protocol)) {
          this.settings.authMode = 'deepseek-account';
        }
        void this.refreshBalance();
      } catch {
        this.toast(this.label('无法读取已保存的服务设置', 'Unable to load the saved API configuration'));
      }
      await this.loadDrafts(context);
      await this.loadMigrationUsed(context);
      this.loaded = true;
      this.applyTheme();
      this.scrollToLatest();
      if (!this.coldMigrationChecked) {
        this.coldMigrationChecked = true;
        if (hasPendingNativeMigration(context)) void this.openHistoryMigration();
      }
    } catch {
      this.status = this.label('无法读取本地会话', "Unable to load local chats");
    }
  }

  private async save(context: common.UIAbilityContext = this.host(), checkpoint: boolean = false): Promise<void> {
    if (!this.loaded || this.deletingSessions || this.committingHistoryImport || this.migrationNavigationStarted) return;
    const sequence = ++this.historySaveSequence;
    let full = !checkpoint || this.hasPendingHistorySave();
    try {
      let snapshot = this.historyWithPartialReplies();
      if (!full) {
        const dirty = this.replies.map<string>((reply: NativeReply): string => reply.sessionId);
        try {
          await this.storage.saveConversations(context, snapshot, dirty);
        } catch (error) {
          if (this.deletingSessions) return;
          // Retry with the current history after the import replaces its snapshot.
          if (this.committingHistoryImport || this.migrationNavigationStarted) throw error as Error;
          full = true;
          snapshot = this.historyWithPartialReplies();
          await this.storage.saveConversations(context, snapshot);
        }
      } else {
        await this.storage.saveConversations(context, snapshot);
      }
      if (full) {
        this.historyFullSaveSequence = Math.max(sequence, this.historyFullSaveSequence);
        if (!this.hasPendingHistorySave()) {
          this.historySaveError = false;
          this.historySaveRetryAttempt = 0;
          this.cancelHistorySaveRetry();
        }
      }
      this.acknowledgeSentDrafts(snapshot);
    } catch {
      if (sequence > this.historyFullSaveSequence) {
        this.historyFailedSaveSequence = Math.max(this.historyFailedSaveSequence, sequence);
        this.scheduleHistorySaveRetry();
      }
    }
  }

  private hasPendingHistorySave(): boolean {
    return this.historyFailedSaveSequence > this.historyFullSaveSequence;
  }

  private cancelHistorySaveRetry(): void {
    if (this.historySaveRetryTimer >= 0) {
      clearTimeout(this.historySaveRetryTimer);
      this.historySaveRetryTimer = -1;
    }
  }

  private scheduleHistorySaveRetry(): void {
    if (this.historySaveRetryAttempt >= HISTORY_SAVE_RETRY_DELAYS.length) {
      this.historySaveError = true;
      return;
    }
    if (!this.visible || this.historySaveRetryTimer >= 0) return;
    this.historySaveRetryTimer = setTimeout(() => {
      this.historySaveRetryTimer = -1;
      if (!this.hasPendingHistorySave()) return;
      if (this.backupBusy || this.migrationInProgress || this.signingOut) {
        this.scheduleHistorySaveRetry();
        return;
      }
      this.historySaveRetryAttempt++;
      void this.save();
    }, HISTORY_SAVE_RETRY_DELAYS[this.historySaveRetryAttempt]);
  }

  private retryHistorySave(): void {
    if (this.migrationReloadFailed) {
      void this.reloadMigratedHistory();
      return;
    }
    if (!this.loaded || !this.hasPendingHistorySave()) return;
    if (this.backupBusy || this.migrationInProgress || this.signingOut) {
      this.scheduleHistorySaveRetry();
      return;
    }
    this.cancelHistorySaveRetry();
    this.historySaveRetryAttempt = 0;
    void this.save();
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
      signedOut: this.settings.signedOut,
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

  private historyGroupLabel(key: string, label: string): string {
    if (this.settings.locale === 'en-US') {
      switch (key) {
        case 'pinned': return 'Pinned';
        case 'today': return 'Today';
        case 'yesterday': return 'Yesterday';
        case 'week': return '7 Days';
        case 'month': return '30 Days';
      }
    }
    return label;
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
    return !this.settings.signedOut && this.settings.authMode === 'deepseek-account' ? this.account?.token ?? '' : '';
  }

  private authenticated(): boolean {
    return !this.settings.signedOut && (!!this.settings.apiKey || !!this.accountToken() ||
      (!!this.settings.model.trim() && allowsKeylessNativeApi(this.settings.baseUrl, this.settings.protocol)));
  }

  private resetBalance(clearCached: boolean = false): void {
    clearTimeout(this.balanceRefreshTimer);
    this.balanceRefreshTimer = -1;
    this.balanceRequest?.cancel();
    this.balanceRequest = undefined;
    this.balance = null;
    this.balanceFetchedAt = 0;
    this.balanceRateLimitedUntil = 0;
    if (clearCached) {
      this.balanceBinding = '';
      void this.balanceStore.clear(this.host());
    }
  }

  private async refreshBalance(force: boolean = false): Promise<void> {
    if (!this.balanceRefreshEnabled || this.signingOut) return;
    const token = this.accountToken();
    const key = this.settings.signedOut ? '' : this.settings.apiKey.trim();
    const binding = this.settings.attachmentBinding;
    const locale = this.settings.locale;
    if (binding !== this.balanceBinding) {
      const previousBinding = this.balanceBinding;
      this.resetBalance();
      this.balanceBinding = binding;
      this.balanceLocale = locale;
      if (previousBinding) void this.balanceStore.clear(this.host(), previousBinding);
    } else if (locale !== this.balanceLocale) {
      this.balanceRequest?.cancel();
      this.balanceRequest = undefined;
      this.balance = null;
      this.balanceFetchedAt = 0;
      this.balanceLocale = locale;
    }
    if (!token && !key) return;
    const now = Date.now();
    if (this.balance && now < this.balanceRateLimitedUntil) return;
    if (!force && (this.balanceRequest || (this.balance && now - this.balanceFetchedAt < 15000))) return;
    this.balanceRequest?.cancel();
    const request = new NativeBalanceRequest();
    this.balanceRequest = request;
    const context = this.host();
    const isCurrent = (): boolean => this.balanceRequest === request && this.settings.attachmentBinding === binding &&
      this.settings.locale === locale && !this.settings.signedOut && !this.signingOut;
    try {
      if (!this.balance) {
        const cached = await this.balanceStore.load(context, binding, locale);
        if (!isCurrent()) return;
        if (cached) this.balance = cached;
      }
      if (Date.now() < this.balanceRateLimitedUntil) return;
      const balance = await request.fetch(this.settings.baseUrl, key, token, locale);
      if (!isCurrent()) return;
      if (request.retryAfterMs) this.balanceRateLimitedUntil = Date.now() + request.retryAfterMs;
      if (balance) {
        this.balance = balance;
        this.balanceFetchedAt = Date.now();
        void this.balanceStore.save(context, binding, locale, balance);
      }
    } finally {
      if (this.balanceRequest === request) this.balanceRequest = undefined;
    }
  }

  private queueBalanceRefresh(binding: string): void {
    if (!this.balanceRefreshEnabled || this.signingOut || this.settings.signedOut ||
      this.settings.attachmentBinding !== binding) return;
    clearTimeout(this.balanceRefreshTimer);
    void this.refreshBalance(true);
    this.balanceRefreshTimer = setTimeout(() => {
      this.balanceRefreshTimer = -1;
      if (this.settings.attachmentBinding === binding) void this.refreshBalance(true);
    }, 2500);
  }

  private async connectKey(credential: NativeApiCredential): Promise<void> {
    if (this.signingOut) throw new Error(this.label('正在退出登录，请稍候', 'Signing out. Please wait.'));
    const settings = this.settingsSnapshot();
    settings.apiKey = credential.apiKey;
    settings.baseUrl = credential.baseUrl;
    settings.model = credential.model;
    settings.protocol = credential.protocol;
    settings.authMode = 'api-key';
    settings.signedOut = false;
    settings.attachmentBinding = util.generateRandomUUID(true);
    await this.settingsStore.save(this.host(), settings, undefined, true);
    this.settings = settings;
    this.onboardingView = 'home';
    if (settings.apiKey) {
      this.offerMigrationPrompt();
    }
    void this.refreshBalance();
  }

  private prepareCredentialSettings(): void {
    this.settingsKey = '';
    this.settingsKeyEditing = false;
    this.settingsBase = this.settings.baseUrl;
    this.settingsModel = this.settings.model;
    this.settingsProtocol = this.settings.protocol;
    this.settingsError = '';
  }

  private settingsEndpointMatches(): boolean {
    return this.settingsBase.trim() === this.settings.baseUrl.trim() && this.settingsProtocol === this.settings.protocol;
  }

  private commitSettingsModel(): void {
    const model = this.settingsModel.trim();
    if (this.settingsVerifying || !model || !this.settingsEndpointMatches() || model === this.settings.model) return;
    this.settings.model = model;
    void this.saveSettings();
  }

  private finishCredentialSettings(): void {
    this.commitSettingsModel();
    this.settingsKey = '';
    this.settingsKeyEditing = false;
    this.settingsError = '';
  }

  private editSettingsKey(): void {
    this.settingsKeyEditing = true;
    setTimeout(() => {
      if (this.settingsVisible && this.settingsSection === 'account' && this.settingsKeyEditing) {
        this.getUIContext().getFocusController().requestFocus('nuwa-account-api-key');
      }
    }, 0);
  }

  private finishSettingsKeyEdit(): void {
    if (this.settings.apiKey && !this.settingsKey.trim() && this.settingsEndpointMatches()) {
      this.settingsKey = '';
      this.settingsKeyEditing = false;
      this.settingsError = '';
    }
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
      this.prepareCredentialSettings();
    } catch (error) {
      this.settingsError = nativeCredentialError(error as Error, this.settings.locale);
    } finally {
      this.settingsVerifying = false;
    }
  }

  private canVerifySettings(): boolean {
    return !!this.settingsBase.trim() && !!this.settingsModel.trim() &&
      (!!this.settingsKey.trim() || allowsKeylessNativeApi(this.settingsBase, this.settingsProtocol));
  }

  private async startAuthorization(inBrowser: boolean = false): Promise<void> {
    if (this.authorizing || this.signingOut || this.backupBusy || this.settingsVerifying) {
      return;
    }
    this.authorizationReturnToAccount = this.settingsVisible && this.settingsSection === 'account';
    this.authorizing = true;
    if (this.authorizationReturnToAccount) this.settingsVisible = false;
    await this.loadAuthorization(inBrowser);
  }

  private async loadAuthorization(inBrowser: boolean, refreshing: boolean = false): Promise<void> {
    this.authorizationUrl = '';
    this.authorizationInBrowser = inBrowser;
    this.authorizationRetry = false;
    this.authorizationStatus = refreshing ?
      this.label('换取账号令牌失败，正在刷新授权页面…', 'Could not get an account token. Reloading the sign-in page…') :
      this.label('正在连接 DeepSeek 开放平台…', 'Connecting to DeepSeek Platform…');
    const attempt = ++this.authAttempt;
    try {
      const callback = inBrowser ? await this.authorizationLoopback.start(
        (target: string): boolean => this.handleAuthorizationCallback(target, attempt),
        (reason: 'timeout' | 'unavailable'): void => {
          if (attempt !== this.authAttempt) return;
          this.offerAuthorizationRetry(reason === 'timeout' ? this.label('授权已超时，请重试', 'Authorization timed out. Please try again.') :
            this.label('浏览器授权连接中断，请重试', 'Connection to browser sign-in was lost. Please try again.'));
        }) : undefined;
      if (attempt !== this.authAttempt) return;
      const challenge = await this.accountController.startLogin(this.host(),
        this.settings.locale === 'en-US' ? 'en_US' : 'zh_CN', callback);
      if (attempt !== this.authAttempt) return;
      if (inBrowser) {
        this.authorizationStatus = this.label('请在系统浏览器完成授权后返回 Nuwa', 'Finish authorizing in your browser, then return to Nuwa.');
        await this.host().openLink(challenge.authorizeUrl, { appLinkingOnly: false });
      } else {
        this.authorizationStatus = this.label('请登录并授权 Nuwa 使用你的 DeepSeek API 账号', "Sign in to authorize Nuwa to use your DeepSeek API account");
        this.authBrowser = new webview.WebviewController();
        this.authorizationUrl = challenge.authorizeUrl;
      }
    } catch (error) {
      if (attempt === this.authAttempt) {
        this.offerAuthorizationRetry(this.label('连接开放平台失败，请检查网络后重试',
          'Could not connect to DeepSeek Platform. Check your connection and try again.'));
        this.toast((error as Error).message || this.label('无法连接 DeepSeek 开放平台', 'Unable to connect to DeepSeek Platform'));
      }
    }
  }

  private switchAuthorizationToBrowser(): void {
    if (!this.authorizationUrl || this.authorizationInBrowser || this.storingAccount) return;
    this.resetAuthorizationAttempt();
    void this.loadAuthorization(true);
  }

  private cancelAuthorization(): void {
    if (this.storingAccount) return;
    this.closeAuthorization();
    this.restoreAuthorizationSettings();
  }

  private closeAuthorization(): void {
    this.resetAuthorizationAttempt();
    this.authorizationInBrowser = false;
    this.authorizationRetry = false;
    this.authorizing = false;
  }

  private restoreAuthorizationSettings(): void {
    if (!this.authorizationReturnToAccount) return;
    this.authorizationReturnToAccount = false;
    this.settingsSection = 'account';
    this.settingsVisible = true;
  }

  private showPendingAuthorizationSuccess(): void {
    if (!this.visible || !this.authorizationSuccessPending) return;
    this.authorizationSuccessPending = false;
    this.toast(this.label('已登录 DeepSeek API 账号', 'Signed in to DeepSeek API account'));
  }

  private resetAuthorizationAttempt(): void {
    this.authAttempt++;
    this.authorizationLoopback.stop();
    this.accountController.cancel();
    this.authorizationUrl = '';
  }

  private offerAuthorizationRetry(message: string): void {
    this.resetAuthorizationAttempt();
    this.authorizationStatus = message;
    this.authorizationRetry = true;
  }

  private interceptAuthorization(target: string, mainFrame: boolean): boolean {
    if (this.accountController.isRedirect(target)) {
      if (!this.authorizationInBrowser) this.handleAuthorizationCallback(target, this.authAttempt);
      return true;
    }
    try {
      const location = url.URL.parseURL(target);
      if (location.protocol !== 'https:' || location.username || location.password ||
        (location.port && location.port !== '443')) return true;
      if (location.hostname === 'platform.deepseek.com') return false;
      if (mainFrame && this.authorizationUrl) {
        this.authorizationStatus = this.label('请使用系统浏览器完成第三方登录', 'Use your browser to finish third-party sign-in.');
      }
      return true;
    } catch {
      return true;
    }
  }

  private handleAuthorizationCallback(target: string, attempt: number): boolean {
    if (!this.authorizing || attempt !== this.authAttempt || !this.accountController.canHandleRedirect(target)) return false;
    void this.consumeAuthorization(target, attempt);
    return true;
  }

  private async consumeAuthorization(target: string, attempt: number): Promise<void> {
    this.authorizationStatus = this.label('正在确认授权…', "Completing authorization…");
    try {
      const account = await this.accountController.handleRedirect(target);
      if (!account || attempt !== this.authAttempt) {
        return;
      }
      const settings = this.settingsSnapshot();
      settings.authMode = 'deepseek-account';
      settings.signedOut = false;
      settings.attachmentBinding = util.generateRandomUUID(true);
      const context = this.host();
      this.storingAccount = true;
      try {
        await saveNativeAccount(account);
        try {
          await this.settingsStore.save(context, settings);
        } catch (error) {
          await saveNativeAccount(this.account).catch(() => {});
          throw error as Error;
        }
      } finally {
        this.storingAccount = false;
      }
      if (attempt !== this.authAttempt) return;
      this.account = account;
      this.settings = settings;
      this.onboardingView = 'home';
      this.closeAuthorization();
      if (!this.offerMigrationPrompt()) this.restoreAuthorizationSettings();
      this.authorizationSuccessPending = true;
      this.showPendingAuthorizationSuccess();
      void this.refreshBalance();
    } catch (error) {
      if (attempt === this.authAttempt) {
        const message = this.label('换取账号令牌失败，请重试', 'Could not get an account token. Please try again.');
        if (error instanceof NativeDeepSeekExchangeError && !this.authorizationInBrowser) {
          this.resetAuthorizationAttempt();
          void this.loadAuthorization(false, true);
        } else {
          this.offerAuthorizationRetry(error instanceof NativeDeepSeekExchangeError ? message :
            this.label('DeepSeek 授权未完成，请重试', 'DeepSeek authorization did not complete. Please try again.'));
        }
        this.toast((error as Error).message || message);
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
      this.resetBalance(true);
      this.settings.authMode = 'api-key';
      this.settings.attachmentBinding = util.generateRandomUUID(true);
      await this.saveSettings();
      void this.refreshBalance();
      if (!this.authenticated()) {
        this.settingsVisible = false;
      }
      void this.accountController.logout(account?.token ?? '', 'zh_CN');
    } catch {
      this.toast(this.label('退出登录失败，请重试', "Couldn't sign out. Please try again."));
    }
  }

  private async signOutAll(): Promise<void> {
    if (this.signingOut || this.settingsVerifying || this.authorizing || this.backupBusy) return;
    this.signingOut = true;
    const context = this.host();
    const account = this.account;
    const settings = this.settingsSnapshot();
    settings.apiKey = '';
    settings.authMode = 'api-key';
    settings.signedOut = true;
    settings.attachmentBinding = util.generateRandomUUID(true);
    try {
      await this.settingsStore.markSignedOut(context);
      const locale = settings.locale === 'en-US' ? 'en_US' : 'zh_CN';
      this.settings = settings;
      this.account = null;
      this.resetBalance(true);
      this.stopVoice();
      this.closeMessageEditor();
      this.cancelAllReplies();
      this.onboardingView = 'home';
      this.settingsKey = '';
      this.settingsVisible = false;
      this.migrationPromptVisible = false;
      this.setDrawer(false);
      void this.accountController.logout(account?.token ?? '', locale);
      const results = await Promise.allSettled([saveNativeAccount(null), this.settingsStore.save(context, settings)]);
      if (results.some((result: PromiseSettledResult<void>): boolean => result.status === 'rejected')) {
        this.toast(this.label('已退出登录，本地凭据清理将在下次启动时重试',
          'Signed out. Local credential cleanup will retry at next launch.'));
      }
    } catch {
      this.toast(this.label('退出登录失败，请重试', "Couldn't sign out. Please try again."));
    } finally {
      this.signingOut = false;
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

  private async retryConversation(id: string): Promise<void> {
    const previous = this.session(id);
    if (!previous?.unreadable || !this.canModifyHistory() || this.deletingSessions ||
      this.retryingConversationIds.includes(id)) return;
    this.retryingConversationIds = [...this.retryingConversationIds, id];
    try {
      const recovered = await this.storage.loadConversation(this.host(), id);
      if (!this.canModifyHistory() || this.deletingSessions || this.session(id) !== previous) return;
      this.history = upsertConversation(this.history, recovered);
      if (this.history.activeId === id) this.scrollToLatest();
      if (this.removedDraftFiles.size > 0) this.scheduleDraftSave(true);
    } catch {
      // Keep this conversation's error visible and allow another local retry.
    } finally {
      this.retryingConversationIds = this.retryingConversationIds.filter((pending: string): boolean => pending !== id);
    }
  }

  private reply(id: string | null = this.history.activeId): NativeReply | undefined {
    return this.replies.find((item: NativeReply): boolean => item.sessionId === id);
  }

  private messages(): NativeConversationMessage[] {
    const session = this.session();
    return session === this.visibleSession ? this.messagePath : session ? visibleMessages(session) : [];
  }

  private syncHistoryViews(): void {
    this.syncMessageList();
    if (this.sidebarSessions !== this.history.sessions) this.refreshSidebarHistory();
  }

  private syncMessageList(): void {
    const session = this.session();
    if (session === this.visibleSession) return;
    const sessionChanged = session?.id !== this.visibleSession?.id;
    const previousLastId = this.messagePath[this.messagePath.length - 1]?.id;
    if (sessionChanged) {
      this.messageLimit = CHAT_PAGE_SIZE;
      this.rangeFromTop = false;
      this.firstVisibleRow = 0;
      this.messageActionsId = '';
      this.hoveredMessageId = '';
      this.followLatest = true;
    }
    this.visibleSession = session;
    this.messagePath = session ? visibleMessages(session) : [];
    if (sessionChanged || previousLastId !== this.messagePath[this.messagePath.length - 1]?.id) {
      this.closeSources();
    }
    this.visibleMessageCount = this.messagePath.length;
    this.updateMessageWindow(!sessionChanged);
  }

  private updateMessageWindow(keepReplyView: boolean = true): void {
    const range = nativeMessageRange(this.messagePath.length, this.messageLimit, this.rangeFromTop);
    this.messageRange = range;
    this.earlierCount = range.start;
    this.laterCount = this.messagePath.length - range.end;
    this.messageList.update(this.messagePath, range, keepReplyView);
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
    if (!this.canModifyHistory()) {
      return;
    }
    if (this.history.activeId !== id) {
      this.rememberCurrentDraft();
      this.stopVoice();
      this.history = selectConversation(this.history, id);
      this.restoreDraft(id ?? '');
      this.closeMessageEditor();
      this.titleTap = 0;
      this.status = '';
      this.scrollToLatest();
      // Switching chats only changes the index. Ongoing replies still need checkpoints.
      void this.save(this.host(), true);
    }
    this.setDrawer(false);
    if (id && this.session(id)?.unreadable) void this.retryConversation(id);
  }

  private setDrawer(open: boolean): void {
    if (open) {
      this.getUIContext().getFocusController().clearFocus();
      this.refreshSidebarHistory();
      void this.refreshBalance();
    } else if (!this.wide()) {
      this.rememberSidebarDrawerPosition();
      this.finishSidebarRename(this.renamingId, this.renameText);
      this.resetSelection();
      this.resetSidebarWindow();
    }
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.drawerOpen = open;
      this.drawerDrag = 0;
    });
  }

  private rememberSidebarDrawerPosition(): void {
    if (!this.sidebarDrawerReady || !this.drawerOpen || this.drawerProgress() <= 0 || this.wide()) return;
    const offset = this.sidebarScroller.currentOffset()?.yOffset;
    if (offset === undefined || !Number.isFinite(offset)) return;
    const first = this.sidebarDrawerFirst;
    let index = first ? visibleSidebarRowIndex(this.sidebarSections, first.index, first.itemIndexInGroup) : -1;
    if (index >= 0 && !this.sidebarRows[index]?.session) index++;
    this.sidebarDrawerPosition = {
      query: this.sidebarQuery, offset: Math.max(0, offset),
      sessionId: this.sidebarRows[index]?.session?.id ?? '', rowIndex: index,
    };
  }

  private restoreSidebarDrawerPosition(): void {
    const saved = this.sidebarDrawerPosition;
    if (!saved || saved.query !== this.sidebarQuery || saved.offset <= 0 || !this.sidebarRows.length) return;
    const index = saved.sessionId ? this.sidebarRows.findIndex((row: NativeSidebarRow): boolean =>
      row.session?.id === saved.sessionId) : -1;
    if (index >= 0 && index !== saved.rowIndex) {
      const group = this.sidebarSections.findIndex((section: NativeSidebarSection): boolean =>
        section.key === this.sidebarRows[index].groupKey);
      if (group >= 0) {
        this.sidebarScroller.scrollToItemInGroup(group, index - this.sidebarSections[group].headerIndex - 1, false);
        return;
      }
    }
    if (index < 0 && saved.rowIndex >= this.sidebarRows.length) {
      this.sidebarScroller.scrollEdge(Edge.Bottom);
    } else {
      this.sidebarScroller.scrollTo({ xOffset: 0, yOffset: saved.offset, animation: false });
    }
  }

  private resetSelection(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private toggleSelected(id: string): void {
    this.selectedIds = this.selectedIds.includes(id) ?
      this.selectedIds.filter((item: string): boolean => item !== id) : [...this.selectedIds, id];
  }

  private refreshSidebarHistory(): void {
    this.sidebarSessions = this.history.sessions;
    if (!this.sidebarSessions.length) this.sidebarDrawerPosition = undefined;
    this.sidebarGroups = groupConversations(this.history.sessions);
    this.refreshSidebarResults();
    this.scheduleSidebarSearch();
  }

  private scheduleSidebarDateRefresh(): void {
    clearTimeout(this.sidebarDateTimer);
    const now = Date.now();
    const midnight = new Date(now).setHours(24, 0, 0, 0);
    this.sidebarDateTimer = setTimeout(() => {
      this.sidebarDateTimer = -1;
      if (!this.visible) return;
      this.sidebarGroups = groupConversations(this.history.sessions);
      this.refreshSidebarResults();
      this.scheduleSidebarDateRefresh();
    }, midnight - now);
  }

  private changeSidebarQuery(value: string): void {
    this.searchText = value;
    const query = normalizeSidebarQuery(value);
    if (query === this.sidebarQuery) return;
    this.sidebarQuery = query;
    this.sidebarDrawerPosition = undefined;
    this.sidebarDrawerFirst = undefined;
    this.sidebarMatches = new Set<string>();
    this.sidebarLimit = SIDEBAR_HISTORY_PAGE_SIZE;
    this.refreshSidebarResults();
    this.sidebarScroller.scrollEdge(Edge.Top);
    this.scheduleSidebarSearch();
  }

  private scheduleSidebarSearch(): void {
    this.sidebarSearch.schedule(this.history.sessions, this.sidebarQuery, (matches: Set<string>): void => {
      this.sidebarMatches = matches;
      this.refreshSidebarResults();
    });
  }

  private refreshSidebarResults(): void {
    this.filteredSidebarGroups = filterSidebarGroups(this.sidebarGroups, this.sidebarQuery,
      this.label('新对话', 'New chat'), this.sidebarMatches);
    this.sidebarResultCount = 0;
    for (const group of this.filteredSidebarGroups) this.sidebarResultCount += group.sessions.length;
    this.updateSidebarRows();
  }

  private updateSidebarRows(): void {
    this.sidebarRows = createSidebarRows(this.filteredSidebarGroups, this.sidebarLimit);
    this.sidebarSections = createSidebarSections(this.sidebarRows);
  }

  private sidebarSectionRows(key: string): NativeSidebarRow[] {
    return this.sidebarSections.find((section: NativeSidebarSection): boolean => section.key === key)?.rows ?? [];
  }

  private resetSidebarWindow(): void {
    if (this.sidebarLimit !== SIDEBAR_HISTORY_PAGE_SIZE) {
      this.sidebarLimit = SIDEBAR_HISTORY_PAGE_SIZE;
      this.updateSidebarRows();
    }
  }

  private maybeLoadSidebarPage(lastIndex: number): void {
    // A 44 vp item plus list spacing makes seven rows about 320 vp from the end.
    if ((this.wide() || this.drawerOpen) && lastIndex >= this.sidebarRows.length - 8 &&
      this.sidebarLimit < this.sidebarResultCount) {
      this.sidebarLimit += SIDEBAR_HISTORY_PAGE_SIZE;
      this.updateSidebarRows();
    }
  }

  private deleteSessions(ids: string[], mode: NativeDeleteMode): void {
    if (!this.canModifyHistory() || this.deleteNotice || this.updateNotice) return;
    const targets = ids.filter((id: string): boolean => !!this.session(id));
    if (mode !== 'all' && targets.length === 0) return;
    this.deleteSessionIds = targets;
    this.refreshDeleteNotice(mode, targets.length, false);
    this.deleteNoticeController.open();
  }

  private refreshDeleteNotice(mode: NativeDeleteMode, count: number, busy: boolean): void {
    const compact = this.compact();
    this.deleteNotice = {
      mode, count, busy,
      locale: this.settings.locale,
      fontScale: this.appFontScale(),
      compact,
      width: Math.max(1, Math.min(380, this.viewportWidth - (compact ? 16 : 32))),
      maxHeight: Math.max(1, this.viewportHeight - (compact ? 16 : 24)),
    };
  }

  private closeDeleteNotice(close: boolean = true): void {
    if (!this.deleteNotice) return;
    this.deleteNotice = null;
    this.deleteSessionIds = [];
    if (close) this.deleteNoticeController.close();
  }

  private async confirmDeleteSessions(): Promise<void> {
    const notice = this.deleteNotice;
    if (!notice || notice.busy || !this.canModifyHistory()) return;
    const deleteAll = notice.mode === 'all';
    const ids = deleteAll ? this.history.sessions.map((session: NativeConversation): string => session.id) :
      this.deleteSessionIds.slice();
    this.backupBusy = true;
    this.refreshDeleteNotice(notice.mode, notice.count, true);
    let failed = false;
    try {
      if (notice.mode === 'batch') {
        for (const id of ids) {
          try {
            await this.removeConversations([id], false);
          } catch {
            failed = true;
          }
        }
      } else {
        await this.removeConversations(ids, deleteAll);
      }
    } catch {
      failed = true;
    } finally {
      this.backupBusy = false;
      if (notice.mode === 'batch' || !failed) {
        this.resetSelection();
        this.closeDeleteNotice();
      } else if (this.deleteNotice) {
        this.refreshDeleteNotice(notice.mode, notice.count, false);
      }
    }
    if (failed) {
      this.toast(deleteAll ? this.label('删除失败，请重试', 'Failed to delete chats. Please try again.') :
        this.label('删除对话失败，请重试', 'Unable to delete this chat. Please try again.'));
    } else if (deleteAll) {
      this.toast(this.label('删除成功', 'Successfully deleted.'));
    }
  }

  private async removeConversations(ids: string[], deleteAll: boolean): Promise<void> {
    if (!this.loaded) return;
    const context = this.host();
    const deleted = new Set<string>(ids);
    this.deletingSessions = true;
    this.deletingSessionIds = deleted;
    try {
      if (deleted.size === 0) {
        if (deleteAll) await this.clearAllDrafts(context);
        return;
      }
      const stopped = this.replies.filter((reply: NativeReply): boolean => deleted.has(reply.sessionId));
      for (const id of deleted) this.cancelReply(id);
      await Promise.all(stopped.map((reply: NativeReply): Promise<void> => reply.completion ?? Promise.resolve()));

      const previous = this.history;
      const active = previous.activeId;
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
          if (deleted.has(id)) {
            candidates.set(file.item.id, file.item);
          } else {
            retained.add(file.item.id);
          }
        }
      }
      const next = deleteConversations(this.historyWithPartialReplies(), ids);
      await this.storage.saveConversations(context, next);
      this.history = deleteConversations(this.history, ids);
      this.draftHistoryWrites.forEach((sessionId: string, replyId: string): void => {
        if (deleted.has(sessionId)) this.draftHistoryWrites.delete(replyId);
      });
      for (const id of deleted) this.drafts.delete(id);
      if (active !== next.activeId) {
        this.stopVoice();
        this.restoreDraft(next.activeId ?? '');
      }
      for (const file of candidates.values()) {
        if (file.local && !retained.has(file.id)) {
          this.removedDraftFiles.set(file.id, file);
        }
      }
      this.draftDirty = true;
      if (deleteAll) await this.clearAllDrafts(context);
    } finally {
      this.deletingSessions = false;
      this.deletingSessionIds.clear();
      // Persist stopped replies after a failed delete, or concurrent changes in retained chats.
      if (ids.length > 0) await this.save(context);
      if (!deleteAll) await this.persistDrafts();
    }
  }

  private async clearAllDrafts(context: common.UIAbilityContext): Promise<void> {
    this.rememberCurrentDraft();
    const originals = new Map<string, NativeAttachment>(this.removedDraftFiles);
    this.drafts.forEach((draft: NativeDraft): void => {
      for (const file of draft.files) {
        if (file.item.local) originals.set(file.item.id, file.item);
      }
    });
    await this.draftStorage.save(context, []);
    this.draftStorageReady = true;
    this.draftHistoryWrites.clear();
    this.drafts.clear();
    this.stopVoice();
    this.restoreDraft('');
    this.draftDirty = false;
    if (this.draftSaveTimer >= 0) {
      clearTimeout(this.draftSaveTimer);
      this.draftSaveTimer = -1;
    }
    await this.removeDraftOriginals(context, Array.from(originals.values()));
  }

  private allPinned(): boolean {
    return this.selectedIds.length > 0 && this.selectedIds.every((id: string): boolean => !!this.session(id)?.pinnedAt);
  }

  private stopReply(): void {
    const reply = this.reply();
    if (!reply || reply.stopped) return;
    reply.stopped = true;
    // Keep shared attachment uploads available to later requests.
    if (reply.uploadingIds.length > 0) this.stoppedUploadReplies.set(reply.client, reply);
    reply.stopPreparing?.();
    reply.client.cancel();
    reply.resumeRetry?.();
  }

  private cancelReplyUploads(reply: NativeReply): void {
    this.stoppedUploadReplies.delete(reply.client);
    reply.uploadingIds.forEach((fileId: string) => { this.attachments.cancelUpload(fileId); });
  }

  private cancelReply(id: string): void {
    const reply = this.reply(id);
    if (reply) {
      reply.stopped = true;
      this.cancelReplyUploads(reply);
      reply.stopPreparing?.();
      reply.client.cancel();
      reply.resumeRetry?.();
    }
    this.stoppedUploadReplies.forEach((stopped: NativeReply): void => {
      if (stopped.sessionId === id) this.cancelReplyUploads(stopped);
    });
  }

  private cancelAllReplies(): void {
    this.replies.forEach((reply: NativeReply) => { this.cancelReply(reply.sessionId); });
    this.stoppedUploadReplies.forEach((reply: NativeReply) => { this.cancelReplyUploads(reply); });
  }

  private restoreDraft(id: string): void {
    const draft = this.drafts.get(id);
    this.draft = draft?.text ?? '';
    this.draftFiles = draft?.files ?? [];
    this.composerSelection = {};
    this.compactToolsOpen = false;
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
            error: ready ? '' : this.label('请重试上传', 'Retry this upload'), retryable: !ready && file.local };
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

  private insertComposerText(text: string, selection: TextRange, restoreFocus: boolean = false): void {
    const original = this.draft;
    const limit = original.length;
    const start = Math.max(0, Math.min(selection.start ?? limit, limit));
    const end = Math.max(start, Math.min(selection.end ?? start, limit));
    const updated = original.slice(0, start) + text + original.slice(end);
    const cursor = start + text.length;
    const id = this.history.activeId;
    this.updateDraftText(updated);
    this.composerSelection = { start: cursor, end: cursor };
    setTimeout(() => {
      if (this.history.activeId !== id || this.draft !== updated) return;
      if (restoreFocus && this.visible && !this.drawerOpen && !this.settingsVisible && !this.backupBusy) {
        this.getUIContext().getFocusController().requestFocus('nuwa-composer');
      }
      this.composerEditor.caretPosition(cursor);
    }, 0);
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
    if (!this.loaded || this.deletingSessions || !this.draftStorageReady || this.draftSaving || !this.draftDirty ||
      this.draftHistoryWrites.size > 0) return;
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
      await this.removeDraftOriginals(context, removed);
    } catch {
      this.draftDirty = true;
      this.toast(this.label('草稿保存失败，请重试', 'Unable to save drafts. Please try again.'));
    } finally {
      this.draftSaving = false;
      if (saved && this.draftDirty) void this.persistDrafts();
    }
  }

  private async removeDraftOriginals(context: common.UIAbilityContext, files: NativeAttachment[]): Promise<void> {
    if (!files.length || this.history.sessions.some((chat: NativeConversation): boolean => chat.unreadable === true)) return;
    const retained = new Set<string>();
    for (const chat of this.history.sessions) {
      for (const message of chat.messages) {
        for (const file of message.files ?? []) retained.add(file.id);
      }
    }
    this.drafts.forEach((draft: NativeDraft): void => {
      for (const file of draft.files) retained.add(file.item.id);
    });
    for (const file of this.draftFiles) retained.add(file.item.id);
    for (const item of files) {
      this.removedDraftFiles.delete(item.id);
      if (!retained.has(item.id)) await this.attachments.remove(context, item).catch(() => {});
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

  private pasteComposerAttachments(selection: TextRange): boolean {
    if (!this.authenticated() || !this.canReceiveFileDrop() || !hasNativeClipboardAttachments()) return false;
    void this.acceptDraftFiles(undefined, selection);
    return true;
  }

  private async acceptDraftFiles(drop?: DragEvent, pasteSelection?: TextRange): Promise<void> {
    if (this.attachmentIntakeDraftId !== null || !this.canModifyHistory() ||
      (!drop && (!this.authenticated() || this.session()?.unreadable))) {
      drop?.setResult(DragResult.DRAG_FAILED);
      return;
    }
    const id = this.history.activeId ?? '';
    const context = this.host();
    const binding = this.settings.attachmentBinding;
    const originalDraft = this.draft;
    let clipboard: NativeClipboardAttachments | undefined;
    this.attachmentIntakeDraftId = id;
    try {
      if (pasteSelection) {
        clipboard = await readNativeAttachmentClipboard(context.abilityInfo.bundleName);
        if (!clipboard.uris.length && !clipboard.pixelMaps.length) {
          if (clipboard.plainText && this.canModifyHistory() && this.authenticated() &&
            (this.history.activeId ?? '') === id && this.draft === originalDraft) {
            this.insertComposerText(clipboard.plainText, pasteSelection);
          }
          return;
        }
      }
      const uris = drop ? await readNativeAttachmentDrop(drop, context.abilityInfo.bundleName) : undefined;
      const archive = uris ? nativeBackupDropUri(uris) : undefined;
      if (archive && drop) {
        const imported = await this.importChatHistory(false, archive);
        drop.setResult(imported ? DragResult.DRAG_SUCCESSFUL : DragResult.DRAG_FAILED);
        return;
      }
      if (!this.authenticated() || this.session(id)?.unreadable) {
        drop?.setResult(DragResult.DRAG_FAILED);
        return;
      }
      const config = this.requestConfig();
      if (!config.accountToken && config.protocol !== 'anthropic') {
        drop?.setResult(DragResult.DRAG_FAILED);
        this.toast(this.label('当前服务不支持附件，请配置 Anthropic 接口', "Configure an Anthropic API endpoint to send attachments"));
        return;
      }
      const existingCount = this.draftItems(id).length;
      let items: NativeAttachment[];
      if (clipboard) {
        items = await this.attachments.importClipboard(context, clipboard, existingCount);
      } else if (uris) {
        items = await this.attachments.importUris(context, uris, existingCount);
      } else {
        items = await this.attachments.pick(context, existingCount);
      }
      if (!this.canModifyHistory() || !this.authenticated() ||
        this.settings.attachmentBinding !== binding || (id && !this.session(id))) {
        await Promise.all(items.map((file: NativeAttachment): Promise<void> => this.attachments.remove(context, file).catch(() => {})));
        drop?.setResult(DragResult.DRAG_FAILED);
        return;
      }
      if (!items.length) {
        if (drop) {
          drop.setResult(DragResult.DRAG_FAILED);
          this.toast(this.label('拖入的内容中没有可用附件', 'No usable files were dropped'));
        }
        return;
      }
      const drafts = items.map<NativeDraftAttachment>((item: NativeAttachment): NativeDraftAttachment => ({
        item, state: 'uploading', error: '',
      }));
      this.updateDraftItems(id, [...this.draftItems(id), ...drafts]);
      drafts.forEach((file: NativeDraftAttachment) => { void this.uploadDraftFile(id, file.item); });
      drop?.setResult(DragResult.DRAG_SUCCESSFUL);
    } catch (error) {
      drop?.setResult(DragResult.DRAG_FAILED);
      this.toast((error as Error).message || this.label('添加附件失败', "Unable to add attachments"));
    } finally {
      this.attachmentIntakeDraftId = null;
      if (clipboard) await releaseNativeAttachmentClipboard(clipboard);
    }
  }

  private canReceiveFileDrop(): boolean {
    return this.loaded && this.attachmentIntakeDraftId === null && this.canModifyHistory() &&
      !this.settingsVisible && !this.authorizing && !this.imagePreview &&
      !this.migrationPromptVisible && !this.migrationChoice && !this.shareImportVisible;
  }

  private trackAttachmentDrag(event: DragEvent): void {
    if (!hasNativeAttachmentDropType(event)) {
      this.fileDropHint = null;
      return;
    }
    const canDrop = this.canReceiveFileDrop();
    this.fileDropHint = canDrop ? (hasNativeBackupDropType(event) ? 'history' :
      this.authenticated() ? 'attachment' : null) : null;
    event.dragBehavior = DragBehavior.COPY;
    event.setResult(canDrop ? DragResult.DROP_ENABLED : DragResult.DROP_DISABLED);
  }

  private dropAttachments(event: DragEvent): void {
    this.fileDropHint = null;
    // The TextArea also receives drops directly. An intake already started by either target owns this drop.
    if (!hasNativeAttachmentDropType(event) || this.attachmentIntakeDraftId !== null) return;
    if (!this.canReceiveFileDrop()) {
      event.setResult(DragResult.DRAG_FAILED);
      return;
    }
    event.dragBehavior = DragBehavior.COPY;
    void this.acceptDraftFiles(event);
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
      const failure = error instanceof NativeAttachmentUploadError ? error : undefined;
      const message = failure?.contentRejected ? this.label('解析失败', 'Parsing failed') :
        (failure?.status ?? 0) >= 500 ? this.label('服务器繁忙', 'Server busy') : this.label('上传失败', 'Upload failed');
      this.replaceDraftFile(draftId, item, 'failed', message, failure?.retryable ?? true);
      if (failure?.quota && this.visible &&
        this.draftItems(draftId).some((file: NativeDraftAttachment): boolean => file.item.id === item.id)) {
        this.showUploadQuota(failure.quota);
      }
    }
  }

  private replaceDraftFile(draftId: string, item: NativeAttachment, state: 'uploading' | 'ready' | 'failed',
    error: string, retryable: boolean = false): void {
    const files = this.draftItems(draftId);
    if (!files.some((existing: NativeDraftAttachment): boolean => existing.item.id === item.id)) return;
    this.updateDraftItems(draftId, files.map((existing: NativeDraftAttachment): NativeDraftAttachment =>
      existing.item.id === item.id ? { item, state, error, retryable } : existing));
  }

  private removeDraftFile(item: NativeAttachment): void {
    const id = this.history.activeId ?? '';
    this.attachments.cancelUpload(item.id);
    this.updateDraftItems(id, this.draftItems(id).filter((file: NativeDraftAttachment): boolean => file.item.id !== item.id));
    this.removedDraftFiles.set(item.id, item);
    this.scheduleDraftSave(true);
  }

  private canSendDraft(): boolean {
    return !this.session()?.unreadable && this.attachmentIntakeDraftId !== (this.history.activeId ?? '') &&
      (!this.draftFiles.length || !!this.accountToken() || this.settings.protocol === 'anthropic') &&
      !this.recognitionId && this.canModifyHistory() && (!!this.draft.trim() || this.draftFiles.length > 0) &&
      this.draftFiles.every((file: NativeDraftAttachment): boolean => file.state === 'ready');
  }

  private async prepareMessages(context: common.UIAbilityContext, session: NativeConversation, config: NativeChatConfig,
    reply: NativeReply, rejectedImages: Set<string>): Promise<NativeChatMessage[]> {
    const messages: NativeChatMessage[] = [];
    const current = this.session(session.id) ?? session;
    const path = visibleMessages(current);
    const prompt = path[path.length - 2];
    const usesFiles = !!config.accountToken || config.protocol === 'anthropic';
    const prepared = new Map<string, NativeChatFileRef>();
    if (usesFiles) {
      const stopped = new Promise<void>((resolve): void => {
        reply.stopPreparing = (): void => { resolve(); };
      });
      try {
        await Promise.race([this.prepareReplyFiles(context, current, config, reply, path, prepared), stopped]);
      } finally {
        reply.stopPreparing = undefined;
      }
    }
    if (reply.stopped) return [];
    let previousReminder: string | undefined;
    for (let index = 0; index < path.length - 1; index++) {
      const message = path[index];
      const previous = path[index - 1];
      const next = path[index + 1];
      if (message.role === 'user' && message.id !== prompt?.id && !this.usableContextReply(current, next)) {
        continue;
      }
      if (message.role === 'assistant' && (!this.usableContextReply(current, message) || previous?.role !== 'user' ||
        messages[messages.length - 1]?.role !== 'user')) {
        continue;
      }
      const files: NativeChatFileRef[] = [];
      let rejectedImageRemoved = false;
      if (message.role === 'user') {
        for (const item of message.files ?? []) {
          const file = prepared.get(item.id);
          if (!file) continue;
          if (file.isImage && rejectedImages.has(file.serverId)) {
            rejectedImageRemoved = true;
          } else {
            files.push(file);
          }
        }
      }
      // Keep an answered image-only turn in context after filtering a rejected image.
      const content = message.content || (rejectedImageRemoved && files.length === 0 ? '[图片]' : '');
      if (content || files.length) {
        const reminder = message.id === prompt?.id ? reply.message.latestReminder : next?.latestReminder;
        if (message.role === 'user' && reminder && reminder !== previousReminder && usesFiles) {
          messages.push({ role: 'latest_reminder', content: reminder });
          previousReminder = reminder;
        }
        const readLinks = message.role === 'assistant' ? message.readLinks : undefined;
        messages.push({
          role: message.role, content, files,
          readLinks: usesFiles ? readLinks?.filter((link: NativeReadLink): boolean =>
            useNativeReadLink(link, reply.attachmentBinding, config.baseUrl, !!config.accountToken)) : readLinks,
          prefillBlocks: message.role === 'assistant' ? message.prefillBlocks : undefined,
        });
      }
    }
    return messages;
  }

  private async prepareReplyFiles(context: common.UIAbilityContext, session: NativeConversation, config: NativeChatConfig,
    reply: NativeReply, path: NativeConversationMessage[], prepared: Map<string, NativeChatFileRef>): Promise<void> {
    const attempts = new Map<string, Promise<NativePreparedReplyFile>>();
    const prepare = (item: NativeAttachment): Promise<NativePreparedReplyFile> => {
      const previous = attempts.get(item.id);
      if (previous) return previous;
      const attempt = this.prepareReplyFile(context, session, config, reply, item).then(
        (result: NativePreparedReplyFile): NativePreparedReplyFile => {
          if (result.file) prepared.set(item.id, result.file);
          return result;
        });
      attempts.set(item.id, attempt);
      return attempt;
    };
    const prompt = path[path.length - 2];
    const currentFiles = await Promise.all((prompt?.files ?? []).map(prepare));
    if (reply.stopped) return;
    const failures: NativeFailedUpload[] = [];
    for (const result of currentFiles) {
      if (result.failure && !failures.some((file: NativeFailedUpload): boolean => file.id === result.failure?.id)) {
        failures.push(result.failure);
      }
    }
    if (failures.length > 0) {
      reply.message.failure = {
        kind: 'upload', detail: failures[0].detail, status: failures[0].status, uploadFiles: failures,
      };
      throw new Error(failures[0].detail);
    }
    // Older rounds use available attachments, and an isolated historical upload failure does not block a new reply.
    for (let index = path.length - 3; index >= 0 && !reply.stopped; index--) {
      const message = path[index];
      if (message.role === 'user' && this.usableContextReply(session, path[index + 1])) {
        for (const item of message.files ?? []) {
          if (reply.stopped) return;
          await prepare(item);
        }
      }
    }
  }

  private async prepareReplyFile(context: common.UIAbilityContext, session: NativeConversation, config: NativeChatConfig,
    reply: NativeReply, original: NativeAttachment): Promise<NativePreparedReplyFile> {
    let file = original;
    try {
      if (!file.local) {
        const hydrated = await hydrateImportedAttachment(context, session, file);
        if (!hydrated) return {};
        if (reply.stopped || !this.updatePreparedAttachment(session.id, file.id, hydrated)) {
          await this.attachments.remove(context, hydrated).catch(() => {});
          return {};
        }
        file = hydrated;
      }
      if (reply.stopped) return {};
      if (file.serverId && file.serverBinding === reply.attachmentBinding) {
        return { file: { serverId: file.serverId, isImage: file.isImage } };
      }
      reply.uploadingIds.push(file.id);
      this.paintLiveReplies();
      try {
        const serverId = await this.attachments.upload(context, config, file);
        const ready: NativeAttachment = {
          id: file.id, name: file.name, size: file.size, isImage: file.isImage, mimeType: file.mimeType,
          purpose: file.purpose, createdAt: file.createdAt, serverId, serverBinding: reply.attachmentBinding,
          archiveId: file.archiveId, local: file.local,
        };
        const keepResult = !reply.stopped || this.stoppedUploadReplies.has(reply.client);
        if (keepResult && this.settings.attachmentBinding === reply.attachmentBinding) {
          const updated = this.updatePreparedAttachment(session.id, file.id, ready);
          if (updated && reply.stopped) void this.save(context);
        }
        return reply.stopped ? {} : { file: { serverId, isImage: file.isImage } };
      } finally {
        reply.uploadingIds = reply.uploadingIds.filter((id: string): boolean => id !== file.id);
        if (reply.stopped) {
          if (reply.uploadingIds.length === 0) this.stoppedUploadReplies.delete(reply.client);
        } else {
          this.paintLiveReplies();
        }
      }
    } catch (cause) {
      if (reply.stopped) return {};
      const detail = (cause as Error)?.message || '';
      const error = cause instanceof NativeAttachmentUploadError ? cause : undefined;
      if (error?.quota && !reply.uploadQuotaShown && this.visible && !this.signingOut &&
        this.history.activeId === session.id && this.session(session.id) && !this.deletingSessionIds.has(session.id) &&
        this.reply(session.id)?.client === reply.client && this.settings.attachmentBinding === reply.attachmentBinding) {
        reply.uploadQuotaShown = true;
        this.showUploadQuota(error.quota);
      }
      return { failure: { id: file.id, detail: detail.slice(0, 512), retryable: error?.retryable ?? true,
        status: error?.status } };
    }
  }

  private updatePreparedAttachment(sessionId: string, originalId: string, file: NativeAttachment): boolean {
    const current = this.session(sessionId);
    if (!current || this.deletingSessionIds.has(sessionId)) return false;
    const next = replaceConversationAttachment(current, originalId, file);
    if (next === current) return false;
    this.history = upsertConversation(this.history, next);
    return true;
  }

  private usableContextReply(session: NativeConversation, message: NativeConversationMessage | undefined): boolean {
    return !!message && message.role === 'assistant' && !!message.content && message.stopReason !== 'refusal' &&
      (message.status === 'done' || message.status === 'stopped') && nativeArchivedReplyTemplate(session, message.id) === undefined;
  }

  private startReply(session: NativeConversation, parentId: string | null,
    prompt?: NativeConversationMessage, clearDraft: boolean = false): boolean {
    if (!this.loaded || session.unreadable || !this.canModifyHistory() || this.reply(session.id)) {
      return false;
    }
    const config = this.requestConfig();
    if (!config.accountToken && (!config.baseUrl || !config.model ||
      (!config.apiKey && !allowsKeylessNativeApi(config.baseUrl, this.settings.protocol)))) {
      this.openSettings('account');
      return false;
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
    reply.completion = this.receive(this.host(), config, next, reply);
    return true;
  }

  private streamMessage(reply: NativeReply, status: string): NativeConversationMessage {
    return {
      id: reply.message.id, role: 'assistant', createdAt: reply.message.createdAt,
      parentId: reply.message.parentId, content: reply.message.content, reasoning: reply.message.reasoning,
      model: reply.message.model, status,
      failure: reply.message.failure,
      stopReason: reply.message.stopReason, canPrefill: reply.message.canPrefill,
      thinking: reply.message.thinking, search: reply.message.search, thinkingSignature: reply.message.thinkingSignature,
      prefillBlocks: reply.message.prefillBlocks,
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
    const rejectedImages = this.historyImageRejections(reply.attachmentBinding);
    const prefixBlocks = config.prefill?.blocks ?? [];
    const previousSources = reply.message.sources ?? [];
    const previousCitations = reply.message.citations ?? [];
    const previousTextLength = reply.message.content.length;
    let skippedBadImages = 0;
    let fileRetries = 0;
    while (!reply.stopped) {
      let messages: NativeChatMessage[];
      try {
        messages = await this.prepareMessages(context, session, config, reply, rejectedImages);
      } catch (cause) {
        const detail = cause instanceof Error ? cause.message : '';
        if (!reply.stopped && !reply.message.failure) {
          reply.message.failure = { kind: 'upload', detail: detail.slice(0, 512) };
        }
        throw new Error(detail);
      }
      if (reply.stopped) return undefined;
      config.requestTitle = config.requestTitle === true && !this.session(session.id)?.title;
      const sources = new NativeChatSources(previousSources, previousCitations, previousTextLength);
      const timeline = new NativeToolTimeline();
      const readLinks = new NativeReadLinkCollector(isOfficialNativeReadLinkRoute(config.baseUrl, !!config.accountToken) ?
        undefined : reply.attachmentBinding);
      const prefix = reply.message.content;
      const prefixTimeline = reply.message.toolTimeline;
      let hasTimeline = false;
      try {
        const outcome = await reply.client.send(config, messages, (content: string, reasoning: string,
          outcome?: NativeReplyOutcome): void => {
          if (reply.message.stopReason === 'refusal') return;
          reply.message.content += content;
          reply.message.reasoning += reasoning;
          if (outcome) this.applyReplyOutcome(reply, outcome, prefixBlocks);
          this.paintLiveReplies();
          if (!this.deletingSessions && Date.now() - this.lastStreamSave > 1500) {
            this.lastStreamSave = Date.now();
            void this.save(context, true);
          }
        }, (event: string, outcome: NativeReplyOutcome): void => {
          this.applyReplyOutcome(reply, outcome, prefixBlocks);
          if (reply.message.stopReason === 'refusal') {
            this.paintLiveReplies();
            return;
          }
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
            reply.message.citations = sources.citationSnapshot();
            this.paintLiveReplies();
          } else if (changed) {
            this.paintLiveReplies();
          }
        }, (title: string): void => { this.applyReplyTitle(context, config, reply, title); });
        this.applyReplyOutcome(reply, outcome, prefixBlocks);
        return outcome;
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
            let lastUserIndex = messages.length - 1;
            while (lastUserIndex > cause.imageMessageIndex && messages[lastUserIndex].role !== 'user') lastUserIndex--;
            if (cause.imageMessageIndex === lastUserIndex) {
              reply.message.failure = { kind: 'unsupported-image', detail: '' };
              throw cause;
            }
            if (skippedBadImages < 10 && !rejectedImages.has(image.serverId)) {
              rejectedImages.add(image.serverId);
              skippedBadImages++;
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
        if (hasTimeline && reply.message.stopReason !== 'refusal') {
          reply.message.toolTimeline = this.mergeReplyTimeline(prefix, prefixTimeline, timeline.snapshot(false));
        }
      }
    }
    return undefined;
  }

  private applyReplyOutcome(reply: NativeReply, outcome: NativeReplyOutcome, prefixBlocks: NativePrefillBlock[]): void {
    const message = reply.message;
    if (message.stopReason === 'refusal') return;
    if (outcome.stopReason) message.stopReason = outcome.stopReason;
    if (message.stopReason === 'refusal') {
      message.canPrefill = false;
      message.content = '';
      message.reasoning = '';
      message.thinkingSignature = undefined;
      message.prefillBlocks = undefined;
      message.citations = undefined;
      message.toolTimeline = undefined;
      message.readLinks = undefined;
      return;
    }
    message.canPrefill = outcome.canPrefill;
    if (outcome.thinkingSignature) message.thinkingSignature = outcome.thinkingSignature;
    if (outcome.prefillBlocks !== undefined) message.prefillBlocks = [...prefixBlocks, ...outcome.prefillBlocks];
  }

  private applyReplyTitle(context: common.UIAbilityContext, config: NativeChatConfig, reply: NativeReply,
    title: string): void {
    if (!config.requestTitle || reply.stopped || this.deletingSessionIds.has(reply.sessionId) || !title.trim()) return;
    const session = this.session(reply.sessionId);
    if (!session || session.title) return;
    config.requestTitle = false;
    this.history = renameConversation(this.history, session.id, title);
    void this.save(context, true);
  }

  private historyImageRejections(binding: string): Set<string> {
    if (this.rejectedImageBinding !== binding) {
      this.rejectedImageBinding = binding;
      this.rejectedHistoryImages = new Set<string>();
    }
    return this.rejectedHistoryImages;
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
        queries: step.queries, resultUrls: step.resultUrls, hasSuccessfulSearch: step.hasSuccessfulSearch,
        pages: step.pages, patterns: step.patterns, text: step.text,
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
      await this.requestReply(context, config, session, reply);
    } catch (cause) {
      error = !reply.stopped;
      if (error && !reply.message.failure) {
        const status = cause instanceof NativeModelError ? cause.status : undefined;
        reply.message.failure = {
          kind: cause instanceof NativeModelError && cause.kind === 'network' ? 'network' : 'response',
          detail: ((cause as Error).message || '').slice(0, 512),
          status: status && status >= 100 && status <= 599 ? status : undefined,
        };
      }
    } finally {
      const failure = reply.message.failure;
      if (error && failure) {
        void recordNativeFeedbackLog(context, 'error', 'chat', 'Model request failed',
          failure.status === undefined ? failure.kind : `${failure.kind} (HTTP ${failure.status})`);
      }
      const current = this.session(session.id);
      if (current) {
        const message = this.streamMessage(reply, error ? 'error' : reply.stopped ? 'stopped' : 'done');
        this.history = upsertConversation(this.history, updateConversationMessage(current, message));
        if (!this.deletingSessions) {
          void this.save(context);
        }
        if (!error && !reply.stopped && !this.settings.ttsMuted && this.history.activeId === current.id) {
          this.readMessage(message);
        }
      }
      this.replies = this.replies.filter((item: NativeReply): boolean => item.sessionId !== reply.sessionId);
      this.queueBalanceRefresh(reply.attachmentBinding);
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
    if (this.startReply(session, thread.length ? thread[thread.length - 1].id : null, message, true)) {
      this.stopReadAloud();
    }
  }

  private canContinue(message: NativeConversationMessage): boolean {
    const path = this.messages();
    const session = this.session();
    const hasServerTools = !!message.readLinks?.length ||
      message.toolTimeline?.steps.some((step: NativeToolTimelineStep): boolean => step.type !== 'thinking' && step.type !== 'text');
    return !!session && path[path.length - 1]?.id === message.id && path[path.length - 2]?.role === 'user' &&
      message.canPrefill === true && message.stopReason !== 'refusal' && message.stopReason !== 'tool_use' &&
      !hasServerTools && nativeArchivedReplyTemplate(session, message.id) === undefined &&
      (message.status === 'stopped' || (message.status === 'done' && message.stopReason === 'max_tokens'));
  }

  private continueReply(message: NativeConversationMessage): void {
    const session = this.session();
    if (!session || !this.canModifyHistory() || this.reply(session.id) || !this.canContinue(message)) {
      return;
    }
    const config = this.requestConfig();
    config.model = config.model || message.model || 'deepseek-flash';
    config.thinking = message.thinking ?? config.thinking;
    config.search = message.search ?? config.search;
    config.requestTitle = !session.title;
    config.prefill = {
      text: message.content, reasoning: message.reasoning, thinkingSignature: message.thinkingSignature ?? '',
      blocks: message.prefillBlocks ??
        nativeReplyPrefillBlocks(message.content, message.reasoning, message.thinkingSignature ?? ''),
    };
    this.resumeReplyInPlace(session, message, config);
  }

  private resumeReplyInPlace(session: NativeConversation, message: NativeConversationMessage, config: NativeChatConfig): void {
    const reply: NativeReply = {
      sessionId: session.id, message, client: new NativeChatClient(), stopped: false, uploadingIds: [],
      attachmentBinding: this.settings.attachmentBinding,
    };
    const pending = this.streamMessage(reply, 'pending');
    pending.stopReason = undefined;
    pending.failure = undefined;
    const next = updateConversationMessage(session, pending, Date.now());
    const current = next.messages.find((item: NativeConversationMessage): boolean => item.id === pending.id);
    if (!current) {
      return;
    }
    reply.message = current;
    this.stopVoice();
    this.status = '';
    this.replies = [...this.replies, reply];
    this.history = upsertConversation(this.history, next);
    this.lastStreamSave = Date.now();
    this.jumpToNewestMessages();
    reply.completion = this.receive(this.host(), config, next, reply);
  }

  private failedUploadReply(promptId: string): NativeConversationMessage | undefined {
    const path = this.messages();
    const tail = path[path.length - 1];
    return path[path.length - 2]?.id === promptId && tail?.role === 'assistant' && tail.status === 'error' &&
      tail.failure?.kind === 'upload' ? tail : undefined;
  }

  private messageUploadFailure(prompt: NativeConversationMessage, item: NativeAttachment): NativeFailedUpload | undefined {
    const failure = this.failedUploadReply(prompt.id)?.failure;
    if (!failure || (item.serverId && item.serverBinding === this.settings.attachmentBinding)) return undefined;
    if (failure.uploadFiles) return failure.uploadFiles.find((file: NativeFailedUpload): boolean => file.id === item.id);
    // Earlier native releases only persisted a reply-level error. Associate it only when one original can match.
    const unbound = prompt.files?.filter((file: NativeAttachment): boolean => file.local &&
      (!file.serverId || file.serverBinding !== this.settings.attachmentBinding)) ?? [];
    if (unbound.length !== 1 || unbound[0].id !== item.id) return undefined;
    const status = failure.status ?? Number(/HTTP\s+(\d{3})\b/.exec(failure.detail)?.[1] ?? 0);
    return { id: item.id, detail: failure.detail, retryable: status === 0 || status === 429 || status >= 500 };
  }

  private canRetryMessageUpload(prompt: NativeConversationMessage, item: NativeAttachment): boolean {
    if (!this.loaded || !this.canModifyHistory() || this.reply()) return false;
    const failure = this.failedUploadReply(prompt.id)?.failure;
    return !!failure && (failure.uploadFiles?.[0]?.retryable ?? true) &&
      this.messageUploadFailure(prompt, item)?.retryable === true;
  }

  private retryMessageUpload(prompt: NativeConversationMessage, file: NativeAttachment): void {
    const session = this.session();
    const failed = this.failedUploadReply(prompt.id);
    if (!session || !failed || !this.canRetryMessageUpload(prompt, file)) return;
    const config = this.requestConfig();
    if (!config.accountToken && (config.protocol !== 'anthropic' || !config.baseUrl || !config.apiKey)) {
      this.openSettings('account');
      return;
    }
    config.model = config.model || failed.model || 'deepseek-flash';
    config.thinking = failed.thinking ?? config.thinking;
    config.search = failed.search ?? config.search;
    config.requestTitle = !session.title;
    this.resumeReplyInPlace(session, failed, config);
  }

  private retry(message: NativeConversationMessage): void {
    const session = this.session();
    if (session && this.startReply(session, message.parentId)) {
      this.stopReadAloud();
    }
  }

  private openMessageEditor(message: NativeConversationMessage): void {
    if (this.reply() || !this.canModifyHistory()) return;
    this.editText = message.content;
    this.editorComposing = false;
    this.editorFocusPending = message.id;
    this.editId = message.id;
  }

  private closeMessageEditor(): void {
    this.editId = '';
    this.editText = '';
    this.editorComposing = false;
    this.editorFocusPending = '';
  }

  private focusMessageEditor(id: string): void {
    if (this.editorFocusPending !== id) return;
    setTimeout(() => {
      if (!this.visible || this.editId !== id || this.editorFocusPending !== id) return;
      this.editorFocusPending = '';
      try {
        this.getUIContext().getFocusController().requestFocus('nuwa-message-editor');
      } catch {
        // The row can disappear if the author changes the visible branch.
      }
    }, 0);
  }

  private canSendMessageEdit(message: NativeConversationMessage): boolean {
    return this.editId === message.id && this.canModifyHistory() && !this.reply() &&
      (!!this.editText.trim() || !!message.files?.length);
  }

  private editMessageKey(event: KeyEvent, message: NativeConversationMessage): boolean {
    if (event.type !== KeyType.Down || this.editorComposing) return false;
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.closeMessageEditor();
      return true;
    }
    const enter = event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER;
    if (!this.wide() || !enter) return false;
    if (event.getModifierKeyState?.(['Shift']) || event.getModifierKeyState?.(['Ctrl'])) {
      const selected = this.messageEditor.getSelection();
      const start = selected?.start ?? this.editText.length;
      const end = selected?.end ?? start;
      if (start !== end) this.messageEditor.deleteText({ start: Math.min(start, end), end: Math.max(start, end) });
      const caret = this.messageEditor.addText('\n', { offset: Math.min(start, end) });
      if (caret >= 0) this.messageEditor.caretPosition(caret);
    } else {
      this.edit(message);
    }
    return true;
  }

  private edit(message: NativeConversationMessage): void {
    const session = this.session();
    if (session && this.canSendMessageEdit(message)) {
      const edited = createConversationMessage('user', this.editText.trim(), '');
      edited.files = message.files;
      if (this.startReply(session, message.parentId, edited)) {
        this.closeMessageEditor();
        this.stopVoice();
      }
    }
  }

  private versions(message: NativeConversationMessage): NativeConversationMessage[] {
    const session = this.session();
    return session ? messageVersions(session, message.id) : [];
  }

  private version(message: NativeConversationMessage): number {
    return this.versions(message).findIndex((item: NativeConversationMessage): boolean => item.id === message.id);
  }

  private canChangeVersion(): boolean {
    return this.canModifyHistory() && !this.reply();
  }

  private changeVersion(message: NativeConversationMessage, offset: number): void {
    if (!this.canChangeVersion()) return;
    const session = this.session();
    const sibling = this.versions(message)[this.version(message) + offset];
    if (session && sibling) {
      const pathIndex = this.messagePath.findIndex((item: NativeConversationMessage): boolean => item.id === message.id);
      const listIndex = pathIndex - this.messageRange.start + Number(this.earlierCount > 0);
      const keepPosition = pathIndex >= this.messageRange.start && pathIndex < this.messageRange.end;
      const top = keepPosition ? this.scroller.getItemRect(listIndex).y : 0;
      const context = this.getUIContext();
      const controlsTop = keepPosition ? nativeBranchControlsTop(context, message.id) : undefined;
      this.branchScrollAnchor.cancel();
      this.closeMessageEditor();
      this.followLatest = false;
      this.closeSources();
      this.history = upsertConversation(this.history, selectMessageVersion(session, sibling.id));
      if (keepPosition && pathIndex >= this.messageRange.start && pathIndex < this.messageRange.end) {
        const targetIndex = pathIndex - this.messageRange.start + Number(this.earlierCount > 0);
        if (controlsTop === undefined) {
          this.restoreListPosition(targetIndex, top);
        } else {
          this.branchScrollAnchor.restore(context, this.scroller, sibling.id, targetIndex, controlsTop,
            (): boolean => this.visible && this.canChangeVersion() && this.history.activeId === session.id &&
              this.messagePath[pathIndex]?.id === sibling.id);
        }
      }
      void this.save();
    }
  }

  private toggleRecognition(): void {
    if (this.recognitionId) {
      this.recognition.finish(this.recognitionId);
    } else if (this.canModifyHistory()) {
      this.getUIContext().getFocusController().clearFocus();
      this.recognitionId = util.generateRandomUUID(true);
      this.voiceInputPhase = 'starting';
      this.recognition.start(this.recognitionId, this.host(), this.speechOptions());
    }
  }

  private startRecordingClock(): void {
    this.stopRecordingClock();
    const started = Date.now();
    this.recordingTimer = setInterval(() => {
      this.recordingSeconds = Math.floor((Date.now() - started) / 1000);
    }, 1000);
  }

  private stopRecordingClock(): void {
    if (this.recordingTimer >= 0) {
      clearInterval(this.recordingTimer);
      this.recordingTimer = -1;
    }
    this.recordingSeconds = 0;
    this.voiceLevel = 0;
  }

  private stopVoice(): void {
    this.recognitionId = '';
    this.voiceInputPhase = 'idle';
    this.stopRecordingClock();
    this.recognition.cancel();
    this.stopReadAloud();
  }

  private stopReadAloud(): void {
    this.readingId = '';
    this.speaker.stop();
  }

  private readMessage(message: NativeConversationMessage): void {
    const text = this.assistantResponseText(message);
    if (!text) return;
    const active = this.readingId === message.id;
    this.speaker.stop();
    this.readingId = active ? '' : message.id;
    if (this.readingId) {
      this.speaker.speak(message.id, text, this.settings.locale, this.speechOptions(), this.host());
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
      case 'permission-denied': return this.label('无法使用麦克风，请在系统设置中允许麦克风权限',
        'Microphone access is blocked. Please allow microphone permission in system settings.');
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
    const wasReading = !!this.readingId;
    if (wasReading) this.stopReadAloud();
    const muted = wasReading || !this.settings.ttsMuted;
    this.settings.ttsMuted = muted;
    void this.saveSettings();
    if (wasReading) return;
    this.toast(muted ? this.label('已静音朗读', "Read-aloud muted") : this.label('已取消朗读静音', "Read-aloud unmuted"));
  }

  private speakerAccessibilityLabel(): string {
    if (this.readingId) return this.label('停止朗读', 'Stop reading');
    return this.settings.ttsMuted ? this.label('已取消朗读静音', 'Read-aloud unmuted') :
      this.label('已静音朗读', 'Read-aloud muted');
  }

  private compact(): boolean {
    return this.viewportWidth <= 340;
  }

  private wide(): boolean {
    return this.viewportWidth >= 768;
  }

  private fontPreferenceScale(): number {
    return this.settings.chatFontSize / 16;
  }

  private appFontScale(): number {
    return this.fontPreferenceScale() * (this.compact() ? 13 / 16 : 1);
  }

  private appFontSize(size: number): number {
    return size * this.appFontScale();
  }

  private composerFieldMinHeight(inline: boolean): number {
    if (inline) return 10 + this.appFontSize(20);
    return 12 + this.appFontSize(this.viewportWidth < 440 ? 30 : 48);
  }

  private composerFieldMaxHeight(inline: boolean): number {
    if (inline) return 54;
    if (this.wide()) return 336;
    // Reserve the tool row and attachment strip inside the keyboard-resized composer.
    const controlsHeight = 58 + (this.draftFiles.length ? 76 : 0);
    return Math.max(this.composerFieldMinHeight(false),
      Math.min(336, Math.max(120, this.viewportHeight - 120) - controlsHeight));
  }

  private desktopSourcesWidth(): number {
    return Math.min(390, this.viewportWidth / 2 - 64);
  }

  private composerToggleLabelsFit(): boolean {
    if (this.compact() || this.composerToggleWidth <= 0) return false;
    const ui = this.getUIContext();
    const measure = ui.getMeasureUtils();
    const thinkingWidth = measure.measureText({ textContent: this.label('深度思考', 'DeepThink'),
      fontSize: this.appFontSize(13), fontWeight: FontWeight.Medium });
    const searchWidth = measure.measureText({ textContent: this.label('智能搜索', 'Search'),
      fontSize: this.appFontSize(13), fontWeight: FontWeight.Medium });
    const controlsWidth = 2 * (14 + 5 + 22 + 2) + 10;
    return ui.px2vp(thinkingWidth + searchWidth) + controlsWidth <= this.composerToggleWidth;
  }

  private setDesktopSidebar(collapsed: boolean): void {
    this.settings.desktopSidebarCollapsed = collapsed;
    if (collapsed) {
      this.finishSidebarRename(this.renamingId, this.renameText);
      this.changeSidebarQuery('');
      this.resetSidebarWindow();
      this.resetSelection();
      this.getUIContext().getFocusController().clearFocus();
    } else {
      void this.refreshBalance();
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
          .fontSize(this.appFontSize(14)).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
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
        Text(this.session()?.title || this.label('新对话', "New chat")).fontSize(this.appFontSize(this.compact() ? 13 : 14)).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary')).textAlign(TextAlign.Center)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .onClick(() => { this.titlePressed(); })
      } else {
        Blank().layoutWeight(1)
      }
      Row({ space: 2 }) {
        this.iconButton(this.settings.ttsMuted && !this.readingId ? $r('app.media.native_muted') : $r('app.media.native_speaker'),
        this.speakerAccessibilityLabel(), () => { this.toggleSpeaker(); }, this.compact() ? 26 : 34)
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
          .fontSize(this.appFontSize(this.wide() && this.viewportHeight <= 500 ? 18 : 20))
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
        if (this.composerToggleLabelsFit()) {
          Text(label()).fontSize(this.appFontSize(13)).fontWeight(FontWeight.Medium).fontColor(active() ?
            $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_primary'))
        }
      }
    }
    .height(this.compact() ? 26 : 34).padding({ left: this.compact() ? 8 : 11, right: this.compact() ? 8 : 11 })
    .backgroundColor(active() ? $r('app.color.native_chat_selected') : Color.Transparent)
    .border({ width: 1, color: active() ? Color.Transparent : $r('app.color.native_chat_stroke') })
    .accessibilityText(label()).accessibilitySelected(active()).onClick(change)
  }

  @Builder
  private voiceButton() {
    if (this.wide() && this.voiceInputPhase === 'recording') {
      Text(this.label(`录音中 ${this.recordingSeconds}s`, `Recording ${this.recordingSeconds}s`))
        .fontSize(this.appFontSize(12)).lineHeight(17).fontColor($r('app.color.native_chat_caption'))
    }
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      if (this.voiceInputPhase === 'recording') {
        Stack() {
          Circle().width(this.compact() ? 22 : 26).height(this.compact() ? 22 : 26)
            .fill($r('app.color.native_chat_blue')).opacity(0.2)
          Circle().width(this.compact() ? 18 : 22).height(this.compact() ? 18 : 22)
            .fill($r('app.color.native_chat_blue')).opacity(0.75)
          Image($r('app.media.native_mic_fill')).width(16).height(16).colorFilter(nativeIconTint(Color.White))
        }
        .width(this.compact() ? 22 : 26).height(this.compact() ? 22 : 26)
      } else if (this.voiceInputPhase === 'transcribing' || this.voiceInputPhase === 'starting') {
        LoadingProgress().width(14).height(14).color($r('app.color.native_chat_action'))
      } else {
        Image($r('app.media.native_voice')).width(22).height(22)
          .colorFilter(nativeIconTint($r('app.color.native_chat_primary'))).draggable(false)
      }
    }
    .width(this.compact() ? 26 : 34).height(this.compact() ? 26 : 34).padding(0)
    .accessibilityText(this.voiceInputPhase === 'recording' ? this.label('结束录音并转写', 'Stop recording and transcribe') :
      this.voiceInputPhase === 'transcribing' ? this.label('正在转写，点击取消', 'Transcribing. Click to cancel') :
      this.voiceInputPhase === 'starting' ? this.label('正在准备录音，点击取消', 'Preparing to record. Click to cancel') :
      this.label('语音输入', 'Voice input'))
    .onClick(() => { this.toggleRecognition(); })
  }

  private attachmentPreview(item: NativeAttachment): string {
    if (!item.isImage) {
      return '';
    }
    if (!item.local || item.archiveId) {
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
    const session = this.session();
    const uri = this.attachments.previewUri(context, item) ||
      (session ? importedAttachmentOriginalUri(context, session, item) : '');
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
    this.iconButton($r('app.media.native_add'), this.label('上传附件', "Upload attachment"), () => { void this.acceptDraftFiles(); },
      34, 22, $r('app.color.native_chat_primary'), Color.Transparent, () => this.attachmentIntakeDraftId === null && !this.backupBusy)
  }

  @Builder
  private attachmentTile(item: NativeAttachment, size: number, preview: string) {
    if (preview) {
      Image(preview).width(size).height(size).objectFit(ImageFit.Cover).autoResize(true)
        .borderRadius(12).draggable(false).accessibilityText(item.name)
        .onClick(() => { void this.openAttachment(item); })
    } else {
      Row({ space: 8 }) {
        Image($r('app.media.native_file')).width(20).height(20).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        Column({ space: 3 }) {
          Text(item.name).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(this.appFontSize(12))
            .fontColor($r('app.color.native_chat_primary'))
          Text(this.attachmentSize(item.size)).fontSize(this.appFontSize(11)).fontColor($r('app.color.native_chat_secondary'))
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width(148).height(62).padding({ left: 10, right: 10 }).borderRadius(12)
      .backgroundColor($r('app.color.native_chat_field')).accessibilityText(item.name)
      .onClick(() => { void this.openAttachment(item); })
    }
  }

  @Builder
  private messageAttachmentTile(prompt: NativeConversationMessage, item: NativeAttachment, preview: string) {
    Stack() {
      this.attachmentTile(item, this.messageImageSize(prompt), preview)
      if (this.reply()?.uploadingIds.includes(item.id)) {
        Row() { LoadingProgress().width(20).height(20).color(Color.White) }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#55000000').borderRadius(12).accessibilityText(this.label('正在上传', "Uploading"))
      } else if (this.messageUploadFailure(prompt, item)) {
        if (this.canRetryMessageUpload(prompt, item)) {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 2 }) {
              Image($r('app.media.native_retry')).width(18).height(18).colorFilter(nativeIconTint(Color.White))
              Text(this.label('重试上传', "Retry upload")).fontSize(this.appFontSize(11)).fontColor(Color.White).maxLines(1)
            }
          }
          .width('100%').height('100%').padding(0).backgroundColor('#88000000')
          .border({ width: 1, color: $r('app.color.native_chat_error') }).borderRadius(12)
          .accessibilityText(this.label('重试上传', "Retry upload") + ': ' + item.name)
          .accessibilityDescription(this.messageUploadFailure(prompt, item)?.detail ?? '')
          .onClick(() => { this.retryMessageUpload(prompt, item); })
        } else {
          Text(this.messageUploadFailure(prompt, item)?.detail || this.label('上传失败', "Upload failed"))
            .width('100%').height('100%').textAlign(TextAlign.Center).fontSize(this.appFontSize(11)).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(Color.White).padding(6)
            .backgroundColor('#88000000').borderRadius(12)
        }
      }
    }
    .width(preview ? this.messageImageSize(prompt) : 148)
    .height(preview ? this.messageImageSize(prompt) : 62)
  }

  @Builder
  private draftDocumentCard(file: NativeDraftAttachment) {
    Row({ space: 8 }) {
      if (file.state === 'uploading') {
        LoadingProgress().width(18).height(18).color($r('app.color.native_chat_blue'))
      } else {
        Image(file.retryable ? $r('app.media.native_retry') : $r('app.media.native_file'))
          .width(20).height(20).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
      }
      Column({ space: 3 }) {
        Text(file.item.name).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(this.appFontSize(12))
          .fontColor($r('app.color.native_chat_primary'))
        Text(file.state === 'failed' ? file.error : file.state === 'uploading' ? this.label('正在上传', 'Uploading…') :
          this.attachmentSize(file.item.size))
          .fontSize(this.appFontSize(11)).fontColor($r('app.color.native_chat_secondary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width(148).height(62).padding({ left: 10, right: 21 }).borderRadius(12)
    .backgroundColor($r('app.color.native_chat_field'))
    .border({ width: file.state === 'failed' ? 1 : 0, color: $r('app.color.native_chat_error') })
    .accessibilityText(file.item.name).accessibilityDescription(file.error)
    .onClick(() => {
      if (file.retryable) void this.uploadDraftFile(this.history.activeId ?? '', file.item);
      else if (file.state === 'ready') void this.openAttachment(file.item);
    })
  }

  @Builder
  private draftImageCard(file: NativeDraftAttachment, preview: string) {
    Stack() {
      this.attachmentTile(file.item, 62, preview)
      if (file.state === 'uploading') {
        Row() { LoadingProgress().width(20).height(20).color(Color.White) }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#55000000').borderRadius(12).accessibilityText(this.label('正在上传', 'Uploading'))
      } else if (file.state === 'failed') {
        Column({ space: 2 }) {
          if (file.retryable) {
            this.iconButton($r('app.media.native_retry'), this.label('重试上传', 'Retry upload'), () => {
              void this.uploadDraftFile(this.history.activeId ?? '', file.item);
            }, 24, 16, Color.White)
          }
          if (!file.retryable || file.error !== this.label('上传失败', 'Upload failed')) {
            Text(file.error).fontSize(this.appFontSize(10)).fontColor(Color.White).textAlign(TextAlign.Center).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%').height('100%').padding(3)
        .justifyContent(file.retryable ? FlexAlign.Center : FlexAlign.End)
        .backgroundColor('#88000000').border({ width: 1, color: $r('app.color.native_chat_error') }).borderRadius(12)
        .accessibilityDescription(file.error)
      }
    }
    .width(62).height(62)
  }

  @Builder
  private draftAttachmentStrip() {
    if (this.draftFiles.length) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.draftFiles, (file: NativeDraftAttachment) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              if (this.attachmentPreview(file.item)) {
                this.draftImageCard(file, this.attachmentPreview(file.item))
              } else {
                this.draftDocumentCard(file)
              }
              Row() {
                this.iconButton($r('app.media.native_close'), this.label('移除附件', "Remove attachment"), () => { this.removeDraftFile(file.item); },
                  18, 12, Color.White,
                  file.state === 'failed' && !file.retryable ? $r('app.color.native_chat_error') : '#990F1115')
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
    Stack({ alignContent: Alignment.Center }) {
      TextArea({ text: this.draft, placeholder: this.label('发消息或语音输入', 'Message or voice input'),
        controller: this.composerEditor })
        .width('100%').constraintSize({ minHeight: this.composerFieldMinHeight(inline),
          maxHeight: this.composerFieldMaxHeight(inline) })
        .padding({ top: inline ? 5 : 12, bottom: inline ? 5 : 0, left: inline ? 4 : 16, right: inline ? 4 : 12 })
        .borderRadius(0).fontSize(this.appFontSize(inline ? 14 : 16))
        .lineHeight(this.appFontSize(inline ? 20 : 24))
        .placeholderColor($r('app.color.native_chat_caption'))
        .fontColor($r('app.color.native_chat_primary')).caretColor($r('app.color.native_chat_blue_text'))
        .backgroundColor(Color.Transparent).enterKeyType(EnterKeyType.NEW_LINE)
        .enabled(this.loaded && this.canModifyHistory() && (this.wide() || this.voiceInputPhase !== 'recording'))
        .opacity(this.wide() || this.voiceInputPhase !== 'recording' ? 1 : 0)
        .accessibilityLevel(this.wide() || this.voiceInputPhase !== 'recording' ? 'auto' : 'no')
        .id('nuwa-composer').defaultFocus(this.wide())
        .allowDrop(NATIVE_COMPOSER_DROP_TYPES)
        .onDragEnter((event: DragEvent) => { this.trackAttachmentDrag(event); })
        .onDragMove((event: DragEvent) => { this.trackAttachmentDrag(event); })
        .onDragLeave(() => { this.fileDropHint = null; })
        .onDrop((event: DragEvent) => { this.dropAttachments(event); })
        .editMenuOptions({
          onCreateMenu: (items: TextMenuItem[]): TextMenuItem[] => {
            if (this.authenticated() && this.canReceiveFileDrop() &&
              !items.some((item: TextMenuItem): boolean => item.id.equals(TextMenuItemId.PASTE)) &&
              hasNativeClipboardAttachments()) {
              items.unshift({ content: this.label('粘贴', 'Paste'), id: TextMenuItemId.PASTE });
            }
            return items;
          },
          onMenuItemClick: (item: TextMenuItem, selection: TextRange): boolean =>
            item.id.equals(TextMenuItemId.PASTE) && this.pasteComposerAttachments(selection),
        })
        .onKeyPreIme((event: KeyEvent): boolean => {
          if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_V ||
            !event.getModifierKeyState?.(['Ctrl']) || event.getModifierKeyState?.(['Alt']) ||
            event.getModifierKeyState?.(['Shift'])) return false;
          return this.pasteComposerAttachments(this.composerSelection);
        })
        .onTextSelectionChange((start: number, end: number) => { this.composerSelection = { start, end }; })
        .onFocus(() => { this.compactToolsOpen = false; })
        .onChange((value: string) => { this.updateDraftText(value); })
      if (!this.wide() && this.voiceInputPhase === 'recording') {
        Column() {
          NativeVoiceSpectrum({ level: this.voiceLevel })
        }
        .width('100%').padding({ left: inline ? 4 : 16, right: inline ? 4 : 12 })
        .translate({ y: inline ? 0 : 8 })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityText(this.label('录音中', 'Recording'))
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
        () => { this.stopReadAloud(); this.stopReply(); }, this.compact() ? 28 : 34, 16,
        Color.White, $r('app.color.native_chat_blue'))
    } else if (this.canSendDraft()) {
      this.composerSendButton()
    } else {
      this.voiceButton()
    }
  }

  @Builder
  private composerSendButton() {
    this.iconButton($r('app.media.native_send'), this.label('发送', 'Send'), () => { this.sendDraft(); },
      this.compact() ? 28 : 34, 16, Color.White, $r('app.color.native_chat_blue'), () => this.loaded && this.canSendDraft())
  }

  @Builder
  private compactComposer() {
    if (this.compactToolsOpen) {
      Row({ space: 6 }) {
        this.composerToggles()
        this.iconButton($r('app.media.native_add'), this.label('上传附件', 'Upload attachment'), () => {
          this.compactToolsOpen = false;
          void this.acceptDraftFiles();
        }, 28, 22, $r('app.color.native_chat_primary'), Color.Transparent,
        () => this.attachmentIntakeDraftId === null && !this.backupBusy)
      }
      .width('100%').padding({ left: 8, right: 8, top: 5, bottom: 4 })
      .border({ width: { bottom: 1 }, color: $r('app.color.native_chat_stroke') })
    }
    Row() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Image($r('app.media.native_add')).width(22).height(22)
            .colorFilter(nativeIconTint($r('app.color.native_chat_primary')))
            .rotate({ angle: this.compactToolsOpen ? 45 : 0 })
        }
        .width(28).height(28).padding(0).accessibilityText(this.label('对话工具', 'Chat tools'))
        .accessibilitySelected(this.compactToolsOpen)
        .onClick(() => { this.compactToolsOpen = !this.compactToolsOpen; })
        if (!this.compactToolsOpen && (this.settings.search || this.settings.thinking)) {
          Circle().width(6).height(6).fill($r('app.color.native_chat_blue')).margin({ top: 3, right: 3 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(28).height(28).margin({ right: 4 })
      this.composerField(true)
      this.composerAction()
    }
    .width('100%').alignItems(VerticalAlign.Bottom).padding({ left: 5, right: 5, top: 3, bottom: 3 })
  }

  @Builder
  private composer() {
    Column({ space: this.compact() ? 0 : 2 }) {
      this.draftAttachmentStrip()
      if (this.compact()) {
        this.compactComposer()
      } else {
        this.composerField(false)
        Row({ space: 8 }) {
          Row({ space: 10 }) {
            this.composerToggles()
          }
          .layoutWeight(1).clip(true)
          .onAreaChange((_before: Area, after: Area) => { this.composerToggleWidth = Number(after.width); })
          Row({ space: 6 }) {
            if (this.reply()) {
              this.addAttachmentButton()
              this.composerAction()
            } else if (this.canSendDraft() || this.voiceInputPhase !== 'idle') {
              this.voiceButton()
              this.addAttachmentButton()
              this.composerSendButton()
            } else {
              this.addAttachmentButton()
              this.voiceButton()
            }
          }
        }
        .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
    }
    .width('100%').borderRadius(this.compact() ? 18 : 24)
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
          () => this.canChangeVersion() && this.version(message) > 0)
        Text(`${this.version(message) + 1}/${this.versions(message).length}`)
          .fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary'))
        this.iconButton($r('app.media.native_chevron_right'), this.label('下一个版本', "Next version"), () => { this.changeVersion(message, 1); },
          26, 14, $r('app.color.native_chat_secondary'), Color.Transparent,
          () => this.canChangeVersion() && this.version(message) + 1 < this.versions(message).length)
      }
      .id(nativeBranchControlsId(message.id))
    }
  }

  private showMessageActions(message: NativeConversationMessage, index: number): boolean {
    const latest = message.role === 'user' ? this.visibleMessageCount - 2 : this.visibleMessageCount - 1;
    return index >= latest || this.messageActionsId === message.id || this.hoveredMessageId === message.id ||
      this.readingId === message.id;
  }

  private hoverMessage(id: string, hovered: boolean): void {
    if (hovered) this.hoveredMessageId = id;
    else if (this.hoveredMessageId === id) this.hoveredMessageId = '';
  }

  @Builder
  private userMessage(message: NativeConversationMessage, index: number) {
    Column({ space: 6 }) {
      if (message.files?.length) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End,
          space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
          ForEach(message.files, (file: NativeAttachment) => {
            this.messageAttachmentTile(message, file, this.attachmentPreview(file))
          }, (file: NativeAttachment): string => file.id)
        }
        .width('100%')
      }
      if (message.id === this.editId) {
        Column() {
          TextArea({ text: this.editText, controller: this.messageEditor })
            .id('nuwa-message-editor').width('100%').constraintSize({ minHeight: 44, maxHeight: 202 })
            .padding({ left: 16, right: 16, top: 10, bottom: 10 }).borderRadius(0)
            .fontSize(this.appFontSize(16)).lineHeight(this.appFontSize(24))
            .fontColor($r('app.color.native_chat_primary')).caretColor($r('app.color.native_chat_blue_text'))
            .backgroundColor(Color.Transparent).enterKeyType(EnterKeyType.NEW_LINE)
            .accessibilityText(this.label('编辑消息', 'Edit message')).enabled(!this.reply() && this.canModifyHistory())
            .onChange((value: string, preview?: PreviewText) => {
              this.editorComposing = !!preview?.value;
              this.editText = value;
            })
            .onKeyEvent((event: KeyEvent): boolean => this.editMessageKey(event, message))
            .onAppear(() => { this.focusMessageEditor(message.id); })
          Row({ space: 8 }) {
            Button(this.label('取消', 'Cancel'), { type: ButtonType.Capsule })
              .height(32).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_primary'))
              .border({ width: 1, color: $r('app.color.native_chat_stroke') }).backgroundColor(Color.Transparent)
              .onClick(() => { this.closeMessageEditor(); })
            Button(this.label('发送', 'Send'), { type: ButtonType.Capsule })
              .height(32).fontSize(this.appFontSize(13)).backgroundColor($r('app.color.native_chat_blue'))
              .enabled(this.canSendMessageEdit(message)).onClick(() => { this.edit(message); })
          }
          .width('100%').justifyContent(FlexAlign.End).padding({ top: 6, bottom: 10, left: 10, right: 10 })
        }
        .width('100%').borderRadius(22).border({ width: 1, color: $r('app.color.native_chat_blue') })
        .clip(true).backgroundColor($r('app.color.native_chat_bg'))
      } else {
        if (message.content) {
          Text(message.content).fontSize(this.appFontSize(16)).lineHeight(this.appFontSize(24)).fontColor($r('app.color.native_chat_primary'))
          .constraintSize({ maxWidth: Math.max(140, Math.min(this.viewportWidth - 40, 752) - 68) })
          .padding({ left: 16, right: 16, top: 10, bottom: 10 }).borderRadius(22)
            .backgroundColor($r('app.color.native_chat_bubble')).copyOption(CopyOptions.LocalDevice)
        }
        Row({ space: 10 }) {
          Row({ space: 10 }) {
            if (message.content) {
              NativeMessageCopyButton({ text: message.content, locale: this.settings.locale })
            }
            this.iconButton($r('app.media.native_edit'), this.label('编辑消息', 'Edit message'), () => { this.openMessageEditor(message); },
              28, 16, $r('app.color.native_chat_action'), Color.Transparent, () => !this.reply() && this.canModifyHistory())
          }
          .opacity(this.showMessageActions(message, index) ? 1 : 0)
          .onFocus(() => { this.messageActionsId = message.id; })
          this.branchControls(message)
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.End).padding({ top: index === 0 ? 34 : 0, bottom: 16 })
    .onHover((hovered: boolean) => { this.hoverMessage(message.id, hovered); })
    .parallelGesture(TapGesture().onAction(() => { this.messageActionsId = message.id; }))
  }

  private closeSources(): void {
    if (this.sourcePanelEntry) {
      this.sourcePanelEntry = '';
      this.panelSources = [];
    }
  }

  private toggleSources(entry: string, sources: NativeChatSource[]): void {
    if (this.sourcePanelEntry === entry) {
      this.closeSources();
    } else if (sources.length > 0) {
      this.panelSources = sources;
      this.sourcePanelEntry = entry;
    }
  }

  private openCitation(sources: NativeChatSource[], index: number): void {
    const source = sources.find((item: NativeChatSource): boolean => item.index === index);
    const target = safeNativeSourceUrl(source?.url);
    if (target) {
      void this.openLink(target);
    }
  }

  @Builder
  private sourcesSummary(entry: string, sources: NativeChatSource[]) {
    if (sources.length) {
      Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 6 }) {
          Image($r('app.media.native_web_search')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
          Text(this.label(`${sources.length} 个网页`, sources.length === 1 ? '1 web page' : `${sources.length} web pages`))
            .fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_secondary'))
          Image($r('app.media.native_chevron_right')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
        }
      }
      .height(34).padding({ left: 12, right: 10 })
      .backgroundColor(this.sourcePanelEntry === entry ? $r('app.color.native_chat_selected') :
        $r('app.color.native_chat_field'))
      .onClick(() => { this.toggleSources(entry, sources); })
    }
  }

  private withCitationMarkers(text: string, citations: NativeChatCitation[], start: number = 0): string {
    const ordered = citations.filter((citation: NativeChatCitation): boolean => citation.offset >= start)
      .sort((left: NativeChatCitation, right: NativeChatCitation): number => left.offset - right.offset);
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
        citations: message().citations ?? [], fontScale: this.appFontScale(), locale: this.settings.locale,
        streaming: message().status === 'pending' || message().status === 'streaming',
        thinking: message().thinking || undefined, stopped: message().status === 'stopped',
        hasResponse: !!this.assistantResponseText(message()),
        messageId: message().id, activeSourceEntry: this.sourcePanelEntry, citationHoverEnabled: this.wide(),
        onSources: (entry: string, sources: NativeChatSource[]): void => { this.toggleSources(entry, sources); },
      })
    } else if (message().reasoning) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Image($r('app.media.native_think')).width(16).height(16).colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
          Text(thinking() ? this.label('正在思考', 'Thinking') : this.label('已思考', 'Thought'))
            .fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_secondary'))
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
        Column() {
          NativeMarkdown({
            content: message().reasoning, fontScale: this.appFontScale(),
            locale: this.settings.locale, theme: this.settings.theme, muted: true, disableLinks: true, loading: thinking(),
          })
        }
        .width('100%').padding({ left: 12 })
        .border({ width: { left: 2 }, color: $r('app.color.native_chat_stroke') })
      }
    }
    if (message().content.length > (message().toolTimeline?.answerOffset ?? 0)) {
      NativeMarkdown({
        content: this.withCitationMarkers(message().content, message().citations ?? [], message().toolTimeline?.answerOffset ?? 0),
        fontScale: this.appFontScale(), viewportWidth: this.viewportWidth, hasCitations: true,
        citationSources: message().sources ?? [], citationHoverEnabled: this.wide(),
        locale: this.settings.locale, theme: this.settings.theme,
        loading: message().status === 'pending' || message().status === 'streaming',
        onCitation: (index: number): void => { this.openCitation(message().sources ?? [], index); },
      })
    }
  }

  private replyNotice(message: NativeConversationMessage): NativeReplyNotice {
    if (message.failure) {
      return describeNativeReplyFailure(message.failure, this.settings.locale);
    }
    return { text: this.archivedReplyTemplate(message) || '' };
  }

  private copyableReply(message: NativeConversationMessage): string {
    if (message.stopReason === 'refusal') {
      return this.archivedReplyTemplate(message) || nativeRefusalText(this.settings.locale);
    }
    return this.assistantResponseText(message) || (message.status === 'error' ? this.replyNotice(message).text : '');
  }

  private assistantResponseText(message: NativeConversationMessage): string {
    if (message.stopReason === 'refusal') return '';
    const answer = message.content.slice(message.toolTimeline?.answerOffset ?? 0);
    if (message.status === 'error' || message.status === 'pending' || message.status === 'streaming') return answer;
    const template = this.archivedReplyTemplate(message);
    return answer && template ? answer + '\n\n' + template : answer || template;
  }

  @Builder
  private replyErrorNotice(message: NativeConversationMessage) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      Text(this.replyNotice(message).text).fontSize(this.appFontSize(14)).fontColor($r('app.color.native_chat_error'))
      if (this.replyNotice(message).action === 'api-key') {
        Button(this.label('更换 API Key', 'Change API Key'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(this.appFontSize(13)).onClick(() => { this.openSettings('account'); })
      } else if (this.replyNotice(message).action === 'top-up') {
        Button(this.label('前往充值', 'Top up'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(this.appFontSize(13)).onClick(() => { void this.openLink('https://platform.deepseek.com/top_up'); })
      }
    }
    .width('100%')
  }

  private activeReplyMessage(id: string): NativeConversationMessage | undefined {
    const message = this.reply()?.message;
    return message?.id === id ? message : undefined;
  }

  private replyContentReady(id: string): boolean {
    const message = this.activeReplyMessage(id);
    return !message || !!(message.content || message.reasoning || message.thinking || message.toolTimeline?.steps.length);
  }

  @Builder
  private assistantMessage(message: () => NativeConversationMessage, index: number) {
    Column({ space: 7 }) {
      if (!this.replyContentReady(message().id)) {
        Row({ space: 6 }) {
          ForEach([0.45, 0.7, 1], (opacity: number) => {
            Circle().width(6).height(6).fill($r('app.color.native_chat_caption')).opacity(opacity)
          }, (opacity: number): string => opacity.toString())
        }
        .height(34).accessibilityText(this.label('正在等待回复', "Waiting for reply"))
      } else if (!this.activeReplyMessage(message().id) && message().stopReason === 'refusal') {
        NativeMarkdown({ content: this.copyableReply(message()), fontScale: this.appFontScale(),
          locale: this.settings.locale, theme: this.settings.theme })
      } else {
        this.replyContent(() => this.activeReplyMessage(message().id) ?? message(), () => {
          const active = this.activeReplyMessage(message().id);
          return !!active && !active.content;
        })
      }
      if (!this.activeReplyMessage(message().id)) {
        this.settledReplyControls(message(), index)
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
    .onHover((hovered: boolean) => { this.hoverMessage(message().id, hovered); })
    .parallelGesture(TapGesture().onAction(() => { this.messageActionsId = message().id; }))
  }

  @Builder
  private settledReplyControls(message: NativeConversationMessage, index: number) {
    if (message.stopReason !== 'refusal') {
      if (message.status !== 'error' && this.archivedReplyTemplate(message)) {
        NativeMarkdown({ content: this.archivedReplyTemplate(message), fontScale: this.appFontScale(),
          locale: this.settings.locale, theme: this.settings.theme })
      }
      this.sourcesSummary(message.id + ':summary', nativeSearchResults(message.sources ?? []))
    }
    if (message.status === 'error' && message.stopReason !== 'refusal' && this.replyNotice(message).text) {
      this.replyErrorNotice(message)
    }
    Row({ space: 10 }) {
      this.branchControls(message)
      Row({ space: 10 }) {
        if (this.copyableReply(message)) {
          NativeMessageCopyButton({ text: this.copyableReply(message), locale: this.settings.locale })
        }
        if (this.assistantResponseText(message)) {
          this.iconButton($r('app.media.native_speaker'),
            this.readingId === message.id ? this.label('停止朗读', 'Stop read-aloud') : this.label('朗读', 'Read aloud'),
            () => { this.readMessage(message); }, 28, 16,
            this.readingId === message.id ? $r('app.color.native_chat_blue_text') : $r('app.color.native_chat_action'))
        }
        this.iconButton($r('app.media.native_retry'), this.label('重新生成', 'Regenerate'), () => { this.retry(message); },
          28, 16, $r('app.color.native_chat_action'), Color.Transparent,
          () => this.canChangeVersion() && message.stopReason !== 'refusal')
      }
      .opacity(this.showMessageActions(message, index) ? 1 : 0)
      .onFocus(() => { this.messageActionsId = message.id; })
      if (this.canContinue(message)) {
        Blank().layoutWeight(1)
        Button(this.label('继续生成', 'Continue'), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(28).fontSize(this.appFontSize(13)).border({ width: 1, color: $r('app.color.native_chat_stroke') })
          .enabled(this.canChangeVersion()).onClick(() => { this.continueReply(message); })
      }
    }
    .width('100%').offset({ x: -6 }).padding({ top: 12, bottom: 10 })
  }

  private openSettings(section: string = 'root'): void {
    if (section === 'account') {
      this.prepareCredentialSettings();
    }
    void this.refreshBalance();
    this.settingsSection = section;
    this.settingsVisible = true;
  }

  private returnToSettings(): void {
    if (this.signingOut || this.deletingSessions) return;
    if (this.settingsSection === 'account') this.finishCredentialSettings();
    this.settingsSection = 'root';
  }

  private closeSettings(): void {
    if (this.signingOut || this.deletingSessions) return;
    if (this.settingsSection === 'account') this.finishCredentialSettings();
    this.settingsVisible = false;
  }

  private startSettingsDrag(fromHeader: boolean): void {
    this.settingsDragStartedAt = !this.wide() && this.settingsVisible &&
      (fromHeader || this.settingsScroll.currentOffset().yOffset <= 1) ? Date.now() : 0;
  }

  private finishSettingsDrag(event: GestureEvent): void {
    const startedAt = this.settingsDragStartedAt;
    this.settingsDragStartedAt = 0;
    if (startedAt && this.settingsVisible &&
      (event.offsetY > 96 || event.offsetY / Math.max(1, Date.now() - startedAt) > 0.45)) {
      this.closeSettings();
    }
  }

  private settingsSheetOptions(): SheetOptions {
    const wide = this.wide();
    return {
      preferType: wide ? SheetType.CENTER : SheetType.BOTTOM,
      width: wide ? 480 : undefined,
      height: wide ? Math.min(660, Math.max(320, this.viewportHeight - 32)) :
        Math.max(1, this.viewportHeight - (this.compact() ? 0 : 48)),
      blurStyle: BlurStyle.Thick,
      backgroundColor: $r('app.color.native_chat_sidebar'),
      dragBar: false,
      showClose: false,
      title: (): void => { this.settingsHeader(); },
      onWillDismiss: (action: DismissSheetAction): void => {
        if (this.signingOut || this.deletingSessions || this.authorizing) return;
        if (action.reason === DismissReason.PRESS_BACK && this.settingsSection !== 'root') {
          this.returnToSettings();
          return;
        }
        if (this.settingsSection === 'account') this.finishCredentialSettings();
        action.dismiss();
      },
    };
  }

  private offerMigrationPrompt(): boolean {
    if (this.settings.migrationPromptHandled) return false;
    this.settingsVisible = false;
    this.migrationPromptVisible = true;
    return true;
  }

  private dismissMigrationPrompt(restoreSettings: boolean = true): void {
    this.migrationPromptVisible = false;
    this.settings.migrationPromptHandled = true;
    if (restoreSettings) this.restoreAuthorizationSettings();
    void this.saveSettings();
  }

  private async importChatHistory(fromPrompt: boolean = false, importedUri?: string): Promise<boolean> {
    if (!this.loaded) return false;
    if (this.backupBusy || this.signingOut || this.migrationInProgress) {
      this.toast(this.label('请等待当前操作结束后再导入', 'Wait for the current operation to finish before importing'));
      return false;
    }
    const settingsFile = !fromPrompt && !importedUri;
    this.backupBusy = true;
    try {
      const context = this.host();
      const onSelected = async (): Promise<boolean> => {
        if (fromPrompt) {
          this.dismissMigrationPrompt();
          return true;
        }
        const selected = await this.getUIContext().getPromptAction().showDialog({
          title: this.label('确认导入历史对话？', 'Import chat history?'),
          message: this.label('上传的历史对话将按会话 ID 增量合并到本地，已有对话不会被清空。',
            'The uploaded chat history will be merged into your local chats by session ID without clearing existing chats.'),
          buttons: [{ text: this.label('取消', 'Cancel'), color: '#61666B' },
            { text: this.label('确认导入', 'Import'), color: '#EC1313' }],
        }).catch(() => undefined);
        if (selected?.index !== 1) return false;
        this.historyImportResult = '';
        this.historyImportFailed = false;
        this.historyImportProgress = this.label('正在解析归档文件，请稍候…', 'Reading the ZIP archive…');
        return true;
      };
      const onProgress = (sessions: number, images: number): void => {
        this.historyImportProgress = images > 0 ?
          this.label(`正在导入：已读取 ${sessions} 个会话，${images} 个附件`,
            `Reading backup. ${sessions} chats and ${images} attachments read.`) :
          this.label(`正在导入：已读取 ${sessions} 个会话`, `Reading backup. ${sessions} chats read.`);
      };
      const onVerified = async (): Promise<void> => {
        this.stopVoice();
        const active = Array.from(this.replies);
        this.cancelAllReplies();
        await Promise.all(active.map((reply: NativeReply): Promise<void> => reply.completion ?? Promise.resolve()));
      };
      const sessions = importedUri ?
        await this.backup.importFromUri(importedUri, context, onVerified) :
        await this.backup.importFromPicker(context, onSelected, onVerified, settingsFile ? onProgress : undefined);
      if (!sessions) return false;
      if (settingsFile) {
        this.historyImportProgress = this.label(`正在写入本地数据库（共 ${sessions.length} 个会话）…`,
          `Writing ${sessions.length} chats to the local database…`);
      }
      this.committingHistoryImport = true;
      const merged = await commitChatBackup(context, this.history, sessions,
        (state: NativeConversationState): Promise<void> => this.storage.saveConversations(context, state));
      this.history = merged.history;
      const count = merged.importedCount;
      const summary = this.label(`已导入 ${count} 个对话`, count === 1 ? 'Imported 1 chat' : `Imported ${count} chats`);
      if (settingsFile) {
        this.historyImportResult = summary;
      } else {
        this.toast(count ? summary : this.label('没有新增对话', 'No new chats to import'));
      }
      return true;
    } catch (error) {
      const storageFull = isBackupSpaceError(error as Error);
      const spaceMessage = this.label('设备存储空间不足，请清理空间后重试。', 'Free up storage space and try again.');
      if (settingsFile) {
        this.historyImportFailed = true;
        this.historyImportResult = storageFull ? spaceMessage : this.label(
          '文件导入失败，可能是文件格式错误或使用了旧版的对话导出 ZIP 文件，请前往 DeepSeek 重新导出历史对话文件后再次导入。',
          'File import failed. The file format may be invalid, or the ZIP file may use an older chat export format. ' +
          'Please export your chat history from DeepSeek again and retry the import.');
      } else {
        this.toast(storageFull ? spaceMessage : (error as Error).message || this.label('文件导入失败', "Unable to import file"));
      }
      return false;
    } finally {
      if (settingsFile) this.historyImportProgress = '';
      this.committingHistoryImport = false;
      this.backupBusy = false;
    }
  }

  private async exportChatHistory(): Promise<void> {
    if (!this.loaded || this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    try {
      if (await this.backup.exportToPicker(this.host(), this.historyWithPartialReplies().sessions, this.settings.locale)) {
        this.toast(this.label('已导出历史对话', "Chat history exported"));
      }
    } catch (error) {
      const detail = (error as Error).message;
      if (detail === NATIVE_BACKUP_UNREADABLE_CONVERSATION) {
        this.toast(this.label('部分对话无法读取。请打开这些对话重试后再导出。',
          'Some chats could not be loaded. Open those chats and retry before exporting.'));
      } else {
        this.toast(isBackupSpaceError(error as Error) ?
          this.label('设备存储空间不足，请清理空间后重试。', 'Free up storage space and try again.') :
          detail || this.label('导出失败', "Export failed"));
      }
    } finally {
      this.backupBusy = false;
    }
  }

  private async loadMigrationUsed(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, MIGRATION_PREFERENCES);
      this.migrationUsed = (await store.get(MIGRATION_USED_KEY, false)) === true;
    } catch {
      // Chat migration remains available if the preference cannot be read.
    }
  }

  private async markMigrationUsed(): Promise<void> {
    if (this.migrationUsed) return;
    this.migrationUsed = true;
    try {
      const store = await preferences.getPreferences(this.host(), MIGRATION_PREFERENCES);
      await store.put(MIGRATION_USED_KEY, true);
      await store.flush();
    } catch {
      // The current process still remembers that the migration was launched.
    }
  }

  private chooseHistoryMigration(): void {
    if (!this.loaded || this.migrationInProgress || this.migrationChoice || this.deleteNotice || this.updateNotice) return;
    if (this.backupBusy || this.replies.length > 0) {
      this.toast(this.label('请在回复结束后迁移', 'Migration is available after the reply finishes'));
      return;
    }
    if (this.migrationUsed || this.history.sessions.length > 0) {
      this.resizeMigrationChoice();
      this.migrationChoiceController.open();
    } else {
      void this.openHistoryMigration();
    }
  }

  private resizeMigrationChoice(): void {
    const compact = this.compact() || this.viewportHeight < 500;
    this.migrationChoice = {
      locale: this.settings.locale,
      fontScale: this.appFontScale(),
      compact,
      width: Math.max(1, Math.min(380, this.viewportWidth - (compact ? 16 : 32))),
      maxHeight: Math.max(1, this.viewportHeight - (compact ? 16 : 24)),
    };
  }

  private closeMigrationChoice(close: boolean = true): void {
    if (!this.migrationChoice) return;
    this.migrationChoice = null;
    if (close) this.migrationChoiceController.close();
  }

  private async openHistoryMigration(intent: NativeMigrationIntent = { clearSession: false, forceReExport: false }): Promise<void> {
    if (!this.loaded || this.migrationInProgress) return;
    if (this.backupBusy || this.replies.length > 0) {
      this.restoreAuthorizationSettings();
      this.toast(this.label('请在回复结束后迁移', 'Migration is available after the reply finishes'));
      return;
    }
    this.closeMigrationChoice();
    this.settingsVisible = false;
    this.migrationInProgress = true;
    try {
      await this.save();
      if (this.hasPendingHistorySave()) {
        this.migrationInProgress = false;
        this.historySaveError = true;
        this.restoreAuthorizationSettings();
        return;
      }
      await this.markMigrationUsed();
      this.migrationNavigationStarted = true;
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/HistoryMigration',
        params: { clearSession: intent.clearSession, forceReExport: intent.forceReExport },
      });
    } catch {
      this.migrationNavigationStarted = false;
      this.migrationPageWasHidden = false;
      this.migrationInProgress = false;
      this.restoreAuthorizationSettings();
      this.toast(this.label('无法打开历史迁移', "Unable to open chat migration"));
    }
  }

  private openShareImport(): void {
    if (!this.canModifyHistory()) {
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
    if (!this.shareInput.trim() || !this.canModifyHistory()) {
      return;
    }
    if (this.replies.length > 0) {
      this.shareImportError = this.label('请在回复结束后导入', 'Import is available after the reply finishes');
      return;
    }
    this.backupBusy = true;
    this.shareImportError = '';
    let lateChanges = false;
    try {
      const ids = new Set<string>(this.history.sessions.map((session: NativeConversation): string => session.id));
      const imported = await importNativeShareLink(this.shareInput, ids);
      const context = this.host();
      const previous = this.history;
      const next = upsertConversation(previous, imported, true);
      this.committingHistoryImport = true;
      try {
        await this.storage.saveConversations(context, next);
      } finally {
        lateChanges = this.history !== previous;
      }
      this.rememberCurrentDraft();
      if (this.history.activeId !== imported.id) this.stopVoice();
      this.history = lateChanges ? upsertConversation(this.history, imported, true) : next;
      this.restoreDraft(imported.id);
      this.shareImportVisible = false;
      this.shareInput = '';
      this.scrollToLatest();
      this.toast(this.label('已导入 1 个对话', "Imported 1 chat"));
    } catch (error) {
      this.shareImportError = (error as Error).message || this.label('该分享链接无法导入', "Unable to import this share link");
    } finally {
      this.committingHistoryImport = false;
      this.backupBusy = false;
      if (lateChanges) void this.save();
    }
  }

  @Builder
  private shareImportDialog() {
    Column({ space: 14 }) {
      Text(this.label('通过 DeepSeek 分享链接导入', "Import from a DeepSeek share link")).fontSize(this.appFontSize(18)).fontWeight(FontWeight.Medium).width('100%')
        .fontColor($r('app.color.native_chat_primary'))
      TextArea({ text: this.shareInput, placeholder: this.label(
        '粘贴分享链接或包含链接的完整分享文案，例如：https://chat.deepseek.com/share/...',
        'Paste a link or text containing a link, such as https://chat.deepseek.com/share/…') })
        .height(96).width('100%').fontSize(this.appFontSize(14)).enabled(!this.backupBusy).maxLength(4096).borderRadius(14)
        .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
        .onChange((text: string) => { this.shareInput = text; this.shareImportError = ''; })
      if (this.shareImportError) {
        Text(this.shareImportError).width('100%').fontColor($r('app.color.native_chat_error')).fontSize(this.appFontSize(13))
      }
      Row({ space: 8 }) {
        Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(this.appFontSize(14)).enabled(!this.backupBusy)
          .onClick(() => { this.closeShareImport(); })
        Button(this.backupBusy ? this.label('导入中…', "Importing…") : this.label('确认导入', "Import"))
          .fontSize(this.appFontSize(14)).enabled(!this.backupBusy && !!this.shareInput.trim())
          .backgroundColor($r('app.color.native_chat_blue')).onClick(() => { void this.acceptShareImport(); })
      }
      .width('100%').justifyContent(FlexAlign.End)
    }
    .width('86%').constraintSize({ maxWidth: 440 }).padding(20).borderRadius(22)
    .backgroundColor($r('app.color.native_chat_surface')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  }

  private archivedReplyTemplate(message: NativeConversationMessage): string {
    const session = this.session();
    return session ? nativeArchivedReplyTemplate(session, message.id) ?? '' : '';
  }

  private async startUpdateChecks(): Promise<void> {
    try {
      this.updatePreferences = await this.updateSchedule.load(this.host());
      this.pendingUpdate = this.updatePreferences.pendingUpdate ?? null;
    } catch {
      // Update checks remain available if the schedule could not be restored.
    }
    if (this.updateTimer < 0) {
      this.updateTimer = setInterval(() => {
        if (this.visible) {
          void this.checkUpdate(true, false);
        }
      }, UPDATE_POLL_MS);
      await this.resumeUpdateChecks(true);
    }
  }

  private async resumeUpdateChecks(force: boolean = false): Promise<void> {
    if (this.pendingUpdate && this.visible && !this.updateNotice && !this.deleteNotice && !this.migrationChoice &&
      !this.checkingUpdate &&
      !this.authorizing && !this.backupBusy && !this.signingOut &&
      !isUpdateSnoozed(this.pendingUpdate, this.updatePreferences, Date.now())) {
      this.presentUpdate(this.pendingUpdate);
    }
    if (force || Date.now() - this.updatePreferences.checkAt >= UPDATE_RESUME_MS) {
      await this.checkUpdate(true);
    }
  }

  private presentUpdate(update: NativeUpdateCheck): void {
    const open = this.updateNotice !== null;
    const compact = this.compact();
    this.updateNotice = {
      update,
      locale: this.settings.locale,
      fontScale: this.appFontScale(),
      compact,
      width: Math.max(1, Math.min(400, this.viewportWidth - (compact ? 16 : 32))),
      maxHeight: Math.max(1, this.viewportHeight - (compact ? 16 : 24)),
    };
    if (!open) this.updateNoticeController.open();
  }

  private closeUpdateNotice(snooze: boolean, close: boolean = true): void {
    const update = this.updateNotice?.update;
    if (!update) return;
    this.updateNotice = null;
    if (close) this.updateNoticeController.close();
    if (snooze) {
      this.updatePreferences.dismissedVersion = update.latestVersion;
      this.updatePreferences.dismissedAt = Date.now();
      void this.updateSchedule.dismissed(this.host(), update.latestVersion, this.updatePreferences.dismissedAt)
        .catch(() => {});
    }
  }

  private openUpdateDestination(): void {
    const update = this.updateNotice?.update;
    if (!update) return;
    this.closeUpdateNotice(false);
    void this.openLink(update.appGalleryUrl ?? update.downloadUrl ?? update.releaseUrl);
  }

  private async checkUpdate(silent: boolean = false, prompt: boolean = true): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const update = await checkNativeUpdate();
      this.updatePreferences.checkAt = Date.now();
      void this.updateSchedule.checked(this.host(), this.updatePreferences.checkAt, update).catch(() => {});
      this.pendingUpdate = update.hasUpdate ? update : null;
      if (!update.hasUpdate) {
        this.closeUpdateNotice(false);
        if (!silent) {
          this.toast(this.label('当前已是最新版本', "You're using the latest version"));
        }
        return;
      }
      if (!this.deleteNotice && !this.migrationChoice && (this.updateNotice || !silent ||
        (prompt && this.visible && !this.authorizing && !this.backupBusy && !this.signingOut &&
          !isUpdateSnoozed(update, this.updatePreferences, Date.now())))) {
        this.presentUpdate(update);
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
      Button(this.label('重试', "Retry"), { buttonStyle: ButtonStyleMode.TEXTUAL })
        .fontSize(this.appFontSize(14)).onClick(() => { void this.loadReleaseNotes(); })
    } else if (!this.releaseNotes.length) {
      Text(this.label('暂无历史版本记录', "No release history")).width('100%').fontColor($r('app.color.native_chat_secondary'))
    } else {
      ForEach(this.releaseNotes, (release: NativeReleaseHistoryItem) => {
        Column({ space: 10 }) {
          Row() {
            Text(`v${release.version}`).fontSize(this.appFontSize(16)).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.native_chat_primary')).layoutWeight(1)
            Text(release.createdAt.slice(0, 10)).fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary'))
          }
          .width('100%')
          Text(release.changelog || this.label('包含体验优化与问题修复。', 'Includes improvements and bug fixes.'))
            .width('100%').fontSize(this.appFontSize(14)).lineHeight(22)
            .fontColor($r('app.color.native_chat_secondary')).copyOption(CopyOptions.LocalDevice)
        }
        .width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.native_chat_surface'))
      }, (release: NativeReleaseHistoryItem): string => release.id)
    }
  }

  private settingsTitle(): string {
    switch (this.settingsSection) {
      case 'account': return this.label('账号管理', "Account management");
      case 'data': return this.label('数据管理', "Data management");
      case 'notes': return this.label('更新日志', "Release notes");
      case 'feedback': return this.label('日志上报与问题反馈', 'Issue Feedback and Diagnostics');
      default: return this.label('设置', "Settings");
    }
  }

  @Builder
  private settingsLabel(title: () => string) {
    Text(title()).width('100%').fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary')).padding({ left: 9, bottom: 4 })
  }

  @Builder
  private settingsIcon(icon: Resource) {
    Image(icon).width(20).height(20).colorFilter(nativeIconTint($r('app.color.native_chat_primary')))
      .draggable(false).accessibilityLevel('no')
  }

  private lowBalance(): boolean {
    return !!this.balance && (!this.balance.isAvailable || Number(this.balance.totalBalance) <= 0);
  }

  @Builder
  private settingsRow(icon: Resource, title: () => string, value: () => string, click: () => void,
    enabled: () => boolean = () => true, showsBalance: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        this.settingsIcon(icon)
        Text(title()).layoutWeight(1).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
        if (showsBalance && this.balance) {
          Text(this.balance.formatted).fontSize(this.appFontSize(13)).fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '48%' })
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(100)
            .fontColor(this.lowBalance() ? $r('app.color.native_settings_balance_low') :
              $r('app.color.native_settings_balance'))
            .backgroundColor(this.lowBalance() ? $r('app.color.native_settings_balance_low_bg') :
              $r('app.color.native_settings_balance_bg'))
        } else if (value()) {
          Text(value()).fontSize(this.appFontSize(14)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '48%' }).fontColor($r('app.color.native_chat_secondary'))
        }
        Image($r('app.media.native_chevron_right')).width(14).height(14).colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
          .draggable(false).accessibilityLevel('no')
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
    .width('100%').padding(0).borderRadius(0).backgroundColor(Color.Transparent).enabled(enabled()).onClick(click)
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
      .font({ size: this.appFontSize(14) })
      .optionFont({ size: this.appFontSize(14) })
      .selectedOptionFont({ size: this.appFontSize(14) })
      .selected(options().findIndex((option: NativeLocationOption): boolean => option.code === current()))
      .value(options().find((option: NativeLocationOption): boolean => option.code === current())?.name ?? placeholder())
      .enabled(options().length > 0)
      .accessibilityText(placeholder())
      .onSelect((index: number) => { onSelect(options()[index]?.code ?? ''); })
  }

  @Builder
  private locationRows() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_location'))
        Text(this.label('位置', 'Location')).layoutWeight(1).fontSize(this.appFontSize(15))
          .fontColor($r('app.color.native_chat_primary'))
        if (this.settings.location) {
          Button(this.label('清除', 'Clear'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(13)).onClick(() => { this.setLocation(null); })
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
        .width('100%').fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary'))
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12, left: 16, right: 16 })
  }

  @Builder
  private settingsRoot() {
    this.settingsLabel(() => this.label('账户', 'Account'))
    Column() {
      this.settingsRow($r('app.media.native_settings_account'), () => this.label('账号管理', 'Account management'), () =>
        this.accountToken() ? this.account?.label ?? this.label('DeepSeek API 账号', 'DeepSeek API account') : this.settings.model,
        () => { this.openSettings('account'); })
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_wallet'), () => this.label('API 余额', 'API balance'),
        () => this.label('前往充值', 'Top up'), () => { void this.openLink('https://platform.deepseek.com/top_up'); },
        () => true, true)
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_data'), () => this.label('数据管理', 'Data management'),
        () => this.loaded ? this.label(`${this.history.sessions.length} 条对话`,
          this.history.sessions.length === 1 ? '1 chat' : `${this.history.sessions.length} chats`) : '',
        () => { this.settingsSection = 'data'; }, () => this.loaded)
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel(() => this.label('应用', 'App'))
    Column() {
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_language'))
        Text(this.label('语言', 'Language')).layoutWeight(1).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '简体中文' }, { value: 'English' }])
          .font({ size: this.appFontSize(14) })
          .optionFont({ size: this.appFontSize(14) })
          .selectedOptionFont({ size: this.appFontSize(14) })
          .selected(this.settings.locale === 'en-US' ? 1 : 0)
          .value(this.settings.locale === 'en-US' ? 'English' : '简体中文')
          .accessibilityText(this.label('语言', 'Language'))
          .onSelect((index: number) => {
            this.settings.locale = index === 1 ? 'en-US' : 'zh-CN';
            void this.refreshBalance(true);
            void this.saveSettings('locale');
          })
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 4, bottom: 4 })
      Divider().color($r('app.color.native_chat_stroke'))
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_theme'))
        Text(this.label('外观', "Theme")).layoutWeight(1).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: this.label('系统', "System") }, { value: this.label('浅色', "Light") }, { value: this.label('深色', "Dark") }])
          .font({ size: this.appFontSize(14) })
          .optionFont({ size: this.appFontSize(14) })
          .selectedOptionFont({ size: this.appFontSize(14) })
          .selected(this.settings.theme === 'dark' ? 2 : this.settings.theme === 'light' ? 1 : 0)
          .value(this.settings.theme === 'dark' ? this.label('深色', "Dark") : this.settings.theme === 'light' ? this.label('浅色', "Light") : this.label('系统', "System"))
          .accessibilityText(this.label('外观', 'Theme'))
          .onSelect((index: number) => {
            this.settings.theme = index === 2 ? 'dark' : index === 1 ? 'light' : 'system';
            this.applyTheme();
            void this.saveSettings();
          })
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 4, bottom: 4 })
      Divider().color($r('app.color.native_chat_stroke'))
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_font_size'))
        Text(this.label('字体大小', "Font size")).layoutWeight(1).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
        Select([{ value: '12px' }, { value: '14px' }, { value: this.label('16px（默认）', "16px (default)") },
          { value: '18px' }, { value: '20px' }, { value: '22px' }])
          .font({ size: this.appFontSize(14) })
          .optionFont({ size: this.appFontSize(14) })
          .selectedOptionFont({ size: this.appFontSize(14) })
          .selected(NATIVE_CHAT_FONT_SIZES.indexOf(this.settings.chatFontSize))
          .value(this.settings.chatFontSize === 16 ? this.label('16px（默认）', "16px (default)") : `${this.settings.chatFontSize}px`)
          .accessibilityText(this.label('字体大小', 'Font size'))
          .onSelect((index: number) => {
            this.settings.chatFontSize = NATIVE_CHAT_FONT_SIZES[index] ?? 16;
            void this.saveSettings();
          })
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 4, bottom: 4 })
      Divider().color($r('app.color.native_chat_stroke'))
      this.locationRows()
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    this.settingsLabel(() => this.label('语音', 'Speech'))
    NativeSpeechSettings({
      locale: this.settings.locale, fontScale: this.appFontScale(), engine: this.settings.speechEngine, voice: this.settings.speechVoice,
      cloudRecognition: isCloudAsrAvailable(this.speechOptions()), cloudSynthesis: isCloudTtsAvailable(this.speechOptions()),
      onEngine: (engine: HarmonySpeechEngine): void => {
        this.stopVoice();
        this.settings.speechEngine = engine;
        void this.saveSettings();
      },
      onVoice: (voice: HarmonySpeechVoice): void => {
        this.settings.speechVoice = voice;
        void this.saveSettings();
      },
    })
    this.settingsLabel(() => this.label('关于', 'About'))
    Column() {
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_info'))
        Text(this.label('当前版本', "Current version")).layoutWeight(1).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
        Text(this.appVersion).fontSize(this.appFontSize(14)).fontColor($r('app.color.native_chat_secondary'))
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 4, bottom: 4 })
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_download'),
        () => this.checkingUpdate ? this.label('检查中...', 'Checking…') : this.label('检查更新', 'Check for updates'),
        () => '', () => { void this.checkUpdate(); }, () => !this.checkingUpdate)
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_document'), () => this.label('更新日志', 'Release notes'), () => '',
        () => { this.settingsSection = 'notes'; void this.loadReleaseNotes(); })
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_info'),
        () => this.label('问题反馈与日志上报', 'Feedback & Diagnostics'), () => '', () => { this.settingsSection = 'feedback'; })
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_document'), () => this.label('隐私政策', 'Privacy policy'), () => '', () => {
        void openNuwaPrivacyPolicy(this.host()).catch(() => {
          this.toast(this.label('无法打开隐私政策', 'Unable to open the privacy policy'));
        });
      })
      Divider().color($r('app.color.native_chat_stroke'))
      this.settingsRow($r('app.media.native_settings_document'), () => this.label('API 文档与帮助', 'API Docs & Help'), () => '',
        () => { void this.openLink(DEEPSEEK_DOCS_URL); })
    }
    .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        this.settingsIcon($r('app.media.native_settings_sign_out'))
        Text(this.label('退出登录', 'Sign Out')).layoutWeight(1).textAlign(TextAlign.Start)
          .fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_primary'))
      }
      .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
    .width('100%').borderRadius(16).padding(0).backgroundColor($r('app.color.native_chat_surface'))
    .enabled(!this.signingOut).onClick(() => { void this.signOutAll(); })
  }

  @Builder
  private accountSettings() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
      Column({ space: 6 }) {
        Text(this.label('DeepSeek API 账号', 'DeepSeek API Account')).fontSize(this.appFontSize(14))
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
        if (this.account) {
          Text(this.accountToken() ? this.label(`当前生效：${this.account.label}`, `Active: ${this.account.label}`) :
            this.label(`已登录：${this.account.label}（当前使用自定义 API Key）`,
              `Signed in: ${this.account.label} (using custom API Key)`))
            .fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary'))
        } else {
          Text(this.label('通过 DeepSeek 开放平台授权登录，免手动复制 API Key',
            'Authorize via DeepSeek Platform without pasting an API Key'))
            .fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_secondary'))
        }
      }
      .constraintSize({ maxWidth: this.compact() ? '100%' : '70%' }).alignItems(HorizontalAlign.Start)
      Row({ space: 6 }) {
        if (this.account) {
          if (!this.accountToken()) {
            Button(this.label('切换为此账号', 'Use Account'), { buttonStyle: ButtonStyleMode.TEXTUAL })
              .height(34).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_blue_text'))
              .enabled(!this.settingsVerifying).onClick(() => { void this.enableAccount(); })
          }
          Button(this.label('退出登录', 'Sign Out'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .height(34).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_error'))
            .enabled(!this.settingsVerifying).onClick(() => { void this.logoutAccount(); })
        } else {
          Button(this.label('账号登录', 'Sign In'), { type: ButtonType.Capsule })
            .height(34).fontSize(this.appFontSize(13)).backgroundColor($r('app.color.native_chat_blue'))
            .enabled(!this.authorizing && !this.settingsVerifying && !this.backupBusy)
            .onClick(() => { void this.startAuthorization(); })
        }
      }
    }
    .width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.native_chat_surface'))
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(8) } }) {
      Text(this.label('接口协议', 'API Protocol')).fontSize(this.appFontSize(14)).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.native_chat_primary'))
      Select([{ value: this.label('OpenAI 兼容', 'OpenAI Compatible') }, { value: this.label('Anthropic 兼容', 'Anthropic Compatible') }])
        .font({ size: this.appFontSize(14) })
        .optionFont({ size: this.appFontSize(14) })
        .selectedOptionFont({ size: this.appFontSize(14) })
        .selected(this.settingsProtocol === 'anthropic' ? 1 : 0)
        .value(this.settingsProtocol === 'anthropic' ? this.label('Anthropic 兼容', 'Anthropic Compatible') :
          this.label('OpenAI 兼容', 'OpenAI Compatible'))
        .enabled(!this.settingsVerifying)
        .onSelect((index: number) => {
          this.settingsProtocol = index === 1 ? 'anthropic' : 'openai';
          this.settingsError = '';
          this.commitSettingsModel();
        })
    }
    .width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.native_chat_surface'))
    this.credentialField(() => this.label('API 地址 (Base URL)', 'API Base URL'), () => this.settingsBase,
      () => this.label('例如 https://api.deepseek.com 或 https://api.openai.com/v1',
        'e.g. https://api.deepseek.com or https://api.openai.com/v1'),
      (value: string) => { this.settingsBase = value; this.settingsError = ''; })
    this.credentialField(() => this.label('模型名称', 'Model Name'), () => this.settingsModel,
      () => this.label('例如 deepseek-chat、deepseek-reasoner、gpt-4o', 'e.g. deepseek-chat, deepseek-reasoner, gpt-4o'),
      (value: string) => { this.settingsModel = value; this.settingsError = ''; })
    this.apiKeySettings()
    if (!this.wide() && this.canVerifySettings()) {
      Button(this.settingsVerifying ? this.label('正在验证...', 'Verifying...') : this.label('确定', 'Confirm'))
        .width('100%').height(42).fontSize(this.appFontSize(14))
        .backgroundColor($r('app.color.native_chat_blue')).enabled(!this.settingsVerifying)
        .onClick(() => { void this.verifySettingsKey(); })
    }
  }

  @Builder
  private credentialField(title: () => string, value: () => string, placeholder: () => string, change: (text: string) => void) {
    Column({ space: 8 }) {
      Text(title()).width('100%').fontSize(this.appFontSize(14)).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.native_chat_primary'))
      TextInput({ text: value(), placeholder: placeholder() }).width('100%').height(42).fontSize(this.appFontSize(14))
        .backgroundColor($r('app.color.native_chat_field')).fontColor($r('app.color.native_chat_primary'))
        .placeholderColor($r('app.color.native_chat_caption')).enabled(!this.settingsVerifying)
        .onChange(change).onBlur(() => { this.commitSettingsModel(); })
        .enterKeyType(EnterKeyType.Done).onSubmit(() => { this.commitSettingsModel(); })
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(16)
    .backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private apiKeySettings() {
    Column({ space: 8 }) {
      Text(this.label('输入 API Key 开始使用', 'Enter an API Key to get started'))
        .width('100%').fontSize(this.appFontSize(14)).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
      if (this.settings.apiKey && !this.settingsKeyEditing && this.settingsEndpointMatches()) {
        Row({ space: 8 }) {
          Text('*'.repeat(this.settings.apiKey.length)).layoutWeight(1).fontSize(this.appFontSize(14)).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.native_chat_secondary'))
          this.iconButton($r('app.media.native_edit'), this.label('修改 API Key', 'Edit API Key'),
            () => { this.editSettingsKey(); }, 32, 16, $r('app.color.native_chat_blue_text'))
        }
        .width('100%').height(42).padding({ left: 12, right: 4 }).borderRadius(21)
        .backgroundColor($r('app.color.native_chat_field'))
      } else {
        Row({ space: 4 }) {
          TextInput({ text: this.settingsKey, placeholder: allowsKeylessNativeApi(this.settingsBase, this.settingsProtocol) ?
            this.label('局域网服务可留空', 'Optional for local services') : this.label('请输入 API Key', 'Enter API Key') })
            .id('nuwa-account-api-key').defaultFocus(this.wide()).layoutWeight(1).height(42)
            .fontSize(this.appFontSize(14)).type(InputType.Password).showPasswordIcon(false).enterKeyType(EnterKeyType.Done)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.native_chat_primary'))
            .placeholderColor($r('app.color.native_chat_caption')).enabled(!this.settingsVerifying)
            .onChange((value: string) => { this.settingsKey = value; this.settingsError = ''; })
            .onBlur(() => { this.finishSettingsKeyEdit(); })
            .onSubmit(() => { void this.verifySettingsKey(); })
          if (this.wide() && this.canVerifySettings()) {
            Button(this.settingsVerifying ? this.label('正在验证...', 'Verifying...') : this.label('确定', 'Confirm'),
              { buttonStyle: ButtonStyleMode.TEXTUAL })
              .height(34).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_blue_text'))
              .enabled(!this.settingsVerifying).onClick(() => { void this.verifySettingsKey(); })
          }
        }
        .width('100%').height(42).borderRadius(21).backgroundColor($r('app.color.native_chat_field'))
        if (this.settingsError) {
          Text(this.settingsError).width('100%').fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_error'))
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(16)
    .backgroundColor($r('app.color.native_chat_surface'))
  }

  @Builder
  private settingsHeader() {
    Column() {
      if (!this.wide()) {
        Row().width(38).height(4).borderRadius(2).margin({ top: 8 }).backgroundColor('#5980808A')
      }
      Row() {
        if (this.settingsSection === 'root') {
          Blank().width(this.compact() ? 30 : 36)
        } else {
          this.iconButton($r('app.media.native_chevron_left'), this.label('返回', "Back"),
            () => { this.returnToSettings(); }, this.compact() ? 30 : 36, 18,
            $r('app.color.native_chat_primary'), $r('app.color.native_chat_surface'))
        }
        Text(this.settingsTitle()).layoutWeight(1).textAlign(TextAlign.Center)
          .fontSize(this.appFontSize(this.compact() ? 15 : 17)).lineHeight(this.compact() ? 20 : 24).fontWeight(600)
          .fontColor($r('app.color.native_chat_primary'))
        this.iconButton($r('app.media.native_close'), this.label('关闭', "Close"),
          () => { this.closeSettings(); }, this.compact() ? 30 : 36, 16,
          $r('app.color.native_chat_primary'), $r('app.color.native_chat_surface'))
      }
      .width('100%').padding({
        left: this.compact() ? 10 : 16, right: this.compact() ? 10 : 16,
        top: this.wide() ? 16 : 8, bottom: this.compact() ? 6 : 10,
      })
    }
    .width('100%').enabled(!this.signingOut)
    .parallelGesture(
      PanGesture({ direction: PanDirection.Down, distance: 3 })
        .onActionStart(() => { this.startSettingsDrag(true); })
        .onActionEnd((event: GestureEvent) => { this.finishSettingsDrag(event); })
    )
  }

  @Builder
  private settingsPage() {
    Scroll(this.settingsScroll) {
      Column({ space: 10 }) {
        if (this.settingsSection === 'account') {
          this.accountSettings()
        } else if (this.settingsSection === 'data') {
          NativeDataSettings({
            busy: this.backupBusy, sessionCount: this.history.sessions.length, locale: this.settings.locale,
            fontScale: this.appFontScale(),
            historyImportProgress: this.historyImportProgress, historyImportResult: this.historyImportResult,
            historyImportFailed: this.historyImportFailed,
            onMigration: () => { this.chooseHistoryMigration(); },
            onShareImport: () => { this.openShareImport(); },
            onImport: () => { void this.importChatHistory(); },
            onExport: () => { void this.exportChatHistory(); },
            onDeleteAll: () => { this.deleteSessions([], 'all'); },
          })
        } else if (this.settingsSection === 'notes') {
          this.releaseNotesPage()
        } else if (this.settingsSection === 'feedback') {
          NativeFeedbackReport({
            locale: this.settings.locale, appVersion: this.appVersion, apiProtocol: this.settings.protocol,
            fontScale: this.appFontScale(),
            authMode: this.settings.authMode, viewportWidth: this.viewportWidth, viewportHeight: this.viewportHeight,
          })
        } else {
          this.settingsRoot()
        }
      }
      .width('100%').padding({
        left: this.compact() ? 10 : 16, right: this.compact() ? 10 : 16,
        top: 4, bottom: this.compact() ? 16 : 24,
      }).alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .enabled(!this.signingOut)
    .parallelGesture(
      PanGesture({ direction: PanDirection.Down, distance: 5 })
        .onActionStart(() => { this.startSettingsDrag(false); })
        .onActionEnd((event: GestureEvent) => { this.finishSettingsDrag(event); })
    )
  }

  @Builder
  private authorizationPage() {
    Column() {
      Row({ space: 8 }) {
        if (this.authorizationInBrowser) {
          Blank().layoutWeight(1)
        } else {
          Text(this.authorizationStatus).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_secondary')).layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.authorizationUrl && !this.authorizationInBrowser) {
          Button(this.label('使用浏览器', 'Use browser'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14))
            .enabled(!this.storingAccount).onClick(() => { this.switchAuthorizationToBrowser(); })
        }
        Button(this.label('关闭', "Close"), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .fontSize(this.appFontSize(14)).enabled(!this.storingAccount)
          .onClick(() => { this.cancelAuthorization(); })
      }
      .width('100%').padding({ left: 14, right: 8, top: 6, bottom: 6 })
      if (this.authorizationUrl) {
        ForEach([this.authAttempt], (attempt: number) => {
          Web({ src: this.authorizationUrl, controller: this.authBrowser }).width('100%').layoutWeight(1)
            .mixedMode(MixedMode.None).javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
            .onLoadIntercept((event) => {
              return attempt !== this.authAttempt ||
                this.interceptAuthorization(event.data.getRequestUrl(), event.data.isMainFrame());
            })
        }, (attempt: number): string => attempt.toString())
      } else if (this.authorizationRetry) {
        Column({ space: 12 }) {
          if (this.authorizationInBrowser) {
            Text(this.authorizationStatus).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_secondary'))
              .textAlign(TextAlign.Center)
          }
          Button(this.label('重试', 'Try again'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14))
            .onClick(() => { void this.loadAuthorization(this.authorizationInBrowser); })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
      } else if (!this.authorizationInBrowser) {
        Column() { LoadingProgress().width(30).height(30) }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Text(this.authorizationStatus).fontSize(this.appFontSize(15)).fontColor($r('app.color.native_chat_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
  }

  private sidebarSessionTitle(title: string): string {
    return title || this.label('新对话', 'New chat');
  }

  private beginSidebarSelection(id: string): void {
    if (this.selecting || this.backupBusy || !this.session(id)) return;
    this.finishSidebarRename(this.renamingId, this.renameText);
    this.selectedIds = [id];
    this.selecting = true;
  }

  private beginSidebarRename(session: NativeSidebarSession): void {
    if (!this.canEditSidebarMetadata(session.id) || this.selecting || this.renamingId === session.id) return;
    this.finishSidebarRename(this.renamingId, this.renameText);
    this.renameText = this.sidebarSessionTitle(session.title);
    this.renamingId = session.id;
  }

  private focusSidebarRename(id: string, retry: boolean = true): void {
    setTimeout((): void => {
      if (this.renamingId !== id) return;
      try {
        this.getUIContext().getFocusController().requestFocus('nuwa-sidebar-rename-' + id);
      } catch {
        // An open system menu can own focus until its close animation finishes.
        if (retry) this.focusSidebarRename(id, false);
      }
    }, retry ? 0 : 160);
  }

  private cancelSidebarRename(id: string): void {
    if (!id || this.renamingId !== id) return;
    this.renamingId = '';
    this.renameText = '';
  }

  private finishSidebarRename(id: string, title: string): void {
    if (!id || this.renamingId !== id) return;
    this.cancelSidebarRename(id);
    const current = this.session(id);
    const trimmed = title.trim();
    if (!this.canModifyHistory() || !current || current.unreadable || !trimmed ||
      trimmed === this.sidebarSessionTitle(current.title)) return;
    this.history = renameConversation(this.history, id, trimmed);
    void this.save();
  }

  private handleSidebarRenameKey(id: string, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ESCAPE) return false;
    this.cancelSidebarRename(id);
    return true;
  }

  private canModifyHistory(): boolean {
    return this.loaded && !this.backupBusy && !this.migrationInProgress && !this.signingOut;
  }

  private canEditSidebarMetadata(id: string): boolean {
    const session = this.session(id);
    return this.canModifyHistory() && !!session && !session.unreadable;
  }

  private canPinSidebarSelection(): boolean {
    return this.selectedIds.length > 0 && this.selectedIds.every((id: string): boolean => this.canEditSidebarMetadata(id));
  }

  private pinSidebarSession(id: string): void {
    if (!this.canEditSidebarMetadata(id)) return;
    this.history = toggleConversationPin(this.history, id);
    void this.save();
  }

  private pinSidebarSelection(): void {
    if (!this.canPinSidebarSelection()) return;
    this.history = setConversationsPinned(this.history, this.selectedIds, !this.allPinned());
    this.resetSelection();
    void this.save();
  }

  @Builder
  private sessionMenu(session: NativeSidebarSession) {
    Menu() {
      MenuItem({ content: session.pinnedAt ? this.label('取消置顶', "Unpin") : this.label('置顶', "Pin") })
        .enabled(this.canEditSidebarMetadata(session.id)).onClick(() => { this.pinSidebarSession(session.id); })
      MenuItem({ content: this.label('多选', "Select") }).onClick(() => { this.beginSidebarSelection(session.id); })
      MenuItem({ content: this.label('重命名', "Rename") }).enabled(this.canEditSidebarMetadata(session.id))
        .onClick(() => { this.beginSidebarRename(session); })
      MenuItem({ content: this.label('删除', "Delete") }).contentFontColor($r('app.color.native_chat_error'))
        .onClick(() => { this.deleteSessions([session.id], 'single'); })
    }
    .font({ size: this.appFontSize(14) })
  }

  @Builder
  private drawerItem(session: NativeSidebarSession) {
    if (!this.selecting && this.renamingId === session.id) {
      TextInput({ text: this.renameText })
        .id('nuwa-sidebar-rename-' + session.id)
        .width('100%').height(this.wide() ? 40 : 44)
        .padding({ left: this.wide() ? 10 : 12, right: this.wide() ? 10 : 12 })
        .fontSize(this.appFontSize(this.wide() ? 14 : 16)).fontColor($r('app.color.native_chat_primary'))
        .borderRadius(this.wide() ? 12 : 16)
        .border({ width: 1, color: $r('app.color.native_chat_blue') })
        .backgroundColor($r('app.color.native_chat_field'))
        .accessibilityText(this.label('重命名对话', 'Rename chat'))
        .selectAll(true).enterKeyType(EnterKeyType.Done)
        .onAppear(() => { this.focusSidebarRename(session.id); })
        .onChange((title: string) => {
          if (this.renamingId === session.id) this.renameText = title;
        })
        .onSubmit((_key: EnterKeyType, event: SubmitEvent) => { this.finishSidebarRename(session.id, event.text); })
        .onBlur(() => { this.finishSidebarRename(session.id, this.renameText); })
        .onKeyPreIme((event: KeyEvent): boolean => this.handleSidebarRenameKey(session.id, event))
    } else {
      Row() {
        Row() {
          if (this.selecting) {
            Checkbox({ name: session.id }).select(this.selectedIds.includes(session.id))
              .shape(CheckBoxShape.CIRCLE).selectedColor($r('app.color.native_chat_blue'))
              .width(20).height(20).margin({ right: 10 })
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          }
          if (session.pinnedAt) {
            Image($r('app.media.native_pin')).width(13).height(13).margin({ right: 5 }).opacity(0.85)
              .colorFilter(nativeIconTint($r('app.color.native_chat_blue_text'))).draggable(false).accessibilityLevel('no')
          }
          Text(this.sidebarSessionTitle(session.title)).fontSize(this.appFontSize(this.wide() ? 14 : 16)).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.native_chat_primary'))
        }
        .height('100%').layoutWeight(1).focusable(true)
        .onClick(() => {
          if (this.selecting) {
            this.toggleSelected(session.id);
          } else {
            this.activate(session.id);
          }
        })
        .priorityGesture(LongPressGesture({ duration: 450 }).onAction(() => { this.beginSidebarSelection(session.id); }))
        if (!this.selecting) {
          Button('⋯', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(18).width(32).height(32).padding(0).margin({ left: 4 })
            .fontColor($r('app.color.native_chat_secondary')).accessibilityText(this.label('对话选项', "Chat options"))
            .bindMenu(this.sessionMenu(session))
        }
      }
      .height(this.wide() ? 40 : 44).width('100%').padding({ left: this.wide() ? 10 : 12, right: 6 })
      .borderRadius(this.wide() ? 12 : 16)
      .backgroundColor(!this.selecting && session.id === this.history.activeId ?
        $r('app.color.native_chat_active_session') : Color.Transparent)
    }
  }

  @Builder
  private sidebarGroupHeader(key: string, label: string) {
    Text(this.historyGroupLabel(key, label)).fontSize(this.appFontSize(12))
      .lineHeight(18).fontWeight(FontWeight.Medium).width('100%')
      .fontColor($r('app.color.native_chat_action')).backgroundColor($r('app.color.native_chat_sidebar'))
      .padding({ top: 2, right: 10, bottom: 2, left: 10 })
  }

  @Builder
  private drawer(desktop: boolean = false) {
    Column() {
      if (desktop && !this.selecting) {
        Row({ space: 9 }) {
          Image($r('app.media.native_welcome_logo')).width(28).height(28).borderRadius(8).draggable(false)
          Text('Nuwa').fontSize(this.appFontSize(20)).fontWeight(FontWeight.Medium).layoutWeight(1)
            .fontColor($r('app.color.native_chat_primary'))
          this.iconButton($r('app.media.native_menu'), this.label('收起侧边栏', 'Close sidebar'),
            () => { this.setDesktopSidebar(true); }, 34)
        }
        .width('100%').height(42).padding({ left: 6 }).margin({ bottom: 10 })
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 10 }) {
            Image($r('app.media.native_new_chat')).width(17).height(17)
              .colorFilter(nativeIconTint($r('app.color.native_chat_blue_text')))
            Text(this.label('开启新对话', 'New chat')).fontSize(this.appFontSize(14)).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.native_chat_blue_text'))
          }
        }
        .width('100%').height(40).margin({ bottom: 8 }).backgroundColor($r('app.color.native_chat_selected'))
        .onClick(() => { this.activate(null); })
      }
      if (this.selecting) {
        Row() {
          Button(this.label('取消', "Cancel"), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14)).onClick(() => { this.resetSelection(); })
          Text(this.label(`已选择 ${this.selectedIds.length} 项`, `${this.selectedIds.length} selected`))
            .fontSize(this.appFontSize(15)).fontWeight(FontWeight.Medium).layoutWeight(1)
            .textAlign(TextAlign.Center).fontColor($r('app.color.native_chat_primary'))
          Button(this.label('全选', "Select all"), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14)).onClick(() => {
            this.selectedIds = this.filteredSidebarGroups.flatMap<string>((group: NativeConversationGroup): string[] =>
              group.sessions.map<string>((session: NativeConversation): string => session.id));
          })
        }
        .width('100%').height(44)
      } else {
        Row({ space: 8 }) {
          Image($r('app.media.native_search')).height(16).width(16).colorFilter(nativeIconTint($r('app.color.native_chat_secondary')))
          TextInput({ text: this.searchText, placeholder: this.label('搜索对话内容...', "Search chats…") }).fontSize(this.appFontSize(15)).height(44).layoutWeight(1)
            .backgroundColor(Color.Transparent).padding(0).cancelButton({ style: CancelButtonStyle.INPUT })
            .onChange((value: string) => { this.changeSidebarQuery(value); })
        }
        .width('100%').borderRadius(14).padding({ left: 14, right: 12 }).backgroundColor($r('app.color.native_chat_field'))
      }
      List({ space: 2, scroller: this.sidebarScroller }) {
        if (this.history.sessions.length === 0) {
          ListItem() {
            Column({ space: 8 }) {
              Text(this.label('暂无对话', "No chats yet")).fontSize(this.appFontSize(15)).fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary'))
              Text(this.label('你与 Nuwa 的对话\n将展示在这里', 'Your chats with Nuwa will appear here'))
                .textAlign(TextAlign.Center).fontSize(this.appFontSize(13))
                .fontColor($r('app.color.native_chat_secondary'))
              Button(this.label('开启新对话', "New chat"), { buttonStyle: ButtonStyleMode.TEXTUAL })
                .fontSize(this.appFontSize(14)).onClick(() => { this.activate(null); })
            }
            .width('100%').padding({ top: 28 })
          }
        } else if (!this.sidebarRows.length) {
          ListItem() {
            Text(this.label('未找到匹配的对话', "No matching chats")).fontSize(this.appFontSize(14)).fontColor($r('app.color.native_chat_secondary')).padding(14)
          }
        }
        ForEach(this.sidebarSections, (section: NativeSidebarSection) => {
          ListItemGroup({ header: this.sidebarGroupHeader(section.key, section.label), space: 2 }) {
            ForEach(this.sidebarSectionRows(section.key), (row: NativeSidebarRow) => {
              ListItem() {
                if (row.session) {
                  this.drawerItem(row.session)
                }
              }
            }, (row: NativeSidebarRow): string => row.key)
          }
        }, (section: NativeSidebarSection): string => section.key)
      }
      .layoutWeight(1).width('100%').padding({ top: 8 }).scrollBar(BarState.Off)
      .sticky(StickyStyle.Header)
      .onAreaChange((_old: Area, area: Area) => {
        if (!desktop && !this.sidebarDrawerReady && Number(area.height) > 0) {
          this.sidebarDrawerReady = true;
          this.restoreSidebarDrawerPosition();
        }
      })
      .onDisAppear(() => {
        if (!desktop) {
          this.sidebarDrawerReady = false;
          this.sidebarDrawerFirst = undefined;
        }
      })
      .onScroll((offset: number) => {
        if (!desktop && offset !== 0) this.rememberSidebarDrawerPosition();
      })
      .onScrollVisibleContentChange((first: VisibleListContentInfo, last: VisibleListContentInfo) => {
        if (!desktop) this.sidebarDrawerFirst = first;
        this.maybeLoadSidebarPage(visibleSidebarRowIndex(this.sidebarSections, last.index, last.itemIndexInGroup));
      })
      if (this.selecting) {
        Row() {
          Button(this.allPinned() ? this.label('取消置顶', "Unpin") : this.label('置顶', "Pin"), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14))
            .enabled(this.canPinSidebarSelection()).layoutWeight(1)
            .onClick(() => { this.pinSidebarSelection(); })
          Button(this.label('删除', "Delete"), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .fontSize(this.appFontSize(14)).fontColor($r('app.color.native_chat_error'))
            .enabled(this.selectedIds.length > 0).layoutWeight(1)
            .onClick(() => { this.deleteSessions(this.selectedIds, 'batch'); })
        }
        .height(52).width('100%')
      } else {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Image($r('app.media.native_welcome_logo')).width(31).height(31).borderRadius(10).draggable(false)
            Text(this.accountToken() ? this.account?.label ?? this.label('DeepSeek API 账号', "DeepSeek API account") : this.label('设置', "Settings"))
              .fontSize(this.appFontSize(15)).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('app.color.native_chat_primary'))
            if (this.balance) {
              Text(this.balance.formatted).fontSize(this.appFontSize(12)).fontColor($r('app.color.native_chat_blue_text'))
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
  private messagePager(earlier: boolean) {
    Row({ space: 8 }) {
      Button(earlier ? this.label(`加载更早消息（还有 ${this.earlierCount} 条）`,
        `Load earlier messages (${this.earlierCount} more)`) :
        this.label(`加载后续消息（还有 ${this.laterCount} 条）`, `Load later messages (${this.laterCount} more)`),
        { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
        .height(32).fontSize(this.appFontSize(12)).border({ width: 1, color: $r('app.color.native_chat_stroke') })
        .fontColor($r('app.color.native_chat_secondary')).onClick(() => { this.loadMoreMessages(earlier); })
      if (!earlier) {
        Button(this.label('回到底部', 'Back to bottom'), { type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.TEXTUAL })
          .height(32).fontSize(this.appFontSize(12)).border({ width: 1, color: $r('app.color.native_chat_blue') })
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
  private unreadableChat(id: string) {
    Column({ space: 8 }) {
      if (this.retryingConversationIds.includes(id)) {
        LoadingProgress().width(28).height(28).color($r('app.color.native_chat_blue'))
          .accessibilityText(this.label('正在读取对话', 'Loading chat'))
      } else {
        Text(this.label('对话加载失败，请重试', 'Unable to load this chat. Please try again.'))
          .fontColor($r('app.color.native_chat_secondary'))
        Button(this.label('重试', 'Retry')).id('nuwa-retry-chat').fontSize(this.appFontSize(14))
          .enabled(this.canModifyHistory() && !this.deletingSessions).onClick(() => { void this.retryConversation(id); })
      }
    }
    .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  private chatPage() {
    Column() {
      if (this.wide() && (this.history.activeId !== null || this.settings.desktopSidebarCollapsed)) {
        this.desktopHeader()
      } else if (!this.wide() && this.viewportHeight > 180) {
        this.header()
      }
      if (this.loaded && (this.historySaveError || this.migrationReloadFailed)) {
        Row({ space: 12 }) {
          Text(this.migrationReloadFailed ? this.label('无法读取导入的对话，请重试', 'Unable to load imported chats. Please retry.') :
            this.label('对话或附件尚未保存到本机，关闭页面可能丢失，请重试',
              'Chats or attachments have not been saved locally. Closing this page may lose them. Please retry.'))
            .fontSize(this.appFontSize(14)).fontColor($r('app.color.native_chat_primary')).layoutWeight(1)
          Button(this.label('重试', 'Retry'), { type: ButtonType.Capsule })
            .fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_primary')).height(30)
            .backgroundColor($r('app.color.native_chat_surface'))
            .border({ width: 1, color: $r('app.color.native_chat_stroke') })
            .enabled(!this.backupBusy && !this.reloadingMigratedHistory).onClick(() => { this.retryHistorySave(); })
        }
        .width('100%').constraintSize({ maxWidth: 680 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      if (!this.loaded) {
        Column({ space: 8 }) {
          if (this.status) {
            Text(this.status).fontColor($r('app.color.native_chat_secondary'))
            Button(this.label('重试', "Retry")).fontSize(this.appFontSize(14)).onClick(() => { void this.load(); })
          } else {
            LoadingProgress().width(28).height(28).color($r('app.color.native_chat_blue'))
          }
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.session()?.unreadable) {
        this.unreadableChat(this.history.activeId ?? '')
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
                NativeAssistantMessageRow({
                  row,
                  content: (message: () => NativeConversationMessage, index: number): void => {
                    this.assistantMessage(message, index)
                  },
                })
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
        Text(this.status).fontSize(this.appFontSize(13)).fontColor($r('app.color.native_chat_error'))
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }
      if (!this.centeredComposer() && !this.session()?.unreadable) {
        this.composerContainer()
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
    .bindSheet($$this.settingsVisible, this.settingsPage(), this.settingsSheetOptions())
  }

  @Builder
  private sourcesSheet() {
    NativeSourcesPanel({
      sources: this.panelSources, title: this.label('搜索结果', 'Search results'), locale: this.settings.locale,
      fontScale: this.appFontScale(),
      onClose: () => { this.closeSources(); },
    })
  }

  @Builder
  private uploadQuotaToast() {
    Column() {
      Row({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Text('!').lineHeight(13).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.native_chat_error'))
        }
        .width(16).height(16).borderRadius(8).margin({ top: 3 })
        .border({ width: 1.3, color: $r('app.color.native_chat_error') })
        .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
        Text() {
          Span(this.uploadQuotaText)
          Span(this.label('删除文件', 'Delete files')).fontColor('#679EFE').onClick(() => {
            this.clearUploadQuota();
            void this.openLink(DELETE_FILE_DOCS_URL);
          })
        }
        .fontSize(this.appFontSize(14)).lineHeight(22).fontColor('#F5F5F5').layoutWeight(1)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .alignItems(VerticalAlign.Top).width('100%').constraintSize({ maxWidth: 480 })
      .padding({ top: 12, bottom: 12, left: 18, right: 18 }).borderRadius(12)
      .backgroundColor($r('app.color.native_chat_toast'))
      .shadow({ radius: 16, offsetY: 4, color: '#1A000000' })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').padding({ top: 40, left: 14, right: 14 })
    .alignItems(HorizontalAlign.Center).hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private attachmentDragMask() {
    Column({ space: 16 }) {
      Image($r('app.media.native_drag_upload')).width(115).height(84).draggable(false)
      Text(this.label('文件拖动到此处即可上传', 'Drop files here to upload'))
        .fontSize(this.appFontSize(20)).lineHeight(28).fontColor($r('app.color.native_chat_primary')).textAlign(TextAlign.Center)
      Text(this.label('最多 50 个，每个 64MB', 'Up to 50 files, 64 MB each'))
        .fontSize(this.appFontSize(14)).lineHeight(22).fontColor($r('app.color.native_chat_caption')).textAlign(TextAlign.Center)
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .padding({ left: 40, right: 40, bottom: this.viewportWidth * 0.03 })
    .backgroundColor($r('app.color.native_chat_drag_mask')).backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private historyDragMask() {
    Column() {
      Text(this.label('单独拖入一个 DeepSeek ZIP 可增量导入历史；混合或多个文件按附件校验',
        'Drop a single DeepSeek ZIP alone to import history; mixed or multiple drops use attachment validation'))
        .fontSize(this.appFontSize(16)).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center)
        .fontColor($r('app.color.native_chat_primary'))
        .padding({ left: 36, right: 36, top: 24, bottom: 24 })
        .backgroundColor($r('app.color.native_chat_surface'))
        .border({ width: 2, style: BorderStyle.Dashed, color: $r('app.color.native_chat_blue') }).borderRadius(16)
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding({ left: 16, right: 16 })
    .backgroundColor('#73000000').backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .hitTestBehavior(HitTestMode.None)
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
              compact: this.compact(), busy: this.authorizing || this.signingOut, view: this.$onboardingView,
              fontScale: this.fontPreferenceScale(),
              initialUrl: this.settings.baseUrl, initialModel: this.settings.model, initialProtocol: this.settings.protocol,
              onAccount: () => { void this.startAuthorization(); },
              onConnect: (credential: NativeApiCredential): Promise<void> => this.connectKey(credential),
              onHelp: () => { void this.openLink(DEEPSEEK_DOCS_URL); },
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
        if (this.wide() && this.sourcePanelEntry) {
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
      if (!this.wide() && this.sourcePanelEntry) {
        Column() { this.sourcesSheet() }
        .width('100%').height('100%').backgroundColor($r('app.color.native_chat_bg'))
      }
      if (this.authorizing) {
        this.authorizationPage()
      }
      if (this.imagePreview) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(this.imagePreview).width('100%').height('100%').objectFit(ImageFit.Contain).autoResize(true)
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
      if (this.migrationPromptVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {
            if (!this.backupBusy) this.dismissMigrationPrompt();
          })
          NativeMigrationPrompt({
            locale: this.settings.locale, compact: this.compact() || this.viewportHeight < 500,
            fontScale: this.appFontScale(), importing: this.backupBusy,
            onMigrate: () => { this.dismissMigrationPrompt(false); void this.openHistoryMigration(); },
            onImport: () => { void this.importChatHistory(true); },
            onDismiss: () => { this.dismissMigrationPrompt(); },
          })
        }
        .width('100%').height('100%')
      }
      if (this.uploadQuotaText) {
        this.uploadQuotaToast()
      }
      if (this.fileDropHint && this.canReceiveFileDrop()) {
        if (this.fileDropHint === 'history') {
          this.historyDragMask()
        } else {
          this.attachmentDragMask()
        }
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.native_chat_sidebar')).clip(true)
    .allowDrop(NATIVE_ATTACHMENT_DROP_TYPES)
    .onDragEnter((event: DragEvent) => { this.trackAttachmentDrag(event); })
    .onDragMove((event: DragEvent) => { this.trackAttachmentDrag(event); })
    .onDragLeave(() => { this.fileDropHint = null; })
    .onDrop((event: DragEvent) => { this.dropAttachments(event); })
    .onAreaChange((_old: Area, area: Area): void => {
      const width = Number(area.width);
      const height = Number(area.height);
      const resized = width !== this.viewportWidth || height !== this.viewportHeight;
      this.viewportWidth = width;
      this.viewportHeight = height;
      if (resized && this.updateNotice) this.presentUpdate(this.updateNotice.update);
      if (resized && this.deleteNotice) {
        this.refreshDeleteNotice(this.deleteNotice.mode, this.deleteNotice.count, this.deleteNotice.busy);
      }
      if (resized && this.migrationChoice) this.resizeMigrationChoice();
      if (this.wide() && (this.drawerOpen || this.drawerDrag !== 0)) {
        this.drawerOpen = false;
        this.drawerDrag = 0;
      }
    })
    // Leave horizontal drags on scrollable message content to the child first.
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 14 })
        .onActionStart((event: GestureEvent) => { this.touchStart = event.fingerList[0]?.globalX ?? this.viewportWidth; })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.wide() && this.authenticated() && !this.settingsVisible && !this.renamingId && !this.authorizing &&
            !this.imagePreview && !this.shareImportVisible && !this.sourcePanelEntry && !this.migrationPromptVisible &&
            !this.migrationChoice &&
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
