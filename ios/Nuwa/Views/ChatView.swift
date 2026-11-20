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
                    ) { visible in
                        SessionDrawerView(
                            listStore: listStore,
                            settings: settings,
                            activeSessionId: chatStore.activeSessionId,
                            isOpen: visible,
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
                        mainSurface(sidebarShown: showSidebar) {
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
                SearchPanelSheet(results: results)
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

    private func mainSurface(sidebarShown: Bool, onToggleSidebar: @escaping () -> Void) -> some View {
        let session = chatStore.activeSession
        let timeline = chatStore.activeTimeline
        let hasMessages = timeline?.messages.isEmpty == false
        return VStack(spacing: 0) {
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
                sessionTitle: session?.title ?? "",
                sidebarShown: sidebarShown,
                onOpenDrawer: onToggleSidebar,
                onScrollToTop: { scrollToTopToken += 1 },
                onCreateNewSession: { chatStore.createNewSession() },
                onToast: { chatStore.showToast($0) }
            )

            ZStack(alignment: .top) {
                if chatStore.historyLoadFailed {
                    ContentUnavailableView(
                        settings.locale == .enUS ? "Couldn’t load conversations" : "无法读取对话记录",
                        systemImage: "exclamationmark.triangle",
                        description: Text(settings.locale == .enUS
                            ? "Your data hasn’t been changed. Reopen Nuwa to try again."
                            : "数据未被修改，请重新打开 Nuwa 后重试。")
                    )
                } else if !chatStore.historyLoaded {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                } else if let session, let timeline, hasMessages {
                    messageList(timeline)
                        .id(session.id)
                } else {
                    welcomeView
                }

                if let toast = chatStore.toastMessage {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .nuwaGlass(in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ChatComposerContainer(
                draftStore: draftStore,
                settings: settings,
                speech: speech,
                sessionId: chatStore.activeSessionId,
                isGenerating: chatStore.isGenerating,
                isImporting: chatStore.importingHistory || !chatStore.historyLoaded,
                onSend: sendMessage,
                onStop: {
                    speech.stopSpeaking()
                    chatStore.stopGenerating()
                },
                onPickFiles: { showAttachmentFilePicker = true },
                onToast: { chatStore.showToast($0) }
            )
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
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
            last: last,
            topCommand: scrollToTopToken,
            animateBoundaryJumps: messages.count <= 240,
            latestLabel: settings.locale == .enUS ? "Scroll to latest" : "跳到最新消息"
        ) { followLatest in
            ForEach(messages) { message in
                Group {
                    if message.id == last?.id && message.isStreaming && chatStore.isGenerating {
                        LiveReplyRow(store: chatStore.liveReply, fallback: message) { reply in
                            messageRow(message: reply, versionInfo: versions[reply.id], isLast: true)
                        } onUpdate: {
                            if isAtBottom { followLatest() }
                        }
                    } else {
                        messageRow(message: message, versionInfo: versions[message.id], isLast: message.id == last?.id)
                    }
                }
                .frame(maxWidth: 748)
                .frame(maxWidth: .infinity)
                .id(ChatScrollTarget.message(message.id))
            }
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
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
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
            let searchResults = message.allSearchResults
            let isActivelySearching = message.isStreaming && message.blocks.contains { block in
                if case .serverToolUse(_, let info) = block {
                    return info.kind.contains("search")
                }
                return false
            } && searchResults.isEmpty

            let allCitations: [TextCitation] = message.blocks.flatMap { block -> [TextCitation] in
                if case .text(_, _, let c, _) = block { return c }
                return []
            }
            let displayThink = refused ? "" : message.fullThinkingContent
            let displayText = message.fullTextContent

            VStack(alignment: .leading, spacing: 10) {
                if !refused && (isActivelySearching || !searchResults.isEmpty) {
                    SearchSummaryPillView(
                        results: searchResults,
                        isSearching: isActivelySearching
                    ) {
                        searchPanelResults = searchResults
                    }
                }

                if !refused {
                    ReplyToolsStatusView(blocks: message.blocks, isStreaming: message.isStreaming)
                }

                if !displayThink.isEmpty {
                    ReasoningDisclosureView(
                        reasoning: displayThink,
                        seconds: message.thinkingSeconds,
                        isStreaming: message.isStreaming && displayText.isEmpty
                    )
                }

                if !displayText.isEmpty {
                    MarkdownMessageView(
                        text: displayText,
                        citations: refused ? [] : allCitations,
                        fontSize: settings.chatFontSize,
                        isStreaming: message.isStreaming,
                        onCopyCode: { _ in chatStore.showToast(L10n.t("copied", locale: settings.locale)) }
                    )
                    .equatable()
                } else if message.isStreaming && displayThink.isEmpty && !isActivelySearching {
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
                    // Lightweight flat native icon buttons (matching original Nuwa IconButton — zero scroll jank!)
                    HStack(spacing: 6) {
                        if !displayText.isEmpty {
                            Button {
                                UIPasteboard.general.string = displayText
                                chatStore.showToast(L10n.t("copied", locale: settings.locale))
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.nuwaLabelSecondary)
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

                        if !refused {
                            Button {
                                speech.stopSpeaking()
                                chatStore.regenerateReply(messageId: message.id, settings: settings)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.nuwaLabelSecondary)
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NuwaTactileButtonStyle())
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
    @ViewBuilder let sidebar: (Bool) -> Sidebar
    @ViewBuilder let surface: Surface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var tracking = false
    @State private var dragProgress: CGFloat?
    @State private var rejectedDrag = false
    @State private var retainDrawer = false

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90)
    }

    var body: some View {
        let open = wide ? wideOpen : compactOpen
        let inset = wide && open ? drawerWidth : 0
        let revealing = compactOpen || dragProgress != nil
        let visible = wide ? open : revealing || retainDrawer

        ZStack(alignment: .leading) {
            if !wide || open {
                sidebar(visible)
                    .frame(width: drawerWidth)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }

            surface
                .overlay {
                    if !wide && compactOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea(.container, edges: .vertical)
                            .onTapGesture { compactOpen = false }
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: max(0, size.width - inset), height: size.height)
                .background(Color.nuwaBgBase.ignoresSafeArea(.container, edges: .vertical))
                .accessibilityHidden(!wide && compactOpen)
                .offset(x: wide ? 0 : drawerWidth * (dragProgress ?? (compactOpen ? 1 : 0)))
                .padding(.leading, inset)
                .animation(dragProgress == nil ? spring : nil, value: compactOpen)
        }
        .simultaneousGesture(pan, including: wide || !gestureEnabled ? .none : .all)
        .onChange(of: tracking) { _, active in
            guard !active else { return }
            rejectedDrag = false
            if dragProgress != nil { withAnimation(spring) { dragProgress = nil } }
        }
        .onChange(of: wide) { _, _ in
            dragProgress = nil
            rejectedDrag = false
        }
        .task(id: revealing) {
            if revealing {
                retainDrawer = true
            } else {
                if !reduceMotion {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                }
                retainDrawer = false
            }
        }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($tracking) { _, active, _ in active = true }
            .onChanged { value in
                guard !wide, gestureEnabled, !rejectedDrag else { return }
                let dx = value.translation.width
                if dragProgress == nil {
                    let canBegin = compactOpen ? dx < 0 : dx > 0 && value.startLocation.x < 32
                    guard canBegin, abs(dx) > abs(value.translation.height) * 1.35 else {
                        rejectedDrag = true
                        return
                    }
                }
                let progress = (compactOpen ? 1.0 : 0) + dx / drawerWidth
                dragProgress = min(1, max(0, progress))
            }
            .onEnded { value in
                guard let current = dragProgress else { return }
                let predicted = (compactOpen ? 1.0 : 0) + value.predictedEndTranslation.width / drawerWidth
                let open = compactOpen
                    ? !(current < 0.72 || (current < 0.86 && predicted < 0.55))
                    : current > 0.28 || (current > 0.14 && predicted > 0.45)
                if open && !compactOpen { dismissKeyboard() }
                retainDrawer = true
                withAnimation(spring) {
                    compactOpen = open
                    dragProgress = nil
                }
            }
    }
}

private enum ChatScrollTarget: Hashable {
    case top, message(UUID), bottom
}

private struct ChatTimeline<Rows: View>: View {
    @Binding var isAtBottom: Bool
    let last: ChatMessage?
    let topCommand: Int
    let animateBoundaryJumps: Bool
    let latestLabel: String
    @ViewBuilder let rows: (@escaping () -> Void) -> Rows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(iOS 18, *) {
            ModernChatTimeline(timeline: self)
        } else {
            ScrollViewReader { proxy in
                decorated(
                    scroll { proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom) }
                        .defaultScrollAnchor(.bottom)
                ) { toBottom in
                    if toBottom {
                        proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
                    } else {
                        proxy.scrollTo(ChatScrollTarget.top, anchor: .top)
                    }
                }
            }
        }
    }

    func scroll(followLatest: @escaping () -> Void) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                Color.clear.frame(height: 1).id(ChatScrollTarget.top)
                rows(followLatest)
                Color.clear
                    .frame(height: 8)
                    .id(ChatScrollTarget.bottom)
                    .onAppear {
                        if #unavailable(iOS 18) { isAtBottom = true }
                    }
                    .onDisappear {
                        if #unavailable(iOS 18) { isAtBottom = false }
                    }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .nuwaNoScrollEdgeEffect()
        .scrollDismissesKeyboard(.interactively)
    }

    func decorated<Scroll: View>(_ scroll: Scroll, scrollTo: @escaping (Bool) -> Void) -> some View {
        ZStack(alignment: .bottomTrailing) {
            scroll
                .onChange(of: last) { _, _ in
                    if isAtBottom { scrollTo(true) }
                }
                .onChange(of: topCommand) { _, _ in
                    isAtBottom = false
                    jump(toBottom: false, using: scrollTo)
                }
            if !isAtBottom {
                Button {
                    isAtBottom = true
                    jump(toBottom: true, using: scrollTo)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 36, height: 36)
                        .nuwaGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(latestLabel)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func jump(toBottom: Bool, using scrollTo: (Bool) -> Void) {
        if reduceMotion || !animateBoundaryJumps {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollTo(toBottom) }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { scrollTo(toBottom) }
        }
    }
}

@available(iOS 18, *)
private struct ModernChatTimeline<Rows: View>: View {
    let timeline: ChatTimeline<Rows>
    @State private var position = ScrollPosition(idType: ChatScrollTarget.self)
    @State private var userScrolling = false

    var body: some View {
        timeline.decorated(
            timeline.scroll { scrollTo(bottom: true) }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollGeometryChange(for: CGSize.self, of: \.containerSize) { _, size in
                    if size.width > 0 && size.height > 0 && timeline.isAtBottom && !userScrolling {
                        scrollTo(bottom: true)
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    nearBottom(geo)
                } action: { _, nearBottom in
                    if userScrolling { timeline.isAtBottom = nearBottom }
                }
                .onScrollPhaseChange { _, phase, context in
                    let wasScrolling = userScrolling
                    userScrolling = phase == .interacting || phase == .decelerating
                    if userScrolling || (wasScrolling && phase == .idle) {
                        timeline.isAtBottom = nearBottom(context.geometry)
                    }
                }
        ) { scrollTo(bottom: $0) }
    }

    private func scrollTo(bottom: Bool) {
        position.scrollTo(
            id: bottom ? ChatScrollTarget.bottom : ChatScrollTarget.top,
            anchor: bottom ? .bottom : .top
        )
    }

    private func nearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - 40
    }
}

private struct LiveReplyRow<Content: View>: View {
    @ObservedObject var store: LiveReplyStore
    let fallback: ChatMessage
    @ViewBuilder let content: (ChatMessage) -> Content
    let onUpdate: () -> Void

    var body: some View {
        content(store.message?.id == fallback.id ? store.message ?? fallback : fallback)
            .onChange(of: store.message) { _, _ in onUpdate() }
    }
}
// MARK: - Isolated Floating Liquid Glass Header

private struct ChatHeaderView: View {
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: SettingsStore
    let hasMessages: Bool
    let sessionTitle: String
    let sidebarShown: Bool
    let onOpenDrawer: () -> Void
    let onScrollToTop: () -> Void
    let onCreateNewSession: () -> Void
    let onToast: (String) -> Void


    var body: some View {
        NuwaGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onOpenDrawer) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 44, height: 44)
                        .nuwaGlass(in: Circle(), interactive: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.locale == .enUS
                    ? (sidebarShown ? "Hide sidebar" : "Show sidebar")
                    : (sidebarShown ? "隐藏边栏" : "打开边栏"))

                if hasMessages {
                    let displayTitle = sessionTitle.isEmpty ? L10n.t("untitledChat", locale: settings.locale) : sessionTitle
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: onScrollToTop)
                        .accessibilityAction(named: Text(settings.locale == .enUS ? "Scroll to top" : "回到顶部"), onScrollToTop)
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
                            .frame(width: 38, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("朗读开关")

                    Button(action: onCreateNewSession) {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 38, height: 34)
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("开启新对话")
                }
                .padding(.horizontal, 4)
                .frame(height: 42)
                .nuwaGlass(in: Capsule(), interactive: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
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
                .font(.system(size: 13))
                .foregroundStyle(active ? Color.nuwaBrandText : Color.nuwaLabelSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(NuwaTactileButtonStyle())
    }
}
