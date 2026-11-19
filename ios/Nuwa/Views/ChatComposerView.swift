import SwiftUI

struct ChatComposerView: View {
    @Binding var text: String
    @Binding var thinkingEnabled: Bool
    let isGenerating: Bool
    let isRecording: Bool
    let isConfigured: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onToggleVoice: () -> Void
    let onOpenSettings: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if !isConfigured {
                Button(action: onOpenSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.nuwaBrand)
                        Text("尚未配置 API Key，点此前往设置")
                            .font(.footnote.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .nuwaGlass(in: Capsule(), tint: .nuwaBrand, interactive: true)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                TextField("向 Nuwa 提问...", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...6)
                    .font(.body)
                    .submitLabel(.return)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)

                NuwaGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                thinkingEnabled.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.caption.weight(.semibold))
                                Text("深度思考")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(thinkingEnabled ? Color.nuwaBrand : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .nuwaGlass(
                                in: Capsule(),
                                tint: thinkingEnabled ? .nuwaBrand : nil,
                                interactive: true
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: onToggleVoice) {
                            Image(systemName: isRecording ? "waveform.circle.fill" : "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isRecording ? .red : .secondary)
                                .frame(width: 34, height: 34)
                                .nuwaGlass(
                                    in: Circle(),
                                    tint: isRecording ? .red : nil,
                                    interactive: true
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isRecording ? "停止语音输入" : "语音输入")

                        if isGenerating {
                            Button(action: onStop) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.nuwaBrand, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("停止生成")
                        } else {
                            Button {
                                isFocused = false
                                onSend()
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(canSend ? .white : .secondary)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        canSend ? Color.nuwaBrand : Color.primary.opacity(0.08),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSend)
                            .accessibilityLabel("发送")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .nuwaGlassCard(cornerRadius: 26, interactive: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
