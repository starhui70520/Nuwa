import SwiftUI
import UIKit

/// SwiftUI wrapper around PlatformAuthViewController for DeepSeek Open Platform PKCE OAuth login.
struct DeepSeekAuthSheet: UIViewControllerRepresentable {
    let onResult: (_ token: String?, _ accountLabel: String?, _ error: String?) -> Void

    func makeUIViewController(context: Context) -> PlatformAuthViewController {
        let authVC = PlatformAuthViewController()
        authVC.onResult = onResult
        return authVC
    }

    func updateUIViewController(_ uiViewController: PlatformAuthViewController, context: Context) {}
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

    func makeUIViewController(context: Context) -> MigrationWebViewController {
        let migVC = MigrationWebViewController()
        migVC.clearSessionOnStart = clearSession
        migVC.forceReExport = forceReExport
        migVC.onResult = onResult
        return migVC
    }

    func updateUIViewController(_ uiViewController: MigrationWebViewController, context: Context) {}
}
