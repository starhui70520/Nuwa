import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let apiKeyAccount = "nuwa_api_key"
        static let apiProtocol = "nuwa.apiProtocol"
        static let apiBaseUrl = "nuwa.apiBaseUrl"
        static let apiModel = "nuwa.apiModel"
        static let thinkingEnabled = "nuwa.thinkingEnabled"
        static let searchEnabled = "nuwa.searchEnabled"
        static let ttsMuted = "nuwa.ttsMuted"
        static let themePreference = "nuwa.themePreference"
        static let chatFontSize = "nuwa.chatFontSize"
        static let systemPrompt = "nuwa.systemPrompt"
    }

    @Published var apiKey: String {
        didSet { KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keys.apiKeyAccount) }
    }

    @Published var apiProtocol: ApiProtocol {
        didSet { UserDefaults.standard.set(apiProtocol.rawValue, forKey: Keys.apiProtocol) }
    }

    @Published var apiBaseUrl: String {
        didSet { UserDefaults.standard.set(apiBaseUrl, forKey: Keys.apiBaseUrl) }
    }

    @Published var apiModel: String {
        didSet { UserDefaults.standard.set(apiModel, forKey: Keys.apiModel) }
    }

    @Published var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: Keys.thinkingEnabled) }
    }

    @Published var searchEnabled: Bool {
        didSet { UserDefaults.standard.set(searchEnabled, forKey: Keys.searchEnabled) }
    }

    @Published var ttsMuted: Bool {
        didSet { UserDefaults.standard.set(ttsMuted, forKey: Keys.ttsMuted) }
    }

    @Published var themePreference: ThemePreference {
        didSet { UserDefaults.standard.set(themePreference.rawValue, forKey: Keys.themePreference) }
    }

    @Published var chatFontSize: Double {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: Keys.chatFontSize) }
    }

    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Keys.systemPrompt) }
    }

    @Published var deepSeekBalanceText: String?
    @Published var isLoadingBalance = false

    init() {
        let defaults = UserDefaults.standard
        apiKey = KeychainStore.load(account: Keys.apiKeyAccount) ?? ""
        apiProtocol = ApiProtocol(rawValue: defaults.string(forKey: Keys.apiProtocol) ?? "") ?? .openai
        apiBaseUrl = defaults.string(forKey: Keys.apiBaseUrl) ?? "https://api.deepseek.com"
        apiModel = defaults.string(forKey: Keys.apiModel) ?? "deepseek-chat"
        thinkingEnabled = defaults.object(forKey: Keys.thinkingEnabled) as? Bool ?? false
        searchEnabled = defaults.object(forKey: Keys.searchEnabled) as? Bool ?? false
        ttsMuted = defaults.object(forKey: Keys.ttsMuted) as? Bool ?? false
        themePreference = ThemePreference(rawValue: defaults.string(forKey: Keys.themePreference) ?? "") ?? .system
        let storedSize = defaults.double(forKey: Keys.chatFontSize)
        chatFontSize = storedSize >= 12 && storedSize <= 22 ? storedSize : 16
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isDeepSeekOfficial: Bool {
        apiBaseUrl.lowercased().contains("api.deepseek.com")
    }

    var effectiveModel: String {
        let trimmed = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if thinkingEnabled && isDeepSeekOfficial && (trimmed.isEmpty || trimmed == "deepseek-chat") {
            return "deepseek-reasoner"
        }
        return trimmed.isEmpty ? "deepseek-chat" : trimmed
    }

    func applyPreset(_ preset: ProviderPreset) {
        apiProtocol = preset.apiProtocol
        apiBaseUrl = preset.baseUrl
        apiModel = preset.defaultModel
    }

    func refreshBalance() async {
        guard isDeepSeekOfficial, isConfigured else {
            deepSeekBalanceText = nil
            return
        }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            deepSeekBalanceText = try await AIClient.fetchDeepSeekBalance(
                baseUrl: apiBaseUrl,
                apiKey: apiKey
            )
        } catch {
            deepSeekBalanceText = "查询失败"
        }
    }
}
