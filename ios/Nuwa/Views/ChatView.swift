import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chatStore: ChatStore
    let draftStore: DraftStore
    let listStore: SessionListStore
    @ObservedObject var settings: SettingsStore
    let speech: SpeechService

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drawerOpen = false
    @SceneStorage("chat.sidebarVisible") private var sidebarVisible = true

    @State private var showSettings = false
    @State private var showMigrationWeb = false
    @State private var showZipImporter = false
    @State private var showAttachmentFilePicker = false

    @State private var editingMessageId: UUID?
    @State private var editDraftText = ""
    @State private var searchPanelResults: [WebSearchResultItem]?
    @State private var previewImage: UIImage?

    @State private var scrollToTopToken = 0
    @State private var isAtBottom = true
    @State private var disclosureOverrides: [UUID: Bool] = [:]
    @State private var disclosureAnchorID: UUID?
    @State private var disclosureAnchorToken = 0
    @State private var headerHeight: CGFloat = 58
    @State private var composerHeight: CGFloat = 114
    @State private var streamingCoordinator = TimelineStreamingCoordinator()

    private var usesSystemSafeAreaBars: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!

    var body: some View {
        ZStack {
            Color.nuwaSidebarFill.ignoresSafeArea()

            GeometryReader { geo in
                let wide = geo.size.width >= 680
                let drawerWidth = wide ? min(geo.size.width * 0.31, 300) : min(geo.size.width * 0.82, 310)
                let showSidebar = wide ? sidebarVisible : drawerOpen
                ZStack(alignment: .leading) {
                    ChatDrawerLayout(
                        size: geo.size,
                        drawerWidth: drawerWidth,
                        wide: wide,
                        wideOpen: sidebarVisible,
                        compactOpen: $drawerOpen,
                        gestureEnabled: !settings.showMigrationPrompt && !showSettings &&
                            editingMessageId == nil && previewImage == nil,
                        dismissKeyboard: dismissKeyboard
                    ) {
                        SessionDrawerView(
                            listStore: listStore,
                            settings: settings,
                            activeSessionId: chatStore.activeSessionId,
                            isOpen: showSidebar,
                            onSelectSession: { chatStore.selectSession($0) },
                            onCreateNewSession: { chatStore.createNewSession(silentIfAlreadyNew: true) },
                            onTogglePin: { chatStore.togglePin($0) },
                            onSetSessionsPinned: { chatStore.setSessionsPinned($0, pinned: $1) },
                            onRenameSession: { chatStore.renameSession($0, title: $1) },
                            onDeleteSession: { chatStore.deleteSession($0) },
                            onDeleteSessions: { chatStore.deleteSessions($0) },
                            onSearch: { await chatStore.matchingSessionIDs(query: $0) },
                            onClose: { if !wide { closeDrawer() } },
                            onOpenSettings: { showSettings = true }
                        )
                        .task {
                            if wide { await settings.refreshBalance() }
                        }
                    } surface: {
                        mainSurface(sidebarShown: showSidebar, drawerModal: !wide && drawerOpen) {
                            if wide {
                                sidebarVisible.toggle()
                            } else if drawerOpen {
                                closeDrawer()
                            } else {
                                dismissKeyboard()
                                drawerOpen = true
                            }
                        }
                    }

                    if settings.showMigrationPrompt {
                        MigrationPromptModalView(
                            settings: settings,
                            chatStore: chatStore,
                            onStartOneClickMigration: {
                                settings.hasUsedOneClickMigration = true
                                showMigrationWeb = true
                            },
                            onStartZipImport: { showZipImporter = true }
                        )
                        .transition(.opacity)
                        .zIndex(50)
                    }

                    if let previewImage {
                        ImageLightboxOverlay(image: previewImage) {
                            withAnimation(.easeOut(duration: 0.16)) {
                                self.previewImage = nil
                            }
                        }
                        .transition(.opacity)
                        .zIndex(60)
                    }
                }
                .onChange(of: wide) { _, _ in closeDrawer() }
            }
        }
        .task(id: chatStore.historyLoaded) {
            guard chatStore.historyLoaded else { return }
            chatStore.checkPendingMigration()
            chatStore.maybeAutoBackupToIcloud(settings: settings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chatStore.checkPendingMigration()
                chatStore.maybeAutoBackupToIcloud(settings: settings)
            } else if phase == .background {
                chatStore.flushPendingSave()
            }
        }
        .onChange(of: chatStore.activeSessionId) { _, _ in
            speech.stopSpeaking()
            editingMessageId = nil
            isAtBottom = true
            disclosureOverrides.removeAll()
            disclosureAnchorID = nil
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, chatStore: chatStore)
        }
        .sheet(isPresented: $showMigrationWeb) {
            DeepSeekMigrationSheet { filePath, _ in
                showMigrationWeb = false
                if let filePath {
                    chatStore.importFromFilePath(filePath)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { searchPanelResults != nil },
            set: { if !$0 { searchPanelResults = nil } }
        )) {
            if let results = searchPanelResults {
                SearchSourcesPanel(items: results, locale: settings.locale) {
                    searchPanelResults = nil
                }
                .presentationDragIndicator(.visible)
                .padding(.top, 12)
            }
        }
        .fileImporter(
            isPresented: $showZipImporter,
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        let count = try await chatStore.importFromFile(url)
                        chatStore.showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
                    } catch {
                        chatStore.showToast("导入失败：\(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $showAttachmentFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let targetSession = chatStore.activeSessionId
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    let name = url.lastPathComponent
                    Task.detached(priority: .userInitiated) {
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) {
                            await MainActor.run {
                                draftStore.addFile(
                                    data: data,
                                    fileName: name,
                                    isImage: AttachmentStore.isImageName(name),
                                    for: targetSession,
                                    settings: settings,
                                    onToast: { chatStore.showToast($0) }
                                )
                            }
                        }
                    }
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private func mainSurface(sidebarShown: Bool, drawerModal: Bool, onToggleSidebar: @escaping () -> Void) -> some View {
        let session = chatStore.activeSession
        let timeline = chatStore.activeTimeline
        let hasMessages = timeline?.messages.isEmpty == false
        let allowComposerPress = !drawerModal && !settings.showMigrationPrompt && previewImage == nil && !showSettings

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            mainContentLayer(
                session: session,
                timeline: timeline,
                hasMessages: hasMessages,
                drawerModal: drawerModal,
                onToggleSidebar: onToggleSidebar
            )
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .overlay(alignment: .top) {
                if let toast = chatStore.toastMessage {
                    toastPill(toast)
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                topHeaderBar(
                    hasMessages: hasMessages,
                    sessionTitle: session?.title ?? "",
                    sidebarShown: sidebarShown,
                    drawerModal: drawerModal,
                    onToggleSidebar: onToggleSidebar
                )
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                bottomComposerBar(
                    drawerModal: drawerModal,
                    allowComposerPress: allowComposerPress,
                    onToggleSidebar: onToggleSidebar
                )
            }
        } else {
            legacyMainSurface(
                session: session,
                timeline: timeline,
                hasMessages: hasMessages,
                sidebarShown: sidebarShown,
                drawerModal: drawerModal,
                allowComposerPress: allowComposerPress,
                onToggleSidebar: onToggleSidebar
            )
        }
        #else
        legacyMainSurface(
            session: session,
            timeline: timeline,
            hasMessages: hasMessages,
            sidebarShown: sidebarShown,
            drawerModal: drawerModal,
            allowComposerPress: allowComposerPress,
            onToggleSidebar: onToggleSidebar
        )
        #endif
    }

    private func mainContentLayer(
        session: ChatSession?,
        timeline: ChatStore.ActiveTimeline?,
        hasMessages: Bool,
        drawerModal: Bool,
        onToggleSidebar: @escaping () -> Void
    ) -> some View {
        Group {
            if chatStore.historyLoadFailed {
                ContentUnavailableView(
                    settings.locale == .enUS ? "Couldn’t load conversations" : "无法读取对话记录",
                    systemImage: "exclamationmark.triangle",
                    description: Text(settings.locale == .enUS
                        ? "Your data hasn’t been changed. Reopen Nuwa to try again."
                        : "数据未被修改，请重新打开 Nuwa 后重试。")
                )
                .padding(.top, usesSystemSafeAreaBars ? 0 : headerHeight)
                .padding(.bottom, usesSystemSafeAreaBars ? 0 : composerHeight)
            } else if !chatStore.historyLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session, let timeline, hasMessages {
                messageList(timeline)
                    .id(session.id)
            } else {
                welcomeView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!drawerModal)
        .accessibilityHidden(drawerModal)
        .overlay {
            if drawerModal && usesSystemSafeAreaBars {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggleSidebar)
                    .accessibilityHidden(true)
            }
        }
    }

    private func topHeaderBar(
        hasMessages: Bool,
        sessionTitle: String,
        sidebarShown: Bool,
        drawerModal: Bool,
        onToggleSidebar: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if chatStore.importingHistory {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                    Text("正在导入并合并历史对话，请稍候...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.nuwaBrand)
            }

            ChatHeaderView(
                speech: speech,
                settings: settings,
                hasMessages: hasMessages,
                sessionTitle: sessionTitle,
                sidebarShown: sidebarShown,
                drawerModal: drawerModal,
                onOpenDrawer: onToggleSidebar,
                onScrollToTop: { scrollToTopToken += 1 },
                onCreateNewSession: { chatStore.createNewSession() },
                onToast: { chatStore.showToast($0) }
            )
        }
    }

    private func bottomComposerBar(
        drawerModal: Bool,
        allowComposerPress: Bool,
        onToggleSidebar: @escaping () -> Void
    ) -> some View {
        ChatComposerContainer(
            draftStore: draftStore,
            settings: settings,
            speech: speech,
            sessionId: chatStore.activeSessionId,
            isGenerating: chatStore.isGenerating,
            isImporting: chatStore.importingHistory || !chatStore.historyLoaded,
            allowPressEffect: allowComposerPress,
            onSend: sendMessage,
            onStop: {
                speech.stopSpeaking()
                chatStore.stopGenerating()
            },
            onPickFiles: { showAttachmentFilePicker = true },
            onToast: { chatStore.showToast($0) }
        )
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(!drawerModal)
        .accessibilityHidden(drawerModal)
        .overlay {
            if drawerModal && usesSystemSafeAreaBars {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea(.container, edges: .bottom)
                    .onTapGesture(perform: onToggleSidebar)
                    .accessibilityHidden(true)
            }
        }
    }

    private func toastPill(_ toast: String) -> some View {
        Text(toast)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.nuwaLabelPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .nuwaGlass(in: Capsule())
            .padding(.top, 8)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(10)
    }

    private func legacyMainSurface(
        session: ChatSession?,
        timeline: ChatStore.ActiveTimeline?,
        hasMessages: Bool,
        sidebarShown: Bool,
        drawerModal: Bool,
        allowComposerPress: Bool,
        onToggleSidebar: @escaping () -> Void
    ) -> some View {
        ZStack {
            mainContentLayer(
                session: session,
                timeline: timeline,
                hasMessages: hasMessages,
                drawerModal: drawerModal,
                onToggleSidebar: onToggleSidebar
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomComposerBar(
                    drawerModal: drawerModal,
                    allowComposerPress: allowComposerPress,
                    onToggleSidebar: onToggleSidebar
                )
                .background(heightReader { height in
                    if height > 0, abs(composerHeight - height) > 0.5 {
                        composerHeight = height
                    }
                })
                .background {
                    if hasMessages {
                        ProgressiveEdgeBlur(edge: .bottom, baseColor: .nuwaChatBackground)
                            .padding(.top, -36)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                }
            }

            if drawerModal {
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.top, headerHeight)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .onTapGesture(perform: onToggleSidebar)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                topHeaderBar(
                    hasMessages: hasMessages,
                    sessionTitle: session?.title ?? "",
                    sidebarShown: sidebarShown,
                    drawerModal: drawerModal,
                    onToggleSidebar: onToggleSidebar
                )
                .background(heightReader { height in
                    if height > 0, abs(headerHeight - height) > 0.5 {
                        headerHeight = height
                    }
                })
                .background {
                    if hasMessages {
                        ProgressiveEdgeBlur(edge: .top, baseColor: .nuwaChatBackground)
                            .padding(.bottom, -32)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }

                if let toast = chatStore.toastMessage {
                    toastPill(toast)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func heightReader(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, newHeight in
                    onChange(newHeight)
                }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("NuwaLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 4)

            Text(L10n.t("welcome", locale: settings.locale))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.nuwaLabelPrimary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, usesSystemSafeAreaBars ? 0 : headerHeight)
        .padding(.bottom, usesSystemSafeAreaBars ? 0 : composerHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func messageList(_ timeline: ChatStore.ActiveTimeline) -> some View {
        let messages = timeline.messages
        let versions = timeline.versions
        let last = messages.last
        return ChatTimeline(
            isAtBottom: $isAtBottom,
            messages: messages,
            versions: versions,
            appearance: ChatTimelineAppearance(
                fontSize: settings.chatFontSize,
                locale: settings.locale,
                isGenerating: chatStore.isGenerating,
                editingMessageID: editingMessageId,
                editDraft: editDraftText,
                disclosureOverrides: disclosureOverrides
            ),
            topInset: headerHeight,
            bottomInset: composerHeight,
            usesSystemSafeAreaBars: usesSystemSafeAreaBars,
            topCommand: scrollToTopToken,
            disclosureAnchorID: disclosureAnchorID,
            disclosureAnchorToken: disclosureAnchorToken,
            streamingCoordinator: streamingCoordinator,
            animateBoundaryJumps: messages.count <= 240,
            latestLabel: settings.locale == .enUS ? "Scroll to latest" : "跳到最新消息"
        ) { message in
            Group {
                if message.id == last?.id && message.isStreaming && chatStore.isGenerating {
                    LiveReplyRow(
                        store: chatStore.liveReply,
                        fallback: message,
                        onUpdate: { streamingCoordinator.onLiveRowUpdated?() }
                    ) { reply in
                        messageRow(message: reply, versionInfo: versions[reply.id], isLast: true)
                    }
                } else {
                    messageRow(message: message, versionInfo: versions[message.id], isLast: message.id == last?.id)
                }
            }
            .frame(maxWidth: 748)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, versionInfo: MessageVersionInfo?, isLast: Bool) -> some View {
        let versionInfo = versionInfo ?? MessageVersionInfo(ids: [message.id], index: 0)

        if message.role == .user {
            let isEditing = editingMessageId == message.id
            VStack(alignment: .trailing, spacing: 6) {
                if !message.files.isEmpty {
                    userFilesStrip(message.files)
                }

                if isEditing {
                    VStack(alignment: .trailing, spacing: 10) {
                        TextField("修改提问内容", text: $editDraftText, axis: .vertical)
                            .lineLimit(1...8)
                            .font(.system(size: settings.chatFontSize))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        HStack(spacing: 8) {
                            Button {
                                editingMessageId = nil
                            } label: {
                                Text(L10n.t("cancel", locale: settings.locale))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.nuwaLabelSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .nuwaPillSurface()
                            }
                            .buttonStyle(NuwaTactileButtonStyle())

                            let canSaveEdit = !chatStore.isGenerating && (!editDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.files.isEmpty)
                            Button {
                                speech.stopSpeaking()
                                chatStore.editUserMessage(messageId: message.id, newContent: editDraftText, settings: settings)
                                editingMessageId = nil
                            } label: {
                                Text("发送")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(canSaveEdit ? Color.nuwaBrand : Color.nuwaBrand.opacity(0.4), in: Capsule())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                            .disabled(!canSaveEdit)
                        }
                    }
                    .padding(12)
                    .background(Color.nuwaDrawerCardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75))
                } else {
                    if !message.content.isEmpty {
                        HStack {
                            Spacer(minLength: 68)
                            Text(message.content)
                                .font(.system(size: settings.chatFontSize))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    Color.nuwaBubbleFill,
                                    in: UnevenRoundedRectangle(
                                        topLeadingRadius: 22, bottomLeadingRadius: 22,
                                        bottomTrailingRadius: 6, topTrailingRadius: 22
                                    )
                                )
                        }
                    }

                    HStack(spacing: 8) {
                        BranchSwitcherView(versionInfo: versionInfo) { targetId in
                            chatStore.selectVersion(messageId: targetId)
                        }

                        if !message.content.isEmpty {
                            Button {
                                UIPasteboard.general.string = message.content
                                chatStore.showToast(L10n.t("copied", locale: settings.locale))
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }

                        if !chatStore.isGenerating {
                            Button {
                                editDraftText = message.content
                                editingMessageId = message.id
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }
                }
            }
        } else {
            let refused = message.stopReason == "refusal"
            let reply = ReplyPresentation(message)
            let displayText = reply.answer

            VStack(alignment: .leading, spacing: 10) {
                if reply.hasDisclosure || !reply.steps.isEmpty {
                    ReplyProcessView(
                        reply: reply,
                        fontSize: settings.chatFontSize,
                        locale: settings.locale,
                        expandedOverride: disclosureOverrides[message.id],
                        onToggleExpanded: { next in
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                disclosureAnchorID = message.id
                                disclosureAnchorToken += 1
                                disclosureOverrides[message.id] = next
                            }
                        },
                        showResults: { searchPanelResults = $0 },
                        onCopyCode: { _ in chatStore.showToast(L10n.t("copied", locale: settings.locale)) }
                    )
                    .id(message.id)
                }

                if !displayText.isEmpty {
                    MarkdownMessageView(
                        text: displayText,
                        citations: reply.citations,
                        fontSize: settings.chatFontSize,
                        isStreaming: message.isStreaming,
                        onCopyCode: { _ in chatStore.showToast(L10n.t("copied", locale: settings.locale)) }
                    )
                    .equatable()
                } else if message.isStreaming && !reply.hasDisclosure && reply.steps.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.t("thinkingNow", locale: settings.locale))
                            .font(.subheadline)
                            .foregroundStyle(Color.nuwaLabelSecondary)
                    }
                }

                if let error = message.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        HStack(spacing: 12) {
                            if error.contains("API Key") || error.contains("401") {
                                Button("更换 API Key") { showSettings = true }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.nuwaBrandText)
                            }
                            if error.contains("余额不足") || error.contains("402") {
                                Button("前往充值") { openURL(topUpURL) }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.nuwaBrandText)
                            }
                            if !chatStore.isGenerating {
                                Button("重试") {
                                    chatStore.regenerateReply(messageId: message.id, settings: settings)
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.nuwaBrandText)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !message.isStreaming {
                    if !refused && !reply.results.isEmpty {
                        SearchSourcesButton(items: reply.results, locale: settings.locale) {
                            searchPanelResults = reply.results
                        }
                        Text(settings.locale == .enUS
                            ? "AI-generated content. Verify important information."
                            : "本回答由 AI 生成，内容仅供参考，请仔细甄别")
                            .font(.footnote.italic())
                            .foregroundStyle(Color.nuwaLabelTertiary)
                    }

                    HStack(spacing: 6) {
                        if !displayText.isEmpty {
                            Button {
                                UIPasteboard.general.string = displayText
                                chatStore.showToast(L10n.t("copied", locale: settings.locale))
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())

                            if !refused {
                                MessageReadAloudButton(
                                    speech: speech,
                                    messageId: message.id,
                                    text: displayText,
                                    settings: settings
                                )
                            }
                        }

                        if isLast && message.canContinueReply {
                            Button {
                                speech.stopSpeaking()
                                chatStore.continueReply(messageId: message.id, settings: settings)
                            } label: {
                                Text(L10n.t("continueGen", locale: settings.locale))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.nuwaBrandText)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .nuwaPillSurface(selected: true)
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }

                        BranchSwitcherView(versionInfo: versionInfo) { targetId in
                            chatStore.selectVersion(messageId: targetId)
                        }

                        Spacer(minLength: 0)

                        if !refused {
                            Button {
                                speech.stopSpeaking()
                                chatStore.regenerateReply(messageId: message.id, settings: settings)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func userFilesStrip(_ files: [FileAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    AttachmentThumbnail(file: file, pointSize: 72) { image in
                        if let thumb = image {
                            Button {
                                Task {
                                    if let full = await Task.detached(priority: .userInitiated, operation: {
                                        AttachmentStore.loadLocalImage(for: file)
                                    }).value {
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                            previewImage = full
                                        }
                                    }
                                }
                            } label: {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: file.isImage ? "photo" : "doc.text.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.nuwaBrandText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.nuwaLabelPrimary)
                                        .lineLimit(1)
                                    Text(AttachmentStore.formatByteSize(file.size))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.nuwaLabelTertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.nuwaBubbleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func closeDrawer() {
        drawerOpen = false
    }

    private func sendMessage() {
        guard settings.hasActiveCredential else {
            showSettings = true
            return
        }
        if speech.isRecording {
            speech.finishRecording()
        }
        speech.stopSpeaking()
        chatStore.sendCurrentDraft(settings: settings)
    }
}

private struct ChatDrawerLayout<Sidebar: View, Surface: View>: View {
    let size: CGSize
    let drawerWidth: CGFloat
    let wide: Bool
    let wideOpen: Bool
    @Binding var compactOpen: Bool
    let gestureEnabled: Bool
    let dismissKeyboard: () -> Void
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let surface: Surface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var legacyTracking = false
    @State private var legacyRejectedDrag = false
    @State private var dragOffset: CGFloat?

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90)
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            layers.gesture(
                ChatDrawerPan(
                    enabled: !wide && gestureEnabled,
                    canBegin: { canBeginDrag(at: $0, moving: $1) },
                    onChange: updateDrag,
                    onEnd: finishDrag,
                    onCancel: cancelDrag
                )
            )
        } else {
            layers
                .simultaneousGesture(legacyPan, including: wide || !gestureEnabled ? .none : .all)
                .onChange(of: legacyTracking) { _, active in
                    guard !active else { return }
                    legacyRejectedDrag = false
                    cancelDrag()
                }
        }
    }

    private var layers: some View {
        let open = wide ? wideOpen : compactOpen
        let inset = wide && open ? drawerWidth : 0
        let surfaceWidth = max(0, size.width - inset)
        let offset = wide ? inset : dragOffset ?? (compactOpen ? drawerWidth : 0)

        return ZStack(alignment: .leading) {
            if !wide || open {
                sidebar
                    .frame(width: drawerWidth)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }

            surface
                .frame(width: surfaceWidth, height: size.height)
                .background(Color.nuwaChatBackground.ignoresSafeArea(.container, edges: .vertical))
                .geometryGroup()
                .position(x: offset + surfaceWidth / 2, y: size.height / 2)
                .animation(wide || dragOffset != nil ? nil : spring, value: compactOpen)
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: wide) { _, _ in dragOffset = nil }
        .onChange(of: gestureEnabled) { _, enabled in
            if !enabled { cancelDrag() }
        }
    }

    private func canBeginDrag(at start: CGPoint, moving direction: CGPoint, edgeOnly: Bool = false) -> Bool {
        guard !wide, gestureEnabled, drawerWidth > 0,
              abs(direction.x) > abs(direction.y) * 1.35 else { return false }
        if compactOpen { return direction.x < 0 }
        return direction.x > 0 && (edgeOnly ? (0..<32).contains(start.x) : start.x >= 12)
    }

    private func updateDrag(_ translation: CGFloat) {
        let start = compactOpen ? drawerWidth : 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = min(drawerWidth, max(0, start + translation))
        }
    }

    private func finishDrag(_ translation: CGFloat, _ predictedTranslation: CGFloat) {
        guard dragOffset != nil, drawerWidth > 0 else { return }
        let start = compactOpen ? 1.0 : 0
        let current = start + translation / drawerWidth
        let predicted = start + predictedTranslation / drawerWidth
        let open = compactOpen
            ? !(current < 0.72 || (current < 0.86 && predicted < 0.55))
            : current > 0.28 || (current > 0.14 && predicted > 0.45)
        if open && !compactOpen { dismissKeyboard() }
        withAnimation(spring) {
            compactOpen = open
            dragOffset = nil
        }
    }

    private func cancelDrag() {
        guard dragOffset != nil else { return }
        withAnimation(spring) { dragOffset = nil }
    }

    private var legacyPan: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($legacyTracking) { _, active, _ in active = true }
            .onChanged { value in
                guard !legacyRejectedDrag else { return }
                let direction = CGPoint(x: value.translation.width, y: value.translation.height)
                if dragOffset == nil && !canBeginDrag(at: value.startLocation, moving: direction, edgeOnly: true) {
                    legacyRejectedDrag = true
                    return
                }
                updateDrag(direction.x)
            }
            .onEnded { value in
                finishDrag(value.translation.width, value.predictedEndTranslation.width)
            }
    }
}

@available(iOS 18.0, *)
private struct ChatDrawerPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let canBegin: (CGPoint, CGPoint) -> Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void
    let onCancel: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, canBegin: canBegin)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = enabled
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.canBegin = canBegin
        pan.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = context.converter.localTranslation?.x ?? 0
        switch pan.state {
        case .began, .changed:
            onChange(dx)
        case .ended:
            let velocity = context.converter.localVelocity?.x ?? 0
            onEnd(dx, dx + velocity * 0.2)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var canBegin: (CGPoint, CGPoint) -> Bool

        init(converter: CoordinateSpaceConverter, canBegin: @escaping (CGPoint, CGPoint) -> Bool) {
            self.converter = converter
            self.canBegin = canBegin
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let translation = converter.localTranslation else { return false }
            let location = converter.localLocation
            return canBegin(CGPoint(x: location.x - translation.x, y: location.y - translation.y), translation)
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || (current as? UITextView)?.isEditable == true {
                    return false
                }
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                    let horizontalInsets = scroll.adjustedContentInset.left + scroll.adjustedContentInset.right
                    if scroll.alwaysBounceHorizontal ||
                        scroll.contentSize.width + horizontalInsets > scroll.bounds.width + 1 {
                        return false
                    }
                }
                if current === gesture.view { break }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gesture: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGesture: UIGestureRecognizer
        ) -> Bool {
            otherGesture is UIPanGestureRecognizer && otherGesture.view is UIScrollView
        }
    }
}

private struct LiveReplyRow<Content: View>: View {
    @ObservedObject var store: LiveReplyStore
    let fallback: ChatMessage
    let onUpdate: () -> Void
    @ViewBuilder let content: (ChatMessage) -> Content

    var body: some View {
        content(store.message?.id == fallback.id ? store.message ?? fallback : fallback)
            .transaction { $0.animation = nil }
            .onChange(of: store.revision) { _, _ in
                onUpdate()
            }
    }
}
// MARK: - Isolated Floating Liquid Glass Header

private struct ChatHeaderView: View {
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: SettingsStore
    let hasMessages: Bool
    let sessionTitle: String
    let sidebarShown: Bool
    let drawerModal: Bool
    let onOpenDrawer: () -> Void
    let onScrollToTop: () -> Void
    let onCreateNewSession: () -> Void
    let onToast: (String) -> Void


    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenDrawer) {
                VStack(alignment: .leading, spacing: 5.5) {
                    Capsule().frame(width: 16, height: 1.7)
                    Capsule().frame(width: 10, height: 1.7)
                }
                .foregroundStyle(Color.nuwaLabelPrimary)
                .frame(width: 42, height: 42)
                .nuwaGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.locale == .enUS
                ? (sidebarShown ? "Hide sidebar" : "Show sidebar")
                : (sidebarShown ? "隐藏边栏" : "打开边栏"))

            if hasMessages {
                let displayTitle = sessionTitle.isEmpty ? L10n.t("untitledChat", locale: settings.locale) : sessionTitle
                Text(displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onScrollToTop)
                    .accessibilityAction(named: Text(settings.locale == .enUS ? "Scroll to top" : "回到顶部"), onScrollToTop)
                    .allowsHitTesting(!drawerModal)
                    .accessibilityHidden(drawerModal)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 2) {
                Button {
                    if speech.isSpeaking {
                        speech.stopSpeaking()
                        settings.ttsMuted = true
                    } else {
                        settings.ttsMuted.toggle()
                        onToast(settings.ttsMuted ? "已静音朗读" : "已取消朗读静音")
                    }
                } label: {
                    Image(systemName: (speech.isSpeaking || !settings.ttsMuted) ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("朗读开关")

                Button(action: onCreateNewSession) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("开启新对话")
            }
            .padding(.horizontal, 4)
            .frame(height: 42)
            .nuwaGlass(in: Capsule(), interactive: true)
            .allowsHitTesting(!drawerModal)
            .accessibilityHidden(drawerModal)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Isolated Composer Container (Typing & Audio Level NEVER Trigger ChatView Re-renders!)

private struct ChatComposerContainer: View {
    @ObservedObject var draftStore: DraftStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService
    let sessionId: UUID?
    let isGenerating: Bool
    let isImporting: Bool
    let allowPressEffect: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onPickFiles: () -> Void
    let onToast: (String) -> Void

    @State private var voiceDraftPrefix = ""

    private var textBinding: Binding<String> {
        Binding(
            get: { draftStore.draft(for: sessionId).text },
            set: { draftStore.setText($0, for: sessionId) }
        )
    }

    var body: some View {
        let currentDraft = draftStore.draft(for: sessionId)
        ChatComposerView(
            text: textBinding,
            attachments: currentDraft.attachments,
            thinkingEnabled: $settings.thinkingEnabled,
            searchEnabled: $settings.searchEnabled,
            locale: settings.locale,
            canSend: draftStore.canSend(for: sessionId, isBusy: isImporting || isGenerating),
            isGenerating: isGenerating,
            isRecording: speech.isRecording,
            isTranscribing: speech.isTranscribing,
            recordingSeconds: speech.recordingSeconds,
            audioLevel: speech.audioLevel,
            hapticFeedbackEnabled: UIDevice.current.userInterfaceIdiom == .phone && settings.hapticFeedbackEnabled,
            allowPressEffect: allowPressEffect,
            onSend: onSend,
            onStop: onStop,
            onToggleVoice: {
                if !speech.isRecording {
                    voiceDraftPrefix = draftStore.draft(for: sessionId).text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let capturedPrefix = voiceDraftPrefix
                speech.toggleRecording(settings: settings) { transcript in
                    let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    if capturedPrefix.isEmpty {
                        draftStore.setText(clean, for: sessionId)
                    } else {
                        draftStore.setText("\(capturedPrefix) \(clean)", for: sessionId)
                    }
                }
            },
            onCancelVoice: { speech.cancelRecording() },
            onPickPhotos: { items in handlePickedPhotos(items) },
            onPickFiles: onPickFiles,
            onRetryAttachment: { fileId in
                draftStore.retryAttachment(fileId: fileId, for: sessionId, settings: settings, onToast: onToast)
            },
            onRemoveAttachment: { fileId in
                draftStore.removeAttachment(fileId: fileId, for: sessionId)
            }
        )
        .onChange(of: speech.errorMessage) { _, newError in
            if let newError { onToast(newError) }
        }
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        let targetSession = sessionId
        Task {
            for (idx, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "photo_\(Int(Date().timeIntervalSince1970))_\(idx).\(ext)"
                    draftStore.addFile(
                        data: data,
                        fileName: name,
                        isImage: true,
                        for: targetSession,
                        settings: settings,
                        onToast: onToast
                    )
                }
            }
        }
    }
}

// MARK: - Isolated Per-Message ReadAloud Button

private struct MessageReadAloudButton: View {
    @ObservedObject var speech: SpeechService
    let messageId: UUID
    let text: String
    let settings: SettingsStore

    var body: some View {
        let active = speech.speakingMessageId == messageId
        Button {
            speech.toggleSpeak(messageId: messageId, text: text, settings: settings)
        } label: {
            Image(systemName: active ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 16))
                .foregroundStyle(active ? Color.nuwaBrandText : Color.nuwaLabelTertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(NuwaTactileButtonStyle())
    }
}
