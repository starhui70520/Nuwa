import Foundation
import UIKit

enum AppLogLevel: String, Codable {
    case error
    case warn
    case info
}

struct AppLogEntry: Identifiable, Codable, Equatable {
    var id: String { "\(ts)-\(source)-\(message.prefix(24))" }
    let ts: String
    let level: AppLogLevel
    let source: String
    let message: String
    let detail: String?
}

struct AppDeviceInfo: Codable {
    let appVersion: String
    let platform: String
    let userAgent: String
    let language: String
    let screen: String
    let viewport: String
    let online: Bool
    let timezone: String
    let apiProtocol: String
    let authMode: String
}

struct IssueReportResult: Decodable {
    let code: String
    let createdAt: String?
}

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    static let issueTypeOptions: [String] = [
        "页面白屏或闪退",
        "对话报错 / 无法回复",
        "语音或朗读异常",
        "一键导入记录失败",
        "文件 / 图片上传失败",
        "界面显示或排版异常",
        "其他问题",
    ]

    private let storageKey = "nuwa:error-logs-v1"
    private let maxLogs = 150
    private let reportAPIURL = URL(string: "https://dl.rankchord.com/api/reports")!

    @Published private(set) var logs: [AppLogEntry] = []

    private init() {
        load()
    }

    func record(_ level: AppLogLevel, source: String, message: String, detail: String? = nil) {
        let entry = AppLogEntry(
            ts: ISO8601DateFormatter().string(from: Date()),
            level: level,
            source: Self.sanitize(source, maxLen: 80),
            message: Self.sanitize(message, maxLen: 800),
            detail: detail.map { Self.sanitize($0, maxLen: 2500) }
        )
        logs.append(entry)
        if logs.count > maxLogs {
            logs = Array(logs.suffix(maxLogs))
        }
        save()
    }

    func clear() {
        logs = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func collectDeviceInfo(settings: SettingsStore) -> AppDeviceInfo {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let screenStr = "\(Int(bounds.width))x\(Int(bounds.height))@\(String(format: "%.2f", scale))"
        let device = UIDevice.current
        let ua = "Nuwa-iOS/\(AppUpdateService.currentVersion) (\(device.model); iOS \(device.systemVersion))"
        return AppDeviceInfo(
            appVersion: AppUpdateService.currentVersion,
            platform: "ios",
            userAgent: ua,
            language: settings.locale.rawValue,
            screen: screenStr,
            viewport: "\(Int(bounds.width))x\(Int(bounds.height))",
            online: true,
            timezone: TimeZone.current.identifier,
            apiProtocol: settings.effectiveProtocol.rawValue,
            authMode: settings.authMode.rawValue
        )
    }

    func submitReport(
        issueType: String,
        description: String,
        contact: String,
        includeLogs: Bool,
        settings: SettingsStore
    ) async throws -> IssueReportResult {
        struct Payload: Encodable {
            let issueType: String
            let description: String
            let contact: String?
            let deviceInfo: AppDeviceInfo
            let logs: [AppLogEntry]
        }

        let trimmedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Payload(
            issueType: issueType.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: trimmedContact.isEmpty ? nil : trimmedContact,
            deviceInfo: collectDeviceInfo(settings: settings),
            logs: includeLogs ? logs : []
        )

        var request = URLRequest(url: reportAPIURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AppLogStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "上报失败：无效响应"])
        }
        if !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(
                domain: "AppLogStore",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: msg ?? "上报失败（HTTP \(http.statusCode)）"]
            )
        }
        let decoded = try JSONDecoder().decode(IssueReportResult.self, from: data)
        return decoded
    }

    static func sanitize(_ input: String, maxLen: Int) -> String {
        var result = input
        let patterns: [(String, String)] = [
            ("sk-[a-zA-Z0-9_-]{8,}", "sk-***"),
            ("chd_[a-zA-Z0-9_-]{8,}", "chd_***"),
            ("(?i)Bearer\\s+[a-zA-Z0-9._-]{8,}", "Bearer ***"),
            ("(?i)(x-api-key|x-dsh-auth-token|apiKey|dshToken)\\s*[:=]\\s*[\"']?[^\\s\"',}]+", "$1: ***"),
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        if result.count > maxLen {
            return String(result.prefix(maxLen)) + "…"
        }
        return result
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppLogEntry].self, from: data)
        else { return }
        logs = Array(decoded.suffix(maxLogs))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(logs.suffix(maxLogs))) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
