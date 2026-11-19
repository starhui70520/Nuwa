import Compression
import Foundation

enum DeepSeekZipError: LocalizedError {
    case invalidArchive
    case noSessionsFound

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "无法识别该文件，请选择 DeepSeek 导出的历史对话 ZIP 或 Nuwa JSON 备份文件。"
        case .noSessionsFound:
            return "未在备份文件中找到可导入的会话记录。"
        }
    }
}

/// Pure Foundation + Apple Compression ZIP reader for DeepSeek export archives (`deepseek_data-*.zip`).
/// Supports both Nuwa/DeepSeek v2 (`chat_sessions/<id>.json`) and legacy `conversations.json`.
enum DeepSeekZipImporter {
    struct ZipEntry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    static func parseZipData(_ data: Data) throws -> [ChatSession] {
        let entries = try readCentralDirectory(from: data)
        var sessions: [ChatSession] = []

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.hasPrefix("chat_sessions/") && lower.hasSuffix(".json") {
                if let entryData = try? extractEntry(entry, from: data),
                   let session = parseV2SessionFile(entryData) {
                    sessions.append(session)
                }
            } else if lower == "conversations.json" || lower.hasSuffix("/conversations.json") {
                if let entryData = try? extractEntry(entry, from: data) {
                    sessions.append(contentsOf: parseLegacyConversations(entryData))
                }
            }
        }

        if sessions.isEmpty {
            throw DeepSeekZipError.noSessionsFound
        }
        return sessions
    }

    // MARK: - Minimal Central Directory ZIP Reader (Store=0, Deflate=8)

    private static func readCentralDirectory(from data: Data) throws -> [ZipEntry] {
        let count = data.count
        guard count >= 22 else { throw DeepSeekZipError.invalidArchive }

        // Locate End of Central Directory (0x06054b50)
        let searchLimit = max(0, count - 65557)
        var eocdOffset = -1
        for i in stride(from: count - 22, through: searchLimit, by: -1) {
            if readUInt32(data, at: i) == 0x06054b50 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw DeepSeekZipError.invalidArchive }

        let totalEntries = Int(readUInt16(data, at: eocdOffset + 10))
        let cdOffset = Int(readUInt32(data, at: eocdOffset + 16))
        guard cdOffset >= 0 && cdOffset < count else { throw DeepSeekZipError.invalidArchive }

        var entries: [ZipEntry] = []
        var cursor = cdOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= count, readUInt32(data, at: cursor) == 0x02014b50 else { break }
            let method = readUInt16(data, at: cursor + 10)
            let compSize = Int(readUInt32(data, at: cursor + 20))
            let uncompSize = Int(readUInt32(data, at: cursor + 24))
            let nameLen = Int(readUInt16(data, at: cursor + 28))
            let extraLen = Int(readUInt16(data, at: cursor + 30))
            let commentLen = Int(readUInt16(data, at: cursor + 32))
            let localOffset = Int(readUInt32(data, at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= count else { break }
            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            entries.append(
                ZipEntry(
                    path: name,
                    compressionMethod: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset
                )
            )
            cursor = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func extractEntry(_ entry: ZipEntry, from data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, readUInt32(data, at: base) == 0x04034b50 else {
            throw DeepSeekZipError.invalidArchive
        }
        let nameLen = Int(readUInt16(data, at: base + 26))
        let extraLen = Int(readUInt16(data, at: base + 28))
        let payloadStart = base + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= data.count else { throw DeepSeekZipError.invalidArchive }

        let compressed = data.subdata(in: payloadStart..<payloadEnd)
        if entry.compressionMethod == 0 {
            return compressed
        }
        if entry.compressionMethod == 8 {
            return try inflateRawDeflate(compressed, expectedSize: max(entry.uncompressedSize, 4096))
        }
        throw DeepSeekZipError.invalidArchive
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var capacity = max(expectedSize + 1024, compressed.count * 4)
        for _ in 0..<4 {
            var output = Data(count: capacity)
            let decodedSize = output.withUnsafeMutableBytes { dstPtr in
                compressed.withUnsafeBytes { srcPtr -> Int in
                    guard let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                          let src = srcPtr.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        dst,
                        capacity,
                        src,
                        compressed.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decodedSize > 0 && decodedSize < capacity {
                output.count = decodedSize
                return output
            }
            capacity *= 2
        }
        throw DeepSeekZipError.invalidArchive
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - DeepSeek Session Parsers

    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        return isoFormatterWithFraction.date(from: raw)
            ?? isoFormatter.date(from: raw)
            ?? Date()
    }

    private static func parseV2SessionFile(_ data: Data) -> ChatSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = obj["messages"] as? [[String: Any]]
        else { return nil }

        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = parseDate(obj["inserted_at"] as? String)
        let updatedAt = parseDate(obj["updated_at"] as? String)
        let externalId = obj["id"] as? String

        // Build active path from current_message_id back to root if available
        let byId = Dictionary(uniqueKeysWithValues: rawMessages.compactMap { msg -> (Int, [String: Any])? in
            guard let id = msg["id"] as? Int else { return nil }
            return (id, msg)
        })

        var ordered: [[String: Any]] = []
        if let currentId = obj["current_message_id"] as? Int, byId[currentId] != nil {
            var cursor: Int? = currentId
            var visited = Set<Int>()
            while let id = cursor, let msg = byId[id], !visited.contains(id) {
                visited.insert(id)
                ordered.append(msg)
                cursor = msg["parent_id"] as? Int
            }
            ordered.reverse()
        } else {
            ordered = rawMessages.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        }

        let messages: [ChatMessage] = ordered.compactMap { msg in
            let roleStr = (msg["role"] as? String ?? "").uppercased()
            let role: MessageRole = roleStr == "USER" ? .user : .assistant
            let insertedAt = parseDate(msg["inserted_at"] as? String)
            let fragments = msg["fragments"] as? [[String: Any]] ?? []

            var contentParts: [String] = []
            var thinkingParts: [String] = []
            for frag in fragments {
                let type = (frag["type"] as? String ?? "").uppercased()
                let text = frag["content"] as? String ?? ""
                if type == "THINK" {
                    if !text.isEmpty { thinkingParts.append(text) }
                } else if type == "REQUEST" || type == "RESPONSE" {
                    if !text.isEmpty { contentParts.append(text) }
                }
            }
            let content = contentParts.joined(separator: "\n")
            let reasoning = thinkingParts.joined(separator: "\n")
            guard !content.isEmpty || !reasoning.isEmpty else { return nil }
            return ChatMessage(
                role: role,
                content: content,
                reasoning: reasoning,
                createdAt: insertedAt
            )
        }

        let sessionId = externalId.flatMap(UUID.init(uuidString:)) ?? stableUUID(for: externalId ?? UUID().uuidString)
        return ChatSession(
            id: sessionId,
            title: (title?.isEmpty == false) ? title! : "新对话",
            messages: messages,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func parseLegacyConversations(_ data: Data) -> [ChatSession] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { conv in
            let title = (conv["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let createdAt = parseDate(conv["inserted_at"] as? String)
            let updatedAt = parseDate(conv["updated_at"] as? String)
            let externalId = conv["id"] as? String
            guard let mapping = conv["mapping"] as? [String: [String: Any]] else { return nil }

            var ordered: [ChatMessage] = []
            var cursor = "root"
            var visited = Set<String>()
            while !visited.contains(cursor), let node = mapping[cursor] {
                visited.insert(cursor)
                if let message = node["message"] as? [String: Any],
                   let fragments = message["fragments"] as? [[String: Any]] {
                    var contentParts: [String] = []
                    var thinkParts: [String] = []
                    var isUser = false
                    for frag in fragments {
                        let type = (frag["type"] as? String ?? "").uppercased()
                        let text = frag["content"] as? String ?? ""
                        if type == "REQUEST" { isUser = true; contentParts.append(text) }
                        else if type == "THINK" { thinkParts.append(text) }
                        else if type == "RESPONSE" { contentParts.append(text) }
                    }
                    let text = contentParts.joined(separator: "\n")
                    let think = thinkParts.joined(separator: "\n")
                    if !text.isEmpty || !think.isEmpty {
                        ordered.append(
                            ChatMessage(
                                role: isUser ? .user : .assistant,
                                content: text,
                                reasoning: think,
                                createdAt: parseDate(message["inserted_at"] as? String)
                            )
                        )
                    }
                }
                if let children = node["children"] as? [String], let next = children.last {
                    cursor = next
                } else {
                    break
                }
            }

            let sessionId = externalId.flatMap(UUID.init(uuidString:)) ?? stableUUID(for: externalId ?? UUID().uuidString)
            return ChatSession(
                id: sessionId,
                title: (title?.isEmpty == false) ? title! : "新对话",
                messages: ordered,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func stableUUID(for string: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (idx, b) in string.utf8.enumerated() {
            bytes[idx % 16] ^= b &+ UInt8(idx & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes) as UUID
    }
}
