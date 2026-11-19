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
/// 1:1 port of chat-demo/src/services/chat/history/importArchive.ts + toLocal.ts:
/// - Preserves full branching trees (rootMessageId / parentId / selectedChildId / current_message_id)
/// - Parses all fragments: REQUEST, FILE, THINK (with elapsed_secs), RESPONSE, TEMPLATE_RESPONSE,
///   TOOL_SEARCH, TOOL_OPEN, TOOL_FIND, READ_LINK
/// - Extracts embedded images from `chat_sessions/<id>_files/...` into AttachmentStore with MIME detection
/// - Supports legacy `conversations.json` archives as fallback
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
        var entriesByNFCPath: [String: ZipEntry] = [:]
        for entry in entries {
            entriesByNFCPath[entry.path.precomposedStringWithCanonicalMapping] = entry
        }

        var sessions: [ChatSession] = []

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.hasPrefix("chat_sessions/") && lower.hasSuffix(".json") && !lower.contains("_files/") {
                if let entryData = try? extractEntry(entry, from: data),
                   let session = parseV2SessionFile(entryData, zipData: data, entriesByPath: entriesByNFCPath) {
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
        for _ in 0..<5 {
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

    // MARK: - V2 DeepSeek Session Parser (Full Branching Tree + All Fragments + Images)

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

    private static func isWebUrl(_ value: String?) -> Bool {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func detectImageMime(_ data: Data) -> String {
        guard data.count >= 12 else { return "" }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        let ascii = String(bytes: b, encoding: .ascii) ?? ""
        if ascii.hasPrefix("GIF87a") || ascii.hasPrefix("GIF89a") { return "image/gif" }
        if ascii.hasPrefix("RIFF") && ascii.dropFirst(8).hasPrefix("WEBP") { return "image/webp" }
        if b[0] == 0x42 && b[1] == 0x4D { return "image/bmp" }
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) {
            return "image/tiff"
        }
        return ""
    }

    private static func saveExtractedImage(
        fileId: String,
        fileName: String,
        exportPath: String,
        zipData: Data,
        entriesByPath: [String: ZipEntry]
    ) -> (localFileName: String, mimeType: String)? {
        let normalizedPath = exportPath.precomposedStringWithCanonicalMapping
        guard let entry = entriesByPath[normalizedPath],
              let imgData = try? extractEntry(entry, from: zipData),
              !imgData.isEmpty
        else { return nil }

        let mime = detectImageMime(imgData)
        let ext: String
        switch mime {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/jpeg": ext = "jpg"
        default:
            let origExt = AttachmentStore.fileExtension(of: fileName)
            ext = origExt.isEmpty ? "jpg" : origExt
        }
        let localName = "\(fileId).\(ext)"
        let dest = AttachmentStore.filesDirectory.appendingPathComponent(localName)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? imgData.write(to: dest, options: [.atomic])
        }
        return (localName, mime.isEmpty ? AttachmentStore.inferMimeType(fileName: fileName, isImage: true) : mime)
    }

    private static func parseV2SessionFile(
        _ data: Data,
        zipData: Data,
        entriesByPath: [String: ZipEntry]
    ) -> ChatSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = obj["messages"] as? [[String: Any]]
        else { return nil }

        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let createdAt = parseDate(obj["inserted_at"] as? String)
        let updatedAt = parseDate(obj["updated_at"] as? String)
        let externalId = obj["id"] as? String
        let isPinned = (obj["pinned"] as? Bool) ?? false

        // Sort ascending by numeric id so parent_id always appears before child (1:1 toLocal.ts buildTree)
        let sortedRaw = rawMessages.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        var uuidByNumId: [Int: UUID] = [:]
        var indexByNumId: [Int: Int] = [:]
        var messages: [ChatMessage] = []

        for raw in sortedRaw {
            guard let numId = raw["id"] as? Int else { continue }
            let localId = UUID()
            uuidByNumId[numId] = localId
            let parentNum = raw["parent_id"] as? Int
            let parentUUID = parentNum.flatMap { uuidByNumId[$0] }
            let insertedAt = parseDate(raw["inserted_at"] as? String)
            let roleStr = (raw["role"] as? String ?? "").uppercased()
            let fragments = raw["fragments"] as? [[String: Any]] ?? []

            let built: ChatMessage
            if roleStr == "USER" {
                var contentParts: [String] = []
                var files: [FileAttachment] = []
                for frag in fragments {
                    let type = (frag["type"] as? String ?? "").uppercased()
                    if type == "REQUEST", let text = frag["content"] as? String, !text.isEmpty {
                        contentParts.append(text)
                    } else if type == "FILE", let rawFiles = frag["files"] as? [[String: Any]] {
                        for rf in rawFiles {
                            let fid = (rf["id"] as? String) ?? UUID().uuidString
                            let fname = (rf["file_name"] as? String) ?? "file"
                            let fsize = (rf["file_size"] as? Int) ?? 0
                            let isImg = (rf["is_image"] as? Bool) ?? AttachmentStore.isImageName(fname)
                            var localName: String? = nil
                            var mime = ""
                            if isImg, let exportPath = rf["export_path"] as? String, !exportPath.isEmpty {
                                if let saved = saveExtractedImage(
                                    fileId: fid,
                                    fileName: fname,
                                    exportPath: exportPath,
                                    zipData: zipData,
                                    entriesByPath: entriesByPath
                                ) {
                                    localName = saved.localFileName
                                    mime = saved.mimeType
                                }
                            }
                            files.append(
                                FileAttachment(
                                    id: fid,
                                    serverId: nil,
                                    name: fname,
                                    size: fsize,
                                    isImage: isImg,
                                    mimeType: mime,
                                    localFileName: localName
                                )
                            )
                        }
                    }
                }
                built = ChatMessage(
                    id: localId,
                    parentId: parentUUID,
                    role: .user,
                    content: contentParts.joined(separator: "\n"),
                    files: files,
                    status: .done,
                    createdAt: insertedAt
                )
            } else {
                let rawStatus = (raw["status"] as? String ?? "FINISHED").uppercased()
                let refused = rawStatus == "CONTENT_FILTER"
                let status: ReplyStatus
                switch rawStatus {
                case "FAILED", "CONTEXT_LENGTH_EXCEEDED", "TIMEOUT": status = .error
                case "INCOMPLETE", "WIP": status = .stopped
                default: status = .done
                }

                let hasDeepSearch = fragments.contains {
                    let t = ($0["type"] as? String ?? "").uppercased()
                    return t == "TOOL_OPEN" || t == "TOOL_FIND"
                }
                let searchKind = hasDeepSearch ? "deep_search" : "search"

                var blocks: [ReplyBlock] = []
                var textParts: [String] = []
                var thinkParts: [String] = []
                var elapsedTotal: Double?

                for (fIdx, frag) in fragments.enumerated() {
                    let type = (frag["type"] as? String ?? "").uppercased()
                    let toolId = "history-\(numId)-\(fIdx)"
                    switch type {
                    case "RESPONSE", "TEMPLATE_RESPONSE":
                        let text = frag["content"] as? String ?? ""
                        let isTemplate = type == "TEMPLATE_RESPONSE"
                        if !text.isEmpty && (!refused || isTemplate) {
                            textParts.append(text)
                            blocks.append(.text(id: UUID(), text: text, citations: [], isTemplate: isTemplate))
                        }

                    case "THINK":
                        let text = frag["content"] as? String ?? ""
                        if !text.isEmpty && !refused {
                            let secs = frag["elapsed_secs"] as? Double
                            if let secs { elapsedTotal = secs }
                            thinkParts.append(text)
                            blocks.append(.thinking(id: UUID(), text: text, signature: nil, startedAt: nil, endedAt: nil, elapsedSeconds: secs))
                        }

                    case "TOOL_SEARCH":
                        let queries = frag["queries"] as? [String] ?? []
                        let fragStatus = (frag["status"] as? String ?? "FINISHED").uppercased()
                        blocks.append(
                            .serverToolUse(
                                id: UUID(),
                                info: ServerToolUseInfo(
                                    id: toolId,
                                    name: "deepseek_web_search",
                                    kind: searchKind,
                                    action: "search",
                                    queries: queries,
                                    url: nil,
                                    pattern: nil
                                )
                            )
                        )
                        if fragStatus != "WIP" {
                            if fragStatus == "FAILED" {
                                blocks.append(.webSearchResult(id: UUID(), toolUseId: toolId, kind: searchKind, items: [], errorCode: "unavailable"))
                            } else {
                                let rawResults = frag["results"] as? [[String: Any]] ?? []
                                let items: [WebSearchResultItem] = rawResults.compactMap { r in
                                    guard let url = r["url"] as? String, isWebUrl(url),
                                          let title = r["title"] as? String
                                    else { return nil }
                                    return WebSearchResultItem(
                                        url: url,
                                        title: title,
                                        snippet: r["snippet"] as? String,
                                        siteName: r["site_name"] as? String,
                                        siteIcon: (r["site_icon"] as? String).flatMap { isWebUrl($0) ? $0 : nil },
                                        pageAge: r["published_at"] as? String
                                    )
                                }
                                blocks.append(.webSearchResult(id: UUID(), toolUseId: toolId, kind: searchKind, items: items, errorCode: nil))
                            }
                        }

                    case "TOOL_OPEN":
                        guard let url = frag["url"] as? String, isWebUrl(url) else { break }
                        let fragStatus = (frag["status"] as? String ?? "FINISHED").uppercased()
                        blocks.append(
                            .serverToolUse(
                                id: UUID(),
                                info: ServerToolUseInfo(
                                    id: toolId,
                                    name: "deepseek_web_search",
                                    kind: "deep_search",
                                    action: "open_page",
                                    queries: [],
                                    url: url,
                                    pattern: nil
                                )
                            )
                        )
                        if fragStatus != "WIP" {
                            let info = fragStatus == "FINISHED"
                                ? WebFetchResultInfo(url: url, title: frag["title"] as? String, publishedAt: frag["published_at"] as? String, errorCode: nil)
                                : WebFetchResultInfo(url: nil, title: nil, publishedAt: nil, errorCode: "unavailable")
                            blocks.append(.webFetchResult(id: UUID(), toolUseId: toolId, kind: "deep_search", result: info, signature: nil))
                        }

                    case "TOOL_FIND":
                        let pattern = frag["pattern"] as? String ?? ""
                        let fragStatus = (frag["status"] as? String ?? "FINISHED").uppercased()
                        blocks.append(
                            .serverToolUse(
                                id: UUID(),
                                info: ServerToolUseInfo(
                                    id: toolId,
                                    name: "deepseek_web_search",
                                    kind: "deep_search",
                                    action: "find_in_page",
                                    queries: [],
                                    url: "",
                                    pattern: pattern
                                )
                            )
                        )
                        if fragStatus != "WIP" {
                            let info = fragStatus == "FINISHED"
                                ? WebFetchResultInfo(url: "", title: nil, publishedAt: nil, errorCode: nil)
                                : WebFetchResultInfo(url: nil, title: nil, publishedAt: nil, errorCode: "unavailable")
                            blocks.append(.webFetchResult(id: UUID(), toolUseId: toolId, kind: "deep_search", result: info, signature: nil))
                        }

                    case "READ_LINK":
                        let rawResults = frag["results"] as? [[String: Any]] ?? []
                        for (rIdx, r) in rawResults.enumerated() {
                            let url = (r["url"] as? String).flatMap { isWebUrl($0) ? $0 : nil } ?? ""
                            let sig = (r["signature"] as? String) ?? ""
                            if url.isEmpty && sig.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                            let subId = "\(toolId)-\(rIdx)"
                            blocks.append(
                                .serverToolUse(
                                    id: UUID(),
                                    info: ServerToolUseInfo(
                                        id: subId,
                                        name: "deepseek_read_url",
                                        kind: "read_link",
                                        action: "read_link",
                                        queries: [],
                                        url: url,
                                        pattern: nil
                                    )
                                )
                            )
                            blocks.append(
                                .webFetchResult(
                                    id: UUID(),
                                    toolUseId: subId,
                                    kind: "read_link",
                                    result: WebFetchResultInfo(url: url, title: r["title"] as? String, publishedAt: nil, errorCode: nil),
                                    signature: sig.isEmpty ? nil : sig
                                )
                            )
                        }

                    default:
                        break
                    }
                }

                built = ChatMessage(
                    id: localId,
                    parentId: parentUUID,
                    role: .assistant,
                    content: textParts.joined(separator: "\n"),
                    reasoning: thinkParts.joined(separator: "\n"),
                    thinkingSeconds: elapsedTotal,
                    blocks: blocks,
                    status: status,
                    stopReason: refused ? "refusal" : nil,
                    thinkingEnabled: (raw["thinking_enabled"] as? Bool) ?? false,
                    searchEnabled: (raw["search_enabled"] as? Bool) ?? false,
                    prefixEnabled: false,
                    createdAt: insertedAt
                )
            }

            if let pNum = parentNum, let pIdx = indexByNumId[pNum] {
                messages[pIdx].selectedChildId = localId
            }
            indexByNumId[numId] = messages.count
            messages.append(built)
        }

        // Select the active path from current_message_id back to root (1:1 toLocal.ts)
        var rootId = messages.first(where: { $0.parentId == nil })?.id ?? messages.first?.id
        if let currentNum = obj["current_message_id"] as? Int, let curIdx = indexByNumId[currentNum] {
            messages[curIdx].selectedChildId = nil
            var cursorIdx = curIdx
            var visited = Set<UUID>()
            while !visited.contains(messages[cursorIdx].id) {
                let currentMsg = messages[cursorIdx]
                visited.insert(currentMsg.id)
                if let pUUID = currentMsg.parentId,
                   let pIdx = messages.firstIndex(where: { $0.id == pUUID }) {
                    messages[pIdx].selectedChildId = currentMsg.id
                    cursorIdx = pIdx
                } else {
                    rootId = currentMsg.id
                    break
                }
            }
        }

        let sessionId = externalId.flatMap(UUID.init(uuidString:)) ?? stableUUID(for: externalId ?? UUID().uuidString)
        return ChatSession(
            id: sessionId,
            title: title,
            rootMessageId: rootId,
            messages: messages,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned
        )
    }

    private static func parseLegacyConversations(_ data: Data) -> [ChatSession] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { conv in
            let title = (conv["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                        var blocks: [ReplyBlock] = []
                        if !isUser {
                            if !think.isEmpty {
                                blocks.append(.thinking(id: UUID(), text: think, signature: nil, startedAt: nil, endedAt: nil, elapsedSeconds: nil))
                            }
                            if !text.isEmpty {
                                blocks.append(.text(id: UUID(), text: text, citations: [], isTemplate: false))
                            }
                        }
                        ordered.append(
                            ChatMessage(
                                role: isUser ? .user : .assistant,
                                content: text,
                                reasoning: think,
                                blocks: blocks,
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
            var session = ChatSession(
                id: sessionId,
                title: title,
                messages: ordered,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            session.ensureTreeNormalized()
            return session
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
