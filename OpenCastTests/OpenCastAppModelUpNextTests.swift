import Foundation
import OpenCastCore
@testable import OpenCastPlayback
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("App model Up Next")
struct OpenCastAppModelUpNextTests {
    private static let podcastID = "https://example.com/up-next.xml"

    @Test("Queue advance marks the finished episode before loading the queue head")
    func advanceFlushesFinishedProgressBeforeLoadingNext() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.playback.seek(to: 60)
        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(fixture.appModel.library.progressRecord(for: "first")?.isPlayed == true)
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.nowPlayingPresentationRequest == 0)
        #expect(flushCount == 1)
    }

    @Test("Advance skips an unresolvable queue head")
    func staleHeadIsSkipped() async throws {
        let fixture = try await makeFixture()
        let missing = episodeSnapshot(id: "missing", podcastID: Self.podcastID)
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(missing, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.lastPlaybackError == nil)
        #expect(fixture.appModel.lastUpNextError == nil)
        #expect(flushCount == 1)
    }

    @Test("Advance skips a missing-audio head when a later episode can play")
    func missingAudioHeadIsSkipped() async throws {
        let fixture = try await makeFixture()
        let missingAudio = try #require(fixture.appModel.episodeSnapshot(for: "missing-audio"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(missingAudio, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.lastPlaybackError == nil)
        #expect(fixture.appModel.lastUpNextError == nil)
        #expect(flushCount == 1)
    }

    @Test("Advance presents the best playback error after exhausting candidates")
    func allCandidatesUnplayable() async throws {
        let fixture = try await makeFixture()
        let stale = episodeSnapshot(id: "stale", podcastID: Self.podcastID)
        let missingAudio = try #require(fixture.appModel.episodeSnapshot(for: "missing-audio"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(stale, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.enqueueLast(missingAudio, modelContext: fixture.context))
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.lastPlaybackError == "This episode does not include an audio file.")
        #expect(fixture.appModel.lastUpNextError == nil)
        #expect(flushCount == 1)
    }

    @Test("A dequeue persistence failure stops advance and retains the queue")
    func dequeuePersistenceFailure() async throws {
        let fixture = try await makeFixture(
            upNextQueue: UpNextQueueStore { _ in throw AppModelQueueSaveFailure() },
            queuedEpisodeID: "first"
        )
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["first"])
        #expect(fixture.appModel.lastUpNextError?.contains("Unable to advance Up Next") == true)
        #expect(fixture.appModel.lastPlaybackError == nil)
        #expect(flushCount == 1)
        #expect(
            try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).map(\.episodeID)
                == ["first"]
        )
    }

    @Test("A failed library load preserves persisted queue IDs in memory")
    func failedLibraryLoadPreservesQueue() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: Self.podcastID, title: "Queue Show"))
        context.insert(
            UpNextQueueItemRecord(
                episodeID: "persisted",
                podcastID: Self.podcastID,
                sequence: 0
            )
        )
        try context.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: LoadFailingCacheStore(),
            allowsAutomaticFeedRefresh: false
        )

        await appModel.ensureCoreStoresLoaded(modelContext: context)

        #expect(appModel.library.state == .failed("Simulated library load failure"))
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["persisted"])
        let freshContext = ModelContext(container)
        #expect(
            try freshContext.fetch(FetchDescriptor<UpNextQueueItemRecord>()).map(\.episodeID)
                == ["persisted"]
        )
    }

    @Test("Playing a queued episode now dequeues it")
    func playNowDequeues() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(first, modelContext: fixture.context))

        try playWithoutAutoplay(first, fixture: fixture)

        #expect(!fixture.appModel.upNextQueue.contains(episodeID: "first"))
        #expect(try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).isEmpty)
    }

    @Test("Mark Played dequeues the episode")
    func markPlayedDequeues() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(first, modelContext: fixture.context))

        #expect(fixture.appModel.markEpisodePlayed(first, modelContext: fixture.context))

        #expect(!fixture.appModel.upNextQueue.contains(episodeID: "first"))
    }

    @Test("An empty queue leaves a naturally completed episode parked")
    func emptyQueueParksAtEnd() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.playback.seek(to: 60)
        fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.playback.state == .paused)
        #expect(fixture.appModel.playback.position == 60)
        #expect(fixture.appModel.lastPlaybackError == nil)
        #expect(fixture.appModel.lastUpNextError == nil)
        #expect(flushCount == 1)
    }

    @Test("Ordinary starts honor the show intro while transcript timestamps remain exact")
    func ordinaryAndTranscriptStartPositions() async throws {
        let fixture = try await makeFixture(skipIntroSeconds: 15)
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))

        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.playback.position == 15)

        try fixture.appModel.playEpisode(
            first,
            at: 5,
            matchingSourceSHA256: "no-matching-download",
            presentsNowPlaying: false,
            autoplay: false,
            modelContext: fixture.context
        )
        #expect(fixture.appModel.playback.position == 5)
    }

    @Test("Outro completion persists played progress and advances Up Next")
    func outroCompletionAdvancesQueueAndPersistsPlayedProgress() async throws {
        let fixture = try await makeFixture(skipIntroSeconds: 5, skipOutroSeconds: 10)
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        fixture.appModel.isNowPlayingPresented = true

        fixture.appModel.playback.handleObservedPlaybackPosition(5, duration: 60)
        fixture.appModel.playback.handleObservedPlaybackPosition(49, duration: 60)
        fixture.appModel.playback.handleObservedPlaybackPosition(50, duration: 60)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(fixture.appModel.playback.position == 5)
        #expect(fixture.appModel.library.progressRecord(for: "first")?.position == 60)
        #expect(fixture.appModel.library.progressRecord(for: "first")?.isPlayed == true)
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(fixture.appModel.isNowPlayingPresented)
    }

    @Test("Compact outro completion with an empty queue unloads playback")
    func compactOutroCompletionWithEmptyQueueUnloadsPlayback() async throws {
        let fixture = try await makeFixture(skipOutroSeconds: 10)
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.playback.handleObservedPlaybackPosition(49, duration: 60)
        fixture.appModel.playback.handleObservedPlaybackPosition(50, duration: 60)

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.playback.state == .idle)
        #expect(fixture.appModel.playback.position == 0)
        #expect(fixture.appModel.library.progressRecord(for: "first")?.isPlayed == true)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(!fixture.appModel.isNowPlayingPresented)
        #expect(!fixture.appModel.playback.isAudioSessionActive)
        #expect(flushCount == 1)
        await fixture.appModel.deferredPlaybackTeardownTask?.value
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context).isEmpty)
    }

    @Test("Expanded completion unloads playback and retains a static presentation")
    func expandedCompletionRetainsFinishedPresentation() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.isNowPlayingPresented = true

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.playback.state == .idle)
        #expect(fixture.appModel.finishedPlaybackPresentation?.episode.episodeID == "first")
        #expect(fixture.appModel.isNowPlayingPresented)
        await fixture.appModel.deferredPlaybackTeardownTask?.value
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context).isEmpty)

        fixture.appModel.isSceneActive = false

        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(!fixture.appModel.isNowPlayingPresented)
    }

    @Test("Now Playing content tracks live, Finished, and empty states")
    func nowPlayingPresentationContentStates() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))

        #expect(!fixture.appModel.hasNowPlayingPresentationContent)

        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.hasNowPlayingPresentationContent)

        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()
        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation != nil)
        #expect(fixture.appModel.hasNowPlayingPresentationContent)

        fixture.appModel.dismissNowPlayingAndDiscardFinishedPlayback()
        #expect(!fixture.appModel.hasNowPlayingPresentationContent)
        #expect(!fixture.appModel.isNowPlayingPresented)
    }

    @Test("Background completion unloads without retaining a presentation")
    func backgroundCompletionDoesNotRetainFinishedPresentation() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.isSceneActive = false

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(!fixture.appModel.isNowPlayingPresented)
        await fixture.appModel.deferredPlaybackTeardownTask?.value
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context).isEmpty)
    }

    @Test("Unplayable Up Next candidates preserve the error and show the expanded completion")
    func unplayableQueueClearsPlaybackAndPreservesError() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let missingAudio = try #require(fixture.appModel.episodeSnapshot(for: "missing-audio"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(missingAudio, modelContext: fixture.context))
        fixture.appModel.isNowPlayingPresented = true
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.lastPlaybackError == "This episode does not include an audio file.")
        #expect(fixture.appModel.lastUpNextError == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation?.episode.episodeID == "first")
        #expect(fixture.appModel.isNowPlayingPresented)
        #expect(flushCount == 1)
    }

    @Test("A dequeue persistence failure clears finished playback and preserves the Up Next error")
    func completionDequeuePersistenceFailureClearsPlayback() async throws {
        let fixture = try await makeFixture(
            upNextQueue: UpNextQueueStore { _ in throw AppModelQueueSaveFailure() },
            queuedEpisodeID: "second"
        )
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        var flushCount = 0
        fixture.appModel.playbackProgressFlushObserver = { flushCount += 1 }

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["second"])
        #expect(fixture.appModel.lastUpNextError?.contains("Unable to advance Up Next") == true)
        #expect(fixture.appModel.lastPlaybackError == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(flushCount == 1)
        await fixture.appModel.deferredPlaybackTeardownTask?.value
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context).isEmpty)
    }

    @Test("End of Episode sleep timer stops without advancing Up Next")
    func endOfEpisodeSleepTimerStopsWithoutAdvancing() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        fixture.appModel.playback.setSleepTimer(mode: .endOfEpisode)

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["second"])
        #expect(fixture.appModel.playback.sleepTimerMode == .off)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
    }

    @Test("Replay uses the configured intro and Done discards the static presentation")
    func replayUsesConfiguredIntroAndDoneDiscardsPresentation() async throws {
        let fixture = try await makeFixture(skipIntroSeconds: 15)
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(fixture.appModel.replayFinishedPlayback(modelContext: fixture.context))
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.playback.position == 15)
        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(fixture.appModel.isNowPlayingPresented)

        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()
        #expect(fixture.appModel.finishedPlaybackPresentation != nil)
        fixture.appModel.dismissNowPlayingAndDiscardFinishedPlayback()

        #expect(fixture.appModel.finishedPlaybackPresentation == nil)
        #expect(!fixture.appModel.isNowPlayingPresented)
    }

    @Test("Deferred teardown bookkeeping keeps the restore key of a Replay started before it runs")
    func deferredTeardownKeepsReplayRestoreKey() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()
        #expect(fixture.appModel.deferredPlaybackTeardownTask != nil)

        #expect(fixture.appModel.replayFinishedPlayback(modelContext: fixture.context))
        await fixture.appModel.deferredPlaybackTeardownTask?.value

        #expect(fixture.appModel.deferredPlaybackTeardownTask == nil)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context) == ["first"])
    }

    @Test("Replay failure retains the Finished presentation and playback error surface")
    func replayFailureRetainsFinishedPresentation() async throws {
        let fixture = try await makeFixture()
        let librarySnapshot = try #require(fixture.appModel.episodeSnapshot(for: "missing-audio"))
        let playableEpisode = Episode(
            id: EpisodeID(rawValue: librarySnapshot.episodeID),
            podcastID: PodcastID(rawValue: librarySnapshot.podcastID),
            podcastTitle: librarySnapshot.podcastTitle,
            title: librarySnapshot.title,
            duration: librarySnapshot.duration,
            audioURL: URL(string: "https://example.com/replay-fixture.mp3")
        )
        try fixture.appModel.playback.load(playableEpisode)
        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()

        #expect(!fixture.appModel.replayFinishedPlayback(modelContext: fixture.context))

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation?.episode.episodeID == "missing-audio")
        #expect(fixture.appModel.isNowPlayingPresented)
        #expect(fixture.appModel.lastPlaybackError == "This episode does not include an audio file.")
    }

    @Test("Unsubscribing purges that show's queued episodes")
    func unsubscribePurgesQueue() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        #expect(fixture.appModel.upNextQueue.enqueueLast(first, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))

        let outcome = await fixture.appModel.unsubscribe(
            feedURL: Self.podcastID,
            modelContext: fixture.context
        )

        #expect(outcome == .removed(warning: nil))
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
    }

    private func makeFixture(
        skipIntroSeconds: TimeInterval = 0,
        skipOutroSeconds: TimeInterval = 0,
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        queuedEpisodeID: String? = nil
    ) async throws -> (
        appModel: OpenCastAppModel,
        context: ModelContext
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: feedSnapshot(), refreshedAt: .now)
        context.insert(
            SubscriptionRecord(
                feedURL: Self.podcastID,
                title: "Queue Show",
                skipIntroSeconds: skipIntroSeconds,
                skipOutroSeconds: skipOutroSeconds
            )
        )
        if let queuedEpisodeID {
            context.insert(
                UpNextQueueItemRecord(
                    episodeID: queuedEpisodeID,
                    podcastID: Self.podcastID,
                    sequence: 0
                )
            )
        }
        try context.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: cache,
            upNextQueue: upNextQueue,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context)
    }

    private func lastPlaybackEpisodeIDs(in context: ModelContext) throws -> [String] {
        try context.fetch(
            FetchDescriptor<LocalPreferenceRecord>(
                predicate: #Predicate { record in
                    record.key == "playback.lastEpisodeID"
                }
            )
        ).map(\.value)
    }

    private func feedSnapshot() throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: Self.podcastID))
        let podcast = Podcast(
            id: PodcastID(rawValue: Self.podcastID),
            feedURL: feedURL,
            title: "Queue Show"
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: ["first", "second", "third", "missing-audio"].map { id in
                Episode(
                    id: EpisodeID(rawValue: id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(id)",
                    duration: 60,
                    audioURL: id == "missing-audio"
                        ? nil
                        : URL(string: "https://example.com/\(id).mp3"),
                    guid: id
                )
            }
        )
    }

    private func playWithoutAutoplay(
        _ episode: EpisodeListItemSnapshot,
        fixture: (appModel: OpenCastAppModel, context: ModelContext)
    ) throws {
        try fixture.appModel.playEpisode(
            episode,
            at: nil,
            matchingSourceSHA256: "no-matching-download",
            presentsNowPlaying: false,
            autoplay: false,
            modelContext: fixture.context
        )
    }

    private func episodeSnapshot(id: String, podcastID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: id,
            podcastID: podcastID,
            duration: 60,
            audioURL: "https://example.com/\(id).mp3",
            guid: id
        )
    }
}

private struct AppModelQueueSaveFailure: LocalizedError {
    var errorDescription: String? { "Simulated queue save failure" }
}

private struct LoadFailingCacheStore: LocalLibraryCacheStore {
    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        throw AppModelLibraryLoadFailure()
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] { [] }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? { nil }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] { [:] }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {}

    func updateEpisodeArtworkPreview(
        _ preview: ArtworkPreview,
        episodeID: String,
        artworkURL: String?
    ) async throws {}

    func updatePodcastArtworkPreview(
        _ preview: ArtworkPreview,
        feedURL: String,
        artworkURL: String?
    ) async throws {}

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {}

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? { nil }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {}

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] { [] }

    func deleteEpisodes(episodeIDs: [String]) async throws {}

    func deleteCache(forPodcastID podcastID: String) async throws {}

    func deleteAllLocalCache() async throws {}

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {}

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] { [:] }

    func hasCompletedLegacyImport() async throws -> Bool { true }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {}
}

private struct AppModelLibraryLoadFailure: LocalizedError {
    var errorDescription: String? { "Simulated library load failure" }
}
