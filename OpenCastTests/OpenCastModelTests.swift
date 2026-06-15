import Foundation
import OpenCastCore
import OpenCastPlayback
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("SwiftData models")
struct OpenCastModelTests {
    private static let modelFixtureFeedURL = "https://example.com/model-fixture.xml"

    @Test("Creates an in-memory two-configuration model container")
    func createsInMemoryContainer() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let subscription = SubscriptionRecord(
            feedURL: Self.modelFixtureFeedURL,
            title: "Model Fixture Podcast"
        )

        context.insert(subscription)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(fetched.map(\.feedURL) == [Self.modelFixtureFeedURL])
        #expect(fetched.first?.isVoiceBoostEnabled == true)
    }

    @Test("Synced records use logical keys instead of unique attributes")
    func syncedRecordsUseLogicalKeys() {
        let subscription = SubscriptionRecord(
            feedURL: Self.modelFixtureFeedURL,
            title: "Model Fixture Podcast"
        )
        let progress = EpisodeProgressRecord(
            episodeID: "episode-id",
            podcastID: subscription.feedURL,
            position: 42
        )

        #expect(subscription.feedURL == progress.podcastID)
        #expect(subscription.isVoiceBoostEnabled == true)
        #expect(progress.position == 42)
    }

    @Test("Subscribe inserts subscription podcast and episode cache rows")
    func subscribeInsertsRowsAndReloadsStoreState() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/subscribe.xml"
        let podcastID = PodcastID(rawValue: feedURL)
        let snapshot = FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: "Subscribed Show",
                author: "Subscribed Author",
                summary: "Subscribed summary",
                websiteURL: URL(string: "https://example.com/show"),
                artworkURL: URL(string: "https://example.com/art.jpg")
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: "subscribe-episode-1"),
                    podcastID: podcastID,
                    podcastTitle: "Subscribed Show",
                    title: "First Subscribed Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_001),
                    duration: 120,
                    audioURL: URL(string: "https://example.com/audio/subscribe-1.mp3"),
                    guid: "subscribe-episode-1"
                ),
                Episode(
                    id: EpisodeID(rawValue: "subscribe-episode-2"),
                    podcastID: podcastID,
                    podcastTitle: "Subscribed Show",
                    title: "Second Subscribed Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_002),
                    duration: 240,
                    audioURL: URL(string: "https://example.com/audio/subscribe-2.mp3"),
                    guid: "subscribe-episode-2"
                )
            ]
        )
        let service = StubFeedService(responses: [feedURL: .success(snapshot)])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        try await store.subscribe(to: " \(feedURL) ", modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let requestedURLs = await service.requestedURLStrings()

        #expect(requestedURLs == [feedURL])
        #expect(subscriptions.count == 1)
        #expect(subscriptions.first?.feedURL == feedURL)
        #expect(subscriptions.first?.title == "Subscribed Show")
        #expect(subscriptions.first?.author == "Subscribed Author")
        #expect(subscriptions.first?.isArchived == false)
        #expect(subscriptions.first?.isVoiceBoostEnabled == true)
        #expect(store.podcastCacheByFeedURL.count == 1)
        #expect(store.podcastCache(for: feedURL)?.feedURL == feedURL)
        #expect(store.podcastCache(for: feedURL)?.title == "Subscribed Show")
        #expect(store.subscriptions.map(\.feedURL) == [feedURL])
        #expect(store.episodes.map(\.episodeID) == ["subscribe-episode-2", "subscribe-episode-1"])
        #expect(store.inboxEpisodes.map(\.episodeID) == ["subscribe-episode-2", "subscribe-episode-1"])
        #expect(store.state == .idle)
    }

    @Test("Subscribe cache write failure does not persist a subscription")
    func subscribeCacheWriteFailureDoesNotPersistSubscription() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/subscribe-cache-failure.xml"
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Cache Failure",
                    episodeID: "cache-failure-episode",
                    episodeTitle: "Cache Failure Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: FailingUpsertCacheStore())

        do {
            try await store.subscribe(to: feedURL, modelContext: context)
            Issue.record("Expected subscribe to fail when the local cache write fails.")
        } catch {
            #expect(error.localizedDescription == "Local cache upsert failed")
        }

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        #expect(subscriptions.isEmpty)
        #expect(store.subscriptions.isEmpty)
        #expect(store.state == .failed("Local cache upsert failed"))
    }

    @Test("Refresh cache write failure does not advance subscription metadata")
    func refreshCacheWriteFailureDoesNotAdvanceSubscriptionMetadata() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/refresh-cache-failure.xml"
        let originalLastRefreshAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Original Show",
                author: "Original Author",
                artworkURL: "https://example.com/original-art.jpg",
                lastRefreshAt: originalLastRefreshAt
            )
        )
        try context.save()

        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Updated Show",
                    episodeID: "refresh-cache-failure-episode",
                    episodeTitle: "Refresh Cache Failure Episode",
                    artworkURL: URL(string: "https://example.com/updated-art.jpg")
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: FailingUpsertCacheStore())

        await store.load(modelContext: context)
        await store.refresh(feedURL: feedURL, modelContext: context)

        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
        let subscription = try #require(subscriptions.first)
        #expect(subscriptions.count == 1)
        #expect(subscription.title == "Original Show")
        #expect(subscription.author == "Original Author")
        #expect(subscription.artworkURL == "https://example.com/original-art.jpg")
        #expect(subscription.lastRefreshAt == originalLastRefreshAt)
    }

    @Test("Resume progress transitions from in-progress to played")
    func progressTransitions() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        await store.load(modelContext: context)
        store.updateProgress(
            episodeID: "episode-id",
            podcastID: Self.modelFixtureFeedURL,
            position: 42,
            duration: 100,
            modelContext: context
        )

        #expect(store.resumePosition(for: "episode-id") == 42)

        store.updateProgress(
            episodeID: "episode-id",
            podcastID: Self.modelFixtureFeedURL,
            position: 96,
            duration: 100,
            modelContext: context
        )

        #expect(store.resumePosition(for: "episode-id") == 0)
    }

    @Test("Mark played writes played progress")
    func markPlayedWritesPlayedProgress() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = makeEpisodeListItem(
            episodeID: "manual-mark-played",
            podcastID: "https://example.com/manual-progress.xml",
            podcastTitle: "Manual Progress",
            title: "Mark Played",
            duration: 120,
            audioURL: "https://example.com/manual-mark-played.mp3"
        )
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        await appModel.library.load(modelContext: context)

        #expect(appModel.markEpisodePlayed(episode, modelContext: context))

        let progressRecords = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(progressRecords.count == 1)
        #expect(progressRecords.first?.episodeID == episode.episodeID)
        #expect(progressRecords.first?.isPlayed == true)
        #expect(appModel.library.progressSummary(for: episode).isCompleted)
    }

    @Test("Mark played unloads current episode even when progress is already played")
    func markPlayedUnloadsCurrentEpisodeEvenWhenProgressIsAlreadyPlayed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = makeEpisodeListItem(
            episodeID: "already-played-current",
            podcastID: "https://example.com/manual-progress.xml",
            podcastTitle: "Manual Progress",
            title: "Already Played Current Episode",
            duration: 120,
            audioURL: "https://example.com/already-played-current.mp3"
        )
        context.insert(EpisodeProgressRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: 120,
            duration: 120,
            isPlayed: true
        ))
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episode.episodeID))
        try context.save()
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        await appModel.library.load(modelContext: context)
        try appModel.playback.load(appModel.library.domainEpisode(for: episode), startPosition: 0)

        let didSave = appModel.markEpisodePlayed(episode, modelContext: context)
        let lastEpisodePreferences = try context.fetch(FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate { record in
                record.key == "playback.lastEpisodeID"
            }
        ))

        #expect(!didSave)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(lastEpisodePreferences.isEmpty)
    }

    @Test("Clear progress removes duplicate progress rows")
    func clearProgressRemovesDuplicateProgressRows() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = makeEpisodeListItem(
            episodeID: "manual-clear-progress",
            podcastID: "https://example.com/manual-progress.xml",
            podcastTitle: "Manual Progress",
            title: "Clear Progress",
            duration: 120,
            audioURL: "https://example.com/manual-clear-progress.mp3"
        )
        context.insert(EpisodeProgressRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: 42,
            duration: 120
        ))
        context.insert(EpisodeProgressRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: 84,
            duration: 120
        ))
        try context.save()
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        await appModel.library.load(modelContext: context)

        #expect(appModel.clearEpisodeProgress(episode, modelContext: context))

        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(appModel.library.progressRecord(for: episode.episodeID) == nil)
        #expect(appModel.library.progressSummary(for: episode).hasVisibleProgress == false)
    }

    @Test("Resume and played state follow duration thresholds")
    func resumeAndPlayedStateUsePositionThresholds() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let podcastID = "https://example.com/progress.xml"

        await store.load(modelContext: context)

        store.updateProgress(
            episodeID: "at-start",
            podcastID: podcastID,
            position: 0,
            duration: 1_000,
            modelContext: context
        )
        #expect(store.resumePosition(for: "at-start") == 0)
        #expect(store.progressRecords.first { $0.episodeID == "at-start" }?.isPlayed == false)

        store.updateProgress(
            episodeID: "midpoint",
            podcastID: podcastID,
            position: 500,
            duration: 1_000,
            modelContext: context
        )
        #expect(store.resumePosition(for: "midpoint") == 500)
        #expect(store.progressRecords.first { $0.episodeID == "midpoint" }?.isPlayed == false)

        store.updateProgress(
            episodeID: "near-end",
            podcastID: podcastID,
            position: 971,
            duration: 1_000,
            modelContext: context
        )
        #expect(store.resumePosition(for: "near-end") == 0)
        #expect(store.progressRecords.first { $0.episodeID == "near-end" }?.isPlayed == true)

        store.updateProgress(
            episodeID: "past-ninety-five-percent",
            podcastID: podcastID,
            position: 951,
            duration: 1_000,
            modelContext: context
        )
        #expect(store.resumePosition(for: "past-ninety-five-percent") == 0)
        #expect(store.progressRecords.first { $0.episodeID == "past-ninety-five-percent" }?.isPlayed == true)

        store.updateProgress(
            episodeID: "past-ninety-five-percent-with-more-than-a-minute-left",
            podcastID: podcastID,
            position: 9_501,
            duration: 10_000,
            modelContext: context
        )
        #expect(store.resumePosition(for: "past-ninety-five-percent-with-more-than-a-minute-left") == 9_501)
        #expect(store.progressRecords.first { $0.episodeID == "past-ninety-five-percent-with-more-than-a-minute-left" }?.isPlayed == false)

        store.updateProgress(
            episodeID: "unknown-duration",
            podcastID: podcastID,
            position: 300,
            duration: nil,
            modelContext: context
        )
        #expect(store.resumePosition(for: "unknown-duration") == 300)
        #expect(store.progressRecords.first { $0.episodeID == "unknown-duration" }?.isPlayed == false)
    }

    @Test("Duplicate progress updates are no-op saves")
    func duplicateProgressUpdatesAreNoOpSaves() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = EpisodeProgressRecord(
            episodeID: "duplicate-progress",
            podcastID: "https://example.com/progress.xml",
            position: 42,
            duration: 100,
            isPlayed: false,
            updatedAt: updatedAt
        )

        context.insert(progress)
        try context.save()
        await store.load(modelContext: context)

        let didSave = store.updateProgress(
            episodeID: "duplicate-progress",
            podcastID: "https://example.com/progress.xml",
            position: 42,
            duration: 100,
            modelContext: context
        )

        #expect(!didSave)
        #expect(progress.updatedAt == updatedAt)
    }

    @Test("Progress position changes save only after one second")
    func progressPositionChangesSaveOnlyAfterOneSecond() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let progress = EpisodeProgressRecord(
            episodeID: "position-threshold",
            podcastID: "https://example.com/progress.xml",
            position: 42,
            duration: 100,
            isPlayed: false,
            updatedAt: updatedAt
        )

        context.insert(progress)
        try context.save()
        await store.load(modelContext: context)

        let subsecondSave = store.updateProgress(
            episodeID: "position-threshold",
            podcastID: "https://example.com/progress.xml",
            position: 42.5,
            duration: 100,
            modelContext: context
        )
        let oneSecondSave = store.updateProgress(
            episodeID: "position-threshold",
            podcastID: "https://example.com/progress.xml",
            position: 43,
            duration: 100,
            modelContext: context
        )

        #expect(!subsecondSave)
        #expect(oneSecondSave)
        #expect(progress.position == 43)
        #expect(progress.updatedAt > updatedAt)
    }

    @Test("Duration and played-state changes save progress")
    func durationAndPlayedStateChangesSaveProgress() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let durationProgress = EpisodeProgressRecord(
            episodeID: "duration-change",
            podcastID: "https://example.com/progress.xml",
            position: 20,
            duration: 100,
            isPlayed: false
        )
        let playedProgress = EpisodeProgressRecord(
            episodeID: "played-change",
            podcastID: "https://example.com/progress.xml",
            position: 80,
            duration: 100,
            isPlayed: false
        )

        context.insert(durationProgress)
        context.insert(playedProgress)
        try context.save()
        await store.load(modelContext: context)

        let durationDidSave = store.updateProgress(
            episodeID: "duration-change",
            podcastID: "https://example.com/progress.xml",
            position: 20,
            duration: 125,
            modelContext: context
        )
        let playedDidSave = store.updateProgress(
            episodeID: "played-change",
            podcastID: "https://example.com/progress.xml",
            position: 80,
            duration: 100,
            modelContext: context
        )

        #expect(durationDidSave)
        #expect(durationProgress.duration == 125)
        #expect(playedDidSave)
        #expect(playedProgress.isPlayed)
    }

    @Test("Progress updates do not reload subscription or episode state")
    func progressUpdatesDoNotReloadSubscriptionOrEpisodeState() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let initialFeedURL = "https://example.com/initial.xml"
        let laterFeedURL = "https://example.com/later.xml"

        insertCachedFeed(feedURL: initialFeedURL, title: "Initial", episodeID: "initial-episode", in: context)
        try context.save()
        await store.load(modelContext: context)

        insertCachedFeed(feedURL: laterFeedURL, title: "Later", episodeID: "later-episode", in: context)
        try context.save()

        let didSave = store.updateProgress(
            episodeID: "initial-episode",
            podcastID: initialFeedURL,
            position: 30,
            duration: 120,
            modelContext: context
        )

        #expect(didSave)
        #expect(store.progressRecords.map(\.episodeID) == ["initial-episode"])
        #expect(store.subscriptions.map(\.feedURL) == [initialFeedURL])
        #expect(store.episodes.map(\.episodeID) == ["initial-episode"])
    }

    @Test("Refresh preserves artwork previews when artwork URL still matches")
    func refreshPreservesMatchingArtworkPreviews() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/preview-preserve.xml"
        let episodeID = "preview-preserve-episode"
        let artworkURL = try #require(URL(string: "https://example.com/artwork/preserve.png"))
        let preview = try makePreview(artworkURL: artworkURL)
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Preview Preserve Updated",
                    episodeID: episodeID,
                    episodeTitle: "Preview Preserve Episode Updated",
                    artworkURL: artworkURL
                )
            )
        ])
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: service, localCache: localCache)

        insertCachedFeed(
            feedURL: feedURL,
            title: "Preview Preserve",
            episodeID: episodeID,
            artworkURL: artworkURL,
            artworkPreview: preview,
            in: context
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)

        let cached = try await localCache.loadLibrary(activePodcastIDs: [feedURL])
        #expect(cached.podcastsByFeedURL[feedURL]?.artworkPreview == preview)
        #expect(cached.episodes.first?.artworkPreview == preview)
        #expect(store.podcastCache(for: feedURL)?.artworkPreview == preview)
        #expect(store.episode(with: episodeID)?.artworkPreview == preview)
    }

    @Test("Refresh clears artwork previews when artwork URL changes")
    func refreshClearsArtworkPreviewsWhenArtworkURLChanges() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/preview-clear.xml"
        let episodeID = "preview-clear-episode"
        let oldArtworkURL = try #require(URL(string: "https://example.com/artwork/old.png"))
        let newArtworkURL = try #require(URL(string: "https://example.com/artwork/new.png"))
        let preview = try makePreview(artworkURL: oldArtworkURL)
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Preview Clear Updated",
                    episodeID: episodeID,
                    episodeTitle: "Preview Clear Episode Updated",
                    artworkURL: newArtworkURL
                )
            )
        ])
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: service, localCache: localCache)

        insertCachedFeed(
            feedURL: feedURL,
            title: "Preview Clear",
            episodeID: episodeID,
            artworkURL: oldArtworkURL,
            artworkPreview: preview,
            in: context
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)

        let cached = try await localCache.loadLibrary(activePodcastIDs: [feedURL])
        let podcast = try #require(cached.podcastsByFeedURL[feedURL])
        let episode = try #require(cached.episodes.first)
        #expect(podcast.artworkURL == newArtworkURL.absoluteString)
        #expect(episode.artworkURL == newArtworkURL.absoluteString)
        #expect(podcast.artworkPreview == nil)
        #expect(episode.artworkPreview == nil)
    }

    @Test("Artwork preview persistence skips no-op saves")
    func artworkPreviewPersistenceSkipsNoOpSaves() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(localCache: localCache)
        let feedURL = "https://example.com/preview-noop.xml"
        let episodeID = "preview-noop-episode"
        let artworkURL = try #require(URL(string: "https://example.com/artwork/noop.png"))
        let firstPreview = try makePreview(artworkURL: artworkURL, sourceHash: "first-source")
        let duplicatePreview = try makePreview(artworkURL: artworkURL, sourceHash: "first-source")
        let updatedPreview = try makePreview(artworkURL: artworkURL, sourceHash: "updated-source")

        insertCachedFeed(feedURL: feedURL, title: "Preview No-Op", episodeID: episodeID, artworkURL: artworkURL, in: context)
        try context.save()
        await store.load(modelContext: context)
        let episode = try #require(store.episode(with: episodeID))

        let firstDidSave = store.updateArtworkPreview(firstPreview, for: episode)
        let duplicateDidSave = store.updateArtworkPreview(duplicatePreview, for: episode)
        let updatedDidSave = store.updateArtworkPreview(updatedPreview, for: episode)
        await store.waitForPendingCacheWrites()

        #expect(firstDidSave)
        #expect(!duplicateDidSave)
        #expect(updatedDidSave)
        #expect(store.episode(with: episodeID)?.artworkPreview == updatedPreview)
        let cached = try await localCache.loadLibrary(activePodcastIDs: [feedURL])
        #expect(cached.episodes.first?.artworkPreview == updatedPreview)
    }

    @Test("Artwork preview persistence replaces stale schema with same source")
    func artworkPreviewPersistenceReplacesStaleSchemaWithSameSource() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let artworkURL = try #require(URL(string: "https://example.com/artwork/stale-schema.png"))
        let preview = try makePreview(artworkURL: artworkURL, sourceHash: "stable-source")
        let episode = EpisodeCacheRecord(
            episodeID: "preview-stale-schema-episode",
            podcastID: "https://example.com/preview-stale-schema.xml",
            podcastTitle: "Preview Stale Schema",
            title: "Preview Stale Schema Episode",
            artworkURL: artworkURL.absoluteString
        )
        episode.artworkPreviewVersion = preview.version - 1
        episode.artworkPreviewCanonicalURLKey = preview.canonicalArtworkURLKey
        episode.artworkPreviewSourceHash = preview.sourceHash
        episode.artworkPreviewPixelWidth = preview.pixelWidth / 2
        episode.artworkPreviewPixelHeight = preview.pixelHeight
        episode.artworkPreviewRGBData = preview.rgbData
        context.insert(episode)
        try context.save()

        let didUpdate = episode.storeArtworkPreviewIfChanged(preview)
        try context.save()

        #expect(didUpdate)
        #expect(episode.artworkPreview == preview)
    }

    @Test("Playback progress flush persists the current snapshot")
    func playbackProgressFlushPersistsCurrentSnapshot() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        let episode = makeEpisodeListItem(
            episodeID: "episode-id",
            podcastID: Self.modelFixtureFeedURL,
            podcastTitle: "Model Fixture Podcast",
            title: "A Test Episode",
            duration: 200,
            audioURL: "https://example.com/audio.mp3"
        )

        await appModel.library.load(modelContext: context)

        try appModel.playback.load(
            appModel.library.domainEpisode(for: episode),
            startPosition: 88
        )
        let firstFlushDidSave = appModel.flushPlaybackProgress(modelContext: context)
        let duplicateFlushDidSave = appModel.flushPlaybackProgress(modelContext: context)

        #expect(firstFlushDidSave)
        #expect(!duplicateFlushDidSave)
        #expect(appModel.library.resumePosition(for: "episode-id") == 88)

        appModel.playback.seek(to: 195)
        let seekFlushDidSave = appModel.flushPlaybackProgress(modelContext: context)

        let progress = appModel.library.progressRecords.first { $0.episodeID == "episode-id" }
        #expect(seekFlushDidSave)
        #expect(progress?.position == 195)
        #expect(progress?.isPlayed == true)

        appModel.playback.unload()
    }

    @Test("Dismiss current playback saves progress unloads and clears restore key")
    func dismissCurrentPlaybackSavesProgressUnloadsAndClearsRestoreKey() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/dismiss-current.xml"
        let episodeID = "dismiss-current-episode"

        insertCachedFeed(feedURL: feedURL, title: "Dismiss Current", episodeID: episodeID, in: context)
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episodeID))
        try context.save()

        await appModel.library.load(modelContext: context)
        let record = try #require(appModel.library.episode(with: episodeID))
        try appModel.playback.load(
            appModel.library.domainEpisode(for: record),
            startPosition: 42
        )
        appModel.isNowPlayingPresented = true

        #expect(appModel.dismissCurrentPlayback(modelContext: context))

        let progress = try #require(appModel.library.progressRecords.first { $0.episodeID == episodeID })
        let lastEpisodePreferences = try context.fetch(FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate { record in
                record.key == "playback.lastEpisodeID"
            }
        ))

        #expect(progress.position == 42)
        #expect(progress.isPlayed == false)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(!appModel.isNowPlayingPresented)
        #expect(lastEpisodePreferences.isEmpty)

        appModel.restorePreviousPlaybackIfAvailable(modelContext: context)

        #expect(appModel.playback.currentEpisode == nil)
    }

    @Test("Previous playback restores as paused mini-player content")
    func previousPlaybackRestoresAsPausedMiniPlayerContent() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/restore.xml"
        let episodeID = "restore-episode"

        insertCachedFeed(feedURL: feedURL, title: "Restore Show", episodeID: episodeID, in: context)
        context.insert(
            EpisodeProgressRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                position: 30,
                duration: 120,
                isPlayed: false
            )
        )
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episodeID))
        try context.save()

        await appModel.library.load(modelContext: context)
        appModel.restorePreviousPlaybackIfAvailable(modelContext: context)

        #expect(appModel.playback.currentEpisode?.id.rawValue == episodeID)
        #expect(appModel.playback.state == .paused)
        #expect(appModel.playback.position == 30)

        appModel.playback.unload()
    }

    @Test("Completed previous playback does not restore mini-player content")
    func completedPreviousPlaybackDoesNotRestoreMiniPlayerContent() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/completed-restore.xml"
        let episodeID = "completed-restore-episode"

        insertCachedFeed(feedURL: feedURL, title: "Completed Restore Show", episodeID: episodeID, in: context)
        context.insert(
            EpisodeProgressRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                position: 80,
                duration: 120,
                isPlayed: true
            )
        )
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episodeID))
        try context.save()

        await appModel.library.load(modelContext: context)
        appModel.restorePreviousPlaybackIfAvailable(modelContext: context)

        #expect(appModel.playback.currentEpisode == nil)
    }

    @Test("Unsubscribe deletes all per-feed records")
    func unsubscribeDeletesAllPerFeedRecords() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/feed.xml"

        insertFeedRecords(feedURL: feedURL, title: "Example Show", episodeID: "example-episode", in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.unsubscribe(feedURL: feedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(store.subscriptions.isEmpty)
        #expect(store.episodes.isEmpty)
        #expect(store.podcastCache(for: feedURL) == nil)
        #expect(store.refreshLogs.isEmpty)
    }

    @Test("Inactive feed caches stay out of library episode surfaces")
    func inactiveFeedCachesStayHidden() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let archivedFeedURL = "https://example.com/archived.xml"
        let archivedEpisodeID = "archived-episode"
        let unsubscribedFeedURL = "https://example.com/unsubscribed.xml"
        let unsubscribedEpisodeID = "unsubscribed-episode"

        context.insert(
            SubscriptionRecord(
                feedURL: archivedFeedURL,
                title: "Archived Show",
                isArchived: true
            )
        )
        context.insert(
            PodcastCacheRecord(
                feedURL: archivedFeedURL,
                title: "Archived Show"
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: archivedEpisodeID,
                podcastID: archivedFeedURL,
                podcastTitle: "Archived Show",
                title: "Archived Episode",
                publishedAt: Date()
            )
        )
        context.insert(
            PodcastCacheRecord(
                feedURL: unsubscribedFeedURL,
                title: "Unsubscribed Show"
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: unsubscribedEpisodeID,
                podcastID: unsubscribedFeedURL,
                podcastTitle: "Unsubscribed Show",
                title: "Unsubscribed Episode",
                publishedAt: Date()
            )
        )
        try context.save()

        await store.load(modelContext: context)

        #expect(store.subscriptions.isEmpty)
        #expect(store.inboxEpisodes.isEmpty)
        #expect(store.episodes(forPodcastID: archivedFeedURL).isEmpty)
        #expect(store.episode(with: archivedEpisodeID)?.episodeID == nil)
        #expect(store.episodes(forPodcastID: unsubscribedFeedURL).isEmpty)
        #expect(store.episode(with: unsubscribedEpisodeID)?.episodeID == nil)
    }

    @Test("Inbox keeps completed episodes from active subscriptions")
    func inboxKeepsCompletedEpisodesFromActiveSubscriptions() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let activeFeedURL = "https://example.com/active.xml"
        let archivedFeedURL = "https://example.com/archived-inbox.xml"
        let unsubscribedFeedURL = "https://example.com/unsubscribed-inbox.xml"

        context.insert(
            SubscriptionRecord(
                feedURL: activeFeedURL,
                title: "Active Show"
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: archivedFeedURL,
                title: "Archived Show",
                isArchived: true
            )
        )
        context.insert(PodcastCacheRecord(feedURL: activeFeedURL, title: "Active Show"))
        context.insert(PodcastCacheRecord(feedURL: archivedFeedURL, title: "Archived Show"))
        context.insert(PodcastCacheRecord(feedURL: unsubscribedFeedURL, title: "Unsubscribed Show"))
        context.insert(
            EpisodeCacheRecord(
                episodeID: "active-unplayed",
                podcastID: activeFeedURL,
                podcastTitle: "Active Show",
                title: "Active Unplayed",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_003)
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "active-played",
                podcastID: activeFeedURL,
                podcastTitle: "Active Show",
                title: "Active Played",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_004)
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "archived-unplayed",
                podcastID: archivedFeedURL,
                podcastTitle: "Archived Show",
                title: "Archived Unplayed",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_005)
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "unsubscribed-unplayed",
                podcastID: unsubscribedFeedURL,
                podcastTitle: "Unsubscribed Show",
                title: "Unsubscribed Unplayed",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_006)
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "active-played",
                podcastID: activeFeedURL,
                position: 120,
                duration: 120,
                isPlayed: true
            )
        )
        try context.save()

        await store.load(modelContext: context)

        #expect(store.subscriptions.map(\.feedURL) == [activeFeedURL])
        #expect(store.episodes.map(\.episodeID).sorted() == ["active-played", "active-unplayed"])
        #expect(store.inboxEpisodes.map(\.episodeID) == ["active-played", "active-unplayed"])
    }

    @Test("Inbox cache keeps newest-first ordering")
    func inboxCacheKeepsNewestFirstOrdering() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/ordered-inbox.xml"

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Ordered Show"))
        context.insert(PodcastCacheRecord(feedURL: feedURL, title: "Ordered Show"))
        context.insert(
            EpisodeCacheRecord(
                episodeID: "older",
                podcastID: feedURL,
                podcastTitle: "Ordered Show",
                title: "Older",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "newer",
                podcastID: feedURL,
                podcastTitle: "Ordered Show",
                title: "Newer",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "zulu-undated",
                podcastID: feedURL,
                podcastTitle: "Ordered Show",
                title: "Zulu Undated"
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: "alpha-undated",
                podcastID: feedURL,
                podcastTitle: "Ordered Show",
                title: "Alpha Undated"
            )
        )
        try context.save()

        await store.load(modelContext: context)

        #expect(store.inboxEpisodes.map(\.episodeID) == [
            "newer",
            "older",
            "alpha-undated",
            "zulu-undated"
        ])
    }

    @Test("Position-only progress changes leave cached inbox episodes unchanged")
    func positionOnlyProgressChangesLeaveCachedInboxEpisodesUnchanged() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/inbox-progress.xml"
        let episodeID = "inbox-progress-episode"

        insertCachedFeed(feedURL: feedURL, title: "Inbox Progress", episodeID: episodeID, in: context)
        context.insert(
            EpisodeProgressRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                position: 10,
                duration: 100,
                isPlayed: false
            )
        )
        try context.save()
        await store.load(modelContext: context)

        let initialInboxEpisodes = store.inboxEpisodes
        let didSave = store.updateProgress(
            episodeID: episodeID,
            podcastID: feedURL,
            position: 11,
            duration: 100,
            modelContext: context
        )

        #expect(didSave)
        #expect(store.progressRecords.first { $0.episodeID == episodeID }?.position == 11)
        #expect(store.inboxEpisodes == initialInboxEpisodes)
    }

    @Test("Completing an episode leaves cached inbox episodes unchanged")
    func completingEpisodeLeavesCachedInboxEpisodesUnchanged() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let feedURL = "https://example.com/inbox-completed-progress.xml"
        let episodeID = "inbox-completed-progress-episode"

        insertCachedFeed(feedURL: feedURL, title: "Inbox Completed Progress", episodeID: episodeID, in: context)
        try context.save()
        await store.load(modelContext: context)

        let initialInboxEpisodes = store.inboxEpisodes
        let didSave = store.updateProgress(
            episodeID: episodeID,
            podcastID: feedURL,
            position: 120,
            duration: 120,
            modelContext: context
        )

        #expect(didSave)
        #expect(store.progressRecords.first { $0.episodeID == episodeID }?.isPlayed == true)
        #expect(store.inboxEpisodes == initialInboxEpisodes)
        #expect(store.progressSummary(for: store.inboxEpisodes[0]).isCompleted)
    }

    @Test("Unsubscribe leaves other feeds intact")
    func unsubscribeLeavesOtherFeedsIntact() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let removedFeedURL = "https://example.com/removed.xml"
        let keptFeedURL = "https://example.com/kept.xml"

        insertFeedRecords(feedURL: removedFeedURL, title: "Removed Show", episodeID: "removed-episode", in: context)
        insertFeedRecords(feedURL: keptFeedURL, title: "Kept Show", episodeID: "kept-episode", in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.unsubscribe(feedURL: removedFeedURL, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.feedURL) == [keptFeedURL])
        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).map(\.podcastID) == [keptFeedURL])
        #expect(Array(store.podcastCacheByFeedURL.keys) == [keptFeedURL])
        #expect(store.refreshLogs.map(\.feedURL) == [keptFeedURL])
        #expect(store.subscriptions.map(\.feedURL) == [keptFeedURL])
        #expect(store.episodes(forPodcastID: keptFeedURL).map(\.episodeID) == ["kept-episode"])
        #expect(store.episodes(forPodcastID: removedFeedURL).isEmpty)
    }

    @Test("Per-feed refresh touches only the targeted feed")
    func perFeedRefreshTouchesOnlyTargetedFeed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedA = "https://example.com/a.xml"
        let feedB = "https://example.com/b.xml"
        let service = StubFeedService(responses: [
            feedA: .success(
                makeSnapshot(
                    feedURL: feedA,
                    podcastTitle: "A Updated",
                    episodeID: "a-new",
                    episodeTitle: "A New Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(feedURL: feedA, title: "A Old", episodeID: "a-old", in: context)
        insertCachedFeed(feedURL: feedB, title: "B Old", episodeID: "b-old", in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedA, modelContext: context)

        let requestedURLs = await service.requestedURLStrings()
        #expect(requestedURLs == [feedA])
        #expect(store.subscriptions.first { $0.feedURL == feedA }?.title == "A Updated")
        #expect(store.subscriptions.first { $0.feedURL == feedB }?.title == "B Old")
        #expect(store.episodes(forPodcastID: feedA).map(\.episodeID).contains("a-new"))
        #expect(store.episodes(forPodcastID: feedB).map(\.episodeID) == ["b-old"])
        #expect(store.latestRefreshLog(feedURL: feedA)?.errorMessage == nil)
        #expect(store.latestRefreshLog(feedURL: feedB) == nil)
        #expect(store.refreshingFeedURLs.isEmpty)
    }

    @Test("Global refresh runs all active subscriptions and records a log per feed")
    func globalRefreshRunsActiveSubscriptionsAndRecordsLogs() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedA = "https://example.com/a.xml"
        let feedB = "https://example.com/b.xml"
        let archivedFeed = "https://example.com/archived.xml"
        let service = StubFeedService(responses: [
            feedA: .success(
                makeSnapshot(
                    feedURL: feedA,
                    podcastTitle: "A Updated",
                    episodeID: "a-new",
                    episodeTitle: "A New Episode"
                )
            ),
            feedB: .success(
                makeSnapshot(
                    feedURL: feedB,
                    podcastTitle: "B Updated",
                    episodeID: "b-new",
                    episodeTitle: "B New Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(feedURL: feedA, title: "A Old", episodeID: "a-old", in: context)
        insertCachedFeed(feedURL: feedB, title: "B Old", episodeID: "b-old", in: context)
        insertCachedFeed(feedURL: archivedFeed, title: "Archived", episodeID: "archived-old", isArchived: true, in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAll(modelContext: context)

        let requestedURLs = await service.requestedURLStrings()
        #expect(Set(requestedURLs) == [feedA, feedB])
        #expect(store.subscriptions.map(\.feedURL).contains(archivedFeed) == false)
        #expect(store.latestRefreshLog(feedURL: feedA)?.errorMessage == nil)
        #expect(store.latestRefreshLog(feedURL: feedB)?.errorMessage == nil)
        #expect(store.latestRefreshLog(feedURL: archivedFeed) == nil)
        #expect(store.refreshLogs.filter { $0.feedURL == feedA }.count == 1)
        #expect(store.refreshLogs.filter { $0.feedURL == feedB }.count == 1)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.state == .idle)
    }

    @Test("Global refresh starts independent feed requests concurrently")
    func globalRefreshStartsIndependentFeedRequestsConcurrently() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedA = "https://example.com/concurrent-a.xml"
        let feedB = "https://example.com/concurrent-b.xml"
        let service = StubFeedService(responses: [
            feedA: .delayedSuccess(
                makeSnapshot(
                    feedURL: feedA,
                    podcastTitle: "A Updated",
                    episodeID: "a-new",
                    episodeTitle: "A New Episode"
                ),
                nanoseconds: 250_000_000
            ),
            feedB: .delayedSuccess(
                makeSnapshot(
                    feedURL: feedB,
                    podcastTitle: "B Updated",
                    episodeID: "b-new",
                    episodeTitle: "B New Episode"
                ),
                nanoseconds: 250_000_000
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(feedURL: feedA, title: "A Old", episodeID: "a-old", in: context)
        insertCachedFeed(feedURL: feedB, title: "B Old", episodeID: "b-old", in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAll(modelContext: context)

        let maximumActiveRequestCount = await service.maximumActiveRequestCount()
        #expect(maximumActiveRequestCount == 2)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.state == .idle)
    }

    @Test("Automatic foreground refresh skips fresh subscriptions")
    func automaticForegroundRefreshSkipsFreshSubscriptions() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = "https://example.com/fresh.xml"
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Fresh Updated",
                    episodeID: "fresh-new",
                    episodeTitle: "Fresh New Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(
            feedURL: feedURL,
            title: "Fresh Old",
            episodeID: "fresh-old",
            lastRefreshAt: now.addingTimeInterval(-(LibraryStore.foregroundRefreshInterval - 1)),
            in: context
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAllIfStale(modelContext: context, now: now)

        let requestedURLs = await service.requestedURLStrings()
        #expect(requestedURLs.isEmpty)
        #expect(store.subscriptions.first?.title == "Fresh Old")
        #expect(store.state == .idle)
    }

    @Test("Automatic foreground refresh pulls only stale active subscriptions")
    func automaticForegroundRefreshPullsOnlyStaleActiveSubscriptions() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let staleFeed = "https://example.com/stale.xml"
        let freshFeed = "https://example.com/stale-companion.xml"
        let service = StubFeedService(responses: [
            staleFeed: .success(
                makeSnapshot(
                    feedURL: staleFeed,
                    podcastTitle: "Stale Updated",
                    episodeID: "stale-new",
                    episodeTitle: "Stale New Episode"
                )
            ),
            freshFeed: .success(
                makeSnapshot(
                    feedURL: freshFeed,
                    podcastTitle: "Companion Updated",
                    episodeID: "companion-new",
                    episodeTitle: "Companion New Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(
            feedURL: staleFeed,
            title: "Stale Old",
            episodeID: "stale-old",
            lastRefreshAt: now.addingTimeInterval(-LibraryStore.foregroundRefreshInterval),
            in: context
        )
        insertCachedFeed(
            feedURL: freshFeed,
            title: "Companion Old",
            episodeID: "companion-old",
            lastRefreshAt: now,
            in: context
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAllIfStale(modelContext: context, now: now)

        let requestedURLs = await service.requestedURLStrings()
        #expect(requestedURLs == [staleFeed])
        #expect(store.subscriptions.first { $0.feedURL == staleFeed }?.title == "Stale Updated")
        #expect(store.subscriptions.first { $0.feedURL == freshFeed }?.title == "Companion Old")
        #expect(store.state == .idle)
    }

    @Test("Automatic foreground refresh waits after recent failed attempts")
    func automaticForegroundRefreshWaitsAfterRecentFailedAttempts() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = "https://example.com/recent-failure.xml"
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Recent Failure Updated",
                    episodeID: "recent-failure-new",
                    episodeTitle: "Recent Failure New Episode"
                )
            )
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(
            feedURL: feedURL,
            title: "Recent Failure Old",
            episodeID: "recent-failure-old",
            lastRefreshAt: now.addingTimeInterval(-(LibraryStore.foregroundRefreshInterval * 3)),
            in: context
        )
        context.insert(
            RefreshLogRecord(
                feedURL: feedURL,
                startedAt: now.addingTimeInterval(-60),
                finishedAt: now.addingTimeInterval(-59),
                errorMessage: "Still too soon to retry"
            )
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAllIfStale(modelContext: context, now: now)

        let requestedURLs = await service.requestedURLStrings()
        #expect(requestedURLs.isEmpty)
        #expect(store.subscriptions.first?.title == "Recent Failure Old")
        #expect(store.state == .idle)
    }

    @Test("Global refresh records one feed failure and continues unaffected feeds")
    func globalRefreshRecordsFailureAndContinues() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedA = "https://example.com/a.xml"
        let feedB = "https://example.com/b.xml"
        let service = StubFeedService(responses: [
            feedA: .success(
                makeSnapshot(
                    feedURL: feedA,
                    podcastTitle: "A Updated",
                    episodeID: "a-new",
                    episodeTitle: "A New Episode"
                )
            ),
            feedB: .failure("Feed B is unavailable")
        ])
        let store = LibraryStore(feedService: service, localCache: SQLiteLocalLibraryCacheStore.inMemory())

        insertCachedFeed(feedURL: feedA, title: "A Old", episodeID: "a-old", in: context)
        insertCachedFeed(feedURL: feedB, title: "B Old", episodeID: "b-old", in: context)
        try context.save()
        await store.load(modelContext: context)

        await store.refreshAll(modelContext: context)

        let requestedURLs = await service.requestedURLStrings()
        #expect(Set(requestedURLs) == [feedA, feedB])
        #expect(store.subscriptions.first { $0.feedURL == feedA }?.title == "A Updated")
        #expect(store.subscriptions.first { $0.feedURL == feedB }?.title == "B Old")
        #expect(store.latestRefreshLog(feedURL: feedA)?.errorMessage == nil)
        #expect(store.latestRefreshLog(feedURL: feedB)?.errorMessage == "Feed B is unavailable")
        #expect(store.latestRefreshFailure?.feedURL == feedB)
        #expect(store.refreshingFeedURLs.isEmpty)
        #expect(store.state == .idle)
    }

    @Test("Refreshing feed URLs clear after success failure and cancellation")
    func refreshingFeedURLsClearAfterSuccessFailureAndCancellation() async throws {
        let successFeed = "https://example.com/success.xml"
        let successContainer = try OpenCastModelContainerFactory.make(inMemory: true)
        let successContext = ModelContext(successContainer)
        let successService = StubFeedService(responses: [
            successFeed: .success(
                makeSnapshot(
                    feedURL: successFeed,
                    podcastTitle: "Success Updated",
                    episodeID: "success-new",
                    episodeTitle: "Success New Episode"
                )
            )
        ])
        let successStore = LibraryStore(feedService: successService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        insertCachedFeed(feedURL: successFeed, title: "Success Old", episodeID: "success-old", in: successContext)
        try successContext.save()
        await successStore.load(modelContext: successContext)

        await successStore.refresh(feedURL: successFeed, modelContext: successContext)

        #expect(successStore.refreshingFeedURLs.isEmpty)
        #expect(successStore.state == .idle)

        let failureFeed = "https://example.com/failure.xml"
        let failureContainer = try OpenCastModelContainerFactory.make(inMemory: true)
        let failureContext = ModelContext(failureContainer)
        let failureService = StubFeedService(responses: [
            failureFeed: .failure("Refresh failed")
        ])
        let failureStore = LibraryStore(feedService: failureService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        insertCachedFeed(feedURL: failureFeed, title: "Failure Old", episodeID: "failure-old", in: failureContext)
        try failureContext.save()
        await failureStore.load(modelContext: failureContext)

        await failureStore.refresh(feedURL: failureFeed, modelContext: failureContext)

        #expect(failureStore.refreshingFeedURLs.isEmpty)
        #expect(failureStore.latestRefreshLog(feedURL: failureFeed)?.errorMessage == "Refresh failed")
        #expect(failureStore.state == .idle)

        let cancelledFeed = "https://example.com/cancelled.xml"
        let cancelledContainer = try OpenCastModelContainerFactory.make(inMemory: true)
        let cancelledContext = ModelContext(cancelledContainer)
        let cancelledService = StubFeedService(responses: [
            cancelledFeed: .delayedSuccess(
                makeSnapshot(
                    feedURL: cancelledFeed,
                    podcastTitle: "Cancelled Updated",
                    episodeID: "cancelled-new",
                    episodeTitle: "Cancelled New Episode"
                ),
                nanoseconds: 1_000_000_000
            )
        ])
        let cancelledStore = LibraryStore(feedService: cancelledService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        insertCachedFeed(feedURL: cancelledFeed, title: "Cancelled Old", episodeID: "cancelled-old", in: cancelledContext)
        try cancelledContext.save()
        await cancelledStore.load(modelContext: cancelledContext)

        let task = Task { @MainActor in
            await cancelledStore.refresh(feedURL: cancelledFeed, modelContext: cancelledContext)
        }
        #expect(await cancelledService.waitForRequestCount(1))
        #expect(cancelledStore.isRefreshing(feedURL: cancelledFeed))
        task.cancel()
        await task.value

        #expect(cancelledStore.refreshingFeedURLs.isEmpty)
        #expect(cancelledStore.refreshLogs.filter { $0.feedURL == cancelledFeed }.isEmpty)
        #expect(cancelledStore.state == .idle)
    }

    @Test("Refresh log retention caps to 50 per feed")
    func refreshLogRetentionCapsPerFeed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/retention.xml"
        let otherFeedURL = "https://example.com/other-retention.xml"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let service = StubFeedService(responses: [
            feedURL: .success(
                makeSnapshot(
                    feedURL: feedURL,
                    podcastTitle: "Retention Updated",
                    episodeID: "retention-new",
                    episodeTitle: "Retention New Episode"
                )
            )
        ])
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: service, localCache: localCache)

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Retention Old"))
        try context.save()
        let seededLogs = (0..<55).map { offset in
            RefreshLogSnapshot(
                refreshID: "old-\(offset)",
                feedURL: feedURL,
                startedAt: baseDate.addingTimeInterval(Double(offset)),
                finishedAt: baseDate.addingTimeInterval(Double(offset))
            )
        } + [
            RefreshLogSnapshot(
                refreshID: "other-0",
                feedURL: otherFeedURL,
                startedAt: baseDate,
                finishedAt: baseDate
            )
        ]
        try await localCache.importLegacyCache(podcasts: [], episodes: [], refreshLogs: seededLogs)
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)

        let logs = store.refreshLogs.filter { $0.feedURL == feedURL }
        let retainedOldOffsets = Set(
            logs.compactMap { log -> Int? in
                guard log.refreshID.hasPrefix("old-") else {
                    return nil
                }
                return Int(log.refreshID.replacingOccurrences(of: "old-", with: ""))
            }
        )
        let otherLogs = store.refreshLogs.filter { $0.feedURL == otherFeedURL }
        #expect(logs.count == LibraryStore.refreshLogRetentionLimit)
        #expect(retainedOldOffsets.contains(0) == false)
        #expect(retainedOldOffsets.contains(5) == false)
        #expect(retainedOldOffsets.contains(6))
        #expect(retainedOldOffsets.contains(54))
        #expect(otherLogs.count == 1)
    }

    @Test("Refreshing the same feed twice de-dupes rows and latest metadata wins")
    func refreshTwiceDeDupesRowsAndLatestMetadataWins() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/twice.xml"
        let episodeID = "twice-episode"
        let service = StubFeedService(responsesByURL: [
            feedURL: [
                .success(
                    makeSnapshot(
                        feedURL: feedURL,
                        podcastTitle: "Twice V1",
                        episodeID: episodeID,
                        episodeTitle: "Episode V1",
                        summary: "First summary",
                        duration: 30
                    )
                ),
                .success(
                    makeSnapshot(
                        feedURL: feedURL,
                        podcastTitle: "Twice V2",
                        episodeID: episodeID,
                        episodeTitle: "Episode V2",
                        summary: "Second summary",
                        duration: 45
                    )
                )
            ]
        ])
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: service, localCache: localCache)

        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Twice Old"
            )
        )
        try context.save()
        await store.load(modelContext: context)

        await store.refresh(feedURL: feedURL, modelContext: context)
        await store.refresh(feedURL: feedURL, modelContext: context)

        let cached = try await localCache.loadLibrary(activePodcastIDs: [feedURL])
        let episode = try #require(store.episode(with: episodeID))
        #expect(cached.episodes.count == 1)
        #expect(episode.title == "Episode V2")
        #expect(episode.summary == "Second summary")
        #expect(episode.duration == 45)
        #expect(store.subscriptions.first { $0.feedURL == feedURL }?.title == "Twice V2")
        #expect(cached.podcastsByFeedURL[feedURL]?.title == "Twice V2")
        #expect(store.podcastCache(for: feedURL)?.title == "Twice V2")
        #expect(store.refreshLogs.filter { $0.feedURL == feedURL }.count == 2)
    }

    @Test("Duplicate subscriptions merge metadata into one canonical row")
    func duplicateSubscriptionsMergeMetadata() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let oldRefresh = Date(timeIntervalSince1970: 1_700_000_000)
        let newRefresh = Date(timeIntervalSince1970: 1_700_000_100)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/feed.xml?b=2&a=1",
                title: "Detailed Show",
                author: "Detailed Host",
                artworkURL: "https://example.com/art.jpg",
                subscribedAt: oldRefresh,
                lastRefreshAt: oldRefresh
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: "HTTPS://EXAMPLE.com/feed.xml?a=1&b=2",
                title: " ",
                subscribedAt: newRefresh,
                lastRefreshAt: newRefresh,
                isVoiceBoostEnabled: false
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)
        let records = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.feedURL == "https://example.com/feed.xml?a=1&b=2")
        #expect(records.first?.title == "Detailed Show")
        #expect(records.first?.author == "Detailed Host")
        #expect(records.first?.artworkURL == "https://example.com/art.jpg")
        #expect(records.first?.lastRefreshAt == newRefresh)
        #expect(records.first?.isVoiceBoostEnabled == false)
        #expect(result.duplicateSubscriptionRecordsFound == 1)
        #expect(result.subscriptionGroupsMerged == 1)
        #expect(result.subscriptionRecordsDeleted == 1)
        #expect(store.subscriptions.map(\.feedURL) == ["https://example.com/feed.xml?a=1&b=2"])
    }

    @Test("Archived duplicate loses to active duplicate")
    func archivedDuplicateLosesToActiveDuplicate() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let activeRefresh = Date(timeIntervalSince1970: 1_700_000_000)
        let archivedRefresh = Date(timeIntervalSince1970: 1_700_000_100)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/archive.xml",
                title: "Active Show",
                lastRefreshAt: activeRefresh,
                isArchived: false
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/archive.xml/",
                title: "Archived Show",
                lastRefreshAt: archivedRefresh,
                isArchived: true
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)
        let records = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.feedURL == "https://example.com/archive.xml")
        #expect(records.first?.title == "Active Show")
        #expect(records.first?.isArchived == false)
        #expect(records.first?.lastRefreshAt == archivedRefresh)
        #expect(result.duplicateRecordsFound == 1)
        #expect(result.groupsMerged == 1)
        #expect(result.recordsDeleted == 1)
    }

    @Test("Duplicate progress rows merge according to played and latest rules")
    func duplicateProgressRowsMergeByPlayedAndLatestRules() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let oldUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let newUpdate = Date(timeIntervalSince1970: 1_700_000_100)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            EpisodeProgressRecord(
                episodeID: "played-episode",
                podcastID: "https://example.com/progress.xml",
                position: 180,
                duration: 200,
                isPlayed: true,
                updatedAt: oldUpdate
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "played-episode",
                podcastID: "HTTPS://EXAMPLE.com/progress.xml/",
                position: 60,
                duration: 300,
                isPlayed: false,
                updatedAt: newUpdate
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "latest-episode",
                podcastID: "https://example.com/progress.xml",
                position: 10,
                duration: 90,
                isPlayed: false,
                updatedAt: oldUpdate
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "latest-episode",
                podcastID: "https://example.com/progress.xml",
                position: 50,
                duration: 80,
                isPlayed: false,
                updatedAt: newUpdate
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)
        let records = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        let playedRecord = records.first { $0.episodeID == "played-episode" }
        let latestRecord = records.first { $0.episodeID == "latest-episode" }

        #expect(records.count == 2)
        #expect(playedRecord?.podcastID == "https://example.com/progress.xml")
        #expect(playedRecord?.position == 180)
        #expect(playedRecord?.duration == 300)
        #expect(playedRecord?.isPlayed == true)
        #expect(playedRecord?.updatedAt == oldUpdate)
        #expect(latestRecord?.position == 50)
        #expect(latestRecord?.duration == 90)
        #expect(latestRecord?.isPlayed == false)
        #expect(latestRecord?.updatedAt == newUpdate)
        #expect(result.duplicateProgressRecordsFound == 2)
        #expect(result.progressGroupsMerged == 2)
        #expect(result.progressRecordsDeleted == 2)
    }

    @Test("Progress repair keeps delimiter-like logical keys distinct")
    func progressRepairKeepsDelimiterLikeKeysDistinct() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let update = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            EpisodeProgressRecord(
                episodeID: "episode|one",
                podcastID: "feed",
                position: 10,
                updatedAt: update
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "one",
                podcastID: "feed|episode",
                position: 20,
                updatedAt: update.addingTimeInterval(10)
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)
        let records = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())

        #expect(result.duplicateProgressRecordsFound == 0)
        #expect(result.progressGroupsMerged == 0)
        #expect(result.progressRecordsDeleted == 0)
        #expect(records.count == 2)
    }

    @Test("Repair leaves unrelated records untouched")
    func repairLeavesUnrelatedRecordsUntouched() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let update = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/one.xml",
                title: "One",
                lastRefreshAt: update
            )
        )
        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/two.xml",
                title: "Two",
                lastRefreshAt: update
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "episode-one",
                podcastID: "https://example.com/one.xml",
                position: 10,
                duration: 100,
                updatedAt: update
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "episode-two",
                podcastID: "https://example.com/two.xml",
                position: 20,
                duration: 200,
                updatedAt: update
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
            .sorted { $0.feedURL < $1.feedURL }
        let progressRecords = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
            .sorted { $0.episodeID < $1.episodeID }

        #expect(result.hasIssues == false)
        #expect(result.duplicateRecordsFound == 0)
        #expect(result.groupsMerged == 0)
        #expect(result.recordsDeleted == 0)
        #expect(subscriptions.map(\.feedURL) == ["https://example.com/one.xml", "https://example.com/two.xml"])
        #expect(subscriptions.map(\.title) == ["One", "Two"])
        #expect(progressRecords.map(\.episodeID) == ["episode-one", "episode-two"])
        #expect(progressRecords.map(\.position) == [10, 20])
    }

    @Test("Repair result counts duplicate groups and deleted rows")
    func repairResultCountsDuplicateGroupsAndDeletedRows() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let update = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        context.insert(SubscriptionRecord(feedURL: "https://example.com/count.xml", title: "Count", lastRefreshAt: update))
        context.insert(SubscriptionRecord(feedURL: "https://example.com/count.xml/", title: "Count Copy", lastRefreshAt: update))
        context.insert(SubscriptionRecord(feedURL: "HTTPS://EXAMPLE.com/count.xml", title: "Count Copy 2", lastRefreshAt: update))
        context.insert(
            EpisodeProgressRecord(
                episodeID: "count-episode",
                podcastID: "https://example.com/count.xml",
                position: 10,
                updatedAt: update
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: "count-episode",
                podcastID: "https://example.com/count.xml/",
                position: 20,
                updatedAt: update.addingTimeInterval(10)
            )
        )
        try context.save()

        let result = try await store.repairSyncDuplicates(modelContext: context)

        #expect(result.duplicateSubscriptionRecordsFound == 2)
        #expect(result.subscriptionGroupsMerged == 1)
        #expect(result.subscriptionRecordsDeleted == 2)
        #expect(result.duplicateProgressRecordsFound == 1)
        #expect(result.progressGroupsMerged == 1)
        #expect(result.progressRecordsDeleted == 1)
        #expect(result.duplicateRecordsFound == 3)
        #expect(result.groupsMerged == 2)
        #expect(result.recordsDeleted == 3)
    }

    @Test("Sync status store uses account status provider")
    func syncStatusStoreUsesAccountStatusProvider() async {
        let availableStore = SyncStatusStore(
            accountStatusProvider: StubCloudKitAccountStatusProvider(status: .available)
        )
        let errorStore = SyncStatusStore(
            accountStatusProvider: StubCloudKitAccountStatusProvider(error: StubFeedError(message: "CloudKit offline"))
        )

        await availableStore.refreshAccountStatus()
        await errorStore.refreshAccountStatus()

        #expect(availableStore.accountStatus == .available)
        #expect(errorStore.accountStatus == .temporarilyUnavailable("CloudKit offline"))
    }

    @Test("Sync status store skips recent account status refreshes")
    func syncStatusStoreSkipsRecentAccountStatusRefreshes() async {
        let provider = CountingCloudKitAccountStatusProvider(statuses: [.available, .noAccount])
        let store = SyncStatusStore(
            accountStatusProvider: provider,
            now: { Date(timeIntervalSinceReferenceDate: 0) }
        )

        await store.refreshAccountStatus()
        await store.refreshAccountStatus()

        let callCount = await provider.callCount
        #expect(callCount == 1)
        #expect(store.accountStatus == .available)
    }

    @Test("Legacy cache rows import once into SQLite")
    func legacyCacheRowsImportOnceIntoSQLite() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(localCache: localCache)
        let feedURL = "https://example.com/legacy-import.xml"

        insertFeedRecords(feedURL: feedURL, title: "Legacy Import", episodeID: "legacy-import-episode", in: context)
        try context.save()

        await store.load(modelContext: context)

        #expect(store.episodes.map(\.episodeID) == ["legacy-import-episode"])
        #expect(store.podcastCacheByFeedURL[feedURL]?.title == "Legacy Import")
        #expect(store.refreshLogs.map(\.feedURL) == [feedURL])
        #expect(try context.fetch(FetchDescriptor<PodcastCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<EpisodeCacheRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RefreshLogRecord>()).isEmpty)
        #expect(try await localCache.hasCompletedLegacyImport())
    }

    @Test("Failed legacy import keeps SwiftData rows and retries")
    func failedLegacyImportKeepsSwiftDataRowsAndRetries() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: FailingImportCacheStore())
        let feedURL = "https://example.com/legacy-import-failure.xml"

        insertFeedRecords(feedURL: feedURL, title: "Legacy Import Failure", episodeID: "legacy-import-failure-episode", in: context)
        try context.save()

        await store.load(modelContext: context)

        #expect(try context.fetch(FetchDescriptor<PodcastCacheRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<EpisodeCacheRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<RefreshLogRecord>()).count == 1)
        #expect(store.lastErrorMessage != nil)
    }

    private func insertCachedFeed(
        feedURL: String,
        title: String,
        episodeID: String,
        lastRefreshAt: Date = .now,
        isArchived: Bool = false,
        artworkURL: URL? = nil,
        artworkPreview: ArtworkPreview? = nil,
        in context: ModelContext
    ) {
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: title,
                artworkURL: artworkURL?.absoluteString,
                lastRefreshAt: lastRefreshAt,
                isArchived: isArchived
            )
        )
        let podcast = PodcastCacheRecord(
            feedURL: feedURL,
            title: title,
            artworkURL: artworkURL?.absoluteString,
            updatedAt: Date()
        )
        if let artworkPreview {
            podcast.storeArtworkPreviewIfChanged(artworkPreview)
        }
        context.insert(podcast)

        let episode = EpisodeCacheRecord(
            episodeID: episodeID,
            podcastID: feedURL,
            podcastTitle: title,
            title: "Episode for \(title)",
            publishedAt: Date(),
            duration: 120,
            audioURL: "https://example.com/\(episodeID).mp3",
            artworkURL: artworkURL?.absoluteString
        )
        if let artworkPreview {
            episode.storeArtworkPreviewIfChanged(artworkPreview)
        }
        context.insert(episode)
    }

    private func makeEpisodeListItem(
        episodeID: String,
        podcastID: String,
        podcastTitle: String,
        title: String,
        duration: TimeInterval?,
        audioURL: String?
    ) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: podcastID,
            podcastTitle: podcastTitle,
            title: title,
            summary: nil,
            publishedAt: nil,
            duration: duration,
            audioURL: audioURL,
            artworkURL: nil,
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }

    private func makePreview(
        artworkURL: URL,
        sourceHash: String = "preview-source"
    ) throws -> ArtworkPreview {
        let rgbData = Data((0..<(8 * 8)).flatMap { _ in [UInt8(240), 44, 32] })
        return try #require(ArtworkPreview(
            version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: ArtworkPreview.canonicalArtworkURLKey(for: artworkURL.absoluteString) ?? "",
            sourceHash: sourceHash,
            pixelWidth: 8,
            pixelHeight: 8,
            rgbData: rgbData
        ))
    }

    private func makeSnapshot(
        feedURL: String,
        podcastTitle: String,
        episodeID: String,
        episodeTitle: String,
        summary: String? = nil,
        duration: TimeInterval = 120,
        artworkURL: URL? = nil
    ) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: podcastTitle,
                author: "\(podcastTitle) Author",
                summary: "\(podcastTitle) Summary",
                artworkURL: artworkURL
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: episodeTitle,
                    summary: summary,
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: duration,
                    audioURL: URL(string: "https://example.com/\(episodeID).mp3"),
                    artworkURL: artworkURL,
                    guid: episodeID
                )
            ]
        )
    }

    private func insertFeedRecords(
        feedURL: String,
        title: String,
        episodeID: String,
        in context: ModelContext
    ) {
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: title,
                lastRefreshAt: Date()
            )
        )
        context.insert(
            PodcastCacheRecord(
                feedURL: feedURL,
                title: title,
                updatedAt: Date()
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                podcastTitle: title,
                title: "Episode for \(title)",
                publishedAt: Date(),
                duration: 120,
                audioURL: "https://example.com/\(episodeID).mp3"
            )
        )
        context.insert(
            EpisodeProgressRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                position: 30,
                duration: 120
            )
        )
        context.insert(
            RefreshLogRecord(
                feedURL: feedURL,
                finishedAt: Date()
            )
        )
    }
}

private actor StubFeedService: FeedService {
    enum Response: Sendable {
        case success(FeedSnapshot)
        case failure(String)
        case delayedSuccess(FeedSnapshot, nanoseconds: UInt64)
    }

    private var responsesByURL: [String: [Response]]
    private var requestedURLs: [String] = []
    private var activeRequestCount = 0
    private var peakActiveRequestCount = 0

    init(responses: [String: Response]) {
        responsesByURL = responses.mapValues { [$0] }
    }

    init(responsesByURL: [String: [Response]]) {
        self.responsesByURL = responsesByURL
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        requestedURLs.append(key)
        activeRequestCount += 1
        peakActiveRequestCount = max(peakActiveRequestCount, activeRequestCount)
        defer {
            activeRequestCount -= 1
        }

        guard var responses = responsesByURL[key],
              !responses.isEmpty
        else {
            throw StubFeedError(message: "No stub response for \(key)")
        }

        let response = responses.removeFirst()
        responsesByURL[key] = responses

        switch response {
        case .success(let snapshot):
            return snapshot
        case .failure(let message):
            throw StubFeedError(message: message)
        case .delayedSuccess(let snapshot, let nanoseconds):
            try await Task.sleep(for: .seconds(Double(nanoseconds) / 1_000_000_000))
            return snapshot
        }
    }

    func requestedURLStrings() -> [String] {
        requestedURLs
    }

    func maximumActiveRequestCount() -> Int {
        peakActiveRequestCount
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        for _ in 0..<1_000 {
            if requestedURLs.count >= count {
                return true
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return requestedURLs.count >= count
    }
}

private struct FailingImportCacheStore: LocalLibraryCacheStore {
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        .empty
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        nil
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        [:]
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {}

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {}

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {}

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {}

    func deleteCache(forPodcastID podcastID: String) async throws {}

    func deleteAllLocalCache() async throws {}

    func hasCompletedLegacyImport() async throws -> Bool {
        false
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        throw StubFeedError(message: "Legacy import failed")
    }
}

private struct FailingUpsertCacheStore: LocalLibraryCacheStore {
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        .empty
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        nil
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        [:]
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        throw StubFeedError(message: "Local cache upsert failed")
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {}

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {}

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {}

    func deleteCache(forPodcastID podcastID: String) async throws {}

    func deleteAllLocalCache() async throws {}

    func hasCompletedLegacyImport() async throws -> Bool {
        true
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {}
}

private struct StubCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    let status: SyncAccountStatus?
    let error: StubFeedError?

    init(status: SyncAccountStatus) {
        self.status = status
        error = nil
    }

    init(error: StubFeedError) {
        status = nil
        self.error = error
    }

    func accountStatus() async throws -> SyncAccountStatus {
        if let error {
            throw error
        }

        return status ?? .couldNotDetermine
    }
}

private actor CountingCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    private var statuses: [SyncAccountStatus]
    private(set) var callCount = 0

    init(statuses: [SyncAccountStatus]) {
        self.statuses = statuses
    }

    func accountStatus() async throws -> SyncAccountStatus {
        callCount += 1
        guard !statuses.isEmpty else {
            return .couldNotDetermine
        }

        return statuses.removeFirst()
    }
}

private struct StubFeedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
