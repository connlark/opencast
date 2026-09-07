import Foundation
import OpenCastCore
import SQLite3
import SwiftData
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
        let firstAttempt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.upsertCache(from: partial, refreshedAt: firstAttempt)
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let loaded = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(Set(loaded.episodes.map(\.episodeID)) == ["episode-1", "episode-2"])
        #expect(loaded.episodes.first { $0.episodeID == "episode-1" }?.title == original.title)
        #expect(loaded.incompleteFeeds[feedURL.absoluteString] == partial.completeness.reason)
        #expect(loaded.podcastsByFeedURL[feedURL.absoluteString]?.artworkPreview == preview)
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        #expect(
            loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString]
                == firstAttempt.addingTimeInterval(60 * 60)
        )
        try await reopened.updateFeedValidators(
            FeedValidators(entityTag: "must-clear", bodyHash: "must-clear"),
            forPodcastID: feedURL.absoluteString
        )
        let secondAttempt = firstAttempt.addingTimeInterval(60 * 60)
        try await reopened.upsertCache(from: partial, refreshedAt: secondAttempt)
        let twicePartial = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(
            twicePartial.automaticRetryAfterByFeedURL[feedURL.absoluteString]
                == secondAttempt.addingTimeInterval(2 * 60 * 60)
        )
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        let complete = try PreparedFeed(snapshot: snapshot([changed, episode(2), episode(3)]))
        try await reopened.upsertCache(from: complete, refreshedAt: secondAttempt.addingTimeInterval(2 * 60 * 60))
        let recovered = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(recovered.episodes.count == 3)
        #expect(recovered.incompleteFeeds.isEmpty)
        #expect(recovered.automaticRetryAfterByFeedURL.isEmpty)
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

    @Test func failedIdentityStatementPreparationReleasesEarlierStatements() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(from: snapshot([episode(0)]), refreshedAt: .now)
        try await store.prepareEpisodeSearchIndex()
        var prepared = try PreparedFeed(snapshot: snapshot([episode(1)]))
        prepared.completeness = .partial(.malformedXML("tail"))

        for deniedColumn in 1...3 {
            let before = try await store.inspectConnectionForTesting { db in
                var count = 0
                var statement = sqlite3_next_stmt(db, nil)
                while let current = statement {
                    count += 1
                    statement = sqlite3_next_stmt(db, current)
                }
                sqlite3_set_authorizer(db, { context, action, table, column, _, _ in
                    guard action == SQLITE_READ,
                          let table, String(cString: table) == "episode_cache",
                          let column else { return SQLITE_OK }
                    let denied = switch Int(bitPattern: context) {
                    case 1: "guid"
                    case 2: "audio_url"
                    default: "published_at"
                    }
                    return String(cString: column) == denied ? SQLITE_DENY : SQLITE_OK
                }, UnsafeMutableRawPointer(bitPattern: deniedColumn))
                return count
            }
            await #expect(throws: (any Error).self) {
                try await store.upsertCache(from: prepared, refreshedAt: .now)
            }
            let after = try await store.inspectConnectionForTesting { db in
                sqlite3_set_authorizer(db, nil, nil)
                var count = 0
                var statement = sqlite3_next_stmt(db, nil)
                while let current = statement {
                    count += 1
                    statement = sqlite3_next_stmt(db, current)
                }
                return count
            }
            #expect(after == before)
            let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
            #expect(loaded.episodes.map(\.episodeID) == ["episode-0"])
        }
        try await store.upsertCache(from: prepared, refreshedAt: .now)
        let recovered = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(Set(recovered.episodes.map(\.episodeID)) == ["episode-0", "episode-1"])
    }

    @Test func cancellationDuringActiveImportRollsBackRowsAndSearch() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let seedStore = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await seedStore.upsertCache(from: snapshot([episode(0)]), refreshedAt: .now)
        try await seedStore.prepareEpisodeSearchIndex()
        try await seedStore.checkpointForSearchBenchmark()
        try rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", at: url)
        let barrier = ImportBatchBarrier()
        let store = SQLiteLocalLibraryCacheStore(
            databaseURL: url,
            importBatchCheckpoint: { completedBatchCount in
                if completedBatchCount == 1 { barrier.reachAndWait() }
            }
        )
        try await store.prepareEpisodeSearchIndex()
        let notes = String(repeating: "Cancellation must preserve the existing catalog. ", count: 100)
        let prepared = try PreparedFeed(snapshot: snapshot((1...5_000).map { index in
            var item = episode(index)
            item.showNotesHTML = notes
            return item
        }))
        let task = Task { try await store.upsertCache(from: prepared, refreshedAt: .now) }
        defer { task.cancel() }
        await barrier.waitUntilReached()
        let cancelledAt = ContinuousClock.now
        task.cancel()
        barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.episodes.map(\.episodeID) == ["episode-0"])
        #expect(loaded.incompleteFeeds.isEmpty)
        #expect(loaded.processingRefreshPodcastIDs == [feedURL.absoluteString])
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
        try await store.recordFeedRetryFailure(
            forPodcastID: feedURL.absoluteString,
            attemptedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", at: url)
        let upgraded = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let loaded = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.processingRefreshPodcastIDs == [feedURL.absoluteString])
        #expect(loaded.automaticRetryAfterByFeedURL.isEmpty)
        #expect(loaded.episodes.count == 1)
        #expect(try await upgraded.feedValidators(forPodcastID: feedURL.absoluteString) == nil)
        var partial = try PreparedFeed(snapshot: snapshot([episode(1), episode(2)]))
        partial.completeness = .partial(.interruptedTransfer("tail reset"))
        let partialDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await upgraded.upsertCache(from: partial, refreshedAt: partialDate)
        let partiallyRecovered = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(partiallyRecovered.processingRefreshPodcastIDs.isEmpty)
        #expect(partiallyRecovered.incompleteFeeds[feedURL.absoluteString] == partial.completeness.reason)
        #expect(
            partiallyRecovered.automaticRetryAfterByFeedURL[feedURL.absoluteString]
                == partialDate.addingTimeInterval(60 * 60)
        )
        try await upgraded.upsertCache(
            from: snapshot([episode(1), episode(2)]),
            refreshedAt: partialDate.addingTimeInterval(60 * 60)
        )
        let validators = FeedValidators(entityTag: "complete", bodyHash: "new")
        try await upgraded.updateFeedValidators(validators, forPodcastID: feedURL.absoluteString)
        let reopened = SQLiteLocalLibraryCacheStore(databaseURL: url)
        let recovered = try await reopened.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(recovered.processingRefreshPodcastIDs.isEmpty)
        #expect(recovered.automaticRetryAfterByFeedURL.isEmpty)
        #expect(recovered.episodes.count == 2)
        #expect(try await reopened.feedValidators(forPodcastID: feedURL.absoluteString) == validators)
    }

    @Test func upgradedPartialFeedBacksOffAcrossRelaunchThenRecoversUnconditionally() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let initialCache = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await initialCache.upsertCache(from: snapshot([episode(1)]), refreshedAt: .now)
        try await initialCache.updateFeedValidators(
            FeedValidators(entityTag: "old-etag", lastModified: "old-date", bodyHash: "old-hash"),
            forPodcastID: feedURL.absoluteString
        )
        try rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", at: url)

        var partial = try PreparedFeed(snapshot: snapshot([episode(1), episode(2)]))
        partial.completeness = .partial(.interruptedTransfer("persistent tail"))
        let completeValidators = FeedValidators(
            entityTag: "complete-etag",
            lastModified: "complete-date",
            bodyHash: "complete-hash"
        )
        let interruptedValidators = FeedValidators(
            entityTag: "partial-etag",
            lastModified: "partial-date",
            bodyHash: "partial-hash"
        )
        let service = PreparedOutcomeSequenceService(outcomes: [
            PreparedFeedOutcome(feed: partial, validators: interruptedValidators),
            PreparedFeedOutcome(
                feed: try PreparedFeed(snapshot: snapshot([episode(1), episode(2), episode(3)])),
                validators: completeValidators
            ),
        ])
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let firstAttempt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL.absoluteString,
                title: "Upgraded Feed",
                lastRefreshAt: firstAttempt.addingTimeInterval(-10_000)
            )
        )
        try context.save()
        var currentDate = firstAttempt
        let firstLibrary = LibraryStore(
            feedService: service,
            localCache: SQLiteLocalLibraryCacheStore(databaseURL: url),
            now: { currentDate }
        )
        #expect(await firstLibrary.load(modelContext: context))
        #expect(firstLibrary.feedURLStringsNeedingLocalCache == [feedURL.absoluteString])

        await firstLibrary.refreshAllIfStale(modelContext: context, now: currentDate)

        #expect(await service.requestCount == 1)
        #expect(firstLibrary.incompleteFeeds[feedURL.absoluteString] == partial.completeness.reason)
        #expect(firstLibrary.feedURLStringsNeedingLocalCache.isEmpty)
        #expect(firstLibrary.automaticRetryAfterByFeedURL[feedURL.absoluteString]
            == firstAttempt.addingTimeInterval(60 * 60))
        #expect(try await initialCache.feedValidators(forPodcastID: feedURL.absoluteString) == nil)

        currentDate = firstAttempt.addingTimeInterval(30 * 60)
        await firstLibrary.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(await service.requestCount == 1)

        // A new store/library instance models an app relaunch. The retry
        // deadline is SQLite-owned and therefore remains authoritative.
        let relaunched = LibraryStore(
            feedService: service,
            localCache: SQLiteLocalLibraryCacheStore(databaseURL: url),
            now: { currentDate }
        )
        #expect(await relaunched.load(modelContext: context))
        await relaunched.refreshAllIfStale(modelContext: context, now: currentDate)
        #expect(await service.requestCount == 1)

        currentDate = firstAttempt.addingTimeInterval(60 * 60)
        await relaunched.refreshAllIfStale(modelContext: context, now: currentDate)

        #expect(await service.requestCount == 2)
        #expect(await service.validators == [nil, nil])
        #expect(await service.intents == [.automatic, .automatic])
        #expect(relaunched.incompleteFeeds.isEmpty)
        #expect(relaunched.automaticRetryAfterByFeedURL.isEmpty)
        #expect(relaunched.feedURLStringsNeedingLocalCache.isEmpty)
        #expect(relaunched.episode(with: "episode-3") != nil)
        #expect(try await initialCache.feedValidators(forPodcastID: feedURL.absoluteString) == completeValidators)
    }

    @Test func zeroUsablePartialAndFailedUpgradeImportKeepUpgradePending() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let initial = SQLiteLocalLibraryCacheStore(databaseURL: url)
        try await initial.upsertCache(from: snapshot([episode(1)]), refreshedAt: .now)
        try rawSQL("UPDATE local_cache_meta SET value='1' WHERE key='feed_processing_version'", at: url)
        try rawSQL("""
            CREATE TRIGGER fail_upgrade_item BEFORE INSERT ON episode_cache
            WHEN NEW.episode_id='episode-2' BEGIN SELECT RAISE(ABORT,'injected upgrade failure'); END;
            """, at: url)
        let upgraded = SQLiteLocalLibraryCacheStore(databaseURL: url)
        _ = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        await #expect(throws: (any Error).self) {
            try await upgraded.upsertCache(from: snapshot([episode(1), episode(2)]), refreshedAt: .now)
        }
        var afterFailure = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(afterFailure.processingRefreshPodcastIDs == [feedURL.absoluteString])

        try rawSQL("DROP TRIGGER fail_upgrade_item", at: url)
        var zero = try PreparedFeed(snapshot: snapshot([]))
        zero.completeness = .partial(.malformedXML("empty salvage"))
        await #expect(throws: (any Error).self) {
            try await upgraded.upsertCache(from: zero, refreshedAt: .now)
        }
        afterFailure = try await upgraded.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(afterFailure.processingRefreshPodcastIDs == [feedURL.absoluteString])
        #expect(afterFailure.episodes.map(\.episodeID) == ["episode-1"])
    }

    @Test func partialRetryBackoffDoublesAndCapsAtTwentyFourHours() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        var partial = try PreparedFeed(snapshot: snapshot([episode(1)]))
        partial.completeness = .partial(.interruptedTransfer("persistent tail"))
        var attemptDate = Date(timeIntervalSince1970: 1_800_000_000)
        for expectedHours in [1, 2, 4, 8, 16, 24, 24] {
            try await store.upsertCache(from: partial, refreshedAt: attemptDate)
            let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
            let expected = attemptDate.addingTimeInterval(TimeInterval(expectedHours * 60 * 60))
            #expect(loaded.automaticRetryAfterByFeedURL[feedURL.absoluteString] == expected)
            attemptDate = expected
        }
    }

    @Test func partialIdentityLookupsUseDedicatedIndexes() async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        _ = try await store.loadLibrary(activePodcastIDs: [])
        let plans = try [
            "SELECT 1 FROM episode_cache WHERE episode_id='id' AND podcast_id='feed' LIMIT 1",
            "SELECT 1 FROM episode_cache WHERE podcast_id='feed' AND guid='guid' LIMIT 1",
            "SELECT 1 FROM episode_cache WHERE podcast_id='feed' AND audio_url='audio' LIMIT 1",
            "SELECT 1 FROM episode_cache WHERE podcast_id='feed' AND published_at=1 AND title='title' LIMIT 1"
        ].map { try queryPlan(for: $0, at: url) }
        #expect(plans[0].contains("sqlite_autoindex_episode_cache_1"))
        #expect(plans[1].contains("episode_cache_podcast_guid_idx"))
        #expect(plans[2].contains("episode_cache_podcast_audio_idx"))
        #expect(plans[3].contains("episode_cache_podcast_published_title_idx"))
    }

    @Test func partialOverlapPreservesEveryIdentityRuleScopeAndIncomingDuplicates() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let original = episode(1)
        try await store.upsertCache(from: snapshot([original]), refreshedAt: .now)

        let otherFeedURL = URL(string: "https://example.com/other.xml")!
        var other = episode(90)
        other.id = EpisodeID(rawValue: "other-episode")
        other.podcastID = PodcastID(rawValue: otherFeedURL.absoluteString)
        other.podcastTitle = "Other Show"
        other.guid = "foreign-guid"
        try await store.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: otherFeedURL.absoluteString),
                    feedURL: otherFeedURL,
                    title: "Other Show"
                ),
                episodes: [other]
            ),
            refreshedAt: .now
        )

        var byID = episode(2)
        byID.id = original.id
        byID.guid = "different-guid"
        byID.audioURL = URL(string: "https://example.com/different-id.mp3")
        var byGUID = episode(3)
        byGUID.guid = original.guid
        var byAudio = episode(4)
        byAudio.audioURL = original.audioURL
        var byPublishedTitle = episode(5)
        byPublishedTitle.publishedAt = original.publishedAt
        byPublishedTitle.title = original.title
        var crossFeedIdentity = episode(6)
        crossFeedIdentity.guid = other.guid
        var firstIncoming = episode(7)
        firstIncoming.guid = "same-incoming-guid"
        var duplicateIncoming = episode(8)
        duplicateIncoming.guid = firstIncoming.guid
        var insufficient = episode(9)
        insufficient.guid = nil
        insufficient.audioURL = nil
        insufficient.publishedAt = nil
        var partial = try PreparedFeed(snapshot: snapshot([
            byID,
            byGUID,
            byAudio,
            byPublishedTitle,
            crossFeedIdentity,
            firstIncoming,
            duplicateIncoming,
            insufficient,
        ]))
        partial.completeness = .partial(.malformedXML("tail"))

        try await store.upsertCache(from: partial, refreshedAt: .now)

        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(Set(loaded.episodes.map(\.episodeID)) == [
            original.id.rawValue,
            crossFeedIdentity.id.rawValue,
            firstIncoming.id.rawValue,
        ])
        let preserved = try #require(
            try await store.episodeDetail(episodeID: original.id.rawValue)
        )
        #expect(preserved.listItem.title == original.title)
        #expect(preserved.showNotesHTML == original.showNotesHTML)
    }

    @Test func optInLargePartialImportsRemainAdditiveAndNearLinear() async throws {
        guard ProcessInfo.processInfo.environment["OPENCAST_LARGE_PARTIAL_IMPORTS"] == "1" else {
            return
        }
        for count in [13_753, 100_000] {
            try await measurePartialCase(count: count, label: "all overlap", expectedCount: count) { baseline in
                baseline
            }
            try await measurePartialCase(count: count, label: "no overlap", expectedCount: count * 2) { _ in
                var incoming = (count..<(count * 2)).map(episode)
                incoming[0].guid = String(repeating: "long-guid-", count: 65_536)
                incoming[0].title = String(repeating: "Long identity title ", count: 8_192)
                return incoming
            }
            let overlapCount = count / 2
            let newCount = count - overlapCount
            try await measurePartialCase(
                count: count,
                label: "mixed overlap",
                expectedCount: count + newCount
            ) { baseline in
                Array(baseline.prefix(overlapCount))
                    + (count..<(count + newCount)).map { index in
                        var item = episode(index + count)
                        item.id = EpisodeID(rawValue: "mixed-\(count)-\(index)")
                        item.guid = "mixed-guid-\(count)-\(index)"
                        item.audioURL = URL(string: "https://example.com/mixed-\(count)-\(index).mp3")
                        return item
                    }
            }
            try await measurePartialCase(
                count: count,
                label: "incoming duplicate identities",
                expectedCount: count + ((count + 1) / 2)
            ) { _ in
                (0..<count).map { index in
                    var item = episode(index + count * 3)
                    item.guid = "incoming-pair-\(count)-\(index / 2)"
                    return item
                }
            }
        }
    }

    private func measurePartialCase(
        count: Int,
        label: String,
        expectedCount: Int,
        makeIncoming: ([Episode]) -> [Episode]
    ) async throws {
        let url = temporaryDatabase()
        defer { removeDatabase(url) }
        let store = SQLiteLocalLibraryCacheStore(databaseURL: url)
        var baseline = (0..<count).map(episode)
        baseline[0].showNotesHTML = "<p>" + String(repeating: "Preserved full note. ", count: 2_048) + "</p>"
        let seedStart = ContinuousClock.now
        try await store.upsertCache(from: snapshot(baseline), refreshedAt: .now)
        let seedDuration = seedStart.duration(to: .now)

        let preservedBaseline = baseline[0]
        var incoming = makeIncoming(baseline)
        baseline.removeAll(keepingCapacity: false)
        let preparationStart = ContinuousClock.now
        var partial = try PreparedFeed(snapshot: snapshot(incoming))
        let preparationDuration = preparationStart.duration(to: .now)
        incoming.removeAll(keepingCapacity: false)
        partial.completeness = .partial(.interruptedTransfer("large partial"))
        let importStart = ContinuousClock.now
        try await store.upsertCache(from: partial, refreshedAt: .now)
        let importDuration = importStart.duration(to: .now)

        let loaded = try await store.loadLibrary(activePodcastIDs: [feedURL.absoluteString])
        #expect(loaded.episodes.count == expectedCount, "\(count), \(label)")
        #expect(Set(loaded.episodes.map(\.episodeID)).count == expectedCount, "\(count), \(label)")
        let preserved = try #require(
            try await store.episodeDetail(episodeID: preservedBaseline.id.rawValue)
        )
        #expect(preserved.listItem.title == preservedBaseline.title, "\(count), \(label)")
        #expect(preserved.showNotesHTML == preservedBaseline.showNotesHTML, "\(count), \(label)")
        print(
            "Large partial \(count) \(label): seed=\(seedDuration), "
                + "prepare=\(preparationDuration), import=\(importDuration)"
        )
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

    private func queryPlan(for sql: String, at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) {
                details.append(String(cString: text))
            }
        }
        return details.joined(separator: "\n")
    }
}

private actor PreparedOutcomeSequenceService: FeedService {
    private var outcomes: [PreparedFeedOutcome]
    private(set) var validators: [FeedValidators?] = []
    private(set) var intents: [FeedPreparationIntent] = []

    init(outcomes: [PreparedFeedOutcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int { validators.count }

    func prepareFeed(
        at url: URL,
        validators: FeedValidators?
    ) async throws -> PreparedFeedOutcome {
        try await prepareFeed(at: url, validators: validators, intent: .interactive)
    }

    func prepareFeed(
        at _: URL,
        validators: FeedValidators?,
        intent: FeedPreparationIntent
    ) async throws -> PreparedFeedOutcome {
        self.validators.append(validators)
        intents.append(intent)
        guard !outcomes.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return outcomes.removeFirst()
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let outcome = try await prepareFeed(at: url, validators: nil, intent: .interactive)
        guard let feed = outcome.feed else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        return try feed.materialized()
    }
}

private final class ImportBatchBarrier: @unchecked Sendable {
    private struct State {
        var reached = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = NSLock()
    private var value = State()
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func reachAndWait() {
        let continuation = state.withLock { () -> CheckedContinuation<Void, Never>? in
            value.reached = true
            defer { value.continuation = nil }
            return value.continuation
        }
        continuation?.resume()
        releaseSemaphore.wait()
    }

    func waitUntilReached() async {
        let shouldWait = state.withLock { !value.reached }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock {
                if value.reached { return true }
                value.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}
