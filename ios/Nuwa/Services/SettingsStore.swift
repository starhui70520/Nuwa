import Foundation
import SwiftUI

enum AuthMode: String, Codable {
    case deepseekAccount = "deepseek-account"
    case apiKey = "api-key"
}

enum AppLocale: String, Codable, CaseIterable, Identifiable {
    case zhCN = "zh-CN"
    case enUS = "en-US"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zhCN: "简体中文"
        case .enUS: "English"
        }
    }
}

enum TtsVoiceOption: String, Codable, CaseIterable, Identifiable {
    case stella
    case tide

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stella: "海星（女声）"
        case .tide: "暗潮（男声）"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let apiKeyAccount = "nuwa_api_key"
        static let dshTokenAccount = "nuwa_dsh_token"
        static let authMode = "nuwa.authMode"
        static let dshAccountLabel = "nuwa.dshAccountLabel"
        static let apiProtocol = "nuwa.apiProtocol"
        static let apiBaseUrl = "nuwa.apiBaseUrl"
        static let apiModel = "nuwa.apiModel"
        static let migrationPromptHandled = "nuwa.migrationPromptHandled"
        static let thinkingEnabled = "nuwa.thinkingEnabled"
        static let searchEnabled = "nuwa.searchEnabled"
        static let ttsMuted = "nuwa.ttsMuted"
        static let ttsVoice = "nuwa.ttsVoice"
        static let locale = "nuwa.locale"
        static let themePreference = "nuwa.themePreference"
        static let chatFontSize = "nuwa.chatFontSize"
        static let systemPrompt = "nuwa.systemPrompt"
    }

    static let fontSizeOptions: [Double] = [12, 14, 16, 18, 20, 22]

    @Published var authMode: AuthMode {
        didSet { UserDefaults.standard.set(authMode.rawValue, forKey: Keys.authMode) }
    }

    @Published var dshToken: String {
        didSet { KeychainStore.save(dshToken.trimmingCharacters(in: .whitespacesAndNewlines), account: Keys.dshTokenAccount) }
    }

    @Published var dshAccountLabel: String {
        didSet { UserDefaults.standard.set(dshAccountLabel, forKey: Keys.dshAccountLabel) }
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

    @Published var migrationPromptHandled: Bool {
        didSet { UserDefaults.standard.set(migrationPromptHandled, forKey: Keys.migrationPromptHandled) }
    }

    @Published var showMigrationPrompt: Bool = false

    @Published var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: Keys.thinkingEnabled) }
    }

    @Published var searchEnabled: Bool {
        didSet { UserDefaults.standard.set(searchEnabled, forKey: Keys.searchEnabled) }
    }

    @Published var ttsMuted: Bool {
        didSet { UserDefaults.standard.set(ttsMuted, forKey: Keys.ttsMuted) }
    }

    @Published var ttsVoice: TtsVoiceOption {
        didSet { UserDefaults.standard.set(ttsVoice.rawValue, forKey: Keys.ttsVoice) }
    }

    @Published var locale: AppLocale {
        didSet { UserDefaults.standard.set(locale.rawValue, forKey: Keys.locale) }
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
        let loadedToken = KeychainStore.load(account: Keys.dshTokenAccount) ?? ""
        let loadedKey = KeychainStore.load(account: Keys.apiKeyAccount) ?? ""
        dshToken = loadedToken
        apiKey = loadedKey
        dshAccountLabel = defaults.string(forKey: Keys.dshAccountLabel) ?? ""
        authMode = AuthMode(rawValue: defaults.string(forKey: Keys.authMode) ?? "")
            ?? (!loadedToken.isEmpty ? .deepseekAccount : .apiKey)
        apiProtocol = ApiProtocol(rawValue: defaults.string(forKey: Keys.apiProtocol) ?? "") ?? .openai
        apiBaseUrl = defaults.string(forKey: Keys.apiBaseUrl) ?? "https://api.deepseek.com"
        apiModel = defaults.string(forKey: Keys.apiModel) ?? "deepseek-chat"
        migrationPromptHandled = defaults.bool(forKey: Keys.migrationPromptHandled)
        thinkingEnabled = defaults.object(forKey: Keys.thinkingEnabled) as? Bool ?? false
        searchEnabled = defaults.object(forKey: Keys.searchEnabled) as? Bool ?? false
        ttsMuted = defaults.object(forKey: Keys.ttsMuted) as? Bool ?? false
        ttsVoice = TtsVoiceOption(rawValue: defaults.string(forKey: Keys.ttsVoice) ?? "") ?? .stella
        locale = AppLocale(rawValue: defaults.string(forKey: Keys.locale) ?? "") ?? .zhCN
        themePreference = ThemePreference(rawValue: defaults.string(forKey: Keys.themePreference) ?? "") ?? .system
        let storedSize = defaults.double(forKey: Keys.chatFontSize)
        chatFontSize = storedSize >= 12 && storedSize <= 22 ? storedSize : 16
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""

        // Show migration prompt automatically on entry if authenticated and not yet handled
        if hasActiveCredential && !migrationPromptHandled {
            showMigrationPrompt = true
        }
    }

    var isUsingDeepSeekAccount: Bool {
        authMode == .deepseekAccount && !dshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeSecret: String {
        if isUsingDeepSeekAccount {
            return dshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveCredential: Bool {
        !activeSecret.isEmpty && !effectiveBaseUrl.isEmpty
    }

    var isConfigured: Bool { hasActiveCredential }

    var effectiveBaseUrl: String {
        if isUsingDeepSeekAccount {
            return "https://api.deepseek.com"
        }
        return apiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveProtocol: ApiProtocol {
        isUsingDeepSeekAccount ? .openai : apiProtocol
    }

    var isDeepSeekOfficial: Bool {
        effectiveBaseUrl.lowercased().contains("api.deepseek.com")
    }

    var effectiveModel: String {
        if isUsingDeepSeekAccount {
            return thinkingEnabled ? "deepseek-reasoner" : "deepseek-chat"
        }
        let trimmed = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if thinkingEnabled && isDeepSeekOfficial && (trimmed.isEmpty || trimmed == "deepseek-chat") {
            return "deepseek-reasoner"
        }
        return trimmed.isEmpty ? "deepseek-chat" : trimmed
    }

    var profileDisplayName: String {
        if isUsingDeepSeekAccount {
            return dshAccountLabel.isEmpty ? "DeepSeek API 账号" : dshAccountLabel
        }
        let trimmed = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "API Key" : trimmed
    }

    func completeAuthentication() {
        if !migrationPromptHandled {
            showMigrationPrompt = true
        }
        Task { await refreshBalance() }
    }

    func signInDeepSeekAccount(token: String, label: String?) {
        dshToken = token
        dshAccountLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "DeepSeek API 账号"
        authMode = .deepseekAccount
        completeAuthentication()
    }

    func signOutDeepSeekAccount() {
        dshToken = ""
        dshAccountLabel = ""
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authMode = .apiKey
        }
        deepSeekBalanceText = nil
    }

    func signOutAll() {
        dshToken = ""
        dshAccountLabel = ""
        apiKey = ""
        authMode = .apiKey
        deepSeekBalanceText = nil
    }

    func dismissMigrationPrompt() {
        migrationPromptHandled = true
        showMigrationPrompt = false
    }

    func applyPreset(_ preset: ProviderPreset) {
        apiProtocol = preset.apiProtocol
        apiBaseUrl = preset.baseUrl
        apiModel = preset.defaultModel
        authMode = .apiKey
    }

    func refreshBalance() async {
        guard isDeepSeekOfficial, hasActiveCredential else {
            deepSeekBalanceText = nil
            return
        }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            deepSeekBalanceText = try await AIClient.fetchDeepSeekBalance(
                baseUrl: effectiveBaseUrl,
                apiKey: activeSecret
            )
        } catch {
            deepSeekBalanceText = nil
        }
    }
}
