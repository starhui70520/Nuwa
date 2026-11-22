import Foundation
import SQLite3

// Owned exclusively by ChatStore's serial persistence queue.
final class ChatHistoryPersistence {
    private var saved: [UUID: ChatSession] = [:]

    func load(legacyURL: URL) throws -> [ChatSession] {
        let db = try Database(url: databaseURL(for: legacyURL))
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

        let loaded: [ChatSession] = try db.statement("SELECT payload FROM sessions") { statement in
            var sessions = [ChatSession]()
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return sessions }
                try db.check(result, expecting: SQLITE_ROW)
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                sessions.append(Self.restored(try decoder.decode(ChatSession.self, from: data)))
            }
        }
        // The schema version prevents re-importing the old snapshot even if cleanup fails.
        try? FileManager.default.removeItem(at: legacyURL)
        saved = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return loaded
    }

    func save(_ sessions: [ChatSession], legacyURL: URL) throws {
        let next = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let changed = sessions.filter { saved[$0.id] != $0 }
        let removed = saved.keys.filter { next[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return }

        let db = try Database(url: databaseURL(for: legacyURL))
        try db.transaction { try write(changed, removing: removed, to: db) }
        saved = next
    }

    private static func restored(_ session: ChatSession) -> ChatSession {
        var restored = session
        restored.ensureTreeNormalized()
        for index in restored.messages.indices where restored.messages[index].isStreaming {
            restored.messages[index].status = .stopped
        }
        return restored
    }

    private func databaseURL(for legacyURL: URL) -> URL {
        legacyURL.deletingPathExtension().appendingPathExtension("sqlite3")
    }

    private func write(_ changed: [ChatSession], removing: [UUID], to db: Database) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        try db.statement("INSERT OR REPLACE INTO sessions (id, payload) VALUES (?, ?)") { statement in
            for session in changed {
                try db.check(sqlite3_bind_text(statement, 1, session.id.uuidString, -1, transient))
                let data = try encoder.encode(session)
                try data.withUnsafeBytes { buffer in
                    try db.check(sqlite3_bind_blob64(statement, 2, buffer.baseAddress, UInt64(buffer.count), transient))
                }
                try db.check(sqlite3_step(statement), expecting: SQLITE_DONE)
                try db.check(sqlite3_reset(statement))
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

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let connection else {
            let error = Self.error(connection, code: result)
            sqlite3_close(connection)
            throw error
        }
        handle = connection
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
