import Compression
import CryptoKit
import Foundation
import zlib

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
/// Reads chat-demo v3 archives and retains compatibility with earlier iOS backups.
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
    let crc32: UInt32
        let localHeaderOffset: Int
    }

    static func parseZipData(_ data: Data) throws -> [ChatSession] {
        let entries = try readCentralDirectory(from: data)
        let manifest = entries.filter { $0.path == "manifest.json" }
        var isV3 = false
        if !manifest.isEmpty {
            guard manifest.count == 1, let first = manifest.first, first.localHeaderOffset == 0,
                  let object = try JSONSerialization.jsonObject(with: extractEntry(first, from: data)) as? [String: Any]
            else { throw DeepSeekZipError.invalidArchive }
            if let version = object["export_format_version"] {
                guard (version as? Int) == 3 else { throw DeepSeekZipError.invalidArchive }
                isV3 = true
            } else {
                guard (object["format_version"] as? Int) == 2 else { throw DeepSeekZipError.invalidArchive }
            }
        }
        var entriesByNFCPath: [String: ZipEntry] = [:]
        for entry in entries {
            let path = entry.path.precomposedStringWithCanonicalMapping
            if entriesByNFCPath.updateValue(entry, forKey: path) != nil, isV3 {
                throw DeepSeekZipError.invalidArchive
            }
        }

        let index = entriesByNFCPath["chat_session_index.json"]
        // Keep accepting older unindexed session dumps; an indexed archive needs a manifest.
        if manifest.isEmpty && index != nil { throw DeepSeekZipError.invalidArchive }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var sessionIds = Set<String>()
        var sessions: [ChatSession] = []

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.hasPrefix("chat_sessions/") && lower.hasSuffix(".json") && !lower.contains("_files/") {
                if let entryData = try? extractEntry(entry, from: data),
                   let session = parseSessionFile(
                    entryData, path: entry.path, zipData: data, entriesByPath: entriesByNFCPath,
                    staging: staging, strict: isV3
                   ) {
                    sessions.append(session)
                    sessionIds.insert(String(entry.path.dropFirst("chat_sessions/".count).dropLast(".json".count)))
                } else if isV3 {
                    throw DeepSeekZipError.invalidArchive
                }
            } else if !isV3 && (lower == "conversations.json" || lower.hasSuffix("/conversations.json")) {
                if let entryData = try? extractEntry(entry, from: data) {
                    sessions.append(contentsOf: parseLegacyConversations(entryData))
                }
            }
        }

        if isV3 {
            guard let index,
                  let rows = try JSONSerialization.jsonObject(with: extractEntry(index, from: data)) as? [[String: Any]]
            else { throw DeepSeekZipError.invalidArchive }
            let ids = Set(rows.compactMap { $0["id"] as? String })
            guard ids == sessionIds, ids.count == rows.count else { throw DeepSeekZipError.invalidArchive }
        }
        if sessions.isEmpty {
            throw DeepSeekZipError.noSessionsFound
        }
        if FileManager.default.fileExists(atPath: staging.path) {
            let destination = AttachmentStore.filesDirectory
            var moved: [URL] = []
            do {
                for image in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                    let target = destination.appendingPathComponent(image.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) { continue }
                    try FileManager.default.moveItem(at: image, to: target)
                    moved.append(target)
                }
            } catch {
                for image in moved { try? FileManager.default.removeItem(at: image) }
                throw error
            }
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
            let crc32 = readUInt32(data, at: cursor + 16)
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
                    crc32: crc32,
                    localHeaderOffset: localOffset
                )
            )
            cursor = nameEnd + extraLen + commentLen
        }
        guard entries.count == totalEntries else { throw DeepSeekZipError.invalidArchive }
        return entries
    }

    private static func extractEntry(_ entry: ZipEntry, from data: Data) throws -> Data {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, readUInt32(data, at: base) == 0x04034b50 else {
            throw DeepSeekZipError.invalidArchive
        }
        let nameLen = Int(readUInt16(data, at: base + 26))
        let extraLen = Int(readUInt16(data, at: base + 28))
        let nameStart = base + 30
        let nameEnd = nameStart + nameLen
        guard nameEnd <= data.count, String(data: data[nameStart..<nameEnd], encoding: .utf8) == entry.path
        else { throw DeepSeekZipError.invalidArchive }
        let payloadStart = base + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= data.count else { throw DeepSeekZipError.invalidArchive }

        let compressed = data.subdata(in: payloadStart..<payloadEnd)
        let decoded: Data
        switch entry.compressionMethod {
        case 0: decoded = compressed
        case 8: decoded = try inflateRawDeflate(compressed, expectedSize: max(entry.uncompressedSize, 4096))
        default: throw DeepSeekZipError.invalidArchive
        }
        guard decoded.count == entry.uncompressedSize,
              decoded.withUnsafeBytes({ bytes in
                  crc32_z(0, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
              }) == UInt(entry.crc32)
        else { throw DeepSeekZipError.invalidArchive }
        return decoded
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
        fileName: String,
        exportPath: String,
        zipData: Data,
        entriesByPath: [String: ZipEntry],
        staging: URL
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
            ext = origExt.range(of: #"^[A-Za-z0-9]{1,10}$"#, options: .regularExpression) != nil ? origExt : "jpg"
        }
        let digest = SHA256.hash(data: imgData).map { String(format: "%02x", $0) }.joined()
        let localName = "\(digest).\(ext)"
        let localURL = AttachmentStore.filesDirectory.appendingPathComponent(localName)
        let stagedURL = staging.appendingPathComponent(localName)
        do {
            if !FileManager.default.fileExists(atPath: localURL.path),
               !FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try imgData.write(to: stagedURL, options: [.atomic])
            }
        } catch {
            return nil
        }
        return (localName, mime.isEmpty ? AttachmentStore.inferMimeType(fileName: fileName, isImage: true) : mime)
    }

    private static func parseSessionFile(
        _ data: Data,
        path: String,
        zipData: Data,
        entriesByPath: [String: ZipEntry],
        staging: URL,
        strict: Bool
    ) -> ChatSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = obj["messages"] as? [[String: Any]]
        else { return nil }

        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let createdAt = parseDate(obj["inserted_at"] as? String)
        let updatedAt = parseDate(obj["updated_at"] as? String)
        let externalId = obj["id"] as? String
        let isPinned = (obj["pinned"] as? Bool) ?? false
        if strict {
            guard let externalId, !externalId.isEmpty, !externalId.contains("/"),
                  path == "chat_sessions/\(externalId).json"
            else { return nil }
        }
        let imagePrefix = String(path.dropLast(".json".count)) + "_files/"
        var importedImages: [String: (localFileName: String, mimeType: String)] = [:]

        // Sort ascending by numeric id so parent_id always appears before child (1:1 toLocal.ts buildTree)
        let sortedRaw = rawMessages.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        var indexByNumId = [Int: Int](minimumCapacity: sortedRaw.count)
        var messages: [ChatMessage] = []
        var parentIndices: [Int?] = []
        messages.reserveCapacity(sortedRaw.count)
        parentIndices.reserveCapacity(sortedRaw.count)
        var lastTimestamp: (raw: String, date: Date)?

        for raw in sortedRaw {
            guard let numId = raw["id"] as? Int else {
                if strict { return nil }
                continue
            }
            let localId = UUID()
            let parentIndex = (raw["parent_id"] as? Int).flatMap { indexByNumId[$0] }
            let roleStr = (raw["role"] as? String ?? "").uppercased()
            if strict {
                guard numId >= 0, indexByNumId[numId] == nil, roleStr == "USER" || roleStr == "ASSISTANT"
                else { return nil }
                if let parentIndex {
                    guard (messages[parentIndex].role == .user) != (roleStr == "USER") else { return nil }
                } else {
                    guard raw["parent_id"] is NSNull, roleStr == "USER" else { return nil }
                }
            }
            let parentUUID = parentIndex.map { messages[$0].id }
            let insertedAt: Date
            if let rawDate = raw["inserted_at"] as? String {
                if let lastTimestamp, lastTimestamp.raw == rawDate {
                    insertedAt = lastTimestamp.date
                } else {
                    insertedAt = parseDate(rawDate)
                    lastTimestamp = (rawDate, insertedAt)
                }
            } else {
                insertedAt = Date()
            }
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
                            if isImg, let exportPath = rf["export_path"] as? String, exportPath.hasPrefix(imagePrefix) {
                                if let saved = importedImages[exportPath] ?? saveExtractedImage(
                                    fileName: fname,
                                    exportPath: exportPath,
                                    zipData: zipData,
                                    entriesByPath: entriesByPath,
                                    staging: staging
                                ) {
                                    importedImages[exportPath] = saved
                                    localName = saved.localFileName
                                    mime = saved.mimeType
                                } else if strict && entriesByPath[exportPath.precomposedStringWithCanonicalMapping] != nil {
                                    return nil
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

            if let pIdx = parentIndex {
                messages[pIdx].selectedChildId = localId
            }
            indexByNumId[numId] = messages.count
            messages.append(built)
            parentIndices.append(parentIndex)
        }

        // Select the active path from current_message_id back to root (1:1 toLocal.ts)
        var rootId = messages.first(where: { $0.parentId == nil })?.id ?? messages.first?.id
        if let currentNum = obj["current_message_id"] as? Int, let curIdx = indexByNumId[currentNum] {
            messages[curIdx].selectedChildId = nil
            var cursorIdx = curIdx
            while let pIdx = parentIndices[cursorIdx] {
                messages[pIdx].selectedChildId = messages[cursorIdx].id
                cursorIdx = pIdx
            }
            rootId = messages[cursorIdx].id
        } else if strict && !messages.isEmpty {
            return nil
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
