import Foundation
import SQLite3

/// A value bound to or read from a statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { s } else { nil } }
    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d): Int64(d)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
    public var data: Data? { if case .blob(let d) = self { d } else { nil } }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// A thin wrapper over the system SQLite. Not thread-safe by itself: GraphStore serializes access.
final class SQLiteDB {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        if path != ":memory:" { try exec("PRAGMA journal_mode=WAL") }
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(description: message) }
    }

    /// Runs one statement and returns its rows, keyed by column name.
    @discardableResult
    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(description: "\(message) in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(stmt, n)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .text(let v): sqlite3_bind_text(stmt, n, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(description: "\(message) in: \(sql)") }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, c)
                    row[name] = .blob(bytes > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: Int(bytes)) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Applies migrations newer than PRAGMA user_version, each in its own transaction.
    func migrate(_ steps: [String]) throws {
        let current = Int(try query("PRAGMA user_version").first?["user_version"]?.int ?? 0)
        for (i, sql) in steps.enumerated() where i >= current {
            try transaction {
                try exec(sql)
                try exec("PRAGMA user_version = \(i + 1)")
            }
        }
    }
}
