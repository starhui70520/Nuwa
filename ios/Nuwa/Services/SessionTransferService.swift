import Foundation
import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum NuwaShareTypes {
    static let sessionUTI = "com.rankchord.nuwa.session"
    static let sessionExtension = "nuwa"

    static var sessionUTType: UTType {
        UTType(exportedAs: sessionUTI, conformingTo: .zip)
    }

    static func sanitizedFileStem(for rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let cleaned = trimmed
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stem = cleaned.isEmpty ? "Nuwa_Chat" : String(cleaned.prefix(48))
        return stem
    }

    static var shareTempRoot: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NuwaShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var incomingTempRoot: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NuwaIncoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Exports a single conversation into a `.nuwa` package (DeepSeek/Nuwa v3 ZIP format)
    /// for iOS proximity AirDrop ("碰一碰") and system share sheets.
    static func writeTemporarySessionArchive(for session: ChatSession) throws -> URL {
        cleanupStaleExports()
        let folder = shareTempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = sanitizedFileStem(for: session.title)
        let url = folder.appendingPathComponent("\(stem).\(sessionExtension)")
        let zipData = try DeepSeekZipExporter.exportSessionsToZip([session])
        try zipData.write(to: url, options: [.atomic])
        return url
    }

    private static func cleanupStaleExports() {
        let cutoff = Date().addingTimeInterval(-600)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: shareTempRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}

struct IncomingFileRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case nuwaSession
        case zipArchive
        case jsonDocument
    }

    let id = UUID()
    let localURL: URL
    let tempDirectory: URL
    let fileName: String
    let fileSize: Int
    let kind: Kind
    let isLikelyBackup: Bool
    let backupSessionCount: Int
    let extractableFileCount: Int

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

private final class SessionSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ChatSession?
    private var eligible = false

    func update(session: ChatSession?, eligible: Bool) {
        lock.lock()
        self.session = session
        self.eligible = eligible
        lock.unlock()
    }

    func currentShareableSession() -> ChatSession? {
        lock.lock()
        defer { lock.unlock() }
        guard eligible, let session, !session.messages.isEmpty else { return nil }
        return session
    }
}

/// Bridges the currently active conversation to iOS 17+ proximity AirDrop ("碰一碰") via
/// `UIWindowScene.activityItemsConfigurationSource` and `rootViewController.activityItemsConfiguration`,
/// exporting the `.nuwa` archive lazily only when proximity transfer is actually triggered.
@MainActor
final class ProximitySessionShareCoordinator: NSObject, UIActivityItemsConfigurationProviding {
    private let snapshotBox = SessionSnapshotBox()
    private var cachedKey: String?
    private var cachedConfiguration: UIActivityItemsConfiguration?

    nonisolated var activityItemsConfiguration: (any UIActivityItemsConfigurationReading)? {
        MainActor.assumeIsolated {
            guard let session = snapshotBox.currentShareableSession() else { return nil }
            return cachedConfiguration ?? Self.makeConfiguration(for: session, snapshotBox: snapshotBox)
        }
    }

    func update(session: ChatSession?, eligible: Bool) {
        snapshotBox.update(session: session, eligible: eligible)
        let shareable = eligible ? session.flatMap { $0.messages.isEmpty ? nil : $0 } : nil
        let nextKey = shareable.map { "\($0.id.uuidString):\($0.title):\($0.messages.count):\($0.updatedAt.timeIntervalSince1970)" }
        if nextKey == cachedKey {
            attachToActiveScenes(configuration: cachedConfiguration)
            return
        }
        cachedKey = nextKey
        cachedConfiguration = shareable.map { Self.makeConfiguration(for: $0, snapshotBox: snapshotBox) }
        attachToActiveScenes(configuration: cachedConfiguration)
    }

    private func attachToActiveScenes(configuration: UIActivityItemsConfiguration?) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.activityItemsConfigurationSource = self
            for window in windowScene.windows where window.isKeyWindow {
                window.rootViewController?.activityItemsConfiguration = configuration
            }
        }
    }

    private static func makeConfiguration(
        for session: ChatSession,
        snapshotBox: SessionSnapshotBox? = nil
    ) -> UIActivityItemsConfiguration {
        let displayTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Nuwa 对话"
            : session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = NuwaShareTypes.sanitizedFileStem(for: displayTitle)
        let fallbackSession = session

        let provider = NSItemProvider()
        provider.suggestedName = stem
        provider.registerFileRepresentation(
            forTypeIdentifier: NuwaShareTypes.sessionUTI,
            fileOptions: [],
            visibility: .all
        ) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let target = snapshotBox?.currentShareableSession() ?? fallbackSession
                    let fileURL = try NuwaShareTypes.writeTemporarySessionArchive(for: target)
                    completion(fileURL, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }

        let config = UIActivityItemsConfiguration(itemProviders: [provider])
        config.metadataProvider = { key in
            switch key {
            case .title:
                return displayTitle
            case .messageBody:
                return "Nuwa 对话记录（\(session.messages.count) 条消息）"
            default:
                return nil
            }
        }
        let iconImage = UIImage(named: "NuwaLogo")
        config.perItemMetadataProvider = { _, key in
            guard key == .linkPresentationMetadata else { return nil }
            let metadata = LPLinkMetadata()
            metadata.title = displayTitle
            metadata.originalURL = URL(fileURLWithPath: "/\(stem).\(NuwaShareTypes.sessionExtension)")
            if let iconImage {
                metadata.iconProvider = NSItemProvider(object: iconImage)
            }
            return metadata
        }
        return config
    }

    /// Opens the native iOS share sheet (supports AirDrop / 碰一碰 / WeChat / Files) for any conversation.
    static func presentShareSheet(for session: ChatSession) {
        let config = makeConfiguration(for: session)
        let activityVC = UIActivityViewController(activityItemsConfiguration: config)

        guard let topVC = topMostViewController() else { return }
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        var cursor = keyWindow?.rootViewController
        while let presented = cursor?.presentedViewController {
            cursor = presented
        }
        return cursor
    }
}

/// Native choice sheet shown when opening a `.zip` or `.json` file in Nuwa from WeChat / Files / AirDrop,
/// offering two clear actions: "对话" (attach to chat) and "导入" (incremental protected history import).
struct IncomingFileActionSheet: View {
    let request: IncomingFileRequest
    let locale: AppLocale
    let onChat: () -> Void
    let onImport: () -> Void
    let onCancel: () -> Void

    @Environment(\.nuwaFontScale) private var fontScale

    private var isEn: Bool { locale == .enUS }

    private var fileSubtitle: String {
        let sizeText = AttachmentStore.formatByteSize(request.fileSize)
        if request.isLikelyBackup {
            if request.backupSessionCount > 0 {
                return isEn
                    ? "\(sizeText) · Nuwa / DeepSeek backup (\(request.backupSessionCount) chats)"
                    : "\(sizeText) · 检测到 Nuwa / DeepSeek 对话备份（\(request.backupSessionCount) 个会话）"
            }
            return isEn
                ? "\(sizeText) · Nuwa / DeepSeek conversation backup"
                : "\(sizeText) · 检测到 Nuwa / DeepSeek 对话备份"
        }
        if request.kind == .zipArchive {
            if request.extractableFileCount > 0 {
                return isEn
                    ? "\(sizeText) · ZIP archive (\(request.extractableFileCount) files)"
                    : "\(sizeText) · 压缩包（含 \(request.extractableFileCount) 个文件）"
            }
            return isEn ? "\(sizeText) · ZIP archive" : "\(sizeText) · 压缩包文件"
        }
        return isEn ? "\(sizeText) · JSON file" : "\(sizeText) · JSON 文件"
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.nuwaBrand.opacity(0.14))
                        .frame(width: 48, height: 48)
                    Image(systemName: request.kind == .zipArchive ? "doc.zipper" : "doc.text.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.nuwaBrand)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.fileName)
                        .font(NuwaFont.bodyMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .lineLimit(2)
                    Text(fileSubtitle)
                        .font(NuwaFont.caption(fontScale))
                        .foregroundStyle(request.isLikelyBackup ? Color.nuwaBrandText : Color.nuwaLabelSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                actionRow(
                    title: isEn ? "Chat with File" : "对话",
                    subtitle: request.kind == .zipArchive
                        ? (isEn ? "Unpack readable files inside and attach to current chat" : "自动解压其中的文档、代码或图片并添加到当前对话")
                        : (isEn ? "Attach this file to the current conversation" : "将文件作为附件添加到当前对话"),
                    icon: "bubble.left.and.text.bubble.right.fill",
                    emphasized: !request.isLikelyBackup,
                    action: onChat
                )

                actionRow(
                    title: isEn ? "Import History" : "导入",
                    subtitle: isEn
                        ? "Merge into chat history (skips older, updates newer, branches conflicts)"
                        : "导入到对话历史（相同或较旧自动跳过，分叉保留双分支）",
                    icon: "square.and.arrow.down.on.square.fill",
                    emphasized: request.isLikelyBackup,
                    action: onImport
                )
            }

            Button(role: .cancel, action: onCancel) {
                Text(L10n.t("cancel", locale: locale))
                    .font(NuwaFont.controlMedium(fontScale))
                    .foregroundStyle(Color.nuwaLabelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .presentationDetents([.height(min(440, max(336, 250 + 86 * fontScale))), .medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func actionRow(
        title: String,
        subtitle: String,
        icon: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(emphasized ? .white : Color.nuwaBrand)
                    .frame(width: 38, height: 38)
                    .background(
                        emphasized ? Color.nuwaBrand : Color.nuwaBrand.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NuwaFont.bodyMedium(fontScale))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                    Text(subtitle)
                        .font(NuwaFont.caption(fontScale))
                        .foregroundStyle(Color.nuwaLabelSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.nuwaLabelTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        emphasized ? Color.nuwaBrand.opacity(0.45) : Color.nuwaControlBorder,
                        lineWidth: emphasized ? 1.2 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(NuwaTactileButtonStyle(pressedScale: 0.98))
    }
}
