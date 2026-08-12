import Foundation
import SQLite3

/// Shared raw-SQLite plumbing for the local cache store and the derived
/// search index: statement preparation, stepping, binding, column reads, and
/// error mapping over one `LocalLibraryCacheStoreError` shape.
nonisolated enum LocalCacheSQLite {
    static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static func execute(
        _ sql: String,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(operation: operation, db: db)
        }
    }

    static func prepare(
        _ sql: String,
        operation: String,
        db: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw error(operation: operation, db: db)
        }
        return statement
    }

    static func run(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql, operation: operation, db: db)
        defer {
            sqlite3_finalize(statement)
        }
        try bindings(statement)
        try step(statement, operation: operation, db: db)
    }

    static func query(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql, operation: operation, db: db)
        defer {
            sqlite3_finalize(statement)
        }
        try bindings(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw error(operation: operation, db: db)
            }
        }
    }

    static func step(
        _ statement: OpaquePointer,
        operation: String,
        db: OpaquePointer
    ) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw error(operation: operation, db: db)
        }
    }

    static func reset(
        _ statement: OpaquePointer,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK
        else {
            throw error(operation: operation, db: db)
        }
    }

    static func bind(
        _ value: String?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        let code = if let value {
            sqlite3_bind_text(statement, index, value, -1, transientDestructor)
        } else {
            sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw error(operation: operation, db: db)
        }
    }

    static func bind(
        _ value: Int?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        let code = if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw error(operation: operation, db: db)
        }
    }

    static func bind(
        _ value: Double?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        let code = if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw error(operation: operation, db: db)
        }
    }

    static func bind(
        _ value: Data?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw error(operation: operation, db: db)
            }
            return
        }
        guard value.count <= Int(Int32.max) else {
            throw LocalLibraryCacheStoreError(
                operation: operation,
                message: "bound payload is too large"
            )
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                transientDestructor
            )
        }
        guard result == SQLITE_OK else {
            throw error(operation: operation, db: db)
        }
    }

    static func columnText(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    static func columnDouble(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    static func columnInt(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    static func columnData(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else {
            return Data()
        }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: count)
    }

    static func compressedData(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompressedData(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }

    static func jsonArray(_ values: some Collection<String>) throws -> String {
        String(
            decoding: try JSONEncoder().encode(values.sorted()),
            as: UTF8.self
        )
    }

    static func jsonArray(_ values: [Int]) throws -> String {
        String(
            decoding: try JSONEncoder().encode(values.sorted()),
            as: UTF8.self
        )
    }

    static func error(
        operation: String,
        db: OpaquePointer
    ) -> LocalLibraryCacheStoreError {
        LocalLibraryCacheStoreError(
            operation: operation,
            message: String(cString: sqlite3_errmsg(db))
        )
    }
}
