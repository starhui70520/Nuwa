import SwiftUI

@main
struct NuwaApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var chatStore = ChatStore()
    @StateObject private var speech = SpeechService()
    @StateObject private var updateMonitor = AppUpdateMonitor()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.hasActiveCredential {
                    ChatView(
                        chatStore: chatStore,
                        draftStore: chatStore.draftStore,
                        listStore: chatStore.listStore,
                        settings: settings,
                        speech: speech
                    )
                } else {
                    OnboardingScreenView(
                        settings: settings,
                        chatStore: chatStore
                    )
                }
            }
            .environment(\.nuwaFontScale, CGFloat(settings.chatFontSize / 16.0))
            .preferredColorScheme(settings.themePreference.colorScheme)
            .tint(Color.nuwaBrand)
            .task {
                updateMonitor.start()
                ShareSuggestionDonor.donateDefaultSuggestionsIfNeeded()
                chatStore.consumePendingAppGroupShares(settings: settings)
            }
            .onOpenURL { url in
                chatStore.handleIncomingURL(url, settings: settings)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    updateMonitor.handleForegroundActive()
                    ShareSuggestionDonor.donateDefaultSuggestionsIfNeeded()
                    chatStore.consumePendingAppGroupShares(settings: settings)
                } else if phase == .background {
                    updateMonitor.handleBackground()
                }
            }
            .alert(
                settings.locale == .enUS ? "Update Available" : "发现新版本",
                isPresented: Binding(
                    get: { updateMonitor.pendingPrompt != nil },
                    set: { if !$0 { updateMonitor.dismissPrompt() } }
                )
            ) {
                if let url = updateMonitor.pendingPrompt?.storeUrl {
                    Button(settings.locale == .enUS ? "Update Now" : "前往更新") {
                        updateMonitor.dismissPrompt()
                        openURL(url)
                    }
                }
                Button(settings.locale == .enUS ? "Later" : "稍后再说", role: .cancel) {
                    updateMonitor.dismissPrompt()
                }
            } message: {
                if let info = updateMonitor.pendingPrompt {
                    let notes = info.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                    let summary = settings.locale == .enUS
                        ? "Version v\(info.latestVersion) is available (current: v\(info.currentVersion))."
                        : "发现新版本 v\(info.latestVersion)（当前 v\(info.currentVersion)）。"
                    Text(notes.isEmpty ? summary : "\(summary)\n\(notes)")
                }
            }
        }
    }
}
