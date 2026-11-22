import Foundation
import SQLite3

// Owned exclusively by ChatStore's serial persistence queue.
final class ChatHistoryPersistence {
    private var savedMetadata: [UUID: ChatSession] = [:]
    private var savedPayloads: [UUID: ChatSession] = [:]

    func load(legacyURL: URL) throws -> [ChatSession] {
        let db = try Database(url: Self.databaseURL(for: legacyURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let version = try db.statement("PRAGMA user_version") { statement in
            try db.check(sqlite3_step(statement), expecting: SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }

        if version == 0 {
            let legacy: [ChatSession]
            do {
                legacy = try decoder.decode([ChatSession].self, from: Data(contentsOf: legacyURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                legacy = []
            }
            var seen = Set<UUID>()
            let restored = legacy.map(Self.restored)
            guard restored.allSatisfy({ seen.insert($0.id).inserted }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try db.transaction {
                try db.run("CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                try write(restored, removing: [], to: db)
                try db.run("PRAGMA user_version = 1")
            }
        } else if version != 1 {
            throw CocoaError(.fileReadUnknown)
        }

        // Exports read a consistent snapshot without blocking history saves.
        try db.run("PRAGMA journal_mode = WAL")

        // The catalog is a rebuildable cache, leaving the v1 payloads usable by older builds.
        try db.transaction {
            try db.run("CREATE TABLE IF NOT EXISTS session_catalog (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL)")
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                let record = operation == "DELETE" ? "OLD" : "NEW"
                try db.run("""
                    CREATE TRIGGER IF NOT EXISTS invalidate_catalog_\(operation) AFTER \(operation) ON sessions
                    BEGIN DELETE FROM session_catalog WHERE id = \(record).id; END
                    """)
            }
            let missing = try db.statement("""
                SELECT s.rowid FROM sessions s LEFT JOIN session_catalog c ON c.id = s.id WHERE c.id IS NULL
                """) { statement in
                var rows: [Int64] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { return rows }
                    try db.check(result, expecting: SQLITE_ROW)
                    rows.append(sqlite3_column_int64(statement, 0))
                }
            }
            try db.statement("""
                INSERT INTO session_catalog (id, metadata)
                SELECT id, json_set(json_remove(CAST(payload AS TEXT), '$.messages'), '$.messages', json('[]'))
                FROM sessions WHERE rowid = ?
                """) { statement in
                for row in missing {
                    try db.check(sqlite3_bind_int64(statement, 1, row))
                    try db.check(sqlite3_step(statement), expecting: SQLITE_DONE)
                    // Reset between rows so SQLite drops each parsed message payload.
                    try db.check(sqlite3_reset(statement))
                }
            }
        }
        let loaded: [ChatSession] = try db.statement("SELECT metadata FROM session_catalog") { statement in
            var sessions = [ChatSession]()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return sessions }
                try db.check(result, expecting: SQLITE_ROW)
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
                let session = try autoreleasepool {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                    return try decoder.decode(ChatSession.self, from: data).metadataOnly
                }
                sessions.append(session)
            }
        }
        // The schema version prevents re-importing the old snapshot even if cleanup fails.
        try? FileManager.default.removeItem(at: legacyURL)
        savedMetadata = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        savedPayloads = [:]
        return loaded
    }

    func save(_ sessions: [ChatSession], legacyURL: URL) throws {
        let next = Dictionary(sessions.map { ($0.id, $0.metadataOnly) }, uniquingKeysWith: { _, latest in latest })
        let resident = sessions.filter(\.hasLoadedMessages)
        let changed = sessions.filter {
            $0.hasLoadedMessages ? savedPayloads[$0.id] != $0 : savedMetadata[$0.id] != next[$0.id]
        }
        let removed = savedMetadata.keys.filter { next[$0] == nil }

        if !changed.isEmpty || !removed.isEmpty {
            let db = try Database(url: Self.databaseURL(for: legacyURL))
            try db.transaction {
                try write(changed, removing: removed, to: db, updateCatalog: true)
            }
        }
        savedMetadata = next
        savedPayloads = Dictionary(resident.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    func retainSavedPayload(for id: UUID?) {
        savedPayloads = savedPayloads.filter { $0.key == id }
    }

    func loadSession(_ id: UUID, legacyURL: URL) throws -> ChatSession {
        let session = try Self.withSessionLoader(legacyURL: legacyURL) { read in try read(id) }
        savedPayloads = [id: session]
        return session
    }

    static func withSessionLoader<T>(
        legacyURL: URL, consistentSnapshot: Bool = false,
        _ body: ((_ id: UUID) throws -> ChatSession) throws -> T
    ) throws -> T {
        let db = try Database(url: databaseURL(for: legacyURL), readOnly: true)
        if consistentSnapshot { try db.run("BEGIN") }
        defer { if consistentSnapshot { try? db.run("ROLLBACK") } }
        return try body { id in try readSession(id, from: db) }
    }

    private static func readSession(_ id: UUID, from db: Database) throws -> ChatSession {
        try autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try db.statement("SELECT payload FROM sessions WHERE id = ?") { statement in
                try db.check(sqlite3_bind_text(statement, 1, id.uuidString, -1, transient))
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { throw CocoaError(.fileReadNoSuchFile) }
                try db.check(result, expecting: SQLITE_ROW)
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                return restored(try decoder.decode(ChatSession.self, from: data))
            }
        }
    }

    private static func restored(_ session: ChatSession) -> ChatSession {
        var restored = session
        restored.ensureTreeNormalized()
        for index in restored.messages.indices where restored.messages[index].isStreaming {
            restored.messages[index].status = .stopped
        }
        return restored
    }

    private static func databaseURL(for legacyURL: URL) -> URL {
        legacyURL.deletingPathExtension().appendingPathExtension("sqlite3")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func write(_ changed: [ChatSession], removing: [UUID], to db: Database, updateCatalog: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transient = Self.transient

        try db.statement("INSERT OR REPLACE INTO sessions (id, payload) VALUES (?, ?)") { statement in
            for record in changed {
                try autoreleasepool {
                    let session: ChatSession
                    if record.hasLoadedMessages {
                        session = record
                    } else {
                        var loaded = try Self.readSession(record.id, from: db)
                        loaded.applyMetadata(from: record)
                        session = loaded
                    }
                    try db.check(sqlite3_bind_text(statement, 1, session.id.uuidString, -1, transient))
                    let data = try encoder.encode(session)
                    try data.withUnsafeBytes { buffer in
                        // SQLITE_STATIC avoids copying the BLOB; clear the binding before the buffer expires.
                        defer {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                        }
                        try db.check(sqlite3_bind_blob64(statement, 2, buffer.baseAddress, UInt64(buffer.count), nil))
                        try db.check(sqlite3_step(statement), expecting: SQLITE_DONE)
                    }
                }
            }
        }
        if updateCatalog {
            try db.statement("INSERT INTO session_catalog (id, metadata) VALUES (?, ?)") { statement in
                for session in changed {
                    try db.check(sqlite3_bind_text(statement, 1, session.id.uuidString, -1, transient))
                    let data = try encoder.encode(session.metadataOnly)
                    try data.withUnsafeBytes { bytes in
                        try db.check(sqlite3_bind_blob64(statement, 2, bytes.baseAddress, UInt64(bytes.count), transient))
                    }
                    try db.check(sqlite3_step(statement), expecting: SQLITE_DONE)
                    try db.check(sqlite3_reset(statement))
                }
            }
        }
        try db.statement("DELETE FROM sessions WHERE id = ?") { statement in
            for id in removing {
                try db.check(sqlite3_bind_text(statement, 1, id.uuidString, -1, transient))
                try db.check(sqlite3_step(statement), expecting: SQLITE_DONE)
                try db.check(sqlite3_reset(statement))
            }
        }
    }
}

private final class Database {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var connection: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let error = Self.error(connection, code: result)
            sqlite3_close(connection)
            throw error
        }
        handle = connection
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    func check(_ result: Int32, expecting expected: Int32 = SQLITE_OK) throws {
        if result != expected { throw Self.error(handle, code: result) }
    }

    private static func error(_ handle: OpaquePointer?, code: Int32) -> NSError {
        let description = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
        return NSError(domain: "Nuwa.ChatHistory", code: Int(code), userInfo: [NSLocalizedDescriptionKey: description])
    }

    func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &prepared, nil))
        defer { sqlite3_finalize(prepared) }
        return try body(prepared!)
    }

    func run(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}
