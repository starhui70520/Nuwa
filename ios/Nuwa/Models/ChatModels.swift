import Foundation
import SwiftUI

enum ApiProtocol: String, Codable, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI 兼容协议"
        case .anthropic: "Anthropic 协议"
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

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let apiProtocol: ApiProtocol
    let baseUrl: String
    let defaultModel: String
    let reasoningModel: String?

    static let presets: [ProviderPreset] = [
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek 官方",
            apiProtocol: .openai,
            baseUrl: "https://api.deepseek.com",
            defaultModel: "deepseek-chat",
            reasoningModel: "deepseek-reasoner"
        ),
        ProviderPreset(
            id: "openai",
            name: "OpenAI 兼容接口",
            apiProtocol: .openai,
            baseUrl: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            reasoningModel: nil
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic 兼容接口",
            apiProtocol: .anthropic,
            baseUrl: "https://api.anthropic.com",
            defaultModel: "claude-sonnet-4-20250514",
            reasoningModel: nil
        ),
    ]
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var reasoning: String
    var thinkingSeconds: Double?
    var createdAt: Date
    var isStreaming: Bool
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoning: String = "",
        thinkingSeconds: Double? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.thinkingSeconds = thinkingSeconds
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, thinkingSeconds, createdAt, errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        thinkingSeconds = try c.decodeIfPresent(Double.self, forKey: .thinkingSeconds)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        isStreaming = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(thinkingSeconds, forKey: .thinkingSeconds)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }
}

struct NuwaBackupArchive: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()
    var sessions: [ChatSession]
}
