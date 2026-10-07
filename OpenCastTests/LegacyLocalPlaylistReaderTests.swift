import Foundation
import OpenCastCore
import SQLite3
import Testing
@testable import OpenCast

@MainActor
@Suite("Legacy local playlist reader")
struct LegacyLocalPlaylistReaderTests {
    /// The table definitions an earlier build's device-local store holds,
    /// verbatim, so the fixtures match what the reader meets in the field.
    private static let playlistTableSQL = """
        CREATE TABLE ZPLAYLISTRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZHIDESPLAYED INTEGER, ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZDEDUPEUUID VARCHAR, ZKINDRAWVALUE VARCHAR, ZNAME VARCHAR, ZORIGINRAWVALUE VARCHAR, ZPLAYLISTID VARCHAR, ZRULEJSON VARCHAR, ZSORTKEY VARCHAR, ZSYMBOLNAME VARCHAR, ZTINTKEY VARCHAR );
        """
    private static let itemTableSQL = """
        CREATE TABLE ZPLAYLISTITEMRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZADDEDAT TIMESTAMP, ZDURATION FLOAT, ZPUBLISHEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZARTWORKURL VARCHAR, ZAUDIOURL VARCHAR, ZDEDUPEUUID VARCHAR, ZEPISODEID VARCHAR, ZEPISODETITLE VARCHAR, ZITEMID VARCHAR, ZPLAYLISTID VARCHAR, ZPODCASTID VARCHAR, ZPODCASTTITLE VARCHAR, ZSORTKEY VARCHAR );
        """
    private static let playlistTableWithoutRetiredColumnsSQL = """
        CREATE TABLE ZPLAYLISTRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZHIDESPLAYED INTEGER, ZCREATEDAT TIMESTAMP, ZUPDATEDAT TIMESTAMP, ZDEDUPEUUID VARCHAR, ZKINDRAWVALUE VARCHAR, ZNAME VARCHAR, ZORIGINRAWVALUE VARCHAR, ZPLAYLISTID VARCHAR, ZRULEJSON VARCHAR, ZTINTKEY VARCHAR );
        """
    private static let ruleJSON =
        "{\"downloadedOnly\":false,\"limit\":25,\"sortOrder\":\"oldestFirst\",\"status\":\"unplayed\",\"version\":1}"

    private enum Value {
        case text(String)
        case real(Double)
        case integer(Int64)
        case null
    }

    @Test("Every playlist and item column decodes exactly, with dates counted from 2001")
    func decodesEveryColumnExactly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableSQL + Self.itemTableSQL, databaseURL: storeURL)
        try insertPlaylist(
            pk: 1,
            playlistID: "legacy-playlist",
            name: "Legacy Smart",
            kind: "smart",
            ruleJSON: .text(Self.ruleJSON),
            hidesPlayed: 1,
            tintKey: .text("red"),
            createdAt: .real(813_011_142.85376),
            updatedAt: .real(813_011_160.50152099),
            databaseURL: storeURL
        )
        try insertItem(
            pk: 1,
            itemID: "legacy-item",
            playlistID: "legacy-playlist",
            episodeID: "legacy-episode",
            addedAt: .real(813_010_922.98736894),
            updatedAt: .real(813_010_958.27637696),
            artworkURL: .text("https://example.com/legacy.jpg"),
            audioURL: .text("https://example.com/legacy.mp3"),
            duration: .real(3_725),
            publishedAt: .integer(812_851_200),
            databaseURL: storeURL
        )
        #expect(try storageClass(of: "ZPUBLISHEDAT", in: "ZPLAYLISTITEMRECORD", databaseURL: storeURL) == "integer")

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        #expect(
            snapshot.playlists == [
                LegacyLocalPlaylistSnapshot.Playlist(
                    playlistID: "legacy-playlist",
                    name: "Legacy Smart",
                    kindRawValue: "smart",
                    ruleJSON: Self.ruleJSON,
                    hidesPlayed: true,
                    tintKey: "red",
                    originRawValue: "user",
                    createdAt: Date(timeIntervalSinceReferenceDate: 813_011_142.85376),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 813_011_160.50152099)
                )
            ]
        )
        #expect(
            snapshot.items == [
                LegacyLocalPlaylistSnapshot.Item(
                    itemID: "legacy-item",
                    playlistID: "legacy-playlist",
                    episodeID: "legacy-episode",
                    podcastID: "https://example.com/legacy.xml",
                    sortKey: "i",
                    addedAt: Date(timeIntervalSinceReferenceDate: 813_010_922.98736894),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 813_010_958.27637696),
                    episodeTitle: "Legacy Episode",
                    podcastTitle: "Legacy Show",
                    artworkURL: "https://example.com/legacy.jpg",
                    audioURL: "https://example.com/legacy.mp3",
                    duration: 3_725,
                    publishedAt: Date(timeIntervalSinceReferenceDate: 812_851_200)
                )
            ]
        )
    }

    @Test("Missing optional columns stay nil and a zero hides-played flag reads false")
    func nullOptionalsStayNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableSQL + Self.itemTableSQL, databaseURL: storeURL)
        try insertPlaylist(pk: 1, playlistID: "plain", name: "Plain", databaseURL: storeURL)
        try insertItem(pk: 1, itemID: "plain-item", playlistID: "plain", episodeID: "episode", databaseURL: storeURL)

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        let playlist = try #require(snapshot.playlists.first)
        #expect(playlist.ruleJSON == nil)
        #expect(playlist.tintKey == nil)
        #expect(!playlist.hidesPlayed)
        let item = try #require(snapshot.items.first)
        #expect(item.artworkURL == nil)
        #expect(item.audioURL == nil)
        #expect(item.duration == nil)
        #expect(item.publishedAt == nil)
    }

    @Test("Rows come back in primary-key order")
    func rowsComeBackInPrimaryKeyOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableSQL + Self.itemTableSQL, databaseURL: storeURL)
        for pk in [3, 1, 2] {
            try insertPlaylist(pk: pk, playlistID: "playlist-\(pk)", name: "Playlist \(pk)", databaseURL: storeURL)
            try insertItem(
                pk: pk,
                itemID: "item-\(pk)",
                playlistID: "playlist-1",
                episodeID: "episode-\(pk)",
                databaseURL: storeURL
            )
        }

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        #expect(snapshot.playlists.map(\.playlistID) == ["playlist-1", "playlist-2", "playlist-3"])
        #expect(snapshot.items.map(\.itemID) == ["item-1", "item-2", "item-3"])
    }

    @Test("A missing store file reads as nothing to migrate")
    func missingFileReturnsNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")

        #expect(try LegacyLocalPlaylistReader.read(storeURL: storeURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
    }

    @Test("A store that predates playlists reads as nothing to migrate")
    func storeWithoutPlaylistTablesReturnsNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute("CREATE TABLE ZLOCALPREFERENCERECORD ( Z_PK INTEGER PRIMARY KEY, ZKEY VARCHAR );", databaseURL: storeURL)

        #expect(try LegacyLocalPlaylistReader.read(storeURL: storeURL) == nil)
    }

    @Test("A store with only one of the two playlist tables reads as nothing to migrate")
    func storeWithOneTableReturnsNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlistsOnlyURL = directory.appending(path: "PlaylistsOnly.store")
        let itemsOnlyURL = directory.appending(path: "ItemsOnly.store")
        try execute(Self.playlistTableSQL, databaseURL: playlistsOnlyURL)
        try insertPlaylist(pk: 1, playlistID: "lonely", name: "Lonely", databaseURL: playlistsOnlyURL)
        try execute(Self.itemTableSQL, databaseURL: itemsOnlyURL)
        try insertItem(pk: 1, itemID: "lonely-item", playlistID: "lonely", episodeID: "episode", databaseURL: itemsOnlyURL)

        #expect(try LegacyLocalPlaylistReader.read(storeURL: playlistsOnlyURL) == nil)
        #expect(try LegacyLocalPlaylistReader.read(storeURL: itemsOnlyURL) == nil)
    }

    @Test("Empty playlist tables read as an empty snapshot")
    func emptyTablesReadAsEmptySnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableSQL + Self.itemTableSQL, databaseURL: storeURL)

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        #expect(snapshot.isEmpty)
    }

    @Test("A playlist table without the retired sort key and symbol columns still reads")
    func playlistTableWithoutRetiredColumnsStillReads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableWithoutRetiredColumnsSQL + Self.itemTableSQL, databaseURL: storeURL)
        try insertPlaylist(
            pk: 1,
            playlistID: "trimmed",
            name: "Trimmed",
            includesRetiredColumns: false,
            databaseURL: storeURL
        )

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        #expect(snapshot.playlists.map(\.playlistID) == ["trimmed"])
        #expect(snapshot.playlists.map(\.name) == ["Trimmed"])
    }

    @Test("Rows still in the write-ahead log are read")
    func rowsInTheWriteAheadLogAreRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "LocalDeviceData.store")
        try execute(Self.playlistTableSQL + Self.itemTableSQL, databaseURL: storeURL)

        let writer = try open(storeURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(writer) }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", db: writer)
        try insertPlaylist(pk: 1, playlistID: "logged", name: "Logged", db: writer)
        try insertItem(pk: 1, itemID: "logged-item", playlistID: "logged", episodeID: "episode", db: writer)
        let walPath = storeURL.path(percentEncoded: false) + "-wal"
        let walSize = try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int
        #expect((walSize ?? 0) > 0)

        let snapshot = try #require(try LegacyLocalPlaylistReader.read(storeURL: storeURL))

        #expect(snapshot.playlists.map(\.playlistID) == ["logged"])
        #expect(snapshot.items.map(\.itemID) == ["logged-item"])
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LegacyLocalPlaylistReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func open(_ databaseURL: URL, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &handle, flags, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close_v2(handle)
            throw LocalLibraryCacheStoreError(operation: "test open", message: "unable to open database")
        }
        return handle
    }

    private func withDatabase(_ databaseURL: URL, _ body: (OpaquePointer) throws -> Void) throws {
        let handle = try open(databaseURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(handle) }
        try body(handle)
    }

    private func execute(_ sql: String, databaseURL: URL) throws {
        try withDatabase(databaseURL) { db in
            try execute(sql, db: db)
        }
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalLibraryCacheStoreError(operation: "test exec", message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Values are bound rather than spelled into the SQL so each fractional
    /// timestamp is stored as exactly the double the test expects back.
    private func insert(_ sql: String, values: [Value], db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalLibraryCacheStoreError(operation: "test prepare", message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code = switch value {
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, LocalCacheSQLite.transientDestructor)
            case .real(let real):
                sqlite3_bind_double(statement, index, real)
            case .integer(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .null:
                sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw LocalLibraryCacheStoreError(operation: "test bind", message: String(cString: sqlite3_errmsg(db)))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalLibraryCacheStoreError(operation: "test insert", message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func insertPlaylist(
        pk: Int,
        playlistID: String,
        name: String,
        kind: String = "manual",
        ruleJSON: Value = .null,
        hidesPlayed: Int64 = 0,
        tintKey: Value = .null,
        createdAt: Value = .real(813_000_000.5),
        updatedAt: Value = .real(813_000_100.25),
        includesRetiredColumns: Bool = true,
        databaseURL: URL
    ) throws {
        try withDatabase(databaseURL) { db in
            try insertPlaylist(
                pk: pk,
                playlistID: playlistID,
                name: name,
                kind: kind,
                ruleJSON: ruleJSON,
                hidesPlayed: hidesPlayed,
                tintKey: tintKey,
                createdAt: createdAt,
                updatedAt: updatedAt,
                includesRetiredColumns: includesRetiredColumns,
                db: db
            )
        }
    }

    private func insertPlaylist(
        pk: Int,
        playlistID: String,
        name: String,
        kind: String = "manual",
        ruleJSON: Value = .null,
        hidesPlayed: Int64 = 0,
        tintKey: Value = .null,
        createdAt: Value = .real(813_000_000.5),
        updatedAt: Value = .real(813_000_100.25),
        includesRetiredColumns: Bool = true,
        db: OpaquePointer
    ) throws {
        var columns = [
            "Z_PK", "Z_ENT", "Z_OPT", "ZHIDESPLAYED", "ZCREATEDAT", "ZUPDATEDAT", "ZDEDUPEUUID",
            "ZKINDRAWVALUE", "ZNAME", "ZORIGINRAWVALUE", "ZPLAYLISTID", "ZRULEJSON", "ZTINTKEY"
        ]
        var values: [Value] = [
            .integer(Int64(pk)), .integer(1), .integer(1), .integer(hidesPlayed), createdAt, updatedAt,
            .text("legacy-dedupe-\(pk)"), .text(kind), .text(name), .text("user"), .text(playlistID),
            ruleJSON, tintKey
        ]
        if includesRetiredColumns {
            columns += ["ZSORTKEY", "ZSYMBOLNAME"]
            values += [.null, .null]
        }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try insert(
            "INSERT INTO ZPLAYLISTRECORD (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            values: values,
            db: db
        )
    }

    private func insertItem(
        pk: Int,
        itemID: String,
        playlistID: String,
        episodeID: String,
        addedAt: Value = .real(813_000_200.75),
        updatedAt: Value = .real(813_000_200.75),
        artworkURL: Value = .null,
        audioURL: Value = .null,
        duration: Value = .null,
        publishedAt: Value = .null,
        databaseURL: URL
    ) throws {
        try withDatabase(databaseURL) { db in
            try insertItem(
                pk: pk,
                itemID: itemID,
                playlistID: playlistID,
                episodeID: episodeID,
                addedAt: addedAt,
                updatedAt: updatedAt,
                artworkURL: artworkURL,
                audioURL: audioURL,
                duration: duration,
                publishedAt: publishedAt,
                db: db
            )
        }
    }

    private func insertItem(
        pk: Int,
        itemID: String,
        playlistID: String,
        episodeID: String,
        addedAt: Value = .real(813_000_200.75),
        updatedAt: Value = .real(813_000_200.75),
        artworkURL: Value = .null,
        audioURL: Value = .null,
        duration: Value = .null,
        publishedAt: Value = .null,
        db: OpaquePointer
    ) throws {
        try insert(
            """
            INSERT INTO ZPLAYLISTITEMRECORD (
                Z_PK, Z_ENT, Z_OPT, ZADDEDAT, ZDURATION, ZPUBLISHEDAT, ZUPDATEDAT, ZARTWORKURL, ZAUDIOURL,
                ZDEDUPEUUID, ZEPISODEID, ZEPISODETITLE, ZITEMID, ZPLAYLISTID, ZPODCASTID, ZPODCASTTITLE, ZSORTKEY
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            values: [
                .integer(Int64(pk)), .integer(2), .integer(1), addedAt, duration, publishedAt, updatedAt,
                artworkURL, audioURL, .text("legacy-item-dedupe-\(pk)"), .text(episodeID), .text("Legacy Episode"),
                .text(itemID), .text(playlistID), .text("https://example.com/legacy.xml"), .text("Legacy Show"),
                .text("i")
            ],
            db: db
        )
    }

    private func storageClass(of column: String, in table: String, databaseURL: URL) throws -> String? {
        var typeName: String?
        try withDatabase(databaseURL) { db in
            try LocalCacheSQLite.query("SELECT typeof(\(column)) FROM \(table)", operation: "test typeof", db: db) { statement in
                typeName = LocalCacheSQLite.columnText(statement, 0)
            }
        }
        return typeName
    }
}
