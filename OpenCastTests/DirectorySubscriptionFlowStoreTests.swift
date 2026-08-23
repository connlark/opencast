import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Directory subscription flow store")
struct DirectorySubscriptionFlowStoreTests {
    private static let newestEpisodeDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let windowedFeedURL = "https://feeds.example.com/windowed"
    private let fullFeedURL = "https://feeds.example.com/full"

    @Test("A single-candidate result subscribes directly")
    func singleCandidateSubscribesDirectly() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 3)
            ]
        )
        var didSubscribe = false

        harness.flow.subscribe(
            to: appleOnlyResult(),
            library: harness.library,
            modelContext: harness.modelContext,
            onSubscribed: { didSubscribe = true }
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(didSubscribe)
        #expect(harness.library.subscriptions.map(\.feedURL) == [windowedFeedURL])
        #expect(harness.flow.pendingChoice == nil)
        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.flow.errorMessage == nil)
    }

    @Test("Apple-only results are enriched through the Apple-ID lookup")
    func appleOnlyResultsAreEnriched() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ],
            lookupResult: podcastIndexEnrichment()
        )

        harness.flow.subscribe(
            to: appleOnlyResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(await harness.directoryService.requestedLookupAppleIDs() == [917_918_570])
        let pending = try #require(harness.flow.pendingChoice)
        #expect(pending.choice.reason == .fullerFeedPromoted)
        #expect(pending.choice.primary.candidate.feedURL.absoluteString == fullFeedURL)
        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.library.subscriptions.isEmpty)
    }

    @Test("Choosing the promoted feed subscribes to the fuller catalog")
    func choosingPromotedFeedSubscribes() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ],
            lookupResult: podcastIndexEnrichment()
        )
        harness.flow.subscribe(
            to: appleOnlyResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()
        let pending = try #require(harness.flow.pendingChoice)

        harness.flow.subscribe(
            candidate: pending.choice.primary,
            for: pending,
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.pendingChoice == nil)
        #expect(harness.library.subscriptions.map(\.feedURL) == [fullFeedURL])
    }

    @Test("A failed enrichment lookup still subscribes to the Apple feed")
    func failedEnrichmentFallsBackToAppleFeed() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33)
            ],
            lookupError: StubFlowError(message: "worker down")
        )

        harness.flow.subscribe(
            to: appleOnlyResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.library.subscriptions.map(\.feedURL) == [windowedFeedURL])
        #expect(harness.flow.errorMessage == nil)
    }

    @Test("A feedless Apple result subscribes through the Apple-ID lookup")
    func feedlessAppleResultSubscribesThroughLookup() async throws {
        let harness = try Harness(
            feeds: [
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124)
            ],
            lookupResult: podcastIndexEnrichment()
        )
        var didSubscribe = false

        harness.flow.subscribe(
            to: feedlessAppleResult(),
            library: harness.library,
            modelContext: harness.modelContext,
            onSubscribed: { didSubscribe = true }
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(await harness.directoryService.requestedLookupAppleIDs() == [917_918_570])
        #expect(didSubscribe)
        #expect(harness.library.subscriptions.map(\.feedURL) == [fullFeedURL])
        #expect(harness.flow.errorMessage == nil)
        #expect(harness.flow.subscribingResultID == nil)
    }

    @Test("A feedless Apple result with a failed lookup surfaces an error")
    func feedlessAppleResultWithFailedLookupSurfacesError() async throws {
        let harness = try Harness(
            feeds: [:],
            lookupError: StubFlowError(message: "worker down")
        )

        harness.flow.subscribe(
            to: feedlessAppleResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.errorMessage != nil)
        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.library.subscriptions.isEmpty)
    }

    @Test("A result with no feed and no lookup capability is rejected")
    func unresolvableResultIsRejected() async throws {
        let harness = try Harness(feeds: [:])

        harness.flow.subscribe(
            to: DirectoryPodcastResult(
                id: "podcastindex:1",
                title: "Unresolvable",
                sources: [.podcastIndex],
                feedCandidates: []
            ),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.flow.errorMessage == nil)
        #expect(harness.library.subscriptions.isEmpty)
    }

    @Test("Merged results resolve without an extra lookup")
    func mergedResultsSkipEnrichment() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ]
        )

        harness.flow.subscribe(
            to: mergedResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(await harness.directoryService.requestedLookupAppleIDs().isEmpty)
        #expect(harness.flow.pendingChoice != nil)
    }

    @Test("A choice resolved after the presenter is gone subscribes to the primary")
    func detachedResolutionSubscribesToPrimary() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ]
        )

        harness.flow.subscribe(
            to: mergedResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        harness.flow.presenterDidDisappear(
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.pendingChoice == nil)
        #expect(harness.library.subscriptions.map(\.feedURL) == [fullFeedURL])
        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.flow.errorMessage == nil)
    }

    @Test("A pending choice orphaned by dismissal subscribes to the primary")
    func orphanedPendingChoiceSubscribesToPrimary() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ]
        )
        harness.flow.subscribe(
            to: mergedResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()
        #expect(harness.flow.pendingChoice != nil)

        harness.flow.presenterDidDisappear(
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.pendingChoice == nil)
        #expect(harness.library.subscriptions.map(\.feedURL) == [fullFeedURL])
    }

    @Test("A cancelled choice does not resubscribe when the presenter disappears")
    func cancelledChoiceStaysCancelledAfterDetach() async throws {
        let harness = try Harness(
            feeds: [
                windowedFeedURL: makeSnapshot(feedURL: windowedFeedURL, episodeCount: 33),
                fullFeedURL: makeSnapshot(feedURL: fullFeedURL, episodeCount: 124),
            ]
        )
        harness.flow.subscribe(
            to: mergedResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()
        harness.flow.dismissChoice()

        harness.flow.presenterDidDisappear(
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.library.subscriptions.isEmpty)
    }

    @Test("Every candidate failing surfaces a subscription error")
    func everyCandidateFailingSurfacesError() async throws {
        let harness = try Harness(feeds: [:])

        harness.flow.subscribe(
            to: appleOnlyResult(),
            library: harness.library,
            modelContext: harness.modelContext
        )
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.flow.errorMessage != nil)
        #expect(harness.flow.subscribingResultID == nil)
        #expect(harness.library.subscriptions.isEmpty)
    }

    private func appleOnlyResult() -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: 917_918_570,
            title: "Serial",
            feedURL: URL(string: windowedFeedURL)
        )
    }

    private func feedlessAppleResult() -> DirectoryPodcastResult {
        DirectoryPodcastResult(id: 917_918_570, title: "Serial")
    }

    private func mergedResult() -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: "apple:917918570",
            title: "Serial",
            feedURL: URL(string: windowedFeedURL),
            appleID: 917_918_570,
            podcastIndexID: 745_392,
            sources: [.apple, .podcastIndex],
            feedCandidates: [
                DirectoryFeedCandidate(source: .apple, feedURL: URL(string: windowedFeedURL)!),
                DirectoryFeedCandidate(source: .podcastIndex, feedURL: URL(string: fullFeedURL)!),
            ]
        )
    }

    private func podcastIndexEnrichment() -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: "podcastindex:745392",
            title: "Serial",
            feedURL: URL(string: fullFeedURL),
            appleID: 917_918_570,
            podcastIndexID: 745_392,
            sources: [.podcastIndex],
            feedCandidates: [
                DirectoryFeedCandidate(source: .podcastIndex, feedURL: URL(string: fullFeedURL)!)
            ]
        )
    }

    private func makeSnapshot(feedURL: String, episodeCount: Int) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let podcastID = URLCanonicalizer.podcastID(for: url)
        let episodes = (0..<episodeCount).map { index in
            Episode(
                id: EpisodeID(rawValue: "\(podcastID.rawValue)#episode-\(index)"),
                podcastID: podcastID,
                podcastTitle: "Serial",
                title: "Episode \(episodeCount - index)",
                publishedAt: Self.newestEpisodeDate.addingTimeInterval(TimeInterval(-index * 24 * 60 * 60)),
                audioURL: URL(string: "https://audio.example.com/\(index).mp3"),
                guid: "episode-\(index)"
            )
        }
        return FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: url, title: "Serial"),
            episodes: episodes
        )
    }

    @MainActor
    private struct Harness {
        let flow: DirectorySubscriptionFlowStore
        let library: LibraryStore
        let modelContext: ModelContext
        let directoryService: StubFlowDirectoryService

        init(
            feeds: [String: FeedSnapshot],
            lookupResult: DirectoryPodcastResult? = nil,
            lookupError: StubFlowError? = nil
        ) throws {
            let container = try OpenCastModelContainerFactory.make(inMemory: true)
            modelContext = ModelContext(container)
            let feedService = StubFlowFeedService(snapshots: feeds)
            library = LibraryStore(
                feedService: feedService,
                localCache: SQLiteLocalLibraryCacheStore.inMemory()
            )
            directoryService = StubFlowDirectoryService(
                lookupResult: lookupResult,
                lookupError: lookupError
            )
            flow = DirectorySubscriptionFlowStore(
                directoryService: directoryService,
                resolver: DirectoryFeedCandidateResolver(feedService: feedService)
            )
        }
    }
}

private actor StubFlowDirectoryService: PodcastDirectoryService {
    private let lookupResult: DirectoryPodcastResult?
    private let lookupError: StubFlowError?
    private var lookupAppleIDs: [Int] = []

    init(lookupResult: DirectoryPodcastResult?, lookupError: StubFlowError?) {
        self.lookupResult = lookupResult
        self.lookupError = lookupError
    }

    func search(query: String) async throws -> [DirectoryPodcastResult] {
        []
    }

    func lookup(appleID: Int) async throws -> DirectoryPodcastResult? {
        lookupAppleIDs.append(appleID)
        if let lookupError {
            throw lookupError
        }
        return lookupResult
    }

    func requestedLookupAppleIDs() -> [Int] {
        lookupAppleIDs
    }
}

private struct StubFlowFeedService: FeedService {
    let snapshots: [String: FeedSnapshot]

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshots[url.absoluteString] else {
            throw OpenCastCoreError.unexpectedStatusCode(404)
        }
        return snapshot
    }
}

private struct StubFlowError: Error, Equatable {
    let message: String
}
