// A thin, thread-safe wrapper over the system's SQLite (the SQLite3 module), for backing the iPhone up (BackupStore):
// one connection in WAL mode, statements prepared once and kept, values bound by position, and transactions that are
// always closed before the call returns, so nothing stays open while Verso is suspended. Every call takes the one
// lock, so the store can be used from the engine, the upload session's delegate and the views alike.

import Foundation
import SQLite3

/// SQLite's "copy this value now" destructor, which Swift does not import as a constant.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum BackupDatabaseError: LocalizedError {
    case open(String)
    case statement(String, String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "The backup's database could not be opened: \(message)"
        case .statement(let sql, let message): "The backup's database failed (\(message)) on: \(sql.prefix(80))"
        }
    }
}

/// A value to bind or read back.
enum BackupValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

protocol BackupBindable {
    var backupValue: BackupValue { get }
}

extension Int: BackupBindable { var backupValue: BackupValue { .integer(Int64(self)) } }
extension Int64: BackupBindable { var backupValue: BackupValue { .integer(self) } }
extension Double: BackupBindable { var backupValue: BackupValue { .real(self) } }
extension String: BackupBindable { var backupValue: BackupValue { .text(self) } }
extension Data: BackupBindable { var backupValue: BackupValue { .blob(self) } }
extension Bool: BackupBindable { var backupValue: BackupValue { .integer(self ? 1 : 0) } }
extension Date: BackupBindable { var backupValue: BackupValue { .real(timeIntervalSince1970) } }
extension Optional: BackupBindable where Wrapped: BackupBindable {
    var backupValue: BackupValue { map(\.backupValue) ?? .null }
}

/// One row of a query's answer, read by column index.
struct BackupRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }
    func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
    func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    func date(_ column: Int32) -> Date? { isNull(column) ? nil : Date(timeIntervalSince1970: double(column)) }

    func text(_ column: Int32) -> String? {
        guard let characters = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: characters)
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return isNull(column) ? nil : Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

final class BackupDatabase: @unchecked Sendable {
    private var connection: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    /// Inside `transaction`, which nests by running inner ones as part of the outer.
    private var transactionDepth = 0

    /// Opens (creating if needed) the database at `file`, in WAL mode.
    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(file.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(opened)
            throw BackupDatabaseError.open(message)
        }
        connection = opened
        sqlite3_busy_timeout(opened, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(connection)
    }

    /// Runs `sql`, which may hold several statements and binds nothing.
    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw BackupDatabaseError.statement(sql, text)
        }
    }

    /// Runs one statement with `values` bound in order; the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [any BackupBindable] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure(sql) }
        return Int(sqlite3_changes(connection))
    }

    /// The rows of one query, each read by `read`.
    func query<Value>(_ sql: String, _ values: [any BackupBindable] = [], _ read: (BackupRow) throws -> Value) throws -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        var rows: [Value] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure(sql) }
            rows.append(try read(BackupRow(statement: statement)))
        }
        return rows
    }

    /// The first row of a query, if any.
    func first<Value>(_ sql: String, _ values: [any BackupBindable] = [], _ read: (BackupRow) throws -> Value) throws -> Value? {
        try query(sql, values, read).first
    }

    /// The last row inserted.
    var lastInsertedRow: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(connection)
    }

    /// Runs `body` in one transaction, committed when it returns and rolled back when it throws; a transaction inside
    /// another is part of it.
    func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let value = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return value
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String, _ values: [any BackupBindable]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let kept = statements[sql] {
            statement = kept
        } else {
            var made: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &made, nil) == SQLITE_OK, let made else { throw failure(sql) }
            statements[sql] = made
            statement = made
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value.backupValue {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transientDestructor)
            case .blob(let data): data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transientDestructor)
            }
            }
            guard code == SQLITE_OK else { throw failure(sql) }
        }
        return statement
    }

    private func failure(_ sql: String) -> BackupDatabaseError {
        .statement(sql, connection.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
}
