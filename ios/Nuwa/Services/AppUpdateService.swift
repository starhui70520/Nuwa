import Foundation

struct AppUpdateResult: Equatable {
    let currentVersion: String
    let buildNumber: String
    let latestVersion: String
    let hasUpdate: Bool
    let releaseNotes: String
    let storeUrl: URL?
}

enum AppUpdateService {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.31"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.rankchord.nuwa"
    }

    /// Queries the official Apple App Store lookup API for iOS updates (App Store Guideline compliant).
    static func checkAppStoreUpdate() async throws -> AppUpdateResult {
        let current = currentVersion
        let build = buildNumber
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleIdentifier)&country=cn") else {
            return AppUpdateResult(
                currentVersion: current,
                buildNumber: build,
                latestVersion: current,
                hasUpdate: false,
                releaseNotes: "",
                storeUrl: nil
            )
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)

        struct LookupResponse: Decodable {
            struct Item: Decodable {
                let version: String?
                let releaseNotes: String?
                let trackViewUrl: String?
            }
            let results: [Item]
        }

        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let item = decoded.results.first, let storeVersion = item.version else {
            // App not yet publicly listed on App Store (e.g. TestFlight phase)
            return AppUpdateResult(
                currentVersion: current,
                buildNumber: build,
                latestVersion: current,
                hasUpdate: false,
                releaseNotes: "当前通过 TestFlight 分发测试，可在 TestFlight 中获取最新测试版。",
                storeUrl: URL(string: "itms-beta://")
            )
        }

        let hasUpdate = compareVersions(storeVersion, current) > 0
        return AppUpdateResult(
            currentVersion: current,
            buildNumber: build,
            latestVersion: storeVersion,
            hasUpdate: hasUpdate,
            releaseNotes: item.releaseNotes ?? "",
            storeUrl: item.trackViewUrl.flatMap(URL.init(string:))
        )
    }

    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(pa.count, pb.count)
        for i in 0..<count {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb ? 1 : -1 }
        }
        return 0
    }
}
