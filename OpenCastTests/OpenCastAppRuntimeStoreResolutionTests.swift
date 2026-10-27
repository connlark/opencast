import Foundation
import os
import SQLite3
import Testing
@testable import OpenCast

@MainActor
@Suite("Launch store resolution")
struct OpenCastAppRuntimeStoreResolutionTests {
    /// The two playlist tables an earlier build's device-local store holds
    /// (`LegacyLocalPlaylistReaderTests` keeps them verbatim).
    private static let playlistTablesSQL = """
        CREATE TABLE ZPLAYLISTRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZHIDESPLAYED INTEGER, ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZDEDUPEUUID VARCHAR, ZKINDRAWVALUE VARCHAR, ZNAME VARCHAR, ZORIGINRAWVALUE VARCHAR, ZPLAYLISTID VARCHAR, ZRULEJSON VARCHAR, ZSORTKEY VARCHAR, ZSYMBOLNAME VARCHAR, ZTINTKEY VARCHAR );
        CREATE TABLE ZPLAYLISTITEMRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZADDEDAT TIMESTAMP, ZDURATION FLOAT, ZPUBLISHEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZARTWORKURL VARCHAR, ZAUDIOURL VARCHAR, ZDEDUPEUUID VARCHAR, ZEPISODEID VARCHAR, ZEPISODETITLE VARCHAR, ZITEMID VARCHAR, ZPLAYLISTID VARCHAR, ZPODCASTID VARCHAR, ZPODCASTTITLE VARCHAR, ZSORTKEY VARCHAR );
        """
    private static let testLogger = Logger(subsystem: "com.connor.opencast", category: "StoreRelocationTests")

    @Test("After a move, the legacy playlist read opens the app copy and each store's line is logged")
    func movedLayoutReadsTheAppCopy() throws {
        let root = try Self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = Self.layout(in: root)
        try Self.writePlaylistStore(playlistID: "group-copy", at: layout.local.groupURL)
        try Self.writePlaylistStore(playlistID: "app-copy", at: layout.local.appURL)
        var moved = layout
        moved.synced.resolvedURL = moved.synced.appURL
        moved.local.resolvedURL = moved.local.appURL
        var relocatedLayouts: [ModelStoreLayout] = []

        let stores = OpenCastAppRuntime.resolveModelStores(
            layout: layout,
            usesInMemoryStore: false,
            relocate: { input in
                relocatedLayouts.append(input)
                return (moved, Self.results(.moved, for: moved))
            },
            relocationLog: Self.relocationLog(in: root),
            defaults: defaults
        )

        #expect(relocatedLayouts == [layout])
        #expect(stores.layout == moved)
        #expect(stores.legacyLocalPlaylists?.playlists.map(\.playlistID) == ["app-copy"])
        let logLines = try String(contentsOf: Self.logURL(in: root), encoding: .utf8).split(separator: "\n")
        #expect(logLines.count == 2)
        #expect(logLines.allSatisfy { $0.contains(" moved; ") })
    }

    @Test("After a deferral, the legacy playlist read opens the group copy")
    func deferredLayoutReadsTheGroupCopy() throws {
        let root = try Self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = Self.layout(in: root)
        try Self.writePlaylistStore(playlistID: "group-copy", at: layout.local.groupURL)
        try Self.writePlaylistStore(playlistID: "app-copy", at: layout.local.appURL)

        let stores = OpenCastAppRuntime.resolveModelStores(
            layout: layout,
            usesInMemoryStore: false,
            relocate: { input in (input, Self.results(.deferred(.unsupported("fixture")), for: input)) },
            relocationLog: Self.relocationLog(in: root),
            defaults: defaults
        )

        #expect(stores.layout == layout)
        #expect(stores.legacyLocalPlaylists?.playlists.map(\.playlistID) == ["group-copy"])
    }

    @Test("A legacy read that fails yields nothing and leaves the migration unrecorded")
    func failedReadLeavesTheMigrationUnrecorded() throws {
        let root = try Self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = Self.layout(in: root)
        var moved = layout
        moved.local.resolvedURL = moved.local.appURL
        try FileManager.default.createDirectory(
            at: moved.local.appURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(ascii: "x"), count: 4096).write(to: moved.local.appURL)

        let stores = OpenCastAppRuntime.resolveModelStores(
            layout: layout,
            usesInMemoryStore: false,
            relocate: { _ in (moved, Self.results(.moved, for: moved)) },
            relocationLog: Self.relocationLog(in: root),
            defaults: defaults
        )

        #expect(stores.layout == moved)
        #expect(stores.legacyLocalPlaylists == nil)
        #expect(defaults.object(forKey: PlaylistLocalStoreMigration.completedDefaultsKey) == nil)
    }

    @Test("A recorded migration skips the legacy read but not the relocation")
    func recordedMigrationSkipsTheRead() throws {
        let root = try Self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PlaylistLocalStoreMigration.completedDefaultsKey)
        let layout = Self.layout(in: root)
        try Self.writePlaylistStore(playlistID: "group-copy", at: layout.local.groupURL)
        var relocationCount = 0

        let stores = OpenCastAppRuntime.resolveModelStores(
            layout: layout,
            usesInMemoryStore: false,
            relocate: { input in
                relocationCount += 1
                return (input, Self.results(.deferred(.unsupported("fixture")), for: input))
            },
            relocationLog: Self.relocationLog(in: root),
            defaults: defaults
        )

        #expect(relocationCount == 1)
        #expect(stores.legacyLocalPlaylists == nil)
    }

    @Test("An in-memory launch skips the relocation, the log and the legacy read")
    func inMemoryLaunchSkipsRelocationAndRead() throws {
        let root = try Self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = Self.layout(in: root)
        try Self.writePlaylistStore(playlistID: "group-copy", at: layout.local.groupURL)
        var relocationCount = 0

        let stores = OpenCastAppRuntime.resolveModelStores(
            layout: layout,
            usesInMemoryStore: true,
            relocate: { input in
                relocationCount += 1
                return (input, [])
            },
            relocationLog: Self.relocationLog(in: root),
            defaults: defaults
        )

        #expect(relocationCount == 0)
        #expect(stores.layout == layout)
        #expect(stores.legacyLocalPlaylists == nil)
        #expect(!FileManager.default.fileExists(atPath: Self.logURL(in: root).path(percentEncoded: false)))
    }

    // MARK: - Fixtures

    private static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAppRuntimeStoreResolutionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OpenCastAppRuntimeStoreResolutionTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private static func layout(in root: URL) -> ModelStoreLayout {
        ModelStoreLayout(
            synced: location(OpenCastModelContainerFactory.syncedConfigurationName, in: root),
            local: location(OpenCastModelContainerFactory.localConfigurationName, in: root)
        )
    }

    private static func location(_ name: String, in root: URL) -> ModelStoreLocation {
        let groupURL = root.appending(path: "group/Library/Application Support/\(name).store")
        return ModelStoreLocation(
            configurationName: name,
            groupURL: groupURL,
            appURL: root.appending(path: "app/Library/Application Support/\(name).store"),
            resolvedURL: groupURL
        )
    }

    private static func results(
        _ outcome: ModelStoreRelocationResult.Outcome,
        for layout: ModelStoreLayout
    ) -> [ModelStoreRelocationResult] {
        [layout.synced, layout.local].map { store in
            ModelStoreRelocationResult(
                configurationName: store.configurationName,
                resolvedURL: store.resolvedURL,
                outcome: outcome,
                storeUUID: nil,
                walSize: nil,
                companions: [],
                notes: []
            )
        }
    }

    private static func logURL(in root: URL) -> URL {
        root.appending(path: "Diagnostics/store-relocation.log")
    }

    private static func relocationLog(in root: URL) -> ModelStoreRelocationLog {
        ModelStoreRelocationLog(fileURL: logURL(in: root), logger: testLogger)
    }

    /// One playlist row, so the snapshot names the file it was read from.
    private static func writePlaylistStore(playlistID: String, at storeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            storeURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        defer { sqlite3_close_v2(handle) }
        guard openCode == SQLITE_OK, let handle else {
            throw LocalLibraryCacheStoreError(operation: "test open", message: "unable to open database")
        }
        let sql = playlistTablesSQL + """
            INSERT INTO ZPLAYLISTRECORD (Z_PK, Z_ENT, Z_OPT, ZHIDESPLAYED, ZCREATEDAT, ZUPDATEDAT, ZKINDRAWVALUE, ZNAME, ZORIGINRAWVALUE, ZPLAYLISTID)
            VALUES (1, 1, 1, 0, 813000000, 813000100, 'manual', 'Fixture', 'user', '\(playlistID)');
            """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalLibraryCacheStoreError(operation: "test exec", message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}
