import Foundation
import SwiftUI

struct AppUpdateResult: Codable, Equatable {
    let currentVersion: String
    let buildNumber: String
    let latestVersion: String
    let hasUpdate: Bool
    let releaseNotes: String
    let storeUrl: URL?
}

/// Periodic App Store update monitor matching Android `v0.1.27` (`a268bcd`) cadence:
/// - Cold start: immediately surfaces a cached pending update (unless snoozed) and silently checks once.
/// - Foreground resume: surfaces cached update; re-checks if >= 10 minutes elapsed.
/// - Foreground timer: checks silently every 30 minutes and caches for the next entry without interrupting chat.
/// - Dismissing ("稍后再说") snoozes that version for 6 hours.
@MainActor
final class AppUpdateMonitor: ObservableObject {
    @Published var pendingPrompt: AppUpdateResult?

    private enum Keys {
        static let lastAutoCheckAt = "nuwa.update.lastAutoCheckAt"
        static let cachedUpdate = "nuwa.update.cachedPending"
        static let dismissedVersion = "nuwa.update.dismissedVersion"
        static let dismissedAt = "nuwa.update.dismissedAt"
    }

    private let pollIntervalSeconds: TimeInterval = 30 * 60
    private let resumeThrottleSeconds: TimeInterval = 10 * 60
    private let dismissSnoozeSeconds: TimeInterval = 6 * 60 * 60

    private var isChecking = false
    private var pollTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        promptCachedIfNeeded()
        Task { await checkSilently(promptOnFound: true) }
        startPollLoop()
    }

    func handleForegroundActive() {
        guard started else {
            start()
            return
        }
        promptCachedIfNeeded()
        let last = UserDefaults.standard.double(forKey: Keys.lastAutoCheckAt)
        if Date().timeIntervalSince1970 - last >= resumeThrottleSeconds {
            Task { await checkSilently(promptOnFound: true) }
        }
        startPollLoop()
    }

    func handleBackground() {
        pollTask?.cancel()
        pollTask = nil
    }

    func dismissPrompt() {
        if let version = pendingPrompt?.latestVersion {
            markDismissed(version)
        }
        pendingPrompt = nil
    }

    private func startPollLoop() {
        pollTask?.cancel()
        let interval = pollIntervalSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkSilently(promptOnFound: false)
            }
        }
    }

    private func checkSilently(promptOnFound: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await AppUpdateService.checkAppStoreUpdate()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastAutoCheckAt)
            if result.hasUpdate {
                writeCached(result)
                if promptOnFound && !isSnoozed(result.latestVersion) && pendingPrompt == nil {
                    pendingPrompt = result
                }
            } else {
                writeCached(nil)
            }
        } catch {
            // Silent check swallows transient network errors.
        }
    }

    private func promptCachedIfNeeded() {
        guard let cached = readCached(), !isSnoozed(cached.latestVersion) else { return }
        let current = AppUpdateService.currentVersion
        guard AppUpdateService.compareVersions(cached.latestVersion, current) > 0 else {
            writeCached(nil)
            return
        }
        if pendingPrompt == nil {
            pendingPrompt = AppUpdateResult(
                currentVersion: current,
                buildNumber: AppUpdateService.buildNumber,
                latestVersion: cached.latestVersion,
                hasUpdate: true,
                releaseNotes: cached.releaseNotes,
                storeUrl: cached.storeUrl
            )
        }
    }

    private func readCached() -> AppUpdateResult? {
        guard let data = UserDefaults.standard.data(forKey: Keys.cachedUpdate) else { return nil }
        return try? JSONDecoder().decode(AppUpdateResult.self, from: data)
    }

    private func writeCached(_ value: AppUpdateResult?) {
        if let value, value.hasUpdate, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Keys.cachedUpdate)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.cachedUpdate)
        }
    }

    private func isSnoozed(_ version: String) -> Bool {
        let dismissed = UserDefaults.standard.string(forKey: Keys.dismissedVersion)
        let at = UserDefaults.standard.double(forKey: Keys.dismissedAt)
        guard dismissed == version, at > 0 else { return false }
        return Date().timeIntervalSince1970 - at < dismissSnoozeSeconds
    }

    private func markDismissed(_ version: String) {
        UserDefaults.standard.set(version, forKey: Keys.dismissedVersion)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.dismissedAt)
    }
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
