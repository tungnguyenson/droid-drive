import Foundation
import SQLite3

/// Thin wrapper over the SQLite C API: prepared statements, typed binds, one error type.
/// Not thread-safe on its own; `ItemStore` serialises access with a lock.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path` nil opens an in-memory database (tests).
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure(code: status, message: message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure(status) }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure(status) }
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure(status) }
            rows.append(try map(Row(statement: statement)))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            statement = cached
        } else {
            var created: OpaquePointer?
            let status = sqlite3_prepare_v2(handle, sql, -1, &created, nil)
            guard status == SQLITE_OK, let created else { throw failure(status) }
            statements[sql] = created
            statement = created
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .int(let int): status = sqlite3_bind_int64(statement, position, int)
            case .real(let real): status = sqlite3_bind_double(statement, position, real)
            case .null: status = sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        return statement
    }

    private func failure(_ status: Int32) -> Failure {
        Failure(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }

    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let pointer = sqlite3_column_text(statement, column) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, column))
            // Decode exactly the stored bytes; device names may be NFD and must not change.
            return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
        }

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }
}

/// SQLite's "copy the bound string now" destructor sentinel, which Swift cannot import.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
