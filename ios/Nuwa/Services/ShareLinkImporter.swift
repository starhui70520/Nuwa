import Foundation

enum ShareLinkImportError: LocalizedError {
    case invalidLink
    case networkError(String)
    case emptyConversation

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "未识别到有效的 DeepSeek 分享链接或分享 ID。"
        case .networkError(let msg):
            return "拉取分享内容失败：\(msg)"
        case .emptyConversation:
            return "该分享链接中没有可导入的对话消息。"
        }
    }
}

/// 1:1 port of chat-demo/src/services/chat/history/importShareLink.ts
enum ShareLinkImporter {
    static func extractShareId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let regex = try? NSRegularExpression(pattern: "(?:https?://)?chat\\.deepseek\\.com/share/([A-Za-z0-9_-]{4,64})", options: .caseInsensitive) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.numberOfRanges > 1,
               let idRange = Range(match.range(at: 1), in: trimmed) {
                return String(trimmed[idRange])
            }
        }
        if trimmed.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    static func fetchSharedSession(input: String) async throws -> ChatSession {
        guard let shareId = extractShareId(from: input),
              let encoded = shareId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://chat.deepseek.com/api/v0/share/content?share_id=\(encoded)")
        else {
            throw ShareLinkImportError.invalidLink
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ShareLinkImportError.networkError("HTTP \(code)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let bizData = dataNode["biz_data"] as? [String: Any],
              let rawMessages = bizData["messages"] as? [[String: Any]],
              !rawMessages.isEmpty
        else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String) ?? "分享链接可能已过期"
            throw ShareLinkImportError.networkError(msg)
        }

        let rawTitle = (bizData["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var idMap: [Int: UUID] = [:]
        var messages: [ChatMessage] = []
        var firstUserText = ""
        let now = Date()

        for item in rawMessages {
            let numId = (item["message_id"] as? Int) ?? (item["id"] as? Int)
            guard let numId else { continue }
            let localId = UUID()
            idMap[numId] = localId
            let parentId = (item["parent_id"] as? Int).flatMap { idMap[$0] }
            let insertedDate = parseDate(item["inserted_at"], fallback: now)
            let roleStr = (item["role"] as? String ?? "").uppercased()
            let fragments = item["fragments"] as? [[String: Any]] ?? []

            if roleStr == "USER" {
                let text = fragments
                    .filter { ($0["type"] as? String) == "REQUEST" }
                    .compactMap { $0["content"] as? String }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if firstUserText.isEmpty && !text.isEmpty {
                    firstUserText = text
                }
                messages.append(
                    ChatMessage(
                        id: localId,
                        parentId: parentId,
                        role: .user,
                        content: text,
                        createdAt: insertedDate
                    )
                )
            } else if roleStr == "ASSISTANT" {
                var blocks: [ReplyBlock] = []
                var textParts: [String] = []
                var thinkParts: [String] = []
                var elapsedTotal: Double?

                for frag in fragments {
                    guard let content = frag["content"] as? String, !content.isEmpty else { continue }
                    let type = (frag["type"] as? String ?? "").uppercased()
                    if type == "THINK" {
                        let secs = frag["elapsed_secs"] as? Double
                        if let secs { elapsedTotal = secs }
                        thinkParts.append(content)
                        blocks.append(.thinking(id: UUID(), text: content, signature: nil, startedAt: nil, endedAt: nil, elapsedSeconds: secs))
                    } else if type == "RESPONSE" || type == "TEMPLATE_RESPONSE" {
                        textParts.append(content)
                        blocks.append(.text(id: UUID(), text: content, citations: [], isTemplate: type == "TEMPLATE_RESPONSE"))
                    }
                }
                let failed = (item["status"] as? String)?.uppercased() == "FAILED"
                messages.append(
                    ChatMessage(
                        id: localId,
                        parentId: parentId,
                        role: .assistant,
                        content: textParts.joined(separator: "\n"),
                        reasoning: thinkParts.joined(separator: "\n"),
                        thinkingSeconds: elapsedTotal,
                        blocks: blocks,
                        status: failed ? .error : .done,
                        thinkingEnabled: (item["thinking_enabled"] as? Bool) ?? false,
                        searchEnabled: (item["search_enabled"] as? Bool) ?? false,
                        createdAt: insertedDate
                    )
                )
            }
        }

        guard !messages.isEmpty else {
            throw ShareLinkImportError.emptyConversation
        }

        for idx in messages.indices {
            if let pid = messages[idx].parentId,
               let pIdx = messages.firstIndex(where: { $0.id == pid }) {
                messages[pIdx].selectedChildId = messages[idx].id
            }
        }
        let rootId = messages.first(where: { $0.parentId == nil })?.id ?? messages.first?.id
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : String(firstUserText.prefix(24))

        return ChatSession(
            title: title.isEmpty ? "分享对话" : title,
            rootMessageId: rootId,
            messages: messages,
            createdAt: messages.first?.createdAt ?? now,
            updatedAt: messages.last?.createdAt ?? now
        )
    }

    private static func parseDate(_ raw: Any?, fallback: Date) -> Date {
        if let num = raw as? Double {
            return Date(timeIntervalSince1970: num > 1e12 ? num / 1000.0 : num)
        }
        if let num = raw as? Int {
            let d = Double(num)
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000.0 : d)
        }
        if let str = raw as? String {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: str) { return d }
            if let d = ISO8601DateFormatter().date(from: str) { return d }
        }
        return fallback
    }
}
