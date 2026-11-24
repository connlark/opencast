import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class PodcastPreviewStore {
    enum State {
        case loading
        case loaded(PodcastPreviewFeeds)
        case failed(PodcastPreviewFailure)
    }

    private(set) var request: PodcastPreviewRequest?
    private(set) var state = State.loading
    var selectedFeedID: String?

    @ObservationIgnored private let directoryService: any PodcastDirectoryService
    @ObservationIgnored private let resolver: DirectoryFeedCandidateResolver
    @ObservationIgnored private let knownPodcasts: KnownPodcastsStore

    init(
        directoryService: any PodcastDirectoryService,
        resolver: DirectoryFeedCandidateResolver,
        knownPodcasts: KnownPodcastsStore
    ) {
        self.directoryService = directoryService
        self.resolver = resolver
        self.knownPodcasts = knownPodcasts
    }

    var displayedFeed: PodcastPreviewFeed? {
        guard case .loaded(let feeds) = state else {
            return nil
        }
        return feeds.feed(id: selectedFeedID)
    }

    func libraryFeedURL(activePodcastIDs: Set<String>) -> String? {
        guard let request else {
            return nil
        }
        return knownPodcasts.libraryFeedURL(for: request.knownPodcastKey, activePodcastIDs: activePodcastIDs)
    }

    func load(_ request: PodcastPreviewRequest) async {
        self.request = request
        state = .loading
        selectedFeedID = nil
        let key = request.knownPodcastKey

        let handedOffChoice: DirectoryFeedChoice?
        let candidates: [DirectoryFeedCandidate]
        if case .resolvedChoice(_, let choice) = request.subject {
            handedOffChoice = choice
            candidates = [choice.primary.candidate]
        } else {
            handedOffChoice = nil
            do {
                candidates = try await self.candidates(for: request)
            } catch {
                if isCurrent(request) {
                    state = .failed(.offline)
                }
                return
            }
            knownPodcasts.learn(Set(candidates.map(\.canonicalFeedURLString)), about: key)
        }
        guard isCurrent(request) else {
            return
        }
        guard let firstFeedURL = candidates.first?.feedURL else {
            state = .failed(.noFeed)
            return
        }

        do {
            let outcome: DirectoryFeedResolution.Outcome
            if let handedOffChoice {
                outcome = .choice(handedOffChoice)
            } else {
                let resolution = try await resolver.resolve(candidates: candidates)
                knownPodcasts.learn(resolution.readFeedURLs, about: key)
                outcome = resolution.outcome
            }
            let feeds = try await PodcastPreviewFeeds.read(outcome)
            knownPodcasts.learn(Set(feeds.all.flatMap(\.knownFeedURLs)), about: key)
            guard isCurrent(request) else {
                return
            }
            selectedFeedID = feeds.recommended.id
            state = .loaded(feeds)
        } catch {
            let host = firstFeedURL.host() ?? firstFeedURL.absoluteString
            guard isCurrent(request), let failure = PodcastPreviewFailure(error: error, host: host) else {
                return
            }
            state = .failed(failure)
        }
    }

    func subscribe(
        through flow: DirectorySubscriptionFlowStore,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void = {}
    ) {
        guard let request, let feed = displayedFeed else {
            return
        }
        flow.subscribe(
            previewed: feed.candidate,
            request: request,
            library: library,
            modelContext: modelContext,
            onSubscribed: onSubscribed
        )
    }

    private func isCurrent(_ request: PodcastPreviewRequest) -> Bool {
        !Task.isCancelled && self.request == request
    }

    private func candidates(for request: PodcastPreviewRequest) async throws -> [DirectoryFeedCandidate] {
        switch request.subject {
        case .result(let result), .resolvedChoice(let result, _):
            try await result.enrichedFeedCandidates(using: directoryService)
        case .feedURL(let feedURL):
            [DirectoryFeedCandidate(source: .apple, feedURL: feedURL)]
        }
    }
}
