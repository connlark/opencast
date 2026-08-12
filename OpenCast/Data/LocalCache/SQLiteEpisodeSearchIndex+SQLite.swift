import Foundation
import SQLite3

/// Thin forwarders so the index's call sites keep their established names
/// while the single shared implementation lives in `LocalCacheSQLite`.
nonisolated extension SQLiteEpisodeSearchIndex {
    static func execute(
        _ sql: String,
        operation: String,
        db: OpaquePointer
    ) throws {
        try LocalCacheSQLite.execute(sql, operation: operation, db: db)
    }

    static func prepare(
        _ sql: String,
        operation: String,
        db: OpaquePointer
    ) throws -> OpaquePointer {
        try LocalCacheSQLite.prepare(sql, operation: operation, db: db)
    }

    static func run(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void
    ) throws {
        try LocalCacheSQLite.run(
            sql,
            operation: operation,
            db: db,
            bindings: bindings
        )
    }

    static func query(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        try LocalCacheSQLite.query(
            sql,
            operation: operation,
            db: db,
            bindings: bindings,
            row: row
        )
    }

    static func step(
        _ statement: OpaquePointer,
        operation: String,
        db: OpaquePointer
    ) throws {
        try LocalCacheSQLite.step(statement, operation: operation, db: db)
    }

    static func reset(
        _ statement: OpaquePointer,
        operation: String,
        db: OpaquePointer
    ) throws {
        try LocalCacheSQLite.reset(statement, operation: operation, db: db)
    }

    static func bind(
        _ value: String?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(
            value,
            at: index,
            statement: statement,
            db: db,
            operation: operation
        )
    }

    static func bind(
        _ value: Int?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(
            value,
            at: index,
            statement: statement,
            db: db,
            operation: operation
        )
    }

    static func bind(
        _ value: Double?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(
            value,
            at: index,
            statement: statement,
            db: db,
            operation: operation
        )
    }

    static func bind(
        _ value: Data?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(
            value,
            at: index,
            statement: statement,
            db: db,
            operation: operation
        )
    }

    static func columnText(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        LocalCacheSQLite.columnText(statement, index)
    }

    static func columnDouble(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Double? {
        LocalCacheSQLite.columnDouble(statement, index)
    }

    static func columnData(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Data? {
        LocalCacheSQLite.columnData(statement, index)
    }

    static func compressedData(_ data: Data) throws -> Data {
        try LocalCacheSQLite.compressedData(data)
    }

    static func decompressedData(_ data: Data) throws -> Data {
        try LocalCacheSQLite.decompressedData(data)
    }

    static func jsonArray(_ values: some Collection<String>) throws -> String {
        try LocalCacheSQLite.jsonArray(values)
    }

    static func jsonArray(_ values: [Int]) throws -> String {
        try LocalCacheSQLite.jsonArray(values)
    }

    static func error(
        operation: String,
        db: OpaquePointer
    ) -> LocalLibraryCacheStoreError {
        LocalCacheSQLite.error(operation: operation, db: db)
    }

    static func compressedSearchEvidence(
        summary: String,
        showNotes: String
    ) throws -> Data? {
        guard !summary.isEmpty || !showNotes.isEmpty else {
            return nil
        }
        return try compressedData(
            JSONEncoder().encode([summary, showNotes])
        )
    }

    static func decompressedSearchEvidence(
        _ data: Data?,
        operation: String
    ) throws -> (summary: String, showNotes: String) {
        guard let data else {
            return ("", "")
        }
        let fields = try JSONDecoder().decode(
            [String].self,
            from: decompressedData(data)
        )
        guard fields.count == 2 else {
            throw LocalLibraryCacheStoreError(
                operation: operation,
                message: "derived search evidence has an invalid field count"
            )
        }
        return (fields[0], fields[1])
    }

}
