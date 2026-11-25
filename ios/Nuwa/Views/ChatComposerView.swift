import PhotosUI
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct ChatComposerView: View {
    @Binding var text: String
    let attachments: [DraftAttachment]
    @Binding var thinkingEnabled: Bool
    @Binding var searchEnabled: Bool
    @Binding var isAttachmentPanelOpen: Bool
    let locale: AppLocale
    let hasActiveCredential: Bool
    let canSend: Bool
    let isGenerating: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let recordingSeconds: Int
    let audioLevel: Float
    let hapticFeedbackEnabled: Bool
    let allowPressEffect: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onToggleVoice: () -> Void
    let onCancelVoice: () -> Void
    let onPickPhotos: ([NuwaLegacyPickedImage]) -> Void
    let onPickRecentPhoto: (Data, String, String) -> Void
    let onPickFiles: () -> Void
    let onRetryAttachment: (String) -> Void
    let onRemoveAttachment: (String) -> Void
    let onRequireCredential: () -> Void
    let onToast: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var legacyFocused = false
    @State private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nuwaFontScale) private var fontScale
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @StateObject private var recentPhotos = RecentPhotosStore()
    @State private var pickingPhotoIds: Set<String> = []

    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 12) {
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
                } else if #available(iOS 16.0, *) {
                    TextField(L10n.t("placeholder", locale: locale), text: $text, axis: .vertical)
                        .focused($isFocused)
                        .lineLimit(1...6)
                        .font(NuwaFont.body(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .submitLabel(.return)
                        .frame(minHeight: max(38, 22 + 16 * fontScale), alignment: .topLeading)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .background {
                            ComposerTouchProbeOverlay(
                                isEnabled: allowPressEffect,
                                onPressChange: { pressing = $0 },
                                onTapFocus: {
                                    if !isFocused { isFocused = true }
                                }
                            )
                        }
                } else {
                    NuwaLegacyMultilineTextField(
                        placeholder: L10n.t("placeholder", locale: locale),
                        text: $text,
                        uiFont: UIFont.systemFont(ofSize: 16 * fontScale),
                        minLines: 1,
                        maxLines: 6,
                        isFocused: $legacyFocused
                    )
                    .frame(minHeight: max(38, 22 + 16 * fontScale), alignment: .topLeading)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background {
                // Keep the text editor's hit area and selection geometry stationary.
                Color.clear
                    .nuwaGlassCard(cornerRadius: 28, tint: colorScheme == .dark ? .white.opacity(0.08) : nil)
                    .brightness(pressing ? (colorScheme == .dark ? 0.035 : -0.015) : 0)
                    .scaleEffect(pressing && !reduceMotion ? 0.96 : 1)
                    .animation(
                        pressing ? .easeOut(duration: 0.065) : .spring(response: 0.34, dampingFraction: 0.66),
                        value: pressing
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28))

            if isAttachmentPanelOpen {
                attachmentDrawerPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: isAttachmentPanelOpen)
        .nuwaOnChange(of: allowPressEffect && !isRecording) { enabled in
            if !enabled { pressing = false }
        }
        .nuwaOnChange(of: isFocused) { focused in
            if focused && isAttachmentPanelOpen {
                isAttachmentPanelOpen = false
            }
        }
        .nuwaOnChange(of: legacyFocused) { focused in
            if focused && isAttachmentPanelOpen {
                isAttachmentPanelOpen = false
            }
        }
        .nuwaOnChange(of: isAttachmentPanelOpen) { open in
            if open {
                isFocused = false
                legacyFocused = false
                recentPhotos.loadRecentPhotos(limit: 16)
            } else {
                pickingPhotoIds.removeAll()
            }
        }
        .modifier(ComposerPhotoPickerModifier(isPresented: $showPhotoPicker, onPicked: onPickPhotos))
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { captured in
                onPickPhotos([captured])
            }
            .ignoresSafeArea()
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
                                .font(NuwaFont.badge(fontScale))
                                .foregroundStyle(Color.nuwaLabelPrimary)
                                .lineLimit(1)
                            Text(statusSubtitle(item))
                                .font(NuwaFont.sized(10, scale: fontScale))
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
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(NuwaFont.sized(13.5, weight: .semibold, scale: fontScale))
                Text(title)
                    .font(NuwaFont.pill(fontScale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .nuwaPillSurface(selected: selected)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.95))
    }

    private var attachmentMenuButton: some View {
        Button {
            guard hasActiveCredential else {
                isAttachmentPanelOpen = false
                onRequireCredential()
                return
            }
            if hapticFeedbackEnabled { Self.lightImpact.impactOccurred() }
            if !isAttachmentPanelOpen {
                dismissEditorKeyboard()
            }
            isAttachmentPanelOpen.toggle()
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundStyle(isAttachmentPanelOpen ? Color.nuwaBrandText : Color.nuwaLabelPrimary)
                .rotationEffect(.degrees(isAttachmentPanelOpen ? 45 : 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isAttachmentPanelOpen)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
        .accessibilityLabel("上传文件")
    }

    private var attachmentDrawerPanel: some View {
        VStack(spacing: 10) {
            if recentPhotos.isLoading || !recentPhotos.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if recentPhotos.isLoading && recentPhotos.items.isEmpty {
                            ForEach(0..<4, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.nuwaControlFill)
                                    .frame(width: 72, height: 72)
                            }
                        } else {
                            ForEach(recentPhotos.items) { photo in
                                recentPhotoTile(photo)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(spacing: 10) {
                attachmentActionCard(
                    title: L10n.t("uploadCamera", locale: locale),
                    systemImage: "camera"
                ) {
                    isAttachmentPanelOpen = false
                    guard hasActiveCredential else {
                        onRequireCredential()
                        return
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCameraPicker = true
                    } else {
                        onToast(locale == .enUS ? "Camera is not available on this device" : "当前设备不支持拍照")
                    }
                }

                attachmentActionCard(
                    title: L10n.t("uploadGallery", locale: locale),
                    systemImage: "photo.on.rectangle"
                ) {
                    isAttachmentPanelOpen = false
                    guard hasActiveCredential else {
                        onRequireCredential()
                        return
                    }
                    showPhotoPicker = true
                }

                attachmentActionCard(
                    title: L10n.t("uploadDocument", locale: locale),
                    systemImage: "paperclip"
                ) {
                    isAttachmentPanelOpen = false
                    guard hasActiveCredential else {
                        onRequireCredential()
                        return
                    }
                    onPickFiles()
                }
            }
        }
        .padding(12)
        .background {
            Color.clear
                .nuwaGlassCard(cornerRadius: 24, tint: colorScheme == .dark ? .white.opacity(0.06) : nil)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func recentPhotoTile(_ photo: RecentPhotoAsset) -> some View {
        let matchedAttachment = attachments.first(where: { $0.sourcePhotoAssetId == photo.id })
        let picked = matchedAttachment != nil
        let picking = pickingPhotoIds.contains(photo.id)

        Button {
            guard !picking else { return }
            if let existing = matchedAttachment {
                if hapticFeedbackEnabled { Self.lightImpact.impactOccurred() }
                onRemoveAttachment(existing.id)
                return
            }
            guard hasActiveCredential else {
                isAttachmentPanelOpen = false
                onRequireCredential()
                return
            }
            if hapticFeedbackEnabled { Self.lightImpact.impactOccurred() }
            pickingPhotoIds.insert(photo.id)
            Task {
                defer { pickingPhotoIds.remove(photo.id) }
                if let loaded = await recentPhotos.loadFullImageData(assetId: photo.id) {
                    onPickRecentPhoto(loaded.data, loaded.fileName, photo.id)
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb = recentPhotos.thumbnails[photo.id] {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.nuwaControlFill
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(picking ? 0.55 : 1)

                if picking {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                        .frame(width: 72, height: 72)
                }

                ZStack {
                    Circle()
                        .fill(picked ? Color.nuwaBrand : Color.black.opacity(0.32))
                        .frame(width: 22, height: 22)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.4)
                        .frame(width: 22, height: 22)
                    if picked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.95))
        .disabled(picking)
        .accessibilityLabel(photo.fileName)
    }

    @ViewBuilder
    private func attachmentActionCard(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.nuwaLabelPrimary)
                Text(title)
                    .font(NuwaFont.captionMedium(fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(Color.nuwaControlFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.nuwaControlBorder, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.96))
    }

    private func dismissEditorKeyboard() {
        isFocused = false
        legacyFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var voiceButton: some View {
        Button {
            isAttachmentPanelOpen = false
            onToggleVoice()
        } label: {
            Group {
                if isTranscribing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isRecording ? "checkmark" : "waveform.circle")
                        .font(.system(size: isRecording ? 15 : 22, weight: isRecording ? .semibold : .regular))
                        .foregroundStyle(isRecording ? .white : Color.nuwaLabelPrimary)
                }
            }
            .frame(width: 34, height: 34)
            .background(isRecording ? Color.nuwaBrand : Color.clear, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.92))
        .accessibilityLabel(isRecording ? "结束录音并转写" : "语音输入")
    }

    private var sendButton: some View {
        Button {
            isFocused = false
            legacyFocused = false
            isAttachmentPanelOpen = false
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(canSend ? Color.nuwaBrand : Color.nuwaBrand.opacity(0.35), in: Circle())
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
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
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
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
    @Environment(\.nuwaFontScale) private var fontScale

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
                .font(NuwaFont.badge(fontScale).monospacedDigit())
                .foregroundStyle(Color.nuwaLabelSecondary)
        }
        .padding(.horizontal, 4)
    }
}

/// Observes the text area without intercepting the editor's native touch gestures.
private struct ComposerTouchProbeOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let onPressChange: (Bool) -> Void
    let onTapFocus: () -> Void

    func makeUIView(context: Context) -> ComposerTouchProbeView {
        let view = ComposerTouchProbeView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.update(
            isEnabled: isEnabled,
            onPressChange: onPressChange,
            onTapFocus: onTapFocus
        )
        return view
    }

    func updateUIView(_ uiView: ComposerTouchProbeView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            onPressChange: onPressChange,
            onTapFocus: onTapFocus
        )
    }

    static func dismantleUIView(_ uiView: ComposerTouchProbeView, coordinator: ()) {
        uiView.detachRecognizer()
    }
}

private final class ComposerTouchProbeView: UIView {
    private let recognizer = ComposerPressRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        recognizer.targetView = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        isEnabled: Bool,
        onPressChange: @escaping (Bool) -> Void,
        onTapFocus: @escaping () -> Void
    ) {
        recognizer.isProbeEnabled = isEnabled
        recognizer.onPressChange = onPressChange
        recognizer.onTapFocus = onTapFocus
    }

    func detachRecognizer() {
        recognizer.cancelPendingRelease()
        recognizer.view?.removeGestureRecognizer(recognizer)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detachRecognizer()
        if let window {
            window.addGestureRecognizer(recognizer)
        }
    }
}

private final class ComposerPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var targetView: UIView?
    var isProbeEnabled = true
    var onPressChange: ((Bool) -> Void)?
    var onTapFocus: (() -> Void)?

    private var startWindowPoint: CGPoint = .zero
    private var pressStartTime: CFTimeInterval = 0
    private var activeTouch: UITouch?
    private var releaseWorkItem: DispatchWorkItem?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func cancelPendingRelease() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch == nil else { return }
        guard isProbeEnabled,
              let targetView,
              targetView.window != nil,
              !targetView.isHidden,
              targetView.alpha > 0.01,
              touches.count == 1,
              let touch = touches.first,
              targetView.bounds.contains(touch.location(in: targetView))
        else {
            state = .failed
            return
        }

        cancelPendingRelease()
        activeTouch = touch
        startWindowPoint = touch.location(in: nil)
        pressStartTime = CACurrentMediaTime()
        onPressChange?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let current = touch.location(in: nil)
        if hypot(current.x - startWindowPoint.x, current.y - startWindowPoint.y) > 16 {
            endPress(immediately: true, focus: false)
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        endPress(immediately: false, focus: isProbeEnabled)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        endPress(immediately: true, focus: false)
        state = .failed
    }

    override func reset() {
        super.reset()
        if activeTouch != nil {
            endPress(immediately: true, focus: false)
        }
    }

    private func endPress(immediately: Bool, focus: Bool) {
        activeTouch = nil
        cancelPendingRelease()

        if focus {
            onTapFocus?()
        }

        if immediately {
            onPressChange?(false)
            return
        }

        let elapsed = CACurrentMediaTime() - pressStartTime
        let remaining = max(0, 0.085 - elapsed)
        if remaining <= 0.004 {
            onPressChange?(false)
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.releaseWorkItem = nil
                self?.onPressChange?(false)
            }
            releaseWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
        }
    }
}

private struct ComposerPhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: ([NuwaLegacyPickedImage]) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.modifier(ModernPhotoPickerModifier(isPresented: $isPresented, onPicked: onPicked))
        } else {
            content.sheet(isPresented: $isPresented) {
                NuwaLegacyPhotoPicker(selectionLimit: 9, onPicked: onPicked)
            }
        }
    }
}

@available(iOS 16.0, *)
private struct ModernPhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: ([NuwaLegacyPickedImage]) -> Void
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPresented,
                selection: $selectedPhotoItems,
                maxSelectionCount: 9,
                matching: .images
            )
            .nuwaOnChange(of: selectedPhotoItems) { items in
                guard !items.isEmpty else { return }
                let batch = items
                selectedPhotoItems = []
                Task {
                    var loaded: [NuwaLegacyPickedImage] = []
                    for (idx, item) in batch.enumerated() {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            let name = "photo_\(Int(Date().timeIntervalSince1970))_\(idx).\(ext)"
                            loaded.append(NuwaLegacyPickedImage(data: data, fileName: name))
                        }
                    }
                    if !loaded.isEmpty {
                        await MainActor.run { onPicked(loaded) }
                    }
                }
            }
    }
}
