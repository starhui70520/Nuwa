import Foundation

enum NuwaShareGroup {
    static let appGroupID = "group.com.rankchord.nuwa"
    static let urlScheme = "nuwa"

    static let intentConversationChat = "nuwa_chat"
    static let intentConversationImport = "nuwa_import"

    enum ActionMode: String, Codable, Equatable {
        case chat
        case `import`
        case ask
    }

    struct HandoffManifest: Codable, Equatable {
        let token: String
        let mode: ActionMode
        let fileNames: [String]
        let text: String?
        let createdAt: TimeInterval
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var shareInboxURL: URL? {
        guard let root = containerURL else { return nil }
        let inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    static func folderURL(forToken token: String) -> URL? {
        shareInboxURL?.appendingPathComponent(token, isDirectory: true)
    }

    static func manifestURL(in folder: URL) -> URL {
        folder.appendingPathComponent("handoff.json")
    }

    static func deepLinkURL(token: String, mode: ActionMode) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "share"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        return components.url
    }

    static func cleanupStaleInboxEntries(olderThan seconds: TimeInterval = 3600) {
        guard let inbox = shareInboxURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for dir in entries {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}
