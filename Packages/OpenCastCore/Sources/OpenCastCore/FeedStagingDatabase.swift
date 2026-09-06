import Foundation
import SQLite3

/// Confined to a single synchronous preparation or replay. No connection is
/// shared between tasks; the published episode source opens read-only readers.
final class FeedStagingDatabase {
    private var connection: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        try execute("PRAGMA cache_size=-1024; PRAGMA temp_store=FILE;")
        if !readOnly { try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=OFF;") }
    }

    deinit { sqlite3_close(connection) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        return statement
    }

    func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        let status = if let value {
            value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
        } else { sqlite3_bind_null(statement, index) }
        guard status == SQLITE_OK else { throw failure() }
    }

    func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let status = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard status == SQLITE_OK else { throw failure() }
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }

    func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column), count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func failure() -> any Error {
        NSError(domain: "OpenCastFeedStaging", code: Int(sqlite3_errcode(connection)), userInfo: [
            NSLocalizedDescriptionKey: "Couldn’t store the feed temporarily: \(String(cString: sqlite3_errmsg(connection)))"
        ])
    }
}
