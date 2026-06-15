import Foundation
import OpenCastCore
import SQLite3

/// SQLite-backed local cache store.
///
/// Owns a single serialized connection. List loads project every column except
/// `show_notes_html`; episode detail fetches the full row lazily by ID.
actor SQLiteLocalLibraryCacheStore: LocalLibraryCacheStore {
    private nonisolated static let legacyImportCompleteKey = "legacy_swiftdata_import_complete"

    private let databaseURL: URL?
    private var connection: OpaquePointer?

    /// - Parameter databaseURL: `nil` opens a private in-memory database.
    init(databaseURL: URL?) {
        self.databaseURL = databaseURL
    }

    isolated deinit {
        if let connection {
            sqlite3_close_v2(connection)
        }
    }

    static func inMemory() -> SQLiteLocalLibraryCacheStore {
        SQLiteLocalLibraryCacheStore(databaseURL: nil)
    }

    nonisolated static func defaultDatabaseURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appending(path: "OpenCast", directoryHint: .isDirectory)
            .appending(path: "LocalLibraryCache.sqlite")
    }

    // MARK: - LocalLibraryCacheStore

    func loadLibrary(activePodcastIDs: Set<String>) throws -> LocalLibraryCacheSnapshot {
        let db = try database()

        var podcastsByFeedURL: [String: PodcastCacheSnapshot] = [:]
        try query(
            """
            SELECT feed_url, title, author, summary, website_url, artwork_url,
                   artwork_preview_version, artwork_preview_canonical_url_key,
                   artwork_preview_source_hash, artwork_preview_pixel_width,
                   artwork_preview_pixel_height, artwork_preview_rgb_data, updated_at
            FROM podcast_cache
            """,
            operation: "podcast load",
            db: db
        ) { statement in
            let podcast = podcastSnapshot(from: statement)
            if podcastsByFeedURL[podcast.feedURL] == nil {
                podcastsByFeedURL[podcast.feedURL] = podcast
            }
        }

        var episodes: [EpisodeListItemSnapshot] = []
        if !activePodcastIDs.isEmpty {
            try query(
                """
                SELECT \(Self.episodeListColumns)
                FROM episode_cache
                WHERE podcast_id IN (SELECT value FROM json_each(?))
                ORDER BY published_at DESC, episode_id ASC
                """,
                operation: "episode list load",
                db: db,
                bindings: { statement in
                    try bind(jsonArray(activePodcastIDs), at: 1, statement: statement, db: db, operation: "episode list load")
                }
            ) { statement in
                episodes.append(episodeListItemSnapshot(from: statement))
            }
            // Stable re-sort of the SQL-ordered rows restores the
            // localizedStandardCompare tiebreak for undated episodes, which
            // SQLite collations cannot express.
            episodes.sort(by: EpisodeListItemSnapshot.newestFirst)
        }

        var refreshLogs: [RefreshLogSnapshot] = []
        try query(
            """
            SELECT refresh_id, feed_url, started_at, finished_at, error_message
            FROM refresh_log
            ORDER BY started_at DESC, (finished_at IS NULL) ASC, finished_at DESC,
                     feed_url ASC, refresh_id ASC
            """,
            operation: "refresh log load",
            db: db
        ) { statement in
            refreshLogs.append(refreshLogSnapshot(from: statement))
        }

        return LocalLibraryCacheSnapshot(
            podcastsByFeedURL: podcastsByFeedURL,
            episodes: episodes,
            refreshLogs: refreshLogs
        )
    }

    func episodeDetail(episodeID: String) throws -> EpisodeDetailSnapshot? {
        let db = try database()
        var detail: EpisodeDetailSnapshot?
        try query(
            """
            SELECT \(Self.episodeListColumns), show_notes_html
            FROM episode_cache
            WHERE episode_id = ?
            LIMIT 1
            """,
            operation: "episode detail load",
            db: db,
            bindings: { statement in
                try bind(episodeID, at: 1, statement: statement, db: db, operation: "episode detail load")
            }
        ) { statement in
            detail = EpisodeDetailSnapshot(
                listItem: episodeListItemSnapshot(from: statement),
                showNotesHTML: columnText(statement, 17)
            )
        }
        return detail
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) throws -> [String: String] {
        guard !activePodcastIDs.isEmpty else {
            return [:]
        }

        let db = try database()
        var showNotesByEpisodeID: [String: String] = [:]
        try query(
            """
            SELECT episode_id, show_notes_html
            FROM episode_cache
            WHERE show_notes_html IS NOT NULL
              AND podcast_id IN (SELECT value FROM json_each(?))
            """,
            operation: "show notes load",
            db: db,
            bindings: { statement in
                try bind(jsonArray(activePodcastIDs), at: 1, statement: statement, db: db, operation: "show notes load")
            }
        ) { statement in
            guard let episodeID = columnText(statement, 0), let showNotes = columnText(statement, 1) else {
                return
            }
            showNotesByEpisodeID[episodeID] = showNotes
        }
        return showNotesByEpisodeID
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) throws {
        try inTransaction("feed upsert") { db in
            let operation = "feed upsert"
            let podcast = snapshot.podcast
            let feedURL = podcast.id.rawValue
            let podcastArtworkURL = podcast.artworkURL?.absoluteString

            try run(
                """
                INSERT INTO podcast_cache (feed_url, title, author, summary, website_url, artwork_url, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(feed_url) DO UPDATE SET
                    title = excluded.title,
                    author = excluded.author,
                    summary = excluded.summary,
                    website_url = excluded.website_url,
                    artwork_url = excluded.artwork_url,
                    updated_at = excluded.updated_at
                """,
                operation: operation,
                db: db
            ) { statement in
                try bind(feedURL, at: 1, statement: statement, db: db, operation: operation)
                try bind(podcast.title, at: 2, statement: statement, db: db, operation: operation)
                try bind(podcast.author, at: 3, statement: statement, db: db, operation: operation)
                try bind(podcast.summary, at: 4, statement: statement, db: db, operation: operation)
                try bind(podcast.websiteURL?.absoluteString, at: 5, statement: statement, db: db, operation: operation)
                try bind(podcastArtworkURL, at: 6, statement: statement, db: db, operation: operation)
                try bind(refreshedAt, at: 7, statement: statement, db: db, operation: operation)
            }

            try run(
                """
                UPDATE podcast_cache
                SET \(Self.clearedArtworkPreviewAssignments)
                WHERE feed_url = ?
                  AND artwork_preview_canonical_url_key IS NOT NULL
                  AND artwork_preview_canonical_url_key <> IFNULL(?, '')
                """,
                operation: operation,
                db: db
            ) { statement in
                try bind(feedURL, at: 1, statement: statement, db: db, operation: operation)
                try bind(ArtworkPreview.canonicalArtworkURLKey(for: podcastArtworkURL), at: 2, statement: statement, db: db, operation: operation)
            }

            let episodeUpsert = try prepare(
                """
                INSERT INTO episode_cache (episode_id, podcast_id, podcast_title, title, summary,
                                           show_notes_html, published_at, duration, audio_url,
                                           artwork_url, guid, cached_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(episode_id) DO UPDATE SET
                    podcast_id = excluded.podcast_id,
                    podcast_title = excluded.podcast_title,
                    title = excluded.title,
                    summary = excluded.summary,
                    show_notes_html = excluded.show_notes_html,
                    published_at = excluded.published_at,
                    duration = excluded.duration,
                    audio_url = excluded.audio_url,
                    artwork_url = excluded.artwork_url,
                    guid = excluded.guid,
                    cached_at = excluded.cached_at
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(episodeUpsert)
            }

            let episodePreviewClear = try prepare(
                """
                UPDATE episode_cache
                SET \(Self.clearedArtworkPreviewAssignments)
                WHERE episode_id = ?
                  AND artwork_preview_canonical_url_key IS NOT NULL
                  AND artwork_preview_canonical_url_key <> IFNULL(?, '')
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(episodePreviewClear)
            }

            for episode in snapshot.episodes {
                let artworkURL = episode.artworkURL?.absoluteString
                try bind(episode.id.rawValue, at: 1, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.podcastID.rawValue, at: 2, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.podcastTitle, at: 3, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.title, at: 4, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.summary, at: 5, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.showNotesHTML, at: 6, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.publishedAt, at: 7, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.duration, at: 8, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.audioURL?.absoluteString, at: 9, statement: episodeUpsert, db: db, operation: operation)
                try bind(artworkURL, at: 10, statement: episodeUpsert, db: db, operation: operation)
                try bind(episode.guid, at: 11, statement: episodeUpsert, db: db, operation: operation)
                try bind(refreshedAt, at: 12, statement: episodeUpsert, db: db, operation: operation)
                try step(episodeUpsert, operation: operation, db: db)
                try reset(episodeUpsert, operation: operation, db: db)

                try bind(episode.id.rawValue, at: 1, statement: episodePreviewClear, db: db, operation: operation)
                try bind(ArtworkPreview.canonicalArtworkURLKey(for: artworkURL), at: 2, statement: episodePreviewClear, db: db, operation: operation)
                try step(episodePreviewClear, operation: operation, db: db)
                try reset(episodePreviewClear, operation: operation, db: db)
            }
        }
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) throws {
        let operation = "episode artwork preview update"
        let db = try database()
        try run(
            """
            UPDATE episode_cache
            SET \(Self.artworkPreviewAssignments)
            WHERE episode_id = ? AND IFNULL(artwork_url, '') = IFNULL(?, '')
            """,
            operation: operation,
            db: db
        ) { statement in
            try bind(preview, statement: statement, db: db, operation: operation)
            try bind(episodeID, at: 7, statement: statement, db: db, operation: operation)
            try bind(artworkURL, at: 8, statement: statement, db: db, operation: operation)
        }
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) throws {
        let operation = "podcast artwork preview update"
        let db = try database()
        try run(
            """
            UPDATE podcast_cache
            SET \(Self.artworkPreviewAssignments)
            WHERE feed_url = ? AND IFNULL(artwork_url, '') = IFNULL(?, '')
            """,
            operation: operation,
            db: db
        ) { statement in
            try bind(preview, statement: statement, db: db, operation: operation)
            try bind(feedURL, at: 7, statement: statement, db: db, operation: operation)
            try bind(artworkURL, at: 8, statement: statement, db: db, operation: operation)
        }
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) throws {
        try inTransaction("refresh log insert") { db in
            let operation = "refresh log insert"
            try run(
                """
                INSERT OR REPLACE INTO refresh_log (refresh_id, feed_url, started_at, finished_at, error_message)
                VALUES (?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            ) { statement in
                try bind(log.refreshID, at: 1, statement: statement, db: db, operation: operation)
                try bind(log.feedURL, at: 2, statement: statement, db: db, operation: operation)
                try bind(log.startedAt, at: 3, statement: statement, db: db, operation: operation)
                try bind(log.finishedAt, at: 4, statement: statement, db: db, operation: operation)
                try bind(log.errorMessage, at: 5, statement: statement, db: db, operation: operation)
            }

            try run(
                """
                DELETE FROM refresh_log
                WHERE feed_url = ?
                  AND refresh_id NOT IN (
                    SELECT refresh_id FROM refresh_log
                    WHERE feed_url = ?
                    ORDER BY started_at DESC, (finished_at IS NULL) ASC, finished_at DESC, refresh_id ASC
                    LIMIT ?
                  )
                """,
                operation: operation,
                db: db
            ) { statement in
                try bind(log.feedURL, at: 1, statement: statement, db: db, operation: operation)
                try bind(log.feedURL, at: 2, statement: statement, db: db, operation: operation)
                try bind(retentionLimit, at: 3, statement: statement, db: db, operation: operation)
            }
        }
    }

    func deleteCache(forPodcastID podcastID: String) throws {
        try inTransaction("feed cache delete") { db in
            let operation = "feed cache delete"
            try run("DELETE FROM episode_cache WHERE podcast_id = ?", operation: operation, db: db) { statement in
                try bind(podcastID, at: 1, statement: statement, db: db, operation: operation)
            }
            try run("DELETE FROM podcast_cache WHERE feed_url = ?", operation: operation, db: db) { statement in
                try bind(podcastID, at: 1, statement: statement, db: db, operation: operation)
            }
            try run("DELETE FROM refresh_log WHERE feed_url = ?", operation: operation, db: db) { statement in
                try bind(podcastID, at: 1, statement: statement, db: db, operation: operation)
            }
        }
    }

    func deleteAllLocalCache() throws {
        try inTransaction("local cache delete") { db in
            try exec("DELETE FROM episode_cache", operation: "local cache delete", db: db)
            try exec("DELETE FROM podcast_cache", operation: "local cache delete", db: db)
            try exec("DELETE FROM refresh_log", operation: "local cache delete", db: db)
        }
    }

    func hasCompletedLegacyImport() throws -> Bool {
        let db = try database()
        var isComplete = false
        try query(
            "SELECT value FROM local_cache_meta WHERE key = ?",
            operation: "legacy import check",
            db: db,
            bindings: { statement in
                try bind(Self.legacyImportCompleteKey, at: 1, statement: statement, db: db, operation: "legacy import check")
            }
        ) { _ in
            isComplete = true
        }
        return isComplete
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) throws {
        try inTransaction("legacy import") { db in
            let operation = "legacy import"

            let podcastInsert = try prepare(
                """
                INSERT OR IGNORE INTO podcast_cache (feed_url, title, author, summary, website_url, artwork_url,
                                                     artwork_preview_version, artwork_preview_canonical_url_key,
                                                     artwork_preview_source_hash, artwork_preview_pixel_width,
                                                     artwork_preview_pixel_height, artwork_preview_rgb_data, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(podcastInsert)
            }
            for podcast in podcasts {
                try bind(podcast.feedURL, at: 1, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.title, at: 2, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.author, at: 3, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.summary, at: 4, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.websiteURL, at: 5, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.artworkURL, at: 6, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.artworkPreview, startingAt: 7, statement: podcastInsert, db: db, operation: operation)
                try bind(podcast.updatedAt, at: 13, statement: podcastInsert, db: db, operation: operation)
                try step(podcastInsert, operation: operation, db: db)
                try reset(podcastInsert, operation: operation, db: db)
            }

            let episodeInsert = try prepare(
                """
                INSERT OR IGNORE INTO episode_cache (episode_id, podcast_id, podcast_title, title, summary,
                                                     show_notes_html, published_at, duration, audio_url, artwork_url,
                                                     artwork_preview_version, artwork_preview_canonical_url_key,
                                                     artwork_preview_source_hash, artwork_preview_pixel_width,
                                                     artwork_preview_pixel_height, artwork_preview_rgb_data,
                                                     guid, cached_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(episodeInsert)
            }
            for episode in episodes {
                let listItem = episode.listItem
                try bind(listItem.episodeID, at: 1, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.podcastID, at: 2, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.podcastTitle, at: 3, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.title, at: 4, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.summary, at: 5, statement: episodeInsert, db: db, operation: operation)
                try bind(episode.showNotesHTML, at: 6, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.publishedAt, at: 7, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.duration, at: 8, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.audioURL, at: 9, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.artworkURL, at: 10, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.artworkPreview, startingAt: 11, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.guid, at: 17, statement: episodeInsert, db: db, operation: operation)
                try bind(listItem.cachedAt, at: 18, statement: episodeInsert, db: db, operation: operation)
                try step(episodeInsert, operation: operation, db: db)
                try reset(episodeInsert, operation: operation, db: db)
            }

            let logInsert = try prepare(
                """
                INSERT OR IGNORE INTO refresh_log (refresh_id, feed_url, started_at, finished_at, error_message)
                VALUES (?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(logInsert)
            }
            for log in refreshLogs {
                try bind(log.refreshID, at: 1, statement: logInsert, db: db, operation: operation)
                try bind(log.feedURL, at: 2, statement: logInsert, db: db, operation: operation)
                try bind(log.startedAt, at: 3, statement: logInsert, db: db, operation: operation)
                try bind(log.finishedAt, at: 4, statement: logInsert, db: db, operation: operation)
                try bind(log.errorMessage, at: 5, statement: logInsert, db: db, operation: operation)
                try step(logInsert, operation: operation, db: db)
                try reset(logInsert, operation: operation, db: db)
            }

            try run(
                "INSERT OR REPLACE INTO local_cache_meta (key, value) VALUES (?, ?)",
                operation: operation,
                db: db
            ) { statement in
                try bind(Self.legacyImportCompleteKey, at: 1, statement: statement, db: db, operation: operation)
                try bind("1", at: 2, statement: statement, db: db, operation: operation)
            }
        }
    }

    // MARK: - Connection and schema

    private func database() throws -> OpaquePointer {
        if let connection {
            return connection
        }

        let path: String
        if let databaseURL {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            path = databaseURL.path(percentEncoded: false)
        } else {
            path = ":memory:"
        }

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw LocalLibraryCacheStoreError(operation: "open", message: message)
        }

        do {
            try exec("PRAGMA journal_mode = WAL", operation: "open", db: handle)
            try exec("PRAGMA synchronous = NORMAL", operation: "open", db: handle)
            try exec("PRAGMA busy_timeout = 5000", operation: "open", db: handle)
            try exec(Self.schemaSQL, operation: "schema creation", db: handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }

        connection = handle
        return handle
    }

    private nonisolated static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS podcast_cache (
      feed_url TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      summary TEXT,
      website_url TEXT,
      artwork_url TEXT,
      artwork_preview_version INTEGER,
      artwork_preview_canonical_url_key TEXT,
      artwork_preview_source_hash TEXT,
      artwork_preview_pixel_width INTEGER,
      artwork_preview_pixel_height INTEGER,
      artwork_preview_rgb_data BLOB,
      updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS episode_cache (
      episode_id TEXT PRIMARY KEY,
      podcast_id TEXT NOT NULL,
      podcast_title TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT,
      show_notes_html TEXT,
      published_at REAL,
      duration REAL,
      audio_url TEXT,
      artwork_url TEXT,
      artwork_preview_version INTEGER,
      artwork_preview_canonical_url_key TEXT,
      artwork_preview_source_hash TEXT,
      artwork_preview_pixel_width INTEGER,
      artwork_preview_pixel_height INTEGER,
      artwork_preview_rgb_data BLOB,
      guid TEXT,
      cached_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS refresh_log (
      refresh_id TEXT PRIMARY KEY,
      feed_url TEXT NOT NULL,
      started_at REAL NOT NULL,
      finished_at REAL,
      error_message TEXT
    );

    CREATE TABLE IF NOT EXISTS local_cache_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS episode_cache_podcast_published_idx
    ON episode_cache(podcast_id, published_at DESC);

    CREATE INDEX IF NOT EXISTS episode_cache_published_idx
    ON episode_cache(published_at DESC);

    CREATE INDEX IF NOT EXISTS refresh_log_feed_started_idx
    ON refresh_log(feed_url, started_at DESC);
    """

    private nonisolated static let episodeListColumns = """
    episode_id, podcast_id, podcast_title, title, summary, published_at, duration, \
    audio_url, artwork_url, artwork_preview_version, artwork_preview_canonical_url_key, \
    artwork_preview_source_hash, artwork_preview_pixel_width, artwork_preview_pixel_height, \
    artwork_preview_rgb_data, guid, cached_at
    """

    private nonisolated static let artworkPreviewAssignments = """
    artwork_preview_version = ?, artwork_preview_canonical_url_key = ?, \
    artwork_preview_source_hash = ?, artwork_preview_pixel_width = ?, \
    artwork_preview_pixel_height = ?, artwork_preview_rgb_data = ?
    """

    private nonisolated static let clearedArtworkPreviewAssignments = """
    artwork_preview_version = NULL, artwork_preview_canonical_url_key = NULL, \
    artwork_preview_source_hash = NULL, artwork_preview_pixel_width = NULL, \
    artwork_preview_pixel_height = NULL, artwork_preview_rgb_data = NULL
    """

    // MARK: - Row mapping

    private func episodeListItemSnapshot(from statement: OpaquePointer) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: columnText(statement, 0) ?? "",
            podcastID: columnText(statement, 1) ?? "",
            podcastTitle: columnText(statement, 2) ?? "",
            title: columnText(statement, 3) ?? "",
            summary: columnText(statement, 4),
            publishedAt: columnDate(statement, 5),
            duration: columnDouble(statement, 6),
            audioURL: columnText(statement, 7),
            artworkURL: columnText(statement, 8),
            artworkPreview: ArtworkPreview(
                storedVersion: columnInt(statement, 9),
                canonicalArtworkURLKey: columnText(statement, 10),
                sourceHash: columnText(statement, 11),
                pixelWidth: columnInt(statement, 12),
                pixelHeight: columnInt(statement, 13),
                rgbData: columnData(statement, 14)
            ),
            guid: columnText(statement, 15),
            cachedAt: columnDate(statement, 16) ?? .distantPast
        )
    }

    private func podcastSnapshot(from statement: OpaquePointer) -> PodcastCacheSnapshot {
        PodcastCacheSnapshot(
            feedURL: columnText(statement, 0) ?? "",
            title: columnText(statement, 1) ?? "",
            author: columnText(statement, 2),
            summary: columnText(statement, 3),
            websiteURL: columnText(statement, 4),
            artworkURL: columnText(statement, 5),
            artworkPreview: ArtworkPreview(
                storedVersion: columnInt(statement, 6),
                canonicalArtworkURLKey: columnText(statement, 7),
                sourceHash: columnText(statement, 8),
                pixelWidth: columnInt(statement, 9),
                pixelHeight: columnInt(statement, 10),
                rgbData: columnData(statement, 11)
            ),
            updatedAt: columnDate(statement, 12) ?? .distantPast
        )
    }

    private func refreshLogSnapshot(from statement: OpaquePointer) -> RefreshLogSnapshot {
        RefreshLogSnapshot(
            refreshID: columnText(statement, 0) ?? "",
            feedURL: columnText(statement, 1) ?? "",
            startedAt: columnDate(statement, 2) ?? .distantPast,
            finishedAt: columnDate(statement, 3),
            errorMessage: columnText(statement, 4)
        )
    }

    // MARK: - SQLite plumbing

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func inTransaction<Result>(
        _ operation: String,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let db = try database()
        try exec("BEGIN IMMEDIATE TRANSACTION", operation: operation, db: db)
        do {
            let result = try body(db)
            try exec("COMMIT TRANSACTION", operation: operation, db: db)
            return result
        } catch {
            try? exec("ROLLBACK TRANSACTION", operation: operation, db: db)
            throw error
        }
    }

    private func exec(_ sql: String, operation: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func prepare(_ sql: String, operation: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw errorFromDatabase(operation: operation, db: db)
        }
        return statement
    }

    private func run(
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

    private func query(
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
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(statement)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw errorFromDatabase(operation: operation, db: db)
            }
        }
    }

    private func step(_ statement: OpaquePointer, operation: String, db: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func reset(_ statement: OpaquePointer, operation: String, db: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK, sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func errorFromDatabase(operation: String, db: OpaquePointer) -> LocalLibraryCacheStoreError {
        LocalLibraryCacheStoreError(operation: operation, message: String(cString: sqlite3_errmsg(db)))
    }

    private func jsonArray(_ values: Set<String>) throws -> String {
        String(decoding: try JSONEncoder().encode(values.sorted()), as: UTF8.self)
    }

    // MARK: - Binding

    private func bind(
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
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func bind(
        _ value: Date?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try bind(value?.timeIntervalSince1970, at: index, statement: statement, db: db, operation: operation)
    }

    private func bind(
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
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func bind(
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
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    private func bind(
        _ value: Data?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        let code = if let value {
            value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transientDestructor)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw errorFromDatabase(operation: operation, db: db)
        }
    }

    /// Binds the six artwork preview columns starting at column 1.
    private func bind(
        _ preview: ArtworkPreview,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try bind(Optional(preview), startingAt: 1, statement: statement, db: db, operation: operation)
    }

    /// Binds the six artwork preview columns starting at the given index.
    private func bind(
        _ preview: ArtworkPreview?,
        startingAt index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try bind(preview?.version, at: index, statement: statement, db: db, operation: operation)
        try bind(preview?.canonicalArtworkURLKey, at: index + 1, statement: statement, db: db, operation: operation)
        try bind(preview?.sourceHash, at: index + 2, statement: statement, db: db, operation: operation)
        try bind(preview?.pixelWidth, at: index + 3, statement: statement, db: db, operation: operation)
        try bind(preview?.pixelHeight, at: index + 4, statement: statement, db: db, operation: operation)
        try bind(preview?.rgbData, at: index + 5, statement: statement, db: db, operation: operation)
    }

    // MARK: - Column reading

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        columnDouble(statement, index).map(Date.init(timeIntervalSince1970:))
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
