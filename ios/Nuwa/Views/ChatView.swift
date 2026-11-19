import SwiftUI
import UIKit

struct ChatView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService

    @State private var draftText = ""
    @State private var showSessions = false
    @State private var showSettings = false

    private let starterPrompts = [
        "帮我梳理一下今天的工作重点",
        "用 SwiftUI 写一个优雅的卡片动画",
        "把下面这段文字润色得更专业简洁",
        "解释一下量子计算的核心原理",
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if let session = chatStore.activeSession, !session.messages.isEmpty {
                    messageList(session: session)
                } else {
                    welcomeView
                }

                if let toast = chatStore.toastMessage {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .nuwaGlass(in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerView(
                    text: $draftText,
                    thinkingEnabled: $settings.thinkingEnabled,
                    isGenerating: chatStore.isGenerating,
                    isRecording: speech.isRecording,
                    isConfigured: settings.isConfigured,
                    onSend: sendMessage,
                    onStop: { chatStore.stopGenerating() },
                    onToggleVoice: {
                        speech.toggleRecording { transcript in
                            draftText = transcript
                        }
                    },
                    onOpenSettings: { showSettings = true }
                )
            }
            .navigationTitle(chatStore.activeSession?.title ?? "Nuwa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSessions = true
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("历史会话")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        chatStore.createNewSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新对话")

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showSessions) {
                SessionDrawerView(chatStore: chatStore) {
                    showSettings = true
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings, chatStore: chatStore)
            }
            .onChange(of: speech.errorMessage) { _, newError in
                if let newError {
                    chatStore.showToast(newError)
                }
            }
        }
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 48)

                Image("NuwaLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 8)

                VStack(spacing: 6) {
                    Text("你好，我是 Nuwa")
                        .font(.title2.weight(.bold))
                    Text("原生 iOS 体验 · 本地优先的多模型 AI 助手")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(starterPrompts, id: \.self) { prompt in
                        Button {
                            draftText = prompt
                            if settings.isConfigured {
                                sendMessage()
                            } else {
                                showSettings = true
                            }
                        } label: {
                            Text(prompt)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                                .padding(12)
                                .nuwaGlassCard(cornerRadius: 16, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func messageList(session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(session.messages) { message in
                        messageRow(message: message, isLast: message.id == session.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 8).id("bottom-anchor")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: session.messages.last?.content) { _, _ in
                if chatStore.isGenerating {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, isLast: Bool) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.system(size: settings.chatFontSize))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.nuwaBrand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !message.reasoning.isEmpty {
                    ReasoningDisclosureView(
                        reasoning: message.reasoning,
                        seconds: message.thinkingSeconds,
                        isStreaming: message.isStreaming && message.content.isEmpty
                    )
                }

                if !message.content.isEmpty {
                    MarkdownMessageView(
                        text: message.content,
                        fontSize: settings.chatFontSize,
                        onCopyCode: { _ in chatStore.showToast("已复制代码") }
                    )
                } else if message.isStreaming && message.reasoning.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在思考...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = message.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !message.isStreaming {
                    NuwaGlassGroup(spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                UIPasteboard.general.string = message.content
                                chatStore.showToast("已复制到剪贴板")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .nuwaGlass(in: Circle(), interactive: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                speech.toggleSpeak(messageId: message.id, text: message.content)
                            } label: {
                                Image(systemName: speech.speakingMessageId == message.id ? "speaker.slash.fill" : "speaker.wave.2")
                                    .font(.caption)
                                    .foregroundStyle(speech.speakingMessageId == message.id ? Color.nuwaBrand : .secondary)
                                    .frame(width: 30, height: 30)
                                    .nuwaGlass(in: Circle(), interactive: true)
                            }
                            .buttonStyle(.plain)

                            if isLast {
                                Button {
                                    chatStore.regenerateLast(settings: settings)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, height: 30)
                                        .nuwaGlass(in: Circle(), interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sendMessage() {
        guard settings.isConfigured else {
            showSettings = true
            return
        }
        if speech.isRecording {
            speech.stopRecording()
        }
        let payload = draftText
        draftText = ""
        chatStore.send(prompt: payload, settings: settings)
    }
}
