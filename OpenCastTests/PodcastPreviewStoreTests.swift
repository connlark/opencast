import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast preview store")
struct PodcastPreviewStoreTests {
    private static let newestEpisodeDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let currentFeedURL = "https://feeds.example.com/current"
    private let archiveFeedURL = "https://feeds.example.com/archive"

    @Test("A show whose recommended feed is the shorter one opens on that feed")
    func opensOnShorterRecommendedFeed() async throws {
        let store = try Harness(feeds: staleArchiveFeeds()).makeStore()

        await store.load(PodcastPreviewRequest(subject: .result(twoFeedResult())))

        #expect(store.displayedFeed?.candidate.candidate.feedURL.absoluteString == currentFeedURL)
    }

    @Test("Subscribe writes the feed chosen in the menu from the read already made, even when the sheet closes at once")
    func subscribeWritesChosenFeedWithoutSecondFetch() async throws {
        let harness = try Harness(feeds: staleArchiveFeeds())
        var store: PodcastPreviewStore? = harness.makeStore()
        await store?.load(PodcastPreviewRequest(subject: .result(twoFeedResult())))
        store?.selectedFeedID = archiveFeedURL

        store?.subscribe(through: harness.flow, library: harness.library, modelContext: harness.modelContext)
        store = nil
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.library.subscriptions.map(\.feedURL) == [archiveFeedURL])
        #expect(await harness.feedService.fetchedURLs.sorted() == [archiveFeedURL, currentFeedURL])
    }

    @Test("Closing the sheet while the feed loads cancels the read", .timeLimit(.minutes(1)))
    func closingWhileLoadingCancelsTheRead() async throws {
        let harness = try Harness(feeds: staleArchiveFeeds(), heldFeedURLs: [currentFeedURL])
        let store = harness.makeStore()
        let loading = Task { await store.load(PodcastPreviewRequest(subject: .feedURL(URL(string: currentFeedURL)!))) }
        await harness.feedService.waitUntilHeld()

        loading.cancel()
        await loading.value

        #expect(await harness.feedService.cancelledURLs == [currentFeedURL])
    }

    @Test("A load that finishes after its replacement is never published", .timeLimit(.minutes(1)))
    func loadFinishingAfterItsReplacementIsNeverPublished() async throws {
        let harness = try Harness(feeds: staleArchiveFeeds(), heldFeedURLs: [currentFeedURL])
        let store = harness.makeStore()
        let loadingFirst = Task { await store.load(PodcastPreviewRequest(subject: .feedURL(URL(string: currentFeedURL)!))) }
        await harness.feedService.waitUntilHeld()

        await store.load(PodcastPreviewRequest(subject: .feedURL(URL(string: archiveFeedURL)!)))
        await harness.feedService.release(currentFeedURL)
        await loadingFirst.value
        store.subscribe(through: harness.flow, library: harness.library, modelContext: harness.modelContext)
        await harness.flow.waitForCurrentSubscription()

        #expect(harness.library.subscriptions.map(\.feedURL) == [archiveFeedURL])
    }

    private func staleArchiveFeeds() -> [String: FeedSnapshot] {
        [
            currentFeedURL: makeSnapshot(feedURL: currentFeedURL, episodeCount: 3, newest: Self.newestEpisodeDate),
            archiveFeedURL: makeSnapshot(
                feedURL: archiveFeedURL,
                episodeCount: 9,
                newest: Self.newestEpisodeDate.addingTimeInterval(-90 * 24 * 60 * 60)
            ),
        ]
    }

    private func twoFeedResult() -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: "apple:917918570",
            title: "Serial",
            feedURL: URL(string: currentFeedURL),
            appleID: 917_918_570,
            sources: [.apple, .podcastIndex],
            feedCandidates: [
                DirectoryFeedCandidate(source: .apple, feedURL: URL(string: currentFeedURL)!),
                DirectoryFeedCandidate(source: .podcastIndex, feedURL: URL(string: archiveFeedURL)!),
            ]
        )
    }

    private func makeSnapshot(feedURL: String, episodeCount: Int, newest: Date) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let podcastID = URLCanonicalizer.podcastID(for: url)
        let episodes = (0..<episodeCount).map { index in
            Episode(
                id: EpisodeID(rawValue: "\(podcastID.rawValue)#episode-\(index)"),
                podcastID: podcastID,
                podcastTitle: "Serial",
                title: "Episode \(episodeCount - index)",
                publishedAt: newest.addingTimeInterval(TimeInterval(-index * 24 * 60 * 60)),
                audioURL: URL(string: "https://audio.example.com/\(index).mp3"),
                guid: "episode-\(index)"
            )
        }
        return FeedSnapshot(podcast: Podcast(id: podcastID, feedURL: url, title: "Serial"), episodes: episodes)
    }

    @MainActor
    private struct Harness {
        let feedService: PreviewFeedService
        let library: LibraryStore
        let flow: DirectorySubscriptionFlowStore
        let modelContext: ModelContext
        let knownPodcasts: KnownPodcastsStore

        init(feeds: [String: FeedSnapshot], heldFeedURLs: Set<String> = []) throws {
            modelContext = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
            feedService = PreviewFeedService(snapshots: feeds, heldURLs: heldFeedURLs)
            library = LibraryStore(feedService: feedService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
            knownPodcasts = KnownPodcastsStore()
            flow = DirectorySubscriptionFlowStore(
                directoryService: NoDirectoryService(),
                resolver: DirectoryFeedCandidateResolver(feedService: feedService),
                knownPodcasts: knownPodcasts
            )
        }

        func makeStore() -> PodcastPreviewStore {
            PodcastPreviewStore(
                directoryService: NoDirectoryService(),
                resolver: DirectoryFeedCandidateResolver(feedService: feedService),
                knownPodcasts: knownPodcasts
            )
        }
    }
}

private struct NoDirectoryService: PodcastDirectoryService {
    func search(query: String) async throws -> [DirectoryPodcastResult] {
        []
    }
}

private actor PreviewFeedService: FeedService {
    private let snapshots: [String: FeedSnapshot]
    private let heldURLs: Set<String>
    private var held: [String: CheckedContinuation<FeedSnapshot, any Error>] = [:]
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var fetchedURLs: [String] = []
    private(set) var cancelledURLs: [String] = []

    init(snapshots: [String: FeedSnapshot], heldURLs: Set<String>) {
        self.snapshots = snapshots
        self.heldURLs = heldURLs
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        fetchedURLs.append(key)
        guard heldURLs.contains(key) else {
            guard let snapshot = snapshots[key] else {
                throw OpenCastCoreError.unexpectedStatusCode(404)
            }
            return snapshot
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    cancelledURLs.append(key)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                held[key] = continuation
                let waiters = heldWaiters
                heldWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    func waitUntilHeld() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release(_ key: String) {
        guard let snapshot = snapshots[key] else { return }
        held.removeValue(forKey: key)?.resume(returning: snapshot)
    }

    private func cancel(_ key: String) {
        guard let continuation = held.removeValue(forKey: key) else { return }
        cancelledURLs.append(key)
        continuation.resume(throwing: CancellationError())
    }
}
