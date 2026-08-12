import Darwin
import Foundation
import SQLite3
import Testing

@Suite("SQLite FTS5 capability")
struct SQLiteFTS5CapabilityTests {
    @Test("Apple runtime creates, queries, ranks, and drops an FTS5 table")
    func appleRuntimeSupportsFTS5() throws {
        let report = try SQLiteFTS5CapabilityProbe.run()
        let data = try JSONEncoder.sorted.encode(report)
        let json = String(decoding: data, as: UTF8.self)

        Attachment.record(json, named: "fts5-capability.json")
        print("OPENCAST_FTS5_CAPABILITY_JSON \(json)")
        #expect(report.functionalMatchRowID == 1)
        #expect(report.bm25Score < 0)
        #expect(report.tableDropped)
    }
}

private enum SQLiteFTS5CapabilityProbe {
    static let compileOptionSQL = "SELECT sqlite_compileoption_used('ENABLE_FTS5')"
    static let versionSQL = "SELECT sqlite_version()"
    static let createSQL = """
    CREATE VIRTUAL TABLE capability_probe USING fts5(
      title,
      body,
      tokenize = 'unicode61 remove_diacritics 2'
    )
    """
    static let insertSQL = """
    INSERT INTO capability_probe(rowid, title, body)
    VALUES (1, 'Café Noir', 'A podcast capability proof')
    """
    static let querySQL = """
    SELECT rowid, bm25(capability_probe, 8.0, 1.0)
    FROM capability_probe
    WHERE capability_probe MATCH '\"cafe noir\" pod*'
    ORDER BY bm25(capability_probe, 8.0, 1.0), rowid
    LIMIT 1
    """
    static let dropSQL = "DROP TABLE capability_probe"

    static func run() throws -> SQLiteFTS5CapabilityReport {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            ":memory:",
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw SQLiteFTS5CapabilityProbeError(operation: "open", message: "Unable to open in-memory SQLite")
        }
        defer {
            sqlite3_close_v2(database)
        }

        let sqliteVersion = try scalarText(versionSQL, database: database)
        let compileOptionUsed = try scalarInt(compileOptionSQL, database: database)
        try execute(createSQL, operation: "create FTS5 table", database: database)
        try execute(insertSQL, operation: "insert FTS5 row", database: database)

        let match = try queryMatch(database: database)
        try execute(dropSQL, operation: "drop FTS5 table", database: database)
        let tableCount = try scalarInt(
            "SELECT count(*) FROM sqlite_master WHERE name = 'capability_probe'",
            database: database
        )

        let environment = ProcessInfo.processInfo.environment
        return SQLiteFTS5CapabilityReport(
            targetLabel: environment["OPENCAST_CAPABILITY_TARGET"] ?? "unspecified",
            runtime: environment["SIMULATOR_UDID"] == nil ? "physical-device" : "simulator",
            simulatorUDID: environment["SIMULATOR_UDID"],
            hardwareModel: environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            sqliteVersion: sqliteVersion,
            enableFTS5CompileOptionUsed: compileOptionUsed,
            functionalMatchRowID: match.rowID,
            bm25Score: match.score,
            tableDropped: tableCount == 0,
            sql: [
                versionSQL,
                compileOptionSQL,
                createSQL,
                insertSQL,
                querySQL,
                dropSQL
            ]
        )
    }

    private static func execute(
        _ sql: String,
        operation: String,
        database: OpaquePointer
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(operation: operation, database: database)
        }
    }

    private static func scalarText(_ sql: String, database: OpaquePointer) throws -> String {
        let statement = try prepare(sql, operation: "read text scalar", database: database)
        defer {
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else {
            throw error(operation: "read text scalar", database: database)
        }
        return String(cString: value)
    }

    private static func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int {
        let statement = try prepare(sql, operation: "read integer scalar", database: database)
        defer {
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw error(operation: "read integer scalar", database: database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func queryMatch(database: OpaquePointer) throws -> (rowID: Int, score: Double) {
        let statement = try prepare(querySQL, operation: "query FTS5 table", database: database)
        defer {
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw error(operation: "query FTS5 table", database: database)
        }
        return (
            Int(sqlite3_column_int64(statement, 0)),
            sqlite3_column_double(statement, 1)
        )
    }

    private static func prepare(
        _ sql: String,
        operation: String,
        database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw error(operation: operation, database: database)
        }
        return statement
    }

    private static func error(
        operation: String,
        database: OpaquePointer
    ) -> SQLiteFTS5CapabilityProbeError {
        SQLiteFTS5CapabilityProbeError(
            operation: operation,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func machineIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct SQLiteFTS5CapabilityReport: Codable {
    let targetLabel: String
    let runtime: String
    let simulatorUDID: String?
    let hardwareModel: String
    let operatingSystem: String
    let sqliteVersion: String
    let enableFTS5CompileOptionUsed: Int
    let functionalMatchRowID: Int
    let bm25Score: Double
    let tableDropped: Bool
    let sql: [String]
}

private struct SQLiteFTS5CapabilityProbeError: Error, CustomStringConvertible {
    let operation: String
    let message: String

    var description: String {
        "SQLite FTS5 capability \(operation) failed: \(message)"
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
