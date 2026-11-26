import Darwin
import Foundation
import SQLite3

/// The same transaction advances the transcript checkpoints, deduplication index and totals.
final class UsageStore {
    enum Table: Int32 {
        case summary, cursor, codex, claude, migration, recovered
    }

    struct Failure: Error {}

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(file: URL) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let resolved = realpath(parent.path, nil) else { throw Failure() }
        let path = String(cString: resolved) + "/" + file.lastPathComponent
        free(resolved)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure() }
        let mode = fchmod(fd, 0o600)
        close(fd)
        guard mode == 0 else { throw Failure() }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let handle
        else {
            sqlite3_close(handle)
            throw Failure()
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 1000)
        try self.execute("PRAGMA secure_delete = ON")
        try self.execute("""
        CREATE TABLE IF NOT EXISTS ledger (
            kind INTEGER NOT NULL, key TEXT NOT NULL, value BLOB,
            PRIMARY KEY (kind, key)
        ) WITHOUT ROWID
        """)
    }

    deinit {
        for statement in self.statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(self.db)
    }

    func transaction<Result>(_ body: (UsageStore) throws -> Result) throws -> Result {
        try self.execute("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try self.execute("COMMIT")
            return result
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    func load<Value: Decodable>(_ type: Value.Type, _ table: Table, _ key: String) throws -> Value? {
        try self.query("SELECT value FROM ledger WHERE kind = ? AND key = ?", table, key) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Failure() }
            return try self.decoder.decode(
                type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }

    func save(_ value: some Encodable, _ table: Table, _ key: String) throws {
        let data = try self.encoder.encode(value)
        try self.query("REPLACE INTO ledger VALUES (?, ?, ?)", table, key) { statement in
            try data.withUnsafeBytes { bytes in
                guard sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), nil) == SQLITE_OK else {
                    throw Failure()
                }
                defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure() }
            }
        }
    }

    func insert(_ table: Table, _ key: String) throws -> Bool {
        try self.query("INSERT OR IGNORE INTO ledger VALUES (?, ?, NULL)", table, key) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure() }
            return sqlite3_changes(self.db) == 1
        }
    }

    func contains(_ table: Table, _ key: String) throws -> Bool {
        try self.query("SELECT 1 FROM ledger WHERE kind = ? AND key = ?", table, key) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_ROW: true
            case SQLITE_DONE: false
            default: throw Failure()
            }
        }
    }

    func clear(_ table: Table) throws {
        try self.execute("DELETE FROM ledger WHERE kind = \(table.rawValue)")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(self.db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure() }
    }

    private func query<Result>(
        _ sql: String, _ table: Table, _ key: String, _ body: (OpaquePointer) throws -> Result) throws -> Result
    {
        let statement: OpaquePointer
        if let cached = self.statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw Failure()
            }
            self.statements[sql] = prepared
            statement = prepared
        }
        return try key.withCString { bytes in
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            guard sqlite3_bind_int(statement, 1, table.rawValue) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, bytes, -1, nil) == SQLITE_OK else { throw Failure() }
            return try body(statement)
        }
    }
}
