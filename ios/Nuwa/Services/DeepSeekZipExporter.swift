import Foundation

/// Pure Swift Store-mode ZIP exporter producing DeepSeek/Nuwa v3 compatible archives
/// (`deepseek_data-YYYY-MM-DD.zip`) with 1:1 parity to chat-demo/src/services/chat/history/toArchive.ts:
/// - manifest.json first (export_format_version: 3)
/// - Topological parent-first message numbering (parent_id < id guaranteed)
/// - All fragments exported: REQUEST, FILE (w/ export_path), THINK, RESPONSE, TEMPLATE_RESPONSE,
///   TOOL_SEARCH, TOOL_OPEN, TOOL_FIND, READ_LINK
/// - Embedded local image files written to `chat_sessions/<sessionId>_files/<fileName>`
/// - chat_session_index.json with message_count & pinned flags
enum DeepSeekZipExporter {
    struct Entry {
        let path: String
        let data: Data
    }

    static func exportSessionsToZip(
        _ sessions: [ChatSession],
        loadSession: (ChatSession) throws -> ChatSession = { $0 }
    ) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entries: [Entry] = []
        var imageEntries: [Entry] = []
        var addedImagePaths = Set<String>()

        // 1. manifest.json (must be first entry per checkArchiveFormat in importArchive.ts)
        let manifestObj = ["export_format_version": 3]
        entries.append(Entry(path: "manifest.json", data: try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted])))

        // 2. chat_sessions/<id>.json
        var indexList: [[String: Any]] = []
        for record in sessions {
            var session = try loadSession(record)
            session.ensureTreeNormalized()
            let sessionIdStr = session.id.uuidString.lowercased()
            let insertedStr = iso.string(from: session.createdAt)
            let updatedStr = iso.string(from: session.updatedAt)

            // Topological parent-first ordering so parent_id < id always holds (1:1 toArchive.ts numberMessages)
            let (ordered, numIdByUUID) = numberMessages(session.messages)

            var exportedMessages: [[String: Any]] = []
            for msg in ordered {
                guard let numId = numIdByUUID[msg.id] else { continue }
                let parentNum: Any = msg.parentId.flatMap { numIdByUUID[$0] } ?? NSNull()
                let msgTimeStr = iso.string(from: msg.createdAt)
                var fragments: [[String: Any]] = []

                if msg.role == .user {
                    if !msg.files.isEmpty {
                        let fileObjs: [[String: Any]] = msg.files.map { f in
                            var exportPath: Any = NSNull()
                            if f.isImage,
                               let localURL = AttachmentStore.localURL(for: f),
                               let imgData = try? Data(contentsOf: localURL),
                               !imgData.isEmpty {
                                let safeName = "\(f.id)_\(f.name)".replacingOccurrences(of: "/", with: "_")
                                let zipPath = "chat_sessions/\(sessionIdStr)_files/\(safeName)"
                                exportPath = zipPath
                                if !addedImagePaths.contains(zipPath) {
                                    addedImagePaths.insert(zipPath)
                                    imageEntries.append(Entry(path: zipPath, data: imgData))
                                }
                            }
                            return [
                                "id": f.id,
                                "file_name": f.name,
                                "file_size": f.size,
                                "token_usage": NSNull(),
                                "inserted_at": msgTimeStr,
                                "export_path": exportPath,
                                "is_image": f.isImage,
                                "width": NSNull(),
                                "height": NSNull(),
                            ]
                        }
                        fragments.append(["type": "FILE", "files": fileObjs])
                    }
                    fragments.append(["type": "REQUEST", "content": msg.content])
                } else {
                    fragments = exportAssistantFragments(msg)
                }

                let statusStr: String
                if msg.role == .user {
                    statusStr = "FINISHED"
                } else if msg.stopReason == "refusal" {
                    statusStr = "CONTENT_FILTER"
                } else {
                    switch msg.status {
                    case .error: statusStr = "FAILED"
                    case .stopped: statusStr = "INCOMPLETE"
                    case .done: statusStr = msg.stopReason == "max_tokens" ? "INCOMPLETE" : "FINISHED"
                    default: statusStr = "WIP"
                    }
                }

                exportedMessages.append([
                    "id": numId,
                    "parent_id": parentNum,
                    "role": msg.role == .user ? "USER" : "ASSISTANT",
                    "status": statusStr,
                    "thinking_enabled": msg.thinkingEnabled,
                    "search_enabled": msg.searchEnabled,
                    "accumulated_token_usage": 0,
                    "inserted_at": msgTimeStr,
                    "fragments": fragments,
                ])
            }

            let visible = session.visibleMessages()
            let currentId = visible.last.flatMap { numIdByUUID[$0.id] } ?? 0

            var sessionObj: [String: Any] = [
                "id": sessionIdStr,
                "title": session.title.isEmpty ? NSNull() : session.title,
                "pinned": session.isPinned,
                "inserted_at": insertedStr,
                "updated_at": updatedStr,
                "current_message_id": currentId,
                "messages": exportedMessages,
            ]
            if let pinnedAt = session.pinnedAt {
                sessionObj["pinned_at"] = iso.string(from: pinnedAt)
            }
            let sData = try JSONSerialization.data(withJSONObject: sessionObj)
            entries.append(Entry(path: "chat_sessions/\(sessionIdStr).json", data: sData))

            indexList.append([
                "id": sessionIdStr,
                "title": session.title.isEmpty ? NSNull() : session.title,
                "pinned": session.isPinned,
                "message_count": exportedMessages.count,
                "inserted_at": insertedStr,
                "updated_at": updatedStr,
            ])
        }

        // 3. chat_session_index.json
        entries.append(Entry(path: "chat_session_index.json", data: try JSONSerialization.data(withJSONObject: indexList)))

        // 4. Embedded session image files (after index per importArchive.ts streaming order)
        entries.append(contentsOf: imageEntries)

        return buildZipArchive(entries: entries)
    }

    private static func numberMessages(_ messages: [ChatMessage]) -> ([ChatMessage], [UUID: Int]) {
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var ids: [UUID: Int] = [:]
        var ordered: [ChatMessage] = []

        func visit(_ message: ChatMessage, depth: Int) {
            if ids[message.id] != nil { return }
            if let pid = message.parentId, let parent = byId[pid], depth < messages.count {
                visit(parent, depth: depth + 1)
            }
            ordered.append(message)
            ids[message.id] = ordered.count
        }

        for msg in messages {
            visit(msg, depth: 0)
        }
        return (ordered, ids)
    }

    private static func exportAssistantFragments(_ msg: ChatMessage) -> [[String: Any]] {
        guard !msg.blocks.isEmpty else {
            var out: [[String: Any]] = []
            if !msg.reasoning.isEmpty {
                var f: [String: Any] = ["type": "THINK", "content": msg.reasoning]
                if let secs = msg.thinkingSeconds { f["elapsed_secs"] = secs }
                out.append(f)
            }
            if !msg.content.isEmpty {
                out.append(["type": "RESPONSE", "content": msg.content])
            }
            return out
        }

        var resultsByToolId: [String: ReplyBlock] = [:]
        for block in msg.blocks {
            switch block {
            case .webSearchResult(_, let toolId, _, _, _):
                resultsByToolId[toolId] = block
            case .webFetchResult(_, let toolId, _, _, _):
                resultsByToolId[toolId] = block
            default:
                break
            }
        }

        var fragments: [[String: Any]] = []
        for block in msg.blocks {
            switch block {
            case .thinking(_, let text, _, let started, let ended, let secs):
                if !text.isEmpty {
                    var f: [String: Any] = ["type": "THINK", "content": text]
                    if let secs {
                        f["elapsed_secs"] = secs
                    } else if let s = started, let e = ended {
                        f["elapsed_secs"] = e.timeIntervalSince(s)
                    } else {
                        f["elapsed_secs"] = NSNull()
                    }
                    fragments.append(f)
                }

            case .text(_, let text, _, let isTemplate):
                if !text.isEmpty {
                    fragments.append(["type": isTemplate ? "TEMPLATE_RESPONSE" : "RESPONSE", "content": text])
                }

            case .serverToolUse(_, let info):
                let resultBlock = resultsByToolId[info.id]
                if info.action == "search" {
                    var statusStr = "WIP"
                    var resArr: [[String: Any]] = []
                    if case .webSearchResult(_, _, _, let items, let errCode) = resultBlock {
                        statusStr = errCode != nil ? "FAILED" : "FINISHED"
                        resArr = items.map { item in
                            [
                                "url": item.url,
                                "title": item.title,
                                "snippet": item.snippet ?? "",
                                "published_at": item.pageAge ?? NSNull(),
                                "site_name": item.siteName ?? NSNull(),
                                "site_icon": item.siteIcon ?? NSNull(),
                            ]
                        }
                    }
                    fragments.append([
                        "type": "TOOL_SEARCH",
                        "queries": info.queries,
                        "status": statusStr,
                        "results": resArr,
                    ])
                } else if info.action == "read_link" {
                    if case .webFetchResult(_, _, _, let fetchInfo, let sig) = resultBlock,
                       let sig, !sig.trimmingCharacters(in: .whitespaces).isEmpty {
                        var r: [String: Any] = [
                            "title": fetchInfo.title ?? NSNull(),
                            "signature": sig,
                        ]
                        if let u = fetchInfo.url ?? info.url, !u.isEmpty {
                            r["url"] = u
                        }
                        fragments.append(["type": "READ_LINK", "results": [r]])
                    }
                } else if info.action == "find_in_page" {
                    var statusStr = "WIP"
                    if case .webFetchResult(_, _, _, let fetchInfo, _) = resultBlock {
                        statusStr = fetchInfo.errorCode == nil ? "FINISHED" : "FAILED"
                    }
                    fragments.append([
                        "type": "TOOL_FIND",
                        "status": statusStr,
                        "pattern": info.pattern ?? "",
                    ])
                } else {
                    var statusStr = "WIP"
                    var pageTitle: Any = NSNull()
                    var pubAt: Any = NSNull()
                    var pageUrl: Any = info.url ?? NSNull()
                    if case .webFetchResult(_, _, _, let fetchInfo, _) = resultBlock {
                        statusStr = fetchInfo.errorCode == nil ? "FINISHED" : "FAILED"
                        pageTitle = fetchInfo.title ?? NSNull()
                        pubAt = fetchInfo.publishedAt ?? NSNull()
                        if let u = fetchInfo.url, !u.isEmpty { pageUrl = u }
                    }
                    fragments.append([
                        "type": "TOOL_OPEN",
                        "status": statusStr,
                        "url": pageUrl,
                        "title": pageTitle,
                        "snippet": statusStr == "FINISHED" ? "" : NSNull(),
                        "site_name": NSNull(),
                        "published_at": pubAt,
                    ])
                }

            default:
                break
            }
        }
        return fragments
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "deepseek_data-\(df.string(from: date)).zip"
    }

    // MARK: - iCloud Ubiquity Auto-Backup (matches backup.ts)

    static func isIcloudAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    static func writeIcloudSnapshot(zipData: Data) -> Bool {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return false
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let target = docs.appendingPathComponent("deepseek_data-latest.zip")
        do {
            try zipData.write(to: target, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Minimal Store-Mode ZIP Writer with Standard IEEE CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func buildZipArchive(entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let localOffset = UInt32(archive.count)

            appendUInt32(&archive, 0x04034B50)
            appendUInt16(&archive, 20)
            appendUInt16(&archive, 0x0800)
            appendUInt16(&archive, 0)
            appendUInt16(&archive, 0)
            appendUInt16(&archive, 0)
            appendUInt32(&archive, crc)
            appendUInt32(&archive, size)
            appendUInt32(&archive, size)
            appendUInt16(&archive, UInt16(nameData.count))
            appendUInt16(&archive, 0)
            archive.append(nameData)
            archive.append(entry.data)

            appendUInt32(&centralDirectory, 0x02014B50)
            appendUInt16(&centralDirectory, 20)
            appendUInt16(&centralDirectory, 20)
            appendUInt16(&centralDirectory, 0x0800)
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt32(&centralDirectory, crc)
            appendUInt32(&centralDirectory, size)
            appendUInt32(&centralDirectory, size)
            appendUInt16(&centralDirectory, UInt16(nameData.count))
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt32(&centralDirectory, 0)
            appendUInt32(&centralDirectory, localOffset)
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        appendUInt32(&archive, 0x06054B50)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, UInt16(entries.count))
        appendUInt16(&archive, UInt16(entries.count))
        appendUInt32(&archive, cdSize)
        appendUInt32(&archive, cdOffset)
        appendUInt16(&archive, 0)

        return archive
    }

    private static func appendUInt16(_ data: inout Data, _ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
