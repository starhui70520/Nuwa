import Foundation

enum AIStreamEvent {
    case blockStart(index: Int, block: ReplyBlock)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, thinking: String)
    case signatureDelta(index: Int, signature: String)
    case citationDelta(index: Int, citation: TextCitation)
    case blockStop(index: Int)
    case messageDelta(stopReason: String?, title: String?)
    case usage(inputTokens: Int?, outputTokens: Int?)
    case disablePrefix
}

enum AIClientError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case httpError(Int, String)
    case uploadFailed(String)
    case streamError(String)
    case interruptedStream
    case unsupportedImage(historyFileIds: [String], message: String)
    case tooManyImages(maxImages: Int, message: String)
    case invalidatedFiles(Set<String>, message: String)
    case decodingError

    private static func firstRegexCapture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先在设置中配置 API Key 或登录 DeepSeek 账号。"
        case .invalidURL:
            return "API 地址格式无效，请检查设置。"
        case .httpError(let code, let message):
            let clean = message
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 401 { return "API Key 无效或已过期，请检查后重试" }
            if code == 402 { return "账户余额不足，请充值后重试" }
            if code == 413 {
                return clean.isEmpty
                    ? "文件体积超过服务端限制（HTTP 413），请压缩后重试"
                    : "文件体积超过服务端限制（HTTP 413）：\(clean)"
            }
            if code == 429 { return "请求过于频繁（HTTP 429），请稍后再试" }
            if code >= 500 { return "服务器繁忙（HTTP \(code)），请稍后再试" }
            if code == 400 {
                if let limit = Self.firstRegexCapture(clean, pattern: #"User file count limit exceeded.*?limit (\d+)"#) {
                    return "已上传文件数达到上限（\(limit) 个），请清理历史文件后重试"
                }
                if let limit = Self.firstRegexCapture(clean, pattern: #"User storage quota exceeded.*?limit ([\d.]+) GB"#) {
                    return "已上传文件占用空间达到上限（\(limit)GB），请清理历史文件后重试"
                }
                if clean.range(
                    of: #"You have uploaded an (unsupported|invalid) (file|image)|The image is too large to process|password-protected|Failed to recognize the file"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil {
                    return "服务端无法解析该文件（HTTP 400）：\(clean)"
                }
            }
            return clean.isEmpty ? "请求失败（HTTP \(code)）" : "请求失败（HTTP \(code)）：\(clean)"
        case .uploadFailed(let detail):
            let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { return "附件上传失败" }
            return clean.hasPrefix("附件上传失败") || clean.hasPrefix("上传失败") ? clean : "附件上传失败：\(clean)"
        case .streamError(let message):
            return message
        case .interruptedStream:
            return "回复连接中断，请重试。"
        case .unsupportedImage(_, let message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "暂不支持解析该图片，请更换 JPG / PNG / WebP 图片后重试。" : clean
        case .tooManyImages(_, let message):
            return AIClientError.httpError(400, message).errorDescription
        case .invalidatedFiles(_, let message):
            return AIClientError.httpError(400, message).errorDescription
        case .decodingError:
            return "解析服务端响应失败。"
        }
    }

    var is32kInputLimit: Bool {
        let message: String
        switch self {
        case .httpError(_, let text), .streamError(let text): message = text
        default: return false
        }
        return message.range(of: "user input too long.*exceeds max 32768 tokens", options: [.regularExpression, .caseInsensitive]) != nil
    }

    fileprivate func invalidatedFiles(in messages: [[String: Any]]) -> AIClientError? {
        guard case .httpError(400, let message) = self,
              message.range(
                of: #"file_ids do not exist or are not created under your account|file data not found for file_id|\.source\.file_id: invalid file_id"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil
        else { return nil }
        let sentIds = Set(messages.flatMap { payload -> [String] in
            guard payload["role"] as? String == "user",
                  let blocks = payload["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { ($0["source"] as? [String: Any])?["file_id"] as? String }
        })
        let regex = try? NSRegularExpression(pattern: #"file-api-[\w-]+"#)
        let range = NSRange(message.startIndex..., in: message)
        let mentioned = Set((regex?.matches(in: message, range: range) ?? []).compactMap {
            Range($0.range, in: message).map { String(message[$0]) }
        })
        let target = mentioned.isEmpty ? sentIds : sentIds.intersection(mentioned)
        return target.isEmpty ? nil : .invalidatedFiles(target, message: message)
    }

    fileprivate func tooManyImagesLimit() -> Int? {
        guard case .httpError(_, let msg) = self,
              let regex = try? NSRegularExpression(pattern: "Too many images:\\s*max\\s+(\\d+)\\s+images", options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(msg.startIndex..., in: msg)
        guard let m = regex.firstMatch(in: msg, range: range),
              m.numberOfRanges >= 2,
              let r1 = Range(m.range(at: 1), in: msg),
              let limit = Int(msg[r1]),
              limit > 0
        else { return nil }
        return limit
    }

    fileprivate func unsupportedImageIndices() -> (messageIndex: Int, blockIndex: Int)? {
        guard case .httpError(400, let msg) = self,
              let regex = try? NSRegularExpression(
                pattern: "messages\\.(\\d+)\\.content\\.(\\d+):.*(?:unsupported image|invalid image|image is too large|too large to process)",
                options: [.caseInsensitive]
              )
        else { return nil }
        let range = NSRange(msg.startIndex..., in: msg)
        guard let m = regex.firstMatch(in: msg, range: range),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: msg),
              let r2 = Range(m.range(at: 2), in: msg),
              let mi = Int(msg[r1]),
              let bi = Int(msg[r2])
        else { return nil }
        return (mi, bi)
    }
}

enum AIClient {
    static let deepSeekOrigin = "https://api.deepseek.com"
    static let defaultSystemPrompt = "该助手为DeepSeek，由深度求索公司创造。"
    static let filesBetaHeader = "files-api-2025-04-14"
    static let maxRequestImages = 600

    static func normalizeOrigin(_ rawBaseUrl: String) -> String {
        let trimmed = rawBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return deepSeekOrigin }
        if let range = trimmed.range(of: "/(v1|anthropic(?:/v1)?)$", options: [.regularExpression, .caseInsensitive]) {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    static func resolveOpenAIEndpoint(_ rawBaseUrl: String, endpoint: String) -> URL? {
        let trimmed = rawBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            return URL(string: "\(deepSeekOrigin)/v1/\(endpoint)")
        }
        if trimmed.hasSuffix("/chat/completions") {
            if endpoint == "chat/completions" {
                return URL(string: trimmed)
            }
            let base = String(trimmed.dropLast("/chat/completions".count))
            return URL(string: "\(base)/\(endpoint)")
        }
        if let parsed = URL(string: trimmed) {
            let path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty {
                return URL(string: "\(trimmed)/v1/\(endpoint)")
            }
            return URL(string: "\(trimmed)/\(endpoint)")
        }
        return URL(string: "\(trimmed)/\(endpoint)")
    }

    static func resolveAnthropicEndpoint(_ rawBaseUrl: String, useAccount: Bool, path: String) -> URL? {
        if useAccount {
            return URL(string: "\(deepSeekOrigin)/anthropic/v1/\(path)")
        }
        let trimmed = rawBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.lowercased().contains("api.anthropic.com") {
            let origin = normalizeOrigin(trimmed)
            return URL(string: "\(origin)/v1/\(path)")
        }
        let origin = normalizeOrigin(trimmed)
        return URL(string: "\(origin)/anthropic/v1/\(path)")
    }

    // MARK: - Verify API Key (1:1 client.ts verifyApiKey)

    static func verifyApiKey(apiKey: String, apiProtocol: ApiProtocol, baseUrl: String) async throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw AIClientError.missingConfiguration }
        guard cleanKey.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw AIClientError.streamError("API Key 包含无效字符或空格，请仅粘贴纯英文与数字密钥。")
        }
        let url: URL?
        if apiProtocol == .openai {
            url = resolveOpenAIEndpoint(baseUrl, endpoint: "models")
        } else {
            url = URL(string: "\(normalizeOrigin(baseUrl))/models")
        }
        guard let targetURL = url else { throw AIClientError.invalidURL }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        if (200...299).contains(http.statusCode) { return }
        if apiProtocol == .openai && (http.statusCode == 404 || http.statusCode == 405) {
            return
        }
        let msg = extractErrorMessage(from: data)
        throw AIClientError.httpError(http.statusCode, msg)
    }

    // MARK: - Files API Upload (1:1 client.ts uploadFile)

    static func uploadFile(
        data: Data,
        fileName: String,
        mimeType: String,
        purpose: String?,
        secret: String,
        useAccount: Bool,
        baseUrl: String
    ) async throws -> String {
        guard let url = resolveAnthropicEndpoint(baseUrl, useAccount: useAccount, path: "files") else {
            throw AIClientError.invalidURL
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        if let purpose {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(purpose)\r\n".data(using: .utf8)!)
        }

        let safeMime = mimeType.isEmpty ? "application/octet-stream" : mimeType
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(safeMime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(filesBetaHeader, forHTTPHeaderField: "anthropic-beta")
        if useAccount {
            request.setValue(secret, forHTTPHeaderField: "x-dsh-auth-token")
        } else {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = body

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await URLSession.shared.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            await AppLogStore.shared.record(.error, source: "api.upload", message: "POST /files network error", detail: error.localizedDescription)
            throw AIClientError.uploadFailed("网络连接异常（\(error.localizedDescription)）")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = extractErrorMessage(from: respData)
            await AppLogStore.shared.record(.error, source: "api.upload", message: "POST /files -> HTTP \(http.statusCode)", detail: msg)
            throw AIClientError.httpError(http.statusCode, msg)
        }
        if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let id = obj["id"] as? String, !id.isEmpty {
            return id
        }
        throw AIClientError.decodingError
    }

    // MARK: - Multi-Provider Balance Query (1:1 balance.ts)

    static func fetchBalance(
        secret: String,
        useAccount: Bool,
        baseUrl: String,
        locale: AppLocale
    ) async -> AccountBalance? {
        guard !secret.isEmpty else { return nil }
        let origin = useAccount ? deepSeekOrigin : normalizeOrigin(baseUrl)

        if useAccount {
            guard let url = URL(string: "\(deepSeekOrigin)/user/balance") else { return nil }
            if let payload = await fetchJSON(url: url, headers: ["x-dsh-auth-token": secret]) {
                return parseDeepSeekBalance(payload, locale: locale)
            }
            return nil
        }

        let authHeaders = ["Authorization": "Bearer \(secret)"]

        if let dsURL = URL(string: "\(origin)/user/balance"),
           let payload = await fetchJSON(url: dsURL, headers: authHeaders),
           let bal = parseDeepSeekBalance(payload, locale: locale) {
            return bal
        }

        let lower = origin.lowercased()

        if lower.contains("openrouter.ai"),
           let url = URL(string: "\(origin)/api/v1/credits"),
           let payload = await fetchJSON(url: url, headers: authHeaders) as? [String: Any] {
            let node = (payload["data"] as? [String: Any]) ?? payload
            if let total = node["total_credits"] as? Double,
               let used = node["total_usage"] as? Double {
                let remaining = total - used
                return buildBalance(currency: "USD", numeric: remaining, isAvailable: remaining > 0)
            }
            return nil
        }

        if lower.contains("siliconflow"),
           let url = URL(string: "\(origin)/v1/user/info"),
           let payload = await fetchJSON(url: url, headers: authHeaders) as? [String: Any] {
            let node = (payload["data"] as? [String: Any]) ?? payload
            if let str = node["totalBalance"] as? String, let num = Double(str) {
                return buildBalance(currency: "CNY", numeric: num, isAvailable: num > 0)
            }
            if let num = node["totalBalance"] as? Double {
                return buildBalance(currency: "CNY", numeric: num, isAvailable: num > 0)
            }
            return nil
        }

        if let subURL = URL(string: "\(origin)/v1/dashboard/billing/subscription"),
           let sub = await fetchJSON(url: subURL, headers: authHeaders) as? [String: Any],
           let hardLimit = sub["hard_limit_usd"] as? Double,
           hardLimit > 0 && hardLimit < 10_000_000 {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let start = df.string(from: Date().addingTimeInterval(-99 * 86400))
            let end = df.string(from: Date().addingTimeInterval(86400))
            if let usageURL = URL(string: "\(origin)/v1/dashboard/billing/usage?start_date=\(start)&end_date=\(end)"),
               let usage = await fetchJSON(url: usageURL, headers: authHeaders) as? [String: Any],
               let totalUsage = usage["total_usage"] as? Double {
                let remaining = hardLimit - totalUsage / 100.0
                return buildBalance(currency: "USD", numeric: remaining, isAvailable: remaining > 0)
            }
        }
        return nil
    }

    private static func fetchJSON(url: URL, headers: [String: String]) async -> Any? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseDeepSeekBalance(_ payload: Any, locale: AppLocale) -> AccountBalance? {
        guard let dict = payload as? [String: Any],
              let infos = dict["balance_infos"] as? [[String: Any]]
        else { return nil }

        struct Candidate { let currency: String; let numeric: Double }
        let candidates: [Candidate] = infos.compactMap { item in
            guard let currency = item["currency"] as? String else { return nil }
            let num: Double?
            if let s = item["total_balance"] as? String { num = Double(s.trimmingCharacters(in: .whitespaces)) }
            else if let d = item["total_balance"] as? Double { num = d }
            else { num = nil }
            guard let value = num, value.isFinite else { return nil }
            return Candidate(currency: currency, numeric: value)
        }
        guard !candidates.isEmpty else { return nil }
        let preferred = locale == .zhCN ? "CNY" : "USD"
        let positive = candidates.filter { $0.numeric > 0 }
        let pool = positive.isEmpty ? candidates : positive
        guard let chosen = pool.first(where: { $0.currency.uppercased() == preferred }) ?? pool.first else {
            return nil
        }
        let isAvailable = (dict["is_available"] as? Bool) ?? (chosen.numeric > 0)
        return buildBalance(currency: chosen.currency, numeric: chosen.numeric, isAvailable: isAvailable)
    }

    private static func buildBalance(currency: String, numeric: Double, isAvailable: Bool) -> AccountBalance {
        let amount: String
        if numeric != 0 && abs(numeric) < 0.01 {
            amount = String(format: "%.4f", numeric)
        } else {
            amount = String(format: "%.2f", numeric)
        }
        let upper = currency.uppercased()
        let formatted: String
        switch upper {
        case "CNY", "RMB": formatted = "¥\(amount)"
        case "USD": formatted = "$\(amount)"
        case "EUR": formatted = "€\(amount)"
        default: formatted = "\(upper) \(amount)"
        }
        return AccountBalance(currency: upper, totalBalance: amount, formatted: formatted, isAvailable: isAvailable)
    }

    // MARK: - Streaming Chat (Anthropic + DeepSeek Tools/Thinking + OpenAI Compatible)

    struct StreamParams {
        let history: [ChatMessage]
        let compactions: [CompactionSpan]?
        let question: ChatMessage
        let prefixReply: ChatMessage?
        let useAccount: Bool
        let apiProtocol: ApiProtocol
        let baseUrl: String
        let secret: String
        let model: String
        let customSystemPrompt: String
        let thinkingEnabled: Bool
        let searchEnabled: Bool
        let wantsTitle: Bool
        let latestReminder: String?
        let omitExtendedFor1M: Bool
        let rejectedFileIds: Set<String>
        let imageCap: Int
    }

    static func generateCompactionSummary(
        promptText: String,
        systemPrompt: String,
        useAccount: Bool,
        apiProtocol: ApiProtocol,
        baseUrl: String,
        secret: String,
        model: String
    ) async throws -> String {
        let params = StreamParams(
            history: [],
            compactions: nil,
            question: ChatMessage(role: .user, content: promptText),
            prefixReply: nil,
            useAccount: useAccount,
            apiProtocol: apiProtocol,
            baseUrl: baseUrl,
            secret: secret,
            model: model,
            customSystemPrompt: systemPrompt,
            thinkingEnabled: false,
            searchEnabled: false,
            wantsTitle: false,
            latestReminder: nil,
            omitExtendedFor1M: true,
            rejectedFileIds: [],
            imageCap: 0
        )
        var rawSummary = ""
        for try await event in streamChat(params) {
            try Task.checkCancellation()
            switch event {
            case .blockStart(_, let block):
                if case .text(_, let text, _, _) = block, !text.isEmpty {
                    rawSummary += text
                }
            case .textDelta(_, let text):
                rawSummary += text
            default:
                break
            }
        }
        return rawSummary
    }

    static func streamChat(_ params: StreamParams) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !params.secret.isEmpty else {
                        throw AIClientError.missingConfiguration
                    }
                    if !params.useAccount && params.apiProtocol == .openai {
                        try await streamOpenAI(params, continuation: continuation)
                    } else {
                        try await streamAnthropic(params, continuation: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    await AppLogStore.shared.record(.error, source: "api.stream", message: error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func contextRounds(_ history: [ChatMessage]) -> [(question: ChatMessage, reply: ChatMessage)] {
        history.indices.dropLast().compactMap { index in
            let question = history[index]
            let reply = history[index + 1]
            guard question.role == .user, reply.role == .assistant,
                  reply.status == .done || reply.status == .stopped,
                  reply.stopReason != "refusal", !reply.fullTextContent.isEmpty,
                  !reply.blocks.contains(where: {
                      if case .text(_, _, _, let isTemplate) = $0 { return isTemplate }
                      return false
                  })
            else { return nil }
            return (question, reply)
        }
    }

    private static func streamAnthropic(
        _ params: StreamParams,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = resolveAnthropicEndpoint(params.baseUrl, useAccount: params.useAccount, path: "messages") else {
            throw AIClientError.invalidURL
        }

        let host = url.host?.lowercased() ?? ""
        let isDeepSeekTarget = params.useAccount || host == "deepseek.com" || host.hasSuffix(".deepseek.com")
        let systemPrompt = params.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (isDeepSeekTarget ? defaultSystemPrompt : "")
            : params.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        var payloadMessages: [[String: Any]] = []
        var hasAnyFile = false
        var previousReminder: String?

        func appendReminder(_ reminder: String?) {
            guard isDeepSeekTarget, let reminder, !reminder.isEmpty else { return }
            let normalized = LocationCatalog.normalizeLatestReminder(reminder)
            guard normalized != previousReminder else { return }
            payloadMessages.append(["role": "latest_reminder", "content": normalized])
            previousReminder = normalized
        }

        let projected = ContextCompaction.projectContextItems(history: params.history, compactions: params.compactions)
        for item in projected {
            switch item {
            case .compaction(let span):
                let pair = ContextCompaction.toCompactionMessagePair(span)
                payloadMessages.append(["role": "user", "content": pair.userText])
                payloadMessages.append(["role": "assistant", "content": [["type": "text", "text": pair.assistantText]]])

            case .round(let question, let reply):
                var effectiveQuestion = question
                if let recalledPrefix = reply.recalledMemory?.blockText, !recalledPrefix.isEmpty {
                    effectiveQuestion.content = effectiveQuestion.content.isEmpty
                        ? recalledPrefix
                        : "\(recalledPrefix)\n\n\(effectiveQuestion.content)"
                }
                guard let (message, hasFile) = buildAnthropicUserMessage(effectiveQuestion, rejectedFileIds: params.rejectedFileIds)
                else { continue }
                let blocks = buildAnthropicAssistantBlocks(reply, includeReadLinks: isDeepSeekTarget)
                guard !blocks.isEmpty else { continue }
                hasAnyFile = hasAnyFile || hasFile
                appendReminder(reply.latestReminder)
                payloadMessages.append(message)
                payloadMessages.append(["role": "assistant", "content": blocks])
            }
        }

        appendReminder(params.latestReminder)
        let (qObj, qHasFile) = buildAnthropicUserMessage(params.question, rejectedFileIds: [])
            ?? (["role": "user", "content": params.question.content], false)
        hasAnyFile = hasAnyFile || qHasFile
        payloadMessages.append(qObj)

        if let prefix = params.prefixReply, prefix.canContinueReply {
            let prefixBlocks = buildAnthropicAssistantBlocks(prefix, isPrefix: true, thinking: params.thinkingEnabled)
            if prefixBlocks.contains(where: {
                let text = ($0["text"] ?? $0["thinking"]) as? String ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                payloadMessages.append(["role": "assistant", "content": prefixBlocks])
            }
        }

        payloadMessages = limitRequestImages(payloadMessages, maxImages: params.imageCap)
        hasAnyFile = payloadMessages.contains { msg in
            guard msg["role"] as? String == "user",
                  let blocks = msg["content"] as? [[String: Any]] else { return false }
            return blocks.contains { block in
                let kind = block["type"] as? String
                return kind == "image" || kind == "document"
            }
        }

        var body: [String: Any] = [
            "model": params.model,
            "messages": payloadMessages,
            "stream": true,
        ]
        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        if isDeepSeekTarget {
            body["thinking"] = ["type": params.thinkingEnabled ? "enabled" : "disabled"]
            let hasDocWithoutSearch = !params.searchEnabled
                && params.question.files.contains(where: { !$0.isImage })
                && params.question.content.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) == nil
            let omitExtended = params.omitExtendedFor1M || hasDocWithoutSearch
            body["safety_check"] = ["level": omitExtended ? "low" : "high"]
            if !omitExtended {
                var tools: [[String: String]] = [
                    ["type": "deepseek_read_url", "name": "deepseek_read_url"],
                ]
                if params.searchEnabled {
                    tools.append(["type": "deepseek_web_search", "name": "deepseek_web_search"])
                }
                body["tools"] = tools
                if params.wantsTitle {
                    body["title"] = ["enabled": true]
                }
            }
        } else {
            body["max_tokens"] = 4096
            if params.thinkingEnabled {
                body["thinking"] = ["type": "enabled", "budget_tokens": 2048]
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if params.useAccount {
            request.setValue(params.secret, forHTTPHeaderField: "x-dsh-auth-token")
        } else {
            request.setValue(params.secret, forHTTPHeaderField: "x-api-key")
            if !isDeepSeekTarget {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }
        if hasAnyFile {
            request.setValue(filesBetaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        if !(200...299).contains(http.statusCode) {
            let errorText = try await collectErrorText(from: bytes)
            let error = AIClientError.httpError(http.statusCode, errorText)
            if let reportedCap = error.tooManyImagesLimit() {
                throw AIClientError.tooManyImages(maxImages: reportedCap, message: errorText)
            }
            if let (messageIndex, blockIndex) = error.unsupportedImageIndices() {
                let resolved = resolveBadHistoryImageIds(
                    in: payloadMessages,
                    messageIndex: messageIndex,
                    blockIndex: blockIndex,
                    alreadyRejected: params.rejectedFileIds
                )
                if !resolved.ids.isEmpty {
                    throw AIClientError.unsupportedImage(historyFileIds: resolved.ids, message: errorText)
                }
                if resolved.isCurrentTurn {
                    throw AIClientError.unsupportedImage(historyFileIds: [], message: errorText)
                }
            }
            throw error.invalidatedFiles(in: payloadMessages) ?? error
        }
        guard isEventStream(http) else {
            throw AIClientError.streamError("服务端没有返回流式回复。")
        }

        var currentEventName = ""
        var sawStopReason = false
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                currentEventName = ""
                continue
            }
            if line.hasPrefix("event:") {
                currentEventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if jsonStr == "[DONE]" { break }

            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                if currentEventName == "error" {
                    throw AIClientError.streamError(jsonStr)
                }
                continue
            }

            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw AIClientError.streamError(msg)
            }
            if currentEventName == "error" {
                throw AIClientError.streamError(jsonStr)
            }

            let type = obj["type"] as? String ?? ""
            switch type {
            case "message_start":
                if let messageObj = obj["message"] as? [String: Any],
                   let usageObj = messageObj["usage"] as? [String: Any] {
                    let inputTokens = usageObj["input_tokens"] as? Int
                    let outputTokens = usageObj["output_tokens"] as? Int
                    if inputTokens != nil || outputTokens != nil {
                        continuation.yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                    }
                }

            case "content_block_start":
                guard let idx = obj["index"] as? Int,
                      let blockDict = obj["content_block"] as? [String: Any]
                else { continue }
                if let parsedBlock = parseAnthropicStartBlock(blockDict) {
                    continuation.yield(.blockStart(index: idx, block: parsedBlock))
                } else if (blockDict["type"] as? String) == "tool_use" {
                    continuation.yield(.disablePrefix)
                }

            case "content_block_delta":
                guard let idx = obj["index"] as? Int,
                      let delta = obj["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String
                else { continue }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        continuation.yield(.textDelta(index: idx, text: text))
                    }
                case "thinking_delta":
                    if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                        continuation.yield(.thinkingDelta(index: idx, thinking: thinking))
                    }
                case "signature_delta":
                    if let sig = delta["signature"] as? String, !sig.isEmpty {
                        continuation.yield(.signatureDelta(index: idx, signature: sig))
                    }
                case "citations_delta":
                    if let cite = delta["citation"] as? [String: Any],
                       let url = cite["url"] as? String {
                        continuation.yield(.citationDelta(
                            index: idx,
                            citation: TextCitation(
                                url: url,
                                title: cite["title"] as? String,
                                citedText: cite["cited_text"] as? String
                            )
                        ))
                    }
                default:
                    break
                }

            case "content_block_stop":
                if let idx = obj["index"] as? Int {
                    continuation.yield(.blockStop(index: idx))
                }

            case "message_delta":
                if let usageObj = obj["usage"] as? [String: Any] {
                    let inputTokens = usageObj["input_tokens"] as? Int
                    let outputTokens = usageObj["output_tokens"] as? Int
                    if inputTokens != nil || outputTokens != nil {
                        continuation.yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                    }
                }
                if let delta = obj["delta"] as? [String: Any] {
                    let stopReason = delta["stop_reason"] as? String
                    if let stopReason, !stopReason.isEmpty { sawStopReason = true }
                    let title = delta["title"] as? String
                    continuation.yield(.messageDelta(stopReason: stopReason, title: title))
                }

            case "message_stop":
                return

            default:
                break
            }
        }
        if !sawStopReason { throw AIClientError.interruptedStream }
    }

    /// Keeps at most `maxImages` image blocks walking backwards from the latest message (never mutating local history).
    private static func limitRequestImages(_ messages: [[String: Any]], maxImages: Int) -> [[String: Any]] {
        var remaining = max(0, maxImages)
        var changed = false
        var result = messages
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[i]
            guard message["role"] as? String == "user",
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }
            var kept: [[String: Any]] = []
            var droppedInMessage = false
            for j in stride(from: blocks.count - 1, through: 0, by: -1) {
                let block = blocks[j]
                if block["type"] as? String == "image" {
                    if remaining > 0 {
                        remaining -= 1
                        kept.append(block)
                    } else {
                        droppedInMessage = true
                        changed = true
                    }
                } else {
                    kept.append(block)
                }
            }
            if droppedInMessage {
                kept.reverse()
                var updated = message
                updated["content"] = kept.isEmpty ? [["type": "text", "text": "[图片]"]] : kept
                result[i] = updated
            }
        }
        return changed ? result : messages
    }

    /// Resolves server-rejected historical image `file_id`s from `messages.{N}.content.{M}`,
    /// tolerating `latest_reminder` index offsets and content block shifts (matching Android v0.1.34).
    private static func resolveBadHistoryImageIds(
        in payloadMessages: [[String: Any]],
        messageIndex: Int,
        blockIndex: Int,
        alreadyRejected: Set<String>
    ) -> (ids: [String], isCurrentTurn: Bool) {
        let lastUserIndex = payloadMessages.lastIndex { ($0["role"] as? String) == "user" }
        let nonReminderIndices = payloadMessages.indices.filter {
            (payloadMessages[$0]["role"] as? String) != "latest_reminder"
        }
        var candidateIndices: [Int] = []
        if nonReminderIndices.indices.contains(messageIndex) {
            let mapped = nonReminderIndices[messageIndex]
            if mapped != messageIndex {
                candidateIndices.append(mapped)
            }
        }
        if payloadMessages.indices.contains(messageIndex) {
            candidateIndices.append(messageIndex)
        }

        func imageFileId(_ block: [String: Any]) -> String? {
            guard block["type"] as? String == "image",
                  let source = block["source"] as? [String: Any],
                  let fid = source["file_id"] as? String,
                  !fid.isEmpty
            else { return nil }
            return fid
        }

        for cIdx in candidateIndices {
            let msg = payloadMessages[cIdx]
            guard msg["role"] as? String == "user",
                  let blocks = msg["content"] as? [[String: Any]]
            else { continue }
            if cIdx == lastUserIndex {
                return ([], true)
            }
            for idx in [blockIndex, blockIndex - 1] where blocks.indices.contains(idx) {
                if let fid = imageFileId(blocks[idx]), !alreadyRejected.contains(fid) {
                    return ([fid], false)
                }
            }
            let imageBlocks = blocks.filter { ($0["type"] as? String) == "image" }
            if imageBlocks.indices.contains(blockIndex),
               let fid = imageFileId(imageBlocks[blockIndex]),
               !alreadyRejected.contains(fid) {
                return ([fid], false)
            }
        }

        for cIdx in candidateIndices {
            guard cIdx != lastUserIndex else { continue }
            let msg = payloadMessages[cIdx]
            guard msg["role"] as? String == "user",
                  let blocks = msg["content"] as? [[String: Any]]
            else { continue }
            let ids = blocks.compactMap { block -> String? in
                guard let fid = imageFileId(block), !alreadyRejected.contains(fid) else { return nil }
                return fid
            }
            if !ids.isEmpty {
                return (ids, false)
            }
        }

        return ([], false)
    }

    private static func buildAnthropicUserMessage(_ message: ChatMessage, rejectedFileIds: Set<String>) -> ([String: Any], Bool)? {
        let uploadedFiles = message.files.filter { file in
            guard let fid = file.serverId else { return false }
            return !(file.isImage && rejectedFileIds.contains(fid))
        }
        guard !uploadedFiles.isEmpty else {
            let hasRejectedImage = message.files.contains {
                guard $0.isImage, let id = $0.serverId else { return false }
                return rejectedFileIds.contains(id)
            }
            guard !message.content.isEmpty || hasRejectedImage else { return nil }
            let text = message.content.isEmpty ? "[图片]" : message.content
            return (["role": "user", "content": text], false)
        }
        var blocks: [[String: Any]] = uploadedFiles.compactMap { file in
            guard let fid = file.serverId else { return nil }
            return [
                "type": file.isImage ? "image" : "document",
                "source": ["type": "file", "file_id": fid],
            ]
        }
        if !message.content.isEmpty {
            blocks.append(["type": "text", "text": message.content])
        }
        return (["role": "user", "content": blocks], true)
    }

    private static func buildAnthropicAssistantBlocks(
        _ message: ChatMessage, isPrefix: Bool = false, thinking: Bool = false, includeReadLinks: Bool = false
    ) -> [[String: Any]] {
        if message.blocks.isEmpty, !message.content.isEmpty {
            return [["type": "text", "text": message.content]]
        }
        var blocks: [[String: Any]] = []
        var text = ""
        func flushText() {
            guard !text.isEmpty else { return }
            let separator = blocks.last?["type"] as? String == "text" ? "\n\n" : ""
            blocks.append(["type": "text", "text": separator + text])
            text = ""
        }
        let unsignedLinks = includeReadLinks ? Set(message.blocks.compactMap { block -> String? in
            guard case .webFetchResult(_, let toolUseId, "read_link", let result, let signature) = block,
                  result.errorCode == nil, signature?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            else { return nil }
            return toolUseId
        }) : []
        for block in message.blocks {
            switch block {
            case .text(_, let value, _, _):
                text += value
            case .thinking(_, let value, let signature, _, _, _):
                if isPrefix && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                flushText()
                if isPrefix && thinking {
                    blocks.append(["type": "thinking", "thinking": value, "signature": signature ?? ""])
                }
            case .serverToolUse(_, let info):
                flushText()
                if includeReadLinks, info.kind == "read_link", !unsignedLinks.contains(info.id), let url = info.url {
                    blocks.append(["type": "server_tool_use", "kind": "read_link", "id": info.id,
                                   "name": info.name, "input": ["action": info.action, "url": url]])
                }
            case .webFetchResult(_, let toolUseId, let kind, let result, let signature):
                flushText()
                guard includeReadLinks, kind == "read_link", !unsignedLinks.contains(toolUseId) else { continue }
                var content: [String: Any]
                if let code = result.errorCode {
                    content = ["type": "web_fetch_tool_result_error", "error_code": code]
                } else if let url = result.url {
                    let document: [String: Any] = [
                        "type": "document", "title": result.title as Any? ?? NSNull(),
                        "source": ["type": "text", "media_type": "text/plain", "data": result.documentText ?? ""],
                    ]
                    content = ["type": "web_fetch_result", "url": url, "content": document,
                               "published_at": result.publishedAt as Any? ?? NSNull()]
                } else {
                    continue
                }
                var resultBlock: [String: Any] = ["type": "web_fetch_tool_result", "tool_use_id": toolUseId,
                                                  "kind": kind, "content": content]
                if let signature { resultBlock["signature"] = signature }
                blocks.append(resultBlock)
            case .webSearchResult:
                flushText()
            }
        }
        flushText()
        return blocks
    }

    private static func parseAnthropicStartBlock(_ dict: [String: Any]) -> ReplyBlock? {
        guard let type = dict["type"] as? String else { return nil }
        switch type {
        case "text":
            let text = dict["text"] as? String ?? ""
            let isTemplate = dict["is_template"] as? Bool ?? false
            var citations: [TextCitation] = []
            if let rawCites = dict["citations"] as? [[String: Any]] {
                for c in rawCites {
                    if let url = c["url"] as? String {
                        citations.append(TextCitation(url: url, title: c["title"] as? String, citedText: c["cited_text"] as? String))
                    }
                }
            }
            return .text(id: UUID(), text: text, citations: citations, isTemplate: isTemplate)

        case "thinking":
            let thinking = dict["thinking"] as? String ?? ""
            let signature = dict["signature"] as? String
            return .thinking(id: UUID(), text: thinking, signature: signature, startedAt: Date(), endedAt: nil, elapsedSeconds: nil)

        case "server_tool_use":
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let kind = dict["kind"] as? String,
                  let input = dict["input"] as? [String: Any],
                  let action = input["action"] as? String
            else { return nil }
            let queries = input["queries"] as? [String] ?? []
            let url = input["url"] as? String
            let pattern = input["pattern"] as? String
            return .serverToolUse(
                id: UUID(),
                info: ServerToolUseInfo(id: id, name: name, kind: kind, action: action, queries: queries, url: url, pattern: pattern)
            )

        case "web_search_tool_result":
            guard let toolUseId = dict["tool_use_id"] as? String,
                  let kind = dict["kind"] as? String,
                  let contentArr = dict["content"] as? [[String: Any]]
            else { return nil }
            var items: [WebSearchResultItem] = []
            var errCode: String?
            for item in contentArr {
                let itemType = item["type"] as? String
                if itemType == "web_search_tool_result_error" {
                    errCode = item["error_code"] as? String
                } else if itemType == "web_search_result",
                          let url = item["url"] as? String,
                          let title = item["title"] as? String {
                    items.append(
                        WebSearchResultItem(
                            url: url,
                            title: title,
                            snippet: item["snippet"] as? String,
                            siteName: item["site_name"] as? String,
                            siteIcon: item["site_icon"] as? String,
                            pageAge: item["page_age"] as? String
                        )
                    )
                }
            }
            return .webSearchResult(id: UUID(), toolUseId: toolUseId, kind: kind, items: items, errorCode: errCode)

        case "web_fetch_tool_result":
            guard let toolUseId = dict["tool_use_id"] as? String,
                  let kind = dict["kind"] as? String,
                  let content = dict["content"] as? [String: Any]
            else { return nil }
            let contentType = content["type"] as? String
            var info: WebFetchResultInfo
            if contentType == "web_fetch_tool_result_error" {
                info = WebFetchResultInfo(url: nil, title: nil, publishedAt: nil, errorCode: content["error_code"] as? String)
            } else {
                let inner = content["content"] as? [String: Any]
                info = WebFetchResultInfo(
                    url: content["url"] as? String,
                    title: inner?["title"] as? String,
                    publishedAt: content["published_at"] as? String,
                    errorCode: nil
                )
                if kind == "read_link" {
                    info.documentText = (inner?["source"] as? [String: Any])?["data"] as? String
                }
            }
            return .webFetchResult(id: UUID(), toolUseId: toolUseId, kind: kind, result: info, signature: dict["signature"] as? String)

        default:
            return nil
        }
    }

    private static let maxOpenAIInlineImages = 16
    private static let maxOpenAIInlineImageBytes = 20 * 1024 * 1024

    private static func buildOpenAIImagePart(for file: FileAttachment) -> [String: Any]? {
        guard file.isImage,
              let url = AttachmentStore.localURL(for: file),
              let rawData = try? Data(contentsOf: url),
              !rawData.isEmpty
        else { return nil }
        let normalized = AttachmentStore.normalizeImageForUpload(data: rawData, fileName: file.name)
        guard !normalized.data.isEmpty, normalized.data.count <= maxOpenAIInlineImageBytes else {
            return nil
        }
        let mime = normalized.mimeType.isEmpty ? "image/jpeg" : normalized.mimeType
        let dataUrl = "data:\(mime);base64,\(normalized.data.base64EncodedString())"
        return [
            "type": "image_url",
            "image_url": ["url": dataUrl],
        ]
    }

    private static func buildOpenAIUserContent(_ message: ChatMessage, imageParts: [[String: Any]]) -> Any? {
        if imageParts.isEmpty {
            return message.content.isEmpty ? nil : message.content
        }
        var parts = imageParts
        if !message.content.isEmpty {
            parts.append(["type": "text", "text": message.content])
        }
        return parts
    }

    private static func streamOpenAI(
        _ params: StreamParams,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = resolveOpenAIEndpoint(params.baseUrl, endpoint: "chat/completions") else {
            throw AIClientError.invalidURL
        }

        let projected = ContextCompaction.projectContextItems(history: params.history, compactions: params.compactions)
        var imageBudget = min(maxOpenAIInlineImages, max(0, params.imageCap))
        var questionImageParts: [[String: Any]] = []
        for file in params.question.files where file.isImage && imageBudget > 0 {
            if let part = buildOpenAIImagePart(for: file) {
                questionImageParts.append(part)
                imageBudget -= 1
            }
        }

        var historyImagePartsByItem: [Int: [[String: Any]]] = [:]
        if imageBudget > 0 {
            for idx in stride(from: projected.count - 1, through: 0, by: -1) {
                guard imageBudget > 0 else { break }
                guard case .round(let question, _) = projected[idx] else { continue }
                let userFiles = question.files
                guard userFiles.contains(where: \.isImage) else { continue }
                var collected: [[String: Any]] = []
                for file in userFiles.reversed() where file.isImage && imageBudget > 0 {
                    if let part = buildOpenAIImagePart(for: file) {
                        collected.append(part)
                        imageBudget -= 1
                    }
                }
                if !collected.isEmpty {
                    historyImagePartsByItem[idx] = collected.reversed()
                }
            }
        }

        var payloadMessages: [[String: Any]] = []
        let trimmedSystem = params.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            payloadMessages.append(["role": "system", "content": trimmedSystem])
        }
        for (idx, item) in projected.enumerated() {
            switch item {
            case .compaction(let span):
                let pair = ContextCompaction.toCompactionMessagePair(span)
                payloadMessages.append(["role": "user", "content": pair.userText])
                payloadMessages.append(["role": "assistant", "content": pair.assistantText])

            case .round(let question, let reply):
                var effectiveQuestion = question
                if let recalledPrefix = reply.recalledMemory?.blockText, !recalledPrefix.isEmpty {
                    effectiveQuestion.content = effectiveQuestion.content.isEmpty
                        ? recalledPrefix
                        : "\(recalledPrefix)\n\n\(effectiveQuestion.content)"
                }
                guard let userContent = buildOpenAIUserContent(effectiveQuestion, imageParts: historyImagePartsByItem[idx] ?? []) else {
                    continue
                }
                payloadMessages.append(["role": "user", "content": userContent])
                let text = buildAnthropicAssistantBlocks(reply).compactMap { $0["text"] as? String }.joined(separator: "\n")
                payloadMessages.append(["role": "assistant", "content": text])
            }
        }
        if let currentContent = buildOpenAIUserContent(params.question, imageParts: questionImageParts) {
            payloadMessages.append(["role": "user", "content": currentContent])
        }
        if let prefix = params.prefixReply, prefix.canContinueReply {
            let text = buildAnthropicAssistantBlocks(prefix, isPrefix: true)
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payloadMessages.append(["role": "assistant", "content": text])
            }
        }

        let body: [String: Any] = [
            "model": params.model,
            "messages": payloadMessages,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(params.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        if !(200...299).contains(http.statusCode) {
            let errText = try await collectErrorText(from: bytes)
            throw AIClientError.httpError(http.statusCode, errText)
        }
        guard isEventStream(http) else {
            throw AIClientError.streamError("服务端没有返回流式回复。")
        }

        var blockIndex = 0
        var thinkingIdx: Int?
        var textIdx: Int?
        var finishReason: String?
        var sawDone = false

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if jsonStr == "[DONE]" {
                sawDone = true
                break
            }
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw AIClientError.streamError(msg)
            }
            if let usageObj = obj["usage"] as? [String: Any] {
                let promptTokens = usageObj["prompt_tokens"] as? Int
                let completionTokens = usageObj["completion_tokens"] as? Int
                if promptTokens != nil || completionTokens != nil {
                    continuation.yield(.usage(inputTokens: promptTokens, outputTokens: completionTokens))
                }
            }
            guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { continue }
            if let fr = first["finish_reason"] as? String { finishReason = fr }
            guard let delta = first["delta"] as? [String: Any] else { continue }

            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            if let reasoning, !reasoning.isEmpty {
                if let tIdx = textIdx {
                    continuation.yield(.blockStop(index: tIdx))
                    textIdx = nil
                }
                if thinkingIdx == nil {
                    let idx = blockIndex
                    blockIndex += 1
                    thinkingIdx = idx
                    continuation.yield(.blockStart(index: idx, block: .thinking(id: UUID(), text: "", signature: nil, startedAt: Date(), endedAt: nil, elapsedSeconds: nil)))
                }
                continuation.yield(.thinkingDelta(index: thinkingIdx!, thinking: reasoning))
            }

            if let content = delta["content"] as? String, !content.isEmpty {
                if let thIdx = thinkingIdx {
                    continuation.yield(.blockStop(index: thIdx))
                    thinkingIdx = nil
                }
                if textIdx == nil {
                    let idx = blockIndex
                    blockIndex += 1
                    textIdx = idx
                    continuation.yield(.blockStart(index: idx, block: .text(id: UUID(), text: "", citations: [], isTemplate: false)))
                }
                continuation.yield(.textDelta(index: textIdx!, text: content))
            }
        }

        guard sawDone || finishReason != nil else { throw AIClientError.interruptedStream }
        if let thIdx = thinkingIdx { continuation.yield(.blockStop(index: thIdx)) }
        if let tIdx = textIdx { continuation.yield(.blockStop(index: tIdx)) }
        let mappedStop = finishReason == "length" ? "max_tokens" : (finishReason == "content_filter" ? "refusal" : "end_turn")
        continuation.yield(.messageDelta(stopReason: mappedStop, title: nil))
    }

    private static func isEventStream(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
    }

    private static func collectErrorText(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = ""
        for try await line in bytes.lines {
            collected.append(line)
            if collected.count > 500 { break }
        }
        return extractErrorMessage(from: Data(collected.utf8))
    }

    private static func extractErrorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
