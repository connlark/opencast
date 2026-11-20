import Foundation
import SQLite3

/// Reads the SQLite file directly: the local configuration no longer declares these entities, so
/// SwiftData would not surface them. A plain open (no `immutable`, no `nolock`) also reads rows
/// still in the write-ahead log.
nonisolated enum LegacyLocalPlaylistReader {
    private static let playlistTableName = "ZPLAYLISTRECORD"
    private static let itemTableName = "ZPLAYLISTITEMRECORD"

    static func read(storeURL: URL) throws -> LegacyLocalPlaylistSnapshot? {
        let path = storeURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        defer {
            sqlite3_close_v2(handle)
        }
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            throw LocalLibraryCacheStoreError(operation: "open legacy playlists", message: message)
        }

        guard try hasPlaylistTables(db: handle) else {
            return nil
        }
        return LegacyLocalPlaylistSnapshot(
            playlists: try readPlaylists(db: handle),
            items: try readItems(db: handle)
        )
    }

    private static func hasPlaylistTables(db: OpaquePointer) throws -> Bool {
        var tableNames: Set<String> = []
        try LocalCacheSQLite.query(
            """
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name IN ('\(playlistTableName)', '\(itemTableName)')
            """,
            operation: "read legacy playlist tables",
            db: db
        ) { statement in
            if let name = LocalCacheSQLite.columnText(statement, 0) {
                tableNames.insert(name)
            }
        }
        return tableNames.contains(playlistTableName) && tableNames.contains(itemTableName)
    }

    /// Leaves out the sort key and symbol columns, which some older tables lack.
    private static func readPlaylists(db: OpaquePointer) throws -> [LegacyLocalPlaylistSnapshot.Playlist] {
        var playlists: [LegacyLocalPlaylistSnapshot.Playlist] = []
        try LocalCacheSQLite.query(
            """
            SELECT ZPLAYLISTID, ZNAME, ZKINDRAWVALUE, ZRULEJSON, ZHIDESPLAYED, ZTINTKEY,
                   ZORIGINRAWVALUE, ZCREATEDAT, ZUPDATEDAT
              FROM \(playlistTableName) ORDER BY Z_PK
            """,
            operation: "read legacy playlists",
            db: db
        ) { statement in
            playlists.append(
                LegacyLocalPlaylistSnapshot.Playlist(
                    playlistID: requiredText(statement, 0),
                    name: requiredText(statement, 1),
                    kindRawValue: requiredText(statement, 2),
                    ruleJSON: LocalCacheSQLite.columnText(statement, 3),
                    hidesPlayed: (LocalCacheSQLite.columnInt(statement, 4) ?? 0) != 0,
                    tintKey: LocalCacheSQLite.columnText(statement, 5),
                    originRawValue: requiredText(statement, 6),
                    createdAt: requiredDate(statement, 7),
                    updatedAt: requiredDate(statement, 8)
                )
            )
        }
        return playlists
    }

    private static func readItems(db: OpaquePointer) throws -> [LegacyLocalPlaylistSnapshot.Item] {
        var items: [LegacyLocalPlaylistSnapshot.Item] = []
        try LocalCacheSQLite.query(
            """
            SELECT ZITEMID, ZPLAYLISTID, ZEPISODEID, ZPODCASTID, ZSORTKEY, ZADDEDAT, ZUPDATEDAT,
                   ZEPISODETITLE, ZPODCASTTITLE, ZARTWORKURL, ZAUDIOURL, ZDURATION, ZPUBLISHEDAT
              FROM \(itemTableName) ORDER BY Z_PK
            """,
            operation: "read legacy playlist items",
            db: db
        ) { statement in
            items.append(
                LegacyLocalPlaylistSnapshot.Item(
                    itemID: requiredText(statement, 0),
                    playlistID: requiredText(statement, 1),
                    episodeID: requiredText(statement, 2),
                    podcastID: requiredText(statement, 3),
                    sortKey: requiredText(statement, 4),
                    addedAt: requiredDate(statement, 5),
                    updatedAt: requiredDate(statement, 6),
                    episodeTitle: requiredText(statement, 7),
                    podcastTitle: requiredText(statement, 8),
                    artworkURL: LocalCacheSQLite.columnText(statement, 9),
                    audioURL: LocalCacheSQLite.columnText(statement, 10),
                    duration: LocalCacheSQLite.columnDouble(statement, 11),
                    publishedAt: optionalDate(statement, 12)
                )
            )
        }
        return items
    }

    private static func requiredText(_ statement: OpaquePointer, _ index: Int32) -> String {
        LocalCacheSQLite.columnText(statement, index) ?? ""
    }

    private static func requiredDate(_ statement: OpaquePointer, _ index: Int32) -> Date {
        optionalDate(statement, index) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// Seconds since 2001-01-01, not the cache store's 1970 epoch. A whole-second value has
    /// INTEGER storage, so the column is read as a double whatever its storage class.
    private static func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        LocalCacheSQLite.columnDouble(statement, index).map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
