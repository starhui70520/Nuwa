import SwiftUI
import UIKit

/// SwiftUI wrapper around PlatformAuthViewController for DeepSeek Open Platform PKCE OAuth login.
struct DeepSeekAuthSheet: UIViewControllerRepresentable {
    let onResult: (_ token: String?, _ accountLabel: String?, _ error: String?) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let authVC = PlatformAuthViewController()
        authVC.onResult = onResult
        let nav = UINavigationController(rootViewController: authVC)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

struct MigrationLaunchOptions: Identifiable, Equatable {
    let id = UUID()
    let clearSession: Bool
    let forceReExport: Bool

    static let standard = MigrationLaunchOptions(clearSession: false, forceReExport: false)
}

/// SwiftUI wrapper around MigrationWebViewController for One-Click DeepSeek history migration.
struct DeepSeekMigrationSheet: UIViewControllerRepresentable {
    var clearSession: Bool = false
    var forceReExport: Bool = false
    let onResult: (_ filePath: String?, _ fileName: String?) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let migVC = MigrationWebViewController()
        migVC.clearSessionOnStart = clearSession
        migVC.forceReExport = forceReExport
        migVC.onResult = onResult
        let nav = UINavigationController(rootViewController: migVC)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
