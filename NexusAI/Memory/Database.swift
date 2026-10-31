import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case text(String), int(Int64), real(Double), blob(Data), null
}

/// Thin, thread-safe SQLite wrapper (system libsqlite3). The database file uses iOS Data Protection;
/// sensitive columns are additionally sealed with AES-GCM via `Vault`.
final class Database: @unchecked Sendable {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.nexus.sqlite")
    let url: URL

    private init() {
        url = Paths.appSupport.appendingPathComponent("nexus.sqlite")
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            db = nil
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS conversations(
            id TEXT PRIMARY KEY, title TEXT, updated REAL, project_id TEXT, preview BLOB, body BLOB);
        CREATE TABLE IF NOT EXISTS memories(
            id TEXT PRIMARY KEY, kind TEXT, content BLOB, project_id TEXT, created REAL, updated REAL,
            last_used REAL, use_count INTEGER DEFAULT 0, importance REAL, pinned INTEGER, status TEXT,
            source TEXT, embedding BLOB);
        CREATE TABLE IF NOT EXISTS projects(
            id TEXT PRIMARY KEY, name TEXT, created REAL, updated REAL, body BLOB);
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY, title TEXT, filename TEXT, kind TEXT, pages INTEGER, chars INTEGER,
            project_id TEXT, created REAL, summary BLOB);
        CREATE TABLE IF NOT EXISTS chunks(
            id TEXT PRIMARY KEY, doc_id TEXT REFERENCES documents(id) ON DELETE CASCADE, idx INTEGER,
            page INTEGER, text BLOB, embedding BLOB);
        CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc_id);
        CREATE TABLE IF NOT EXISTS benchmarks(id TEXT PRIMARY KEY, created REAL, body BLOB);
        CREATE TABLE IF NOT EXISTS eval_runs(id TEXT PRIMARY KEY, created REAL, body BLOB);
        CREATE TABLE IF NOT EXISTS research(id TEXT PRIMARY KEY, created REAL, title TEXT, body BLOB);
        """)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        queue.sync {
            guard let db else { return false }
            return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) -> Bool {
        queue.sync {
            guard let db else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, args)
            let rc = sqlite3_step(stmt)
            return rc == SQLITE_DONE || rc == SQLITE_ROW
        }
    }

    func query(_ sql: String, _ args: [SQLValue] = []) -> [[String: SQLValue]] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, args)
            var rows: [[String: SQLValue]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: SQLValue] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, i))
                        if let p = sqlite3_column_blob(stmt, i), n > 0 { row[name] = .blob(Data(bytes: p, count: n)) }
                        else { row[name] = .blob(Data()) }
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ args: [SQLValue]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func wipeAll() {
        exec("DELETE FROM chunks; DELETE FROM documents; DELETE FROM memories; DELETE FROM conversations; DELETE FROM projects; DELETE FROM benchmarks; DELETE FROM eval_runs; DELETE FROM research;")
        exec("VACUUM;")
    }
}

extension Dictionary where Key == String, Value == SQLValue {
    func string(_ k: String) -> String? { if case .text(let s)? = self[k] { return s }; return nil }
    func int(_ k: String) -> Int64? { if case .int(let v)? = self[k] { return v }; if case .real(let d)? = self[k] { return Int64(d) }; return nil }
    func double(_ k: String) -> Double? { if case .real(let v)? = self[k] { return v }; if case .int(let i)? = self[k] { return Double(i) }; return nil }
    func blob(_ k: String) -> Data? { if case .blob(let d)? = self[k] { return d }; return nil }
    func date(_ k: String) -> Date { Date(timeIntervalSince1970: double(k) ?? 0) }
    func uuid(_ k: String) -> UUID? { string(k).flatMap(UUID.init(uuidString:)) }
    /// Decrypts a Vault-sealed text column.
    func sealedText(_ k: String) -> String? { blob(k).flatMap(Vault.openString) }
}

extension Optional where Wrapped == UUID {
    var sql: SQLValue { self.map { .text($0.uuidString) } ?? .null }
}
