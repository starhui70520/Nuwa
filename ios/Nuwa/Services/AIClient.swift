import Foundation

enum AIStreamEvent {
    case reasoning(String)
    case content(String)
}

enum AIClientError: LocalizedError {
    case missingConfiguration
    case invalidURL
    case httpError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "请先在设置中配置 API Key 与接口地址。"
        case .invalidURL:
            return "API 地址格式无效，请检查设置。"
        case .httpError(let code, let message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "请求失败（HTTP \(code)）" : "请求失败（HTTP \(code)）：\(clean)"
        case .decodingError:
            return "解析服务端响应失败。"
        }
    }
}

enum AIClient {
    static func streamChat(
        messages: [ChatMessage],
        apiProtocol: ApiProtocol,
        baseUrl: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !cleanKey.isEmpty, !cleanBase.isEmpty else {
                        throw AIClientError.missingConfiguration
                    }

                    switch apiProtocol {
                    case .openai:
                        try await streamOpenAI(
                            messages: messages,
                            baseUrl: cleanBase,
                            apiKey: cleanKey,
                            model: model,
                            systemPrompt: systemPrompt,
                            continuation: continuation
                        )
                    case .anthropic:
                        try await streamAnthropic(
                            messages: messages,
                            baseUrl: cleanBase,
                            apiKey: cleanKey,
                            model: model,
                            systemPrompt: systemPrompt,
                            thinkingEnabled: thinkingEnabled,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func openAIEndpoint(baseUrl: String) -> URL? {
        if baseUrl.hasSuffix("/chat/completions") {
            return URL(string: baseUrl)
        }
        if baseUrl.hasSuffix("/v1") {
            return URL(string: "\(baseUrl)/chat/completions")
        }
        return URL(string: "\(baseUrl)/v1/chat/completions")
    }

    private static func anthropicEndpoint(baseUrl: String) -> URL? {
        if baseUrl.hasSuffix("/messages") {
            return URL(string: baseUrl)
        }
        if baseUrl.hasSuffix("/v1") {
            return URL(string: "\(baseUrl)/messages")
        }
        return URL(string: "\(baseUrl)/v1/messages")
    }

    private static func streamOpenAI(
        messages: [ChatMessage],
        baseUrl: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = openAIEndpoint(baseUrl: baseUrl) else {
            throw AIClientError.invalidURL
        }

        var payloadMessages: [[String: String]] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            payloadMessages.append(["role": "system", "content": trimmedSystem])
        }
        for msg in messages where !msg.content.isEmpty {
            payloadMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        if !(200...299).contains(http.statusCode) {
            let errorText = try await collectErrorBody(from: bytes)
            throw AIClientError.httpError(http.statusCode, errorText)
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if jsonStr == "[DONE]" { break }
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { continue }

            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                continuation.yield(.reasoning(reasoning))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                continuation.yield(.content(text))
            }
        }
    }

    private static func streamAnthropic(
        messages: [ChatMessage],
        baseUrl: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        thinkingEnabled: Bool,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = anthropicEndpoint(baseUrl: baseUrl) else {
            throw AIClientError.invalidURL
        }

        let payloadMessages: [[String: String]] = messages
            .filter { $0.role != .system && !$0.content.isEmpty }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": payloadMessages,
            "stream": true,
        ]
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["system"] = trimmedSystem
        }
        if thinkingEnabled {
            body["thinking"] = ["type": "enabled", "budget_tokens": 2048]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.decodingError
        }
        if !(200...299).contains(http.statusCode) {
            let errorText = try await collectErrorBody(from: bytes)
            throw AIClientError.httpError(http.statusCode, errorText)
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            if type == "content_block_delta", let delta = obj["delta"] as? [String: Any] {
                if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                    continuation.yield(.reasoning(thinking))
                }
                if let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.content(text))
                }
            } else if type == "message_stop" {
                break
            }
        }
    }

    static func fetchDeepSeekBalance(baseUrl: String, apiKey: String) async throws -> String {
        let cleanBase = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(cleanBase)/user/balance") else {
            throw AIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIClientError.decodingError
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let infos = json["balance_infos"] as? [[String: Any]],
           let first = infos.first {
            let currency = first["currency"] as? String ?? "CNY"
            let total = first["total_balance"] as? String ?? "0.00"
            return "\(currency) \(total)"
        }
        return "不可用"
    }

    private static func collectErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = ""
        for try await line in bytes.lines {
            collected.append(line)
            if collected.count > 400 { break }
        }
        if let data = collected.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return collected
    }
}
