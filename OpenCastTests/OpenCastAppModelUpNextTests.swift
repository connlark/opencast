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

    @Test("Starting another episode leaves the interrupted one out of Up Next by default")
    func startingAnotherEpisodeDoesNotRequeueByDefault() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let third = try #require(fixture.appModel.episodeSnapshot(for: "third"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.playback.seek(to: 10)

        try playWithoutAutoplay(third, fixture: fixture)

        #expect(fixture.appModel.playbackSettings.isRequeueInterruptedEpisodeEnabled == false)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(fixture.appModel.library.progressRecord(for: "first")?.position == 10)
    }

    @Test("With the setting on, starting another episode puts the interrupted one at the head of Up Next")
    func startingAnotherEpisodeRequeuesTheInterruptedOne() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setRequeueInterruptedEpisodeEnabled(true, modelContext: fixture.context))
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        let third = try #require(fixture.appModel.episodeSnapshot(for: "third"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        fixture.appModel.playback.seek(to: 10)

        try playWithoutAutoplay(third, fixture: fixture)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["first", "second"])
        #expect(fixture.appModel.library.progressRecord(for: "first")?.position == 10)
        #expect(fixture.appModel.lastUpNextError == nil)
    }

    @Test("Starting a queued episode moves it out of Up Next and the interrupted one in")
    func startingAQueuedEpisodeSwapsWithTheInterruptedOne() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setRequeueInterruptedEpisodeEnabled(true, modelContext: fixture.context))
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        let third = try #require(fixture.appModel.episodeSnapshot(for: "third"))
        try playWithoutAutoplay(first, fixture: fixture)
        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.enqueueLast(third, modelContext: fixture.context))

        try playWithoutAutoplay(third, fixture: fixture)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["first", "second"])
    }

    @Test("Restarting the playing episode leaves Up Next alone")
    func restartingThePlayingEpisodeDoesNotRequeueIt() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setRequeueInterruptedEpisodeEnabled(true, modelContext: fixture.context))
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.playback.seek(to: 10)

        try playWithoutAutoplay(first, fixture: fixture)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
    }

    @Test("A finished episode is not requeued when the next one starts")
    func finishedEpisodeIsNotRequeued() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setRequeueInterruptedEpisodeEnabled(true, modelContext: fixture.context))
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.playback.seek(to: 60)

        try playWithoutAutoplay(second, fixture: fixture)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(fixture.appModel.library.progressRecord(for: "first")?.isPlayed == true)
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
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

    @Test("Show-notes timestamps start exactly, bypassing the intro floor")
    func showNotesTimestampStartPosition() async throws {
        let fixture = try await makeFixture(skipIntroSeconds: 15)
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))

        try fixture.appModel.playEpisode(first, at: 5, presentsNowPlaying: false, modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.playback.position == 5)
        #expect(fixture.appModel.nowPlayingPresentationRequest == 0)
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

    @Test("Unsubscribing deletes the show's Auto Add to Up Next watermark row")
    func unsubscribeRemovesUpNextAutoAddWatermark() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setUpNextAutoAddPosition(.bottom, forPodcastID: Self.podcastID, modelContext: fixture.context))
        #expect(fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) != nil)
        #expect(try watermarkRows(forPodcastID: Self.podcastID, in: fixture.context).count == 1)

        let outcome = await fixture.appModel.unsubscribe(
            feedURL: Self.podcastID,
            modelContext: fixture.context
        )

        #expect(outcome == .removed(warning: nil))
        #expect(fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == nil)
        #expect(try watermarkRows(forPodcastID: Self.podcastID, in: fixture.context).isEmpty)
        #expect(fixture.appModel.library.upNextAutoAddPodcastIDs.isEmpty)
    }

    @Test("A data nuke reloads an empty Auto Add to Up Next store")
    func nukeReloadsEmptyUpNextAutoAddSettings() async throws {
        // The nuke refuses to run without an iCloud account.
        let fixture = try await makeFixture(
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableCloudKitAccountStatusProvider())
        )
        #expect(fixture.appModel.setUpNextAutoAddPosition(.top, forPodcastID: Self.podcastID, modelContext: fixture.context))
        #expect(fixture.appModel.setUpNextAutoAddLimit(.ten, modelContext: fixture.context))
        #expect(fixture.appModel.setUpNextAutoAddLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.appModel.upNextAutoAddSettings.limit == .ten)
        #expect(fixture.appModel.upNextAutoAddSettings.limitReachedAction == .addToTopOnly)

        try await fixture.appModel.nukeAllData(modelContext: fixture.context)

        #expect(fixture.appModel.upNextAutoAddSettings.limit == .standard)
        #expect(fixture.appModel.upNextAutoAddSettings.limitReachedAction == .stopAdding)
        #expect(fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == nil)
        #expect(fixture.appModel.upNextAutoAddSettings.lastErrorMessage == nil)
        #expect(fixture.appModel.library.upNextAutoAddPodcastIDs.isEmpty)
        let upNextRows = try fixture.context.fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key.hasPrefix("upNext.") }
        #expect(upNextRows.isEmpty)
    }

    @Test("The shows turned on through the app model count toward the Settings row")
    func upNextAutoAddPodcastIDsCountShowsTurnedOn() async throws {
        let secondPodcastID = "https://example.com/up-next-second.xml"
        let fixture = try await makeFixture(extraSubscriptionFeedURLs: [secondPodcastID])
        #expect(fixture.appModel.library.upNextAutoAddPodcastIDs.isEmpty)

        #expect(fixture.appModel.setUpNextAutoAddPosition(.bottom, forPodcastID: Self.podcastID, modelContext: fixture.context))
        #expect(fixture.appModel.setUpNextAutoAddPosition(.top, forPodcastID: secondPodcastID, modelContext: fixture.context))

        #expect(fixture.appModel.library.upNextAutoAddPodcastIDs.count == 2)

        #expect(fixture.appModel.setUpNextAutoAddPosition(nil, forPodcastID: Self.podcastID, modelContext: fixture.context))

        #expect(fixture.appModel.library.upNextAutoAddPodcastIDs == [secondPodcastID])
        #expect(fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == nil)
    }

    @Test("A pass before the core stores load leaves the stored watermarks alone; after the load it queues")
    func upNextAutoAddPassWaitsForCoreStores() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let feedURL = try #require(URL(string: Self.podcastID))
        let podcast = Podcast(id: PodcastID(rawValue: Self.podcastID), feedURL: feedURL, title: "Queue Show")
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: podcast,
                episodes: ["older", "newer"].enumerated().map { index, id in
                    Episode(
                        id: EpisodeID(rawValue: id),
                        podcastID: podcast.id,
                        podcastTitle: podcast.title,
                        title: "Episode \(id)",
                        publishedAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 86_400),
                        duration: 60,
                        audioURL: URL(string: "https://example.com/\(id).mp3"),
                        guid: id
                    )
                }
            ),
            refreshedAt: .now
        )
        let storedWatermark = UpNextAutoAddSettingsStore.encodeWatermark(.distantPast)
        context.insert(SubscriptionRecord(feedURL: Self.podcastID, title: "Queue Show", autoAddToUpNext: 2))
        context.insert(
            LocalPreferenceRecord(key: UpNextAutoAddSettingsStore.watermarkKeyPrefix + Self.podcastID, value: storedWatermark)
        )
        try context.save()
        let appModel = OpenCastAppModel(localLibraryCacheStore: cache, allowsAutomaticFeedRefresh: false)
        await appModel.library.load(modelContext: context)
        #expect(appModel.library.upNextAutoAddPodcastIDs == [Self.podcastID])

        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(try watermarkRows(forPodcastID: Self.podcastID, in: context) == [storedWatermark])
        #expect(appModel.upNextQueue.items.isEmpty)

        await appModel.ensureCoreStoresLoaded(modelContext: context)
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: context)
        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["newer", "older"])
        #expect(try watermarkRows(forPodcastID: Self.podcastID, in: context) != [storedWatermark])
    }

    @Test("A pass after a failed library load leaves the stored watermark alone; the next launch's load lets it run")
    func upNextAutoAddPassWaitsForALoadedLibrary() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let storedWatermark = UpNextAutoAddSettingsStore.encodeWatermark(.distantPast)
        context.insert(
            SubscriptionRecord(
                feedURL: Self.podcastID,
                title: "Auto Add Show",
                autoAddToUpNext: UpNextAutoAddPosition.bottom.stored
            )
        )
        context.insert(
            LocalPreferenceRecord(key: UpNextAutoAddSettingsStore.watermarkKeyPrefix + Self.podcastID, value: storedWatermark)
        )
        try context.save()
        let failedLaunch = OpenCastAppModel(localLibraryCacheStore: LoadFailingCacheStore(), allowsAutomaticFeedRefresh: false)
        await failedLaunch.ensureCoreStoresLoaded(modelContext: context)
        failedLaunch.restorePlaybackSurfaceIfNeeded(modelContext: context)
        #expect(failedLaunch.library.state == .failed("Simulated library load failure"))
        #expect(failedLaunch.coreStoresHydrated)

        failedLaunch.runUpNextAutoAddPass(modelContext: context)

        #expect(try watermarkRows(forPodcastID: Self.podcastID, in: context) == [storedWatermark])
        #expect(failedLaunch.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == .distantPast)
        #expect(failedLaunch.upNextQueue.items.isEmpty)

        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(
            from: Self.autoAddFeedSnapshot(feedURL: Self.podcastID, episodeIDs: ["older", "newer"]),
            refreshedAt: .now
        )
        let nextLaunch = OpenCastAppModel(localLibraryCacheStore: cache, allowsAutomaticFeedRefresh: false)
        await nextLaunch.ensureCoreStoresLoaded(modelContext: context)
        nextLaunch.restorePlaybackSurfaceIfNeeded(modelContext: context)
        nextLaunch.runUpNextAutoAddPass(modelContext: context)

        #expect(nextLaunch.upNextQueue.items.map(\.episodeID) == ["older", "newer"])
        #expect(nextLaunch.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == Self.autoAddRelease(1))
    }

    @Test("After a data nuke, a show turned on again in the same session gets its passes")
    func upNextAutoAddPassRunsAfterADataNuke() async throws {
        // The nuke refuses to run without an iCloud account.
        let fixture = try await makeAutoAddFixture(
            episodeIDsByFeedURL: [Self.podcastID: ["older"]],
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableCloudKitAccountStatusProvider())
        )
        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)
        try await fixture.appModel.nukeAllData(modelContext: fixture.context)
        #expect(fixture.appModel.library.subscriptions.isEmpty)

        try await fixture.cache.upsertCache(
            from: Self.autoAddFeedSnapshot(feedURL: Self.podcastID, episodeIDs: ["older"]),
            refreshedAt: .now
        )
        fixture.context.insert(SubscriptionRecord(feedURL: Self.podcastID, title: "Auto Add Show"))
        try fixture.context.save()
        try await fixture.appModel.library.reloadPersistedData(modelContext: fixture.context)
        #expect(fixture.appModel.setUpNextAutoAddPosition(.bottom, forPodcastID: Self.podcastID, modelContext: fixture.context))
        try await fixture.cache.upsertCache(
            from: Self.autoAddFeedSnapshot(feedURL: Self.podcastID, episodeIDs: ["older", "newer"]),
            refreshedAt: .now
        )
        try await fixture.appModel.library.reloadPersistedData(modelContext: fixture.context)

        fixture.appModel.runUpNextAutoAddPass(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["newer"])
        #expect(fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID) == Self.autoAddRelease(1))
    }

    @Test("A pass waits for playback restoration, then leaves the restored episode out as the current one")
    func upNextAutoAddPassWaitsForPlaybackRestoration() async throws {
        let fixture = try await makeAutoAddFixture(
            episodeIDsByFeedURL: [Self.podcastID: ["older", "newer"]],
            restorableEpisodeID: "newer"
        )
        #expect(fixture.appModel.coreStoresHydrated)
        #expect(!fixture.appModel.hasRestoredPlaybackSurface)

        fixture.appModel.runUpNextAutoAddPass(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(
            try watermarkRows(forPodcastID: Self.podcastID, in: fixture.context)
                == [UpNextAutoAddSettingsStore.encodeWatermark(.distantPast)]
        )

        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newer")
        fixture.appModel.runUpNextAutoAddPass(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["older"])
        #expect(
            fixture.appModel.upNextAutoAddSettings.watermark(forPodcastID: Self.podcastID)
                == Self.autoAddRelease(1)
        )
    }

    @Test("A failed automatic queue save surfaces once as the Up Next error, after later saves in the pass and by hand succeed")
    func upNextAutoAddPassSurfacesAFailedQueueSave() async throws {
        let showA = "https://example.com/up-next-a.xml"
        let showB = "https://example.com/up-next-b.xml"
        var failsNextSave = false
        let upNextQueue = UpNextQueueStore { saveContext in
            if failsNextSave {
                failsNextSave = false
                throw AppModelQueueSaveFailure()
            }
            try saveContext.save()
        }
        let fixture = try await makeAutoAddFixture(
            episodeIDsByFeedURL: [showA: ["a-new"], showB: ["b-new"]],
            upNextQueue: upNextQueue
        )
        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)
        let showAFailure = "Unable to add the episode to Up Next: Simulated queue save failure"
        failsNextSave = true

        fixture.appModel.runUpNextAutoAddPass(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["b-new"])
        #expect(fixture.appModel.lastUpNextError == showAFailure)
        #expect(fixture.appModel.upNextQueue.lastErrorMessage == nil)

        let handPicked = episodeSnapshot(id: "hand-picked", podcastID: showB)
        fixture.appModel.performUpNextQueueMutation {
            fixture.appModel.upNextQueue.enqueueLast(handPicked, modelContext: fixture.context)
        }

        #expect(fixture.appModel.lastUpNextError == showAFailure)

        // The alert's dismissal; the next pass queues show A's episode and
        // has nothing left to report.
        fixture.appModel.lastUpNextError = nil
        fixture.appModel.runUpNextAutoAddPass(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["b-new", "hand-picked", "a-new"])
        #expect(fixture.appModel.lastUpNextError == nil)
    }

    @Test("The Up Next accessory shows only after restore with a queue and nothing loaded")
    func upNextAccessoryShowsOnlyAfterRestoreWithAQueueAndNothingLoaded() async throws {
        let fixture = try await makeFixture(queuedEpisodeID: "first")
        defer { fixture.appModel.playback.pause() }
        #expect(!fixture.appModel.hasRestoredPlaybackSurface)
        #expect(!fixture.appModel.showsUpNextAccessory)

        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)

        #expect(fixture.appModel.hasRestoredPlaybackSurface)
        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.upNextAccessoryEpisode?.episodeID == "first")

        #expect(fixture.appModel.advanceToNextQueuedEpisode(modelContext: fixture.context))

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.upNextQueue.items.isEmpty)
        #expect(!fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.nowPlayingPresentationRequest == 0)

        #expect(fixture.appModel.dismissCurrentPlayback(modelContext: fixture.context))

        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(!fixture.appModel.showsUpNextAccessory)
    }

    @Test("The Up Next accessory follows enqueue and clear after restore")
    func upNextAccessoryTracksQueueChangesAfterRestore() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)
        #expect(!fixture.appModel.showsUpNextAccessory)

        #expect(fixture.appModel.upNextQueue.enqueueLast(first, modelContext: fixture.context))
        #expect(fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.upNextAccessoryEpisode?.episodeID == "first")

        #expect(fixture.appModel.upNextQueue.clear(modelContext: fixture.context))
        #expect(!fixture.appModel.showsUpNextAccessory)
    }

    @Test("The Up Next accessory needs a resolvable queue item and skips a stale head")
    func upNextAccessoryNeedsAResolvableQueueItem() async throws {
        let fixture = try await makeFixture()
        let stale = episodeSnapshot(id: "stale", podcastID: Self.podcastID)
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)

        #expect(fixture.appModel.upNextQueue.enqueueLast(stale, modelContext: fixture.context))
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["stale"])
        #expect(!fixture.appModel.showsUpNextAccessory)

        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        #expect(fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.upNextAccessoryEpisode?.episodeID == "second")
    }

    @Test("A restored episode wins over the queued accessory on cold launch")
    func restoredEpisodeWinsOverTheQueuedAccessoryOnColdLaunch() async throws {
        let fixture = try await makeFixture(queuedEpisodeID: "second", restorableEpisodeID: "first")
        #expect(!fixture.appModel.showsUpNextAccessory)

        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)

        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(fixture.appModel.playback.state != .playing)
        #expect(!fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["second"])
        #expect(try lastPlaybackEpisodeIDs(in: fixture.context) == ["first"])
    }

    @Test("A retained Finished card hides the queued accessory until it is dismissed")
    func finishedCardKeepsTheQueuedAccessoryHiddenUntilDismissed() async throws {
        let fixture = try await makeFixture()
        let first = try #require(fixture.appModel.episodeSnapshot(for: "first"))
        let second = try #require(fixture.appModel.episodeSnapshot(for: "second"))
        fixture.appModel.restorePlaybackSurfaceIfNeeded(modelContext: fixture.context)
        try playWithoutAutoplay(first, fixture: fixture)
        fixture.appModel.isNowPlayingPresented = true
        fixture.appModel.playback.handleCurrentItemDidPlayToEnd()
        #expect(fixture.appModel.playback.currentEpisode == nil)
        #expect(fixture.appModel.finishedPlaybackPresentation != nil)

        #expect(fixture.appModel.upNextQueue.enqueueLast(second, modelContext: fixture.context))
        #expect(!fixture.appModel.showsUpNextAccessory)

        fixture.appModel.dismissNowPlayingAndDiscardFinishedPlayback()

        #expect(fixture.appModel.showsUpNextAccessory)
        #expect(fixture.appModel.upNextAccessoryEpisode?.episodeID == "second")
    }

    @Test("Up Next accessory copy inflects the queued count")
    func upNextAccessoryCopyInflects() {
        #expect(UpNextAccessoryText.subtitle(queuedCount: 1) == "Up Next · 1 episode")
        #expect(UpNextAccessoryText.subtitle(queuedCount: 3) == "Up Next · 3 episodes")
        #expect(UpNextAccessoryText.queuedEpisodes(1) == "1 episode queued")
        #expect(UpNextAccessoryText.queuedEpisodes(3) == "3 episodes queued")
    }

    private func makeFixture(
        skipIntroSeconds: TimeInterval = 0,
        skipOutroSeconds: TimeInterval = 0,
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        queuedEpisodeID: String? = nil,
        restorableEpisodeID: String? = nil,
        extraSubscriptionFeedURLs: [String] = [],
        syncStatus: SyncStatusStore = SyncStatusStore()
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
        for feedURL in extraSubscriptionFeedURLs {
            context.insert(SubscriptionRecord(feedURL: feedURL, title: "Extra Show"))
        }
        if let queuedEpisodeID {
            context.insert(
                UpNextQueueItemRecord(
                    episodeID: queuedEpisodeID,
                    podcastID: Self.podcastID,
                    sequence: 0
                )
            )
        }
        if let restorableEpisodeID {
            context.insert(
                EpisodeProgressRecord(
                    episodeID: restorableEpisodeID,
                    podcastID: Self.podcastID,
                    position: 30,
                    duration: 60
                )
            )
            context.insert(
                LocalPreferenceRecord(
                    key: PlaybackRestorePreferenceStore.episodeIDKey,
                    value: restorableEpisodeID
                )
            )
        }
        try context.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: cache,
            upNextQueue: upNextQueue,
            syncStatus: syncStatus,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context)
    }

    /// Day `day` of the Auto Add fixture's releases.
    private static func autoAddRelease(_ day: Int) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400)
    }

    /// A show whose episodes are released a day apart in array order,
    /// starting on day 0.
    private static func autoAddFeedSnapshot(feedURL feedURLString: String, episodeIDs: [String]) throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: feedURLString))
        let podcast = Podcast(id: PodcastID(rawValue: feedURLString), feedURL: feedURL, title: "Auto Add Show")
        return FeedSnapshot(
            podcast: podcast,
            episodes: episodeIDs.enumerated().map { index, id in
                Episode(
                    id: EpisodeID(rawValue: id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(id)",
                    publishedAt: autoAddRelease(index),
                    duration: 60,
                    audioURL: URL(string: "https://example.com/\(id).mp3"),
                    guid: id
                )
            }
        )
    }

    /// Hydrated, with every show subscribed at Bottom and a watermark older
    /// than all of its episodes (`autoAddFeedSnapshot`). Playback
    /// restoration is left to the test.
    private func makeAutoAddFixture(
        episodeIDsByFeedURL: [String: [String]],
        restorableEpisodeID: String? = nil,
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        syncStatus: SyncStatusStore = SyncStatusStore()
    ) async throws -> (appModel: OpenCastAppModel, context: ModelContext, cache: SQLiteLocalLibraryCacheStore) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        for (feedURLString, episodeIDs) in episodeIDsByFeedURL {
            try await cache.upsertCache(
                from: Self.autoAddFeedSnapshot(feedURL: feedURLString, episodeIDs: episodeIDs),
                refreshedAt: .now
            )
            context.insert(
                SubscriptionRecord(
                    feedURL: feedURLString,
                    title: "Auto Add Show",
                    autoAddToUpNext: UpNextAutoAddPosition.bottom.stored
                )
            )
            context.insert(
                LocalPreferenceRecord(
                    key: UpNextAutoAddSettingsStore.watermarkKeyPrefix + feedURLString,
                    value: UpNextAutoAddSettingsStore.encodeWatermark(.distantPast)
                )
            )
        }
        if let restorableEpisodeID {
            let podcastID = try #require(
                episodeIDsByFeedURL.first { $0.value.contains(restorableEpisodeID) }?.key
            )
            context.insert(
                EpisodeProgressRecord(episodeID: restorableEpisodeID, podcastID: podcastID, position: 30, duration: 60)
            )
            context.insert(
                LocalPreferenceRecord(key: PlaybackRestorePreferenceStore.episodeIDKey, value: restorableEpisodeID)
            )
        }
        try context.save()
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: cache,
            upNextQueue: upNextQueue,
            syncStatus: syncStatus,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context, cache)
    }

    private func watermarkRows(forPodcastID podcastID: String, in context: ModelContext) throws -> [String] {
        let key = UpNextAutoAddSettingsStore.watermarkKeyPrefix + podcastID
        return try ModelContext(context.container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
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
