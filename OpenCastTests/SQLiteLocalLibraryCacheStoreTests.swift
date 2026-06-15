import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("SQLite local library cache store")
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

        let library = try await store.loadLibrary(activePodcastIDs: [])
        #expect(library.refreshLogs.count == 51)

        let feedLogs = library.refreshLogs.filter { $0.feedURL == Self.feedURL }
        #expect(feedLogs.map(\.refreshID) == (6...55).reversed().map { "refresh-\($0)" })
        #expect(library.refreshLogs.last == otherLog)
    }

    @Test("Deleting one feed's cache leaves other feeds untouched")
    func deleteCacheRemovesSingleFeed() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await seedTwoFeeds(in: store)

        try await store.deleteCache(forPodcastID: Self.feedURL)

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL, Self.otherFeedURL])
        #expect(library.podcastsByFeedURL[Self.feedURL] == nil)
        #expect(library.podcastsByFeedURL[Self.otherFeedURL] != nil)
        #expect(library.episodes.map(\.episodeID) == ["ep-other"])
        #expect(library.refreshLogs.map(\.feedURL) == [Self.otherFeedURL])
    }

    @Test("Deleting all local cache clears podcasts, episodes, and refresh logs")
    func deleteAllLocalCacheClearsEverything() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        try await seedTwoFeeds(in: store)

        try await store.deleteAllLocalCache()

        let library = try await store.loadLibrary(activePodcastIDs: [Self.feedURL, Self.otherFeedURL])
        #expect(library.podcastsByFeedURL.isEmpty)
        #expect(library.episodes.isEmpty)
        #expect(library.refreshLogs.isEmpty)
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
                artworkURL: artworkURL.flatMap { URL(string: $0) }
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
