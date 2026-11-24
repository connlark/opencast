import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding completion service")
struct OnboardingCompletionServiceTests {
    @Test("Finishing while a quick add is in flight completes with that show and no fallback offer")
    func finishingWhileAQuickAddIsInFlightCompletesWithThatShow() async throws {
        let context = try makeContext()
        let feedURL = "https://example.com/quick-add.xml"
        let (library, addFlow) = startQuickAdd(of: feedURL, modelContext: context)
        let onboardingState = OnboardingStateStore()

        let outcome = try await OnboardingCompletionService.finish(
            after: addFlow,
            library: library,
            onboardingState: onboardingState,
            modelContext: context
        )

        #expect(outcome == .completed)
        #expect(library.subscriptions.map(\.feedURL) == [feedURL])
        #expect(onboardingState.isCompleted)
    }

    @Test("A finish cancelled before its wait ends completes nothing and offers nothing")
    func cancelledFinishCompletesNothing() async throws {
        let context = try makeContext()
        let feedURL = "https://example.com/quick-add.xml"
        let (library, addFlow) = startQuickAdd(of: feedURL, modelContext: context)
        let onboardingState = OnboardingStateStore()

        let finishing = Task {
            try await OnboardingCompletionService.finish(
                after: addFlow,
                library: library,
                onboardingState: onboardingState,
                modelContext: context
            )
        }
        finishing.cancel()

        await #expect(throws: CancellationError.self) {
            try await finishing.value
        }
        #expect(!onboardingState.isCompleted)
        #expect(library.subscriptions.map(\.feedURL) == [feedURL])
    }

    @Test("Fallback subscription uses This American Life and completes onboarding")
    func fallbackSubscriptionUsesThisAmericanLifeAndCompletesOnboarding() async throws {
        let context = try makeContext()
        let feedService = StubOnboardingFeedService(responses: [
            OpenCastConstants.thisAmericanLifeFeedURL: .success(
                makeSnapshot(
                    feedURL: OpenCastConstants.thisAmericanLifeFeedURL,
                    podcastTitle: "This American Life",
                    episodeID: "tal-episode-1"
                )
            )
        ])
        let library = LibraryStore(feedService: feedService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let onboardingState = OnboardingStateStore()

        try await OnboardingCompletionService.subscribeToFallbackAndComplete(
            library: library,
            onboardingState: onboardingState,
            modelContext: context
        )

        #expect(await feedService.requestedURLStrings() == [OpenCastConstants.thisAmericanLifeFeedURL])
        #expect(library.subscriptions.map(\.feedURL) == [OpenCastConstants.thisAmericanLifeFeedURL])
        #expect(library.episodes.map(\.episodeID) == ["tal-episode-1"])
        #expect(onboardingState.isCompleted)
        #expect(try LocalPreferenceRecord.preference(
            forKey: OnboardingStateStore.completedPreferenceKey,
            modelContext: context
        )?.value == "true")
    }

    @Test("Fallback failure keeps onboarding incomplete")
    func fallbackFailureKeepsOnboardingIncomplete() async throws {
        let context = try makeContext()
        let feedService = StubOnboardingFeedService(responses: [
            OpenCastConstants.thisAmericanLifeFeedURL: .failure("Feed offline")
        ])
        let library = LibraryStore(feedService: feedService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let onboardingState = OnboardingStateStore()

        do {
            try await OnboardingCompletionService.subscribeToFallbackAndComplete(
                library: library,
                onboardingState: onboardingState,
                modelContext: context
            )
            Issue.record("Expected fallback subscription to fail.")
        } catch {
            #expect(error.localizedDescription == "Feed offline")
        }

        #expect(await feedService.requestedURLStrings() == [OpenCastConstants.thisAmericanLifeFeedURL])
        #expect(library.subscriptions.isEmpty)
        #expect(!onboardingState.isCompleted)
        #expect(try LocalPreferenceRecord.preference(
            forKey: OnboardingStateStore.completedPreferenceKey,
            modelContext: context
        ) == nil)
    }

    private func startQuickAdd(of feedURL: String, modelContext: ModelContext) -> (LibraryStore, DirectorySubscriptionFlowStore) {
        let feedService = StubOnboardingFeedService(responses: [
            feedURL: .success(makeSnapshot(feedURL: feedURL, podcastTitle: "Quick Add", episodeID: "quick-add-1"))
        ])
        let library = LibraryStore(feedService: feedService, localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let addFlow = DirectorySubscriptionFlowStore(
            directoryService: StubOnboardingDirectoryService(),
            resolver: DirectoryFeedCandidateResolver(feedService: feedService),
            knownPodcasts: KnownPodcastsStore()
        )
        addFlow.subscribe(
            to: DirectoryPodcastResult(id: 1, title: "Quick Add", feedURL: URL(string: feedURL)),
            library: library,
            modelContext: modelContext
        )
        return (library, addFlow)
    }

    private func makeContext() throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        return ModelContext(container)
    }

    private func makeSnapshot(
        feedURL: String,
        podcastTitle: String,
        episodeID: String
    ) -> FeedSnapshot {
        let podcastID = PodcastID(rawValue: feedURL)
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: podcastTitle,
                author: "\(podcastTitle) Author"
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: "Episode for \(podcastTitle)",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 120,
                    audioURL: URL(string: "https://example.com/\(episodeID).mp3"),
                    guid: episodeID
                )
            ]
        )
    }
}

private actor StubOnboardingFeedService: FeedService {
    enum Response: Sendable {
        case success(FeedSnapshot)
        case failure(String)
    }

    private var responsesByURL: [String: [Response]]
    private var requestedURLs: [String] = []

    init(responses: [String: Response]) {
        responsesByURL = responses.mapValues { [$0] }
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        requestedURLs.append(key)

        guard var responses = responsesByURL[key],
              !responses.isEmpty
        else {
            throw StubOnboardingFeedError(message: "No stub response for \(key)")
        }

        let response = responses.removeFirst()
        responsesByURL[key] = responses

        switch response {
        case .success(let snapshot):
            return snapshot
        case .failure(let message):
            throw StubOnboardingFeedError(message: message)
        }
    }

    func requestedURLStrings() -> [String] {
        requestedURLs
    }
}

private struct StubOnboardingDirectoryService: PodcastDirectoryService {
    func search(query: String) async throws -> [DirectoryPodcastResult] {
        []
    }
}

private struct StubOnboardingFeedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
