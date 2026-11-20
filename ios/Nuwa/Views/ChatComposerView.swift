import PhotosUI
import SwiftUI
import UIKit

/// Exact 1:1 recreation of chat-demo/src/components/chatInput/ChatInput.tsx
/// Single floating iOS 26 Liquid Glass container (ZERO nested glass-on-glass!).
/// DeepThink & Search toggles use crisp Nuwa blue pills + light haptic + tactile scale feedback.
struct ChatComposerView: View {
    @Binding var text: String
    let attachments: [DraftAttachment]
    @Binding var thinkingEnabled: Bool
    @Binding var searchEnabled: Bool
    let locale: AppLocale
    let canSend: Bool
    let isGenerating: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let recordingSeconds: Int
    let audioLevel: Float
    let hapticFeedbackEnabled: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onToggleVoice: () -> Void
    let onCancelVoice: () -> Void
    let onPickPhotos: ([PhotosPickerItem]) -> Void
    let onPickFiles: () -> Void
    let onRetryAttachment: (String) -> Void
    let onRemoveAttachment: (String) -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false

    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 10) {
                // Draft attachments strip (cached thumbnails + status/retry/remove)
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { item in
                                draftAttachmentChip(item)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                    }
                }

                // Recording waveform spectrum OR TextField
                if isRecording {
                    VoiceSpectrumBar(level: audioLevel, seconds: recordingSeconds, onCancel: onCancelVoice)
                        .frame(minHeight: 40)
                } else {
                    TextField(L10n.t("placeholder", locale: locale), text: $text, axis: .vertical)
                        .focused($isFocused)
                        .lineLimit(1...6)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .submitLabel(.return)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }

                // Bottom action row — lightweight crisp native controls inside ONE Liquid Glass card
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        togglePill(
                            title: L10n.t("thinking", locale: locale),
                            systemImage: "atom",
                            selected: thinkingEnabled
                        ) {
                            if hapticFeedbackEnabled { Self.lightImpact.impactOccurred() }
                            withAnimation(.easeInOut(duration: 0.16)) {
                                thinkingEnabled.toggle()
                            }
                        }

                        togglePill(
                            title: L10n.t("search", locale: locale),
                            systemImage: "globe",
                            selected: searchEnabled
                        ) {
                            if hapticFeedbackEnabled { Self.lightImpact.impactOccurred() }
                            withAnimation(.easeInOut(duration: 0.16)) {
                                searchEnabled.toggle()
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        if isGenerating {
                            attachmentMenuButton
                            stopButton
                        } else if isRecording || isTranscribing {
                            voiceButton
                        } else if !canSend {
                            attachmentMenuButton
                            voiceButton
                        } else {
                            voiceButton
                            attachmentMenuButton
                            sendButton
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .nuwaGlassCard(cornerRadius: 24, interactive: false)
            .overlay {
                let shape = RoundedRectangle(cornerRadius: 24)
                shape
                    .strokeBorder(Color.nuwaBrandText.opacity(isFocused ? 0.42 : 0), lineWidth: 1)
                    .shadow(color: Color.nuwaBrandText.opacity(isFocused ? 0.48 : 0), radius: 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.015 : 1, anchor: .bottom)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.65), value: isFocused)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 9,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let batch = items
            selectedPhotoItems = []
            onPickPhotos(batch)
        }
    }

    @ViewBuilder
    private func draftAttachmentChip(_ item: DraftAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            AttachmentThumbnail(file: item.file, pointSize: 56) { image in
                if let uiImg = image {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.nuwaBrandText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.file.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .lineLimit(1)
                            Text(statusSubtitle(item))
                                .font(.system(size: 10))
                                .foregroundStyle(isFailed(item.status) ? .red : Color.nuwaLabelTertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 56)
                    .frame(maxWidth: 160)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .overlay {
                if item.status == .uploading {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(ProgressView().tint(.white).controlSize(.small))
                } else if isFailed(item.status) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.28))
                        .overlay {
                            Button {
                                onRetryAttachment(item.id)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                }
            }

            Button {
                onRemoveAttachment(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    private func isFailed(_ status: DraftUploadStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func statusSubtitle(_ item: DraftAttachment) -> String {
        switch item.status {
        case .uploading: return "上传中..."
        case .done: return AttachmentStore.formatByteSize(item.file.size)
        case .failed: return "失败，点击重试"
        }
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
                    .font(.system(size: 12.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .nuwaPillSurface(selected: selected)
            .contentShape(Capsule())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.95))
    }

    private var attachmentMenuButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("相册图片", systemImage: "photo.on.rectangle")
            }
            Button {
                onPickFiles()
            } label: {
                Label("选取文件 (PDF / Word / 代码等)", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.nuwaLabelSecondary)
                .frame(width: 32, height: 32)
                .background(Color.nuwaControlFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75))
                .contentShape(Circle())
        }
        .accessibilityLabel("上传文件")
    }

    private var voiceButton: some View {
        Button(action: onToggleVoice) {
            Group {
                if isTranscribing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isRecording ? "checkmark" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isRecording ? .white : Color.nuwaLabelSecondary)
                }
            }
            .frame(width: 32, height: 32)
            .background(isRecording ? Color.nuwaBrand : Color.nuwaControlFill, in: Circle())
            .overlay(
                Circle().strokeBorder(isRecording ? Color.clear : Color.nuwaControlBorder, lineWidth: 0.75)
            )
            .contentShape(Circle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
        .accessibilityLabel(isRecording ? "结束录音并转写" : "语音输入")
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
                .contentShape(Circle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
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
                .contentShape(Circle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
        .accessibilityLabel("停止生成")
    }
}

/// Live animated audio waveform bar matching chat-demo/src/components/chatInput/Spectrum.tsx
private struct VoiceSpectrumBar: View {
    let level: Float
    let seconds: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.nuwaControlFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(NuwaTactileButtonStyle())

            HStack(spacing: 3) {
                ForEach(0..<18, id: \.self) { i in
                    let wave = sin(Double(i) * 0.65 + Double(seconds) * 1.4)
                    let factor = max(0.18, min(1.0, Double(level) * (0.55 + 0.45 * abs(wave))))
                    Capsule()
                        .fill(Color.nuwaBrand)
                        .frame(width: 3, height: CGFloat(6 + factor * 22))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(maxWidth: .infinity)

            Text("录音中 \(seconds)s")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.nuwaLabelSecondary)
        }
        .padding(.horizontal, 4)
    }
}
