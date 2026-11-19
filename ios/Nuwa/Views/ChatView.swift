import SwiftUI
import UIKit

/// Exact 1:1 recreation of Nuwa mobile UI/UX:
/// - Push-style left drawer (300pt offset, 0.95 scale, 24pt corner radius)
/// - Floating MobileHeader (42pt circular menu button + center title + 42pt speaker/new-chat capsule)
/// - Minimal Welcome screen (52pt Nuwa logo + "你好，让我们开始聊天吧")
/// - Soft bluish user bubbles + clean assistant Markdown + bottom ChatComposerView
/// All interactive controls upgraded with native iOS 26 Liquid Glass.
struct ChatView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService

    @State private var draftText = ""
    @State private var drawerOpen = false
    @State private var showSettings = false

    private let drawerWidth: CGFloat = 300

    private var hasMessages: Bool {
        !(chatStore.activeSession?.messages.isEmpty ?? true)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Left push-drawer sidebar
            SessionDrawerView(
                chatStore: chatStore,
                settings: settings,
                onClose: { closeDrawer() },
                onOpenSettings: { showSettings = true }
            )
            .frame(width: drawerWidth)

            // Main chat surface (pushes right + scales to 0.95 when drawer opens, matching App.module.css)
            mainSurface
                .background(Color.nuwaBgBase)
                .clipShape(RoundedRectangle(cornerRadius: drawerOpen ? 24 : 0, style: .continuous))
                .shadow(
                    color: Color.black.opacity(drawerOpen ? 0.14 : 0),
                    radius: 24,
                    x: -6,
                    y: 0
                )
                .scaleEffect(drawerOpen ? 0.95 : 1.0, anchor: .leading)
                .offset(x: drawerOpen ? drawerWidth : 0)
                .overlay {
                    if drawerOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeDrawer() }
                            .offset(x: drawerWidth)
                    }
                }
                .animation(.spring(response: 0.30, dampingFraction: 0.88), value: drawerOpen)
                .gesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onEnded { value in
                            if !drawerOpen && value.startLocation.x < 36 && value.translation.width > 60 {
                                openDrawer()
                            } else if drawerOpen && value.translation.width < -50 {
                                closeDrawer()
                            }
                        }
                )
        }
        .background(Color.nuwaSidebarFill.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, chatStore: chatStore)
        }
        .onChange(of: speech.errorMessage) { _, newError in
            if let newError {
                chatStore.showToast(newError)
            }
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 0) {
            mobileHeader

            ZStack(alignment: .top) {
                if let session = chatStore.activeSession, !session.messages.isEmpty {
                    messageList(session: session)
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
            ChatComposerView(
                text: $draftText,
                thinkingEnabled: $settings.thinkingEnabled,
                searchEnabled: $settings.searchEnabled,
                isGenerating: chatStore.isGenerating,
                isRecording: speech.isRecording,
                onSend: sendMessage,
                onStop: { chatStore.stopGenerating() },
                onToggleVoice: {
                    speech.toggleRecording { transcript in
                        draftText = transcript
                    }
                },
                onAttachmentTap: {
                    chatStore.showToast("附件上传功能正在接入原生端")
                }
            )
        }
    }

    /// Exact 1:1 MobileHeader: 42pt circular menu button + centered title + 42pt 2-action capsule
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
                .accessibilityLabel("展开侧边栏")

                if hasMessages, let title = chatStore.activeSession?.title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
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
                            chatStore.showToast(settings.ttsMuted ? "已关闭自动朗读" : "已开启朗读")
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

    /// Exact 1:1 Welcome.tsx: centered 52x52 NuwaLogo + "你好，让我们开始聊天吧"
    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("NuwaLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 4)

            Text("你好，让我们开始聊天吧")
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
            // Exact UserMessage.module.css: soft bluish fill (--dsw-specific-bubble), 22pt radius, primary text
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
                            .foregroundStyle(Color.nuwaLabelSecondary)
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
                                chatStore.showToast("已复制")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(Color.nuwaLabelSecondary)
                                    .frame(width: 30, height: 30)
                                    .nuwaGlass(in: Circle(), interactive: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                speech.toggleSpeak(messageId: message.id, text: message.content)
                            } label: {
                                Image(systemName: speech.speakingMessageId == message.id ? "speaker.slash.fill" : "speaker.wave.2")
                                    .font(.caption)
                                    .foregroundStyle(speech.speakingMessageId == message.id ? Color.nuwaBrandText : Color.nuwaLabelSecondary)
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
                                        .foregroundStyle(Color.nuwaLabelSecondary)
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

    private func openDrawer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        drawerOpen = true
    }

    private func closeDrawer() {
        drawerOpen = false
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
