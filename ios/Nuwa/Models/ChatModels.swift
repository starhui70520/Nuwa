import Foundation
import SwiftUI

enum ApiProtocol: String, Codable, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI 兼容"
        case .anthropic: "Anthropic 兼容"
        }
    }
}

enum SpeechEngineOption: String, Codable, CaseIterable, Identifiable {
    case auto
    case native
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "自动"
        case .native: "设备原生"
        case .cloud: "云端"
        }
    }
}

enum ThemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AccountBalance: Codable, Equatable {
    let currency: String
    let totalBalance: String
    let formatted: String
    let isAvailable: Bool
}

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let apiProtocol: ApiProtocol
    let baseUrl: String
    let defaultModel: String

    static let presets: [ProviderPreset] = [
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek 官方 (Anthropic)",
            apiProtocol: .anthropic,
            baseUrl: "https://api.deepseek.com",
            defaultModel: "deepseek-flash"
        ),
        ProviderPreset(
            id: "deepseek-openai",
            name: "DeepSeek (OpenAI 兼容)",
            apiProtocol: .openai,
            baseUrl: "https://api.deepseek.com",
            defaultModel: "deepseek-chat"
        ),
        ProviderPreset(
            id: "openai",
            name: "OpenAI 兼容中转",
            apiProtocol: .openai,
            baseUrl: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini"
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic 官方",
            apiProtocol: .anthropic,
            baseUrl: "https://api.anthropic.com",
            defaultModel: "claude-sonnet-4-20250514"
        ),
    ]
}

// MARK: - Attachments

struct FileAttachment: Identifiable, Codable, Equatable {
    let id: String
    var serverId: String?
    let name: String
    let size: Int
    let isImage: Bool
    var mimeType: String
    var localFileName: String?

    init(
        id: String = UUID().uuidString,
        serverId: String? = nil,
        name: String,
        size: Int,
        isImage: Bool,
        mimeType: String = "",
        localFileName: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.size = size
        self.isImage = isImage
        self.mimeType = mimeType
        self.localFileName = localFileName
    }
}

enum DraftUploadStatus: Equatable {
    case uploading
    case done
    case failed(String)
}

struct DraftAttachment: Identifiable, Equatable {
    let id: String
    var file: FileAttachment
    var status: DraftUploadStatus
    var sourcePhotoAssetId: String? = nil
}

struct DraftEntry: Equatable {
    var text: String = ""
    var attachments: [DraftAttachment] = []
}

// MARK: - Structured Reply Blocks (1:1 chat-demo/src/services/chat/types.ts)

struct TextCitation: Identifiable, Codable, Equatable {
    var id: String { "\(url)-\(title ?? "")" }
    let url: String
    let title: String?
    let citedText: String?
}

struct WebSearchResultItem: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    let title: String
    let snippet: String?
    let siteName: String?
    let siteIcon: String?
    let pageAge: String?
}

struct WebFetchResultInfo: Codable, Equatable {
    let url: String?
    let title: String?
    let publishedAt: String?
    let errorCode: String?
    var documentText: String? = nil
}

struct ServerToolUseInfo: Codable, Equatable {
    let id: String
    let name: String
    let kind: String // search, deep_search, read_link, image_search
    let action: String // search, open_page, read_link, find_in_page
    let queries: [String]
    let url: String?
    let pattern: String?
}

enum ReplyBlock: Identifiable, Codable, Equatable {
    case thinking(id: UUID, text: String, signature: String?, startedAt: Date?, endedAt: Date?, elapsedSeconds: Double?)
    case text(id: UUID, text: String, citations: [TextCitation], isTemplate: Bool)
    case serverToolUse(id: UUID, info: ServerToolUseInfo)
    case webSearchResult(id: UUID, toolUseId: String, kind: String, items: [WebSearchResultItem], errorCode: String?)
    case webFetchResult(id: UUID, toolUseId: String, kind: String, result: WebFetchResultInfo, signature: String?)

    var id: UUID {
        switch self {
        case .thinking(let id, _, _, _, _, _),
             .text(let id, _, _, _),
             .serverToolUse(let id, _),
             .webSearchResult(let id, _, _, _, _),
             .webFetchResult(let id, _, _, _, _):
            return id
        }
    }
}

enum CompactionSource: String, Codable, Equatable {
    case auto
    case manual
}

struct CompactionSpan: Identifiable, Codable, Equatable {
    let id: UUID
    let startMessageId: UUID
    let endMessageId: UUID
    var title: String
    var summary: String
    var keywords: [String]?
    var editedByUser: Bool?
    let source: CompactionSource
    let coveredRounds: Int
    let originalTokensEstimate: Int
    var summaryTokensEstimate: Int
    let model: String?
    let createdAt: Date
    var updatedAt: Date
}

struct RecalledMemory: Codable, Equatable {
    let roundNumbers: [Int]
    let spanTitles: [String]
    let blockText: String?
}

struct MessageTokenUsage: Codable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
}

enum ReplyStatus: String, Codable {
    case pending
    case streaming
    case done
    case stopped
    case error
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var parentId: UUID?
    var selectedChildId: UUID?
    let role: MessageRole
    var content: String
    var reasoning: String
    var thinkingSeconds: Double?
    var files: [FileAttachment]
    var blocks: [ReplyBlock]
    var status: ReplyStatus
    var stopReason: String?
    var thinkingEnabled: Bool
    var searchEnabled: Bool
    var prefixEnabled: Bool
    var latestReminder: String?
    var recalledMemory: RecalledMemory?
    var usage: MessageTokenUsage?
    var createdAt: Date
    var errorMessage: String?

    var isStreaming: Bool {
        status == .streaming || status == .pending
    }

    var fullTextContent: String {
        if role == .assistant && !blocks.isEmpty {
            let joined = blocks.compactMap { block -> String? in
                if case .text(_, let t, _, _) = block { return t }
                return nil
            }.joined()
            if !joined.isEmpty { return joined }
        }
        return content
    }

    var fullThinkingContent: String {
        if role == .assistant && !blocks.isEmpty {
            let joined = blocks.compactMap { block -> String? in
                if case .thinking(_, let t, _, _, _, _) = block { return t }
                return nil
            }.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        return reasoning
    }

    var allSearchResults: [WebSearchResultItem] {
        var seen = Set<String>()
        var out: [WebSearchResultItem] = []
        for block in blocks {
            if case .webSearchResult(_, _, _, let items, _) = block {
                for item in items where !seen.contains(item.url) {
                    seen.insert(item.url)
                    out.append(item)
                }
            }
        }
        return out
    }

    var canContinueReply: Bool {
        guard role == .assistant, prefixEnabled else { return false }
        if stopReason == "refusal" || stopReason == "tool_use" { return false }
        let hasServerTools = blocks.contains { block in
            switch block {
            case .serverToolUse, .webSearchResult, .webFetchResult: return true
            case .text(_, _, _, let isTemplate): return isTemplate
            default: return false
            }
        }
        if hasServerTools { return false }
        return status == .stopped || (status == .done && stopReason == "max_tokens")
    }

    init(
        id: UUID = UUID(),
        parentId: UUID? = nil,
        selectedChildId: UUID? = nil,
        role: MessageRole,
        content: String,
        reasoning: String = "",
        thinkingSeconds: Double? = nil,
        files: [FileAttachment] = [],
        blocks: [ReplyBlock] = [],
        status: ReplyStatus = .done,
        stopReason: String? = nil,
        thinkingEnabled: Bool = false,
        searchEnabled: Bool = false,
        prefixEnabled: Bool = true,
        latestReminder: String? = nil,
        recalledMemory: RecalledMemory? = nil,
        usage: MessageTokenUsage? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.selectedChildId = selectedChildId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.thinkingSeconds = thinkingSeconds
        self.files = files
        self.blocks = blocks
        self.status = isStreaming ? .streaming : status
        self.stopReason = stopReason
        self.thinkingEnabled = thinkingEnabled
        self.searchEnabled = searchEnabled
        self.prefixEnabled = prefixEnabled
        self.latestReminder = latestReminder
        self.recalledMemory = recalledMemory
        self.usage = usage
        self.createdAt = createdAt
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, parentId, selectedChildId, role, content, reasoning, thinkingSeconds
        case files, blocks, status, stopReason, thinkingEnabled, searchEnabled, prefixEnabled
        case latestReminder, recalledMemory, usage, createdAt, errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        selectedChildId = try c.decodeIfPresent(UUID.self, forKey: .selectedChildId)
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        thinkingSeconds = try c.decodeIfPresent(Double.self, forKey: .thinkingSeconds)
        files = try c.decodeIfPresent([FileAttachment].self, forKey: .files) ?? []
        blocks = try c.decodeIfPresent([ReplyBlock].self, forKey: .blocks) ?? []
        let decodedStatus = try c.decodeIfPresent(ReplyStatus.self, forKey: .status) ?? .done
        status = (decodedStatus == .streaming || decodedStatus == .pending) ? .stopped : decodedStatus
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        thinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        searchEnabled = try c.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? false
        prefixEnabled = try c.decodeIfPresent(Bool.self, forKey: .prefixEnabled) ?? true
        latestReminder = try c.decodeIfPresent(String.self, forKey: .latestReminder)
        recalledMemory = try c.decodeIfPresent(RecalledMemory.self, forKey: .recalledMemory)
        usage = try c.decodeIfPresent(MessageTokenUsage.self, forKey: .usage)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

// MARK: - Branching Session Model (1:1 chat-demo/src/services/chat/branches.ts)

struct MessageVersionInfo: Equatable {
    let ids: [UUID]
    let index: Int
    var count: Int { ids.count }
}

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var rootMessageId: UUID?
    var messages: [ChatMessage]
    var compactions: [CompactionSpan]?
    var autoCompact: Bool?
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var pinnedAt: Date?
    private(set) var hasLoadedMessages = true

    private enum CodingKeys: String, CodingKey {
        case id, title, rootMessageId, messages, compactions, autoCompact, createdAt, updatedAt, isPinned, pinnedAt
    }

    var metadataOnly: ChatSession {
        var result = self
        result.messages = []
        result.compactions = nil
        result.autoCompact = nil
        result.hasLoadedMessages = false
        return result
    }

    mutating func applyMetadata(from record: ChatSession) {
        title = record.title
        updatedAt = record.updatedAt
        isPinned = record.isPinned
        pinnedAt = record.pinnedAt
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        rootMessageId: UUID? = nil,
        messages: [ChatMessage] = [],
        compactions: [CompactionSpan]? = nil,
        autoCompact: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.rootMessageId = rootMessageId
        self.messages = messages
        self.compactions = compactions
        self.autoCompact = autoCompact
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt ?? (isPinned ? updatedAt : nil)
    }

    /// Normalizes a legacy linear message list into a linked tree with rootMessageId / parentId / selectedChildId.
    mutating func ensureTreeNormalized() {
        guard !messages.isEmpty else { return }
        if let root = rootMessageId, messages.contains(where: { $0.id == root }) {
            return
        }
        if rootMessageId != nil {
            // Repair an orphaned rootMessageId pointer without discarding existing branch links.
            rootMessageId = messages.first(where: { $0.parentId == nil })?.id ?? messages.first?.id
            return
        }
        rootMessageId = messages.first?.id
        for i in messages.indices {
            messages[i].parentId = i > 0 ? messages[i - 1].id : nil
            messages[i].selectedChildId = i + 1 < messages.count ? messages[i + 1].id : nil
        }
    }

    /// Returns the currently visible linear branch path (1:1 getVisibleMessages).
    func visibleMessages() -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        guard let root = rootMessageId else {
            return messages
        }
        var byId = [UUID: Int](minimumCapacity: messages.count)
        for (index, message) in messages.enumerated() {
            if byId[message.id] == nil {
                byId[message.id] = index
            }
        }
        let startId: UUID? = byId[root] != nil
            ? root
            : (messages.first(where: { $0.parentId == nil })?.id ?? messages.first?.id)
        var path: [ChatMessage] = []
        var cursor: UUID? = startId
        while let id = cursor, let index = byId.removeValue(forKey: id) {
            let msg = messages[index]
            path.append(msg)
            cursor = msg.selectedChildId
        }
        return path.isEmpty ? messages : path
    }

    func messageVersions() -> [UUID: MessageVersionInfo] {
        var firstChild = [UUID?: UUID](minimumCapacity: messages.count)
        var siblings: [UUID?: [UUID]] = [:]
        for message in messages {
            let parent = message.parentId
            if let first = firstChild[parent] {
                siblings[parent, default: [first]].append(message.id)
            } else {
                firstChild[parent] = message.id
            }
        }
        var versions: [UUID: MessageVersionInfo] = [:]
        for ids in siblings.values {
            for (index, id) in ids.enumerated() {
                versions[id] = MessageVersionInfo(ids: ids, index: index)
            }
        }
        return versions
    }

    /// Appends a new branch under `parentId` and selects it while preserving old branches (1:1 appendBranch).
    mutating func appendBranch(parentId: UUID?, newMessages: [ChatMessage]) {
        ensureTreeNormalized()
        guard let first = newMessages.first else { return }
        if parentId == nil {
            rootMessageId = first.id
        } else if let pIdx = messages.firstIndex(where: { $0.id == parentId }) {
            messages[pIdx].selectedChildId = first.id
        }
        for (offset, var msg) in newMessages.enumerated() {
            msg.parentId = offset == 0 ? parentId : newMessages[offset - 1].id
            msg.selectedChildId = offset + 1 < newMessages.count ? newMessages[offset + 1].id : nil
            messages.append(msg)
        }
    }

    /// Switches active version among siblings (1:1 selectVersion).
    mutating func selectVersion(messageId: UUID) {
        ensureTreeNormalized()
        guard let target = messages.first(where: { $0.id == messageId }) else { return }
        if target.parentId == nil {
            rootMessageId = target.id
        } else if let pIdx = messages.firstIndex(where: { $0.id == target.parentId }) {
            messages[pIdx].selectedChildId = target.id
        }
    }
}

struct NuwaBackupArchive: Codable {
    var version: Int = 2
    var exportedAt: Date = Date()
    var sessions: [ChatSession]
}
