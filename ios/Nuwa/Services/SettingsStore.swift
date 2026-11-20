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
        static let oneClickMigrationUsed = "nuwa.oneClickMigrationUsed"
        static let thinkingEnabled = "nuwa.thinkingEnabled"
        static let searchEnabled = "nuwa.searchEnabled"
        static let ttsMuted = "nuwa.ttsMuted"
        static let hapticFeedbackEnabled = "nuwa.hapticFeedbackEnabled"
        static let ttsVoice = "nuwa.ttsVoice"
        static let speechEngine = "nuwa.speechEngine"
        static let icloudAutoBackup = "nuwa.icloudAutoBackup"
        static let location = "nuwa.location"
        static let locale = "nuwa.locale"
        static let themePreference = "nuwa.themePreference"
        static let chatFontSize = "nuwa.chatFontSize"
        static let systemPrompt = "nuwa.systemPrompt"
        static let cachedBalance = "nuwa.cachedBalance"
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

    @Published var hasUsedOneClickMigration: Bool {
        didSet { UserDefaults.standard.set(hasUsedOneClickMigration, forKey: Keys.oneClickMigrationUsed) }
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
    @Published var hapticFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled) }
    }

    @Published var ttsVoice: TtsVoiceOption {
        didSet { UserDefaults.standard.set(ttsVoice.rawValue, forKey: Keys.ttsVoice) }
    }

    @Published var speechEngine: SpeechEngineOption {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: Keys.speechEngine) }
    }

    @Published var icloudAutoBackup: Bool {
        didSet { UserDefaults.standard.set(icloudAutoBackup, forKey: Keys.icloudAutoBackup) }
    }

    @Published var location: UserLocation? {
        didSet {
            if let location, let data = try? JSONEncoder().encode(location) {
                UserDefaults.standard.set(data, forKey: Keys.location)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.location)
            }
        }
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

    @Published var accountBalance: AccountBalance?
    @Published var isLoadingBalance = false

    private var lastBalanceRefreshAt: Date?

    init() {
        let defaults = UserDefaults.standard
        let loadedToken = KeychainStore.load(account: Keys.dshTokenAccount) ?? ""
        let loadedKey = KeychainStore.load(account: Keys.apiKeyAccount) ?? ""
        dshToken = loadedToken
        apiKey = loadedKey
        dshAccountLabel = defaults.string(forKey: Keys.dshAccountLabel) ?? ""
        authMode = AuthMode(rawValue: defaults.string(forKey: Keys.authMode) ?? "")
            ?? (!loadedToken.isEmpty ? .deepseekAccount : .apiKey)
        // Default to DeepSeek Anthropic protocol + deepseek-flash matching Android v0.1.31
        apiProtocol = ApiProtocol(rawValue: defaults.string(forKey: Keys.apiProtocol) ?? "") ?? .anthropic
        apiBaseUrl = defaults.string(forKey: Keys.apiBaseUrl) ?? "https://api.deepseek.com"
        apiModel = defaults.string(forKey: Keys.apiModel) ?? "deepseek-flash"
        migrationPromptHandled = defaults.bool(forKey: Keys.migrationPromptHandled)
        hasUsedOneClickMigration = defaults.bool(forKey: Keys.oneClickMigrationUsed)
        thinkingEnabled = defaults.object(forKey: Keys.thinkingEnabled) as? Bool ?? false
        searchEnabled = defaults.object(forKey: Keys.searchEnabled) as? Bool ?? false
        ttsMuted = defaults.object(forKey: Keys.ttsMuted) as? Bool ?? true
        hapticFeedbackEnabled = defaults.bool(forKey: Keys.hapticFeedbackEnabled)
        ttsVoice = TtsVoiceOption(rawValue: defaults.string(forKey: Keys.ttsVoice) ?? "") ?? .stella
        speechEngine = SpeechEngineOption(rawValue: defaults.string(forKey: Keys.speechEngine) ?? "") ?? .auto
        icloudAutoBackup = defaults.bool(forKey: Keys.icloudAutoBackup)
        if let locData = defaults.data(forKey: Keys.location),
           let decodedLoc = try? JSONDecoder().decode(UserLocation.self, from: locData) {
            location = decodedLoc
        } else {
            location = nil
        }
        locale = AppLocale(rawValue: defaults.string(forKey: Keys.locale) ?? "") ?? .zhCN
        themePreference = ThemePreference(rawValue: defaults.string(forKey: Keys.themePreference) ?? "") ?? .system
        let storedSize = defaults.double(forKey: Keys.chatFontSize)
        chatFontSize = storedSize >= 12 && storedSize <= 22 ? storedSize : 16
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""

        if let balData = defaults.data(forKey: Keys.cachedBalance),
           let cached = try? JSONDecoder().decode(AccountBalance.self, from: balData) {
            accountBalance = cached
        }

        if hasActiveCredential && !migrationPromptHandled {
            showMigrationPrompt = true
        }
    }

    var deepSeekBalanceText: String? { accountBalance?.formatted }

    var isBalanceLow: Bool {
        guard let bal = accountBalance else { return false }
        return !bal.isAvailable || (Double(bal.totalBalance) ?? 0) <= 0
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
        isUsingDeepSeekAccount ? .anthropic : apiProtocol
    }

    var isDeepSeekOfficial: Bool {
        effectiveBaseUrl.lowercased().contains("api.deepseek.com")
    }

    var effectiveModel: String {
        if isUsingDeepSeekAccount {
            return "deepseek-flash"
        }
        let trimmed = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveProtocol == .openai && thinkingEnabled && isDeepSeekOfficial && (trimmed.isEmpty || trimmed == "deepseek-chat") {
            return "deepseek-reasoner"
        }
        return trimmed.isEmpty ? (effectiveProtocol == .anthropic ? "deepseek-flash" : "deepseek-chat") : trimmed
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
        Task { await refreshBalance(force: true) }
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
        accountBalance = nil
        UserDefaults.standard.removeObject(forKey: Keys.cachedBalance)
    }

    func signOutAll() {
        dshToken = ""
        dshAccountLabel = ""
        apiKey = ""
        authMode = .apiKey
        accountBalance = nil
        UserDefaults.standard.removeObject(forKey: Keys.cachedBalance)
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

    func refreshBalance(force: Bool = false) async {
        guard hasActiveCredential else {
            accountBalance = nil
            return
        }
        if !force, let last = lastBalanceRefreshAt, Date().timeIntervalSince(last) < 15 {
            return
        }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        lastBalanceRefreshAt = Date()
        let result = await AIClient.fetchBalance(
            secret: activeSecret,
            useAccount: isUsingDeepSeekAccount,
            baseUrl: effectiveBaseUrl,
            locale: locale
        )
        accountBalance = result
        if let result, let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Keys.cachedBalance)
        }
    }

    func schedulePostReplyBalanceRefresh() {
        Task {
            try? await Task.sleep(for: .milliseconds(2500))
            await refreshBalance(force: true)
        }
    }
}
