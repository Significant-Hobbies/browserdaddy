import Foundation
import SQLite3

public enum DBValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    public var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

public struct DBError: Error, Equatable {
    public let message: String
}

/// Thin SQLite3 wrapper. All access serialized through a recursive lock.
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        // URI form needs a percent-escaped path — a bare '?' or '#' in a
        // profile dir name would corrupt the query string.
        let escaped = url.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? url.path
        let path = readOnly ? "file:\(escaped)?mode=ro" : url.path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw DBError(message: "open failed: \(url.lastPathComponent)")
        }
        db = handle
        if !readOnly {
            _ = try? execute("PRAGMA journal_mode=WAL")
            _ = try? execute("PRAGMA synchronous=NORMAL")
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    public func execute(_ sql: String, _ params: [DBValue] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(message: lastError(sql))
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError(message: lastError(sql))
        }
        return Int(sqlite3_changes(db))
    }

    /// Returns rows as ordered column-name → value dictionaries.
    public func query(_ sql: String, _ params: [DBValue] = []) throws -> [[String: DBValue]] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(message: lastError(sql))
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var out: [[String: DBValue]] = []
        let ncols = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            // BUSY/IOERR/SCHEMA mid-iteration must surface — treating them
            // as DONE would return a silently truncated result set.
            guard rc == SQLITE_ROW else {
                throw DBError(message: lastError(sql))
            }
            var row: [String: DBValue] = [:]
            for i in 0..<ncols {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = value(stmt, i)
            }
            out.append(row)
        }
        return out
    }

    public func scalar<T>(_ sql: String, _ params: [DBValue] = [],
                          as read: (DBValue) -> T?) throws -> T? {
        try query(sql, params).first?.values.first.flatMap(read)
    }

    /// Runs `body` while holding the store lock — for multi-statement
    /// transactions that must not interleave with other writers.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [DBValue]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    /// Runs `body` inside BEGIN IMMEDIATE … COMMIT while holding the lock.
    /// Rolls back if `body` throws — otherwise a mid-write error leaves an
    /// open transaction that stalls every later write on this connection.
    public func writeTransaction<T>(_ body: () throws -> T) throws -> T {
        try transaction {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                _ = try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func value(_ stmt: OpaquePointer?, _ col: Int32) -> DBValue {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, col))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, col))
        case SQLITE_BLOB: return .null  // no blob columns in our schemas
        case SQLITE_NULL: return .null
        default:
            guard let ptr = sqlite3_column_text(stmt, col) else { return .null }
            return .text(String(cString: ptr))
        }
    }

    private func lastError(_ sql: String) -> String {
        let msg = String(cString: sqlite3_errmsg(db))
        return "\(msg) — in: \(sql.prefix(80))"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
