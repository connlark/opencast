import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding completion service")
struct OnboardingCompletionServiceTests {
    @Test("Empty library finish needs sample confirmation")
    func emptyLibraryFinishNeedsSampleConfirmation() {
        #expect(OnboardingCompletionService.needsSampleConfirmation(activePodcastIDs: []))
    }

    @Test("Existing subscriptions finish without sample confirmation")
    func existingSubscriptionsFinishWithoutSampleConfirmation() {
        #expect(!OnboardingCompletionService.needsSampleConfirmation(activePodcastIDs: [
            "https://example.com/feed.xml"
        ]))
    }

    @Test("Sample suggestions include public App Review samples with artwork")
    func sampleSuggestionsIncludePublicAppReviewSamplesWithArtwork() {
        #expect(OpenCastSamplePodcastSuggestions.all.contains { result in
            result.title == "This American Life"
                && result.feedURLString == OpenCastConstants.thisAmericanLifeFeedURL
                && result.artworkURL != nil
        })
        #expect(OpenCastSamplePodcastSuggestions.all.contains { result in
            result.title == "LibriVox Community Podcast"
                && result.feedURLString == OpenCastConstants.libriVoxCommunityFeedURL
                && result.artworkURL != nil
        })
        #expect(OpenCastSamplePodcastSuggestions.all.allSatisfy { result in
            result.artworkURL != nil
        })
        #expect(OpenCastSamplePodcastSuggestions.all.contains { result in
            result.feedURLString?.contains("private-feed") == true
        } == false)
    }

    @Test("Sample suggestions keep This American Life fallback")
    func sampleSuggestionsKeepThisAmericanLifeFallback() {
        #expect(OpenCastSamplePodcastSuggestions.all.contains { result in
            result.title == "This American Life"
                && result.feedURLString == OpenCastConstants.thisAmericanLifeFeedURL
        })
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
        let library = LibraryStore(feedService: feedService)
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
        let library = LibraryStore(feedService: feedService)
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

private struct StubOnboardingFeedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
