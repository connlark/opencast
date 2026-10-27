import Foundation
import SQLite3
@testable import OpenCast

/// A "group" and an "app" `Library/Application Support` under one temporary
/// root, so the two share a volume for real, with raw-SQLite stores shaped
/// like Core Data's and companion trees with nested, non-empty files.
struct ModelStoreRelocationFixture {
    enum Entry: Hashable {
        case directory
        case file(Data)
    }

    struct StoreContents: Equatable {
        var uuid: String?
        var rows: [String]
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static let syncedName = "SyncedUserData"
    static let localName = "LocalDeviceData"

    let root: URL
    let groupDirectory: URL
    let appDirectory: URL

    init(createsDirectories: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ModelStoreRelocationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        groupDirectory = root.appending(path: "group/Library/Application Support", directoryHint: .isDirectory)
        appDirectory = root.appending(path: "app/Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createsDirectories {
            try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
    }

    func location(_ name: String = syncedName) -> ModelStoreLocation {
        let groupURL = groupDirectory.appending(path: "\(name).store")
        return ModelStoreLocation(
            configurationName: name,
            groupURL: groupURL,
            appURL: appDirectory.appending(path: "\(name).store"),
            resolvedURL: groupURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Stores

    /// A WAL-mode store at rest, as Core Data leaves one it has closed: every
    /// row in the main file, a zero-byte `-wal` and a `-shm` beside it.
    static func writeStore(at url: URL, uuid: String, rows: [String], journalMode: String = "WAL") throws {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(db) }
        try execute("PRAGMA journal_mode = \(journalMode);", db: db)
        try fill(db, uuid: uuid, rows: rows)
    }

    /// Rows that exist only in the `-wal`: written on a connection that never
    /// checkpoints, and copied with its log while that connection is open.
    /// Returns the size of the copied `-wal`.
    @discardableResult
    func writeStoreWithRowsInTheLog(at url: URL, uuid: String, rows: [String]) throws -> Int {
        let sourceDirectory = root.appending(path: "writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appending(path: url.lastPathComponent)
        let writer = try Self.open(source, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(writer) }
        try Self.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;", db: writer)
        try Self.fill(writer, uuid: uuid, rows: rows)
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.copyItem(at: Self.sidecar(source, "-wal"), to: Self.sidecar(url, "-wal"))

        let mainFileOnly = sourceDirectory.appending(path: "main-only-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: mainFileOnly)
        guard try Self.tableCount(at: mainFileOnly) == 0 else {
            throw FixtureError(description: "the main file already holds the schema; the log fixture proves nothing")
        }
        return try Self.size(of: Self.sidecar(url, "-wal"))
    }

    /// Opens a fresh connection, so rows still in a `-wal` are read too.
    static func contents(of url: URL) throws -> StoreContents {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(db) }
        return StoreContents(
            uuid: try strings("SELECT Z_UUID FROM Z_METADATA", db: db).first,
            rows: try strings("SELECT ZNAME FROM ZITEM ORDER BY Z_PK", db: db)
        )
    }

    static func tableCount(at url: URL) throws -> Int {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(db) }
        return try strings("SELECT count(*) FROM sqlite_master WHERE type = 'table'", db: db).first.flatMap(Int.init) ?? 0
    }

    static func execute(_ sql: String, at url: URL) throws {
        let db = try open(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(db) }
        try execute(sql, db: db)
    }

    static func sidecar(_ storeURL: URL, _ suffix: String) -> URL {
        storeURL.deletingLastPathComponent().appending(path: storeURL.lastPathComponent + suffix)
    }

    private static func fill(_ db: OpaquePointer, uuid: String, rows: [String]) throws {
        try execute(
            """
            CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR, Z_PLIST BLOB);
            CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);
            INSERT INTO Z_METADATA (Z_VERSION, Z_UUID, Z_PLIST) VALUES (1, '\(uuid)', x'62706c6973743030');
            """,
            db: db
        )
        for row in rows {
            try execute("INSERT INTO ZITEM (ZNAME) VALUES ('\(row)');", db: db)
        }
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw FixtureError(description: "open \(url.lastPathComponent) failed")
        }
        return handle
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func strings(_ sql: String, db: OpaquePointer) throws -> [String] {
        var values: [String] = []
        try LocalCacheSQLite.query(sql, operation: "fixture query", db: db) { statement in
            values.append(LocalCacheSQLite.columnText(statement, 0) ?? "")
        }
        return values
    }

    // MARK: - Companions and snapshots

    /// `.N_SUPPORT/_EXTERNAL_DATA/<files>` and `N_ckAssets/<nested>/<files>`,
    /// every file distinct and non-empty. Returns the names, sorted.
    @discardableResult
    static func writeCompanions(_ name: String = syncedName, in directory: URL, seed: String) throws -> [String] {
        let support = ".\(name)_SUPPORT"
        let assets = "\(name)_ckAssets"
        let files = [
            "\(support)/_EXTERNAL_DATA/0A1B2C3D-payload",
            "\(support)/_EXTERNAL_DATA/4E5F6A7B-payload",
            "\(support)/_EXTERNAL_DATA/8C9D0E1F-payload",
            "\(support)/_EXTERNAL_DATA/A2B3C4D5-payload",
            "\(assets)/zone-1/record-1/asset-1.bin",
            "\(assets)/zone-1/record-2/asset-2.bin",
            "\(assets)/zone-2/asset-3.bin",
            "\(assets)/asset-4.bin"
        ]
        for (index, file) in files.enumerated() {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var contents = Data(repeating: UInt8(truncatingIfNeeded: index + seed.utf8.count), count: 4_096 + index * 512)
            contents.append(Data("\(seed)-\(file)".utf8))
            try contents.write(to: url)
        }
        return [support, assets]
    }

    /// Every entry under `directory` by relative path, with file bytes.
    static func tree(at directory: URL) throws -> [String: Entry] {
        var tree: [String: Entry] = [:]
        for subpath in try FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            let url = directory.appending(path: subpath)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            tree[subpath] = isDirectory.boolValue ? .directory : .file(try Data(contentsOf: url))
        }
        return tree
    }

    /// The entries of one store's package (`N.store…`, `.N_…`, `N_…`), with
    /// the `-shm` left out: it is an index that every open rewrites.
    static func packageEntries(_ name: String = syncedName, at directory: URL) throws -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return [:]
        }
        return try tree(at: directory).filter { path, _ in
            let top = path.split(separator: "/").first.map(String.init) ?? path
            let isPackage = top.hasPrefix("\(name).store") || top.hasPrefix(".\(name)_") || top.hasPrefix("\(name)_")
            return isPackage && top != "\(name).store-shm"
        }
    }

    static func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? Int) ?? -1
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
