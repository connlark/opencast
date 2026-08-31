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
    private let episodeSearchRebuildBatchSize: Int
    private let episodeSearchRebuildCheckpoint: (@Sendable () async -> Void)?
    private var connection: OpaquePointer?
    private var episodeSearchIndexState = EpisodeSearchIndexState.unknown
    private var hasValidatedEpisodeSearchIndex = false
    private var episodeSearchIndexRebuildHandler: (@MainActor @Sendable () -> Void)?

    private enum EpisodeSearchIndexState {
        case unknown
        case needsRebuild
        case rebuilding
        case ready
        case unavailable
    }

    /// - Parameter databaseURL: `nil` opens a private in-memory database.
    init(
        databaseURL: URL?,
        episodeSearchRebuildBatchSize: Int =
            SQLiteEpisodeSearchIndex.rebuildBatchSize,
        episodeSearchRebuildCheckpoint: (@Sendable () async -> Void)? = nil
    ) {
        self.databaseURL = databaseURL
        self.episodeSearchRebuildBatchSize = max(
            episodeSearchRebuildBatchSize,
            1
        )
        self.episodeSearchRebuildCheckpoint = episodeSearchRebuildCheckpoint
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
                   artwork_preview_pixel_height, artwork_preview_rgb_data, updated_at,
                   language
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

        // Per-feed projection: routine reloads only feed recency lookups
        // (latest log, latest success), so loading every retained log row
        // (50 x feed count) here paid for history nobody read. The full
        // history stays behind allRefreshLogs() for diagnostics.
        // The UNION sits inside a subquery because a compound SELECT's ORDER
        // BY may only name result columns; the expression ordering lives on
        // the plain outer SELECT.
        var refreshLogs: [RefreshLogSnapshot] = []
        try query(
            """
            SELECT refresh_id, feed_url, started_at, finished_at, error_message
            FROM (
                SELECT refresh_id, feed_url, started_at, finished_at, error_message
                FROM (
                    SELECT refresh_id, feed_url, started_at, finished_at, error_message,
                           ROW_NUMBER() OVER (
                               PARTITION BY feed_url
                               ORDER BY started_at DESC, (finished_at IS NULL) ASC,
                                        finished_at DESC, refresh_id ASC
                           ) AS recency_rank
                    FROM refresh_log
                ) WHERE recency_rank = 1
                UNION
                SELECT refresh_id, feed_url, started_at, finished_at, error_message
                FROM (
                    SELECT refresh_id, feed_url, started_at, finished_at, error_message,
                           ROW_NUMBER() OVER (
                               PARTITION BY feed_url
                               ORDER BY started_at DESC, (finished_at IS NULL) ASC,
                                        finished_at DESC, refresh_id ASC
                           ) AS recency_rank
                    FROM refresh_log
                    WHERE IFNULL(error_message, '') = '' AND finished_at IS NOT NULL
                ) WHERE recency_rank = 1
            )
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

    func allRefreshLogs() throws -> [RefreshLogSnapshot] {
        let db = try database()
        var refreshLogs: [RefreshLogSnapshot] = []
        try query(
            """
            SELECT refresh_id, feed_url, started_at, finished_at, error_message
            FROM refresh_log
            ORDER BY started_at DESC, (finished_at IS NULL) ASC, finished_at DESC,
                     feed_url ASC, refresh_id ASC
            """,
            operation: "refresh log history load",
            db: db
        ) { statement in
            refreshLogs.append(refreshLogSnapshot(from: statement))
        }
        return refreshLogs
    }

    func episodeDetail(episodeID: String) throws -> EpisodeDetailSnapshot? {
        let db = try database()
        var detail: EpisodeDetailSnapshot?
        try query(
            """
            SELECT \(Self.episodeListColumns), show_notes_html, chapters_url
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
                showNotesHTML: columnText(statement, 17),
                chaptersURL: columnText(statement, 18)
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

    func prepareEpisodeSearchIndex() async throws {
        let db = try database()
        guard episodeSearchIndexState != .unavailable else {
            throw EpisodeSearchIndexError.unavailable
        }
        guard episodeSearchIndexState != .rebuilding else {
            return
        }

        if episodeSearchIndexState == .ready,
           hasValidatedEpisodeSearchIndex {
            return
        }
        if episodeSearchIndexState == .ready,
           try SQLiteEpisodeSearchIndex.isConsistent(in: db) {
            hasValidatedEpisodeSearchIndex = true
            return
        }

        episodeSearchIndexState = .rebuilding
        hasValidatedEpisodeSearchIndex = false
        do {
            try inTransaction("episode search rebuild start") { db in
                try SQLiteEpisodeSearchIndex.markNeedsRebuild(in: db)
                try SQLiteEpisodeSearchIndex.clear(in: db)
            }
            await episodeSearchRebuildCheckpoint?()

            var finalEpisodeID: String?
            while true {
                try Task.checkCancellation()
                let batch = try SQLiteEpisodeSearchIndex.rebuildBatch(
                    after: finalEpisodeID,
                    limit: episodeSearchRebuildBatchSize,
                    in: db
                )
                guard !batch.isEmpty else {
                    break
                }
                try inTransaction("episode search rebuild batch") { db in
                    try SQLiteEpisodeSearchIndex.replace(batch, in: db)
                }
                finalEpisodeID = batch.last?.episodeID
                await Task.yield()
            }

            try inTransaction("episode search rebuild finish") { db in
                guard try SQLiteEpisodeSearchIndex.isConsistent(in: db) else {
                    throw EpisodeSearchIndexError.invalidSchema
                }
                try SQLiteEpisodeSearchIndex.markReady(in: db)
            }
            episodeSearchIndexState = .ready
            hasValidatedEpisodeSearchIndex = true
            notifyEpisodeSearchIndexRebuilt()
        } catch {
            episodeSearchIndexState = .needsRebuild
            try? SQLiteEpisodeSearchIndex.markNeedsRebuild(in: db)
            throw error
        }
    }

    func setEpisodeSearchIndexRebuildHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        episodeSearchIndexRebuildHandler = handler
    }

    /// The rebuild paths clear the transcript FTS and segment tables but can
    /// repopulate only canonical `episode_cache` metadata. Notify the
    /// transcript owner so its documents converge without a relaunch.
    private func notifyEpisodeSearchIndexRebuilt() {
        guard let handler = episodeSearchIndexRebuildHandler else {
            return
        }
        Task {
            await handler()
        }
    }

    func searchEpisodes(
        _ request: EpisodeSearchIndexRequest
    ) async throws -> [EpisodeSearchIndexHit] {
        let db = try database()
        switch episodeSearchIndexState {
        case .ready:
            guard hasValidatedEpisodeSearchIndex else {
                throw EpisodeSearchIndexError.notReady("validating")
            }
        case .rebuilding:
            throw EpisodeSearchIndexError.rebuilding
        case .unknown:
            throw EpisodeSearchIndexError.notReady("unknown")
        case .needsRebuild:
            throw EpisodeSearchIndexError.notReady("needsRebuild")
        case .unavailable:
            throw EpisodeSearchIndexError.unavailable
        }

        do {
            return try SQLiteEpisodeSearchIndex.search(request, in: db)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            episodeSearchIndexState = .needsRebuild
            hasValidatedEpisodeSearchIndex = false
            try? SQLiteEpisodeSearchIndex.markNeedsRebuild(in: db)
            throw error
        }
    }

    func replaceEpisodeTranscriptSearchDocument(
        _ document: EpisodeSearchTranscriptDocument
    ) async throws {
        _ = try writableEpisodeSearchIndexDatabase()
        try inTransaction("episode transcript search replace") { db in
            try SQLiteEpisodeSearchIndex.replaceTranscript(document, in: db)
        }
    }

    func removeEpisodeTranscriptSearchDocument(
        episodeID: String
    ) async throws {
        _ = try writableEpisodeSearchIndexDatabase()
        try inTransaction("episode transcript search delete") { db in
            try SQLiteEpisodeSearchIndex.deleteTranscript(
                episodeID: episodeID,
                in: db
            )
        }
    }

    func reconcileEpisodeTranscriptSearchDocuments(
        retaining episodeIDs: Set<String>
    ) async throws {
        _ = try writableEpisodeSearchIndexDatabase()
        try inTransaction("episode transcript search reconcile") { db in
            try SQLiteEpisodeSearchIndex.removeTranscripts(
                except: episodeIDs,
                in: db
            )
        }
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) throws {
        try inTransaction("feed upsert") { db in
            let operation = "feed upsert"
            let podcast = snapshot.podcast
            let feedURL = podcast.id.rawValue
            let podcastArtworkURL = podcast.artworkURL?.absoluteString

            // The DO UPDATE WHERE clauses compare content only (never the
            // refresh timestamp), so a refresh that returns identical data
            // writes nothing: no WAL churn, and the timestamps keep meaning
            // "content last changed" — which is what the search-corpus cache
            // key needs to stop flushing on every refresh.
            try run(
                """
                INSERT INTO podcast_cache (feed_url, title, author, summary, website_url, artwork_url, updated_at, language)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(feed_url) DO UPDATE SET
                    title = excluded.title,
                    author = excluded.author,
                    summary = excluded.summary,
                    website_url = excluded.website_url,
                    artwork_url = excluded.artwork_url,
                    updated_at = excluded.updated_at,
                    language = excluded.language
                WHERE title IS NOT excluded.title
                   OR author IS NOT excluded.author
                   OR summary IS NOT excluded.summary
                   OR website_url IS NOT excluded.website_url
                   OR artwork_url IS NOT excluded.artwork_url
                   OR language IS NOT excluded.language
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
                try bind(podcast.languageCode, at: 8, statement: statement, db: db, operation: operation)
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
                                           artwork_url, guid, cached_at, chapters_url)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    cached_at = excluded.cached_at,
                    chapters_url = excluded.chapters_url
                WHERE podcast_id IS NOT excluded.podcast_id
                   OR podcast_title IS NOT excluded.podcast_title
                   OR title IS NOT excluded.title
                   OR summary IS NOT excluded.summary
                   OR show_notes_html IS NOT excluded.show_notes_html
                   OR published_at IS NOT excluded.published_at
                   OR duration IS NOT excluded.duration
                   OR audio_url IS NOT excluded.audio_url
                   OR artwork_url IS NOT excluded.artwork_url
                   OR guid IS NOT excluded.guid
                   OR chapters_url IS NOT excluded.chapters_url
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

            var changedSearchDocuments: [SQLiteEpisodeSearchDocument] = []
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
                try bind(episode.chaptersURL?.absoluteString, at: 13, statement: episodeUpsert, db: db, operation: operation)
                try step(episodeUpsert, operation: operation, db: db)
                let didChangeSearchableContent = sqlite3_changes(db) > 0
                try reset(episodeUpsert, operation: operation, db: db)

                if didChangeSearchableContent {
                    changedSearchDocuments.append(
                        SQLiteEpisodeSearchDocument(
                            episodeID: episode.id.rawValue,
                            podcastID: episode.podcastID.rawValue,
                            title: episode.title,
                            podcastTitle: episode.podcastTitle,
                            summaryHTML: episode.summary,
                            showNotesHTML: episode.showNotesHTML
                        )
                    )
                }

                try bind(episode.id.rawValue, at: 1, statement: episodePreviewClear, db: db, operation: operation)
                try bind(ArtworkPreview.canonicalArtworkURLKey(for: artworkURL), at: 2, statement: episodePreviewClear, db: db, operation: operation)
                try step(episodePreviewClear, operation: operation, db: db)
                try reset(episodePreviewClear, operation: operation, db: db)
            }

            _ = maintainEpisodeSearchIndex(in: db) {
                try SQLiteEpisodeSearchIndex.replace(
                    changedSearchDocuments,
                    in: db
                )
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

    func feedValidators(forPodcastID podcastID: String) throws -> FeedValidators? {
        let db = try database()
        var validators: FeedValidators?
        try query(
            "SELECT etag, last_modified, body_hash FROM podcast_cache WHERE feed_url = ?",
            operation: "feed validators load",
            db: db,
            bindings: { statement in
                try bind(podcastID, at: 1, statement: statement, db: db, operation: "feed validators load")
            }
        ) { statement in
            let loaded = FeedValidators(
                entityTag: columnText(statement, 0),
                lastModified: columnText(statement, 1),
                bodyHash: columnText(statement, 2)
            )
            validators = loaded.isEmpty ? nil : loaded
        }
        return validators
    }

    /// Touches only the validator columns: `updated_at` keeps meaning
    /// "content last changed" and must not move for an unchanged feed.
    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) throws {
        let operation = "feed validators update"
        let db = try database()
        try run(
            "UPDATE podcast_cache SET etag = ?, last_modified = ?, body_hash = ? WHERE feed_url = ?",
            operation: operation,
            db: db
        ) { statement in
            try bind(validators.entityTag, at: 1, statement: statement, db: db, operation: operation)
            try bind(validators.lastModified, at: 2, statement: statement, db: db, operation: operation)
            try bind(validators.bodyHash, at: 3, statement: statement, db: db, operation: operation)
            try bind(podcastID, at: 4, statement: statement, db: db, operation: operation)
        }
    }

    func cachedEpisodes(forPodcastID podcastID: String) throws -> [EpisodeListItemSnapshot] {
        let db = try database()
        var episodes: [EpisodeListItemSnapshot] = []
        try query(
            """
            SELECT \(Self.episodeListColumns)
            FROM episode_cache
            WHERE podcast_id = ?
            """,
            operation: "cached episode load",
            db: db,
            bindings: { statement in
                try bind(podcastID, at: 1, statement: statement, db: db, operation: "cached episode load")
            }
        ) { statement in
            episodes.append(episodeListItemSnapshot(from: statement))
        }
        return episodes
    }

    func deleteEpisodes(episodeIDs: [String]) throws {
        guard !episodeIDs.isEmpty else {
            return
        }
        try inTransaction("episode delete") { db in
            let operation = "episode delete"
            _ = maintainEpisodeSearchIndex(in: db) {
                try SQLiteEpisodeSearchIndex.deleteEpisodes(
                    episodeIDs: episodeIDs,
                    in: db
                )
            }
            try run(
                "DELETE FROM episode_cache WHERE episode_id IN (SELECT value FROM json_each(?))",
                operation: operation,
                db: db
            ) { statement in
                try bind(jsonArray(episodeIDs), at: 1, statement: statement, db: db, operation: operation)
            }
        }
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) throws {
        try inTransaction("notification feed health replace") { db in
            let operation = "notification feed health replace"
            try exec("DELETE FROM notification_feed_health", operation: operation, db: db)
            guard !records.isEmpty else {
                return
            }

            let insert = try prepare(
                """
                INSERT OR REPLACE INTO notification_feed_health
                (feed_url, consecutive_failures, last_http_status, last_error, last_polled_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(insert)
            }
            for record in records {
                try bind(record.feedURL, at: 1, statement: insert, db: db, operation: operation)
                try bind(record.health.consecutiveFailures, at: 2, statement: insert, db: db, operation: operation)
                try bind(record.health.lastHTTPStatus, at: 3, statement: insert, db: db, operation: operation)
                try bind(record.health.lastError, at: 4, statement: insert, db: db, operation: operation)
                try bind(record.health.lastPolledAtEpochSeconds, at: 5, statement: insert, db: db, operation: operation)
                try step(insert, operation: operation, db: db)
                try reset(insert, operation: operation, db: db)
            }
        }
    }

    func notificationFeedHealthByFeedURL() throws -> [String: NotificationFeedHealth] {
        let db = try database()
        var healthByFeedURL: [String: NotificationFeedHealth] = [:]
        try query(
            """
            SELECT feed_url, consecutive_failures, last_http_status, last_error, last_polled_at
            FROM notification_feed_health
            """,
            operation: "notification feed health load",
            db: db
        ) { statement in
            guard let feedURL = columnText(statement, 0) else {
                return
            }
            healthByFeedURL[feedURL] = NotificationFeedHealth(
                consecutiveFailures: columnInt(statement, 1) ?? 0,
                lastHTTPStatus: columnInt(statement, 2),
                lastError: columnText(statement, 3),
                lastPolledAtEpochSeconds: columnInt(statement, 4)
            )
        }
        return healthByFeedURL
    }

    func deleteCache(forPodcastID podcastID: String) throws {
        try inTransaction("feed cache delete") { db in
            let operation = "feed cache delete"
            _ = maintainEpisodeSearchIndex(in: db) {
                try SQLiteEpisodeSearchIndex.deletePodcast(
                    podcastID: podcastID,
                    in: db
                )
            }
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
            let didClearSearchIndex = maintainEpisodeSearchIndex(
                in: db,
                allowWhenNotReady: true
            ) {
                try SQLiteEpisodeSearchIndex.clear(in: db)
                try SQLiteEpisodeSearchIndex.markReady(in: db)
            }
            if didClearSearchIndex {
                episodeSearchIndexState = .ready
                hasValidatedEpisodeSearchIndex = true
                notifyEpisodeSearchIndexRebuilt()
            }
        }
    }

    /// Cumulative SQLite row changes on this connection. Test hook for
    /// asserting the change-detecting upsert skips unchanged rows.
    func totalRowChangeCount() throws -> Int {
        Int(sqlite3_total_changes64(try database()))
    }

    func checkpointForSearchBenchmark() throws {
        try exec(
            "PRAGMA wal_checkpoint(TRUNCATE)",
            operation: "search benchmark checkpoint",
            db: database()
        )
    }

    /// Current PRAGMA user_version. Test hook for the versioned migrations.
    func currentSchemaVersion() throws -> Int {
        try schemaVersion(db: try database())
    }

    /// Current derived-search lifecycle state. Test hook for rebuild/fallback
    /// transition assertions.
    func episodeSearchIndexStateDescription() throws -> String {
        _ = try database()
        return switch episodeSearchIndexState {
        case .unknown: "unknown"
        case .needsRebuild: "needsRebuild"
        case .rebuilding: "rebuilding"
        case .ready:
            hasValidatedEpisodeSearchIndex ? "ready" : "validating"
        case .unavailable: "unavailable"
        }
    }

    private func schemaVersion(db: OpaquePointer) throws -> Int {
        var version = 0
        try query("PRAGMA user_version", operation: "schema version", db: db) { statement in
            version = Int(sqlite3_column_int64(statement, 0))
        }
        return version
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
                                                     guid, cached_at, chapters_url)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                operation: operation,
                db: db
            )
            defer {
                sqlite3_finalize(episodeInsert)
            }
            var changedSearchDocuments: [SQLiteEpisodeSearchDocument] = []
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
                try bind(episode.chaptersURL, at: 19, statement: episodeInsert, db: db, operation: operation)
                try step(episodeInsert, operation: operation, db: db)
                let didInsert = sqlite3_changes(db) > 0
                try reset(episodeInsert, operation: operation, db: db)
                if didInsert {
                    changedSearchDocuments.append(
                        SQLiteEpisodeSearchDocument(
                            episodeID: listItem.episodeID,
                            podcastID: listItem.podcastID,
                            title: listItem.title,
                            podcastTitle: listItem.podcastTitle,
                            summaryHTML: listItem.summary,
                            showNotesHTML: episode.showNotesHTML
                        )
                    )
                }
            }
            _ = maintainEpisodeSearchIndex(in: db) {
                try SQLiteEpisodeSearchIndex.replace(
                    changedSearchDocuments,
                    in: db
                )
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
            // Pre-language databases: CREATE TABLE IF NOT EXISTS leaves the
            // existing schema untouched, so add the column when missing.
            try? exec("ALTER TABLE podcast_cache ADD COLUMN language TEXT", operation: "schema migration", db: handle)
            try? exec("ALTER TABLE episode_cache ADD COLUMN chapters_url TEXT", operation: "schema migration", db: handle)
            // Installed caches created the index before it was removed from
            // schemaSQL; no query shape ever chooses it.
            try? exec("DROP INDEX IF EXISTS episode_cache_published_idx", operation: "schema migration", db: handle)
            // Versioned migrations start here (PRAGMA user_version; version 0
            // predates versioning). The try?-ALTER pattern keeps version 1
            // idempotent for fresh databases whose CREATE TABLE already has
            // the columns.
            if try schemaVersion(db: handle) < 1 {
                try? exec("ALTER TABLE podcast_cache ADD COLUMN etag TEXT", operation: "schema migration", db: handle)
                try? exec("ALTER TABLE podcast_cache ADD COLUMN last_modified TEXT", operation: "schema migration", db: handle)
                try? exec("ALTER TABLE podcast_cache ADD COLUMN body_hash TEXT", operation: "schema migration", db: handle)
                try exec("PRAGMA user_version = 1", operation: "schema migration", db: handle)
            }

            // The search index is rebuildable derived data. An unavailable
            // FTS module must not prevent the canonical cache from opening;
            // search will use the legacy fallback and retry on next launch.
            do {
                try SQLiteEpisodeSearchIndex.ensureSchema(in: handle)
                if try schemaVersion(db: handle) < SQLiteEpisodeSearchIndex.schemaVersion {
                    try exec(
                        "PRAGMA user_version = \(SQLiteEpisodeSearchIndex.schemaVersion)",
                        operation: "episode search schema migration",
                        db: handle
                    )
                }
                let storedVersion = try SQLiteEpisodeSearchIndex.storedContentVersion(
                    in: handle
                )
                episodeSearchIndexState = storedVersion
                    == SQLiteEpisodeSearchIndex.contentVersion
                    ? .ready
                    : .needsRebuild
            } catch {
                episodeSearchIndexState = .unavailable
            }
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
      updated_at REAL NOT NULL,
      language TEXT,
      etag TEXT,
      last_modified TEXT,
      body_hash TEXT
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
      cached_at REAL NOT NULL,
      chapters_url TEXT
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

    CREATE TABLE IF NOT EXISTS notification_feed_health (
      feed_url TEXT PRIMARY KEY,
      consecutive_failures INTEGER NOT NULL,
      last_http_status INTEGER,
      last_error TEXT,
      last_polled_at INTEGER
    );

    CREATE INDEX IF NOT EXISTS episode_cache_podcast_published_idx
    ON episode_cache(podcast_id, published_at DESC);

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
            updatedAt: columnDate(statement, 12) ?? .distantPast,
            languageCode: columnText(statement, 13)
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

    @discardableResult
    private func writableEpisodeSearchIndexDatabase() throws -> OpaquePointer {
        let db = try database()
        switch episodeSearchIndexState {
        case .ready where hasValidatedEpisodeSearchIndex:
            return db
        case .rebuilding:
            return db
        case .ready:
            throw EpisodeSearchIndexError.notReady("validating")
        case .unknown:
            throw EpisodeSearchIndexError.notReady("unknown")
        case .needsRebuild:
            throw EpisodeSearchIndexError.notReady("needsRebuild")
        case .unavailable:
            throw EpisodeSearchIndexError.unavailable
        }
    }

    private func maintainEpisodeSearchIndex(
        in db: OpaquePointer,
        allowWhenNotReady: Bool = false,
        _ update: () throws -> Void
    ) -> Bool {
        guard episodeSearchIndexState != .unavailable else {
            return false
        }
        guard allowWhenNotReady
                || (episodeSearchIndexState == .ready
                    && hasValidatedEpisodeSearchIndex)
                || episodeSearchIndexState == .rebuilding
        else {
            return false
        }
        do {
            try update()
            return true
        } catch {
            episodeSearchIndexState = .needsRebuild
            hasValidatedEpisodeSearchIndex = false
            try? SQLiteEpisodeSearchIndex.markNeedsRebuild(in: db)
            return false
        }
    }

    private func exec(_ sql: String, operation: String, db: OpaquePointer) throws {
        try LocalCacheSQLite.execute(sql, operation: operation, db: db)
    }

    private func prepare(_ sql: String, operation: String, db: OpaquePointer) throws -> OpaquePointer {
        try LocalCacheSQLite.prepare(sql, operation: operation, db: db)
    }

    private func run(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void
    ) throws {
        try LocalCacheSQLite.run(sql, operation: operation, db: db, bindings: bindings)
    }

    private func query(
        _ sql: String,
        operation: String,
        db: OpaquePointer,
        bindings: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        try LocalCacheSQLite.query(sql, operation: operation, db: db, bindings: bindings, row: row)
    }

    private func step(_ statement: OpaquePointer, operation: String, db: OpaquePointer) throws {
        try LocalCacheSQLite.step(statement, operation: operation, db: db)
    }

    private func reset(_ statement: OpaquePointer, operation: String, db: OpaquePointer) throws {
        try LocalCacheSQLite.reset(statement, operation: operation, db: db)
    }

    private func errorFromDatabase(operation: String, db: OpaquePointer) -> LocalLibraryCacheStoreError {
        LocalCacheSQLite.error(operation: operation, db: db)
    }

    private func jsonArray(_ values: some Collection<String>) throws -> String {
        try LocalCacheSQLite.jsonArray(values)
    }

    // MARK: - Binding

    private func bind(
        _ value: String?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(value, at: index, statement: statement, db: db, operation: operation)
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
        try LocalCacheSQLite.bind(value, at: index, statement: statement, db: db, operation: operation)
    }

    private func bind(
        _ value: Int?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(value, at: index, statement: statement, db: db, operation: operation)
    }

    private func bind(
        _ value: Data?,
        at index: Int32,
        statement: OpaquePointer,
        db: OpaquePointer,
        operation: String
    ) throws {
        try LocalCacheSQLite.bind(value, at: index, statement: statement, db: db, operation: operation)
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
        LocalCacheSQLite.columnText(statement, index)
    }

    private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        LocalCacheSQLite.columnDouble(statement, index)
    }

    private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        columnDouble(statement, index).map(Date.init(timeIntervalSince1970:))
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        LocalCacheSQLite.columnInt(statement, index)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        LocalCacheSQLite.columnData(statement, index)
    }
}
