import SwiftUI

@main
struct NuwaApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var chatStore = ChatStore()
    @StateObject private var speech = SpeechService()

    var body: some Scene {
        WindowGroup {
            ChatView(
                chatStore: chatStore,
                settings: settings,
                speech: speech
            )
            .preferredColorScheme(settings.themePreference.colorScheme)
            .tint(Color.nuwaBrand)
        }
    }
}
