import Foundation

enum ShareLinkImportError: LocalizedError {
    case invalidLink
    case expiredLink
    case networkError(String)
    case emptyConversation
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "未识别到有效链接（支持 DeepSeek 分享链接或官方数据导出 ZIP 下载链接）。"
        case .expiredLink:
            return "导出链接已失效或无权访问（DeepSeek 导出链接有时效限制，请重新导出后再试）。"
        case .networkError(let msg):
            return msg
        case .emptyConversation:
            return "该分享链接中没有可导入的对话消息。"
        case .unsupportedContent:
            return "该链接返回的内容不是有效的 DeepSeek 导出压缩包（ZIP）或分享对话。"
        }
    }
}

enum LinkImportPayload {
    case share(ChatSession)
    case archiveData(Data, fileName: String)
}

/// 1:1 port of chat-demo/src/services/chat/history/importShareLink.ts (including v0.1.34 DeepSeek export ZIP & redirect links).
enum ShareLinkImporter {
    static func extractShareId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let regex = try? NSRegularExpression(
            pattern: "(?:https?://)?(?:[a-z0-9-]+\\.)*deepseek\\.com/(?:a/chat/s|share)/([A-Za-z0-9_-]{4,64})",
            options: .caseInsensitive
        ) {
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

    static func extractHttpUrl(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'`）)】》]+", options: .caseInsensitive)
        else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let urlRange = Range(match.range, in: trimmed)
        else { return nil }
        var raw = String(trimmed[urlRange])
        while let last = raw.last, ".,;:!?。，；：！？".contains(last) {
            raw.removeLast()
        }
        return URL(string: raw)
    }

    static func importFromLink(
        input: String,
        onStage: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> LinkImportPayload {
        if let directShareId = extractShareId(from: input) {
            await onStage?("正在拉取分享对话…")
            let session = try await fetchSharedSession(shareId: directShareId)
            return .share(session)
        }

        guard let remoteURL = extractHttpUrl(from: input) else {
            throw ShareLinkImportError.invalidLink
        }

        await onStage?("正在下载链接内容…")
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 60
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let finalUrl = response.url?.absoluteString ?? remoteURL.absoluteString
        if let redirectedShareId = extractShareId(from: finalUrl) {
            await onStage?("正在拉取分享对话…")
            let session = try await fetchSharedSession(shareId: redirectedShareId)
            return .share(session)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 404 || status == 410 {
            throw ShareLinkImportError.expiredLink
        }
        guard (200...299).contains(status) else {
            throw ShareLinkImportError.networkError("链接下载失败（HTTP \(status > 0 ? "\(status)" : "网络错误")）")
        }

        let isZip = DeepSeekZipImporter.isZipData(data) || (
            data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && (data[2] == 0x03 || data[2] == 0x05)
        )
        if isZip {
            await onStage?("正在导入对话记录…")
            let name = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .archiveData(data, fileName: (name?.isEmpty == false ? name! : "deepseek_export.zip"))
        }

        if !data.isEmpty && data.count <= 512 * 1024,
           let bodyText = String(data: data, encoding: .utf8),
           let embeddedShareId = extractShareId(from: bodyText) {
            await onStage?("正在拉取分享对话…")
            let session = try await fetchSharedSession(shareId: embeddedShareId)
            return .share(session)
        }

        throw ShareLinkImportError.unsupportedContent
    }

    static func fetchSharedSession(input: String) async throws -> ChatSession {
        guard let shareId = extractShareId(from: input) else {
            throw ShareLinkImportError.invalidLink
        }
        return try await fetchSharedSession(shareId: shareId)
    }

    private static func fetchSharedSession(shareId: String) async throws -> ChatSession {
        guard let encoded = shareId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
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

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShareLinkImportError.networkError("解析分享数据失败")
        }
        let code = root["code"] as? Int
        let dataNode = root["data"] as? [String: Any]
        let bizCode = dataNode?["biz_code"] as? Int
        if code != 0 || bizCode != 0 {
            let errMsg = (dataNode?["biz_msg"] as? String)
                ?? (root["msg"] as? String)
                ?? "分享链接已失效或无法访问"
            throw ShareLinkImportError.networkError(errMsg)
        }
        guard let bizData = dataNode?["biz_data"] as? [String: Any],
              let rawMessages = bizData["messages"] as? [[String: Any]],
              !rawMessages.isEmpty
        else {
            throw ShareLinkImportError.emptyConversation
        }

        let sortedMessages = rawMessages.sorted { lhs, rhs in
            let idL = (lhs["message_id"] as? Int) ?? (lhs["id"] as? Int) ?? 0
            let idR = (rhs["message_id"] as? Int) ?? (rhs["id"] as? Int) ?? 0
            return idL < idR
        }

        let rawTitle = (bizData["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var idMap: [Int: UUID] = [:]
        var messages: [ChatMessage] = []
        var firstUserText = ""
        let now = Date()

        for item in sortedMessages {
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
        let trimmedTitle = rawTitle ?? ""
        let isGenericTitle = trimmedTitle.isEmpty
            || trimmedTitle == "Shared Conversation"
            || trimmedTitle == "来自分享的对话"
        let collapsedUserText = firstUserText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let title = isGenericTitle
            ? (collapsedUserText.isEmpty ? "分享导入的对话" : String(collapsedUserText.prefix(28)))
            : trimmedTitle
        let firstTs = messages.first?.createdAt ?? now
        let lastTs = messages.last?.createdAt ?? now

        return ChatSession(
            title: title,
            rootMessageId: rootId,
            messages: messages,
            createdAt: firstTs,
            updatedAt: max(now, lastTs)
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
