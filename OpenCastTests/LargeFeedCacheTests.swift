import Foundation
import OpenCastCore
import SQLite3
import Testing
@testable import OpenCast

@MainActor
@Suite(.serialized)
struct LargeFeedCacheTests {
    private let feedURL = URL(string: "https://example.com/large.xml")!

    @Test func pinnedLargeCatalogsImportCompleteNotesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OPENCAST_LARGE_FEED_CAPTURES"] == "1" else { return }
        for (name, count) in [("herd", 13_753), ("greenfield", 1_819), ("eofire", 4_559), ("changelog", 2_391)] {
            let store = SQLiteLocalLibraryCacheStore.inMemory()
            try await store.prepareEpisodeSearchIndex()
            let url = URL(fileURLWithPath: "/private/tmp/opencast-feed-research-\(name).xml")
            let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            try await store.upsertCache(from: prepared, refreshedAt: .now)
            let library = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
            #expect(library.episodes.count == count, "\(name)")
            #expect(library.incompleteFeeds.isEmpty)
            var first: Episode?
            var last: Episode?
            try prepared.episodes.forEachBatch { batch in
                if first == nil { first = batch.first }
                last = batch.last
            }
            for original in [first, last].compactMap({ $0 }) {
                let detail = try #require(try await store.episodeDetail(episodeID: original.id.rawValue))
                #expect(detail.listItem.guid == original.guid)
                #expect(detail.listItem.title == original.title)
                let notesMatch = detail.showNotesHTML == original.showNotesHTML
                #expect(notesMatch, "\(name) full notes")
            }
        }
    }

    @Test func fullNotesStayInDetailAndSearchInsteadOfListRows() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.prepareEpisodeSearchIndex()
        var episode = episode(1)
        let notes = String(repeating: "Complete show notes. ", count: 4_000) + "quasararchive"
        episode.summary = notes
        episode.showNotesHTML = "<article>\(notes)</article>"
        let prepared = try PreparedFeed(snapshot: snapshot([episode]))
        try await store.upsertCache(from: prepared, refreshedAt: .now)
        let library = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(library.episodes.count == 1)
        #expect(library.episodes.first?.summary == nil)
        let detail = try await store.episodeDetail(episodeID: episode.id.rawValue)
        #expect(detail?.listItem.summary == notes)
        #expect(detail?.showNotesHTML == episode.showNotesHTML)
        let request = EpisodeSearchIndexRequest(query: "quasararchive", mode: .fullText,
                                                activePodcastIDs: [feedURL.absoluteString])
        let hits = try await store.searchEpisodes(request)
        #expect(hits.map(\.episodeID).contains(episode.id.rawValue))
    }

    @Test func partialImportPreservesRowsInvalidatesValidatorsAndRetries() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let original = episode(1)
        var initial = snapshot([original])
        let artwork = "https://example.com/existing-art.png"
        initial.podcast.artworkURL = URL(string: artwork)
        try await store.upsertCache(from: initial, refreshedAt: .now)
        let artworkKey = try #require(ArtworkPreview.canonicalArtworkURLKey(for: artwork))
        let preview = try #require(ArtworkPreview(version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: artworkKey,
            sourceHash: "existing-preview", pixelWidth: 8, pixelHeight: 8,
            rgbData: Data(repeating: 0x40, count: ArtworkPreview.requiredRGBByteCount(width: 8, height: 8))))
        try await store.updatePodcastArtworkPreview(preview, feedURL: feedURL.absoluteString, artworkURL: artwork)
        try await store.updateFeedValidators(FeedValidators(entityTag: "old", bodyHash: "old"), forPodcastID: feedURL.absoluteString)
        var changed = original
        changed.title = "Must not overwrite a partial catalog"
        var rekeyed = original
        rekeyed.id = EpisodeID(rawValue: "new-id-same-audio")
        rekeyed.guid = "changed-guid"
        var fullyRekeyed = rekeyed
        fullyRekeyed.id = EpisodeID(rawValue: "new-id-changed-audio")
        fullyRekeyed.audioURL = URL(string: "https://example.com/relocated.mp3")
        var partial = try PreparedFeed(snapshot: snapshot([changed, rekeyed, fullyRekeyed, episode(2)]))
        partial.completeness = .partial(.interruptedTransfer("Connection closed"))
        try await store.upsertCache(from: partial, refreshedAt: .now)
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let loaded = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(Set(loaded.episodes.map(\.episodeID)) == ["episode-1", "episode-2"])
        #expect(loaded.episodes.first { $0.episodeID == "episode-1" }?.title == original.title)
        #expect(loaded.incompleteFeeds[feedURL.absoluteString] == partial.completeness.reason)
        #expect(loaded.podcastsByFeedURL[feedURL.absoluteString]?.artworkPreview == preview)
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        let complete = try PreparedFeed(snapshot: snapshot([changed, episode(2), episode(3)]))
        try await reopened.upsertCache(from: complete, refreshedAt: .now)
        let recovered = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(recovered.episodes.count == 3)
        #expect(recovered.incompleteFeeds.isEmpty)
        #expect(recovered.episodes.first { $0.episodeID == "episode-1" }?.title == changed.title)
    }

    @Test func writeFailureAfterFirstBatchRollsBackEntireImport() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await store.upsertCache(from: snapshot([episode(0)]), refreshedAt: .now)
        try rawSQL("""
            CREATE TRIGGER fail_late_item BEFORE INSERT ON episode_cache
            WHEN NEW.episode_id='episode-257' BEGIN SELECT RAISE(ABORT,'injected disk write failure'); END;
            """, at: url)
        let prepared = try PreparedFeed(snapshot: snapshot((1...600).map(episode)))
        await #expect(throws: (any Error).self) {
            try await store.upsertCache(from: prepared, refreshedAt: .now)
        }
        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.episodes.map(\.episodeID) == ["episode-0"])
        #expect(loaded.incompleteFeeds.isEmpty)
    }

    @Test func searchWriteFailureRollsBackCatalogAndIndexTogether() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await store.upsertCache(from: snapshot([episode(0)]), refreshedAt: .now)
        try await store.prepareEpisodeSearchIndex()
        try rawSQL("""
            CREATE TRIGGER fail_search_item BEFORE INSERT ON episode_search_spelling_document
            WHEN NEW.episode_id='episode-257' BEGIN SELECT RAISE(ABORT,'injected index write failure'); END;
            """, at: url)
        let prepared = try PreparedFeed(snapshot: snapshot((1...600).map(episode)))
        await #expect(throws: (any Error).self) {
            try await store.upsertCache(from: prepared, refreshedAt: .now)
        }
        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.episodes.map(\.episodeID) == ["episode-0"])
        let request = EpisodeSearchIndexRequest(query: "Episode 257", mode: .episodes, activePodcastIDs: [feedURL.absoluteString])
        #expect(try await store.episodeSearchIndexStateDescription() == "needsRebuild")
        try await store.prepareEpisodeSearchIndex()
        let hits = try await store.searchEpisodes(request)
        #expect(!hits.map(\.episodeID).contains("episode-257"))
    }

    @Test func cancellationDuringActiveImportRollsBackRowsAndSearch() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await store.upsertCache(from: snapshot([episode(0)]), refreshedAt: .now)
        try await store.prepareEpisodeSearchIndex()
        try await store.checkpointForSearchBenchmark()
        let notes = String(repeating: "Cancellation must preserve the existing catalog. ", count: 100)
        let prepared = try PreparedFeed(snapshot: snapshot((1...5_000).map { index in
            var item = episode(index)
            item.showNotesHTML = notes
            return item
        }))
        let task = Task { try await store.upsertCache(from: prepared, refreshedAt: .now) }
        defer { task.cancel() }
        // A spill into the initially empty WAL proves the transaction has
        // written catalog pages before cancellation; no sleep-based guess.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var observedWrite = false
        while ContinuousClock.now < deadline {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path + "-wal")
            if let bytes = attributes[.size] as? NSNumber, bytes.intValue > 32 {
                observedWrite = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(observedWrite)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.episodes.map(\.episodeID) == ["episode-0"])
        #expect(loaded.incompleteFeeds.isEmpty)
        let request = EpisodeSearchIndexRequest(query: "Cancellation", mode: .fullText,
                                                activePodcastIDs: [feedURL.absoluteString])
        #expect(try await store.searchEpisodes(request).isEmpty)
    }

    @Test func processingUpgradeInvalidatesOnceAndRequestsForegroundRefresh() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await store.upsertCache(from: snapshot([episode(1)]), refreshedAt: .now)
        try await store.updateFeedValidators(FeedValidators(entityTag: "truncated", bodyHash: "old"), forPodcastID: feedURL.absoluteString)
        try rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", at: url)
        let upgraded = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let loaded = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.processingRefreshPodcastIDs == [feedURL.absoluteString])
        #expect(loaded.episodes.count == 1)
        #expect(try await upgraded.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        try await upgraded.upsertCache(from: snapshot([episode(1), episode(2)]), refreshedAt: .now)
        let validators = FeedValidators(entityTag: "complete", bodyHash: "new")
        try await upgraded.updateFeedValidators(validators, forPodcastID: feedURL.absoluteString)
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let recovered = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(recovered.processingRefreshPodcastIDs.isEmpty)
        #expect(recovered.episodes.count == 2)
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == validators)
    }

    private func episode(_ index: Int) -> Episode {
        Episode(id: EpisodeID(rawValue: "episode-\(index)"), podcastID: PodcastID(rawValue: feedURL.absoluteString),
                podcastTitle: "Large Show", title: "Episode \(index)", summary: "Summary \(index)",
                showNotesHTML: "<p>Complete notes \(index)</p>", publishedAt: Date(timeIntervalSince1970: Double(index)),
                audioURL: URL(string: "https://example.com/\(index).mp3"), guid: "guid-\(index)")
    }

    private func snapshot(_ episodes: [Episode]) -> FeedSnapshot {
        FeedSnapshot(podcast: Podcast(id: PodcastID(rawValue: feedURL.absoluteString), feedURL: feedURL, title: "Large Show"), episodes: episodes)
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("large-feed-cache-\(UUID()).sqlite")
    }

    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func rawSQL(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LargeFeedTestSQLite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
