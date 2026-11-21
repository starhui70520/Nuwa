import Foundation
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var didStartProcessing = false
    private var stagedToken: String?
    private var stagedFolder: URL?
    private var stagedFileNames: [String] = []
    private var stagedText: String?

    private let spinnerView = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLoadingUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartProcessing else { return }
        didStartProcessing = true
        processIncomingShare()
    }

    private func setupLoadingUI() {
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        spinnerView.startAnimating()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在准备分享到 Nuwa..."
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinnerView, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func resolveIntentMode() -> NuwaShareGroup.ActionMode? {
        guard let intent = extensionContext?.intent as? INSendMessageIntent,
              let convId = intent.conversationIdentifier
        else { return nil }
        switch convId {
        case NuwaShareGroup.intentConversationChat:
            return .chat
        case NuwaShareGroup.intentConversationImport:
            return .import
        default:
            return nil
        }
    }

    private func processIncomingShare() {
        let intentMode = resolveIntentMode()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            finishExtension()
            return
        }

        NuwaShareGroup.cleanupStaleInboxEntries()
        let token = UUID().uuidString
        guard let folder = NuwaShareGroup.folderURL(forToken: token) else {
            showFailureAndClose("无法访问共享容器")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showFailureAndClose("创建缓存目录失败")
            return
        }

        Task {
            let extracted = await Self.extractProviders(providers, into: folder)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stagedToken = token
                self.stagedFolder = folder
                self.stagedFileNames = extracted.fileNames
                self.stagedText = extracted.text

                guard !extracted.fileNames.isEmpty || !(extracted.text ?? "").isEmpty else {
                    try? FileManager.default.removeItem(at: folder)
                    self.showFailureAndClose("未读取到可分享的文件或文本")
                    return
                }

                // 1. If launched directly from Row 1 Share Suggestions ("用 Nuwa 对话" or "导入到 Nuwa"),
                //    immediately jump to Nuwa and execute that exact action with zero extra clicks!
                if let intentMode {
                    self.commitAndOpenHostApp(mode: intentMode)
                    return
                }

                // 2. Dedicated `.nuwa` session share -> auto-import directly.
                if extracted.fileNames.count == 1,
                   (extracted.fileNames[0] as NSString).pathExtension.lowercased() == "nuwa" {
                    self.commitAndOpenHostApp(mode: .import)
                    return
                }

                // 3. Launched from Row 2 ("Nuwa") with a ZIP or JSON -> show clean 2-option picker ("对话" / "导入").
                let hasArchiveOrJSON = extracted.fileNames.contains { name in
                    let ext = (name as NSString).pathExtension.lowercased()
                    return ext == "zip" || ext == "json"
                }
                if hasArchiveOrJSON {
                    self.presentModeChooser(fileNames: extracted.fileNames)
                    return
                }

                // 4. Plain documents, images, or text -> send straight to chat.
                self.commitAndOpenHostApp(mode: .chat)
            }
        }
    }

    private func presentModeChooser(fileNames: [String]) {
        spinnerView.stopAnimating()
        view.subviews.forEach { $0.removeFromSuperview() }

        let primaryName = fileNames.first ?? "文件"
        let displayTitle = fileNames.count > 1 ? "\(primaryName) 等 \(fileNames.count) 个文件" : primaryName
        let isZip = fileNames.contains { ($0 as NSString).pathExtension.lowercased() == "zip" }

        let chooser = ShareModeChooserView(
            fileTitle: displayTitle,
            isZip: isZip,
            onChat: { [weak self] in
                self?.commitAndOpenHostApp(mode: .chat)
            },
            onImport: { [weak self] in
                self?.commitAndOpenHostApp(mode: .import)
            },
            onCancel: { [weak self] in
                self?.cancelAndCleanup()
            }
        )
        let host = UIHostingController(rootView: chooser)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func commitAndOpenHostApp(mode: NuwaShareGroup.ActionMode) {
        guard let token = stagedToken, let folder = stagedFolder else {
            finishExtension()
            return
        }

        let manifest = NuwaShareGroup.HandoffManifest(
            token: token,
            mode: mode,
            fileNames: stagedFileNames,
            text: stagedText,
            createdAt: Date().timeIntervalSince1970
        )
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: NuwaShareGroup.manifestURL(in: folder), options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            showFailureAndClose("保存分享数据失败")
            return
        }

        guard let deepLink = NuwaShareGroup.deepLinkURL(token: token, mode: mode) else {
            finishExtension()
            return
        }

        openHostApp(url: deepLink) { [weak self] in
            self?.finishExtension()
        }
    }

    private func openHostApp(url: URL, completion: @escaping @MainActor () -> Void) {
        // iOS 18+ Share Extension host-app handoff: traverse responder chain to UIApplication
        // and invoke the non-deprecated `open(_:options:completionHandler:)`.
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { _ in
                    Task { @MainActor in
                        completion()
                    }
                }
                return
            }
            responder = current.next
        }

        if let context = extensionContext {
            context.open(url) { _ in
                Task { @MainActor in
                    completion()
                }
            }
            return
        }

        completion()
    }

    private func cancelAndCleanup() {
        if let folder = stagedFolder {
            try? FileManager.default.removeItem(at: folder)
        }
        extensionContext?.cancelRequest(withError: NSError(domain: "com.rankchord.nuwa.share", code: 0))
    }

    private func showFailureAndClose(_ message: String) {
        spinnerView.stopAnimating()
        statusLabel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finishExtension()
        }
    }

    private func finishExtension() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Low-Memory Streaming Extraction from NSItemProvider

    private struct ExtractedPayload {
        let fileNames: [String]
        let text: String?
    }

    private static func extractProviders(_ providers: [NSItemProvider], into folder: URL) async -> ExtractedPayload {
        var fileNames: [String] = []
        var textParts: [String] = []
        var usedNames = Set<String>()

        for provider in providers {
            if let copiedName = await copyFileAttachment(from: provider, into: folder, usedNames: &usedNames) {
                fileNames.append(copiedName)
                continue
            }
            if let text = await loadTextOrURL(from: provider), !text.isEmpty {
                textParts.append(text)
            }
        }

        let combinedText = textParts.isEmpty ? nil : textParts.joined(separator: "\n")
        return ExtractedPayload(fileNames: fileNames, text: combinedText)
    }

    private static func copyFileAttachment(
        from provider: NSItemProvider,
        into folder: URL,
        usedNames: inout Set<String>
    ) async -> String? {
        let preferredTypes: [String] = [
            "com.rankchord.nuwa.session",
            UTType.zip.identifier,
            "com.pkware.zip-archive",
            UTType.json.identifier,
            UTType.pdf.identifier,
            UTType.image.identifier,
            UTType.fileURL.identifier,
            UTType.data.identifier,
            UTType.item.identifier,
        ]

        // Only handle file/data/image items here; let pure URL/plainText fall through to loadTextOrURL.
        let isPureWebURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.zip.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
        if isPureWebURL {
            return nil
        }
        let isPurePlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.zip.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.json.identifier)
        if isPurePlainText {
            return nil
        }

        for typeId in preferredTypes where provider.hasItemConformingToTypeIdentifier(typeId) {
            if typeId == UTType.fileURL.identifier {
                if let copied = await loadFileURLItem(provider: provider, folder: folder, usedNames: &usedNames) {
                    return copied
                }
                continue
            }
            if let copied = await loadStreamedFile(provider: provider, typeIdentifier: typeId, folder: folder, usedNames: &usedNames) {
                return copied
            }
        }
        return nil
    }

    private static func loadStreamedFile(
        provider: NSItemProvider,
        typeIdentifier: String,
        folder: URL,
        usedNames: inout Set<String>
    ) async -> String? {
        let suggested = provider.suggestedName
        let tempCopy: (url: URL, name: String)? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { tempURL, _ in
                guard let tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let rawName = resolveFileName(tempURL: tempURL, suggestedName: suggested, typeIdentifier: typeIdentifier)
                let staging = folder.appendingPathComponent(".tmp_\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: tempURL, to: staging)
                    continuation.resume(returning: (staging, rawName))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let tempCopy else { return nil }
        let uniqueName = makeUniqueFileName(tempCopy.name, usedNames: &usedNames)
        let finalURL = folder.appendingPathComponent(uniqueName)
        do {
            try FileManager.default.moveItem(at: tempCopy.url, to: finalURL)
            return uniqueName
        } catch {
            try? FileManager.default.removeItem(at: tempCopy.url)
            return nil
        }
    }

    private static func loadFileURLItem(
        provider: NSItemProvider,
        folder: URL,
        usedNames: inout Set<String>
    ) async -> String? {
        let suggested = provider.suggestedName
        let tempCopy: (url: URL, name: String)? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let sourceURL: URL?
                if let url = item as? URL {
                    sourceURL = url
                } else if let data = item as? Data {
                    sourceURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    sourceURL = nil
                }
                guard let sourceURL, sourceURL.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                let rawName = resolveFileName(tempURL: sourceURL, suggestedName: suggested, typeIdentifier: UTType.fileURL.identifier)
                let staging = folder.appendingPathComponent(".tmp_\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: staging)
                    continuation.resume(returning: (staging, rawName))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let tempCopy else { return nil }
        let uniqueName = makeUniqueFileName(tempCopy.name, usedNames: &usedNames)
        let finalURL = folder.appendingPathComponent(uniqueName)
        do {
            try FileManager.default.moveItem(at: tempCopy.url, to: finalURL)
            return uniqueName
        } catch {
            try? FileManager.default.removeItem(at: tempCopy.url)
            return nil
        }
    }

    private static func loadTextOrURL(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let urlText: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL, !url.isFileURL {
                        continuation.resume(returning: url.absoluteString)
                    } else if let str = item as? String {
                        continuation.resume(returning: str)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let urlText, !urlText.isEmpty { return urlText }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    continuation.resume(returning: item as? String)
                }
            }
        }
        return nil
    }

    private static func resolveFileName(tempURL: URL, suggestedName: String?, typeIdentifier: String) -> String {
        let urlName = tempURL.lastPathComponent
        let chosen: String
        if !urlName.isEmpty && urlName != "data" {
            chosen = urlName
        } else if let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            chosen = suggested
        } else {
            chosen = "shared_file"
        }
        let cleaned = chosen.replacingOccurrences(of: "/", with: "_")
        if !(cleaned as NSString).pathExtension.isEmpty {
            return cleaned
        }
        if typeIdentifier == "com.rankchord.nuwa.session" {
            return "\(cleaned).nuwa"
        }
        if let utType = UTType(typeIdentifier), let ext = utType.preferredFilenameExtension {
            return "\(cleaned).\(ext)"
        }
        return cleaned
    }

    private static func makeUniqueFileName(_ raw: String, usedNames: inout Set<String>) -> String {
        var candidate = raw
        let stem = (raw as NSString).deletingPathExtension
        let ext = (raw as NSString).pathExtension
        var index = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }
}

private struct ShareModeChooserView: View {
    let fileTitle: String
    let isZip: Bool
    let onChat: () -> Void
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: isZip ? "doc.zipper" : "doc.text.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text("选择在 Nuwa 中处理该文件的方式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                optionButton(
                    title: "用 Nuwa 对话",
                    subtitle: isZip ? "自动解压文件并添加到当前对话" : "作为附件添加到当前对话",
                    icon: "bubble.left.and.text.bubble.right.fill",
                    tint: Color(red: 0.145, green: 0.388, blue: 0.922),
                    action: onChat
                )
                optionButton(
                    title: "导入到 Nuwa",
                    subtitle: "按增量合并规则导入到对话历史",
                    icon: "square.and.arrow.down.on.square.fill",
                    tint: Color(red: 0.055, green: 0.647, blue: 0.914),
                    action: onImport
                )
            }

            Button(role: .cancel, action: onCancel) {
                Text("取消")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    @ViewBuilder
    private func optionButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
