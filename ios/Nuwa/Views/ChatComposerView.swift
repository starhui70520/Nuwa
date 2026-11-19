import SwiftUI

/// Exact 1:1 recreation of chat-demo/src/components/chatInput/ChatInput.tsx
/// upgraded with native iOS keyboard avoidance and iOS 26 Liquid Glass controls.
struct ChatComposerView: View {
    @Binding var text: String
    @Binding var thinkingEnabled: Bool
    @Binding var searchEnabled: Bool
    let isGenerating: Bool
    let isRecording: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onToggleVoice: () -> Void
    let onAttachmentTap: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating && !isRecording
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 10) {
                TextField("发消息或语音输入", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...6)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                    .submitLabel(.return)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                NuwaGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        // Left toggles: 深度思考 & 智能搜索
                        HStack(spacing: 6) {
                            togglePill(
                                title: "深度思考",
                                systemImage: "atom",
                                selected: thinkingEnabled
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    thinkingEnabled.toggle()
                                }
                            }

                            togglePill(
                                title: "智能搜索",
                                systemImage: "globe",
                                selected: searchEnabled
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    searchEnabled.toggle()
                                }
                            }
                        }

                        Spacer(minLength: 4)

                        // Right actions matching ChatInput.tsx exactly
                        HStack(spacing: 6) {
                            if isGenerating {
                                attachmentButton
                                stopButton
                            } else if !canSend && !isRecording {
                                attachmentButton
                                voiceButton
                            } else {
                                voiceButton
                                attachmentButton
                                sendButton
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .nuwaGlassCard(cornerRadius: 24, interactive: false)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func togglePill(
        title: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .nuwaGlass(
                in: Capsule(),
                tint: selected ? .nuwaBrand : nil,
                interactive: true
            )
        }
        .buttonStyle(.plain)
    }

    private var attachmentButton: some View {
        Button(action: onAttachmentTap) {
            Image(systemName: "plus.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.nuwaLabelSecondary)
                .frame(width: 32, height: 32)
                .nuwaGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上传文件")
    }

    private var voiceButton: some View {
        Button(action: onToggleVoice) {
            Image(systemName: isRecording ? "waveform.circle.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isRecording ? .red : Color.nuwaLabelSecondary)
                .frame(width: 32, height: 32)
                .nuwaGlass(in: Circle(), tint: isRecording ? .red : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "停止语音输入" : "语音输入")
    }

    private var sendButton: some View {
        Button {
            isFocused = false
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(canSend ? Color.nuwaBrand : Color.nuwaBrand.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("发送")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.nuwaBrand, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("停止生成")
    }
}
