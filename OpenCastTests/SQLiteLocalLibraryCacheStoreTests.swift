import Foundation
import OpenCastCore
import SQLite3
import Testing
@testable import OpenCast

@MainActor
@Suite("SQLite local library cache store", .serialized)
struct SQLiteLocalLibraryCacheStoreTests {
    private static let feedURL = "https://example.com/sqlite-cache.xml"
    private static let otherFeedURL = "https://example.com/sqlite-other.xml"

    @Test("Fresh in-memory store loads an empty snapshot without a legacy import marker")
    func emptyStoreLoadsEmptySnapshot() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        let hasImported = try await store.hasCompletedLegacyImport()

        #expect(library.podcastsByFeedURL.isEmpty)
        #expect(library.episodes.isEmpty)
        #expect(library.refreshLogs.isEmpty)
        #expect(!hasImported)
    }

    @Test("Upsert inserts podcast and episodes ordered newest first with undated episodes last")
    func upsertInsertsPodcastAndOrderedEpisodes() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let snapshot = makeFeedSnapshot(episodes: [
            makeEpisode(id: "ep-nil-beta", title: "Beta Undated", publishedAt: nil),
            makeEpisode(id: "ep-old", title: "Old Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            makeEpisode(id: "ep-nil-alpha", title: "Alpha Undated", publishedAt: nil),
            makeEpisode(id: "ep-new", title: "New Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))
        ])

        try await store.upsertCache(from: snapshot, refreshedAt: refreshedAt)

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.episodes.map(\.episodeID) == ["ep-new", "ep-old", "ep-nil-alpha", "ep-nil-beta"])
        #expect(library.episodes.map(\.cachedAt) == Array(repeating: refreshedAt, count: 4))

        let podcast = try #require(library.podcastsByFeedURL[Self.feedURL])
        #expect(podcast.title == "Cached Show")
        #expect(podcast.author == "Cached Author")
        #expect(podcast.summary == "Cached summary")
        #expect(podcast.updatedAt == refreshedAt)
    }

    @Test("Podcast language round-trips through the cache")
    func podcastLanguageRoundTripsThroughCache() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let snapshot = makeFeedSnapshot(
            languageCode: "de-DE",
            episodes: [
                makeEpisode(id: "ep-lang", title: "Lang Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
            ]
        )

        try await store.upsertCache(from: snapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_500))

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL]?.languageCode == "de-DE")

        let clearedSnapshot = makeFeedSnapshot(
            languageCode: nil,
            episodes: [
                makeEpisode(id: "ep-lang", title: "Lang Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
            ]
        )
        try await store.upsertCache(from: clearedSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_600))
        let reloaded = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(reloaded.podcastsByFeedURL[Self.feedURL]?.languageCode == nil)
    }

    @Test("Second upsert updates metadata, dedupes by episode ID, and keeps missing episodes")
    func secondUpsertUpdatesWithoutStaleDeletion() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let firstSnapshot = makeFeedSnapshot(episodes: [
            makeEpisode(id: "ep-1", title: "First Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200)),
            makeEpisode(id: "ep-2", title: "Second Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])
        try await store.upsertCache(from: firstSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_300))

        let secondSnapshot = makeFeedSnapshot(
            title: "Renamed Show",
            summary: "Renamed summary",
            episodes: [
                makeEpisode(
                    id: "ep-1",
                    title: "First Episode Updated",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    audioURL: "https://example.com/audio/ep-1-remastered.mp3"
                ),
                makeEpisode(id: "ep-3", title: "Third Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_250))
            ]
        )
        try await store.upsertCache(from: secondSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_400))

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        let podcast = try #require(library.podcastsByFeedURL[Self.feedURL])
        #expect(podcast.title == "Renamed Show")
        #expect(podcast.summary == "Renamed summary")

        #expect(library.episodes.map(\.episodeID) == ["ep-3", "ep-1", "ep-2"])
        let updated = try #require(library.episodes.first { $0.episodeID == "ep-1" })
        #expect(updated.title == "First Episode Updated")
        #expect(updated.audioURL == "https://example.com/audio/ep-1-remastered.mp3")
    }

    @Test("Upsert keeps artwork previews for unchanged URLs and clears them on URL change")
    func upsertPreservesOrClearsArtworkPreviews() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastArt = "https://example.com/podcast-art.png"
        let keptArt = "https://example.com/kept-art.png"
        let changedArt = "https://example.com/changed-art.png"
        let snapshot = makeFeedSnapshot(
            artworkURL: podcastArt,
            episodes: [
                makeEpisode(
                    id: "ep-kept",
                    title: "Kept Artwork",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    artworkURL: keptArt
                ),
                makeEpisode(
                    id: "ep-changed",
                    title: "Changed Artwork",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    artworkURL: changedArt
                )
            ]
        )
        try await store.upsertCache(from: snapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_300))

        let podcastPreview = try makePreview(forArtworkURL: podcastArt)
        let keptPreview = try makePreview(forArtworkURL: keptArt)
        let changedPreview = try makePreview(forArtworkURL: changedArt)
        try await store.updatePodcastArtworkPreview(podcastPreview, feedURL: Self.feedURL, artworkURL: podcastArt)
        try await store.updateEpisodeArtworkPreview(keptPreview, episodeID: "ep-kept", artworkURL: keptArt)
        try await store.updateEpisodeArtworkPreview(changedPreview, episodeID: "ep-changed", artworkURL: changedArt)

        let secondSnapshot = makeFeedSnapshot(
            artworkURL: podcastArt,
            episodes: [
                makeEpisode(
                    id: "ep-kept",
                    title: "Kept Artwork",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    artworkURL: keptArt
                ),
                makeEpisode(
                    id: "ep-changed",
                    title: "Changed Artwork",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    artworkURL: "https://example.com/replacement-art.png"
                )
            ]
        )
        try await store.upsertCache(from: secondSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_400))

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL]?.artworkPreview == podcastPreview)
        let kept = try #require(library.episodes.first { $0.episodeID == "ep-kept" })
        #expect(kept.artworkPreview == keptPreview)
        let changed = try #require(library.episodes.first { $0.episodeID == "ep-changed" })
        #expect(changed.artworkPreview == nil)

        let thirdSnapshot = makeFeedSnapshot(
            artworkURL: "https://example.com/new-podcast-art.png",
            episodes: []
        )
        try await store.upsertCache(from: thirdSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_500))

        let relisted = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(relisted.podcastsByFeedURL[Self.feedURL]?.artworkPreview == nil)
    }

    @Test("Re-upserting an identical snapshot writes zero rows and keeps timestamps")
    func identicalSnapshotUpsertWritesNothing() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let firstRefreshedAt = Date(timeIntervalSince1970: 1_700_000_300)
        let snapshot = makeFeedSnapshot(episodes: [
            makeEpisode(
                id: "ep-1",
                title: "First Episode",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                showNotesHTML: "<p>Notes</p>"
            ),
            makeEpisode(id: "ep-2", title: "Second Episode", publishedAt: nil)
        ])
        try await store.upsertCache(from: snapshot, refreshedAt: firstRefreshedAt)
        let changesBeforeSecondUpsert = try await store.totalRowChangeCount()

        try await store.upsertCache(from: snapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_900))

        #expect(try await store.totalRowChangeCount() == changesBeforeSecondUpsert)
        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.episodes.map(\.cachedAt) == Array(repeating: firstRefreshedAt, count: 2))
        #expect(library.podcastsByFeedURL[Self.feedURL]?.updatedAt == firstRefreshedAt)
    }

    @Test("A changed episode writes one canonical row, refreshes its index row, and advances only its timestamp")
    func changedEpisodeWritesExactlyThatRow() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let firstRefreshedAt = Date(timeIntervalSince1970: 1_700_000_300)
        let unchangedEpisode = makeEpisode(
            id: "ep-stable",
            title: "Stable Episode",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-edited", title: "Original Title", publishedAt: Date(timeIntervalSince1970: 1_700_000_200)),
                unchangedEpisode
            ]),
            refreshedAt: firstRefreshedAt
        )
        let changesBeforeSecondUpsert = try await store.totalRowChangeCount()

        let secondRefreshedAt = Date(timeIntervalSince1970: 1_700_000_900)
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-edited", title: "Edited Title", publishedAt: Date(timeIntervalSince1970: 1_700_000_200)),
                unchangedEpisode
            ]),
            refreshedAt: secondRefreshedAt
        )

        // Exact bound: the refresh may write only the one changed canonical
        // row. (The derived index is not yet prepared on this store, so no
        // index rows contribute; its refresh behavior has its own coverage.)
        #expect(try await store.totalRowChangeCount() == changesBeforeSecondUpsert + 1)
        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        let edited = try #require(library.episodes.first { $0.episodeID == "ep-edited" })
        let stable = try #require(library.episodes.first { $0.episodeID == "ep-stable" })
        #expect(edited.title == "Edited Title")
        #expect(edited.cachedAt == secondRefreshedAt)
        #expect(stable.cachedAt == firstRefreshedAt)
    }

    @Test("Episode detail carries show notes and the bulk lookup covers active feeds only")
    func listDetailSplitExposesShowNotes() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let activeSnapshot = makeFeedSnapshot(episodes: [
            makeEpisode(
                id: "ep-noted",
                title: "Noted Episode",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                showNotesHTML: "<p>Noted body</p>"
            ),
            makeEpisode(id: "ep-plain", title: "Plain Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])
        let inactiveSnapshot = makeFeedSnapshot(
            feedURL: Self.otherFeedURL,
            title: "Inactive Show",
            episodes: [
                makeEpisode(
                    id: "ep-inactive",
                    feedURL: Self.otherFeedURL,
                    title: "Inactive Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_150),
                    showNotesHTML: "<p>Inactive body</p>"
                )
            ]
        )
        try await store.upsertCache(from: activeSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_300))
        try await store.upsertCache(from: inactiveSnapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_300))

        let detail = try #require(try await store.episodeDetail(episodeID: "ep-noted"))
        #expect(detail.showNotesHTML == "<p>Noted body</p>")
        #expect(detail.listItem.episodeID == "ep-noted")
        #expect(detail.listItem.title == "Noted Episode")

        let missing = try await store.episodeDetail(episodeID: "ep-missing")
        #expect(missing == nil)

        let showNotes = try await store.showNotesHTMLByEpisodeID(activePodcastIDs: [Self.feedURL])
        #expect(showNotes == ["ep-noted": "<p>Noted body</p>"])
    }

    @Test("Library load filters episodes to active feeds but lists every cached podcast")
    func loadLibraryFiltersEpisodesByActiveFeeds() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-active", title: "Active Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.upsertCache(
            from: makeFeedSnapshot(
                feedURL: Self.otherFeedURL,
                title: "Other Show",
                episodes: [
                    makeEpisode(
                        id: "ep-other",
                        feedURL: Self.otherFeedURL,
                        title: "Other Episode",
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_250)
                    )
                ]
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.episodes.map(\.episodeID) == ["ep-active"])
        #expect(Set(library.podcastsByFeedURL.keys) == [Self.feedURL, Self.otherFeedURL])
    }

    @Test("Refresh log insert prunes each feed to the newest fifty entries")
    func refreshLogInsertPrunesPerFeed() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let otherLog = RefreshLogSnapshot(
            refreshID: "other-refresh",
            feedURL: Self.otherFeedURL,
            startedAt: base.addingTimeInterval(-100),
            finishedAt: base.addingTimeInterval(-90)
        )
        try await store.insertRefreshLog(otherLog, prunedTo: 50)

        for index in 1...55 {
            let log = RefreshLogSnapshot(
                refreshID: "refresh-\(index)",
                feedURL: Self.feedURL,
                startedAt: base.addingTimeInterval(Double(index)),
                finishedAt: base.addingTimeInterval(Double(index) + 1)
            )
            try await store.insertRefreshLog(log, prunedTo: 50)
        }

        let allLogs = try await store.allRefreshLogs()
        #expect(allLogs.count == 51)

        let feedLogs = allLogs.filter { $0.feedURL == Self.feedURL }
        #expect(feedLogs.map(\.refreshID) == (6...55).reversed().map { "refresh-\($0)" })
        #expect(allLogs.last == otherLog)

        // The library snapshot carries only the per-feed-latest projection.
        let library = try await store.loadLibrary(activePodcastIDs: [])
        #expect(library.refreshLogs.map(\.refreshID) == ["refresh-55", "other-refresh"])
    }

    @Test("Library snapshot projects each feed's latest log plus its latest success")
    func librarySnapshotProjectsLatestAndLatestSuccessPerFeed() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldSuccess = RefreshLogSnapshot(
            refreshID: "old-success",
            feedURL: Self.feedURL,
            startedAt: base,
            finishedAt: base.addingTimeInterval(1)
        )
        let midFailure = RefreshLogSnapshot(
            refreshID: "mid-failure",
            feedURL: Self.feedURL,
            startedAt: base.addingTimeInterval(10),
            finishedAt: base.addingTimeInterval(11),
            errorMessage: "boom"
        )
        let latestFailure = RefreshLogSnapshot(
            refreshID: "latest-failure",
            feedURL: Self.feedURL,
            startedAt: base.addingTimeInterval(20),
            finishedAt: base.addingTimeInterval(21),
            errorMessage: "boom again"
        )
        for log in [oldSuccess, midFailure, latestFailure] {
            try await store.insertRefreshLog(log, prunedTo: 50)
        }

        let library = try await store.loadLibrary(activePodcastIDs: [])

        // Latest overall (a failure) and the newest success both survive the
        // projection; the middle failure does not.
        #expect(library.refreshLogs.map(\.refreshID) == ["latest-failure", "old-success"])
    }

    @Test("Feed validators round-trip without touching the content timestamp")
    func feedValidatorsRoundTripWithoutTouchingTimestamp() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let snapshot = makeFeedSnapshot(episodes: [
            makeEpisode(id: "ep-1", title: "First", publishedAt: Date(timeIntervalSince1970: 1_700_000_100))
        ])
        try await store.upsertCache(from: snapshot, refreshedAt: refreshedAt)
        #expect(try await store.feedValidators(forPodcastID: Self.feedURL) == nil)

        let validators = FeedValidators(
            entityTag: "\"tag-1\"",
            lastModified: "Wed, 08 Apr 2026 12:00:00 GMT",
            bodyHash: "hash-1"
        )
        try await store.updateFeedValidators(validators, forPodcastID: Self.feedURL)

        #expect(try await store.feedValidators(forPodcastID: Self.feedURL) == validators)
        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL]?.updatedAt == refreshedAt)
    }

    @Test("The schema reports the versioned-migration user_version")
    func schemaReportsUserVersion() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        _ = try await store.loadLibrary(activePodcastIDs: [])
        #expect(try await store.currentSchemaVersion() == 5)
    }

    @Test("Episode search rebuild enables fielded and scoped retrieval")
    func episodeSearchRebuildEnablesFieldedAndScopedRetrieval() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "title",
                    title: "The Orchard at Midnight",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "notes",
                    title: "How a Night Bird Finds North",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: """
                    <article><p>Cryptochrome&nbsp;<strong>radical pairs</strong>
                    respond to a magnetic field &amp; guide migration.</p>
                    <script>unfindable-script-token</script></article>
                    """
                ),
                makeEpisode(
                    id: "japanese",
                    title: "東京の小さな庭",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )

        let notesRequest = EpisodeSearchIndexRequest(
            query: "radical pairs",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )
        await #expect(throws: EpisodeSearchIndexError.self) {
            _ = try await store.searchEpisodes(notesRequest)
        }

        try await store.prepareEpisodeSearchIndex()
        #expect(try await store.episodeSearchIndexStateDescription() == "ready")

        let titleHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "orch",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(titleHits.map(\.episodeID) == ["title"])
        #expect(titleHits.first?.scoreTrace.channel == .prefix)

        let notesHits = try await store.searchEpisodes(notesRequest)
        #expect(notesHits.map(\.episodeID) == ["notes"])
        #expect(notesHits.first?.scoreTrace.matchedFields.contains(.showNotes) == true)
        #expect(notesHits.first?.snippet?.contains("radical pairs") == true)
        #expect(notesHits.first?.snippet?.contains("<") == false)
        #expect(notesHits.first?.snippet?.contains("& guide") == true)

        let excludedMarkupHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "unfindable-script-token",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(excludedMarkupHits.isEmpty)

        let visibleOnlyHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "radical pairs",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(visibleOnlyHits.isEmpty)

        let disallowedHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "orchard",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL],
                allowedEpisodeIDs: ["notes"]
            )
        )
        #expect(disallowedHits.isEmpty)

        let unsegmentedJapaneseHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "東京 庭",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(unsegmentedJapaneseHits.map(\.episodeID) == ["japanese"])
        #expect(
            unsegmentedJapaneseHits.first?.scoreTrace.channel
                == .visibleSubstring
        )
    }

    @Test("Episode search reads pre-cleaned derived evidence instead of canonical HTML")
    func episodeSearchReadsDerivedBodyEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SQLiteSearchEvidenceTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appending(path: "LocalLibraryCache.sqlite")
        let store = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "derived-evidence",
                    title: "Upper Atmosphere",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: """
                    <section><p>Mesosphere&nbsp;<em>aurora coupling</em>
                    is visible &amp; measurable.</p></section>
                    """
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.prepareEpisodeSearchIndex()

        try execRawSQL(
            """
            UPDATE episode_cache
            SET show_notes_html = '<p>Canonical HTML changed.</p>'
            WHERE episode_id = 'derived-evidence'
            """,
            databaseURL: databaseURL
        )

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "mesosphere aurora",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hits.map(\.episodeID) == ["derived-evidence"])
        #expect(hits.first?.scoreTrace.matchedFields.contains(.showNotes) == true)
        #expect(hits.first?.snippet?.contains("Mesosphere aurora coupling") == true)
        #expect(hits.first?.snippet?.contains("& measurable") == true)
    }

    @Test("Episode search maintenance follows content updates and deletes")
    func episodeSearchMaintenanceFollowsUpdatesAndDeletes() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "mutable",
                    title: "Ceramic Receiver",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: "<p>A vanadium lattice stabilizes reception.</p>"
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.prepareEpisodeSearchIndex()
        #expect(try await store.episodeSearchIndexStateDescription() == "ready")

        let oldRequest = EpisodeSearchIndexRequest(
            query: "ceramic receiver",
            mode: .episodes,
            activePodcastIDs: [Self.feedURL]
        )
        #expect(try await store.searchEpisodes(oldRequest).map(\.episodeID) == ["mutable"])
        let oldBodyRequest = EpisodeSearchIndexRequest(
            query: "vanadium lattice",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )
        #expect(
            try await store.searchEpisodes(oldBodyRequest).map(\.episodeID)
                == ["mutable"]
        )

        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "mutable",
                    title: "Optical Compass",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: "<p>A xenon gyroscope stabilizes navigation.</p>"
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        let newRequest = EpisodeSearchIndexRequest(
            query: "optical compass",
            mode: .episodes,
            activePodcastIDs: [Self.feedURL]
        )
        #expect(try await store.searchEpisodes(oldRequest).isEmpty)
        #expect(try await store.searchEpisodes(oldBodyRequest).isEmpty)
        #expect(try await store.searchEpisodes(newRequest).map(\.episodeID) == ["mutable"])
        let newBodyRequest = EpisodeSearchIndexRequest(
            query: "xenon gyroscope",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )
        let newBodyHits = try await store.searchEpisodes(newBodyRequest)
        #expect(newBodyHits.map(\.episodeID) == ["mutable"])
        #expect(newBodyHits.first?.snippet?.contains("xenon gyroscope") == true)

        try await store.deleteEpisodes(episodeIDs: ["mutable"])
        #expect(try await store.searchEpisodes(newRequest).isEmpty)
        #expect(try await store.searchEpisodes(newBodyRequest).isEmpty)
    }

    @Test("Episode search treats hostile syntax as literals")
    func episodeSearchTreatsHostileSyntaxAsLiterals() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "syntax",
                    title: "OR Near Five",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.prepareEpisodeSearchIndex()
        #expect(try await store.episodeSearchIndexStateDescription() == "ready")

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "\"OR\" NEAR(5) *",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hits.map(\.episodeID) == ["syntax"])
    }

    @Test("Episode search corrects scoped corpus terms without broad negative matches")
    func episodeSearchUsesBoundedCorpusCorrections() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "keyboard",
                    title: "Keyboard Membrane",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "kubernetes",
                    title: "Kubernetes Pronunciation",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                ),
                makeEpisode(
                    id: "episode",
                    title: "Episode 42",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                makeEpisode(
                    id: "cache",
                    title: "Local Cache",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()

        let transpositionHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "keybaord membrane",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(transpositionHits.first?.episodeID == "keyboard")
        #expect(transpositionHits.first?.scoreTrace.channel == .corrected)

        let deletionHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "kubernets",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(deletionHits.first?.episodeID == "kubernetes")
        #expect(deletionHits.first?.scoreTrace.channel == .corrected)

        let hostileNegativeHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "'); DROP TABLE episode_cache;--",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hostileNegativeHits.isEmpty)
    }

    @Test("Episode search retrieves, times, replaces, and removes transcript passages")
    func episodeSearchMaintainsTranscriptPassages() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "bird",
                    title: "How a Night Bird Finds North",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "repetitive",
                    title: "Counting Exercise",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()
        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "bird",
                podcastID: Self.feedURL,
                version: "v1",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "bird-1",
                        startSeconds: 42,
                        endSeconds: 57,
                        text: "Cryptochrome radical pairs respond to Earth's magnetic field."
                    )
                ]
            )
        )
        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "repetitive",
                podcastID: Self.feedURL,
                version: "v1",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "repeat-1",
                        startSeconds: 8,
                        endSeconds: 18,
                        text: String(repeating: "coral ", count: 80)
                    )
                ]
            )
        )

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "cryptochrome radical pairs",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hits.first?.episodeID == "bird")
        #expect(hits.first?.scoreTrace.matchedFields.contains(.transcript) == true)
        #expect(hits.first?.transcriptPassage?.segmentID == "bird-1")
        #expect(hits.first?.transcriptPassage?.startSeconds == 42)
        #expect(hits.first?.transcriptPassage?.endSeconds == 57)

        let visibleOnlyHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "magnetoreception",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(visibleOnlyHits.isEmpty)

        let typoHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "magnetorecpetion",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(typoHits.first?.episodeID == "bird")
        #expect(typoHits.first?.transcriptPassage?.segmentID == "bird-1")

        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "bird",
                podcastID: Self.feedURL,
                version: "v2",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "bird-2",
                        startSeconds: 60,
                        endSeconds: 72,
                        text: "A replacement passage discusses polarized starlight."
                    )
                ]
            )
        )
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "magnetoreception",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        ).isEmpty)
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "polarized starlight",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        ).first?.transcriptPassage?.segmentID == "bird-2")

        try await store.removeEpisodeTranscriptSearchDocument(episodeID: "bird")
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "polarized starlight",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        ).isEmpty)
    }

    @Test("Transcript hits render a passage snippet and body evidence still wins")
    func transcriptHitsRenderPassageSnippet() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "transcript-only",
                    title: "Deep Water Survey",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "notes-and-transcript",
                    title: "Harbor Report",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: "<p>The bioluminescent plankton bloom stretched for miles offshore.</p>"
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()
        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "transcript-only",
                podcastID: Self.feedURL,
                version: "v1",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "deep-1",
                        startSeconds: 10,
                        endSeconds: 24,
                        text: "The sonar picked up a bioluminescent shimmer near the trench floor."
                    )
                ]
            )
        )
        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: "notes-and-transcript",
                podcastID: Self.feedURL,
                version: "v1",
                segments: [
                    EpisodeSearchTranscriptSegment(
                        segmentID: "harbor-1",
                        startSeconds: 5,
                        endSeconds: 15,
                        text: "Divers reported bioluminescent flashes under the pier."
                    )
                ]
            )
        )

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "bioluminescent",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        let transcriptOnly = try #require(
            hits.first { $0.episodeID == "transcript-only" }
        )
        #expect(transcriptOnly.snippet?.contains("sonar") == true)
        #expect(transcriptOnly.snippetHighlightTerms == ["bioluminescent"])
        #expect(transcriptOnly.transcriptPassage?.segmentID == "deep-1")

        // Legacy search surfaced the show-notes snippet; a hit matching both
        // sources must keep it rather than the transcript excerpt.
        let bothSources = try #require(
            hits.first { $0.episodeID == "notes-and-transcript" }
        )
        #expect(bothSources.snippet?.contains("plankton bloom") == true)
        #expect(bothSources.scoreTrace.matchedFields.contains(.transcript))
    }

    @Test("Replacing an unchanged transcript document writes nothing")
    func unchangedTranscriptReplaceWritesNothing() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "stable-transcript",
                    title: "Stable Transcript",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()
        let document = EpisodeSearchTranscriptDocument(
            episodeID: "stable-transcript",
            podcastID: Self.feedURL,
            version: "v1",
            segments: [
                EpisodeSearchTranscriptSegment(
                    segmentID: "stable-1",
                    startSeconds: 0,
                    endSeconds: 9,
                    text: "An unchanged aurora forecast for the northern stations."
                ),
                EpisodeSearchTranscriptSegment(
                    segmentID: "stable-2",
                    startSeconds: 9,
                    endSeconds: 20,
                    text: "Signal strength held steady through the night."
                ),
            ]
        )
        try await store.replaceEpisodeTranscriptSearchDocument(document)
        let changesBeforeIdenticalReplace = try await store.totalRowChangeCount()

        try await store.replaceEpisodeTranscriptSearchDocument(document)

        // Reconciliation replays every completed transcript per launch; an
        // unchanged version+segment set must be a read-only no-op.
        #expect(
            try await store.totalRowChangeCount() == changesBeforeIdenticalReplace
        )

        let changedDocument = EpisodeSearchTranscriptDocument(
            episodeID: "stable-transcript",
            podcastID: Self.feedURL,
            version: "v2",
            segments: [
                EpisodeSearchTranscriptSegment(
                    segmentID: "stable-1",
                    startSeconds: 0,
                    endSeconds: 9,
                    text: "A revised aurora forecast replaces the overnight guidance."
                )
            ]
        )
        try await store.replaceEpisodeTranscriptSearchDocument(changedDocument)
        #expect(
            try await store.totalRowChangeCount() > changesBeforeIdenticalReplace
        )
        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "revised aurora",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hits.first?.episodeID == "stable-transcript")
    }

    @Test("Mid-word substring recall supplements FTS hits after the ranked results")
    func midWordSubstringRecallSupplementsRankedResults() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "substring",
                    title: "The Broadcast Hour",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "token",
                    title: "Cast Away Reunion",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                makeEpisode(
                    id: "miss",
                    title: "Harbor Report",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "cast",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        // The whole-token FTS match keeps its rank; the mid-word containment
        // hit the legacy matcher used to find follows it.
        #expect(hits.map(\.episodeID) == ["token", "substring"])
        #expect(hits.last?.scoreTrace.channel == .visibleSubstring)
    }

    @Test("Turkish dotted and dotless titles are found from either casing")
    func turkishDottedAndDotlessTitlesAreFound() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "uppercase",
                    title: "IŞIK Söyleşisi",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "lowercase",
                    title: "ışık masalı",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await store.prepareEpisodeSearchIndex()

        for query in ["ışık", "IŞIK", "isik"] {
            let hits = try await store.searchEpisodes(
                EpisodeSearchIndexRequest(
                    query: query,
                    mode: .episodes,
                    activePodcastIDs: [Self.feedURL]
                )
            )
            #expect(
                Set(hits.map(\.episodeID)) == ["uppercase", "lowercase"],
                "query \(query)"
            )
        }
    }

    @Test("Broad queries return the same result set as the legacy fallback")
    func broadQueriesMatchLegacyFallbackResultSet() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let episodes = (0..<60).map { index in
            makeEpisode(
                id: String(format: "bulk-%02d", index),
                title: "Fieldwork Dispatch \(index)",
                publishedAt: Date(
                    timeIntervalSince1970: 1_700_000_000 + Double(index)
                )
            )
        }
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: episodes),
            refreshedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        try await store.prepareEpisodeSearchIndex()
        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])

        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "fieldwork",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        let legacyMatches = EpisodeSearch.matchingEpisodes(
            in: library.episodes,
            query: "fieldwork"
        )

        // The old 50-hit default silently truncated broad queries while the
        // legacy fallback returned everything; both paths must agree now.
        #expect(hits.count == 60)
        #expect(
            Set(hits.map(\.episodeID)) == Set(legacyMatches.map(\.episodeID))
        )
    }

    @Test("A relaunched search index validates before use and preserves ranking")
    func episodeSearchRelaunchValidatesBeforeUse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SQLiteSearchRelaunchTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "LocalLibraryCache.sqlite")
        let request = EpisodeSearchIndexRequest(
            query: "orchard midnight",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )

        let firstStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await firstStore.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "relaunch-exact",
                    title: "The Orchard at Midnight",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "relaunch-body",
                    title: "Night Agriculture",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: "<p>An orchard after midnight.</p>"
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await firstStore.prepareEpisodeSearchIndex()
        let expectedIDs = try await firstStore.searchEpisodes(request)
            .map(\.episodeID)

        let relaunchedStore = SQLiteLocalLibraryCacheStore(
            databaseURL: databaseURL
        )
        #expect(
            try await relaunchedStore.episodeSearchIndexStateDescription()
                == "validating"
        )
        await #expect(throws: EpisodeSearchIndexError.self) {
            _ = try await relaunchedStore.searchEpisodes(request)
        }

        try await relaunchedStore.prepareEpisodeSearchIndex()
        #expect(
            try await relaunchedStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )
    }

    @Test("Upgrade and derived-index corruption rebuild to canonical rankings")
    func episodeSearchUpgradeAndCorruptionRecover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SQLiteSearchRecoveryTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "LocalLibraryCache.sqlite")
        let request = EpisodeSearchIndexRequest(
            query: "recovery beacon",
            mode: .fullText,
            activePodcastIDs: [Self.feedURL]
        )

        let originalStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await originalStore.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "recovery-title",
                    title: "Recovery Beacon",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
                ),
                makeEpisode(
                    id: "recovery-notes",
                    title: "Repair Log",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    showNotesHTML: "<p>The recovery beacon remained visible.</p>"
                ),
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try await originalStore.prepareEpisodeSearchIndex()
        let expectedIDs = try await originalStore.searchEpisodes(request)
            .map(\.episodeID)

        // Version 1 is the pre-search canonical cache version. Opening it must
        // preserve canonical rows while recreating only disposable search data.
        try execRawSQL("PRAGMA user_version = 1", databaseURL: databaseURL)
        let upgradedStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        _ = try await upgradedStore.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(try await upgradedStore.currentSchemaVersion() == 5)
        try await upgradedStore.prepareEpisodeSearchIndex()
        #expect(
            try await upgradedStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )

        // Delete one derived evidence row without touching canonical cache
        // data or the ready marker. Relaunch validation must detect and heal it.
        try execRawSQL(
            "DELETE FROM episode_search_evidence WHERE search_rowid IN (SELECT search_rowid FROM episode_search_evidence LIMIT 1)",
            databaseURL: databaseURL
        )
        let corruptedStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        await #expect(throws: EpisodeSearchIndexError.self) {
            _ = try await corruptedStore.searchEpisodes(request)
        }
        try await corruptedStore.prepareEpisodeSearchIndex()
        #expect(
            try await corruptedStore.searchEpisodes(request).map(\.episodeID)
                == expectedIDs
        )
        let canonical = try await corruptedStore.loadLibrary(
            activePodcastIDs: [Self.feedURL]
        )
        #expect(canonical.episodes.count == 2)
    }

    @Test("A cancelled rebuild remains resumable and converges without ghosts")
    func episodeSearchInterruptedRebuildResumes() async throws {
        let store = SQLiteLocalLibraryCacheStore(
            databaseURL: nil,
            episodeSearchRebuildBatchSize: 1
        )
        let episodes = (0..<160).map { index in
            makeEpisode(
                id: "interrupted-\(index)",
                title: index == 159
                    ? "Interrupted Rebuild Sentinel"
                    : "Routine Episode \(index)",
                publishedAt: Date(
                    timeIntervalSince1970: 1_700_000_000 + Double(index)
                )
            )
        }
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: episodes),
            refreshedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )

        let rebuildTask = Task {
            try await store.prepareEpisodeSearchIndex()
        }
        var observedRebuild = false
        for _ in 0..<200 {
            if try await store.episodeSearchIndexStateDescription()
                == "rebuilding" {
                observedRebuild = true
                break
            }
            await Task.yield()
        }
        try #require(observedRebuild)
        rebuildTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await rebuildTask.value
        }
        #expect(
            try await store.episodeSearchIndexStateDescription()
                == "needsRebuild"
        )

        try await store.prepareEpisodeSearchIndex()
        let hits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "interrupted rebuild sentinel",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL]
            )
        )
        #expect(hits.map(\.episodeID) == ["interrupted-159"])
    }

    @Test("Identity replacement, cancellation, and concurrent refresh stay bounded")
    func episodeSearchIdentityReplacementAndConcurrency() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "old-identity",
                    title: "Copper Wayfinder",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.prepareEpisodeSearchIndex()

        try await store.deleteEpisodes(episodeIDs: ["old-identity"])
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(
                    id: "new-identity",
                    title: "Copper Wayfinder",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        let request = EpisodeSearchIndexRequest(
            query: "copper",
            mode: .episodes,
            activePodcastIDs: [Self.feedURL]
        )
        #expect(
            try await store.searchEpisodes(request).map(\.episodeID)
                == ["new-identity"]
        )

        let cancelledSearch = Task {
            try Task.checkCancellation()
            return try await store.searchEpisodes(request)
        }
        cancelledSearch.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledSearch.value
        }

        let searches = Task {
            for _ in 0..<20 {
                _ = try await store.searchEpisodes(request)
            }
        }
        let refresh = Task {
            try await store.upsertCache(
                from: makeFeedSnapshot(episodes: [
                    makeEpisode(
                        id: "new-identity",
                        title: "Silver Wayfinder",
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_200)
                    )
                ]),
                refreshedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        }
        try await searches.value
        try await refresh.value

        #expect(try await store.searchEpisodes(request).isEmpty)
        #expect(
            try await store.searchEpisodes(
                EpisodeSearchIndexRequest(
                    query: "silver wayfinder",
                    mode: .episodes,
                    activePodcastIDs: [Self.feedURL]
                )
            ).map(\.episodeID) == ["new-identity"]
        )
    }

    @Test("Deleting one feed's cache leaves other feeds untouched")
    func deleteCacheRemovesSingleFeed() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await seedTwoFeeds(in: store)
        try await store.prepareEpisodeSearchIndex()

        try await store.deleteCache(forPodcastID: Self.feedURL)

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL, Self.otherFeedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL] == nil)
        #expect(library.podcastsByFeedURL[Self.otherFeedURL] != nil)
        #expect(library.episodes.map(\.episodeID) == ["ep-other"])
        #expect(library.refreshLogs.map(\.feedURL) == [Self.otherFeedURL])
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "main",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL, Self.otherFeedURL]
            )
        ).isEmpty)
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "other episode",
                mode: .episodes,
                activePodcastIDs: [Self.feedURL, Self.otherFeedURL]
            )
        ).map(\.episodeID) == ["ep-other"])
    }

    @Test("Deleting all local cache clears podcasts, episodes, and refresh logs")
    func deleteAllLocalCacheClearsEverything() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await seedTwoFeeds(in: store)
        try await store.prepareEpisodeSearchIndex()

        try await store.deleteAllLocalCache()

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL, Self.otherFeedURL])
        #expect(library.podcastsByFeedURL.isEmpty)
        #expect(library.episodes.isEmpty)
        #expect(library.refreshLogs.isEmpty)
        #expect(try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "episode",
                mode: .fullText,
                activePodcastIDs: [Self.feedURL, Self.otherFeedURL]
            )
        ).isEmpty)
    }

    @Test("Legacy import inserts rows, marks completion, and ignores conflicting re-imports")
    func legacyImportInsertsAndIgnoresConflicts() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let podcast = makeLegacyPodcast(title: "Legacy Show")
        let episode = EpisodeDetailSnapshot(
            listItem: makeLegacyListItem(episodeID: "legacy-episode", title: "Legacy Episode"),
            showNotesHTML: "<p>Legacy notes</p>"
        )
        let log = RefreshLogSnapshot(
            refreshID: "legacy-refresh",
            feedURL: Self.feedURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_005)
        )
        try await store.importLegacyCache(podcasts: [podcast], episodes: [episode], refreshLogs: [log])

        let hasImported = try await store.hasCompletedLegacyImport()
        #expect(hasImported)

        let conflictingEpisode = EpisodeDetailSnapshot(
            listItem: makeLegacyListItem(episodeID: "legacy-episode", title: "Conflicting Episode"),
            showNotesHTML: "<p>Conflicting notes</p>"
        )
        try await store.importLegacyCache(
            podcasts: [makeLegacyPodcast(title: "Conflicting Show")],
            episodes: [conflictingEpisode],
            refreshLogs: []
        )

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL]?.title == "Legacy Show")
        #expect(library.episodes.map(\.title) == ["Legacy Episode"])
        #expect(library.refreshLogs.map(\.refreshID) == ["legacy-refresh"])

        let detail = try await store.episodeDetail(episodeID: "legacy-episode")
        #expect(detail?.showNotesHTML == "<p>Legacy notes</p>")
    }

    @Test("File-backed store persists data across store instances")
    func fileBackedStorePersistsAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SQLiteLocalLibraryCacheStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appending(path: "LocalLibraryCache.sqlite")

        let firstStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await firstStore.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-file", title: "Persisted Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        let secondStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        let library = try await secondStore.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL]?.title == "Cached Show")
        #expect(library.episodes.map(\.episodeID) == ["ep-file"])
    }

    @Test("Reopening a pre-existing cache drops the legacy published index")
    func reopeningPreExistingCacheDropsLegacyPublishedIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SQLiteLocalLibraryCacheStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appending(path: "LocalLibraryCache.sqlite")

        let firstStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        try await firstStore.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-idx", title: "Indexed Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        // Installed devices created this index before it left schemaSQL.
        try execRawSQL(
            "CREATE INDEX IF NOT EXISTS episode_cache_published_idx ON episode_cache(published_at DESC)",
            databaseURL: databaseURL
        )
        #expect(try indexNames(databaseURL: databaseURL).contains("episode_cache_published_idx"))

        let secondStore = SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        _ = try await secondStore.loadLibrary(activePodcastIDs: [Self.feedURL])

        let names = try indexNames(databaseURL: databaseURL)
        #expect(!names.contains("episode_cache_published_idx"))
        #expect(names.contains("episode_cache_podcast_published_idx"))
    }

    private func execRawSQL(_ sql: String, databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw LocalLibraryCacheStoreError(operation: "test open", message: "unable to open database")
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalLibraryCacheStoreError(operation: "test exec", message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func indexNames(databaseURL: URL) throws -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw LocalLibraryCacheStoreError(operation: "test open", message: "unable to open database")
        }
        defer { sqlite3_close_v2(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT name FROM sqlite_master WHERE type = 'index'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw LocalLibraryCacheStoreError(operation: "test prepare", message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: name))
            }
        }
        return names
    }

    private func seedTwoFeeds(in store: SQLiteLocalLibraryCacheStore) async throws {
        try await store.upsertCache(
            from: makeFeedSnapshot(episodes: [
                makeEpisode(id: "ep-main", title: "Main Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))
            ]),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.upsertCache(
            from: makeFeedSnapshot(
                feedURL: Self.otherFeedURL,
                title: "Other Show",
                episodes: [
                    makeEpisode(
                        id: "ep-other",
                        feedURL: Self.otherFeedURL,
                        title: "Other Episode",
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                    )
                ]
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try await store.insertRefreshLog(
            RefreshLogSnapshot(
                refreshID: "main-refresh",
                feedURL: Self.feedURL,
                startedAt: Date(timeIntervalSince1970: 1_700_000_290),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_300)
            ),
            prunedTo: 50
        )
        try await store.insertRefreshLog(
            RefreshLogSnapshot(
                refreshID: "other-refresh",
                feedURL: Self.otherFeedURL,
                startedAt: Date(timeIntervalSince1970: 1_700_000_280),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_290)
            ),
            prunedTo: 50
        )
    }

    private func makeFeedSnapshot(
        feedURL: String = SQLiteLocalLibraryCacheStoreTests.feedURL,
        title: String = "Cached Show",
        summary: String? = "Cached summary",
        artworkURL: String? = "https://example.com/podcast-art.png",
        languageCode: String? = nil,
        episodes: [Episode]
    ) -> FeedSnapshot {
        FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: feedURL),
                feedURL: URL(string: feedURL)!,
                title: title,
                author: "Cached Author",
                summary: summary,
                websiteURL: URL(string: "https://example.com/show"),
                artworkURL: artworkURL.flatMap { URL(string: $0) },
                languageCode: languageCode
            ),
            episodes: episodes,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeEpisode(
        id: String,
        feedURL: String = SQLiteLocalLibraryCacheStoreTests.feedURL,
        title: String,
        publishedAt: Date?,
        showNotesHTML: String? = nil,
        audioURL: String? = nil,
        artworkURL: String? = nil
    ) -> Episode {
        Episode(
            id: EpisodeID(rawValue: id),
            podcastID: PodcastID(rawValue: feedURL),
            podcastTitle: "Cached Show",
            title: title,
            summary: "Summary for \(title)",
            showNotesHTML: showNotesHTML,
            publishedAt: publishedAt,
            duration: 120,
            audioURL: URL(string: audioURL ?? "https://example.com/audio/\(id).mp3"),
            artworkURL: artworkURL.flatMap { URL(string: $0) },
            guid: id
        )
    }

    private func makePreview(forArtworkURL artworkURL: String) throws -> ArtworkPreview {
        let canonicalKey = try #require(ArtworkPreview.canonicalArtworkURLKey(for: artworkURL))
        return try #require(
            ArtworkPreview(
                version: ArtworkPreview.currentVersion,
                canonicalArtworkURLKey: canonicalKey,
                sourceHash: "hash-\(artworkURL)",
                pixelWidth: 8,
                pixelHeight: 8,
                rgbData: Data(repeating: 0x40, count: ArtworkPreview.requiredRGBByteCount(width: 8, height: 8))
            )
        )
    }

    @Test("Stale artwork preview writes are skipped when the row's artwork URL changed")
    func staleArtworkPreviewWritesAreSkipped() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let originalArt = "https://example.com/original-art.png"
        let replacementArt = "https://example.com/replacement-art.png"
        let snapshot = makeFeedSnapshot(
            artworkURL: originalArt,
            episodes: [
                makeEpisode(
                    id: "ep-1",
                    title: "Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    artworkURL: replacementArt
                )
            ]
        )
        try await store.upsertCache(from: snapshot, refreshedAt: Date(timeIntervalSince1970: 1_700_000_300))

        let stalePreview = try makePreview(forArtworkURL: originalArt)
        try await store.updateEpisodeArtworkPreview(stalePreview, episodeID: "ep-1", artworkURL: originalArt)
        try await store.updatePodcastArtworkPreview(stalePreview, feedURL: Self.feedURL, artworkURL: replacementArt)

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL])
        #expect(library.episodes.first?.artworkPreview == nil)
        #expect(library.podcastsByFeedURL[Self.feedURL]?.artworkPreview == nil)
    }

    private func makeLegacyPodcast(title: String) -> PodcastCacheSnapshot {
        PodcastCacheSnapshot(
            feedURL: Self.feedURL,
            title: title,
            author: "Legacy Author",
            summary: "Legacy summary",
            websiteURL: "https://example.com/legacy",
            artworkURL: "https://example.com/legacy-art.png",
            artworkPreview: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeLegacyListItem(episodeID: String, title: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: Self.feedURL,
            podcastTitle: "Legacy Show",
            title: title,
            summary: "Summary for \(title)",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_010),
            duration: 90,
            audioURL: "https://example.com/audio/\(episodeID).mp3",
            artworkURL: "https://example.com/legacy-episode-art.png",
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )
    }
}
