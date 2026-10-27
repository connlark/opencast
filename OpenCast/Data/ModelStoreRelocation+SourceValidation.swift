import Foundation
import SQLite3

nonisolated extension ModelStoreRelocation {
    /// What step 2 learned about the group store. A deferral keeps the facts
    /// read before it, for the log.
    nonisolated struct SourceValidation {
        var storeUUID: String?
        var walSize: Int?
        var companions: [String] = []
        var deferral: Deferral?
    }

    /// Step 2: establishes that the group file is a WAL-mode Core Data store
    /// with its log folded into the main file, not its integrity. The open
    /// is read-write without create, so a missing file is never conjured, and
    /// the handle never outlives the call. Every failure is a deferral; a
    /// checkpoint that advanced the main file before one is harmless.
    static func validateSource(
        _ group: Package,
        operations: any ModelStoreFileOperations
    ) -> SourceValidation {
        var validation = SourceValidation()
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            group.storeURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close_v2(handle)
            validation.deferral = .inaccessible("open \(group.storeName): \(message) (\(openCode))")
            return validation
        }
        let inspectionDeferral = inspect(handle, group: group, operations: operations, validation: &validation)
        let closeCode = sqlite3_close_v2(handle)
        if let inspectionDeferral {
            validation.deferral = inspectionDeferral
            return validation
        }
        guard closeCode == SQLITE_OK else {
            validation.deferral = .unsupported("close \(group.storeName): \(closeCode)")
            return validation
        }
        validation.deferral = checkClosedPackage(group, operations: operations)
        return validation
    }

    private static func inspect(
        _ db: OpaquePointer,
        group: Package,
        operations: any ModelStoreFileOperations,
        validation: inout SourceValidation
    ) -> Deferral? {
        // SQLite falls back to a read-only open when the file is not
        // writable; a store that cannot take writes must not move.
        guard sqlite3_db_readonly(db, "main") == 0 else {
            return .inaccessible("open \(group.storeName): read-only")
        }
        if let deferral = readSchema(db, validation: &validation) {
            return deferral
        }
        do {
            validation.walSize = try operations.status(at: group.url(group.walName))?.size
        } catch {
            return .inaccessible("probe \(group.walName): \(describe(error))")
        }
        let inventory: Package.Inventory
        do {
            inventory = try group.inventory(operations: operations)
        } catch {
            return .inaccessible("list \(group.directory.lastPathComponent): \(describe(error))")
        }
        validation.companions = inventory.companions
        guard inventory.unforeseen.isEmpty else {
            return .unsupported("unforeseen entries: \(inventory.unforeseen.joined(separator: ", "))")
        }
        return checkpoint(db)
    }

    /// The journal mode comes first: a file that is not a database fails
    /// here, and a mode other than WAL defers before any checkpoint, so the
    /// `-journal` rule never has to judge a rollback journal's leftovers.
    private static func readSchema(_ db: OpaquePointer, validation: inout SourceValidation) -> Deferral? {
        var journalMode: String?
        var tableCount: Int?
        do {
            try LocalCacheSQLite.query("PRAGMA journal_mode", operation: "read journal mode", db: db) { statement in
                journalMode = LocalCacheSQLite.columnText(statement, 0)
            }
        } catch {
            return .inaccessible(describe(error))
        }
        guard journalMode?.lowercased() == "wal" else {
            return .unsupported("journal mode \(journalMode ?? "unknown")")
        }
        do {
            try LocalCacheSQLite.query(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table'",
                operation: "count tables",
                db: db
            ) { statement in
                tableCount = LocalCacheSQLite.columnInt(statement, 0)
            }
        } catch {
            return .inaccessible(describe(error))
        }
        guard let tableCount, tableCount > 0 else {
            return .invalid("no tables")
        }
        return readStoreUUID(db, validation: &validation)
    }

    /// A statement that does not prepare names a missing table or column, so
    /// the store has no usable schema; a step that fails is an I/O problem.
    private static func readStoreUUID(_ db: OpaquePointer, validation: inout SourceValidation) -> Deferral? {
        let operation = "read Z_METADATA"
        let statement: OpaquePointer
        do {
            statement = try LocalCacheSQLite.prepare("SELECT Z_UUID FROM Z_METADATA", operation: operation, db: db)
        } catch {
            return .invalid(describe(error))
        }
        defer {
            sqlite3_finalize(statement)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let storeUUID = LocalCacheSQLite.columnText(statement, 0) else {
                return .invalid("Z_METADATA has no Z_UUID")
            }
            validation.storeUUID = storeUUID
            return nil
        case SQLITE_DONE:
            return .invalid("Z_METADATA has no row")
        default:
            return .inaccessible(describe(LocalCacheSQLite.error(operation: operation, db: db)))
        }
    }

    private static func checkpoint(_ db: OpaquePointer) -> Deferral? {
        var counts: (busy: Int, log: Int, checkpointed: Int)?
        do {
            try LocalCacheSQLite.query("PRAGMA wal_checkpoint(TRUNCATE)", operation: "checkpoint", db: db) { statement in
                counts = (
                    LocalCacheSQLite.columnInt(statement, 0) ?? -1,
                    LocalCacheSQLite.columnInt(statement, 1) ?? -1,
                    LocalCacheSQLite.columnInt(statement, 2) ?? -1
                )
            }
        } catch {
            return .unsupported(describe(error))
        }
        guard let counts else {
            return .unsupported("checkpoint answered no row")
        }
        guard counts.busy == 0, counts.log == counts.checkpointed else {
            return .unsupported("checkpoint busy \(counts.busy), log \(counts.log), checkpointed \(counts.checkpointed)")
        }
        return nil
    }

    /// After the clean close the log must be folded in and no rollback
    /// journal may exist. The `-shm` keeps its size; the next open rebuilds it.
    private static func checkClosedPackage(_ group: Package, operations: any ModelStoreFileOperations) -> Deferral? {
        let wal: ModelStoreFileStatus?
        let journal: ModelStoreFileStatus?
        do {
            wal = try operations.status(at: group.url(group.walName))
        } catch {
            return .inaccessible("probe \(group.walName): \(describe(error))")
        }
        do {
            journal = try operations.status(at: group.url(group.journalName))
        } catch {
            return .inaccessible("probe \(group.journalName): \(describe(error))")
        }
        if let wal, wal.size > 0 {
            return .unsupported("\(group.walName) holds \(wal.size) bytes after the close")
        }
        if journal != nil {
            return .unsupported("\(group.journalName) exists after the close")
        }
        return nil
    }
}
