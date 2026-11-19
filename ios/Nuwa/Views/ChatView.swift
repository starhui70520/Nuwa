import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Exact 1:1 recreation of Nuwa v0.1.31 mobile UI/UX with full Android feature parity:
/// - Full-bleed edge-to-edge background (zero top/bottom blank strips)
/// - Interactive finger-following push drawer (dragProgress 0...1, 0.95 scale, 24pt corner radius)
/// - Floating Liquid Glass MobileHeader (42pt circle menu + centered double-tap-to-top title + 42pt speaker/new-chat capsule)
/// - Minimal Welcome screen (52pt NuwaLogo + greeting)
/// - Full branching conversation tree (inline edit user message, regenerate any reply, < 1/N > switcher, continue generating)
/// - Structured ReplyBlocks (DeepThink accordion, Web Search + Read Link / Open Page steps + SearchPanelSheet, rich Markdown + citations)
/// - Native file & photo attachments (draft strip, upload status, thumbnails, full-screen image lightbox preview)
/// - Per-session drafts, voice prefix append, MigrationPromptModal, pending migration recovery, Settings over open sidebar, iCloud auto-backup
struct ChatView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var drawerOpen = false
    @State private var dragProgress: CGFloat? = nil
    @State private var isTrackingHorizontalDrag = false

    @State private var showSettings = false
    @State private var showMigrationWeb = false
    @State private var showZipImporter = false
    @State private var showAttachmentFilePicker = false

    @State private var editingMessageId: UUID?
    @State private var editDraftText = ""
    @State private var searchPanelResults: [WebSearchResultItem]?
    @State private var previewImage: UIImage?

    @State private var voiceDraftPrefix = ""
    @State private var scrollToTopToken = 0
    @State private var lastTitleTapAt: Date?
    @State private var isAtBottom = true

    private let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!

    private var visibleMessages: [ChatMessage] {
        chatStore.activeSession?.visibleMessages() ?? []
    }

    private var hasMessages: Bool {
        !visibleMessages.isEmpty
    }

    private var effectiveProgress: CGFloat {
        dragProgress ?? (drawerOpen ? 1 : 0)
    }

    private var currentDraftBinding: Binding<String> {
        Binding(
            get: { chatStore.draft(for: chatStore.activeSessionId).text },
            set: { chatStore.setDraftText($0, for: chatStore.activeSessionId) }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = min(geo.size.width * 0.82, 310)
            let progress = effectiveProgress
            let scale = 1.0 - 0.05 * progress
            let cornerRadius = 24.0 * progress

            ZStack(alignment: .leading) {
                SessionDrawerView(
                    chatStore: chatStore,
                    settings: settings,
                    isOpen: drawerOpen,
                    onClose: { closeDrawer() },
                    onOpenSettings: { showSettings = true }
                )
                .frame(width: drawerWidth)

                mainSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.nuwaBgBase.ignoresSafeArea(.container, edges: .vertical))
                    .mask {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .ignoresSafeArea(.container, edges: .vertical)
                    }
                    .shadow(
                        color: Color.black.opacity(0.14 * progress),
                        radius: 24,
                        x: -6,
                        y: 0
                    )
                    .scaleEffect(scale, anchor: .leading)
                    .offset(x: drawerWidth * progress)
                    .overlay {
                        if drawerOpen && dragProgress == nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .ignoresSafeArea(.container, edges: .vertical)
                                .onTapGesture { closeDrawer() }
                                .offset(x: drawerWidth)
                        }
                    }
                    .animation(
                        dragProgress == nil ? .spring(response: 0.28, dampingFraction: 0.88) : nil,
                        value: drawerOpen
                    )

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
                        withAnimation(.easeOut(duration: 0.18)) {
                            self.previewImage = nil
                        }
                    }
                    .transition(.opacity)
                    .zIndex(60)
                }
            }
            .background(Color.nuwaSidebarFill.ignoresSafeArea())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        guard !settings.showMigrationPrompt, !showSettings, editingMessageId == nil, previewImage == nil else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height

                        if !isTrackingHorizontalDrag {
                            guard abs(dx) > abs(dy) * 1.25 else { return }
                            if (!drawerOpen && dx <= 0) || (drawerOpen && dx >= 0) {
                                return
                            }
                            isTrackingHorizontalDrag = true
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }

                        let raw = drawerOpen ? (1.0 + dx / drawerWidth) : (dx / drawerWidth)
                        dragProgress = max(0, min(1, raw))
                    }
                    .onEnded { value in
                        guard isTrackingHorizontalDrag else { return }
                        let current = dragProgress ?? (drawerOpen ? 1 : 0)
                        let predictedDx = value.predictedEndTranslation.width
                        let predictedProgress = drawerOpen
                            ? (1.0 + predictedDx / drawerWidth)
                            : (predictedDx / drawerWidth)

                        isTrackingHorizontalDrag = false
                        dragProgress = nil

                        if drawerOpen {
                            drawerOpen = !(current < 0.72 || predictedProgress < 0.55)
                        } else {
                            drawerOpen = (current > 0.28 || predictedProgress > 0.45)
                        }
                    }
            )
        }
        .onAppear {
            chatStore.checkPendingMigration()
            chatStore.maybeAutoBackupToIcloud(settings: settings)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chatStore.checkPendingMigration()
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
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try chatStore.importFromFileData(data)
                    chatStore.showToast(count == 1 ? "已导入 1 个对话" : "已导入 \(count) 个对话")
                } catch {
                    chatStore.showToast("导入失败：\(error.localizedDescription)")
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
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        let name = url.lastPathComponent
                        chatStore.addDraftFile(
                            data: data,
                            fileName: name,
                            isImage: AttachmentStore.isImageName(name),
                            for: targetSession,
                            settings: settings
                        )
                    }
                }
            case .failure(let error):
                chatStore.showToast("选择文件失败：\(error.localizedDescription)")
            }
        }
        .onChange(of: speech.errorMessage) { _, newError in
            if let newError {
                chatStore.showToast(newError)
            }
        }
    }

    private var mainSurface: some View {
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

            mobileHeader

            ZStack(alignment: .top) {
                if let session = chatStore.activeSession, !visibleMessages.isEmpty {
                    messageList(session: session, messages: visibleMessages)
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let sid = chatStore.activeSessionId
            let currentDraft = chatStore.draft(for: sid)
            ChatComposerView(
                text: currentDraftBinding,
                attachments: currentDraft.attachments,
                thinkingEnabled: $settings.thinkingEnabled,
                searchEnabled: $settings.searchEnabled,
                locale: settings.locale,
                canSend: chatStore.canSendDraft(for: sid),
                isGenerating: chatStore.isGenerating,
                isRecording: speech.isRecording,
                isTranscribing: speech.isTranscribing,
                recordingSeconds: speech.recordingSeconds,
                audioLevel: speech.audioLevel,
                onSend: sendMessage,
                onStop: {
                    speech.stopSpeaking()
                    chatStore.stopGenerating()
                },
                onToggleVoice: {
                    if !speech.isRecording {
                        voiceDraftPrefix = chatStore.draft(for: sid).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let capturedPrefix = voiceDraftPrefix
                    speech.toggleRecording(settings: settings) { transcript in
                        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        if capturedPrefix.isEmpty {
                            chatStore.setDraftText(clean, for: sid)
                        } else {
                            chatStore.setDraftText("\(capturedPrefix) \(clean)", for: sid)
                        }
                    }
                },
                onCancelVoice: { speech.cancelRecording() },
                onPickPhotos: { items in handlePickedPhotos(items, sessionId: sid) },
                onPickFiles: { showAttachmentFilePicker = true },
                onRetryAttachment: { fileId in
                    chatStore.retryDraftAttachment(fileId: fileId, for: sid, settings: settings)
                },
                onRemoveAttachment: { fileId in
                    chatStore.removeDraftAttachment(fileId: fileId, for: sid)
                }
            )
        }
    }

    private var mobileHeader: some View {
        NuwaGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    openDrawer()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 42, height: 42)
                        .nuwaGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开边栏")

                if hasMessages {
                    let displayTitle = (chatStore.activeSession?.title.isEmpty == false)
                        ? chatStore.activeSession!.title
                        : L10n.t("untitledChat", locale: settings.locale)
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Double-tap title to scroll to top (1:1 SessionView.tsx onTitleTap)
                            let now = Date()
                            if let last = lastTitleTapAt, now.timeIntervalSince(last) <= 0.4 {
                                lastTitleTapAt = nil
                                scrollToTopToken += 1
                            } else {
                                lastTitleTapAt = now
                            }
                        }
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
                            chatStore.showToast(settings.ttsMuted ? "已静音朗读" : "已取消朗读静音")
                        }
                    } label: {
                        Image(systemName: (speech.isSpeaking || !settings.ttsMuted) ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 38, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("朗读开关")

                    Button {
                        chatStore.createNewSession()
                    } label: {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 38, height: 34)
                    }
                    .buttonStyle(.plain)
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

    private func messageList(session: ChatSession, messages: [ChatMessage]) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        Color.clear.frame(height: 1).id("top-anchor")
                        ForEach(messages) { message in
                            messageRow(
                                session: session,
                                message: message,
                                isLast: message.id == messages.last?.id
                            )
                            .id(message.id)
                        }
                        Color.clear
                            .frame(height: 8)
                            .id("bottom-anchor")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
                .onChange(of: messages.last?.content) { _, _ in
                    if chatStore.isGenerating && isAtBottom {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
                .onChange(of: scrollToTopToken) { _, _ in
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo("top-anchor", anchor: .top)
                    }
                }

                if !isAtBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.nuwaLabelPrimary)
                            .frame(width: 36, height: 36)
                            .nuwaGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(session: ChatSession, message: ChatMessage, isLast: Bool) -> some View {
        let versionInfo = session.versionInfo(for: message)

        if message.role == .user {
            let isEditing = editingMessageId == message.id
            VStack(alignment: .trailing, spacing: 6) {
                if !message.files.isEmpty {
                    userFilesStrip(message.files)
                }

                if isEditing {
                    // 1:1 Inline Editor matching UserMessage.tsx .editor
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
                                    .nuwaGlass(in: Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)

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
                            .buttonStyle(.plain)
                            .disabled(!canSaveEdit)
                        }
                    }
                    .padding(12)
                    .nuwaGlassCard(cornerRadius: 20, interactive: false)
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

                    // User action row: Copy, Inline Edit, Branch Switcher (< 1/N >)
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
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                        }

                        if !chatStore.isGenerating {
                            Button {
                                editDraftText = message.content
                                editingMessageId = message.id
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.nuwaLabelTertiary)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
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
                        onCopyCode: { _ in chatStore.showToast(L10n.t("copied", locale: settings.locale)) }
                    )
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
                    NuwaGlassGroup(spacing: 6) {
                        HStack(spacing: 8) {
                            if !displayText.isEmpty {
                                Button {
                                    UIPasteboard.general.string = displayText
                                    chatStore.showToast(L10n.t("copied", locale: settings.locale))
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .frame(width: 30, height: 30)
                                        .nuwaGlass(in: Circle(), interactive: true)
                                }
                                .buttonStyle(.plain)

                                if !refused {
                                    Button {
                                        speech.toggleSpeak(messageId: message.id, text: displayText, settings: settings)
                                    } label: {
                                        Image(systemName: speech.speakingMessageId == message.id ? "speaker.slash.fill" : "speaker.wave.2")
                                            .font(.caption)
                                            .foregroundStyle(speech.speakingMessageId == message.id ? Color.nuwaBrandText : Color.nuwaLabelSecondary)
                                            .frame(width: 30, height: 30)
                                            .nuwaGlass(in: Circle(), interactive: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !refused {
                                Button {
                                    speech.stopSpeaking()
                                    chatStore.regenerateReply(messageId: message.id, settings: settings)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundStyle(Color.nuwaLabelSecondary)
                                        .frame(width: 30, height: 30)
                                        .nuwaGlass(in: Circle(), interactive: true)
                                }
                                .buttonStyle(.plain)
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
                                        .frame(height: 30)
                                        .nuwaGlass(in: Capsule(), tint: .nuwaBrand, interactive: true)
                                }
                                .buttonStyle(.plain)
                            }

                            BranchSwitcherView(versionInfo: versionInfo) { targetId in
                                chatStore.selectVersion(messageId: targetId)
                            }
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
                    if file.isImage, let img = AttachmentStore.loadLocalImage(for: file) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                previewImage = img
                            }
                        } label: {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
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

    private func handlePickedPhotos(_ items: [PhotosPickerItem], sessionId: UUID?) {
        Task {
            for (idx, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "photo_\(Int(Date().timeIntervalSince1970))_\(idx).\(ext)"
                    chatStore.addDraftFile(
                        data: data,
                        fileName: name,
                        isImage: true,
                        for: sessionId,
                        settings: settings
                    )
                }
            }
        }
    }

    private func openDrawer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        drawerOpen = true
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
