import SwiftUI

@main
struct NuwaApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var chatStore = ChatStore()
    @StateObject private var speech = SpeechService()

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
            .preferredColorScheme(settings.themePreference.colorScheme)
            .tint(Color.nuwaBrand)
        }
    }
}
